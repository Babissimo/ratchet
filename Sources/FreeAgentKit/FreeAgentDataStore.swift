import Foundation
import RatchetCore

@MainActor
public final class FreeAgentDataStore: DataStore {
    public private(set) var clients: [RatchetClient] = []
    public private(set) var accountEmail: String = ""
    public private(set) var timeslips: [RatchetTimeslip] = []
    public private(set) var lastRefreshedAt: Date?
    public private(set) var currentRunningTimeslip: RatchetTimeslip?

    /// How far back `refresh()` fetches timeslips for the "Recent time entries" menu. The menu
    /// only shows the last 20 entries anyway, so this just needs to comfortably cover
    /// "recently logged, including back-dated entries" without fetching a whole history.
    private static let recentTimeslipWindowDays: Double = 14

    private let apiClient: FreeAgentAPIClient
    private let clock: () -> Date
    /// project URL -> client URL, so timeslip DTOs (which only know their
    /// project) can be assigned the right clientId.
    private var projectToClientId: [String: String] = [:]
    private var currentUserURL: String = ""

    public init(apiClient: FreeAgentAPIClient, clock: @escaping () -> Date = Date.init) {
        self.apiClient = apiClient
        self.clock = clock
    }

    public func refresh() async throws {
        let user: FreeAgentUserDTO = try await apiClient.get("users/me", envelopeKey: "user")
        accountEmail = user.email
        currentUserURL = user.url

        let contacts: [FreeAgentContactDTO] = try await apiClient.getList("contacts", listKey: "contacts")
        let projects: [FreeAgentProjectDTO] = try await apiClient.getList("projects", listKey: "projects")
        let tasks: [FreeAgentTaskDTO] = try await apiClient.getList("tasks", listKey: "tasks")

        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter traps at runtime if
        // pagination ever hands back the same project URL twice (e.g. a page boundary served
        // twice). "Last write wins" is a fine outcome for a duplicate of the same project.
        projectToClientId = Dictionary(projects.map { ($0.url, $0.contact) }, uniquingKeysWith: { _, new in new })

        let tasksByProject = Dictionary(grouping: tasks, by: \.project)
        let projectsByContact = Dictionary(grouping: projects, by: \.contact)

        clients = contacts.map { contact in
            let contactProjects = (projectsByContact[contact.url] ?? []).map { project in
                let projectTasks = (tasksByProject[project.url] ?? []).map { $0.toRatchetTask() }
                return project.toRatchetProject(tasks: projectTasks)
            }
            return contact.toRatchetClient(projects: contactProjects)
        }

        // A trailing window rather than today-only: the menu's "Recent time entries" list is
        // meant to be a short history, and "Log past time" writes entries dated in the past —
        // with a today-only fetch those vanished from the menu on the very next refresh.
        let today = todayString()
        let windowStart = dateString(clock().addingTimeInterval(-Self.recentTimeslipWindowDays * 24 * 60 * 60))
        let recentTimeslips: [FreeAgentTimeslipDTO] = try await apiClient.getList(
            "timeslips", query: [
                URLQueryItem(name: "from_date", value: windowStart),
                URLQueryItem(name: "to_date", value: today),
                URLQueryItem(name: "user", value: currentUserURL),
            ], listKey: "timeslips"
        )
        timeslips = recentTimeslips.map { resolvedTimeslip($0) }

        let runningTimeslips: [FreeAgentTimeslipDTO] = try await apiClient.getList(
            "timeslips", query: [
                URLQueryItem(name: "view", value: "running"),
                URLQueryItem(name: "user", value: currentUserURL),
            ], listKey: "timeslips"
        )
        currentRunningTimeslip = runningTimeslips.first.map { resolvedTimeslip($0) }

        lastRefreshedAt = clock()
    }

