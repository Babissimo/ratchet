// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum Screen: Equatable {
    case loggedOut
    case idleNoHistory
    case idle(mostRecent: TrackedTaskRef)
    case tracking(task: TrackedTaskRef, startedAt: Date)
}

public final class AppState {
    public private(set) var isLoggedIn: Bool = false
    public private(set) var mostRecent: TrackedTaskRef?
    public private(set) var trackingTask: TrackedTaskRef?
    public private(set) var trackingStartedAt: Date?
    public private(set) var launchAtLoginEnabled: Bool = false
    public var onChange: (() -> Void)?

    private let clock: () -> Date

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// Exposed for tests that need the exact instant a running timer started.
    public var trackingStartedAtForTesting: Date? { trackingStartedAt }

    public var screen: Screen {
        guard isLoggedIn else { return .loggedOut }
        if let task = trackingTask, let startedAt = trackingStartedAt {
            return .tracking(task: task, startedAt: startedAt)
        }
        if let mostRecent {
            return .idle(mostRecent: mostRecent)
        }
        return .idleNoHistory
    }

    public func logIn() {
        isLoggedIn = true
        onChange?()
    }

    public func logOut() {
        isLoggedIn = false
        mostRecent = nil
        trackingTask = nil
        trackingStartedAt = nil
        onChange?()
    }

    public func startTracking(_ task: TrackedTaskRef, startedAt: Date? = nil) {
        trackingTask = task
        trackingStartedAt = startedAt ?? clock()
        mostRecent = task
        onChange?()
    }

    /// Reassigns the task of an *already-running* timer without touching `trackingStartedAt` —
    /// "Switch task" edits the running timeslip's task in place server-side rather than
    /// stopping and restarting it, so the elapsed-time baseline must keep counting from the
    /// original start instant, not reset to now. No-op (beyond `onChange`) if nothing is
    /// currently tracking, since there's no running timer to reassign.
    public func retask(_ task: TrackedTaskRef) {
        guard trackingStartedAt != nil else { return }
        trackingTask = task
        mostRecent = task
        onChange?()
    }

    public func stopTracking() {
        trackingTask = nil
        trackingStartedAt = nil
        onChange?()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginEnabled = enabled
        onChange?()
    }
}
