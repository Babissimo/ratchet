import XCTest
@testable import RatchetCore

@MainActor
final class FakeDataStoreErrorInjectionTests: XCTestCase {
    func test_refresh_throwsInjectedError() async {
        let dataStore = FakeDataStore.seeded()
        dataStore.refreshError = FakeSessionExpiredError()

        do {
            try await dataStore.refresh()
            XCTFail("expected refresh() to throw the injected error")
        } catch {
            XCTAssertTrue(error.indicatesSessionExpired)
        }
        XCTAssertEqual(dataStore.refreshCount, 0, "a thrown refresh() must not count as a completed refresh")
    }

    func test_refresh_withoutInjectedError_succeedsAsBefore() async throws {
        let dataStore = FakeDataStore.seeded()
        try await dataStore.refresh()
        XCTAssertEqual(dataStore.refreshCount, 1)
        XCTAssertNotNil(dataStore.lastRefreshedAt)
    }
}
