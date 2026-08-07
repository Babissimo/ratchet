import XCTest
import AppKit
@testable import RatchetCore

final class MenuBuilderIdleWithHistoryAndTrackingTests: XCTestCase {
    private let sampleTask = TrackedTaskRef(
        clientId: "client-1", clientName: "Acme",
        projectId: "proj-1", projectName: "Website Redesign",
        taskId: "task-1", taskName: "Development"
    )

    private func noopActions() -> MenuActions {
        MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, quit: {}
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
    }

    func test_idleWithHistory_topItemStartsTrackingTheMostRecentTask() {
        var started: TrackedTaskRef?
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { started = $0 }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, quit: {}
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
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[3].title, "Log past time")
        XCTAssertEqual(menu.items[4].title, "Recent time entries")
        XCTAssertTrue(menu.items[5].isSeparatorItem)
        XCTAssertEqual(menu.items[6].title, "Settings")
        XCTAssertEqual(menu.items[7].title, "Quit")
    }

    func test_tracking_stopItemInvokesStopTracking() {
        var stopped = false
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: { stopped = true },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, quit: {}
        )
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)

        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: actions)
        let stopItem = menu.items[1] as! ClosureMenuItem
        _ = stopItem.target?.perform(stopItem.action, with: stopItem)

        XCTAssertTrue(stopped)
    }
}
