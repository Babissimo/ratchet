// SPDX-License-Identifier: GPL-3.0-or-later
// Sources/Ratchet/AppDelegate.swift
import AppKit
import RatchetCore
import FreeAgentKit
import ServiceManagement

/// `@MainActor` because AppKit only ever calls a delegate on the main thread, and its stored
/// properties (`URLSchemeHandler`, `StatusItemController`) are main-actor-isolated themselves.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let urlSchemeHandler = URLSchemeHandler()
    private let tokenStore = KeychainTokenStore()
    private let environment = FreeAgentEnvironment.configured

    func applicationWillFinishLaunching(_ notification: Notification) {
        urlSchemeHandler.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let apiClient = FreeAgentAPIClient(environment: environment, tokenStore: tokenStore)
        let authenticator = FreeAgentAuthenticator(environment: environment, apiClient: apiClient)
        let dataStore = FreeAgentDataStore(apiClient: apiClient, environment: environment)
        let appState = AppState()
        // Reads real state rather than defaulting to false, so the checkbox is right even if the
        // user enabled/disabled the login item outside the app, e.g. via System Settings.
        appState.setLaunchAtLogin(isLaunchAtLoginEnabled())

        let controller = StatusItemController(
            appState: appState,
            dataStore: dataStore,
            performLogin: { [urlSchemeHandler, tokenStore] in
                let (authorizeURL, expectedState) = authenticator.buildAuthorizeURL()
                NSWorkspace.shared.open(authorizeURL)
                let callbackURL = try await urlSchemeHandler.waitForCallback(timeout: 180)
                let tokens = try await authenticator.handleCallback(url: callbackURL, expectedState: expectedState)
                guard tokenStore.save(tokens) else { throw FreeAgentError.credentialStorageFailed }
            },
            restoreRunningTimer: { restoreRunningTimer(from: dataStore, into: appState) },
            setLaunchAtLogin: { enabled in
                // SMAppService's calls are documented safe from any thread, but they're
                // synchronous, blocking XPC round-trips to smd that can take seconds on first
                // registration — running them straight from this @MainActor closure would hang
                // the menu bar and elapsed-timer tick for that long. Task.detached moves the
                // actual blocking work off the main actor; only the returned result crosses back.
                try await Task.detached {
                    if enabled {
                        try SMAppService.mainApp.register()
                        // register() can return without throwing while still sitting in
                        // .requiresApproval — macOS requires the user to approve the login item in
                        // System Settings on first registration. That's not a failure, but it also
                        // isn't "enabled" yet, so report the real status rather than `enabled`.
                        return isLaunchAtLoginEnabled()
                    } else {
                        try SMAppService.mainApp.unregister()
                        return false
                    }
                }.value
            }
        )
        statusItemController = controller

        controller.onLogOut = { [tokenStore] in
            tokenStore.clear()
        }

        if tokenStore.load() != nil {
            appState.logIn()
            Task { @MainActor in
                do {
                    try await dataStore.refresh()
                    restoreRunningTimer(from: dataStore, into: appState)
                    // appState.logIn() (above) fired rebuild() before this refresh completed, so
                    // the menu was built from an empty, unrefreshed dataStore. restoreRunningTimer
                    // triggers its own rebuild via appState.onChange, but when no timer is running
                    // nothing further mutates appState — without this, the freshly-fetched
                    // clients/projects/tasks and "Last refreshed at" would stay hidden until the
                    // user manually clicks "Refresh projects & tasks".
                    controller.refreshMenu()
                } catch where error.indicatesSessionExpired {
                    // The stored refresh token is dead. Silently swallowing this left the app
                    // looking logged in with a permanently empty menu and no way to re-trigger
                    // login short of Settings → Log Out → Log In.
                    controller.handleSessionExpired()
                } catch {
                    // Any other launch-time refresh failure isn't fatal — the user can
                    // trigger "Refresh projects & tasks" manually; surfacing an alert before the
                    // menu bar item is even visible/clicked would be a jarring first impression
                    // on every launch where e.g. Wi-Fi hasn't connected yet.
                }
            }
        }
    }
}

/// Single definition of "enabled" for the launch-at-login checkbox, shared by the launch-time
/// seed and `setLaunchAtLogin`'s post-register re-read so the two can't drift. Not `@MainActor`:
/// `SMAppService`'s properties are documented safe from any thread, and this needs to be callable
/// from inside `Task.detached` (nonisolated) as well as from `applicationDidFinishLaunching`.
private nonisolated func isLaunchAtLoginEnabled() -> Bool {
    SMAppService.mainApp.status == .enabled
}

/// Adopts whatever timer FreeAgent reports as running into local `AppState`, so the menu shows
/// "tracking" for a timer started elsewhere (another device, the FreeAgent web app, or this app
/// before a quit or a log out).
///
/// Shared by the launch-time restore and `StatusItemController`'s post-login restore — these
/// were separate before, so quit-and-relaunch restored a running timer but log-out-and-back-in
/// showed idle, from identical server state.
@MainActor
func restoreRunningTimer(from dataStore: FreeAgentDataStore, into appState: AppState) {
    guard let running = dataStore.currentRunningTimeslip else {
        // The server genuinely has nothing running, so local "tracking" is now stale. Without
        // this, a timer stopped elsewhere left the menu tracking forever.
        if appState.trackingTask != nil { appState.stopTracking() }
        return
    }

    // Resolve as far as the local tree allows and fall back to placeholders for the rest.
    // Treating an unresolvable-but-running timeslip as "nothing is running" used to call
    // stopTracking(), which is worse than a wrong label: "Stop tracking" only exists on the
    // tracking screen, so the menu dropped to idle and left no route to stop a timer that went
    // on billing. It is reachable whenever the running task is Completed or Hidden, its project
    // archived, or a list fetch came back short.
    let client = dataStore.clients.first { $0.id == running.clientId }
    let project = client?.projects.first { $0.id == running.projectId }
    let task = project?.tasks.first { $0.id == running.taskId }
    let isFullyResolved = task != nil

    let ref = TrackedTaskRef(
        clientId: running.clientId, clientName: client?.name ?? "Unknown client",
        projectId: running.projectId, projectName: project?.name ?? "Unknown project",
        taskId: running.taskId, taskName: task?.name ?? "Unknown task"
    )
    // A timeslip the running-view query returned but that carries no timer start is a response
    // Ratchet can't date; counting from adoption undercounts, which is strictly safer than the
    // old midnight fallback's wild overcount.
    appState.startTracking(ref, startedAt: running.timerStartedAt ?? Date(), recordAsMostRecent: isFullyResolved)
}
