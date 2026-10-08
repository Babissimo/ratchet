// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import AppKit
@testable import RatchetCore

// Exercises @MainActor-isolated types (see DataStore's isolation), so the whole case is pinned
// to the main actor rather than annotating every test method.
@MainActor
final class StatusItemControllerTests: XCTestCase {
    private var controller: StatusItemController?

    override func tearDown() {
        // tearDown() is nonisolated (inherited from XCTestCase), but this class is @MainActor —
        // its body touches main-actor state, so it must run inside an isolated context explicitly.
        MainActor.assumeIsolated {
            if let controller {
                NSStatusBar.system.removeStatusItem(controller.statusItemForTesting)
            }
            controller = nil
        }
        super.tearDown()
    }

    func test_construction_setsInitialMenuOnStatusItem() {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller

        XCTAssertNotNil(controller.statusItemForTesting.menu)
        XCTAssertEqual(controller.statusItemForTesting.menu?.items.first?.title, "Log in with browser")
    }

    func test_stateChange_rebuildsMenu() {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller

        appState.logIn()

        XCTAssertEqual(controller.statusItemForTesting.menu?.items.first?.title, "Start timer")
    }

    func test_tooltip_loggedOut_isNil() {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller

        XCTAssertNil(controller.statusItemForTesting.button?.toolTip)
    }

    func test_tooltip_idle_showsIdle() {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller

        appState.logIn()

        XCTAssertEqual(controller.statusItemForTesting.button?.toolTip, "Idle")
    }

    func test_tooltip_tracking_showsElapsedTaskAndClientProject() {
        let startedAt = Date(timeIntervalSince1970: 1_000_000)
        let now = startedAt.addingTimeInterval(90) // 1 minute 30 seconds in
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore, now: { now })
        self.controller = controller

        appState.logIn()
        let task = TrackedTaskRef(
            clientId: "client-1", clientName: "Acme",
            projectId: "proj-1", projectName: "Website Redesign",
            taskId: "task-1", taskName: "Development"
        )
        appState.startTracking(task, startedAt: startedAt)

