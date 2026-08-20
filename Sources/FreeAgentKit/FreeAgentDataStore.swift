// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RatchetCore

@MainActor
public final class FreeAgentDataStore: DataStore {
    public private(set) var clients: [RatchetClient] = []
    public private(set) var accountEmail: String = ""
    public private(set) var timeslips: [RatchetTimeslip] = []
    public private(set) var lastRefreshedAt: Date?
    public private(set) var currentRunningTimeslip: RatchetTimeslip?
    /// The signed-in company's own web app URL (e.g. https://acebusiness.sandbox.freeagent.com),
    /// for "Open FreeAgent" — nil until the first successful `refresh()`.
    public private(set) var webAppURL: URL?

    /// How far back `refresh()` fetches timeslips for the "Recent time entries" menu. The menu
    /// only shows the last 20 entries anyway, so this just needs to comfortably cover
    /// "recently logged, including back-dated entries" without fetching a whole history.
    private static let recentTimeslipWindowDays: Double = 14

    private let apiClient: FreeAgentAPIClient
    private let environment: FreeAgentEnvironment
    private let clock: () -> Date
    /// project URL -> client URL, so timeslip DTOs (which only know their
    /// project) can be assigned the right clientId.
    private var projectToClientId: [String: String] = [:]
    private var currentUserURL: String = ""
    /// Bumped on entry to every method that changes server-side state. `refresh()` snapshots it
    /// before its first request and abandons its commit if the value moved, because a refresh's
    /// responses describe the world as of when the server answered them — which, for a request
    /// still in flight when the user starts or stops a timer, is the world *before* that action.
    /// Committing them anyway reinstated it: a stopped timer came back as "tracking" (green
    /// tray, climbing clock, and a Stop that then DELETEs a dead timer), and a just-started one
    /// vanished to idle while FreeAgent went on billing.
    private var mutationEpoch: UInt64 = 0

    /// Called at the *start* of each mutating method, not the end — a refresh whose responses
    /// were computed while a mutation was mid-flight is just as stale as one that predates it.
    private func beginMutation() {
        mutationEpoch &+= 1
    }

    public init(apiClient: FreeAgentAPIClient, environment: FreeAgentEnvironment, clock: @escaping () -> Date = Date.init) {
        self.apiClient = apiClient
        self.environment = environment
        self.clock = clock
    }

    public func refresh() async throws {
        let epoch = mutationEpoch
        // Everything below is built into locals and assigned in the single commit block at the
        // end. The previous shape assigned as it went, so a failure partway through left the
        // store half-new: `clients` replaced while `timeslips` and `currentRunningTimeslip`
        // still described the old world. That combination is exactly what makes a running
        // timeslip unresolvable against the client tree, which used to drop the menu to idle
        // while FreeAgent kept billing.
        let user: FreeAgentUserDTO = try await apiClient.get("users/me", envelopeKey: "user")
        let userURL = user.url

        // Best-effort: "Open FreeAgent" keeps whatever URL it already had if this fails, rather
        // than failing the whole refresh over a menu convenience link.
        let company: FreeAgentCompanyDTO? = try? await apiClient.get("company", envelopeKey: "company")

        // A trailing window rather than today-only: "Recent time entries" is meant to be a short
        // history, and "Log past time" writes entries dated in the past — with a today-only
        // fetch those vanished from the menu on the very next refresh.
        let today = todayString()
        let windowStart = dateString(clock().addingTimeInterval(-Self.recentTimeslipWindowDays * 24 * 60 * 60))

        // All five fetched as one concurrent batch: none depends on another's result, and each
        // is paginated, so running them in sequence made a launch-time refresh cost the sum of
        // every round trip before the menu showed anything. `async let` starts its child task at
        // the declaration, not the `await`, so these all have to be declared together up front.
        async let contactsFetch: [FreeAgentContactDTO] = apiClient.getList("contacts", listKey: "contacts")
        async let projectsFetch: [FreeAgentProjectDTO] = apiClient.getList("projects", listKey: "projects")
        async let tasksFetch: [FreeAgentTaskDTO] = apiClient.getList("tasks", listKey: "tasks")
        async let recentFetch: [FreeAgentTimeslipDTO] = apiClient.getList(
            "timeslips", query: [
                URLQueryItem(name: "from_date", value: windowStart),
                URLQueryItem(name: "to_date", value: today),
                URLQueryItem(name: "user", value: userURL),
            ], listKey: "timeslips"
        )
        async let runningFetch = fetchRunningTimeslipDTO(userURL: userURL)

        let contacts = try await contactsFetch
        let projects = try await projectsFetch
        let tasks = try await tasksFetch
        let recentDTOs = try await recentFetch
        let runningDTO = try await runningFetch

        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter traps at runtime if
        // pagination ever hands back the same project URL twice. "Last write wins" is fine for
        // a duplicate of the same project.
        let newProjectToClientId = Dictionary(projects.map { ($0.url, $0.contact) }, uniquingKeysWith: { _, new in new })
        let tasksByProject = Dictionary(grouping: tasks, by: \.project)
        let projectsByContact = Dictionary(grouping: projects, by: \.contact)

        let newClients = contacts.map { contact in
            let contactProjects = (projectsByContact[contact.url] ?? []).map { project in
                let projectTasks = (tasksByProject[project.url] ?? []).map { $0.toRatchetTask() }
                return project.toRatchetProject(tasks: projectTasks)
            }
            return contact.toRatchetClient(projects: contactProjects)
        }
        // Resolved against the map just built, not the instance property — which is still the
        // *previous* refresh's map until the commit block below.
        // Kept sorted ascending by day so the array has one defined order regardless of what
        // sequence pagination returned; `logTime` preserves it on insert.
        let newTimeslips = recentDTOs.map { resolvedTimeslip($0, using: newProjectToClientId) }.sorted { $0.day < $1.day }
        let newRunning = runningDTO.map { resolvedTimeslip($0, using: newProjectToClientId) }

        // A mutation landed while these responses were in flight, so they describe a superseded
        // world. Drop them — and deliberately don't stamp `lastRefreshedAt`, so the next menu
        // open or wake treats the data as stale and fetches again.
        guard mutationEpoch == epoch else { return }

        // Single commit point: no `await` between here and the end of the function, so no other
        // main-actor work can observe a half-applied refresh.
        accountEmail = user.email
        currentUserURL = userURL
        if let company { webAppURL = environment.webAppURL(subdomain: company.subdomain) }
        projectToClientId = newProjectToClientId
        clients = newClients
        timeslips = newTimeslips
        currentRunningTimeslip = newRunning
        lastRefreshedAt = clock()
    }

