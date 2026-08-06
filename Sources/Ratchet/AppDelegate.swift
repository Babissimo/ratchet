// Sources/Ratchet/AppDelegate.swift
import AppKit
import RatchetCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dataStore = FakeDataStore.seeded()
        let appState = AppState()
        statusItemController = StatusItemController(appState: appState, dataStore: dataStore)
    }
}
