// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

public struct OAuthCallbackResult {
    public let code: String
    public let state: String
}

public enum OAuthCallbackParser {
    /// Parses "ratchet://callback?code=...&state=..." — returns nil if the
    /// URL isn't a well-formed callback (missing code or state).
    public static func parse(url: URL) -> OAuthCallbackResult? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let code = queryItems.first(where: { $0.name == "code" })?.value,
              let state = queryItems.first(where: { $0.name == "state" })?.value
        else { return nil }
        return OAuthCallbackResult(code: code, state: state)
    }

    /// The callback's `state`. Nothing else in a callback is read until it matches the sign-in
    /// waiting for it.
    public static func state(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
    }
}

/// One sign-in attempt: the page to open, and what its callback and code exchange must carry.
public struct AuthorizationRequest {
    public let url: URL
    public let state: String
    /// The secret behind the `code_challenge` in `url`. The sign-in service seals the tokens to that
    /// challenge and hands them over only for this, so an app that intercepts the `ratchet://`
    /// callback can't use what it gets.
    let codeVerifier: String
}

public final class FreeAgentAuthenticator {
    /// Where the sign-in service sends the browser once FreeAgent has answered (`APP_CALLBACK` in
    /// `worker/src/index.js`).
    public static let callbackURL = "ratchet://callback"

    private let environment: FreeAgentEnvironment
    private let apiClient: FreeAgentAPIClient

    public init(environment: FreeAgentEnvironment, apiClient: FreeAgentAPIClient) {
        self.environment = environment
        self.apiClient = apiClient
    }

    /// Starts a sign-in attempt with a fresh CSRF nonce and code verifier.
    ///
    /// Non-throwing, unlike the request paths in `FreeAgentAPIClient`: every input here is a
    /// compile-time constant — `environment.authorizeURL` is built from a URL literal in
    /// `FreeAgentEnvironment`, and `URLQueryItem` percent-encodes the values — so failure would
    /// mean the literal itself is malformed, which is a programming error rather than anything
    /// a user or FreeAgent can provoke. `preconditionFailure` states that invariant instead of
    /// pushing an impossible error case onto the caller.
    public func makeAuthorizationRequest() -> AuthorizationRequest {
        let state = UUID().uuidString
        let codeVerifier = Self.base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        guard var components = URLComponents(url: environment.authorizeURL, resolvingAgainstBaseURL: false) else {
            preconditionFailure("FreeAgentEnvironment.authorizeURL is not a valid URL: \(environment.authorizeURL)")
        }
        // The sign-in service adds the client ID and redirect URI on its way to FreeAgent.
        components.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: codeVerifier)),
        ]
        guard let url = components.url else {
            preconditionFailure("authorize URL query could not be encoded: \(components)")
        }
        return AuthorizationRequest(url: url, state: state, codeVerifier: codeVerifier)
    }

    /// Validates the callback URL against `request`, then exchanges the code for tokens.
    public func handleCallback(url: URL, for request: AuthorizationRequest) async throws -> FreeAgentTokens {
        guard OAuthCallbackParser.state(of: url) == request.state else {
            throw FreeAgentError.stateMismatch
        }
        guard let result = OAuthCallbackParser.parse(url: url) else {
            throw Self.callbackFailure(url)
        }
        return try await apiClient.exchangeAuthorizationCode(result.code, codeVerifier: request.codeVerifier)
    }

    /// RFC 7636's S256 method.
    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A callback without a code is the user's own choice only when FreeAgent says they declined;
    /// anything else is a failure they need to see.
    private static func callbackFailure(_ url: URL) -> FreeAgentError {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let error = items.first { $0.name == "error" }?.value
        if error == "access_denied" { return .authCancelled }
        let description = items.first { $0.name == "error_description" }?.value
        return .authRejected(description ?? error ?? "no authorisation code came back")
    }
}
