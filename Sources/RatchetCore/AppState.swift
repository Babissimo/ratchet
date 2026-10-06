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
    private let mostRecentStore: MostRecentTaskStore

    public init(
        clock: @escaping () -> Date = Date.init,
        mostRecentStore: MostRecentTaskStore = EphemeralMostRecentTaskStore()
    ) {
        self.clock = clock
        self.mostRecentStore = mostRecentStore
        // Restored up front rather than after the first refresh, so a relaunch offers
        // "Start tracking …" the moment the menu is first opened — the launch refresh is a
        // network round trip, and the whole point of this row is that it's there immediately.
        self.mostRecent = mostRecentStore.load()
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

    /// `forgettingMostRecent` clears the remembered task, on disk too: after a deliberate log out
    /// it belongs to the account that left, not the next one to sign in on this Mac.
    public func logOut(forgettingMostRecent: Bool = true) {
        isLoggedIn = false
        if forgettingMostRecent { setMostRecent(nil) }
        trackingTask = nil
        trackingStartedAt = nil
        onChange?()
    }

    /// `recordAsMostRecent: false` is for adopting a timer whose task can't be named from local
    /// data — the placeholder ref keeps "Stop tracking" reachable, but it must never become the
    /// "Start tracking …" row the idle screen offers afterwards.
    public func startTracking(_ task: TrackedTaskRef, startedAt: Date? = nil, recordAsMostRecent: Bool = true) {
        // A start that completes after a log out belongs to the account that left.
        guard isLoggedIn else { return }
        trackingTask = task
        trackingStartedAt = startedAt ?? clock()
        if recordAsMostRecent { setMostRecent(task) }
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
        setMostRecent(task)
        onChange?()
    }

    /// Adopts the newest resolvable task from timeslip history as the "Start tracking …" offer,
    /// in memory and on disk.
    ///
    /// Unconditional apart from the running-timer guard, so the offer follows work tracked in
    /// the FreeAgent web app or on another device. The user's own starts and switches are
    /// timeslip writes, so a refresh that commits after them has them in its history.
    func adoptMostRecentFromHistory(_ task: TrackedTaskRef) {
        // A running timer's task outranks history: FreeAgent doesn't reliably bump `updated_at`
        // when it resumes a timeslip's timer. Matched on id, since a timer the tree can't name
        // is tracked under placeholder names.
        if let trackingTask, trackingTask.taskId == mostRecent?.taskId { return }
        if setMostRecent(task) { onChange?() }
    }

    /// Re-checks the remembered task against the client tree a refresh committed: re-stamps its
    /// names if they changed, and forgets it, on disk too, once the tree no longer contains it.
    /// In this file rather than with `reconcile(with:)` because `setMostRecent` is private to it.
    ///
    /// Only for a committed tree. A refresh commits all or nothing, so a client, project or task
    /// missing from it is one FreeAgent no longer lists, which also covers a task remembered from
    /// another account. The empty tree of a store that has never committed a refresh says
    /// nothing, and reading it as "everything was deleted" would wipe the task on a cold launch.
    func revalidateMostRecent(against clients: [RatchetClient]) {
        guard let mostRecent else { return }
        if setMostRecent(MostRecentTask.reresolve(mostRecent, in: clients)) { onChange?() }
    }

    /// The one write path for a most-recent task, user-chosen or derived, so memory and disk
    /// can't drift. Returns whether it changed: every refresh re-derives the task, and an
    /// unchanged one should cost neither a disk write nor a menu rebuild.
    @discardableResult
    private func setMostRecent(_ task: TrackedTaskRef?) -> Bool {
        guard task != mostRecent else { return false }
        mostRecent = task
        mostRecentStore.save(task)
        return true
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
