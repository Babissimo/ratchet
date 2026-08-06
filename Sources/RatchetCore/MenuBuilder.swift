import AppKit

public enum MenuBuilder {
    public static func build(state: AppState, dataStore: DataStore, actions: MenuActions) -> NSMenu {
        switch state.screen {
        case .loggedOut:
            return buildLoggedOut(actions: actions)
        case .idleNoHistory:
            return buildIdle(mostRecent: nil, dataStore: dataStore, state: state, actions: actions)
        case .idle(let mostRecent):
            return buildIdle(mostRecent: mostRecent, dataStore: dataStore, state: state, actions: actions)
        case .tracking(let task, let startedAt):
            return buildTracking(task: task, startedAt: startedAt, dataStore: dataStore, state: state, actions: actions)
        }
    }

    private static func buildLoggedOut(actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Log in with browser", handler: actions.logIn))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit", handler: actions.quit, keyEquivalent: "q"))
        return menu
    }

    static func buildIdle(mostRecent: TrackedTaskRef?, dataStore: DataStore, state: AppState, actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        if let mostRecent {
            menu.addItem(ClosureMenuItem(title: "Start tracking \(mostRecent.taskName)", handler: { actions.startTracking(mostRecent) }))
            menu.addItem(disabledItem("\(mostRecent.clientName) · \(mostRecent.projectName)"))
        }
        let startItem = NSMenuItem(title: "Start", action: nil, keyEquivalent: "")
        startItem.submenu = buildStartSubmenu(dataStore: dataStore, actions: actions)
        menu.addItem(startItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = buildSettingsSubmenu(dataStore: dataStore, state: state, actions: actions)
        menu.addItem(settingsItem)
        menu.addItem(ClosureMenuItem(title: "Quit", handler: actions.quit, keyEquivalent: "q"))
        return menu
    }

    static func buildTracking(task: TrackedTaskRef, startedAt: Date, dataStore: DataStore, state: AppState, actions: MenuActions) -> NSMenu {
        // Implemented in Task 6.
        NSMenu()
    }

    static func buildStartSubmenu(dataStore: DataStore, actions: MenuActions) -> NSMenu {
        // Implemented in Task 7.
        NSMenu()
    }

    static func buildSettingsSubmenu(dataStore: DataStore, state: AppState, actions: MenuActions) -> NSMenu {
        // Implemented in Task 8.
        NSMenu()
    }

    static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
