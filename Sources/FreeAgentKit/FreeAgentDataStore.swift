// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RatchetCore

/// `value` as the forms enter it: trimmed, and absent when empty, so it matches the null or ""
/// FreeAgent may hold for an absent one.
private func asEntered(_ value: String?) -> String? {
    TaskNameValidator.validate(value ?? "")
}

/// A timeslip as `POST /timeslips` and `PUT /timeslips/:id` take it. A create is identified by
/// its whole body, so only an identical retry is matched to one whose outcome is unknown.
private struct TimeslipBody: Encodable, CreateIdentity {
    static let made = DataStoreError.Resource.timeslip
    let project: String
    let task: String
    let user: String
    let dated_on: String
    let hours: String
    let comment: String?

    /// Whether `dto` records this entry. Hours compare numerically to within half a minute,
    /// since FreeAgent echoes the decimal it stored rather than the string sent.
    func identifies(_ dto: FreeAgentTimeslipDTO) -> Bool {
        guard dto.user == user, dto.project == project, dto.task == task, dto.datedOn == dated_on,
              let sent = Double(hours), let stored = Double(dto.hours), abs(sent - stored) < 1.0 / 120
        else { return false }
        return asEntered(comment) == asEntered(dto.comment)
    }
}

// The identities below hold names as entered, so the key a retry is matched by and the test a
// listed resource must pass are the same comparison.

/// A new contact, identified as the forms name it: by its organisation, or by first and last name
/// when it has none. An organisation's contact person is optional, so a retry may omit it.
private struct ContactIdentity: CreateIdentity {
    static let made = DataStoreError.Resource.client
    let organisationName: String?
    let firstName: String?
    let lastName: String?

    init(organisationName: String?, firstName: String?, lastName: String?) {
        self.organisationName = asEntered(organisationName)
        let isPerson = self.organisationName == nil
        self.firstName = isPerson ? asEntered(firstName) : nil
        self.lastName = isPerson ? asEntered(lastName) : nil
    }

    func identifies(_ dto: FreeAgentContactDTO) -> Bool {
        self == ContactIdentity(organisationName: dto.organisationName, firstName: dto.firstName, lastName: dto.lastName)
    }
}

/// A new project, identified by its name under its contact.
private struct ProjectIdentity: CreateIdentity {
    static let made = DataStoreError.Resource.project
    let contact: String
    let name: String?

    init(contact: String, name: String) {
        self.contact = contact
        self.name = asEntered(name)
    }

    func identifies(_ dto: FreeAgentProjectDTO) -> Bool {
        self == ProjectIdentity(contact: dto.contact, name: dto.name)
    }
}

/// A new task, identified by its name under its project.
private struct TaskIdentity: CreateIdentity {
    static let made = DataStoreError.Resource.task
    let project: String
    let name: String?

    init(project: String, name: String) {
        self.project = project
        self.name = asEntered(name)
    }

    func identifies(_ dto: FreeAgentTaskDTO) -> Bool {
        self == TaskIdentity(project: dto.project, name: dto.name)
    }
}

@MainActor
public final class FreeAgentDataStore: DataStore {
    public private(set) var clients: [RatchetClient] = []
    public private(set) var accountEmail: String = ""
    public private(set) var timeslips: [RatchetTimeslip] = []
    public private(set) var lastRefreshedAt: Date?
    public private(set) var hasLocalWritesSinceRefresh: Bool = false
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
    private let timeslipCreates: RetrySafeCreates<TimeslipBody>
    private let contactCreates: RetrySafeCreates<ContactIdentity>
    private let projectCreates: RetrySafeCreates<ProjectIdentity>
    private let taskCreates: RetrySafeCreates<TaskIdentity>
    /// project URL -> client URL, so timeslip DTOs (which only know their
    /// project) can be assigned the right clientId.
    private var projectToClientId: [String: String] = [:]
    private var currentUserURL: String = ""
    /// Bumped as each mutating method exits, by any path. A refresh discards its result if this
    /// has moved since it began, or if `mutationsInFlight` is non-zero when it would commit: its
    /// responses may then predate a mutation's effect on the server, and committing them would
    /// overwrite what the mutation wrote locally (as `stopTimer` clears the running timer before
    /// it re-reads the stopped one).
    private var mutationEpoch: UInt64 = 0
    private var mutationsInFlight = 0

