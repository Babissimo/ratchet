import Foundation

/// `Sendable` because the shared token-refresh `Task` in `FreeAgentAPIClient` hands its result
/// back across an actor boundary — trivially safe, since every stored property is immutable.
public struct FreeAgentTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// True once within 60 seconds of expiry (or past it) — leaves headroom
    /// so a request built "now" doesn't land as expired mid-flight.
    public var isExpired: Bool {
        expiresAt.timeIntervalSinceNow < 60
    }
}
