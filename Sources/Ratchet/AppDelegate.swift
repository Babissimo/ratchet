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
    private let environment = FreeAgentEnvironment.configured
    private lazy var tokenStore = KeychainTokenStore(environment: environment)

    func applicationWillFinishLaunching(_ notification: Notification) {
        urlSchemeHandler.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let apiClient = FreeAgentAPIClient(environment: environment, tokenStore: tokenStore)
        let authenticator = FreeAgentAuthenticator(environment: environment, apiClient: apiClient)
        let dataStore = FreeAgentDataStore(apiClient: apiClient, environment: environment)
        // Keyed by environment: sandbox and production builds share a bundle id, and so a
        // defaults domain, and each must not offer the other's task.
        let appState = AppState(mostRecentStore: UserDefaultsMostRecentTaskStore(key: "mostRecentTask.\(environment)"))
        // Reads real state rather than defaulting to false, so the checkbox is right even if the
        // user enabled/disabled the login item outside the app, e.g. via System Settings.
        appState.setLaunchAtLogin(isLaunchAtLoginEnabled())

        let controller = StatusItemController(
            appState: appState,
            dataStore: dataStore,
            performLogin: { [urlSchemeHandler, tokenStore] in
                let request = authenticator.makeAuthorizationRequest()
                NSWorkspace.shared.open(request.url)
                let callbackURL = try await urlSchemeHandler.waitForCallback(state: request.state, timeout: 180)
                let tokens = try await authenticator.handleCallback(url: callbackURL, for: request)
                guard tokenStore.save(tokens) else { throw FreeAgentError.credentialStorageFailed }
            },
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
                    appState.reconcile(with: dataStore)
                    // appState.logIn() (above) fired rebuild() before this refresh completed, so
                    // the menu was built from an empty, unrefreshed dataStore. reconcile(with:)
                    // triggers its own rebuild via appState.onChange, but when it changes nothing
                    // (no timer running, and the remembered task already correct) nothing further
                    // mutates appState — without this, the freshly-fetched clients/projects/tasks
                    // and "Last refreshed at" would stay hidden until the user manually clicks
                    // "Refresh projects & tasks".
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