    /// Wraps a mutating method's whole body, so each is counted in `mutationsInFlight` while it
    /// runs and bumps `mutationEpoch` as it exits.
    private func withMutation<T>(_ body: () async throws -> T) async rethrows -> T {
        mutationsInFlight += 1
        defer {
            mutationsInFlight -= 1
            mutationEpoch &+= 1
            // On a throw too, since a write that failed partway may still have changed server
            // state.
            hasLocalWritesSinceRefresh = true
        }
        return try await body()
    }

    /// Every write interpolates `currentUserURL` into a body or query, and it is "" until the
    /// first successful `refresh()`. An empty `user=` filter is not a harmless no-op: it asks
    /// FreeAgent to file an entry against no user, or — on the running-timeslip query — to
    /// answer for the whole company, which would let Ratchet adopt or stop a colleague's timer.
    private func requireUserURL() throws -> String {
        guard !currentUserURL.isEmpty else {
            throw DataStoreError.underlying("Ratchet hasn't loaded your FreeAgent account yet — choose Refresh and try again.")
        }
        return currentUserURL
    }

    public init(apiClient: FreeAgentAPIClient, environment: FreeAgentEnvironment, clock: @escaping () -> Date = Date.init) {
        self.apiClient = apiClient
        self.environment = environment
        self.clock = clock
        timeslipCreates = RetrySafeCreates(apiClient: apiClient, clock: clock)
        contactCreates = RetrySafeCreates(apiClient: apiClient, clock: clock)
        projectCreates = RetrySafeCreates(apiClient: apiClient, clock: clock)
        taskCreates = RetrySafeCreates(apiClient: apiClient, clock: clock)
    }

    /// Tracks an in-flight `refresh()` so concurrent callers share one round trip. Same idiom as
    /// `FreeAgentAPIClient.refreshTokensShared` — see its doc comment.
    ///
    /// Nothing serialized these before: the launch-time refresh (`AppDelegate`) and the
    /// post-login refresh (`StatusItemController`'s `logIn` action) call `refresh()` directly,
    /// setting neither `isSilentlyRefreshing` nor anything else. Launch with stored tokens, then
    /// open the menu before the launch refresh finishes, and `menuWillOpen` — seeing
    /// `lastRefreshedAt == nil` — starts a second, fully concurrent `refresh()`. `refresh()`
    /// itself never bumped `mutationEpoch`, so neither call's epoch guard trips on the other;
    /// the loser's single commit block simply overwrites the winner's wholesale and stamps
    /// `lastRefreshedAt` fresh, hiding the staleness behind `silentlyRefreshIfStale()`'s
    /// 120-second gate rather than actually resolving it.
    private var inFlightRefresh: Task<Void, Error>?

