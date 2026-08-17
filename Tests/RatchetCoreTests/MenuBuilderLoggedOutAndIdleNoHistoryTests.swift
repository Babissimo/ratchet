import XCTest
import AppKit
@testable import RatchetCore

// Exercises @MainActor-isolated types (see DataStore's isolation), so the whole case is pinned
// to the main actor rather than annotating every test method.
@MainActor
final class MenuBuilderLoggedOutAndIdleNoHistoryTests: XCTestCase {
    private func noopActions() -> MenuActions {
        MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {}, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, switchToNewTask: { _, _ in }, quit: {}
        )
    }

    func test_loggedOut_showsLogInThenSeparatorThenQuit() {
        let state = AppState()
        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: noopActions())

        XCTAssertEqual(menu.items.map(\.title), ["Log in with browser", "", "Quit"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertNotNil(menu.items[0].image)
    }

    func test_loggedOut_logInItemInvokesLogInAction() {
        var loggedIn = false
        let actions = MenuActions(
            logIn: { loggedIn = true }, logOut: {}, startTracking: { _ in }, stopTracking: {}, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, switchToNewTask: { _, _ in }, quit: {}
        )
        let menu = MenuBuilder.build(state: AppState(), dataStore: FakeDataStore.seeded(), actions: actions)

        let logInItem = menu.items[0] as! ClosureMenuItem
        _ = logInItem.target?.perform(logInItem.action, with: logInItem)

        XCTAssertTrue(loggedIn)
    }

    func test_idleNoHistory_showsOnlyStartAndFooter() {
        let state = AppState()
        state.logIn()
        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: noopActions())

        XCTAssertEqual(menu.items.map(\.title), ["Start timer", "", "Log past time", "Recent time entries", "", "Settings", "Quit"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertNotNil(menu.items[0].submenu)
        XCTAssertNotNil(menu.items[2].submenu)
        XCTAssertNotNil(menu.items[3].submenu)
        XCTAssertNotNil(menu.items[5].submenu)
        // The four high-traffic rows carry an SF Symbol; "Quit" deliberately doesn't (see
        // MenuBuilder.menuIcon's doc comment on not decorating every row).
        XCTAssertNotNil(menu.items[0].image)
        XCTAssertNotNil(menu.items[2].image)
        XCTAssertNotNil(menu.items[3].image)
        XCTAssertNotNil(menu.items[5].image)
        XCTAssertNil(menu.items[6].image)
    }
}
