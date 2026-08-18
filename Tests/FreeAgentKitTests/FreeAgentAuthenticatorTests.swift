// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import FreeAgentKit

// Exercises @MainActor-isolated types (see DataStore's isolation), so the whole case is pinned
// to the main actor rather than annotating every test method.
@MainActor
final class FreeAgentAuthenticatorTests: XCTestCase {
    func test_parse_extractsCodeAndState() {
        let url = URL(string: "ratchet://callback?code=abc123&state=xyz")!
        let result = OAuthCallbackParser.parse(url: url)
        XCTAssertEqual(result?.code, "abc123")
        XCTAssertEqual(result?.state, "xyz")
    }

    func test_parse_returnsNilWhenCodeMissing() {
        let url = URL(string: "ratchet://callback?state=xyz")!
        XCTAssertNil(OAuthCallbackParser.parse(url: url))
    }

    func test_parse_returnsNilWhenStateMissing() {
        let url = URL(string: "ratchet://callback?code=abc123")!
        XCTAssertNil(OAuthCallbackParser.parse(url: url))
    }

    func test_buildAuthorizeURL_includesRedirectURIAndGeneratesUniqueState() {
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: KeychainTokenStore(service: "unused-in-this-test"))
        let authenticator = FreeAgentAuthenticator(environment: .sandbox, apiClient: apiClient)

        let (url1, state1) = authenticator.buildAuthorizeURL()
        let (_, state2) = authenticator.buildAuthorizeURL()

        XCTAssertTrue(url1.absoluteString.contains("redirect_uri=ratchet://callback") || url1.absoluteString.contains("redirect_uri=ratchet%3A%2F%2Fcallback"))
        XCTAssertNotEqual(state1, state2)
    }

    func test_handleCallback_throwsStateMismatchWhenStateDoesNotMatch() async {
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: KeychainTokenStore(service: "unused-in-this-test"))
        let authenticator = FreeAgentAuthenticator(environment: .sandbox, apiClient: apiClient)
        let callbackURL = URL(string: "ratchet://callback?code=abc&state=wrong")!

        do {
            _ = try await authenticator.handleCallback(url: callbackURL, expectedState: "expected")
            XCTFail("expected FreeAgentError.stateMismatch")
        } catch FreeAgentError.stateMismatch {
            // expected
        } catch {
            XCTFail("expected FreeAgentError.stateMismatch, got \(error)")
        }
    }

    func test_handleCallback_throwsAuthCancelledWhenCodeMissing() async {
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: KeychainTokenStore(service: "unused-in-this-test"))
        let authenticator = FreeAgentAuthenticator(environment: .sandbox, apiClient: apiClient)
        let callbackURL = URL(string: "ratchet://callback?state=expected")!

        do {
            _ = try await authenticator.handleCallback(url: callbackURL, expectedState: "expected")
            XCTFail("expected FreeAgentError.authCancelled")
        } catch FreeAgentError.authCancelled {
            // expected
        } catch {
            XCTFail("expected FreeAgentError.authCancelled, got \(error)")
        }
    }
}
