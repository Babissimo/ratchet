import XCTest
import AppKit
@testable import RatchetCore

final class MenuBuilderLoggedOutAndIdleNoHistoryTests: XCTestCase {
    private func noopActions() -> MenuActions {
        MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
        )
    }

    func test_loggedOut_showsLogInThenSeparatorThenQuit() {
        let state = AppState()
        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: noopActions())

        XCTAssertEqual(menu.items.map(\.title), ["Log in with browser", "", "Quit"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
    }

    func test_loggedOut_logInItemInvokesLogInAction() {
        var loggedIn = false
        let actions = MenuActions(
            logIn: { loggedIn = true }, logOut: {}, startTracking: { _ in }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
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

        XCTAssertEqual(menu.items.map(\.title), ["Start", "", "Settings", "Quit"])
        XCTAssertNotNil(menu.items[0].submenu)
        XCTAssertNotNil(menu.items[2].submenu)
    }
}
