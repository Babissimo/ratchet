// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Derives "the last thing you tracked" from timeslip history, for the idle screen's
/// "Start tracking …" row.
///
/// Whenever history names a task, it replaces `MostRecentTaskStore`'s persisted value, which
/// only has to bridge the gap until the launch refresh lands. History covers what persistence
/// structurally can't: a fresh install, cleared preferences, a new machine, or work tracked from
/// the FreeAgent web app or another device since this app last ran.
public enum MostRecentTask {
    /// The newest history entry that still resolves to a real client/project/task, or nil if
    /// none does. Unresolvable entries are skipped rather than offered under placeholder names:
    /// unlike a running timer, which must stay stoppable, an idle offer gains nothing from one.
    public static func resolve(timeslips: [RatchetTimeslip], clients: [RatchetClient]) -> TrackedTaskRef? {
        // By `day`, then `updatedAt` within a day. Not by `updatedAt` alone: correcting a
        // month-old entry bumps it to now, and would offer that task ahead of this morning's work.
        let newestFirst = timeslips.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day > rhs.day }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
        return newestFirst.lazy.compactMap {
            lookUp(clientId: $0.clientId, projectId: $0.projectId, taskId: $0.taskId, in: clients)
        }.first
    }

    /// Rebuilds `ref` from the client tree as it stands now, or nil if the tree no longer
    /// contains its client, project or task.
    ///
    /// A persisted ref is a snapshot of names as they were when it was written, possibly several
    /// launches ago. Without this, renaming a task in FreeAgent would leave the idle screen
    /// offering its old name indefinitely, and deleting one would leave an offer to start a task
    /// that no longer exists, which fails server-side with an error alert.
    public static func reresolve(_ ref: TrackedTaskRef, in clients: [RatchetClient]) -> TrackedTaskRef? {
        lookUp(clientId: ref.clientId, projectId: ref.projectId, taskId: ref.taskId, in: clients)
    }

    private static func lookUp(
        clientId: String, projectId: String, taskId: String, in clients: [RatchetClient]
    ) -> TrackedTaskRef? {
        guard let client = clients.first(where: { $0.id == clientId }),
              let project = client.projects.first(where: { $0.id == projectId }),
              let task = project.tasks.first(where: { $0.id == taskId })
        else { return nil }
        return TrackedTaskRef(
            clientId: client.id, clientName: client.name,
            projectId: project.id, projectName: project.name,
            taskId: task.id, taskName: task.name
        )
    }
}

/// Persistence for the idle screen's "Start tracking …" suggestion across launches.
///
/// Injected rather than called directly from `AppState` for the same reason `performLogin` and
/// `setLaunchAtLogin` are injected into `StatusItemController`: `RatchetCore` describes what
/// should happen, and tests need a seam that doesn't touch the real user defaults.
public protocol MostRecentTaskStore: AnyObject {
    func load() -> TrackedTaskRef?
    /// nil clears the stored value, as `AppState.logOut()` does after a deliberate log out.
    func save(_ ref: TrackedTaskRef?)
}

/// The default no-op, so `AppState()` keeps working (and stays free of side effects) for every
/// caller that doesn't care about persistence — tests and the `Antagonise` harness included.
public final class EphemeralMostRecentTaskStore: MostRecentTaskStore {
    public init() {}
    public func load() -> TrackedTaskRef? { nil }
    public func save(_ ref: TrackedTaskRef?) {}
}

/// The real one, backed by `UserDefaults`.
public final class UserDefaultsMostRecentTaskStore: MostRecentTaskStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "mostRecentTask") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> TrackedTaskRef? {
        guard let data = defaults.data(forKey: key) else { return nil }
        // A decode failure means a ref written by an older build whose shape has since changed.
        // That's a suggestion the user loses once, not an error worth surfacing — and
        // `MostRecentTask.resolve` re-derives an answer from history on the next refresh anyway.
        return try? JSONDecoder().decode(TrackedTaskRef.self, from: data)
    }

    public func save(_ ref: TrackedTaskRef?) {
        guard let ref, let data = try? JSONEncoder().encode(ref) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
