// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum FreeAgentEnvironment {
    case sandbox
    case production

    public var apiBaseURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://api.sandbox.freeagent.com/v2")!
        case .production: return URL(string: "https://api.freeagent.com/v2")!
        }
    }

    public var authorizeURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://api.sandbox.freeagent.com/v2/approve_app")!
        case .production: return URL(string: "https://api.freeagent.com/v2/approve_app")!
        }
    }

    public var tokenURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://api.sandbox.freeagent.com/v2/token_endpoint")!
        case .production: return URL(string: "https://api.freeagent.com/v2/token_endpoint")!
        }
    }

    /// The web app URL for a specific company, e.g. "acebusiness" ->
    /// https://acebusiness.sandbox.freeagent.com — matches the subdomain FreeAgent itself
    /// redirects to during the OAuth authorize step. Production drops the "sandbox" segment
    /// entirely rather than swapping it for something else.
    public func webAppURL(subdomain: String) -> URL {
        switch self {
        case .sandbox: return URL(string: "https://\(subdomain).sandbox.freeagent.com")!
        case .production: return URL(string: "https://\(subdomain).freeagent.com")!
        }
    }
}

public extension FreeAgentEnvironment {
    /// The environment the compiled-in `FreeAgentSecrets.clientID`/`clientSecret` were registered
    /// against. Exposed here rather than making `FreeAgentSecrets` itself public, since callers
    /// outside this module need the environment but never the credentials.
    static var configured: FreeAgentEnvironment { FreeAgentSecrets.environment }
}
