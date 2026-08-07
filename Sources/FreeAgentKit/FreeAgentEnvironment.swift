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
}
