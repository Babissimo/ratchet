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
}
