// SPDX-License-Identifier: GPL-3.0-or-later
// Sources/Antagonise/main.swift
//
// Dev-only regression harness for the nine ways Ratchet's in-memory state could silently
// disagree with FreeAgent's, fixed across cbcb28f..64853c6. Each scenario drives the real
// `FreeAgentDataStore` against a scriptable stub transport and asserts the *fixed* behaviour, so
// a `BUG` line means a regression. Exits non-zero if any scenario fails.
//
// This is an executable rather than an XCTest case because `swift test` cannot run on a machine
// without Xcode (see CLAUDE.md) — the unit tests covering this work are unrun code, and this is
// the only runnable evidence the bugs stay fixed. Run it after any change to `FreeAgentDataStore`,
// `AppState`, or `restoreRunningTimer`:
//
//     swift run Antagonise          # all nine
//     ONLY=4 swift run Antagonise   # one scenario
//
// It writes throwaway Keychain items under `com.ratchet.antagonise.<uuid>` and clears each one
// as it goes; if a run is killed part-way, sweep the leftovers with:
//
//     security dump-keychain 2>/dev/null | grep -o 'com\.ratchet\.antagonise\.[A-F0-9-]*' \
//       | sort -u | while read s; do security delete-generic-password -s "$s" >/dev/null 2>&1; done
import Foundation
import FreeAgentKit
import RatchetCore

@MainActor
final class Stub: FreeAgentTransport {
    struct Rule { let match: String; var status: Int; var body: String }
    var rules: [Rule] = []
    var log: [(method: String, url: String, body: String)] = []

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await MainActor.run {
            let url = request.url!.absoluteString
            log.append((request.httpMethod ?? "?", url, String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""))
            guard let rule = rules.first(where: { url.contains($0.match) }) else { fatalError("no stub for \(url)") }
            return (Data(rule.body.utf8), HTTPURLResponse(url: request.url!, statusCode: rule.status, httpVersion: nil, headerFields: nil)!)
        }
    }

    /// Rules are first-match-wins and order matters: FreeAgent filter params embed full
    /// /projects/ and /tasks/ URLs in the query string, so timeslip routes must be registered
    /// before the resource-list routes or a `?task=.../tasks/1` query matches the tasks rule.
    func setRule(_ match: String, body: String, status: Int = 200) {
        if let i = rules.firstIndex(where: { $0.match == match }) { rules[i].body = body; rules[i].status = status }
        else { rules.append(Rule(match: match, status: status, body: body)) }
    }
}

/// Holds the first request matching `gateMatch` open until released, so a user action can be
/// interleaved with a refresh that is still in flight.
@MainActor
final class GatedStub: FreeAgentTransport {
    let inner: Stub
    let gateMatch: String
    var armed = false
    private(set) var gateHit = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(inner: Stub, gateMatch: String) { self.inner = inner; self.gateMatch = gateMatch }

    /// Registers the continuation synchronously on the main actor, so `release()` can never run
    /// before the waiter is recorded — that ordering hole deadlocks instead of failing.
    private func waitIfGated(_ url: String) async {
        guard armed, url.contains(gateMatch), !gateHit else { return }
        gateHit = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiting.append(c) }
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await waitIfGated(request.url!.absoluteString)
        return try await inner.send(request)
    }

    func release() { let w = waiting; waiting = []; w.forEach { $0.resume() } }
}

