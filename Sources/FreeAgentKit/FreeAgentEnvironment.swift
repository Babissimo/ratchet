import Foundation

public enum FreeAgentEnvironment {
    case sandbox

    public var apiBaseURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://api.sandbox.freeagent.com/v2")!
        }
    }

    public var authorizeURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://api.sandbox.freeagent.com/v2/approve_app")!
        }
    }

    public var tokenURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://api.sandbox.freeagent.com/v2/token_endpoint")!
        }
    }

    /// The web app URL for a specific company, e.g. "acebusiness" ->
    /// https://acebusiness.sandbox.freeagent.com — matches the subdomain FreeAgent itself
    /// redirects to during the OAuth authorize step.
    public func webAppURL(subdomain: String) -> URL {
        switch self {
        case .sandbox: return URL(string: "https://\(subdomain).sandbox.freeagent.com")!
        }
    }
}
