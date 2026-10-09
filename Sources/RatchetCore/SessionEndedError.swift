// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Adopted by errors thrown to work a session left unfinished, once logging out has ended it.
/// Those get no alert: the user has left that session, and whoever is signed in now may be another
/// account.
///
/// Recognised through a protocol for the same reason as `SessionExpiredError`: `RatchetCore`
/// can't see `FreeAgentKit`.
public protocol SessionEndedError: Error {
    var isSessionEnded: Bool { get }
}

public extension Error {
    var indicatesSessionEnded: Bool {
        (self as? SessionEndedError)?.isSessionEnded == true
    }
}
