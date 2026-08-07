import Foundation

public struct FreeAgentTokens: Codable, Equatable {
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
