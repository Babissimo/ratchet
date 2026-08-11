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
            }
        )
        statusItemController = controller

        if tokenStore.load() != nil {
            appState.logIn()
            Task { @MainActor in
                do {
                    try await dataStore.refresh()
                    if let running = dataStore.currentRunningTimeslip,
                       let client = dataStore.clients.first(where: { $0.id == running.clientId }),
                       let project = client.projects.first(where: { $0.id == running.projectId }),
                       let task = project.tasks.first(where: { $0.id == running.taskId }) {
                        let ref = TrackedTaskRef(
                            clientId: client.id, clientName: client.name,
                            projectId: project.id, projectName: project.name,
                            taskId: task.id, taskName: task.name
                        )
                        appState.startTracking(ref, startedAt: running.date)
                    }
                    // appState.logIn() (above) fired rebuild() before this refresh completed, so
                    // the menu was built from an empty, unrefreshed dataStore. startTracking above
                    // triggers its own rebuild via appState.onChange, but when no timer is running
                    // nothing further mutates appState — without this, the freshly-fetched
                    // clients/projects/tasks and "Last refreshed at" would stay hidden until the
                    // user manually clicks "Refresh projects & tasks".
                    controller.refreshMenu()
                } catch {
                    // Launch-time refresh failure isn't fatal — the user can
                    // trigger "Refresh projects & tasks" manually; surfacing
                    // an alert before the menu bar item is even visible/clicked
                    // would be a jarring first impression on every launch
                    // where e.g. Wi-Fi hasn't connected yet.
                }
            }
        }

        controller.onLogOut = { [tokenStore] in
            tokenStore.clear()
        }
    }
}
