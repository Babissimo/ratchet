import Foundation

@MainActor
public final class FakeDataStore: DataStore {
    public private(set) var clients: [RatchetClient]
    public let accountEmail: String
    public private(set) var refreshCount = 0
    public private(set) var timeslips: [RatchetTimeslip] = []
    public private(set) var lastRefreshedAt: Date?

    /// id of the timeslip with a currently-running timer, if any.
    private var runningTimeslipId: String?

    private let clock: () -> Date

    public init(clients: [RatchetClient], accountEmail: String, clock: @escaping () -> Date = Date.init) {
        self.clients = clients
        self.accountEmail = accountEmail
        self.clock = clock
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

    public func addTask(
        name: String,
        projectId: String,
        clientId: String,
        isBillable: Bool = true,
        status: TaskStatus = .active,
        billingRate: Double? = nil,
        billingPeriod: BillingPeriod? = nil
    ) async throws -> RatchetTask {
        guard let clientIndex = clients.firstIndex(where: { $0.id == clientId }) else { throw DataStoreError.notFound }
        guard let projectIndex = clients[clientIndex].projects.firstIndex(where: { $0.id == projectId }) else { throw DataStoreError.notFound }

        let newTask = RatchetTask(
            id: "task-\(UUID().uuidString.prefix(8))",
            name: name,
            isBillable: isBillable,
            status: status,
            billingRate: billingRate,
            billingPeriod: billingPeriod
        )
        var projects = clients[clientIndex].projects
        let existingProject = projects[projectIndex]
        projects[projectIndex] = RatchetProject(
            id: existingProject.id,
            name: existingProject.name,
            tasks: existingProject.tasks + [newTask],
            status: existingProject.status,
            currency: existingProject.currency,
            budget: existingProject.budget,
            budgetUnits: existingProject.budgetUnits,
            hoursPerDay: existingProject.hoursPerDay,
            normalBillingRate: existingProject.normalBillingRate,
            billingPeriod: existingProject.billingPeriod,
            usesProjectInvoiceSequence: existingProject.usesProjectInvoiceSequence,
            contractPoReference: existingProject.contractPoReference,
            startsOn: existingProject.startsOn,
            endsOn: existingProject.endsOn
        )
        clients[clientIndex] = RatchetClient(
            id: clients[clientIndex].id,
            name: clients[clientIndex].name,
            projects: projects,
            email: clients[clientIndex].email,
            phoneNumber: clients[clientIndex].phoneNumber,
            address1: clients[clientIndex].address1,
            town: clients[clientIndex].town,
            postcode: clients[clientIndex].postcode,
            country: clients[clientIndex].country
        )
        return newTask
    }

    public func addClient(
        name: String,
        email: String? = nil,
        phoneNumber: String? = nil,
        address1: String? = nil,
        town: String? = nil,
        postcode: String? = nil,
        country: String? = nil
    ) async throws -> RatchetClient {
        let newClient = RatchetClient(
            id: "client-\(UUID().uuidString.prefix(8))",
            name: name,
            projects: [],
            email: email,
            phoneNumber: phoneNumber,
            address1: address1,
            town: town,
            postcode: postcode,
            country: country
        )
        clients.append(newClient)
        return newClient
    }

    public func addProject(
        name: String,
        clientId: String,
        status: ProjectStatus,
        currency: String,
        budget: Double,
        budgetUnits: BudgetUnits,
        hoursPerDay: Double,
        normalBillingRate: Double,
        billingPeriod: BillingPeriod,
        usesProjectInvoiceSequence: Bool,
        contractPoReference: String? = nil,
        startsOn: Date? = nil,
        endsOn: Date? = nil
    ) async throws -> RatchetProject {
        guard let clientIndex = clients.firstIndex(where: { $0.id == clientId }) else { throw DataStoreError.notFound }

        let newProject = RatchetProject(
            id: "proj-\(UUID().uuidString.prefix(8))",
            name: name,
            tasks: [],
            status: status,
            currency: currency,
            budget: budget,
            budgetUnits: budgetUnits,
            hoursPerDay: hoursPerDay,
            normalBillingRate: normalBillingRate,
            billingPeriod: billingPeriod,
            usesProjectInvoiceSequence: usesProjectInvoiceSequence,
            contractPoReference: contractPoReference,
            startsOn: startsOn,
            endsOn: endsOn
        )
        var projects = clients[clientIndex].projects
        projects.append(newProject)
        clients[clientIndex] = RatchetClient(
            id: clients[clientIndex].id,
            name: clients[clientIndex].name,
            projects: projects,
            email: clients[clientIndex].email,
            phoneNumber: clients[clientIndex].phoneNumber,
            address1: clients[clientIndex].address1,
            town: clients[clientIndex].town,
            postcode: clients[clientIndex].postcode,
            country: clients[clientIndex].country
        )
        return newProject
    }

    public func logTime(
        taskId: String,
        projectId: String,
        clientId: String,
        date: Date,
        hours: Double,
        comment: String? = nil
    ) async throws -> RatchetTimeslip {
        guard let client = clients.first(where: { $0.id == clientId }),
              let project = client.projects.first(where: { $0.id == projectId }),
              project.tasks.contains(where: { $0.id == taskId })
        else { throw DataStoreError.notFound }

        let entry = RatchetTimeslip(
            id: "timeslip-\(UUID().uuidString.prefix(8))",
            clientId: clientId,
            projectId: projectId,
            taskId: taskId,
            date: date,
            hours: hours,
            comment: comment
        )
        timeslips.append(entry)
        return entry
    }

    public func refresh() async throws {
        refreshCount += 1
        lastRefreshedAt = clock()
    }

    public func startTimer(taskId: String, projectId: String, clientId: String) async throws -> RatchetTimeslip {
        guard let client = clients.first(where: { $0.id == clientId }),
              let project = client.projects.first(where: { $0.id == projectId }),
              project.tasks.contains(where: { $0.id == taskId })
        else { throw DataStoreError.notFound }

        // Starting a new timer implicitly stops whichever one was running: `runningTimeslipId`
        // is simply reassigned below, and the old entry keeps whatever hours it had accrued.
        let entry = RatchetTimeslip(
            id: "timeslip-\(UUID().uuidString.prefix(8))",
            clientId: clientId,
            projectId: projectId,
            taskId: taskId,
            date: clock(),
            hours: 0,
            comment: nil
        )
        timeslips.append(entry)
        runningTimeslipId = entry.id
        return entry
    }

    public func stopTimer() async throws -> RatchetTimeslip? {
        guard let runningTimeslipId, let index = timeslips.firstIndex(where: { $0.id == runningTimeslipId }) else {
            return nil
        }
        self.runningTimeslipId = nil
        return timeslips[index]
    }
}
