// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum DataStoreError: Error, CustomStringConvertible, Equatable {
    /// What a create makes, so an error about it can say so.
    public enum Resource: String {
        case timeslip, client, project, task
    }

    case notFound
    case underlying(String)
    /// `logTime` found the entry already in FreeAgent, from an earlier attempt whose outcome was
    /// unknown, and adopted it rather than logging it again.
    case alreadyLogged
    /// A create FreeAgent may or may not have applied. The same create made again before Ratchet
    /// quits looks for the earlier attempt's result before posting.
    case unconfirmed(Resource)

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
        case .unconfirmed(.timeslip):
            return "FreeAgent didn't confirm this entry, so it may or may not be logged. Log the same entry again before quitting Ratchet, and it will check first rather than log it twice."
        case .unconfirmed(let resource):
            let noun = resource.rawValue
            return "FreeAgent didn't confirm the new \(noun), so it may or may not have been created. Create it again under the same name before quitting Ratchet: if FreeAgent did create it, Ratchet will use that \(noun) rather than make a second."
        }
    }
}
