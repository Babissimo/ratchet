// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RatchetCore

/// A timeslip as `POST /timeslips` and `PUT /timeslips/:id` take it. `Hashable` so a create
/// whose outcome is unknown can be matched to an identical retry.
private struct TimeslipBody: Encodable, Hashable {
    let project: String
    let task: String
    let user: String
    let dated_on: String
    let hours: String
    let comment: String?

    /// Whether `dto` records this entry. Hours compare numerically to within half a minute,
    /// since FreeAgent echoes the decimal it stored rather than the string sent, and comments
    /// compare as the log form normalises them, since an absent one may come back as null or "".
    func isRecorded(by dto: FreeAgentTimeslipDTO) -> Bool {
        guard dto.user == user, dto.project == project, dto.task == task, dto.datedOn == dated_on,
              let sent = Double(hours), let stored = Double(dto.hours), abs(sent - stored) < 1.0 / 120
        else { return false }
        return TaskNameValidator.validate(dto.comment ?? "") == TaskNameValidator.validate(comment ?? "")
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
    /// project URL -> client URL, so timeslip DTOs (which only know their
    /// project) can be assigned the right clientId.
    private var projectToClientId: [String: String] = [:]
    private var currentUserURL: String = ""
    /// Bumped on **both** entry to and exit from every mutating method (via `withMutation`
    /// below, which makes forgetting either edge a compile error rather than a silent gap).
    /// `refresh()` snapshots this before its first request and discards its commit if the value
    /// has moved by the time it would otherwise commit, because a refresh's responses describe
    /// the world as of when the server answered them, not as of when it started.
    ///
    /// One edge is not enough. Bumping only on entry leaves a hole: a refresh that *starts*
    /// after a mutation's entry-bump snapshots the already-incremented epoch, so as far as the
    /// guard is concerned nothing has changed — even though the mutation's own result hasn't
    /// landed yet. Concretely: the user clicks Start, `startTimer` bumps to N and suspends on
    /// `fetchRunningTimeslip` (several round trips); the user then hits "Refresh projects &
    /// tasks" (which deliberately bypasses the staleness gate), and that refresh reads epoch=N;
    /// its `view=running` query is answered *before* `startTimer`'s `POST /timer` lands, so that
    /// refresh's "nothing running" snapshot commits straight over a timer that has, in fact,
    /// already started server-side. The exit bump closes that hole for every exit path,
    /// including a thrown error, since a mutation that failed partway through may still have
    /// changed server state a refresh in flight has no way to know about.
    ///
    /// Both edges still leave a narrower hole: a refresh that snapshots the epoch *after* a
    /// mutation's entry-bump and commits *before* its exit-bump sees no epoch movement either,
    /// and commits normally — this needs a whole refresh to complete inside one mutation's
    /// single suspension, so it's rare, but real on a slow POST. If that refresh's response
    /// already includes the entity the mutation is about to write locally (its own request
    /// landed server-side first), an append-only local write would then insert a second copy of
    /// it. `logTime`, `addClient`, `addProject`, and `addTask` close that gap the same way
    /// `updateTimeslip` always has: an id-keyed replace-if-present instead of a bare append.
    private var mutationEpoch: UInt64 = 0

    /// Wraps a mutating method's whole body so the entry and exit epoch bumps can't be
    /// forgotten independently — see `mutationEpoch`'s doc comment for why both edges matter.
    /// Bumps on entry, runs `body`, then bumps again via `defer`, on every exit path including a
    /// thrown error. Replaces the previous shape (a `beginMutation()` call paired by hand with a
    /// `defer { mutationEpoch &+= 1 }` at each call site), which let a future mutating method
    /// omit the `defer` with no compiler error and silently reopen the race this guards against.
    private func withMutation<T>(_ body: () async throws -> T) async rethrows -> T {
        mutationEpoch &+= 1
        defer {
            mutationEpoch &+= 1
            // On exit, so a refresh committing mid-mutation can't clear it, and on throw too,
            // since a write that failed partway may still have changed server state.
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
        // mutation: the mutation's epoch bump would make the refresh discard its own result.
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
            let created: FreeAgentContactDTO = try await apiClient.post(
                "contacts", envelopeKey: "contact",
                body: CreateContactBody(
                    organisation_name: organisationName, first_name: firstName, last_name: lastName,
                    email: email, phone_number: phoneNumber,
                    address1: address1, town: town, postcode: postcode, country: country
                )
            )
            let client = created.toRatchetClient(projects: [])
            // id-keyed upsert, not a bare append — see `mutationEpoch`'s doc comment for the
            // narrow window in which a concurrent refresh can commit this same client first.
            if let index = clients.firstIndex(where: { $0.id == client.id }) {
                clients[index] = client
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
            clients[clientIndex] = withUpsertedProject(clients[clientIndex], project)
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
            clients[clientIndex] = withUpsertedTask(clients[clientIndex], projectIndex: projectIndex, task: task)
            return task
        }
    }

    public func logTime(
        taskId: String, projectId: String, clientId: String, date: Date, hours: Double, comment: String?
    ) async throws -> RatchetTimeslip {
        try await withMutation {
            let userURL = try requireUserURL()
            let (created, isEarlierAttempt) = try await createTimeslip(TimeslipBody(
                project: projectId, task: taskId, user: userURL,
                dated_on: dateString(date), hours: String(hours), comment: comment
            ))
            let resolved = resolvedTimeslip(created, clientId: clientId)
            // id-keyed upsert, not a bare append — see `mutationEpoch`'s doc comment for the
            // narrow window in which a concurrent refresh can commit this same entry first.
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

    // MARK: - Creates whose outcome is unknown

    /// Allows for the Mac's clock running ahead of FreeAgent's, and for `created_at` being whole
    /// seconds, when a request's send time is compared with the `created_at` of its result.
    private static let clockSkewAllowance: TimeInterval = 5 * 60

    /// A `POST /timeslips` that may have reached FreeAgent although no response reached Ratchet.
    private struct UncertainCreate {
        let sentAt: Date
        /// Entries already cached when it was sent, none of which can be its result.
        let knownIds: Set<String>
    }

    /// Keyed by request body, so an identical retry finds the create it may be repeating.
    private var uncertainCreates: [TimeslipBody: UncertainCreate] = [:]

    /// Every timeslip `logTime` has created or adopted, none of which can be the result of another
    /// create, including one still in flight. `UncertainCreate.knownIds` can't cover these: the
    /// cache holds only `refresh()`'s window, which a back-dated entry leaves at the next refresh.
    private var ownTimeslipIds: Set<String> = []

    /// The last create queued for each body. Identical creates run one at a time, so each is
    /// settled before the next is posted: run together, one can adopt the other's entry before
    /// that create's response arrives, or post while the other's outcome is still open.
    private var queuedCreates: [TimeslipBody: Task<CreateResult, Error>] = [:]

    private typealias CreateResult = (dto: FreeAgentTimeslipDTO, isEarlierAttempt: Bool)

    /// `POST /timeslips`, safe to retry. FreeAgent has no idempotency key, so a create whose
    /// outcome is unknown is remembered and settled by looking for the entry it would have made:
    /// straight away, and again before an identical create is posted. `isEarlierAttempt` is true
    /// when that second look finds it, so nothing was posted this time.
    private func createTimeslip(_ body: TimeslipBody) async throws -> CreateResult {
        let previous = queuedCreates[body]
        let create = Task { [self] in
            _ = try? await previous?.value
            return try await performCreateTimeslip(body)
        }
        queuedCreates[body] = create
        defer { if queuedCreates[body] == create { queuedCreates[body] = nil } }
        return try await create.value
    }

    private func performCreateTimeslip(_ body: TimeslipBody) async throws -> CreateResult {
        if let earlier = uncertainCreates[body], let found = try await findCreated(body, by: earlier) {
            settle(body, as: found)
            return (found, true)
        }
        // Outside the POST, so an expired token failing to refresh reads as nothing sent.
        try await apiClient.prepareTokens()
        let sentAt = clock()
        let cachedAtSend = timeslips
        do {
            let created: FreeAgentTimeslipDTO = try await apiClient.post("timeslips", envelopeKey: "timeslip", body: body)
            settle(body, as: created)
            return (created, false)
        } catch where Self.mayHaveBeenApplied(error) {
            // Kept, and reported as unconfirmed, even when the look below finds nothing: a
            // request that timed out can still commit after the look has run. An earlier record
            // for the same entry is kept in preference, since its window covers both attempts.
            let record = uncertainCreates[body] ?? UncertainCreate(sentAt: sentAt, knownIds: Set(cachedAtSend.map(\.id)))
            uncertainCreates[body] = record
            // Not the original error: a plain network error reads as "not logged" and invites a
            // blind retry.
            guard let found = try await findCreated(body, by: record) else { throw DataStoreError.unconfirmed }
            settle(body, as: found)
            return (found, false)
        }
    }

    private func settle(_ body: TimeslipBody, as result: FreeAgentTimeslipDTO) {
        uncertainCreates[body] = nil
        ownTimeslipIds.insert(result.url)
    }

    /// Whether a create that threw may still have been applied. A 4xx is FreeAgent refusing it;
    /// no response at all, a 5xx (a gateway gives up on requests the app may yet complete), or a
    /// success whose body didn't decode leaves the outcome open.
    private static func mayHaveBeenApplied(_ error: Error) -> Bool {
        switch error as? FreeAgentError {
        case .network(let underlying)?:
            // Name resolution and connecting both fail before any of the request is sent.
            // `.notConnectedToInternet` describes the interface rather than this request, so it
            // can't vouch that nothing went out.
            let unsent: Set<URLError.Code> = [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost]
            return (underlying as? URLError).map { !unsent.contains($0.code) } ?? true
        case .decoding?: return true
        case .apiError(let status, _)?: return status >= 500
        default: return false
        }
    }

    /// The entry `attempt` created, if FreeAgent applied it.
    private func findCreated(_ body: TimeslipBody, by attempt: UncertainCreate) async throws -> FreeAgentTimeslipDTO? {
        let sameDay: [FreeAgentTimeslipDTO]
        do {
            sameDay = try await sameDayTimeslips(task: body.task, project: body.project, day: body.dated_on, user: body.user)
        } catch where !error.indicatesSessionExpired {
            throw DataStoreError.unconfirmed
        }
        let earliest = attempt.sentAt.addingTimeInterval(-Self.clockSkewAllowance)
        let candidates = sameDay.compactMap { dto -> (dto: FreeAgentTimeslipDTO, createdAt: Date)? in
            guard let createdAt = dto.createdAt, createdAt >= earliest, !attempt.knownIds.contains(dto.url),
                  !ownTimeslipIds.contains(dto.url), body.isRecorded(by: dto) else { return nil }
            return (dto, createdAt)
        }
        // The earliest is the likeliest to be this request's own.
        return candidates.min { $0.createdAt < $1.createdAt }?.dto
    }

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

    // MARK: - Private helpers

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

    private func withUpsertedProject(_ client: RatchetClient, _ project: RatchetProject) -> RatchetClient {
        if let index = client.projects.firstIndex(where: { $0.id == project.id }) {
            return client.replacingProject(at: index, with: project)
        }
        return client.withProjects(client.projects + [project])
    }

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
