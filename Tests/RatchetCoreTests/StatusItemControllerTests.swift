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
