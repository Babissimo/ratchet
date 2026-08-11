// Sources/Ratchet/AppDelegate.swift
import AppKit
import RatchetCore
import FreeAgentKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let urlSchemeHandler = URLSchemeHandler()
    private let tokenStore = KeychainTokenStore()
    private let environment: FreeAgentEnvironment = .sandbox

    func applicationWillFinishLaunching(_ notification: Notification) {
        urlSchemeHandler.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let apiClient = FreeAgentAPIClient(environment: environment, tokenStore: tokenStore)
        let authenticator = FreeAgentAuthenticator(environment: environment, apiClient: apiClient)
        let dataStore = FreeAgentDataStore(apiClient: apiClient)
        let appState = AppState()

        let controller = StatusItemController(
            appState: appState,
            dataStore: dataStore,
            performLogin: { [urlSchemeHandler, tokenStore] in
                let (authorizeURL, expectedState) = authenticator.buildAuthorizeURL()
                NSWorkspace.shared.open(authorizeURL)
                let callbackURL = try await urlSchemeHandler.waitForCallback(timeout: 180)
                let tokens = try await authenticator.handleCallback(url: callbackURL, expectedState: expectedState)
                tokenStore.save(tokens)
            },
            restoreRunningTimer: { restoreRunningTimer(from: dataStore, into: appState) }
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

/// Adopts whatever timer FreeAgent reports as running into local `AppState`, so the menu shows
/// "tracking" for a timer started elsewhere (another device, the FreeAgent web app, or this app
/// before a quit or a log out).
///
/// Shared by the launch-time restore and `StatusItemController`'s post-login restore — these
/// were separate before, so quit-and-relaunch restored a running timer but log-out-and-back-in
/// showed idle, from identical server state.
@MainActor
func restoreRunningTimer(from dataStore: FreeAgentDataStore, into appState: AppState) {
    guard let running = dataStore.currentRunningTimeslip,
          let client = dataStore.clients.first(where: { $0.id == running.clientId }),
          let project = client.projects.first(where: { $0.id == running.projectId }),
          let task = project.tasks.first(where: { $0.id == running.taskId })
    else { return }
    let ref = TrackedTaskRef(
        clientId: client.id, clientName: client.name,
        projectId: project.id, projectName: project.name,
        taskId: task.id, taskName: task.name
    )
    appState.startTracking(ref, startedAt: running.date)
}