    public func startTimer(taskId: String, projectId: String, clientId: String) async throws -> RatchetTimeslip {
        beginMutation()
        // Ask the server first, same as stopTimer()'s fallback: the today-scoped "existing
        // timeslip for this task" query below only finds a timeslip *created* today, not one
        // still running from before midnight — FreeAgent doesn't re-date a timeslip's
        // `dated_on` when its timer crosses a day boundary. Without this check, restarting a
        // timer for the same task after the day rolled over (app restart, some other code path
        // re-invoking start) found nothing "for today" and created a second, duplicate timeslip
        // while the original kept running server-side.
        //
        // Always re-fetched from the server rather than trusting a cached `currentRunningTimeslip`
        // — the cache can outlive the timeslip it names (stopped from the FreeAgent web app,
        // another device, or simply yesterday's timer having ended). Trusting it here meant the
        // same-task branch below returned "success" without a single network call: the menu
        // showed tracking while FreeAgent was never told anything.
        let running = try await fetchRunningTimeslip()
        if let running {
            if running.taskId == taskId {
                // Already running for exactly the task being requested — resume it rather than
                // starting (or creating) a second timeslip. Re-stamped with the caller's
                // `clientId`, matching the two paths below, rather than whatever `running`
                // already carried (from cache, or freshly resolved via `projectToClientId`) —
                // keeps this path consistent with the others if the two ever disagree.
                let resumed = RatchetTimeslip(
                    id: running.id, clientId: clientId, projectId: running.projectId, taskId: running.taskId,
                    day: running.day, timerStartedAt: running.timerStartedAt, hours: running.hours,
                    comment: running.comment, isInvoiced: running.isInvoiced
                )
                currentRunningTimeslip = resumed
                return resumed
            }
            // The menu only ever offers "Start tracking" from the idle screen — never alongside
            // an active .tracking screen — so a running timeslip for a *different* task here
            // means local state has drifted from the server (a timer started from the FreeAgent
            // web app, another device, or a stale cache), not a normal call path. The app has no
            // multi-timer support (see TODO.md), so surface this rather than silently stopping
            // someone else's/another device's timer out from under them.
            // "Stop it first" has no menu route from the idle screen (only "Switch task", on the
            // tracking screen, offers a stop) — pointing at Refresh gives the idle-screen user
            // an actual next step: it re-adopts the drifted timer so it shows as tracking here,
            // and only then does "Stop tracking" exist to act on it.
            throw DataStoreError.underlying("A timer is already running for another task elsewhere. Choose Refresh, then stop it from there.")
        }

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
        if started.timer?.running == false {
            // Distinct from the "object omitted" case handled below: the server answered with a
            // `timer` object and explicitly said it isn't running, i.e. the POST didn't actually
            // start anything. Stamping `clock()` for this would present a dead timer as running
            // since now — the one shape that made the "omitted means just-started" assumption
            // below unsafe — so surface it as a failure instead.
            throw DataStoreError.underlying("FreeAgent didn't start the timer — try again.")
        }
        var resolved = resolvedTimeslip(started, clientId: clientId)
        if resolved.timerStartedAt == nil {
            // The timer object was omitted altogether (not explicitly running:false, ruled out
            // above), and this call is what started it — so "now" is accurate to the round trip.
            // Without this the elapsed baseline fell back to whatever `day` holds (local
            // midnight), and a timer begun seconds ago displayed hours of elapsed time.
            resolved = RatchetTimeslip(
                id: resolved.id, clientId: resolved.clientId, projectId: resolved.projectId,
                taskId: resolved.taskId, day: resolved.day, timerStartedAt: clock(),
                hours: resolved.hours, comment: resolved.comment, isInvoiced: resolved.isInvoiced
            )
        }
        currentRunningTimeslip = resolved
        return resolved
    }

