// SPDX-License-Identifier: GPL-3.0-or-later
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
        let logInItem = ClosureMenuItem(title: "Log in with browser", handler: actions.logIn)
        menu.addItem(logInItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Send feedback", handler: actions.sendFeedback))
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
            item.image = menuIcon("play.fill", "Start tracking")
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
        recentItem.submenu = buildRecentTimeEntriesSubmenu(dataStore: dataStore, actions: actions)
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
        let elapsedTitle = elapsedItemTitle(startedAt: startedAt, bookedDay: dataStore.currentRunningTimeslip?.day, now: now())
        menu.addItem(disabledItem(elapsedTitle))
        let stopTitle = "Stop tracking \(task.taskName)"
        let stopItem = ClosureMenuItem(title: stopTitle, handler: actions.stopTracking)
        stopItem.attributedTitle = twoLineAttributedTitle(
            firstLine: stopTitle,
            secondLine: "\(task.clientName) · \(task.projectName)"
        )
        stopItem.image = menuIcon("stop.fill", "Stop tracking")
        menu.addItem(stopItem)
        let switchItem = NSMenuItem(title: "Switch task", action: nil, keyEquivalent: "")
        switchItem.submenu = buildSwitchTaskSubmenu(dataStore: dataStore, actions: actions, currentTaskId: task.taskId)
        menu.addItem(switchItem)
        menu.addItem(.separator())
        let logPastTimeItem = NSMenuItem(title: "Log past time", action: nil, keyEquivalent: "")
        logPastTimeItem.submenu = buildLogPastTimeSubmenu(dataStore: dataStore, actions: actions)
        menu.addItem(logPastTimeItem)
        let recentItem = NSMenuItem(title: "Recent time entries", action: nil, keyEquivalent: "")
        recentItem.submenu = buildRecentTimeEntriesSubmenu(dataStore: dataStore, actions: actions)
        menu.addItem(recentItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = buildSettingsSubmenu(dataStore: dataStore, state: state, actions: actions)
        menu.addItem(settingsItem)
        menu.addItem(ClosureMenuItem(title: "Quit", handler: actions.quit, keyEquivalent: "q"))
        return menu
    }

    /// The tracking menu's top row: elapsed time, then the day the hours book to when that is
    /// before today. FreeAgent books a timeslip's whole duration to its `dated_on`, so a timer
    /// left running past midnight goes on adding to the earlier day.
    ///
    /// `StatusItemController` re-renders this every second rather than only on a rebuild, so
    /// the note appears at midnight even in a menu built, or held open, before it.
    static func elapsedItemTitle(startedAt: Date, bookedDay: Date?, now: Date) -> String {
        let elapsed = ElapsedTimeFormatter.format(seconds: now.timeIntervalSince(startedAt))
        guard let bookedDay, let pastDay = CalendarDay.pastDayDisplayString(from: bookedDay, now: now) else { return elapsed }
        return "\(elapsed) · booked to \(pastDay)"
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

    /// "Switch task", reachable only from the tracking screen, is the same picker whose leaves
    /// stop the running timer and start tracking the picked (or newly created) task instead.
    /// `currentTaskId` is excluded from the leaves — picking the task that's already running
    /// would otherwise stop and immediately re-resume the same timer for no reason.
    static func buildSwitchTaskSubmenu(dataStore: DataStore, actions: MenuActions, currentTaskId: String) -> NSMenu {
        taskPicker(dataStore: dataStore, actions: actions, leaves: TaskPickerLeaves(
            chooseTask: { client, project, task in
                actions.switchTask(TrackedTaskRef(
                    clientId: client.id, clientName: client.name,
                    projectId: project.id, projectName: project.name,
                    taskId: task.id, taskName: task.name
                ))
            },
            chooseNewTask: { client, project in actions.switchToNewTask(client.id, project.id) },
            excludingTaskId: currentTaskId
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
        /// Omitted from the leaf task list — only "Switch task" sets this, to hide whichever
        /// task is already running.
        var excludingTaskId: String? = nil
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
        let tasks = project.tasks.filter { $0.id != leaves.excludingTaskId }
        if tasks.isEmpty {
            menu.addItem(disabledItem("No tasks"))
        }
        for task in tasks {
            menu.addItem(ClosureMenuItem(title: task.name, handler: { leaves.chooseTask(client, project, task) }))
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "New task…", handler: { leaves.chooseNewTask(client, project) }))
        return menu
    }

    static func buildRecentTimeEntriesSubmenu(dataStore: DataStore, actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Sorted here rather than trusting the store's array order. That order comes from
        // whatever sequence FreeAgent's pagination happened to return, and `logTime` appends
        // locally — so a back-dated entry logged just now would otherwise sort as the newest
        // thing in the list until the next refresh reshuffled it.
        // Excludes the running entry, not just re-labels it: FreeAgent doesn't live-update a
        // running timeslip's `hours`, so whatever's on record is stale from the last pause and
        // it isn't finally logged yet anyway. Filtered before the prefix(20) truncation so
        // dropping it can reveal a 21st entry rather than shortening the visible list.
        let recent = dataStore.timeslips
            .filter { $0.id != dataStore.currentRunningTimeslip?.id }
            .sorted { $0.day > $1.day }
            .prefix(20)

        menu.addItem(sectionHeaderItem("Unbilled"))
        addTimeEntryItems(recent.filter { !$0.isInvoiced }, editable: true, to: menu, dataStore: dataStore, actions: actions)

        menu.addItem(sectionHeaderItem("Invoiced"))
        // FreeAgent closes an entry off once it's on an invoice, so unlike the unbilled section
        // above these rows are shown for reference only — not `editTimeEntry` click targets.
        addTimeEntryItems(recent.filter { $0.isInvoiced }, editable: false, to: menu, dataStore: dataStore, actions: actions)

        return menu
    }

    private static func addTimeEntryItems(
        _ entries: [RatchetTimeslip], editable: Bool, to menu: NSMenu, dataStore: DataStore, actions: MenuActions
    ) {
        if entries.isEmpty {
            menu.addItem(disabledItem("(empty)"))
            return
        }
        for entry in entries {
            let path = path(for: entry, in: dataStore)
            let duration = ElapsedTimeFormatter.format(seconds: entry.hours * 3600)
            let dateText = CalendarDay.displayString(from: entry.day)
            let title = "\(path) · \(duration) · \(dateText)"
            if editable {
                // Clickable rather than `disabledItem`: this is the only route to correcting a
                // mis-logged entry short of leaving the app and editing it in FreeAgent's web UI.
                menu.addItem(ClosureMenuItem(title: title, handler: { actions.editTimeEntry(entry) }))
            } else {
                menu.addItem(disabledItem(title))
            }
        }
    }

    /// A non-interactive, visually distinct row labelling each half of "Recent time entries".
    /// The system-styled section header (`NSMenuItem.sectionHeader`) only exists from macOS 14;
    /// this app's deployment target is 13 (see `Package.swift`), so older systems fall back to a
    /// plain disabled row with the same title.
    private static func sectionHeaderItem(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        return disabledItem(title)
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
        let refreshItem = ClosureMenuItem(title: refreshItemTitle, handler: actions.refresh)
        refreshItem.attributedTitle = refreshItemAttributedTitle(lastRefreshedAt: dataStore.lastRefreshedAt)
        // Assigning `attributedTitle` also rewrites the plain `.title` to that string's full
        // (two-line) contents, so `StatusItemController` can't find this item again by matching
        // `.title` against `refreshItemTitle` — it uses this tag instead.
        refreshItem.tag = refreshItemTag
        menu.addItem(refreshItem)
        let launchItem = ClosureMenuItem(title: "Launch at login", handler: actions.toggleLaunchAtLogin)
        launchItem.state = state.launchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Open FreeAgent", handler: actions.openFreeAgent))
        menu.addItem(ClosureMenuItem(title: "Send feedback", handler: actions.sendFeedback))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Log out", handler: actions.logOut))
        return menu
    }

    static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// An SF Symbol sized for a menu row, marked as a template image so AppKit recolors it to
    /// match the menu's current appearance (regular black glyph in light mode, white in dark
    /// mode, blue when the row is highlighted) instead of rendering the symbol's own flat color.
    /// Only applied to Start/Stop tracking, the app's two primary verbs — icons on every row
    /// read as noise rather than a wayfinding aid.
    private static func menuIcon(_ symbolName: String, _ accessibilityDescription: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
        image?.isTemplate = true
        return image
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

    /// The Settings submenu's "Refresh projects & tasks" row title, used as its initial `.title`.
    static let refreshItemTitle = "Refresh projects & tasks"

    /// Tags the refresh row so `StatusItemController` can find it again after `attributedTitle`
    /// has overwritten `.title` with the two-line text — see the comment at the assignment site.
    static let refreshItemTag = 1

    /// The Settings submenu's "Refresh projects & tasks" row, so `StatusItemController` can find
    /// it again to update it in place. Not `.title`, which `attributedTitle` overwrites.
    static func refreshItem(in settingsSubmenu: NSMenu) -> NSMenuItem? {
        settingsSubmenu.items.first(where: { $0.tag == refreshItemTag })
    }

    /// Rebuilds just the two-line attributed title for the refresh row, so
    /// `StatusItemController.silentlyRefreshIfStale()` can update that row's "Last refreshed at"
    /// line in place — via `NSMenuItem.attributedTitle`, mirroring how `elapsedMenuItem` updates
    /// its `.title` live — without a full menu `rebuild()`, which is guarded out while the menu
    /// is open.
    static func refreshItemAttributedTitle(lastRefreshedAt: Date?) -> NSAttributedString {
        twoLineAttributedTitle(firstLine: refreshItemTitle, secondLine: lastRefreshedSubtitle(lastRefreshedAt))
    }

    /// Shown on the refresh row for the (usually sub-second, but real) network round-trip a
    /// silent refresh takes — without this, the row keeps showing the pre-refresh timestamp with
    /// no sign anything is happening, which reads as if the menu-open/wake refresh never fired.
    static func refreshingAttributedTitle() -> NSAttributedString {
        twoLineAttributedTitle(firstLine: refreshItemTitle, secondLine: "Refreshing…")
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
