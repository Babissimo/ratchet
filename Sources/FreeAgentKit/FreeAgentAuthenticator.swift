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
    public func buildAuthorizeURL() -> (url: URL, state: String) {
        let state = UUID().uuidString
        var components = URLComponents(url: environment.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: FreeAgentSecrets.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        return (components.url!, state)
    }

    /// Validates the callback URL against the nonce from `buildAuthorizeURL`,
    /// then exchanges the code for tokens.
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