        XCTAssertEqual(
            controller.statusItemForTesting.button?.toolTip,
            "0:01\nTracking Development\nAcme · Website Redesign"
        )
    }

    /// Nothing rebuilds the menu at midnight, and the first open after it can't (an open menu is
    /// never rebuilt), so the elapsed row's per-second tick has to bring in the booked-day note.
    func test_elapsedRow_notesTheBookedDayOncePastMidnight_withoutARebuild() throws {
        let booked = CalendarDay.day(from: "2026-08-12")!
        let startedAt = booked.addingTimeInterval(23 * 3600)
        var now = startedAt.addingTimeInterval(59 * 60)
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        dataStore.seedTimeslips([RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            day: booked, timerStartedAt: startedAt, hours: 0
        )], runningId: "timeslip-1")
        let controller = StatusItemController(appState: appState, dataStore: dataStore, now: { now })
        self.controller = controller
        appState.logIn()
        appState.startTracking(TrackedTaskRef(
            clientId: "client-1", clientName: "Acme",
            projectId: "proj-1", projectName: "Website Redesign",
            taskId: "task-1", taskName: "Development"
        ), startedAt: startedAt)
        let menu = controller.statusItemForTesting.menu!
        XCTAssertEqual(menu.items[0].title, "0:59")

        now = startedAt.addingTimeInterval(61 * 60)
        try XCTUnwrap(controller.elapsedTimerForTesting).fire()

        XCTAssertTrue(controller.statusItemForTesting.menu === menu, "the tick, not a rebuild, updates the row")
        XCTAssertEqual(menu.items[0].title, "1:01 · booked to yesterday")
    }

    /// An open menu isn't rebuilt when a refresh lands, so the tick keeps the booked day of the
    /// timeslip the rest of that menu was built from rather than whatever the store holds now.
    func test_elapsedRow_keepsTheBookedDayItsMenuWasBuiltFrom() throws {
        let yesterday = CalendarDay.day(from: "2026-08-12")!
        let today = CalendarDay.day(from: "2026-08-13")!
        let startedAt = yesterday.addingTimeInterval(17 * 3600)
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        dataStore.seedTimeslips([RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            day: yesterday, timerStartedAt: startedAt, hours: 0
        )], runningId: "timeslip-1")
        let controller = StatusItemController(
            appState: appState, dataStore: dataStore, now: { today.addingTimeInterval(9 * 3600) }
        )
        self.controller = controller
        appState.logIn()
        appState.startTracking(TrackedTaskRef(
            clientId: "client-1", clientName: "Acme",
            projectId: "proj-1", projectName: "Website Redesign",
            taskId: "task-1", taskName: "Development"
        ), startedAt: startedAt)
        let menu = controller.statusItemForTesting.menu!
        XCTAssertEqual(menu.items[0].title, "16:00 · booked to yesterday")

        dataStore.seedTimeslips([RatchetTimeslip(
            id: "timeslip-2", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            day: today, timerStartedAt: startedAt, hours: 0
        )], runningId: "timeslip-2")
        try XCTUnwrap(controller.elapsedTimerForTesting).fire()

        XCTAssertEqual(menu.items[0].title, "16:00 · booked to yesterday")
    }

    func test_menuWillOpen_refreshesWhenNeverRefreshed() async {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller
        appState.logIn()

        let menu = controller.statusItemForTesting.menu!
        menu.delegate?.menuWillOpen?(menu)
        await drainMainActorQueue()

        XCTAssertEqual(dataStore.refreshCount, 1)
    }

    func test_menuWillOpen_skipsRefreshWhenRecentlyRefreshed() async throws {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        try await dataStore.refresh()
        XCTAssertEqual(dataStore.refreshCount, 1)

        let fixedNow = Date()
        let controller = StatusItemController(
            appState: appState, dataStore: dataStore,
            now: { fixedNow }
        )
        self.controller = controller
        appState.logIn()

        let menu = controller.statusItemForTesting.menu!
        menu.delegate?.menuWillOpen?(menu)
        await drainMainActorQueue()

        XCTAssertEqual(dataStore.refreshCount, 1, "a refresh 0s ago is well within the 2-minute staleness threshold")
    }

    func test_menuWillOpen_refreshesWhenStaleBeyondThreshold() async throws {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        try await dataStore.refresh()
        XCTAssertEqual(dataStore.refreshCount, 1)

        // 3 minutes after the refresh above — past the 2-minute threshold.
        let laterNow = dataStore.lastRefreshedAt!.addingTimeInterval(180)
        let controller = StatusItemController(
            appState: appState, dataStore: dataStore,
            now: { laterNow }
        )
        self.controller = controller
        appState.logIn()

        let menu = controller.statusItemForTesting.menu!
        menu.delegate?.menuWillOpen?(menu)
        await drainMainActorQueue()

        XCTAssertEqual(dataStore.refreshCount, 2)
    }

    func test_menuWillOpen_refreshFailure_isSilent() async {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        dataStore.refreshError = DataStoreError.notFound
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller
        appState.logIn()

        let menu = controller.statusItemForTesting.menu!
        // Must not crash and must not present a modal alert (no way to assert "no alert shown"
        // directly without blocking on NSAlert.runModal — the absence of a hang/crash here,
        // combined with the menu still reflecting the logged-in idle screen below, is the
        // signal that no alert was raised for this background failure).
        menu.delegate?.menuWillOpen?(menu)
        await drainMainActorQueue()

        XCTAssertEqual(controller.statusItemForTesting.menu?.items.first?.title, "Start timer")
    }

    func test_menuWillOpen_sessionExpired_logsOut() async {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        dataStore.refreshError = FakeSessionExpiredError()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller
        appState.logIn()

        let menu = controller.statusItemForTesting.menu!
        menu.delegate?.menuWillOpen?(menu)
        await drainMainActorQueue()

        XCTAssertEqual(controller.statusItemForTesting.menu?.items.first?.title, "Log in with browser")
    }

    func test_menuWillOpen_whenLoggedOut_doesNotRefresh() async {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller
        // No appState.logIn() — dataStore.lastRefreshedAt is nil, which the staleness gate would
        // otherwise treat as "stale" and refresh anyway, throwing .unauthorized and triggering a
        // false "session expired" alert for someone who simply never logged in.

        let menu = controller.statusItemForTesting.menu!
        menu.delegate?.menuWillOpen?(menu)
        await drainMainActorQueue()

        XCTAssertEqual(dataStore.refreshCount, 0)
    }

    func test_systemWake_refreshesWhenStale() async {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller
        appState.logIn()

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainActorQueue()

        XCTAssertEqual(dataStore.refreshCount, 1)
    }

    func test_systemWake_skipsRefreshWhenRecentlyRefreshed() async throws {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        try await dataStore.refresh()
        XCTAssertEqual(dataStore.refreshCount, 1)

        let fixedNow = Date()
        let controller = StatusItemController(
            appState: appState, dataStore: dataStore,
            now: { fixedNow }
        )
        self.controller = controller
        appState.logIn()

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainActorQueue()

        XCTAssertEqual(dataStore.refreshCount, 1, "a refresh 0s ago is well within the 2-minute staleness threshold")
    }

    func test_systemWake_refreshFailure_isSilent() async {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        dataStore.refreshError = DataStoreError.notFound
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller
        appState.logIn()

        // Must not crash and must not present a modal alert — same reasoning as
        // test_menuWillOpen_refreshFailure_isSilent above.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainActorQueue()

        XCTAssertEqual(controller.statusItemForTesting.menu?.items.first?.title, "Start timer")
    }

    func test_systemWake_sessionExpired_logsOut() async {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        dataStore.refreshError = FakeSessionExpiredError()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller
        appState.logIn()

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainActorQueue()

        XCTAssertEqual(controller.statusItemForTesting.menu?.items.first?.title, "Log in with browser")
    }

    /// Fire-and-forget `Task { @MainActor in ... }` work (like `silentlyRefreshIfStale()`) needs
    /// somewhere to run before assertions read its effects. `FakeDataStore.refresh()` never
    /// suspends on real I/O, so a handful of yields is enough for it to complete — cheaper and
    /// less flaky than a fixed `Task.sleep`.
    private func drainMainActorQueue() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}
