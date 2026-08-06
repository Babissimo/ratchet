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
            addTask: { _, _ in }, quit: {}
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
            "Acme · Website Redesign",
            "Start", "", "Settings", "Quit",
        ])
        XCTAssertFalse(menu.items[1].isEnabled)
    }

    func test_idleWithHistory_topItemStartsTrackingTheMostRecentTask() {
        var started: TrackedTaskRef?
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { started = $0 }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
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

        XCTAssertEqual(menu.items[0].title, "Development")
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertEqual(menu.items[1].title, "Acme · Website Redesign")
        XCTAssertFalse(menu.items[1].isEnabled)
        XCTAssertEqual(menu.items[2].title, "1:47") // elapsed time line
        XCTAssertFalse(menu.items[2].isEnabled)
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        XCTAssertEqual(menu.items[4].title, "Stop tracking")
        XCTAssertTrue(menu.items[5].isSeparatorItem)
        XCTAssertEqual(menu.items[6].title, "Settings")
        XCTAssertEqual(menu.items[7].title, "Quit")
    }

    func test_tracking_stopItemInvokesStopTracking() {
        var stopped = false
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: { stopped = true },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
        )
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)

        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: actions)
        let stopItem = menu.items[4] as! ClosureMenuItem
        _ = stopItem.target?.perform(stopItem.action, with: stopItem)

        XCTAssertTrue(stopped)
    }
}
