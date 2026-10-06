// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum DataStoreError: Error, CustomStringConvertible, Equatable {
    case notFound
    case underlying(String)
    /// `logTime` found the entry already in FreeAgent, from an earlier attempt whose outcome was
    /// unknown, and adopted it rather than logging it again.
    case alreadyLogged
    /// `logTime` can't tell whether FreeAgent logged the entry.
    case unconfirmed

    /// Alerts interpolate the error directly, so without this the user would see the raw enum
    /// case name ("notFound") as the explanation.
    public var description: String {
        switch self {
        case .notFound:
            return "that item couldn't be found — try refreshing your projects & tasks"
        case .underlying(let message):
            return message
        case .alreadyLogged:
            return "FreeAgent already had this entry from an earlier attempt, so Ratchet didn't log it again. Log it again if you meant to add a second."
        case .unconfirmed:
            return "FreeAgent didn't confirm this entry, so it may or may not be logged. Log the same entry again before quitting Ratchet, and it will check first rather than log it twice."
        }
    }
}
