// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Security
@testable import FreeAgentKit

final class KeychainTokenStoreTests: XCTestCase {
    // Unique service per test run so parallel/repeated runs never collide
    // with a stale Keychain item from a previous run.
    private func makeStore() -> KeychainTokenStore {
        KeychainTokenStore(service: "com.ratchet.freeagent.test.\(UUID().uuidString)")
    }

    func test_load_returnsNilWhenNothingSaved() {
        let store = makeStore()
        XCTAssertNil(store.load())
    }

    func test_save_thenLoad_roundTrips() {
        let store = makeStore()
        let tokens = FreeAgentTokens(accessToken: "access", refreshToken: "refresh", expiresAt: Date(timeIntervalSinceNow: 3600))

        store.save(tokens)

        XCTAssertEqual(store.load(), tokens)
        store.clear()
    }

    func test_save_overwritesPreviousValue() {
        let store = makeStore()
        store.save(FreeAgentTokens(accessToken: "first", refreshToken: "r1", expiresAt: Date()))
        store.save(FreeAgentTokens(accessToken: "second", refreshToken: "r2", expiresAt: Date()))

        XCTAssertEqual(store.load()?.accessToken, "second")
        store.clear()
    }

    func test_clear_removesTheValue() {
        let store = makeStore()
        store.save(FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date()))

        store.clear()

        XCTAssertNil(store.load())
    }

    func test_isExpired_trueWithin60SecondsOfExpiry() {
        let almostExpired = FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: 30))
        let farFromExpiry = FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: 3600))

        XCTAssertTrue(almostExpired.isExpired)
        XCTAssertFalse(farFromExpiry.isExpired)
    }

    func test_loadResult_reportsMissingWhenNothingIsStored() {
        let store = makeStore()
        guard case .missing = store.loadResult() else {
            return XCTFail("an empty store should report .missing")
        }
    }

    func test_loadResult_reportsFoundAfterASave() {
        let store = makeStore()
        defer { store.clear() }
        let tokens = FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: 3600))
        XCTAssertTrue(store.save(tokens))
        guard case .found(let loaded) = store.loadResult() else {
            return XCTFail("expected .found")
        }
        XCTAssertEqual(loaded, tokens)
    }

    func test_credentialStoreUnavailableIsNotASessionExpiry() {
        // The whole point of the new case: a Keychain that can't be read says nothing about
        // whether the FreeAgent session is alive, and must never reach the code path that
        // deletes the stored refresh token.
        XCTAssertFalse(FreeAgentError.credentialStoreUnavailable(errSecInteractionNotAllowed).indicatesSessionExpired)
        XCTAssertTrue(FreeAgentError.unauthorized.indicatesSessionExpired)
    }
}
