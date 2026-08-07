import Foundation

public enum FreeAgentError: Error, CustomStringConvertible {
    case network(Error)
    case unauthorized
    case decoding(Error)
    case apiError(status: Int, message: String?)
    case authCancelled
    case authTimedOut
    case stateMismatch

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
        }
    }
}
