// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RatchetCore

@MainActor
final class SwitchTaskTests: XCTestCase {
    /// The regression: "Switch task" sent the whole timeslip record back with the `hours` it
    /// had cached at the last refresh, so anything the server had accrued since (a pause and
    /// resume from the web app) was asserted away.
    func test_switchTask_sendsTheServersHoursNotTheCachedOnes() async throws {
        let store = FakeDataStore.seeded()
        let day = CalendarDay.day(from: "2026-08-19")!
        let stale = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            day: day, timerStartedAt: day.addingTimeInterval(9 * 3600), hours: 2.0
        )
        store.seedTimeslips([stale], runningId: "timeslip-1")
        // The server has moved on: the same timeslip now stands at 5 hours.
        store.serverRunningOverride = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            day: day, timerStartedAt: day.addingTimeInterval(9 * 3600), hours: 5.0
        )

        let running = try await store.runningTimeslip()
        XCTAssertEqual(running?.hours, 5.0)
        _ = try await store.updateTimeslip(
            id: running!.id, taskId: "task-2", projectId: "proj-1", clientId: "client-1",
            date: running!.day, hours: running!.hours, comment: running!.comment
        )
        XCTAssertEqual(store.timeslips.first { $0.id == "timeslip-1" }?.hours, 5.0)
    }
}
