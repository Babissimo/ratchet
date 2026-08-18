import XCTest
import AppKit
@testable import RatchetCore

// Exercises @MainActor-isolated types (see DataStore's isolation), so the whole case is pinned
// to the main actor rather than annotating every test method.
@MainActor
final class MenuBuilderSettingsSubmenuTests: XCTestCase {
    private func noopActions() -> MenuActions {
        MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {}, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
        )
    }

    func test_layout_matchesSpecOrder() {
        let state = AppState()
        let menu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: state, actions: noopActions())

        // The refresh row's `.title` isn't the plain "Refresh projects & tasks" — assigning
        // `attributedTitle` (its two-line "title\nsubtitle" display) rewrites `.title` to that
        // string's full contents, which is why `StatusItemController` looks this row up by `.tag`
        // (`MenuBuilder.refreshItemTag`) rather than by title.
        XCTAssertEqual(menu.items.map(\.title), [
            "al@example.com",
            "Refresh projects & tasks\nNever refreshed",
            "Launch at login",
            "",
            "Open FreeAgent",
            "",
            "Log out",
        ])
        XCTAssertEqual(menu.items[1].tag, MenuBuilder.refreshItemTag)
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        XCTAssertTrue(menu.items[5].isSeparatorItem)
        // Icons are reserved for Start/Stop tracking on the main menu; nothing in Settings
        // carries one.
        XCTAssertNil(menu.items[0].image)
        XCTAssertNil(menu.items[1].image)
        XCTAssertNil(menu.items[2].image)
        XCTAssertNil(menu.items[4].image)
        XCTAssertNil(menu.items[6].image)
    }

    func test_refreshItem_showsNeverRefreshedByDefault() {
        let menu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: AppState(), actions: noopActions())
        XCTAssertEqual(menu.items[1].attributedTitle?.string, "Refresh projects & tasks\nNever refreshed")
    }

    func test_refreshItem_showsLastRefreshedTimestampAfterRefresh() async throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        let store = FakeDataStore(clients: [], accountEmail: "al@example.com", clock: { fixedDate })
        try await store.refresh()

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
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {}, switchTask: { _ in },
            refresh: { refreshed = true }, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
        )
        let menu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: AppState(), actions: actions)
        let refreshItem = menu.items[1] as! ClosureMenuItem
        _ = refreshItem.target?.perform(refreshItem.action, with: refreshItem)
        XCTAssertTrue(refreshed)
    }

    func test_logOutItem_invokesLogOutAction() {
        var loggedOut = false
        let actions = MenuActions(
            logIn: {}, logOut: { loggedOut = true }, startTracking: { _ in }, stopTracking: {}, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
        )
        let menu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: AppState(), actions: actions)
        let logOutItem = menu.items[6] as! ClosureMenuItem
        _ = logOutItem.target?.perform(logOutItem.action, with: logOutItem)
        XCTAssertTrue(loggedOut)
    }
}
