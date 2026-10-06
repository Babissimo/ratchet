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

    /// Ratchet's sign-in service (`worker/`). FreeAgent registers only confidential OAuth clients,
    /// so the client credentials live there and the app ships none: sign-in starts at
    /// `authorizeURL` and every token request goes to `tokenURL`, where the service adds them.
    private static let signInServiceURL = URL(string: "https://auth.ratchet.babissimo.net")!

    public var authorizeURL: URL { Self.signInServiceURL.appendingPathComponent("\(signInServicePath)/authorize") }

    public var tokenURL: URL { Self.signInServiceURL.appendingPathComponent("\(signInServicePath)/token") }

    private var signInServicePath: String {
        switch self {
        case .sandbox: return "sandbox"
        case .production: return "production"
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
    /// Production, unless built with `-Xswiftc -DFREEAGENT_SANDBOX`.
    static var configured: FreeAgentEnvironment {
        #if FREEAGENT_SANDBOX
        return .sandbox
        #else
        return .production
        #endif
    }
}
