import Foundation
@testable import RatchetCore

/// Minimal `SessionExpiredError` conformance for tests that need to simulate a dead FreeAgent
/// session without depending on `FreeAgentKit` (which `RatchetCoreTests` doesn't link against).
struct FakeSessionExpiredError: SessionExpiredError {
    var isSessionExpired: Bool = true
}