    public func startTimer(taskId: String, projectId: String, clientId: String) async throws -> RatchetTimeslip {
        let today = todayString()
        let existing: [FreeAgentTimeslipDTO] = try await apiClient.getList(
            "timeslips", query: [
                URLQueryItem(name: "task", value: taskId),
                URLQueryItem(name: "project", value: projectId),
                URLQueryItem(name: "from_date", value: today),
                URLQueryItem(name: "to_date", value: today),
                URLQueryItem(name: "user", value: currentUserURL),
            ], listKey: "timeslips"
        )

        let timeslipURL: String
        if let found = existing.first {
            timeslipURL = found.url
        } else {
            struct CreateTimeslipBody: Encodable {
                let project: String
                let task: String
                let user: String
                let dated_on: String
                let hours: String
            }
            let created: FreeAgentTimeslipDTO = try await apiClient.post(
                "timeslips", envelopeKey: "timeslip",
                body: CreateTimeslipBody(project: projectId, task: taskId, user: currentUserURL, dated_on: today, hours: "0.0")
            )
            timeslipURL = created.url
        }

        struct EmptyBody: Encodable {}
        let started: FreeAgentTimeslipDTO = try await apiClient.post(
            "\(timeslipURL)/timer", envelopeKey: "timer", responseEnvelopeKey: "timeslip", body: EmptyBody()
        )
        let resolved = resolvedTimeslip(started, clientId: clientId)
        currentRunningTimeslip = resolved
        return resolved
    }

    public func stopTimer() async throws -> RatchetTimeslip? {
        guard let running = currentRunningTimeslip else { return nil }
        try await apiClient.delete("\(running.id)/timer")
        currentRunningTimeslip = nil
        return running
    }

    public func addClient(
        name: String, email: String?, phoneNumber: String?, address1: String?,
        town: String?, postcode: String?, country: String?
    ) async throws -> RatchetClient {
        struct CreateContactBody: Encodable {
            let organisation_name: String?
            let email: String?
            let phone_number: String?
            let address1: String?
            let town: String?
            let postcode: String?
            let country: String?
        }
        let created: FreeAgentContactDTO = try await apiClient.post(
            "contacts", envelopeKey: "contact",
            body: CreateContactBody(
                organisation_name: name, email: email, phone_number: phoneNumber,
                address1: address1, town: town, postcode: postcode, country: country
            )
        )
        let client = created.toRatchetClient(projects: [])
        clients.append(client)
        return client
    }

    public func addProject(
        name: String, clientId: String, status: ProjectStatus, currency: String,
        budget: Double, budgetUnits: BudgetUnits, hoursPerDay: Double,
        normalBillingRate: Double, billingPeriod: BillingPeriod,
        usesProjectInvoiceSequence: Bool, contractPoReference: String?,
        startsOn: Date?, endsOn: Date?
    ) async throws -> RatchetProject {
        struct CreateProjectBody: Encodable {
            let contact: String
            let name: String
            let status: String
            let currency: String
            let budget: String
            let budget_units: String
            let hours_per_day: String
            let normal_billing_rate: String
            let billing_period: String
            let uses_project_invoice_sequence: Bool
            let contract_po_reference: String?
        }
        let created: FreeAgentProjectDTO = try await apiClient.post(
            "projects", envelopeKey: "project",
            body: CreateProjectBody(
                contact: clientId, name: name, status: status.rawValue, currency: currency,
                budget: String(budget), budget_units: budgetUnits.rawValue,
                hours_per_day: String(hoursPerDay), normal_billing_rate: String(normalBillingRate),
                billing_period: billingPeriod.rawValue, uses_project_invoice_sequence: usesProjectInvoiceSequence,
                contract_po_reference: contractPoReference
            )
        )
        projectToClientId[created.url] = clientId
        let project = created.toRatchetProject(tasks: [])
        guard let clientIndex = clients.firstIndex(where: { $0.id == clientId }) else { throw DataStoreError.notFound }
        clients[clientIndex] = withAppendedProject(clients[clientIndex], project)
        return project
    }

