// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import RatchetCore

@MainActor
final class FakeDataStore: DataStore {
    private(set) var clients: [RatchetClient]
    let accountEmail: String
    private(set) var refreshCount = 0
    /// Set by tests to make the next `refresh()` call throw instead of succeeding, simulating a
    /// network failure or a dead session (via `FakeSessionExpiredError`).
    var refreshError: Error?
    private(set) var timeslips: [RatchetTimeslip] = []
    private(set) var lastRefreshedAt: Date?
    let webAppURL: URL? = URL(string: "https://app.freeagent.com")

    /// id of the timeslip with a currently-running timer, if any.
    private var runningTimeslipId: String?

    /// Computed, not stored: `runningTimeslipId` is the single source of truth (kept in sync by
    /// `startTimer`/`stopTimer`), so deriving this from it — same as `FreeAgentDataStore` derives
    /// its own stored property from the API's running-timeslip response — rules out the two ever
    /// disagreeing.
    var currentRunningTimeslip: RatchetTimeslip? {
        guard let runningTimeslipId else { return nil }
        return timeslips.first { $0.id == runningTimeslipId }
    }

    private let clock: () -> Date

    init(clients: [RatchetClient], accountEmail: String, timeslips: [RatchetTimeslip] = [], clock: @escaping () -> Date = Date.init) {
        self.clients = clients
        self.accountEmail = accountEmail
        self.timeslips = timeslips
        self.clock = clock
    }

    /// Test-only seam: directly sets the "Recent time entries" backing array and, optionally,
    /// which of those entries is the one with a running timer — mirroring how `refresh()`
    /// populates both from the API without going through `startTimer`'s day-matching logic.
    func seedTimeslips(_ entries: [RatchetTimeslip], runningId: String? = nil) {
        timeslips = entries
        runningTimeslipId = runningId
    }

    static func seeded(timeslips: [RatchetTimeslip] = []) -> FakeDataStore {
        let developmentTask = RatchetTask(id: "task-1", name: "Development")
        let designTask = RatchetTask(id: "task-2", name: "Design")
        let websiteProject = RatchetProject(id: "proj-1", name: "Website Redesign", tasks: [developmentTask, designTask])
        let copywritingTask = RatchetTask(id: "task-3", name: "Copywriting")
        let retainerProject = RatchetProject(id: "proj-2", name: "Q3 Retainer", tasks: [copywritingTask])
        let acme = RatchetClient(id: "client-1", name: "Acme", projects: [websiteProject, retainerProject])
        let otherCo = RatchetClient(id: "client-2", name: "Other Co", projects: [])
        return FakeDataStore(clients: [acme, otherCo], accountEmail: "al@example.com", timeslips: timeslips)
    }

    func addTask(
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
        let existingProject = clients[clientIndex].projects[projectIndex]
        let updatedProject = existingProject.withTasks(existingProject.tasks + [newTask])
        clients[clientIndex] = clients[clientIndex].replacingProject(at: projectIndex, with: updatedProject)
        return newTask
    }

    func addClient(
        organisationName: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        email: String? = nil,
        phoneNumber: String? = nil,
        address1: String? = nil,
        town: String? = nil,
        postcode: String? = nil,
        country: String? = nil
    ) async throws -> RatchetClient {
        // Mirrors FreeAgentContactDTO.displayName, for the same reason the fake mirrors the
        // real store's timer-reuse semantics: a fake that names clients differently from the
        // real one lets a display-name regression pass its tests.
        let displayName = organisationName.flatMap { $0.isEmpty ? nil : $0 }
            ?? [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        let newClient = RatchetClient(
            id: "client-\(UUID().uuidString.prefix(8))",
            name: displayName,
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

    func addProject(
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
        clients[clientIndex] = clients[clientIndex].withProjects(clients[clientIndex].projects + [newProject])
        return newProject
    }

    func logTime(
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

    func updateTimeslip(
        id: String,
        taskId: String,
        projectId: String,
        clientId: String,
        date: Date,
        hours: Double,
        comment: String? = nil
    ) async throws -> RatchetTimeslip {
        guard let index = timeslips.firstIndex(where: { $0.id == id }) else { throw DataStoreError.notFound }
        guard let client = clients.first(where: { $0.id == clientId }),
              let project = client.projects.first(where: { $0.id == projectId }),
              project.tasks.contains(where: { $0.id == taskId })
        else { throw DataStoreError.notFound }

        let updated = RatchetTimeslip(
            id: id, clientId: clientId, projectId: projectId, taskId: taskId,
            date: date, hours: hours, comment: comment
        )
        timeslips[index] = updated
        return updated
    }

    func refresh() async throws {
        if let refreshError {
            throw refreshError
        }
        refreshCount += 1
        lastRefreshedAt = clock()
    }

    func startTimer(taskId: String, projectId: String, clientId: String) async throws -> RatchetTimeslip {
        guard let client = clients.first(where: { $0.id == clientId }),
              let project = client.projects.first(where: { $0.id == projectId }),
              project.tasks.contains(where: { $0.id == taskId })
        else { throw DataStoreError.notFound }

        // Mirrors FreeAgentDataStore.startTimer's conflict guard: a running timeslip for a
        // *different* task means local/server state drifted (the menu never offers "Start" for
        // a task other than the one already tracking), so this throws instead of implicitly
        // switching — a fake that silently switched let a regression in the real guard sail
        // through any test written against this one.
        if let runningTimeslipId, let running = timeslips.first(where: { $0.id == runningTimeslipId }), running.taskId != taskId {
            throw DataStoreError.underlying("A timer is already running for another task elsewhere. Choose Refresh, then stop it from there.")
        }

        // Deliberately mirrors FreeAgentDataStore.startTimer: resume today's existing timeslip for
        // this task instead of opening a second one, creating a slip only when none exists. A fake
        // that always appended made the resume path untestable — every "start, stop, start again"
        // test passed against two fresh zero-hour slips, so a regression that duplicated the day's
        // timeslip (and split the accrued hours across two entries) would sail through the suite.
        //
        // Matched on the *calendar day*, not `Date` equality, because the real store's filter is a
        // `dated_on` day string: two starts hours apart on the same local day must collide, which
        // raw `Date ==` would never do. `clock()` is the single source of "now" here so a test that
        // injects a clock can straddle midnight and see the same boundary the real store sees.
        let today = CalendarDay.dayString(from: clock())
        if let index = timeslips.firstIndex(where: {
            $0.taskId == taskId && $0.projectId == projectId && CalendarDay.dayString(from: $0.date) == today
        }) {
            runningTimeslipId = timeslips[index].id
            return timeslips[index]
        }

        // Nothing was running (the guard above would have thrown or resumed otherwise), so this
        // is a genuinely fresh start — `runningTimeslipId` is simply assigned below.
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

    func stopTimer() async throws -> RatchetTimeslip? {
        guard let runningTimeslipId, let index = timeslips.firstIndex(where: { $0.id == runningTimeslipId }) else {
            return nil
        }
        self.runningTimeslipId = nil
        return timeslips[index]
    }
}
