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

    func test_addTask_appendsToMatchingProjectAndReturnsIt() {
        let store = FakeDataStore.seeded()
        let clientId = store.clients[0].id
        let projectId = store.clients[0].projects[0].id

        let created = store.addTask(name: "QA", projectId: projectId, clientId: clientId)

        XCTAssertEqual(created?.name, "QA")
        XCTAssertEqual(store.clients[0].projects[0].tasks.map(\.name), ["Development", "Design", "QA"])
    }

    func test_addTask_returnsNilForUnknownProject() {
        let store = FakeDataStore.seeded()
        let result = store.addTask(name: "QA", projectId: "nonexistent", clientId: store.clients[0].id)
        XCTAssertNil(result)
    }

    func test_refresh_incrementsRefreshCount() {
        let store = FakeDataStore.seeded()
        XCTAssertEqual(store.refreshCount, 0)
        store.refresh()
        XCTAssertEqual(store.refreshCount, 1)
    }
}
