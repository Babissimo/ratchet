// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@MainActor
extension AppState {
    /// Brings local state into line with what the server just said, after any `refresh()` —
    /// launch, login, the manual "Refresh projects & tasks", and the ~2-minute silent refresh
    /// all call this.
    ///
    /// `@MainActor` on the extension rather than on `AppState` itself: `DataStore` is
    /// main-actor-isolated, so reading it has to be, but `AppState` stays a plain class every
    /// non-UI caller can use unisolated.
    ///
    /// In `RatchetCore` rather than the `Ratchet` executable target because an executable can't
    /// be imported: the `Antagonise` harness has to exercise this definition, not a copy of it.
    public func reconcile(with dataStore: DataStore) {
        // A refresh can land after a log out, and what it fetched belongs to the account that
        // just left.
        guard isLoggedIn else { return }
        adoptRunningTimer(from: dataStore)
        // Matters when history below resolves to nothing and the remembered ref survives: it
        // re-stamps a renamed task and drops a vanished one. Only against a committed tree; see
        // `revalidateMostRecent`.
        if dataStore.lastRefreshedAt != nil {
            revalidateMostRecent(against: dataStore.clients)
        }
        // Last, so it wins. A nil `resolve` changes nothing: a refresh with nothing to offer must
        // not wipe a good remembered task.
        if let derived = MostRecentTask.resolve(timeslips: dataStore.timeslips, clients: dataStore.clients) {
            adoptMostRecentFromHistory(derived)
        }
    }

    /// Adopts whatever timer FreeAgent reports as running, so the menu shows "tracking" for a
    /// timer started elsewhere (another device, the FreeAgent web app, or this app before a quit
    /// or a log out).
    private func adoptRunningTimer(from dataStore: DataStore) {
        guard let running = dataStore.currentRunningTimeslip else {
            // The server genuinely has nothing running, so local "tracking" is stale. Without
            // this, a timer stopped elsewhere would leave the menu tracking forever.
            if trackingTask != nil { stopTracking() }
            return
        }

        // Resolve as far as the local tree allows and fall back to placeholders for the rest.
        // Treating an unresolvable-but-running timeslip as "nothing is running" would be worse
        // than a wrong label: "Stop tracking" only exists on the tracking screen, so the menu
        // would drop to idle and leave no route to stop a timer that goes on billing. It is
        // reachable whenever FreeAgent's default list views leave out the running task, its
        // project or its client.
        let client = dataStore.clients.first { $0.id == running.clientId }
        let project = client?.projects.first { $0.id == running.projectId }
        let task = project?.tasks.first { $0.id == running.taskId }
        let isFullyResolved = task != nil

        let ref = TrackedTaskRef(
            clientId: running.clientId, clientName: client?.name ?? "Unknown client",
            projectId: running.projectId, projectName: project?.name ?? "Unknown project",
            taskId: running.taskId, taskName: task?.name ?? "Unknown task"
        )
        // A running timeslip with no timer start is a response Ratchet can't date, so it counts
        // from first adoption: an undercount, which is safer than inventing a start instant and
        // overcounting. This runs after every refresh, so a timer already tracked under the same
        // task keeps that instant, even as a placeholder resolves or the task is renamed;
        // re-stamping it would reset the elapsed time roughly every two minutes.
        let keptStart = trackingTask?.taskId == ref.taskId ? trackingStartedAt : nil
        let startedAt = running.timerStartedAt ?? keptStart
        guard trackingTask != ref || trackingStartedAt != startedAt else { return }
        startTracking(ref, startedAt: startedAt, recordAsMostRecent: isFullyResolved)
    }
}
