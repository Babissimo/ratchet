// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Adopted by errors that mean "the stored credentials are no longer usable" — i.e. the only
/// recovery is to throw the tokens away and log in again.
///
/// `RatchetCore` can't see `FreeAgentKit` (the dependency runs the other way), so this protocol
/// is how `StatusItemController` recognises `FreeAgentError.unauthorized` without importing it.
public protocol SessionExpiredError: Error {
    var isSessionExpired: Bool { get }
}

public extension Error {
    /// True when this error means the session is dead and the app should log itself out.
    var indicatesSessionExpired: Bool {
        (self as? SessionExpiredError)?.isSessionExpired == true
    }
}
