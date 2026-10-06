// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Adopted by errors that mean the user ended sign-in themselves, by declining on FreeAgent's page.
/// Those get no failure alert.
///
/// Recognised through a protocol for the same reason as `SessionExpiredError`: `RatchetCore`
/// can't see `FreeAgentKit`.
public protocol LoginCancelledError: Error {
    var isLoginCancelled: Bool { get }
}

public extension Error {
    var indicatesLoginCancelled: Bool {
        (self as? LoginCancelledError)?.isLoginCancelled == true
    }
}