    public func stopTimer() async throws -> RatchetTimeslip? {
        beginMutation()
        // Falling straight through to `return nil` on an empty cache was a silent failure with
        // real money attached: the caller discards the result and drops the UI to idle either
        // way, so a timer the cache had lost (a refresh that raced the running-view query, a
        // timer started from the FreeAgent web app) kept running server-side and accrued
        // billable hours with nothing in the menu to suggest it. Ask the server before believing
        // there's nothing to stop.
        let running: RatchetTimeslip
        if let cached = currentRunningTimeslip {
            running = cached
        } else if let found = try await fetchRunningTimeslip() {
            running = found
        } else {
            return nil
        }
        try await apiClient.delete("\(running.id)/timer")
        currentRunningTimeslip = nil
        return running
    }

    /// The authoritative "is anything running for this user" query, shared by `refresh()` and
    /// `stopTimer()`'s fallback. Returns the raw DTO rather than resolving it to a
    /// `RatchetTimeslip` — `refresh()` runs this concurrently with the projects fetch that
    /// `resolvedTimeslip` depends on, so resolution has to happen after that fetch is awaited,
    /// not inside this function.
    private func fetchRunningTimeslipDTO(userURL: String? = nil) async throws -> FreeAgentTimeslipDTO? {
        let running: [FreeAgentTimeslipDTO] = try await apiClient.getList(
            "timeslips", query: [
                URLQueryItem(name: "view", value: "running"),
                URLQueryItem(name: "user", value: userURL ?? currentUserURL),
            ], listKey: "timeslips"
        )
        return running.first
    }

    private func fetchRunningTimeslip() async throws -> RatchetTimeslip? {
        try await fetchRunningTimeslipDTO().map { resolvedTimeslip($0) }
    }

