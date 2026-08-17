public struct MenuActions {
    public let logIn: () -> Void
    public let logOut: () -> Void
    public let startTracking: (TrackedTaskRef) -> Void
    public let stopTracking: () -> Void
    /// Stops whatever's currently tracking and starts the picked task instead, in one menu
    /// action — the "Switch task" submenu's leaf for an existing task.
    public let switchTask: (TrackedTaskRef) -> Void
    public let refresh: () -> Void
    public let toggleLaunchAtLogin: () -> Void
    public let openFreeAgent: () -> Void
    public let addTask: (_ clientId: String, _ projectId: String) -> Void
    public let addClient: () -> Void
    public let addProject: (_ clientId: String) -> Void
    public let logPastTime: (_ clientId: String, _ projectId: String, _ taskId: String) -> Void
    public let logPastTimeForNewTask: (_ clientId: String, _ projectId: String) -> Void
    /// "Switch task"'s "New task…" leaf: create the task, then switch tracking onto it. Kept
    /// distinct from `addTask` (which only ever starts tracking a fresh task from idle, with
    /// nothing running to stop first) so that path doesn't have to reason about a switch it
    /// never performs.
    public let switchToNewTask: (_ clientId: String, _ projectId: String) -> Void
    /// Clicking a row in "Recent time entries" — opens whatever form lets its hours/task/comment
    /// be changed. Takes the full `RatchetTimeslip` rather than just an id: the menu already has
    /// the entry in hand from building the list, and the id alone isn't enough to prefill a form
    /// without a second lookup back into `dataStore.timeslips`.
    public let editTimeEntry: (RatchetTimeslip) -> Void
    public let quit: () -> Void

    public init(
        logIn: @escaping () -> Void,
        logOut: @escaping () -> Void,
        startTracking: @escaping (TrackedTaskRef) -> Void,
        stopTracking: @escaping () -> Void,
        switchTask: @escaping (TrackedTaskRef) -> Void,
        refresh: @escaping () -> Void,
        toggleLaunchAtLogin: @escaping () -> Void,
        openFreeAgent: @escaping () -> Void,
        addTask: @escaping (_ clientId: String, _ projectId: String) -> Void,
        addClient: @escaping () -> Void,
        addProject: @escaping (_ clientId: String) -> Void,
        logPastTime: @escaping (_ clientId: String, _ projectId: String, _ taskId: String) -> Void,
        logPastTimeForNewTask: @escaping (_ clientId: String, _ projectId: String) -> Void,
        switchToNewTask: @escaping (_ clientId: String, _ projectId: String) -> Void,
        editTimeEntry: @escaping (RatchetTimeslip) -> Void,
        quit: @escaping () -> Void
    ) {
        self.logIn = logIn
        self.logOut = logOut
        self.startTracking = startTracking
        self.stopTracking = stopTracking
        self.switchTask = switchTask
        self.refresh = refresh
        self.toggleLaunchAtLogin = toggleLaunchAtLogin
        self.openFreeAgent = openFreeAgent
        self.addTask = addTask
        self.addClient = addClient
        self.addProject = addProject
        self.logPastTime = logPastTime
        self.logPastTimeForNewTask = logPastTimeForNewTask
        self.switchToNewTask = switchToNewTask
        self.editTimeEntry = editTimeEntry
        self.quit = quit
    }
}
