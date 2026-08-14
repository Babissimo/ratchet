import AppKit

@MainActor
public enum MenuBuilder {
    public static func build(state: AppState, dataStore: DataStore, actions: MenuActions, now: () -> Date = Date.init) -> NSMenu {
        switch state.screen {
        case .loggedOut:
            return buildLoggedOut(actions: actions)
        case .idleNoHistory:
            return buildIdle(mostRecent: nil, dataStore: dataStore, state: state, actions: actions)
        case .idle(let mostRecent):
            return buildIdle(mostRecent: mostRecent, dataStore: dataStore, state: state, actions: actions)
        case .tracking(let task, let startedAt):
            return buildTracking(task: task, startedAt: startedAt, dataStore: dataStore, state: state, actions: actions, now: now)
        }
    }

    private static func buildLoggedOut(actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: "Log in with browser", handler: actions.logIn))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit", handler: actions.quit, keyEquivalent: "q"))
        return menu
    }

    static func buildIdle(mostRecent: TrackedTaskRef?, dataStore: DataStore, state: AppState, actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let mostRecent {
            let title = "Start tracking \(mostRecent.taskName)"
            let item = ClosureMenuItem(title: title, handler: { actions.startTracking(mostRecent) })
            item.attributedTitle = twoLineAttributedTitle(
                firstLine: title,
                secondLine: "\(mostRecent.clientName) · \(mostRecent.projectName)"
            )
            menu.addItem(item)
        }
        let startItem = NSMenuItem(title: "Start timer", action: nil, keyEquivalent: "")
        startItem.submenu = buildStartSubmenu(dataStore: dataStore, actions: actions)
        menu.addItem(startItem)
        menu.addItem(.separator())
        let logPastTimeItem = NSMenuItem(title: "Log past time", action: nil, keyEquivalent: "")
        logPastTimeItem.submenu = buildLogPastTimeSubmenu(dataStore: dataStore, actions: actions)
        menu.addItem(logPastTimeItem)
        let recentItem = NSMenuItem(title: "Recent time entries", action: nil, keyEquivalent: "")
        recentItem.submenu = buildRecentTimeEntriesSubmenu(dataStore: dataStore)
        menu.addItem(recentItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = buildSettingsSubmenu(dataStore: dataStore, state: state, actions: actions)
        menu.addItem(settingsItem)
        menu.addItem(ClosureMenuItem(title: "Quit", handler: actions.quit, keyEquivalent: "q"))
        return menu
    }

    static func buildTracking(task: TrackedTaskRef, startedAt: Date, dataStore: DataStore, state: AppState, actions: MenuActions, now: () -> Date = Date.init) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let elapsed = ElapsedTimeFormatter.format(seconds: now().timeIntervalSince(startedAt))
        menu.addItem(disabledItem(elapsed))
        let stopTitle = "Stop tracking \(task.taskName)"
        let stopItem = ClosureMenuItem(title: stopTitle, handler: actions.stopTracking)
        stopItem.attributedTitle = twoLineAttributedTitle(
            firstLine: stopTitle,
            secondLine: "\(task.clientName) · \(task.projectName)"
        )
        menu.addItem(stopItem)
        menu.addItem(.separator())
        let logPastTimeItem = NSMenuItem(title: "Log past time", action: nil, keyEquivalent: "")
        logPastTimeItem.submenu = buildLogPastTimeSubmenu(dataStore: dataStore, actions: actions)
        menu.addItem(logPastTimeItem)
        let recentItem = NSMenuItem(title: "Recent time entries", action: nil, keyEquivalent: "")
        recentItem.submenu = buildRecentTimeEntriesSubmenu(dataStore: dataStore)
        menu.addItem(recentItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = buildSettingsSubmenu(dataStore: dataStore, state: state, actions: actions)
        menu.addItem(settingsItem)
        menu.addItem(ClosureMenuItem(title: "Quit", handler: actions.quit, keyEquivalent: "q"))
        return menu
    }

    /// "Start timer" is the task picker whose leaves start the clock.
    ///
    /// A named entry point rather than an inline `taskPicker(…)` call at each use site because
    /// the two pickers are the app's two primary verbs, and tests pin them by name.
    static func buildStartSubmenu(dataStore: DataStore, actions: MenuActions) -> NSMenu {
        taskPicker(dataStore: dataStore, actions: actions, leaves: TaskPickerLeaves(
            chooseTask: { client, project, task in
                actions.startTracking(TrackedTaskRef(
                    clientId: client.id, clientName: client.name,
                    projectId: project.id, projectName: project.name,
                    taskId: task.id, taskName: task.name
                ))
            },
            chooseNewTask: { client, project in actions.addTask(client.id, project.id) }
        ))
    }

    /// "Log past time" is the same picker whose leaves open the retrospective-entry sheet.
    static func buildLogPastTimeSubmenu(dataStore: DataStore, actions: MenuActions) -> NSMenu {
        taskPicker(dataStore: dataStore, actions: actions, leaves: TaskPickerLeaves(
            chooseTask: { client, project, task in actions.logPastTime(client.id, project.id, task.id) },
            chooseNewTask: { client, project in actions.logPastTimeForNewTask(client.id, project.id) }
        ))
    }

    /// Everything that distinguishes the two task pickers.
    ///
    /// The pickers used to be two hand-copied three-level trees, identical down to their
    /// separators and empty-state rows, and every change to the shared scaffolding — a renamed
    /// placeholder, a reordered row — had to be applied twice or the two menus silently drifted.
    /// Naming the difference as a value makes it structurally impossible for the shapes to
    /// diverge: a new picker supplies two closures and inherits the rest.
    private struct TaskPickerLeaves {
        let chooseTask: (RatchetClient, RatchetProject, RatchetTask) -> Void
        let chooseNewTask: (RatchetClient, RatchetProject) -> Void
    }

    /// Client → project → task, with an "add one" escape hatch at each level so a user who
    /// discovers mid-flow that the thing they want doesn't exist yet never has to back out to
    /// FreeAgent. The escape hatches above the leaves are the same for every picker — only the
    /// bottom two rows are parameterised.
    private static func taskPicker(dataStore: DataStore, actions: MenuActions, leaves: TaskPickerLeaves) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if dataStore.clients.isEmpty {
            menu.addItem(disabledItem("No clients"))
        }
        for client in dataStore.clients {
            let item = NSMenuItem(title: client.name, action: nil, keyEquivalent: "")
            item.submenu = taskPickerProjects(client: client, actions: actions, leaves: leaves)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Add client…", handler: actions.addClient))
        return menu
    }

    private static func taskPickerProjects(client: RatchetClient, actions: MenuActions, leaves: TaskPickerLeaves) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if client.projects.isEmpty {
            menu.addItem(disabledItem("No projects"))
        }
        for project in client.projects {
            let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            item.submenu = taskPickerTasks(client: client, project: project, leaves: leaves)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Add project…", handler: { actions.addProject(client.id) }))
        return menu
    }

    private static func taskPickerTasks(client: RatchetClient, project: RatchetProject, leaves: TaskPickerLeaves) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if project.tasks.isEmpty {
            menu.addItem(disabledItem("No tasks"))
        }
        for task in project.tasks {
            menu.addItem(ClosureMenuItem(title: task.name, handler: { leaves.chooseTask(client, project, task) }))
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "New task…", handler: { leaves.chooseNewTask(client, project) }))
        return menu
    }

    static func buildRecentTimeEntriesSubmenu(dataStore: DataStore) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Sorted here rather than trusting the store's array order. That order comes from
        // whatever sequence FreeAgent's pagination happened to return, and `logTime` appends
        // locally — so a back-dated entry logged just now would otherwise sort as the newest
        // thing in the list until the next refresh reshuffled it.
        let recent = dataStore.timeslips.sorted { $0.date > $1.date }.prefix(20)
        if recent.isEmpty {
            menu.addItem(disabledItem("No time logged yet"))
            return menu
        }
        for entry in recent {
            let path = path(for: entry, in: dataStore)
            let duration = ElapsedTimeFormatter.format(seconds: entry.hours * 3600)
            let dateText = CalendarDay.displayString(from: entry.date)
            menu.addItem(disabledItem("\(path) · \(duration) · \(dateText)"))
        }
        return menu
    }

    private static func path(for entry: RatchetTimeslip, in dataStore: DataStore) -> String {
        guard let client = dataStore.clients.first(where: { $0.id == entry.clientId }) else { return "Unknown task" }
        guard let project = client.projects.first(where: { $0.id == entry.projectId }) else { return "\(client.name) · Unknown task" }
        guard let task = project.tasks.first(where: { $0.id == entry.taskId }) else { return "\(client.name) · \(project.name) · Unknown task" }
        return "\(client.name) · \(project.name) · \(task.name)"
    }

    static func buildSettingsSubmenu(dataStore: DataStore, state: AppState, actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(disabledItem(dataStore.accountEmail))
        let refreshTitle = "Refresh projects & tasks"
        let refreshItem = ClosureMenuItem(title: refreshTitle, handler: actions.refresh)
        refreshItem.attributedTitle = twoLineAttributedTitle(
            firstLine: refreshTitle,
            secondLine: lastRefreshedSubtitle(dataStore.lastRefreshedAt)
        )
        menu.addItem(refreshItem)
        let launchItem = ClosureMenuItem(title: "Launch at login", handler: actions.toggleLaunchAtLogin)
        launchItem.state = state.launchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Open FreeAgent", handler: actions.openFreeAgent))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Log out", handler: actions.logOut))
        return menu
    }

    static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Two-line title (e.g. "Start tracking X" over "Client · Project", or
    /// "Refresh projects & tasks" over "Last refreshed at …") rendered as a single menu row
    /// with one click target, so the action and its context read as one coupled unit rather
    /// than two adjacent-looking items.
    private static func twoLineAttributedTitle(firstLine: String, secondLine: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: "\(firstLine)\n",
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        )
        result.append(NSAttributedString(
            string: secondLine,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return result
    }

    private static func lastRefreshedSubtitle(_ lastRefreshedAt: Date?) -> String {
        guard let lastRefreshedAt else { return "Never refreshed" }
        return "Last refreshed at \(lastRefreshedAtFormatter.string(from: lastRefreshedAt))"
    }

    /// A wall-clock timestamp, not a calendar day, so this stays a local `DateFormatter` rather
    /// than going through `CalendarDay`. The locale and calendar are pinned because a fixed
    /// `dateFormat` is still rendered through the user's own: a preference for Arabic-Indic or
    /// Devanagari digits would otherwise print non-ASCII numerals, and a non-Gregorian regional
    /// calendar would print the wrong year entirely.
    private static let lastRefreshedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "HH:mm 'on' yyyy-MM-dd"
        return formatter
    }()
}
