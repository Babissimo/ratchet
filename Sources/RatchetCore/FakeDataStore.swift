import Foundation

public final class FakeDataStore: DataStore {
    public private(set) var clients: [RatchetClient]
    public let accountEmail: String
    public private(set) var refreshCount = 0

    public init(clients: [RatchetClient], accountEmail: String) {
        self.clients = clients
        self.accountEmail = accountEmail
    }

    public static func seeded() -> FakeDataStore {
        let developmentTask = RatchetTask(id: "task-1", name: "Development")
        let designTask = RatchetTask(id: "task-2", name: "Design")
        let websiteProject = RatchetProject(id: "proj-1", name: "Website Redesign", tasks: [developmentTask, designTask])
        let copywritingTask = RatchetTask(id: "task-3", name: "Copywriting")
        let retainerProject = RatchetProject(id: "proj-2", name: "Q3 Retainer", tasks: [copywritingTask])
        let acme = RatchetClient(id: "client-1", name: "Acme", projects: [websiteProject, retainerProject])
        let otherCo = RatchetClient(id: "client-2", name: "Other Co", projects: [])
        return FakeDataStore(clients: [acme, otherCo], accountEmail: "al@example.com")
    }

    public func addTask(name: String, projectId: String, clientId: String) -> RatchetTask? {
        guard let clientIndex = clients.firstIndex(where: { $0.id == clientId }) else { return nil }
        guard let projectIndex = clients[clientIndex].projects.firstIndex(where: { $0.id == projectId }) else { return nil }

        let newTask = RatchetTask(id: "task-\(UUID().uuidString.prefix(8))", name: name)
        var projects = clients[clientIndex].projects
        let existingProject = projects[projectIndex]
        projects[projectIndex] = RatchetProject(id: existingProject.id, name: existingProject.name, tasks: existingProject.tasks + [newTask])
        clients[clientIndex] = RatchetClient(id: clients[clientIndex].id, name: clients[clientIndex].name, projects: projects)
        return newTask
    }

    public func refresh() {
        refreshCount += 1
    }
}
