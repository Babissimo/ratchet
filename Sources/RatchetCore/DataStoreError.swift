// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum DataStoreError: Error, CustomStringConvertible, Equatable {
    case notFound
    case underlying(String)

    /// Alerts interpolate the error directly, so without this the user would see the raw enum
    /// case name ("notFound") as the explanation.
    public var description: String {
        switch self {
        case .notFound:
            return "that item couldn't be found — try refreshing your projects & tasks"
        case .underlying(let message):
            return message
        }
    }

    public static func == (lhs: DataStoreError, rhs: DataStoreError) -> Bool {
        switch (lhs, rhs) {
        case (.notFound, .notFound): return true
        case (.underlying(let a), .underlying(let b)): return a == b
        default: return false
        }
    }
}
