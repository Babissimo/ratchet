// SPDX-License-Identifier: GPL-3.0-or-later
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
}

public final class FreeAgentAuthenticator {
    public static let redirectURI = "ratchet://callback"

    private let environment: FreeAgentEnvironment
    private let apiClient: FreeAgentAPIClient

    public init(environment: FreeAgentEnvironment, apiClient: FreeAgentAPIClient) {
        self.environment = environment
        self.apiClient = apiClient
    }

    /// Builds the browser URL to open, and the CSRF nonce the eventual
    /// callback's `state` must match.
    ///
    /// Non-throwing, unlike the request paths in `FreeAgentAPIClient`: every input here is a
    /// compile-time constant — `environment.authorizeURL` is a URL literal in
    /// `FreeAgentEnvironment`, and `URLQueryItem` percent-encodes the values — so failure would
    /// mean the literal itself is malformed, which is a programming error rather than anything
    /// a user or FreeAgent can provoke. `preconditionFailure` states that invariant instead of
    /// pushing an impossible error case onto the caller.
    public func buildAuthorizeURL() -> (url: URL, state: String) {
        let state = UUID().uuidString
        guard var components = URLComponents(url: environment.authorizeURL, resolvingAgainstBaseURL: false) else {
            preconditionFailure("FreeAgentEnvironment.authorizeURL is not a valid URL: \(environment.authorizeURL)")
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: FreeAgentSecrets.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            preconditionFailure("authorize URL query could not be encoded: \(components)")
        }
        return (url, state)
    }

    /// Validates the callback URL against the nonce from `buildAuthorizeURL`, then exchanges the
    /// code for tokens.
    ///
    /// PKCE (RFC 7636) was tried here and reverted — live-tested against FreeAgent's sandbox,
    /// dropping the client secret entirely got `invalid_grant` on every token exchange. FreeAgent's
    /// OAuth app registration is a confidential-client type; it doesn't recognize
    /// `code_challenge`/`code_verifier` and still requires `Authorization: Basic` with the secret.
    /// See `FreeAgentAPIClient.exchangeAuthorizationCode`.
    public func handleCallback(url: URL, expectedState: String) async throws -> FreeAgentTokens {
        guard let result = OAuthCallbackParser.parse(url: url) else {
            throw FreeAgentError.authCancelled
        }
        guard result.state == expectedState else {
            throw FreeAgentError.stateMismatch
        }
        return try await apiClient.exchangeAuthorizationCode(result.code, redirectURI: Self.redirectURI)
    }
}
