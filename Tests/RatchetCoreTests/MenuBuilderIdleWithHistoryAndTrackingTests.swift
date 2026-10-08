// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import AppKit
@testable import RatchetCore

// Exercises @MainActor-isolated types (see DataStore's isolation), so the whole case is pinned
// to the main actor rather than annotating every test method.
@MainActor
final class MenuBuilderIdleWithHistoryAndTrackingTests: XCTestCase {
    private let sampleTask = TrackedTaskRef(
        clientId: "client-1", clientName: "Acme",
        projectId: "proj-1", projectName: "Website Redesign",
        taskId: "task-1", taskName: "Development"
    )

    private func noopActions() -> MenuActions {
        MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {}, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {}, sendFeedback: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in },
            switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
        )
    }

    func test_idleWithHistory_showsStartTrackingHeaderAndSubtitle() {
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)
        state.stopTracking()

        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: noopActions())

        XCTAssertEqual(menu.items.map(\.title), [
            "Start tracking Development",
            "Start timer", "", "Log past time", "Recent time entries", "", "Settings", "Quit",
        ])
        // Client/project context is coupled into the same row via attributedTitle, not a
        // separate menu item — the plain .title is the fallback string, the two-line
        // rendering lives in .attributedTitle.
        XCTAssertEqual(menu.items[0].attributedTitle?.string, "Start tracking Development\nAcme · Website Redesign")
        XCTAssertNotNil(menu.items[0].image)
    }

    func test_idleWithHistory_topItemStartsTrackingTheMostRecentTask() {
        var started: TrackedTaskRef?
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { started = $0 }, stopTracking: {}, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {}, sendFeedback: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in },
            switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
        )
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)
        state.stopTracking()

        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: actions)
        let topItem = menu.items[0] as! ClosureMenuItem
        _ = topItem.target?.perform(topItem.action, with: topItem)

        XCTAssertEqual(started, sampleTask)
    }

    func test_tracking_showsTaskSubtitleElapsedAndStop() {
        let fixedStart = Date(timeIntervalSince1970: 0)
        let state = AppState(clock: { fixedStart })
        state.logIn()
        state.startTracking(sampleTask)

        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: noopActions(), now: { Date(timeIntervalSince1970: 6420) })

        XCTAssertEqual(menu.items[0].title, "1:47") // elapsed time line, on top per user request
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertEqual(menu.items[1].title, "Stop tracking Development")
        // Client/project context is coupled into the same row via attributedTitle, matching
        // the "Start tracking" row's treatment.
        XCTAssertEqual(menu.items[1].attributedTitle?.string, "Stop tracking Development\nAcme · Website Redesign")
        XCTAssertNotNil(menu.items[1].image) // stop tracking
        XCTAssertEqual(menu.items[2].title, "Switch task")
        XCTAssertNotNil(menu.items[2].submenu)
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        XCTAssertEqual(menu.items[4].title, "Log past time")
        XCTAssertEqual(menu.items[5].title, "Recent time entries")
        XCTAssertTrue(menu.items[6].isSeparatorItem)
        XCTAssertEqual(menu.items[7].title, "Settings")
        XCTAssertEqual(menu.items[8].title, "Quit")
        XCTAssertNil(menu.items[4].image) // log past time stays unadorned
        XCTAssertNil(menu.items[5].image) // recent time entries stays unadorned
        XCTAssertNil(menu.items[7].image) // settings stays unadorned
        XCTAssertNil(menu.items[8].image) // quit stays unadorned
    }

    func test_tracking_switchTaskSubmenuMirrorsClientProjectTaskTree() {
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)

        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: noopActions())
        let switchSubmenu = menu.items[2].submenu!

        // Same shape as "Start timer"/"Log past time": one item per client, plus "Add client…".
        XCTAssertTrue(switchSubmenu.items.contains { $0.title == "Add client…" })
        let clientItem = switchSubmenu.items.first { $0.title == "Acme" }
        XCTAssertNotNil(clientItem?.submenu)
        let projectItem = clientItem?.submenu?.items.first { $0.title == "Website Redesign" }
        XCTAssertNotNil(projectItem?.submenu)
        // The currently-tracked task (Development, per `sampleTask`) is excluded — switching to
        // the task that's already running would just stop and immediately re-resume it.
        XCTAssertFalse(projectItem?.submenu?.items.contains { $0.title == "Development" } ?? true)
        XCTAssertTrue(projectItem?.submenu?.items.contains { $0.title == "Design" } ?? false)
        XCTAssertTrue(projectItem?.submenu?.items.contains { $0.title == "New task…" } ?? false)
    }

    func test_tracking_switchTaskLeafStopsCurrentAndSwitchesToPickedTask() {
        var switchedTo: TrackedTaskRef?
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {}, switchTask: { switchedTo = $0 },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {}, sendFeedback: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in },
            switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
        )
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)

        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: actions)
        let switchSubmenu = menu.items[2].submenu!
        let clientItem = switchSubmenu.items.first { $0.title == "Acme" }!
        let projectItem = clientItem.submenu!.items.first { $0.title == "Website Redesign" }!
        // "Development" (the currently-tracked task, per `sampleTask`) is excluded from this
        // submenu, so switch to the other task in the same project instead.
        let taskItem = projectItem.submenu!.items.first { $0.title == "Design" } as! ClosureMenuItem
        _ = taskItem.target?.perform(taskItem.action, with: taskItem)

        XCTAssertEqual(switchedTo, TrackedTaskRef(
            clientId: "client-1", clientName: "Acme",
            projectId: "proj-1", projectName: "Website Redesign",
            taskId: "task-2", taskName: "Design"
        ))
    }

    func test_tracking_stopItemInvokesStopTracking() {
        var stopped = false
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: { stopped = true }, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {}, sendFeedback: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in },
            switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
        )
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)

        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: actions)
        let stopItem = menu.items[1] as! ClosureMenuItem
        _ = stopItem.target?.perform(stopItem.action, with: stopItem)

        XCTAssertTrue(stopped)
    }

    // MARK: - The day a running timer books to

    // Mid-August dates, clear of daylight-saving changes, so local hours add up exactly.

    func test_tracking_timerBookedToday_showsElapsedTimeAlone() {
        let today = day("2026-08-13")
        let menu = trackingMenu(bookedOn: today, startedAt: at(9, on: today), now: at(10.5, on: today))

        XCTAssertEqual(menu.items[0].title, "1:30")
    }

    func test_tracking_timerBookedYesterday_saysSo() {
        let yesterday = day("2026-08-12")
        let menu = trackingMenu(bookedOn: yesterday, startedAt: at(17, on: yesterday), now: at(9, on: day("2026-08-13")))

        XCTAssertEqual(menu.items[0].title, "16:00 · booked to yesterday")
        XCTAssertFalse(menu.items[0].isEnabled)
    }

    func test_tracking_timerBookedEarlierThisWeek_namesTheWeekday() {
        let monday = day("2026-08-10")
        let menu = trackingMenu(bookedOn: monday, startedAt: at(9, on: monday), now: at(9, on: day("2026-08-13")))

        XCTAssertEqual(menu.items[0].title, "72:00 · booked to Monday")
    }

    func test_tracking_timerBookedOverAWeekAgo_givesTheDate() {
        let booked = day("2026-08-03")
        let menu = trackingMenu(bookedOn: booked, startedAt: at(9, on: booked), now: at(9, on: day("2026-08-13")))

        XCTAssertEqual(menu.items[0].title, "240:00 · booked to \(CalendarDay.displayString(from: booked))")
    }

    /// FreeAgent can resume a timer on an older timeslip, and the hours then go to that
    /// timeslip's day however recently the timer started.
    func test_tracking_timerResumedTodayOnYesterdaysTimeslip_saysYesterday() {
        let today = day("2026-08-13")
        let menu = trackingMenu(bookedOn: day("2026-08-12"), startedAt: at(9, on: today), now: at(10, on: today))

        XCTAssertEqual(menu.items[0].title, "1:00 · booked to yesterday")
    }

    /// The tracking menu for `sampleTask`, whose timer runs on a timeslip dated `bookedDay`.
    private func trackingMenu(bookedOn bookedDay: Date, startedAt: Date, now: Date) -> NSMenu {
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask, startedAt: startedAt)
        let running = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            day: bookedDay, timerStartedAt: startedAt, hours: 0
        )
        let store = FakeDataStore.seeded()
        store.seedTimeslips([running], runningId: running.id)
        return MenuBuilder.build(state: state, dataStore: store, actions: noopActions(), now: { now })
    }

    private func day(_ text: String) -> Date {
        CalendarDay.day(from: text)!
    }

    private func at(_ hours: Double, on day: Date) -> Date {
        day.addingTimeInterval(hours * 3600)
    }
}
