import Foundation

public struct RatchetTask: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct RatchetProject: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let tasks: [RatchetTask]

    public init(id: String, name: String, tasks: [RatchetTask]) {
        self.id = id
        self.name = name
        self.tasks = tasks
    }
}

public struct RatchetClient: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let projects: [RatchetProject]

    public init(id: String, name: String, projects: [RatchetProject]) {
        self.id = id
        self.name = name
        self.projects = projects
    }
}

public struct TrackedTaskRef: Equatable, Codable {
    public let clientId: String
    public let clientName: String
    public let projectId: String
    public let projectName: String
    public let taskId: String
    public let taskName: String

    public init(clientId: String, clientName: String, projectId: String, projectName: String, taskId: String, taskName: String) {
        self.clientId = clientId
        self.clientName = clientName
        self.projectId = projectId
        self.projectName = projectName
        self.taskId = taskId
        self.taskName = taskName
    }
}
