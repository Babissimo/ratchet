// Sources/RatchetCore/StatusItemController.swift
import AppKit

public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let dataStore: DataStore
    private var elapsedTimer: Timer?

    /// Exposed for tests to inspect the live NSStatusItem's menu/icon.
    public var statusItemForTesting: NSStatusItem { statusItem }

    public init(appState: AppState, dataStore: DataStore, statusBar: NSStatusBar = .system) {
        self.appState = appState
        self.dataStore = dataStore
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        appState.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    private lazy var actions: MenuActions = MenuActions(
        logIn: { [weak self] in self?.appState.logIn() },
        logOut: { [weak self] in self?.appState.logOut() },
        startTracking: { [weak self] task in self?.appState.startTracking(task) },
        stopTracking: { [weak self] in self?.appState.stopTracking() },
        refresh: { [weak self] in self?.dataStore.refresh(); self?.rebuild() },
        toggleLaunchAtLogin: { [weak self] in
            guard let self else { return }
            self.appState.setLaunchAtLogin(!self.appState.launchAtLoginEnabled)
        },
        openFreeAgent: {
            NSWorkspace.shared.open(URL(string: "https://app.freeagent.com")!)
        },
        addTask: { [weak self] clientId, projectId in
            self?.presentAddTaskPrompt(clientId: clientId, projectId: projectId)
        },
        quit: {
            NSApp.terminate(nil)
        }
    )

    private func rebuild() {
        statusItem.menu = MenuBuilder.build(state: appState, dataStore: dataStore, actions: actions)
        updateIcon()
        updateTimer()
    }

    private func updateIcon() {
        let isTracking: Bool
        if case .tracking = appState.screen { isTracking = true } else { isTracking = false }
        let symbolName = isTracking ? "clock.fill" : "clock"
        statusItem.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Ratchet")
    }

    private func updateTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if case .tracking = appState.screen {
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.statusItem.menu = MenuBuilder.build(state: self.appState, dataStore: self.dataStore, actions: self.actions)
            }
        }
    }

    private func presentAddTaskPrompt(clientId: String, projectId: String) {
        let alert = NSAlert()
        alert.messageText = "New Task"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let name = TaskNameValidator.validate(field.stringValue) else { return }
        _ = dataStore.addTask(name: name, projectId: projectId, clientId: clientId)
        rebuild()
    }
}
