public protocol DataStore: AnyObject {
    var clients: [RatchetClient] { get }
    var accountEmail: String { get }
    func addTask(name: String, projectId: String, clientId: String) -> RatchetTask?
    func refresh()
}
