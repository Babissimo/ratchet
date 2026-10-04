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

    // `URLSchemeHandler` decides with this which callback may end a sign-in.
    func test_state_readsThePercentEncodedStateWithOrWithoutACode() {
        XCTAssertEqual(OAuthCallbackParser.state(of: URL(string: "ratchet://callback?state=a%20b&code=x")!), "a b")
        XCTAssertEqual(OAuthCallbackParser.state(of: URL(string: "ratchet://callback?error=access_denied&state=xyz")!), "xyz")
        XCTAssertNil(OAuthCallbackParser.state(of: URL(string: "ratchet://callback?error=access_denied")!))
    }

    func test_makeAuthorizationRequest_startsAtTheSignInServiceWithAFreshStateAndChallenge() {
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: KeychainTokenStore(service: "unused-in-this-test"))
        let authenticator = FreeAgentAuthenticator(environment: .sandbox, apiClient: apiClient)

        let request1 = authenticator.makeAuthorizationRequest()
        let request2 = authenticator.makeAuthorizationRequest()

        let components = URLComponents(url: request1.url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.scheme, "https")
        XCTAssertEqual(components?.host, "auth.ratchet.babissimo.net")
        XCTAssertEqual(components?.path, "/sandbox/authorize")
        // The client ID and redirect URI are the sign-in service's to add.
        XCTAssertEqual(components?.queryItems, [
            URLQueryItem(name: "state", value: request1.state),
            URLQueryItem(name: "code_challenge", value: FreeAgentAuthenticator.codeChallenge(for: request1.codeVerifier)),
        ])
        // RFC 7636: 32 random bytes, base64url without padding.
        XCTAssertEqual(request1.codeVerifier.count, 43)
        XCTAssertNil(request1.codeVerifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(request1.state, request2.state)
        XCTAssertNotEqual(request1.codeVerifier, request2.codeVerifier)
    }

    func test_codeChallenge_matchesRFC7636AppendixB() {
        XCTAssertEqual(
            FreeAgentAuthenticator.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func test_handleCallback_throwsStateMismatchWhenStateDoesNotMatch() async {
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: KeychainTokenStore(service: "unused-in-this-test"))
        let authenticator = FreeAgentAuthenticator(environment: .sandbox, apiClient: apiClient)
        let callbackURL = URL(string: "ratchet://callback?code=abc&state=wrong")!

        do {
            _ = try await authenticator.handleCallback(url: callbackURL, for: Self.request(state: "expected"))
            XCTFail("expected FreeAgentError.stateMismatch")
        } catch FreeAgentError.stateMismatch {
            // expected
        } catch {
            XCTFail("expected FreeAgentError.stateMismatch, got \(error)")
        }
    }

    // Otherwise anything that can open a ratchet:// URL could cancel a sign-in or put words in its
    // failure alert.
    func test_handleCallback_checksStateBeforeReadingAnythingElse() async {
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: KeychainTokenStore(service: "unused-in-this-test"))
        let authenticator = FreeAgentAuthenticator(environment: .sandbox, apiClient: apiClient)
        let callbacks = [
            "ratchet://callback?error=access_denied",
            "ratchet://callback?error=server_error&error_description=Call%20us&state=wrong",
        ]

        for callback in callbacks {
            do {
                _ = try await authenticator.handleCallback(url: URL(string: callback)!, for: Self.request(state: "expected"))
                XCTFail("expected FreeAgentError.stateMismatch for \(callback)")
            } catch FreeAgentError.stateMismatch {
                // expected
            } catch {
                XCTFail("expected FreeAgentError.stateMismatch for \(callback), got \(error)")
            }
        }
    }

    func test_handleCallback_throwsAuthCancelledWhenTheUserDeclines() async {
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: KeychainTokenStore(service: "unused-in-this-test"))
        let authenticator = FreeAgentAuthenticator(environment: .sandbox, apiClient: apiClient)
        let callbackURL = URL(string: "ratchet://callback?error=access_denied&state=expected")!

        do {
            _ = try await authenticator.handleCallback(url: callbackURL, for: Self.request(state: "expected"))
            XCTFail("expected FreeAgentError.authCancelled")
        } catch FreeAgentError.authCancelled {
            // expected
        } catch {
            XCTFail("expected FreeAgentError.authCancelled, got \(error)")
        }
    }

    private static func request(state: String) -> AuthorizationRequest {
        AuthorizationRequest(url: URL(string: "https://auth.ratchet.babissimo.net/sandbox/authorize")!, state: state, codeVerifier: "v")
    }

    // Silent cancellation is only for a deliberate decline; these must reach the user.
    func test_handleCallback_throwsAuthRejectedForAnyOtherCodelessCallback() async {
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: KeychainTokenStore(service: "unused-in-this-test"))
        let authenticator = FreeAgentAuthenticator(environment: .sandbox, apiClient: apiClient)
        let cases: [(String, String)] = [
            ("ratchet://callback?error=server_error&error_description=Try%20later&state=expected", "Try later"),
            ("ratchet://callback?error=temporarily_unavailable&state=expected", "temporarily_unavailable"),
            ("ratchet://callback?state=expected", "no authorisation code came back"),
        ]

        for (callback, reason) in cases {
            do {
                _ = try await authenticator.handleCallback(url: URL(string: callback)!, for: Self.request(state: "expected"))
                XCTFail("expected FreeAgentError.authRejected for \(callback)")
            } catch FreeAgentError.authRejected(let actual) {
                XCTAssertEqual(actual, reason)
            } catch {
                XCTFail("expected FreeAgentError.authRejected for \(callback), got \(error)")
            }
        }
    }
}
