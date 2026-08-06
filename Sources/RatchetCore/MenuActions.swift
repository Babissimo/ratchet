public struct MenuActions {
    public let logIn: () -> Void
    public let logOut: () -> Void
    public let startTracking: (TrackedTaskRef) -> Void
    public let stopTracking: () -> Void
    public let refresh: () -> Void
    public let toggleLaunchAtLogin: () -> Void
    public let openFreeAgent: () -> Void
    public let addTask: (_ clientId: String, _ projectId: String) -> Void
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
        self.quit = quit
    }
}
