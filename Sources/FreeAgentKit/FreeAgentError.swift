// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RatchetCore

public enum FreeAgentError: Error, CustomStringConvertible {
    case network(Error)
    case unauthorized
    case decoding(Error)
    case apiError(status: Int, message: String?)
    case authCancelled
    case authTimedOut
    case stateMismatch
    case credentialStorageFailed
    case credentialStoreUnavailable(OSStatus)
    case invalidURL(String)

    public var description: String {
        switch self {
        case .network(let error):
            return "network error (\(error.localizedDescription))"
        case .unauthorized:
            return "session expired, please log in again"
        case .decoding(let error):
            return "couldn't understand FreeAgent's response (\(error.localizedDescription))"
        case .apiError(let status, let message):
            return message ?? "FreeAgent returned an error (status \(status))"
        case .authCancelled:
            return "login was cancelled"
        case .authTimedOut:
            return "login timed out — please try again"
        case .stateMismatch:
            return "login response didn't match the request (possible tampering) — please try again"
        case .credentialStorageFailed:
            return "couldn't save your FreeAgent login to the Keychain — you may be asked to log in again next time Ratchet starts"
        case .credentialStoreUnavailable(let status):
            return "couldn't read your FreeAgent login from the Keychain (status \(status)) — this is usually temporary; try again in a moment"
        case .invalidURL(let path):
            return "FreeAgent returned an address Ratchet couldn't use (\"\(path)\")"
        }
    }
}

extension FreeAgentError: SessionExpiredError {
    /// `.unauthorized` is thrown both when no tokens are stored and when FreeAgent rejects the
    /// refresh token (revoked, or already rotated away). Either way the stored credentials are
    /// dead and the app must drop them and send the user back through login.
    ///
    /// `.credentialStoreUnavailable` deliberately does *not* qualify: a Keychain that can't be
    /// read says nothing about whether FreeAgent still accepts the session, and treating it as
    /// an expiry deleted valid credentials.
    public var isSessionExpired: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}
