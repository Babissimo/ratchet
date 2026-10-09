// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import RatchetCore

/// Minimal `SessionEndedError` conformance, for the reason `FakeSessionExpiredError` gives.
struct FakeSessionEndedError: SessionEndedError {
    var isSessionEnded: Bool = true
}