    public func refresh() async throws {
        if let existing = inFlightRefresh {
            return try await existing.value
        }
        let task = Task<Void, Error> { [self] in
            try await performRefresh()
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    private func performRefresh() async throws {
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

        // A mutation overlapped these responses, so they may describe a superseded world. Drop
        // them without stamping `lastRefreshedAt`; the mutation's exit sets
        // `hasLocalWritesSinceRefresh`, so the next menu open or wake fetches again.
        guard mutationEpoch == epoch, mutationsInFlight == 0 else { return }

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
        hasLocalWritesSinceRefresh = false
    }

    /// The last `startTimer` call queued. Starts run one at a time: two at once can each find no
    /// timeslip for today and create one apiece, leaving both billing.
    private var lastStart: Task<RatchetTimeslip, Error>?

    public func startTimer(taskId: String, projectId: String, clientId: String) async throws -> RatchetTimeslip {
        let previous = lastStart
        let start = Task { [self] in
            _ = try? await previous?.value
            return try await performStartTimer(taskId: taskId, projectId: projectId, clientId: clientId)
        }
        lastStart = start
        return try await start.value
    }

    private func performStartTimer(taskId: String, projectId: String, clientId: String) async throws -> RatchetTimeslip {
        // The idle screen offers the remembered task before the launch refresh lands, so a start
        // can arrive before the account is known. Join or run that refresh first, outside the
        // mutation, since a refresh that commits while one is in flight discards its result.
        if currentUserURL.isEmpty { try await refresh() }
        return try await withMutation {
            let userURL = try requireUserURL()
            // Ask the server first, same as stopTimer()'s unconditional check: the today-scoped
            // "existing timeslip for this task" query below only finds a timeslip *created* today, not one
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
                    let resumed = running.withClientId(clientId)
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
            let existing = try await sameDayTimeslips(task: taskId, project: projectId, day: today, user: userURL)

            let timeslipURL: String
            if let found = existing.first {
                timeslipURL = found.url
            } else {
                let created: FreeAgentTimeslipDTO = try await apiClient.post(
                    "timeslips", envelopeKey: "timeslip",
                    body: TimeslipBody(project: projectId, task: taskId, user: userURL, dated_on: today, hours: "0.0", comment: nil)
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
                resolved = resolved.withTimerStartedAt(clock())
            }
            currentRunningTimeslip = resolved
            return resolved
        }
    }

    public func stopTimer() async throws -> RatchetTimeslip? {
        try await withMutation {
            // Always the server, never the cache. The old code only queried when the cache was
            // empty — but a cache naming the *wrong* timeslip is the dangerous case, not the
            // absent one: it DELETEd a timer that had already been stopped elsewhere, reported
            // success, and left the timer that was genuinely running to bill on unnoticed.
            guard let running = try await fetchRunningTimeslip() else {
                currentRunningTimeslip = nil
                return nil
            }
            try await apiClient.delete("\(running.id)/timer")
            currentRunningTimeslip = nil

            // Re-read rather than reuse `running`: a running timeslip's `hours` reflects the last
            // pause, so only the stopped one carries the real total.
            let stopped: RatchetTimeslip
            if let settled: FreeAgentTimeslipDTO = try? await apiClient.get(running.id, envelopeKey: "timeslip") {
                stopped = resolvedTimeslip(settled, clientId: running.clientId).withTimerStartedAt(nil)
            } else {
                // The stop itself succeeded, so a failed read-back must not report it as an error.
                // The hours stay understated until the next refresh, which this write forces.
                stopped = running.withTimerStartedAt(nil)
            }
            // Into the cache now rather than at the next refresh: `startTimer` creates today's
            // timeslip on demand, so one started and stopped between refreshes exists nowhere
            // else locally, and "Recent time entries" is built from this cache.
            upsertKeepingDayOrder(stopped)
            return stopped
        }
    }

    public func runningTimeslip() async throws -> RatchetTimeslip? {
        try await fetchRunningTimeslip()
    }

    /// The authoritative "is anything running for this user" query, shared by `refresh()`,
    /// `startTimer()`, `stopTimer()`, and `runningTimeslip()` — none of them trusts a cached
    /// `currentRunningTimeslip` in its place. Returns the raw DTO rather than resolving it to a
    /// `RatchetTimeslip` — `refresh()` runs this concurrently with the projects fetch that
    /// `resolvedTimeslip` depends on, so resolution has to happen after that fetch is awaited,
    /// not inside this function.
    private func fetchRunningTimeslipDTO(userURL: String? = nil) async throws -> FreeAgentTimeslipDTO? {
        // `refresh()` passes its own freshly-fetched user URL explicitly (it hasn't committed
        // `currentUserURL` yet at that point); only the nil path — every other caller — reads
        // the stored one, so only that path needs the guard.
        let resolvedUserURL = try userURL ?? requireUserURL()
        let running: [FreeAgentTimeslipDTO] = try await apiClient.getList(
            "timeslips", query: [
                URLQueryItem(name: "view", value: "running"),
                URLQueryItem(name: "user", value: resolvedUserURL),
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
        try await withMutation {
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
            let body = CreateContactBody(
                organisation_name: organisationName, first_name: firstName, last_name: lastName,
                email: email, phone_number: phoneNumber,
                address1: address1, town: town, postcode: postcode, country: country
            )
            // Here and in `addProject` and `addTask`, an earlier attempt's result is returned as this
            // one's: unlike a second time entry, a second client, project or task under the same
            // name is not what a retry means.
            let (created, _) = try await contactCreates.create(
                ContactIdentity(organisationName: organisationName, firstName: firstName, lastName: lastName),
                cachedIds: { [self] in Set(clients.map(\.id)) },
                // Anything created since `createdSince` has been updated since then too.
                candidates: { [self] createdSince in
                    try await apiClient.getList(
                        "contacts", query: [URLQueryItem(name: "updated_since", value: createdSince.ISO8601Format())],
                        listKey: "contacts"
                    )
                },
                post: { [self] in try await apiClient.post("contacts", envelopeKey: "contact", body: body) }
            )
            let client = created.toRatchetClient(projects: [])
            // An upsert that keeps a cached copy's projects: a client adopted from an earlier
            // attempt may already be cached, with projects added since.
            if let index = clients.firstIndex(where: { $0.id == client.id }) {
                clients[index] = client.withProjects(clients[index].projects)
            } else {
                clients.append(client)
            }
            return client
        }
    }

    public func addProject(
        name: String, clientId: String, status: ProjectStatus, currency: String,
        budget: Double, budgetUnits: BudgetUnits, hoursPerDay: Double,
        normalBillingRate: Double, billingPeriod: BillingPeriod,
        usesProjectInvoiceSequence: Bool, contractPoReference: String?,
        startsOn: Date?, endsOn: Date?
    ) async throws -> RatchetProject {
        try await withMutation {
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
            let body = CreateProjectBody(
                contact: clientId, name: name, status: status.rawValue, currency: currency,
                budget: String(budget), budget_units: budgetUnits.rawValue,
                hours_per_day: String(hoursPerDay), normal_billing_rate: String(normalBillingRate),
                billing_period: billingPeriod.rawValue, uses_project_invoice_sequence: usesProjectInvoiceSequence,
                contract_po_reference: contractPoReference,
                starts_on: startsOn.map(dateString), ends_on: endsOn.map(dateString)
            )
            let (created, _) = try await projectCreates.create(
                ProjectIdentity(contact: clientId, name: name),
                cachedIds: { [self] in Set(clients.flatMap(\.projects).map(\.id)) },
                candidates: { [self] _ in
                    let ofClient = URLQueryItem(name: "contact", value: clientId)
                    var listed: [FreeAgentProjectDTO] = try await apiClient.getList("projects", query: [ofClient], listKey: "projects")
                    // FreeAgent doesn't document which statuses the plain list includes, and a
                    // retry may name another status than the attempt it settles, so every other
                    // status's view is asked too.
                    for other in ProjectStatus.allCases where other != .active {
                        let view = URLQueryItem(name: "view", value: other.rawValue.lowercased())
                        do {
                            listed += try await apiClient.getList("projects", query: [ofClient, view], listKey: "projects")
                        } catch FreeAgentError.apiError(let status, _) where [400, 404, 422].contains(status) {
                            // A view FreeAgent refuses says nothing about this project. One left
                            // unanswered (timed out, rate-limited, failed) might have listed it, so
                            // that still throws.
                        }
                    }
                    return listed
                },
                post: { [self] in try await apiClient.post("projects", envelopeKey: "project", body: body) }
            )
            projectToClientId[created.url] = clientId
            let project = created.toRatchetProject(tasks: [])
            // FreeAgent has made the project, so a client the cache has since dropped (hidden in
            // the web app, say) must not turn it into a failure that invites making a second.
            if let clientIndex = clients.firstIndex(where: { $0.id == clientId }) {
                clients[clientIndex] = withUpsertedProject(clients[clientIndex], project)
            }
            return project
        }
    }

    public func addTask(
        name: String, projectId: String, clientId: String, isBillable: Bool,
        status: TaskStatus, billingRate: Double?, billingPeriod: BillingPeriod?
    ) async throws -> RatchetTask {
        try await withMutation {
            struct CreateTaskBody: Encodable {
                let name: String
                let is_billable: Bool
                let status: String
                let billing_rate: String?
                let billing_period: String?
            }
            let body = CreateTaskBody(
                name: name, is_billable: isBillable, status: status.rawValue,
                billing_rate: billingRate.map { String($0) }, billing_period: billingPeriod?.rawValue
            )
            let inProject = [URLQueryItem(name: "project", value: projectId)]
            let (created, _) = try await taskCreates.create(
                TaskIdentity(project: projectId, name: name),
                cachedIds: { [self] in Set(clients.flatMap(\.projects).flatMap(\.tasks).map(\.id)) },
                candidates: { [self] _ in try await apiClient.getList("tasks", query: inProject, listKey: "tasks") },
                post: { [self] in try await apiClient.post("tasks", envelopeKey: "task", query: inProject, body: body) }
            )
            let task = created.toRatchetTask()
            // Returned even when the cache has dropped its project, as in `addProject`.
            if let clientIndex = clients.firstIndex(where: { $0.id == clientId }),
               let projectIndex = clients[clientIndex].projects.firstIndex(where: { $0.id == projectId }) {
                clients[clientIndex] = withUpsertedTask(clients[clientIndex], projectIndex: projectIndex, task: task)
            }
            return task
        }
    }

    public func logTime(
        taskId: String, projectId: String, clientId: String, date: Date, hours: Double, comment: String?
    ) async throws -> RatchetTimeslip {
        try await withMutation {
            let userURL = try requireUserURL()
            let body = TimeslipBody(
                project: projectId, task: taskId, user: userURL,
                dated_on: dateString(date), hours: String(hours), comment: comment
            )
            let (created, isEarlierAttempt) = try await timeslipCreates.create(
                body,
                cachedIds: { [self] in Set(timeslips.map(\.id)) },
                candidates: { [self] _ in
                    try await sameDayTimeslips(task: body.task, project: body.project, day: body.dated_on, user: body.user)
                },
                post: { [self] in try await apiClient.post("timeslips", envelopeKey: "timeslip", body: body) }
            )
            let resolved = resolvedTimeslip(created, clientId: clientId)
            // An upsert, since an entry adopted from an earlier attempt may already be cached.
            upsertKeepingDayOrder(resolved)
            // Thrown rather than returned: this request may be a deliberate second entry rather
            // than a retry, and only the user can say which.
            if isEarlierAttempt { throw DataStoreError.alreadyLogged }
            return resolved
        }
    }

    public func updateTimeslip(
        id: String, taskId: String, projectId: String, clientId: String, date: Date, hours: Double, comment: String?
    ) async throws -> RatchetTimeslip {
        try await withMutation {
            let userURL = try requireUserURL()
            // FreeAgent's timeslip PUT keeps any attribute it isn't sent, so a cleared comment
            // goes as "" rather than being left out.
            let updated: FreeAgentTimeslipDTO = try await apiClient.put(
                id, envelopeKey: "timeslip",
                body: TimeslipBody(
                    project: projectId, task: taskId, user: userURL,
                    dated_on: dateString(date), hours: String(hours), comment: comment ?? ""
                )
            )
            let resolved = resolvedTimeslip(updated, clientId: clientId)
            // A PUT response that omits the `timer` object doesn't mean the timer stopped —
            // FreeAgent doesn't always echo it back on this endpoint — so when this slip is the one
            // actually running, carry its previously known start instant forward rather than letting
            // a bare PUT null it out in the cache. `AppState.reconcile(with:)` reads
            // `currentRunningTimeslip.timerStartedAt` as the elapsed-time baseline on every launch,
            // login, manual refresh and silent refresh, so a silently dropped start instant here
            // would re-base a running timer's displayed elapsed time to "now" the next time any of
            // those adopts it.
            let reconciled: RatchetTimeslip
            if resolved.timerStartedAt == nil, let stillRunning = currentRunningTimeslip, stillRunning.id == id,
               let preserved = stillRunning.timerStartedAt {
                reconciled = resolved.withTimerStartedAt(preserved)
            } else {
                reconciled = resolved
            }
            // Replaced only if still cached, rather than assuming it must be — an edit from a
            // stale menu (built before the entry aged out of the `refresh()` window, or from a
            // duplicate submenu still open after the underlying array changed) shouldn't silently
            // reinsert a slip the local cache had already dropped.
            if timeslips.contains(where: { $0.id == id }) {
                upsertKeepingDayOrder(reconciled)
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
    }

    // MARK: - Private helpers

    /// `user`'s timeslips for one task on one `yyyy-MM-dd` day.
    private func sameDayTimeslips(task: String, project: String, day: String, user: String) async throws -> [FreeAgentTimeslipDTO] {
        try await apiClient.getList(
            "timeslips", query: [
                URLQueryItem(name: "task", value: task),
                URLQueryItem(name: "project", value: project),
                URLQueryItem(name: "from_date", value: day),
                URLQueryItem(name: "to_date", value: day),
                URLQueryItem(name: "user", value: user),
            ], listKey: "timeslips"
        )
    }

    /// Inserts `slip` into `timeslips` keeping the array day-ascending, replacing any entry that
    /// already carries its id.
    ///
    /// Both write paths need this, for different reasons. `logTime` needs the ordering because a
    /// back-dated entry appended to the end reads as the newest thing in the array — exactly how
    /// it used to jump to the top of "Recent time entries" until the next refresh reshuffled it.
    /// `updateTimeslip` needs it because the edit sheet lets an entry's date change, and writing
    /// the result back at its old index left the array unsorted; the *next* `logTime` then picked
    /// its insertion point with a search that assumes ascending order, so one re-dated edit put
    /// every subsequent entry in the wrong place until a refresh rebuilt the list.
    private func upsertKeepingDayOrder(_ slip: RatchetTimeslip) {
        if let existing = timeslips.firstIndex(where: { $0.id == slip.id }) {
            timeslips.remove(at: existing)
        }
        let insertionIndex = timeslips.firstIndex { $0.day > slip.day } ?? timeslips.endIndex
        timeslips.insert(slip, at: insertionIndex)
    }

    private func resolvedTimeslip(_ dto: FreeAgentTimeslipDTO, using projectMap: [String: String], clientId: String? = nil) -> RatchetTimeslip {
        let resolvedClientId = clientId ?? projectMap[dto.project] ?? ""
        return dto.toRatchetTimeslip().withClientId(resolvedClientId)
    }

    /// The committed-state resolver, for the mutating calls that run outside `refresh()`.
    private func resolvedTimeslip(_ dto: FreeAgentTimeslipDTO, clientId: String? = nil) -> RatchetTimeslip {
        resolvedTimeslip(dto, using: projectToClientId, clientId: clientId)
    }

    /// An upsert, since a project adopted from an earlier attempt may already be cached.
    private func withUpsertedProject(_ client: RatchetClient, _ project: RatchetProject) -> RatchetClient {
        if let index = client.projects.firstIndex(where: { $0.id == project.id }) {
            // A cached copy keeps its tasks, as a cached client keeps its projects in `addClient`.
            return client.replacingProject(at: index, with: project.withTasks(client.projects[index].tasks))
        }
        return client.withProjects(client.projects + [project])
    }

    /// An upsert, since a task adopted from an earlier attempt may already be cached.
    private func withUpsertedTask(_ client: RatchetClient, projectIndex: Int, task: RatchetTask) -> RatchetClient {
        let existing = client.projects[projectIndex]
        let tasks: [RatchetTask]
        if let index = existing.tasks.firstIndex(where: { $0.id == task.id }) {
            var updated = existing.tasks
            updated[index] = task
            tasks = updated
        } else {
            tasks = existing.tasks + [task]
        }
        return client.replacingProject(at: projectIndex, with: existing.withTasks(tasks))
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
