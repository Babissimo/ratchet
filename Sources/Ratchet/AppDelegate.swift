// Sources/Ratchet/AppDelegate.swift
import AppKit
import RatchetCore
import FreeAgentKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    let urlSchemeHandler = URLSchemeHandler()

    func applicationWillFinishLaunching(_ notification: Notification) {
        urlSchemeHandler.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dataStore = FakeDataStore.seeded()
        let appState = AppState()
        statusItemController = StatusItemController(appState: appState, dataStore: dataStore)
    }
}