@MainActor
func awaitGate(_ gate: GatedStub) async -> Bool {
    for _ in 0..<2000 {
        if gate.gateHit { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return false
}

let U = "https://api.sandbox.freeagent.com/v2"
func user() -> String { #"{"user":{"url":"\#(U)/users/1","email":"al@example.com"}}"# }
func company() -> String { #"{"company":{"subdomain":"acme"}}"# }
func contacts() -> String { #"{"contacts":[{"url":"\#(U)/contacts/1","organisation_name":"Acme","first_name":null,"last_name":null,"email":null,"phone_number":null,"address1":null,"town":null,"postcode":null,"country":null}]}"# }
func projects() -> String { #"{"projects":[{"url":"\#(U)/projects/1","contact":"\#(U)/contacts/1","name":"Site","status":"Active","currency":"GBP","budget":"0","budget_units":"Hours","hours_per_day":"8","normal_billing_rate":"0","billing_period":"hour","uses_project_invoice_sequence":false,"contract_po_reference":null,"starts_on":null,"ends_on":null}]}"# }
func tasks(_ ids: [Int] = [1, 2]) -> String {
    let body = ids.map { #"{"url":"\#(U)/tasks/\#($0)","project":"\#(U)/projects/1","name":"Task\#($0)","is_billable":true,"status":"Active","billing_rate":null,"billing_period":null}"# }.joined(separator: ",")
    return #"{"tasks":[\#(body)]}"#
}
func slip(id: Int, task: Int, hours: String, datedOn: String, timerStart: String?) -> String {
    let timer = timerStart.map { #""timer":{"running":true,"start_from":"\#($0)"}"# } ?? #""timer":null"#
    return #"{"url":"\#(U)/timeslips/\#(id)","project":"\#(U)/projects/1","task":"\#(U)/tasks/\#(task)","user":"\#(U)/users/1","dated_on":"\#(datedOn)","hours":"\#(hours)","comment":null,\#(timer),"billed_on_invoice":null}"#
}
func today() -> String { CalendarDay.dayString(from: Date()) }

@MainActor
func makeStore(_ transport: FreeAgentTransport) -> (FreeAgentDataStore, KeychainTokenStore) {
    let ts = KeychainTokenStore(service: "com.ratchet.antagonise.\(UUID().uuidString)")
    _ = ts.save(FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: 3600)))
    let api = FreeAgentAPIClient(environment: .sandbox, tokenStore: ts, transport: transport)
    return (FreeAgentDataStore(apiClient: api, environment: .sandbox), ts)
}

@MainActor
func baseRules(_ s: Stub, running: String? = nil, recent: String = "[]") {
    s.setRule("users/me", body: user())
    s.setRule("/company", body: company())
    s.setRule("view=running", body: #"{"timeslips":[\#(running ?? "")]}"#)
    s.setRule("timeslips?", body: #"{"timeslips":\#(recent)}"#)
    s.setRule("/timer", body: "{}")
    s.setRule("contacts?", body: contacts())
    s.setRule("projects?", body: projects())
    s.setRule("/tasks?", body: tasks())
}

func hdr(_ n: Int, _ t: String) { print("\n=== \(n). \(t) ===") }
func ok(_ m: String) { print("   ok  \(m)") }
var bugCount = 0
func bad(_ m: String) { bugCount += 1; print("  BUG  \(m)") }

let acmeRef = TrackedTaskRef(clientId: "\(U)/contacts/1", clientName: "Acme",
                             projectId: "\(U)/projects/1", projectName: "Site",
                             taskId: "\(U)/tasks/1", taskName: "Task1")

/// Line-for-line replica of Ratchet/AppDelegate.restoreRunningTimer — the executable target
/// can't be imported, so this must be kept in step with it by hand.
@MainActor
func restoreRunningTimer(from dataStore: FreeAgentDataStore, into appState: AppState) {
    guard let running = dataStore.currentRunningTimeslip else {
        if appState.trackingTask != nil { appState.stopTracking() }
        return
    }
    let client = dataStore.clients.first { $0.id == running.clientId }
    let project = client?.projects.first { $0.id == running.projectId }
    let task = project?.tasks.first { $0.id == running.taskId }
    let isFullyResolved = task != nil
    let ref = TrackedTaskRef(
        clientId: running.clientId, clientName: client?.name ?? "Unknown client",
        projectId: running.projectId, projectName: project?.name ?? "Unknown project",
        taskId: running.taskId, taskName: task?.name ?? "Unknown task"
    )
    if running.timerStartedAt == nil, appState.trackingTask == ref { return }
    appState.startTracking(ref, startedAt: running.timerStartedAt ?? Date(), recordAsMostRecent: isFullyResolved)
}

// MARK: - Scenarios

@MainActor func s1() async throws {
    hdr(1, "User stops the timer while a silent refresh is in flight")
    let stub = Stub()
    let running = slip(id: 9, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z")
    baseRules(stub, running: running, recent: "[\(running)]")
    stub.setRule("timeslips/9/timer", body: "{}")
    let gate = GatedStub(inner: stub, gateMatch: "view=running")
    let (store, ts) = makeStore(gate); defer { ts.clear() }
    try await store.refresh()
    let app = AppState(); app.logIn(); restoreRunningTimer(from: store, into: app)
    print("   after first refresh: tracking = \(app.trackingTask != nil)")

    gate.armed = true
    let inFlight = Task { @MainActor in try? await store.refresh() }
    guard await awaitGate(gate) else { bad("gate never fired"); return }
    _ = try await store.stopTimer()
    app.stopTracking()
    print("   user stopped: running = \(store.currentRunningTimeslip?.id ?? "nil")")
    gate.release()
    _ = await inFlight.value
    restoreRunningTimer(from: store, into: app)
    if store.currentRunningTimeslip == nil, app.trackingTask == nil { ok("the stop survived the concurrent refresh") }
    else { bad("stale refresh resurrected the stopped timer: running=\(store.currentRunningTimeslip?.id ?? "nil")") }
}

@MainActor func s2() async throws {
    hdr(2, "User starts a timer while a silent refresh is in flight")
    let stub = Stub()
    baseRules(stub, running: nil, recent: "[]")
    stub.setRule("v2/timeslips", body: #"{"timeslip":\#(slip(id: 42, task: 1, hours: "0.0", datedOn: today(), timerStart: nil))}"#)
    let gate = GatedStub(inner: stub, gateMatch: "view=running")
    let (store, ts) = makeStore(gate); defer { ts.clear() }
    try await store.refresh()
    let app = AppState(); app.logIn()

    gate.armed = true
    let inFlight = Task { @MainActor in try? await store.refresh() }
    guard await awaitGate(gate) else { bad("gate never fired"); return }
    stub.setRule("timeslips?", body: #"{"timeslips":[]}"#)
    stub.setRule("/timer", body: #"{"timeslip":\#(slip(id: 42, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z"))}"#)
    let started = try await store.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    app.startTracking(acmeRef, startedAt: started.timerStartedAt ?? Date())
    print("   user started: running = \(store.currentRunningTimeslip?.id ?? "nil")")
    gate.release()
    _ = await inFlight.value
    restoreRunningTimer(from: store, into: app)
    if store.currentRunningTimeslip != nil, app.trackingTask != nil { ok("the start survived the concurrent refresh") }
    else { bad("in-flight refresh erased the just-started timer") }
}

@MainActor func s3() async throws {
    hdr(3, "stopTimer() must stop what the server says is running, not the cache")
    let stub = Stub()
    let slipA = slip(id: 100, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z")
    baseRules(stub, running: slipA, recent: "[\(slipA)]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()
    print("   cached running = \(store.currentRunningTimeslip!.id)")
    // Elsewhere: 100 was stopped from the web app and 200 started instead.
    stub.setRule("view=running", body: #"{"timeslips":[\#(slip(id: 200, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T11:00:00Z"))]}"#)
    stub.setRule("timeslips/", body: "{}")
    stub.log = []
    _ = try await store.stopTimer()
    let deletes = stub.log.filter { $0.method == "DELETE" }.map(\.url)
    let queried = stub.log.contains { $0.url.contains("view=running") }
    print("   DELETE calls: \(deletes)")
    if queried, deletes == ["\(U)/timeslips/200/timer"] { ok("asked the server first and stopped what was actually running") }
    else { bad("stopped \(deletes) (queried=\(queried))") }
}

@MainActor func s4() async throws {
    hdr(4, "Switch task must PUT the server's hours, not the cached ones")
    let stub = Stub()
    let stale = slip(id: 300, task: 1, hours: "2.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z")
    baseRules(stub, running: stale, recent: "[\(stale)]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()
    print("   cached hours at refresh time: \(store.currentRunningTimeslip!.hours)")
    // Elsewhere: paused and resumed, so the server now stands at 5.0.
    stub.setRule("view=running", body: #"{"timeslips":[\#(slip(id: 300, task: 1, hours: "5.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z"))]}"#)
    stub.setRule("timeslips/300", body: #"{"timeslip":\#(slip(id: 300, task: 2, hours: "5.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z"))}"#)
    stub.log = []
    guard let fresh = try await store.runningTimeslip() else { bad("no running timeslip"); return }
    _ = try await store.updateTimeslip(id: fresh.id, taskId: "\(U)/tasks/2", projectId: "\(U)/projects/1",
                                       clientId: "\(U)/contacts/1", date: fresh.day, hours: fresh.hours, comment: fresh.comment)
    let put = stub.log.first { $0.method == "PUT" }!
    print("   PUT body: \(put.body)")
    if put.body.contains("\"hours\":\"5.0\"") { ok("the PUT carries the server's hours, not the cached 2.0") }
    else { bad("the PUT still asserts stale hours: \(put.body)") }
    if stub.log.contains(where: { $0.url.contains("view=running") }) { ok("re-read the running timeslip before writing") }
    else { bad("wrote without re-reading") }
}

@MainActor func s5() async throws {
    hdr(5, "A timer-start response without a `timer` object must not backdate the clock")
    let stub = Stub()
    baseRules(stub, running: nil, recent: "[]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()
    stub.setRule("timeslips?", body: #"{"timeslips":[\#(slip(id: 55, task: 1, hours: "0.0", datedOn: today(), timerStart: nil))]}"#)
    stub.setRule("/timer", body: #"{"timeslip":\#(slip(id: 55, task: 1, hours: "0.0", datedOn: today(), timerStart: nil))}"#)
    let started = try await store.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    guard let startedAt = started.timerStartedAt else { bad("startTimer returned no timer start"); return }
    let elapsed = Date().timeIntervalSince(startedAt)
    print("   startedAt = \(startedAt), elapsed shown immediately = \(ElapsedTimeFormatter.format(seconds: elapsed))")
    if elapsed > 120 { bad("a timer started just now displays \(ElapsedTimeFormatter.format(seconds: elapsed))") }
    else { ok("elapsed baseline is sane (\(ElapsedTimeFormatter.format(seconds: elapsed)))") }
}

@MainActor func s6() async throws {
    hdr(6, "A refresh that fails halfway must commit nothing")
    let stub = Stub()
    let slipA = slip(id: 400, task: 1, hours: "1.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z")
    baseRules(stub, running: slipA, recent: "[\(slipA)]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()
    let before = (clients: store.clients.count, slips: store.timeslips.count, at: store.lastRefreshedAt)
    print("   before: clients=\(before.clients) timeslips=\(before.slips) running=\(store.currentRunningTimeslip?.id ?? "nil")")
    stub.setRule("contacts?", body: #"{"contacts":[]}"#)
    stub.setRule("timeslips?", body: #"{"error":"boom"}"#, status: 500)
    do { try await store.refresh(); bad("expected the refresh to throw") } catch { print("   refresh threw: \(error)") }
    print("   after:  clients=\(store.clients.count) timeslips=\(store.timeslips.count) running=\(store.currentRunningTimeslip?.id ?? "nil")")
    if store.clients.count == before.clients, store.timeslips.count == before.slips, store.currentRunningTimeslip != nil {
        ok("the failed refresh committed nothing; the previous snapshot is intact")
    } else { bad("partial commit: clients=\(store.clients.count) timeslips=\(store.timeslips.count)") }
    if store.lastRefreshedAt == before.at { ok("lastRefreshedAt not stamped by the failed refresh") }
    else { bad("lastRefreshedAt advanced despite the failure") }
}

@MainActor func s7() async throws {
    hdr(7, "A running timer whose task isn't in the local tree must stay stoppable")
    let stub = Stub()
    let running = slip(id: 500, task: 7, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z")
    baseRules(stub, running: running, recent: "[\(running)]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()
    let app = AppState(); app.logIn()
    print("   server says running: \(store.currentRunningTimeslip!.id) on tasks/7 (not in the local tree)")
    restoreRunningTimer(from: store, into: app)
    if case .tracking(let t, _) = app.screen { ok("still tracking, labelled \"\(t.taskName)\" — Stop stays reachable") }
    else { bad("dropped to idle with a timer still running server-side: \(app.screen)") }
    // The placeholder must not become the idle screen's "Start tracking …" row.
    app.stopTracking()
    if case .idleNoHistory = app.screen { ok("placeholder did not pollute most-recent") }
    else { bad("placeholder leaked into most-recent: \(app.screen)") }
}

@MainActor func s8() async throws {
    hdr(8, "A list response under an unexpected key must be an error, not an empty account")
    let stub = Stub()
    baseRules(stub)
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()
    print("   clients after good refresh: \(store.clients.count)")
    stub.setRule("contacts?", body: #"{"data":[]}"#)
    do {
        try await store.refresh()
        bad("refresh() reported success with \(store.clients.count) clients despite an unrecognised envelope")
    } catch {
        ok("mismatch surfaced as an error: \(error)")
        if store.clients.count == 1 { ok("previous clients left intact") } else { bad("clients clobbered anyway") }
    }
}

@MainActor func s9() async throws {
    hdr(9, "A Keychain read failure must be distinguished from a dead session")
    let stub = Stub()
    baseRules(stub)
    let (store, ts) = makeStore(stub)
    try await store.refresh()
    ts.clear()  // a genuinely deleted item: this one IS a real "log in again"
    do { try await store.refresh(); bad("expected an error after the credentials were removed") }
    catch {
        print("   removed item -> \(error)  indicatesSessionExpired = \(error.indicatesSessionExpired)")
        if error.indicatesSessionExpired { ok("a missing item still logs out, as it should") }
        else { bad("a missing item no longer logs out") }
    }
    if FreeAgentError.credentialStoreUnavailable(errSecInteractionNotAllowed).indicatesSessionExpired {
        bad("a Keychain read failure still routes to handleSessionExpired() -> tokenStore.clear()")
    } else { ok("a Keychain read failure no longer clears the stored refresh token") }
}

@MainActor func s10() async throws {
    hdr(10, "Re-dating an entry must keep `timeslips` day-ascending")
    let stub = Stub()
    let older = slip(id: 601, task: 1, hours: "1.0", datedOn: "2026-08-10", timerStart: nil)
    let newer = slip(id: 602, task: 1, hours: "1.0", datedOn: "2026-08-18", timerStart: nil)
    baseRules(stub, running: nil, recent: "[\(older),\(newer)]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()
    print("   after refresh: \(store.timeslips.map { CalendarDay.dayString(from: $0.day) })")

    // The edit sheet lets the date change: move the oldest entry to the newest day.
    stub.setRule("timeslips/601", body: #"{"timeslip":\#(slip(id: 601, task: 1, hours: "1.0", datedOn: "2026-08-20", timerStart: nil))}"#)
    _ = try await store.updateTimeslip(id: "\(U)/timeslips/601", taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1",
                                       clientId: "\(U)/contacts/1", date: CalendarDay.day(from: "2026-08-20")!,
                                       hours: 1.0, comment: nil)
    let days = store.timeslips.map { CalendarDay.dayString(from: $0.day) }
    print("   after re-dating 601 to 2026-08-20: \(days)")
    if days == days.sorted() { ok("array stayed day-ascending") }
    else { bad("array left unsorted: \(days) — the next logTime picks its index with a search that assumes order") }

    // The invariant that actually breaks: a subsequent logTime must land in the right place.
    stub.setRule("v2/timeslips", body: #"{"timeslip":\#(slip(id: 603, task: 1, hours: "1.0", datedOn: "2026-08-14", timerStart: nil))}"#)
    _ = try await store.logTime(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1",
                                date: CalendarDay.day(from: "2026-08-14")!, hours: 1.0, comment: nil)
    let after = store.timeslips.map { CalendarDay.dayString(from: $0.day) }
    print("   after logging a 2026-08-14 entry: \(after)")
    if after == after.sorted() { ok("the newly logged entry landed in date order") }
    else { bad("newly logged entry landed out of order: \(after)") }
}

setvbuf(stdout, nil, _IOLBF, 0)
let only = ProcessInfo.processInfo.environment["ONLY"].flatMap(Int.init)
func want(_ n: Int) -> Bool { only == nil || only == n }

Task { @MainActor in
    do {
        if want(1) { try await s1() }
        if want(2) { try await s2() }
        if want(3) { try await s3() }
        if want(4) { try await s4() }
        if want(5) { try await s5() }
        if want(6) { try await s6() }
        if want(7) { try await s7() }
        if want(8) { try await s8() }
        if want(9) { try await s9() }
        if want(10) { try await s10() }
    } catch { print("harness error: \(error)"); bugCount += 1 }
    print("\n\(bugCount == 0 ? "ALL CLEAR" : "\(bugCount) BUG LINE(S)")")
    exit(bugCount == 0 ? 0 : 1)
}
RunLoop.main.run()
