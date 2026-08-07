import XCTest
@testable import RatchetCore

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
}
