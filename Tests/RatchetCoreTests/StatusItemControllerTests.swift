import XCTest
import AppKit
@testable import RatchetCore

final class StatusItemControllerTests: XCTestCase {
    func test_construction_setsInitialMenuOnStatusItem() {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)

        XCTAssertNotNil(controller.statusItemForTesting.menu)
        XCTAssertEqual(controller.statusItemForTesting.menu?.items.first?.title, "Log in with browser")
    }

    func test_stateChange_rebuildsMenu() {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)

        appState.logIn()

        XCTAssertEqual(controller.statusItemForTesting.menu?.items.first?.title, "Start")
    }
}
