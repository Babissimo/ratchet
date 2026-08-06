// Sources/RatchetCore/StatusItemController.swift
import AppKit

public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let dataStore: DataStore
    private var elapsedTimer: Timer?
    private weak var elapsedMenuItem: NSMenuItem?

    /// Exposed for tests to inspect the live NSStatusItem's menu/icon.
    public var statusItemForTesting: NSStatusItem { statusItem }

    public init(appState: AppState, dataStore: DataStore, statusBar: NSStatusBar = .system) {
        self.appState = appState
        self.dataStore = dataStore
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        appState.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    deinit {
        elapsedTimer?.invalidate()
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
        let menu = MenuBuilder.build(state: appState, dataStore: dataStore, actions: actions)
        statusItem.menu = menu
        if case .tracking = appState.screen {
            // Index 2 is the disabled elapsed-time line built by MenuBuilder.buildTracking.
            elapsedMenuItem = menu.items[2]
        } else {
            elapsedMenuItem = nil
        }
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
        if case .tracking(_, let startedAt) = appState.screen {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard case .tracking = self.appState.screen else { return }
                self.elapsedMenuItem?.title = ElapsedTimeFormatter.format(seconds: Date().timeIntervalSince(startedAt))
            }
            // Menus run the run loop in .eventTracking mode while open (the only time the
            // elapsed line is visible), so .common is required for the tick to fire then.
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
        }
    }

    private func presentAddTaskPrompt(clientId: String, projectId: String) {
        // Defer until the menu-tracking run loop session has unwound: running a modal
        // session synchronously from inside menu action dispatch is a known AppKit hazard
        // (the alert can appear behind/non-key, or interact oddly with the just-closed menu).
        DispatchQueue.main.async { [weak self] in
            self?.runAddTaskPrompt(clientId: clientId, projectId: projectId)
        }
    }

    private func runAddTaskPrompt(clientId: String, projectId: String) {
        let alert = NSAlert()
        alert.messageText = "New Task"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Task name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // The app runs as .accessory and is not the active app when a status-bar item is
        // clicked, so the alert can appear non-key/non-frontmost without this.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let name = TaskNameValidator.validate(field.stringValue) else { return }
        _ = dataStore.addTask(name: name, projectId: projectId, clientId: clientId)
        rebuild()
    }
}
