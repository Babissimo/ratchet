import Foundation

public enum DataStoreError: Error, Equatable {
    case notFound
    case underlying(String)

    public static func == (lhs: DataStoreError, rhs: DataStoreError) -> Bool {
        switch (lhs, rhs) {
        case (.notFound, .notFound): return true
        case (.underlying(let a), .underlying(let b)): return a == b
        default: return false
        }
    }
}