    public func addClient(
        organisationName: String?, firstName: String?, lastName: String?,
        email: String?, phoneNumber: String?, address1: String?,
        town: String?, postcode: String?, country: String?
    ) async throws -> RatchetClient {
        beginMutation()
        struct CreateContactBody: Encodable {
            let organisation_name: String?
            let first_name: String?
            let last_name: String?
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
                organisation_name: organisationName, first_name: firstName, last_name: lastName,
                email: email, phone_number: phoneNumber,
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
        beginMutation()
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
            let starts_on: String?
            let ends_on: String?
        }
        let created: FreeAgentProjectDTO = try await apiClient.post(
            "projects", envelopeKey: "project",
            body: CreateProjectBody(
                contact: clientId, name: name, status: status.rawValue, currency: currency,
                budget: String(budget), budget_units: budgetUnits.rawValue,
                hours_per_day: String(hoursPerDay), normal_billing_rate: String(normalBillingRate),
                billing_period: billingPeriod.rawValue, uses_project_invoice_sequence: usesProjectInvoiceSequence,
                contract_po_reference: contractPoReference,
                starts_on: startsOn.map(dateString), ends_on: endsOn.map(dateString)
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
        beginMutation()
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
        beginMutation()
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
        // Inserted in date order, not appended: a back-dated entry appended to the end would
        // read as the newest thing in the array, which is exactly how it used to jump to the
        // top of "Recent time entries" until the next refresh reshuffled it.
        let insertionIndex = timeslips.firstIndex { $0.day > resolved.day } ?? timeslips.endIndex
        timeslips.insert(resolved, at: insertionIndex)
        return resolved
    }

    public func updateTimeslip(
        id: String, taskId: String, projectId: String, clientId: String, date: Date, hours: Double, comment: String?
    ) async throws -> RatchetTimeslip {
        beginMutation()
        // Same body shape as `logTime`'s create — FreeAgent's timeslip PUT takes the full
        // record, not a partial patch, so reassigning the task means resending project/task too.
        struct UpdateTimeslipBody: Encodable {
            let project: String
            let task: String
            let user: String
            let dated_on: String
            let hours: String
            let comment: String?
        }
        let updated: FreeAgentTimeslipDTO = try await apiClient.put(
            id, envelopeKey: "timeslip",
            body: UpdateTimeslipBody(
                project: projectId, task: taskId, user: currentUserURL,
                dated_on: dateString(date), hours: String(hours), comment: comment
            )
        )
        let resolved = resolvedTimeslip(updated, clientId: clientId)
        // A PUT response that omits the `timer` object doesn't mean the timer stopped —
        // FreeAgent doesn't always echo it back on this endpoint — so when this slip is the one
        // actually running, carry its previously known start instant forward rather than letting
        // a bare PUT null it out in the cache. Nothing reads `currentRunningTimeslip.
        // timerStartedAt` today, but later reconciliation work reads from this same cache, so a
        // silently dropped start instant here is a live trap for whichever of those ends up
        // trusting it for elapsed time.
        let reconciled: RatchetTimeslip
        if resolved.timerStartedAt == nil, let stillRunning = currentRunningTimeslip, stillRunning.id == id,
           let preserved = stillRunning.timerStartedAt {
            reconciled = RatchetTimeslip(
                id: resolved.id, clientId: resolved.clientId, projectId: resolved.projectId,
                taskId: resolved.taskId, day: resolved.day, timerStartedAt: preserved,
                hours: resolved.hours, comment: resolved.comment, isInvoiced: resolved.isInvoiced
            )
        } else {
            reconciled = resolved
        }
        // Replaced in place if still cached, rather than assuming it must be — an edit from a
        // stale menu (built before the entry aged out of the `refresh()` window, or from a
        // duplicate submenu still open after the underlying array changed) shouldn't silently
        // reinsert a slip the local cache had already dropped.
        if let index = timeslips.firstIndex(where: { $0.id == id }) {
            timeslips[index] = reconciled
        }
        // `currentRunningTimeslip` is a separate stored property, not derived from `timeslips`
        // — "Switch task" edits a *running* timeslip's task in place (see `StatusItemController.
        // switchTask`) without stopping its timer, so without this the cache would keep
        // pointing at the pre-edit task/project/client until the next `refresh()`.
        if currentRunningTimeslip?.id == id {
            currentRunningTimeslip = reconciled
        }
        return reconciled
    }

    // MARK: - Private helpers

    private func resolvedTimeslip(_ dto: FreeAgentTimeslipDTO, using projectMap: [String: String], clientId: String? = nil) -> RatchetTimeslip {
        let resolvedClientId = clientId ?? projectMap[dto.project] ?? ""
        let mapped = dto.toRatchetTimeslip()
        return RatchetTimeslip(
            id: mapped.id, clientId: resolvedClientId, projectId: mapped.projectId,
            taskId: mapped.taskId, day: mapped.day, timerStartedAt: mapped.timerStartedAt,
            hours: mapped.hours, comment: mapped.comment, isInvoiced: mapped.isInvoiced
        )
    }

    /// The committed-state resolver, for the mutating calls that run outside `refresh()`.
    private func resolvedTimeslip(_ dto: FreeAgentTimeslipDTO, clientId: String? = nil) -> RatchetTimeslip {
        resolvedTimeslip(dto, using: projectToClientId, clientId: clientId)
    }

    private func withAppendedProject(_ client: RatchetClient, _ project: RatchetProject) -> RatchetClient {
        client.withProjects(client.projects + [project])
    }

    private func withAppendedTask(_ client: RatchetClient, projectIndex: Int, task: RatchetTask) -> RatchetClient {
        let existing = client.projects[projectIndex]
        return client.replacingProject(at: projectIndex, with: existing.withTasks(existing.tasks + [task]))
    }

    private func todayString() -> String { dateString(clock()) }

    /// `dated_on` is a plain calendar day — "the day you did the work" — so it has to be the
    /// user's local day. This used to pin the formatter to UTC, which booked a Los Angeles
    /// user's evening entry to the following day, and made an Auckland user's "today" resolve
    /// to yesterday (so the today-filter below missed today's timeslip and created a duplicate).
    private func dateString(_ date: Date) -> String {
        CalendarDay.dayString(from: date)
    }
}
