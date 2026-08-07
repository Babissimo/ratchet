public struct MenuActions {
    public let logIn: () -> Void
    public let logOut: () -> Void
    public let startTracking: (TrackedTaskRef) -> Void
    public let stopTracking: () -> Void
    public let refresh: () -> Void
    public let toggleLaunchAtLogin: () -> Void
    public let openFreeAgent: () -> Void
    public let addTask: (_ clientId: String, _ projectId: String) -> Void
    public let addClient: () -> Void
    public let addProject: (_ clientId: String) -> Void
    public let logPastTime: (_ clientId: String, _ projectId: String, _ taskId: String) -> Void
    public let logPastTimeForNewTask: (_ clientId: String, _ projectId: String) -> Void
    public let quit: () -> Void

    public init(
        logIn: @escaping () -> Void,
        logOut: @escaping () -> Void,
        startTracking: @escaping (TrackedTaskRef) -> Void,
        stopTracking: @escaping () -> Void,
        refresh: @escaping () -> Void,
        toggleLaunchAtLogin: @escaping () -> Void,
        openFreeAgent: @escaping () -> Void,
        addTask: @escaping (_ clientId: String, _ projectId: String) -> Void,
        addClient: @escaping () -> Void,
        addProject: @escaping (_ clientId: String) -> Void,
        logPastTime: @escaping (_ clientId: String, _ projectId: String, _ taskId: String) -> Void,
        logPastTimeForNewTask: @escaping (_ clientId: String, _ projectId: String) -> Void,
        quit: @escaping () -> Void
    ) {
        self.logIn = logIn
        self.logOut = logOut
        self.startTracking = startTracking
        self.stopTracking = stopTracking
        self.refresh = refresh
        self.toggleLaunchAtLogin = toggleLaunchAtLogin
        self.openFreeAgent = openFreeAgent
        self.addTask = addTask
        self.addClient = addClient
        self.addProject = addProject
        self.logPastTime = logPastTime
        self.logPastTimeForNewTask = logPastTimeForNewTask
        self.quit = quit
    }
}
