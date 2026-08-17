import XCTest
@testable import RatchetCore

// Exercises @MainActor-isolated types (see DataStore's isolation), so the whole case is pinned
// to the main actor rather than annotating every test method.
@MainActor
final class FakeDataStoreTests: XCTestCase {
    func test_seeded_hasExpectedClientsAndAccountEmail() {
        let store = FakeDataStore.seeded()
        XCTAssertEqual(store.accountEmail, "al@example.com")
        XCTAssertEqual(store.clients.map(\.name), ["Acme", "Other Co"])
        XCTAssertEqual(store.clients[0].projects.map(\.name), ["Website Redesign", "Q3 Retainer"])
        XCTAssertEqual(store.clients[0].projects[0].tasks.map(\.name), ["Development", "Design"])
    }

    func test_addTask_appendsToMatchingProjectAndReturnsIt() async throws {
        let store = FakeDataStore.seeded()
        let clientId = store.clients[0].id
        let projectId = store.clients[0].projects[0].id

        let created = try await store.addTask(
            name: "QA", projectId: projectId, clientId: clientId,
            isBillable: true, status: .active, billingRate: nil, billingPeriod: nil
        )

        XCTAssertEqual(created.name, "QA")
        XCTAssertEqual(store.clients[0].projects[0].tasks.map(\.name), ["Development", "Design", "QA"])
    }

    func test_addTask_throwsNotFoundForUnknownProject() async {
        let store = FakeDataStore.seeded()
        do {
            _ = try await store.addTask(
                name: "QA", projectId: "nonexistent", clientId: store.clients[0].id,
                isBillable: true, status: .active, billingRate: nil, billingPeriod: nil
            )
            XCTFail("expected DataStoreError.notFound")
        } catch DataStoreError.notFound {
            // expected
        } catch {
            XCTFail("expected DataStoreError.notFound, got \(error)")
        }
    }

    func test_refresh_incrementsRefreshCount() async throws {
        let store = FakeDataStore.seeded()
        XCTAssertEqual(store.refreshCount, 0)
        try await store.refresh()
        XCTAssertEqual(store.refreshCount, 1)
    }

    func test_startTimer_thenStopTimer_returnsTheRunningTimeslip() async throws {
        let store = FakeDataStore.seeded()
        let clientId = store.clients[0].id
        let projectId = store.clients[0].projects[0].id
        let taskId = store.clients[0].projects[0].tasks[0].id

        let started = try await store.startTimer(taskId: taskId, projectId: projectId, clientId: clientId)
        XCTAssertEqual(started.taskId, taskId)

        let stopped = try await store.stopTimer()
        XCTAssertEqual(stopped?.id, started.id)

        let stoppedAgain = try await store.stopTimer()
        XCTAssertNil(stoppedAgain)
    }

    func test_startTimer_throwsNotFoundForUnknownTask() async {
        let store = FakeDataStore.seeded()
        do {
            _ = try await store.startTimer(taskId: "nonexistent", projectId: store.clients[0].projects[0].id, clientId: store.clients[0].id)
            XCTFail("expected DataStoreError.notFound")
        } catch DataStoreError.notFound {
            // expected
        } catch {
            XCTFail("expected DataStoreError.notFound, got \(error)")
        }
    }

    func test_updateTimeslip_replacesTheMatchingEntryInPlace() async throws {
        let clientId = "client-1"
        let originalProjectId = "proj-1"
        let originalTaskId = "task-1"
        let newProjectId = "proj-2"
        let newTaskId = "task-3"
        let original = RatchetTimeslip(
            id: "timeslip-1", clientId: clientId, projectId: originalProjectId, taskId: originalTaskId,
            date: Date(timeIntervalSince1970: 0), hours: 1, comment: "Original"
        )
        let store = FakeDataStore.seeded(timeslips: [original])

        let newDate = Date(timeIntervalSince1970: 86_400)
        let updated = try await store.updateTimeslip(
            id: "timeslip-1", taskId: newTaskId, projectId: newProjectId, clientId: clientId,
            date: newDate, hours: 2.5, comment: "Reassigned"
        )

        XCTAssertEqual(updated.id, "timeslip-1")
        XCTAssertEqual(updated.projectId, newProjectId)
        XCTAssertEqual(updated.taskId, newTaskId)
        XCTAssertEqual(updated.hours, 2.5)
        XCTAssertEqual(updated.comment, "Reassigned")
        // In place, not appended — the store still has exactly one timeslip afterwards.
        XCTAssertEqual(store.timeslips.count, 1)
        XCTAssertEqual(store.timeslips[0], updated)
    }

    func test_updateTimeslip_throwsNotFoundForUnknownId() async {
        let store = FakeDataStore.seeded()
        do {
            _ = try await store.updateTimeslip(
                id: "nonexistent", taskId: store.clients[0].projects[0].tasks[0].id,
                projectId: store.clients[0].projects[0].id, clientId: store.clients[0].id,
                date: Date(), hours: 1, comment: nil
            )
            XCTFail("expected DataStoreError.notFound")
        } catch DataStoreError.notFound {
            // expected
        } catch {
            XCTFail("expected DataStoreError.notFound, got \(error)")
        }
    }

    func test_updateTimeslip_throwsNotFoundForUnknownTask() async {
        let original = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            date: Date(), hours: 1, comment: nil
        )
        let store = FakeDataStore.seeded(timeslips: [original])
        do {
            _ = try await store.updateTimeslip(
                id: "timeslip-1", taskId: "nonexistent", projectId: "proj-1", clientId: "client-1",
                date: Date(), hours: 1, comment: nil
            )
            XCTFail("expected DataStoreError.notFound")
        } catch DataStoreError.notFound {
            // expected
        } catch {
            XCTFail("expected DataStoreError.notFound, got \(error)")
        }
    }
}
