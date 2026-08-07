import XCTest
import AppKit
@testable import RatchetCore

final class MenuBuilderSettingsSubmenuTests: XCTestCase {
    private func noopActions() -> MenuActions {
        MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, quit: {}
        )
    }

    func test_layout_matchesSpecOrder() {
        let state = AppState()
        let menu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: state, actions: noopActions())

        XCTAssertEqual(menu.items.map(\.title), [
            "al@example.com",
            "Refresh projects & tasks",
            "Launch at login",
            "",
            "Open FreeAgent",
            "",
            "Log out",
        ])
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        XCTAssertTrue(menu.items[5].isSeparatorItem)
    }

    func test_refreshItem_showsNeverRefreshedByDefault() {
        let menu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: AppState(), actions: noopActions())
        XCTAssertEqual(menu.items[1].attributedTitle?.string, "Refresh projects & tasks\nNever refreshed")
    }

    func test_refreshItem_showsLastRefreshedTimestampAfterRefresh() {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        let store = FakeDataStore(clients: [], accountEmail: "al@example.com", clock: { fixedDate })
        store.refresh()

        let menu = MenuBuilder.buildSettingsSubmenu(dataStore: store, state: AppState(), actions: noopActions())

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm 'on' yyyy-MM-dd"
        let expectedSubtitle = "Last refreshed at \(formatter.string(from: fixedDate))"
        XCTAssertEqual(menu.items[1].attributedTitle?.string, "Refresh projects & tasks\n\(expectedSubtitle)")
    }

    func test_launchAtLoginCheckmark_reflectsState() {
        let offState = AppState()
        let offMenu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: offState, actions: noopActions())
        XCTAssertEqual(offMenu.items[2].state, .off)

        let onState = AppState()
        onState.setLaunchAtLogin(true)
        let onMenu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: onState, actions: noopActions())
        XCTAssertEqual(onMenu.items[2].state, .on)
    }

    func test_refreshItem_invokesRefreshAction() {
        var refreshed = false
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {},
            refresh: { refreshed = true }, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, quit: {}
        )
        let menu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: AppState(), actions: actions)
        let refreshItem = menu.items[1] as! ClosureMenuItem
        _ = refreshItem.target?.perform(refreshItem.action, with: refreshItem)
        XCTAssertTrue(refreshed)
    }

    func test_logOutItem_invokesLogOutAction() {
        var loggedOut = false
        let actions = MenuActions(
            logIn: {}, logOut: { loggedOut = true }, startTracking: { _ in }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, quit: {}
        )
        let menu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: AppState(), actions: actions)
        let logOutItem = menu.items[6] as! ClosureMenuItem
        _ = logOutItem.target?.perform(logOutItem.action, with: logOutItem)
        XCTAssertTrue(loggedOut)
    }
}
