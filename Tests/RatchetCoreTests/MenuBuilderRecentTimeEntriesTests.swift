import XCTest
import AppKit
@testable import RatchetCore

// Exercises @MainActor-isolated types (see DataStore's isolation), so the whole case is pinned
// to the main actor rather than annotating every test method.
@MainActor
final class MenuBuilderRecentTimeEntriesTests: XCTestCase {
    func test_excludesTheCurrentlyRunningEntry() {
        let dataStore = FakeDataStore.seeded()
        let stopped = RatchetTimeslip(
            id: "timeslip-stopped", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            date: Date(timeIntervalSince1970: 1_700_000_000), hours: 2.5
        )
        let running = RatchetTimeslip(
            id: "timeslip-running", clientId: "client-1", projectId: "proj-1", taskId: "task-2",
            date: Date(timeIntervalSince1970: 1_700_086_400), hours: 1.0
        )
        dataStore.seedTimeslips([stopped, running], runningId: running.id)

        let menu = MenuBuilder.buildRecentTimeEntriesSubmenu(dataStore: dataStore)

        // Only the stopped entry appears; the running one is excluded outright rather than shown
        // with its stale, paused-at duration.
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertTrue(menu.items[0].title.contains("Development"))
        XCTAssertFalse(menu.items.contains { $0.title.contains("Design") })
    }

    func test_noRunningEntry_showsAllRecentEntries() {
        let dataStore = FakeDataStore.seeded()
        let entry = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            date: Date(timeIntervalSince1970: 1_700_000_000), hours: 2.5
        )
        dataStore.seedTimeslips([entry])

        let menu = MenuBuilder.buildRecentTimeEntriesSubmenu(dataStore: dataStore)

        XCTAssertEqual(menu.items.count, 1)
        XCTAssertTrue(menu.items[0].title.contains("Development"))
    }
}