    public func addTask(
        name: String, projectId: String, clientId: String, isBillable: Bool,
        status: TaskStatus, billingRate: Double?, billingPeriod: BillingPeriod?
    ) async throws -> RatchetTask {
        struct CreateTaskBody: Encodable {
            let name: String
            let is_billable: Bool
            let status: String
            let billing_rate: String?
            let billing_period: String?
        }
        let created: FreeAgentTaskDTO = try await apiClient.post(
            "tasks", envelopeKey: "task",
            query: [URLQueryItem(name: "project", value: projectId)],
            body: CreateTaskBody(
                name: name, is_billable: isBillable, status: status.rawValue,
                billing_rate: billingRate.map { String($0) }, billing_period: billingPeriod?.rawValue
            )
        )
        let task = created.toRatchetTask()
        guard let clientIndex = clients.firstIndex(where: { $0.id == clientId }),
              let projectIndex = clients[clientIndex].projects.firstIndex(where: { $0.id == projectId })
        else { throw DataStoreError.notFound }
        clients[clientIndex] = withAppendedTask(clients[clientIndex], projectIndex: projectIndex, task: task)
        return task
    }

    public func logTime(
        taskId: String, projectId: String, clientId: String, date: Date, hours: Double, comment: String?
    ) async throws -> RatchetTimeslip {
        struct CreateTimeslipBody: Encodable {
            let project: String
            let task: String
            let user: String
            let dated_on: String
            let hours: String
            let comment: String?
        }
        let created: FreeAgentTimeslipDTO = try await apiClient.post(
            "timeslips", envelopeKey: "timeslip",
            body: CreateTimeslipBody(
                project: projectId, task: taskId, user: currentUserURL,
                dated_on: dateString(date), hours: String(hours), comment: comment
            )
        )
        let resolved = resolvedTimeslip(created, clientId: clientId)
        timeslips.append(resolved)
        return resolved
    }

    // MARK: - Private helpers

    private func resolvedTimeslip(_ dto: FreeAgentTimeslipDTO, clientId: String? = nil) -> RatchetTimeslip {
        let resolvedClientId = clientId ?? projectToClientId[dto.project] ?? ""
        let mapped = dto.toRatchetTimeslip()
        return RatchetTimeslip(
            id: mapped.id, clientId: resolvedClientId, projectId: mapped.projectId,
            taskId: mapped.taskId, date: mapped.date, hours: mapped.hours, comment: mapped.comment
        )
    }

    private func withAppendedProject(_ client: RatchetClient, _ project: RatchetProject) -> RatchetClient {
        RatchetClient(
            id: client.id, name: client.name, projects: client.projects + [project],
            email: client.email, phoneNumber: client.phoneNumber, address1: client.address1,
            town: client.town, postcode: client.postcode, country: client.country
        )
    }

    private func withAppendedTask(_ client: RatchetClient, projectIndex: Int, task: RatchetTask) -> RatchetClient {
        var projects = client.projects
        let existing = projects[projectIndex]
        projects[projectIndex] = RatchetProject(
            id: existing.id, name: existing.name, tasks: existing.tasks + [task],
            status: existing.status, currency: existing.currency, budget: existing.budget,
            budgetUnits: existing.budgetUnits, hoursPerDay: existing.hoursPerDay,
            normalBillingRate: existing.normalBillingRate, billingPeriod: existing.billingPeriod,
            usesProjectInvoiceSequence: existing.usesProjectInvoiceSequence,
            contractPoReference: existing.contractPoReference, startsOn: existing.startsOn, endsOn: existing.endsOn
        )
        return RatchetClient(
            id: client.id, name: client.name, projects: projects,
            email: client.email, phoneNumber: client.phoneNumber, address1: client.address1,
            town: client.town, postcode: client.postcode, country: client.country
        )
    }

    private func todayString() -> String { dateString(clock()) }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
