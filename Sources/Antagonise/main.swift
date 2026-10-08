// SPDX-License-Identifier: GPL-3.0-or-later
// Sources/Antagonise/main.swift
//
// Dev-only regression harness for the ways Ratchet's in-memory state could silently disagree
// with FreeAgent's, or go stale against it. Scenarios 1-10 cover local/remote divergence in the
// store; 11-15 cover staleness (a stopped timer reaching "Recent time entries", the idle screen
// keeping the last task across a restart, and a local write forcing the next refresh); 16-19
// cover the "Start tracking …" offer itself (following history, yielding to a running timer,
// and dropping a task, project or client that has gone); 20-23 cover a "Log past time" create
// whose response is lost, which a retry must not log twice; 24 covers an edit that clears an
// entry's comment, which FreeAgent must be told about. Each drives the real `FreeAgentDataStore`
// against a scriptable stub transport and asserts the *fixed* behaviour, so a `BUG` line means a
// regression. Exits non-zero if any scenario fails.
//
// This is an executable rather than an XCTest case because `swift test` cannot run on a machine
// without Xcode (see CLAUDE.md) — the unit tests covering this work are unrun code, and this is
// the only runnable evidence the bugs stay fixed. Run it after any change to `FreeAgentDataStore`,
// `AppState`, or `AppState.reconcile(with:)`:
//
//     swift run Antagonise          # all twenty-four
//     ONLY=4 swift run Antagonise   # one scenario
//
// It writes throwaway Keychain items under `com.ratchet.antagonise.<uuid>` and clears each one
// as it goes; if a run is killed part-way, sweep the leftovers with:
//
//     security dump-keychain 2>/dev/null | grep -o 'com\.ratchet\.antagonise\.[A-F0-9-]*' \
//       | sort -u | while read s; do security delete-generic-password -s "$s" >/dev/null 2>&1; done
import AppKit
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
/// `updatedAt` is the tie-break `MostRecentTask.resolve` uses *within* a day, so scenarios that
/// need a deterministic order among same-day entries have to supply it; omitted, it decodes as
/// nil, which sorts as `distantPast`.
func slip(id: Int, task: Int, hours: String, datedOn: String, timerStart: String?, updatedAt: String? = nil) -> String {
    let timer = timerStart.map { #""timer":{"running":true,"start_from":"\#($0)"}"# } ?? #""timer":null"#
    let updated = updatedAt.map { #","updated_at":"\#($0)""# } ?? ""
    return #"{"url":"\#(U)/timeslips/\#(id)","project":"\#(U)/projects/1","task":"\#(U)/tasks/\#(task)","user":"\#(U)/users/1","dated_on":"\#(datedOn)","hours":"\#(hours)","comment":null,\#(timer),"billed_on_invoice":null\#(updated)}"#
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

// MARK: - Scenarios

@MainActor func s1() async throws {
    hdr(1, "User stops the timer while a silent refresh is in flight")
    let stub = Stub()
    let running = slip(id: 9, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z")
    baseRules(stub, running: running, recent: "[\(running)]")
    stub.setRule("timeslips/9/timer", body: "{}")
    // `stopTimer` re-reads the settled timeslip after the DELETE, to pick up the hours the
    // server finally recorded — see its comment.
    stub.setRule("timeslips/9", body: #"{"timeslip":\#(slip(id: 9, task: 1, hours: "0.75", datedOn: today(), timerStart: nil))}"#)
    let gate = GatedStub(inner: stub, gateMatch: "view=running")
    let (store, ts) = makeStore(gate); defer { ts.clear() }
    try await store.refresh()
    let app = AppState(); app.logIn(); app.reconcile(with: store)
    print("   after first refresh: tracking = \(app.trackingTask != nil)")

    gate.armed = true
    let inFlight = Task { @MainActor in try? await store.refresh() }
    guard await awaitGate(gate) else { bad("gate never fired"); return }
    _ = try await store.stopTimer()
    app.stopTracking()
    print("   user stopped: running = \(store.currentRunningTimeslip?.id ?? "nil")")
    gate.release()
    _ = await inFlight.value
    app.reconcile(with: store)
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
    app.reconcile(with: store)
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
    app.reconcile(with: store)
    if case .tracking(let t, _) = app.screen { ok("still tracking, labelled \"\(t.taskName)\" — Stop stays reachable") }
    else { bad("dropped to idle with a timer still running server-side: \(app.screen)") }
    // The placeholder must not become the idle screen's "Start tracking …" row.
    app.stopTracking()
    if case .idleNoHistory = app.screen { ok("placeholder did not pollute most-recent") }
    else { bad("placeholder leaked into most-recent: \(app.screen)") }

    // A running timeslip with no timer start counts from adoption, and has to keep that instant
    // when a later refresh can name its task: re-stamping it would reset the elapsed time.
    let undated = slip(id: 501, task: 7, hours: "0.0", datedOn: today(), timerStart: nil)
    let stub2 = Stub()
    baseRules(stub2, running: undated, recent: "[\(undated)]")
    let (store2, ts2) = makeStore(stub2); defer { ts2.clear() }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let app2 = AppState(clock: { now }); app2.logIn()
    try await store2.refresh()
    app2.reconcile(with: store2)
    let adoptedAt = app2.trackingStartedAtForTesting
    now = now.addingTimeInterval(120)
    stub2.setRule("/tasks?", body: tasks([1, 2, 7]))
    try await store2.refresh()
    app2.reconcile(with: store2)
    if app2.trackingTask?.taskName == "Task7" { ok("an undated timer's placeholder is renamed once the tree names it") }
    else { bad("still labelled \(app2.trackingTask?.taskName ?? "nothing")") }
    if adoptedAt != nil, app2.trackingStartedAtForTesting == adoptedAt { ok("and keeps the start it was adopted with") }
    else { bad("elapsed time re-based: adopted \(String(describing: adoptedAt)), now \(String(describing: app2.trackingStartedAtForTesting))") }
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

@MainActor func s11() async throws {
    hdr(11, "A just-stopped timer must appear in Recent time entries immediately")
    let stub = Stub()
    baseRules(stub, running: nil, recent: "[]")
    // Registered before the bare "v2/timeslips" create rule below: a GET of
    // .../v2/timeslips/42 contains both matches, and rules are first-match-wins in
    // registration order.
    stub.setRule("timeslips/42", body: #"{"timeslip":\#(slip(id: 42, task: 1, hours: "1.5", datedOn: today(), timerStart: nil))}"#)
    stub.setRule("v2/timeslips", body: #"{"timeslip":\#(slip(id: 42, task: 1, hours: "0.0", datedOn: today(), timerStart: nil))}"#)
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()

    // Start: creates timeslip 42 for today and runs its timer.
    stub.setRule("/timer", body: #"{"timeslip":\#(slip(id: 42, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z"))}"#)
    _ = try await store.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    // The server now reports it as running, and has accrued 1.5h by the time it is stopped.
    stub.setRule("view=running", body: #"{"timeslips":[\#(slip(id: 42, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z"))]}"#)
    print("   timeslips before stop: \(store.timeslips.map(\.id))")

    _ = try await store.stopTimer()
    let stopped = store.timeslips.first { $0.id == "\(U)/timeslips/42" }
    if let stopped {
        ok("the stopped entry is in `timeslips`")
        if stopped.hours == 1.5 { ok("with the hours the server finally recorded") }
        else { bad("with stale hours \(stopped.hours), not the server's 1.5") }
        if stopped.timerStartedAt == nil { ok("and no longer marked as running") }
        else { bad("still carries timerStartedAt \(stopped.timerStartedAt!)") }
    } else {
        bad("the stopped entry is missing from `timeslips`: \(store.timeslips.map(\.id))")
    }
}

@MainActor func s12() async throws {
    hdr(12, "After a restart with nothing running, the last tracked task must still be offerable")
    let stub = Stub()
    let older = slip(id: 100, task: 1, hours: "2.0", datedOn: "2026-08-10", timerStart: nil)
    let newest = slip(id: 101, task: 2, hours: "3.0", datedOn: "2026-08-18", timerStart: nil)
    baseRules(stub, running: nil, recent: "[\(older),\(newest)]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }

    // Exactly the launch path: stored tokens -> logIn -> refresh -> reconcile.
    let app = AppState(); app.logIn()
    try await store.refresh()
    app.reconcile(with: store)
    print("   timeslips after launch refresh: \(store.timeslips.map(\.id))")
    print("   screen: \(app.screen)")

    switch app.screen {
    case .idle(let mostRecent):
        if mostRecent.taskId == "\(U)/tasks/2" { ok("the idle screen offers the last task worked on (Task2)") }
        else { bad("offers \(mostRecent.taskName), not the most recent Task2") }
    case .idleNoHistory:
        bad("idle screen has no history, so there is no `Start tracking …` row after a restart")
    default:
        bad("unexpected screen \(app.screen)")
    }

    // A remembered offer is on screen before the launch refresh lands, so starting it has to
    // wait for that refresh rather than fail for want of an account, and must not make the
    // refresh discard its own result.
    let cold = Stub()
    baseRules(cold, running: nil, recent: "[]")
    cold.setRule("v2/timeslips", body: #"{"timeslip":\#(slip(id: 102, task: 1, hours: "0.0", datedOn: today(), timerStart: nil))}"#)
    cold.setRule("/timer", body: #"{"timeslip":\#(slip(id: 102, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z"))}"#)
    let gate = GatedStub(inner: cold, gateMatch: "view=running")
    let (coldStore, ts2) = makeStore(gate); defer { ts2.clear() }
    gate.armed = true
    let launchRefresh = Task { @MainActor in try? await coldStore.refresh() }
    guard await awaitGate(gate) else { bad("gate never fired"); return }
    let start = Task { @MainActor in
        try await coldStore.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    }
    // Let the start reach the account check while the launch refresh is still held.
    for _ in 0..<5 { await Task.yield() }
    gate.release()
    _ = await launchRefresh.value
    do {
        _ = try await start.value
        ok("starting before the launch refresh lands waits for it, then succeeds")
    } catch {
        bad("starting before the launch refresh landed failed: \(error)")
    }
    if coldStore.lastRefreshedAt != nil { ok("and the launch refresh still committed") }
    else { bad("the start made the launch refresh discard its result") }

    // A second click while that start waits must queue behind it: two starts at once can each
    // find no timeslip for today and create one apiece.
    let twice = Stub()
    baseRules(twice, running: nil, recent: "[]")
    twice.setRule("v2/timeslips", body: #"{"timeslip":\#(slip(id: 103, task: 1, hours: "0.0", datedOn: today(), timerStart: nil))}"#)
    twice.setRule("/timer", body: #"{"timeslip":\#(slip(id: 103, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z"))}"#)
    let (twiceStore, ts3) = makeStore(twice); defer { ts3.clear() }
    try await twiceStore.refresh()
    twice.log = []
    let first = Task { @MainActor in
        try await twiceStore.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    }
    let second = Task { @MainActor in
        try await twiceStore.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    }
    _ = try? await first.value
    _ = try? await second.value
    let calls = twice.log.map { "\($0.method) \($0.url)" }
    let firstTimerStart = calls.firstIndex { $0.hasPrefix("POST") && $0.hasSuffix("/timer") }
    let secondRunningCheck = calls.indices.filter { calls[$0].contains("view=running") }.dropFirst().first
    if let firstTimerStart, let secondRunningCheck, secondRunningCheck > firstTimerStart {
        ok("a second start waits for the first to finish")
    } else {
        bad("two starts ran together: \(calls)")
    }
}

/// Every action a no-op: these scenarios assert what the menu *shows*, never what clicking does.
@MainActor
let inertActions = MenuActions(
    logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {}, switchTask: { _ in },
    refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {}, addTask: { _, _ in }, addClient: {},
    addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in },
    switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
)

@MainActor
func recentEntryTitles(_ app: AppState, _ store: FreeAgentDataStore) -> [String] {
    let menu = MenuBuilder.build(state: app, dataStore: store, actions: inertActions)
    guard let submenu = menu.item(withTitle: "Recent time entries")?.submenu else { return [] }
    return submenu.items.map(\.title).filter { !$0.isEmpty }
}

@MainActor func s13() async throws {
    hdr(13, "A local write must force the next silent refresh past the 120s staleness gate")
    let stub = Stub()
    baseRules(stub, running: nil, recent: "[]")
    stub.setRule("v2/timeslips", body: #"{"timeslip":\#(slip(id: 55, task: 1, hours: "0.0", datedOn: today(), timerStart: nil))}"#)
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()
    if !store.hasLocalWritesSinceRefresh { ok("a fresh refresh leaves nothing unreconciled") }
    else { bad("flag set straight after a refresh") }

    stub.setRule("/timer", body: #"{"timeslip":\#(slip(id: 55, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z"))}"#)
    _ = try await store.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    // The gate in StatusItemController.silentlyRefreshIfStale() reads exactly this pair: without
    // the flag, `lastRefreshedAt` is seconds old and the next menu open skips refreshing.
    if store.hasLocalWritesSinceRefresh { ok("starting a timer marks the cache unreconciled") }
    else { bad("a start left the cache looking freshly refreshed") }

    stub.setRule("view=running", body: #"{"timeslips":[\#(slip(id: 55, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z"))]}"#)
    try await store.refresh()
    if !store.hasLocalWritesSinceRefresh { ok("a completed refresh clears it again") }
    else { bad("refresh did not clear the flag") }
}

@MainActor func s14() async throws {
    hdr(14, "Recent time entries must show a just-stopped entry without waiting for a refresh")
    let stub = Stub()
    baseRules(stub, running: nil, recent: "[]")
    stub.setRule("timeslips/77", body: #"{"timeslip":\#(slip(id: 77, task: 1, hours: "1.5", datedOn: today(), timerStart: nil))}"#)
    stub.setRule("v2/timeslips", body: #"{"timeslip":\#(slip(id: 77, task: 1, hours: "0.0", datedOn: today(), timerStart: nil))}"#)
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    let app = AppState(); app.logIn()
    try await store.refresh()
    app.reconcile(with: store)

    stub.setRule("/timer", body: #"{"timeslip":\#(slip(id: 77, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z"))}"#)
    let started = try await store.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    app.startTracking(acmeRef, startedAt: started.timerStartedAt ?? Date())
    stub.setRule("view=running", body: #"{"timeslips":[\#(slip(id: 77, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z"))]}"#)

    _ = try await store.stopTimer()
    app.stopTracking()
    // Deliberately no refresh() between the stop and the menu build — that is the whole point.
    let titles = recentEntryTitles(app, store)
    print("   recent rows after stopping: \(titles)")
    if titles.contains(where: { $0.contains("Task1") && $0.contains("1:30") }) {
        ok("the stopped entry is listed, with the hours the server settled on")
    } else {
        bad("no row for the entry just stopped")
    }
}

/// In-memory `MostRecentTaskStore`, standing in for the real `UserDefaults`-backed one so these
/// scenarios never touch the user's actual preferences.
@MainActor
final class FakeMostRecentStore: MostRecentTaskStore {
    var stored: TrackedTaskRef?
    init(_ stored: TrackedTaskRef?) { self.stored = stored }
    nonisolated func load() -> TrackedTaskRef? { MainActor.assumeIsolated { stored } }
    nonisolated func save(_ ref: TrackedTaskRef?) { MainActor.assumeIsolated { stored = ref } }
}

@MainActor func s15() async throws {
    hdr(15, "A remembered task must be re-checked against the tree each refresh")
    let stub = Stub()
    let recent = slip(id: 300, task: 2, hours: "1.0", datedOn: "2026-08-18", timerStart: nil)
    baseRules(stub, running: nil, recent: "[\(recent)]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()

    // Re-stamping is only observable against a store whose history offers nothing: on every other
    // path the newest history entry replaces the remembered ref outright (scenario 16).
    let quiet = Stub()
    baseRules(quiet, running: nil, recent: "[]")
    let (quietStore, ts3) = makeStore(quiet); defer { ts3.clear() }
    try await quietStore.refresh()

    // Remembered from a previous launch, under the name the task had back then.
    let stale = TrackedTaskRef(clientId: "\(U)/contacts/1", clientName: "Acme Ltd (old)",
                               projectId: "\(U)/projects/1", projectName: "Site",
                               taskId: "\(U)/tasks/1", taskName: "Task1 (old name)")
    let renamedStore = FakeMostRecentStore(stale)
    let renamed = AppState(mostRecentStore: renamedStore); renamed.logIn()
    renamed.reconcile(with: quietStore)
    if renamed.mostRecent?.taskName == "Task1", renamed.mostRecent?.clientName == "Acme" {
        ok("a renamed task is re-stamped with its current names")
    } else {
        bad("still offering stale names: \(renamed.mostRecent.map { "\($0.clientName)/\($0.taskName)" } ?? "nil")")
    }
    if renamedStore.stored?.taskName == "Task1" { ok("and the corrected ref was written back to disk") }
    else { bad("disk still holds the stale ref") }

    // Remembered task since deleted in FreeAgent: it must be dropped, not offered.
    let gone = TrackedTaskRef(clientId: "\(U)/contacts/1", clientName: "Acme",
                              projectId: "\(U)/projects/1", projectName: "Site",
                              taskId: "\(U)/tasks/99", taskName: "Deleted task")
    let deletedStore = FakeMostRecentStore(gone)
    let deleted = AppState(mostRecentStore: deletedStore); deleted.logIn()
    deleted.reconcile(with: store)
    if deleted.mostRecent?.taskId == "\(U)/tasks/2" {
        ok("a deleted task is dropped and replaced from history")
    } else {
        bad("offered \(deleted.mostRecent?.taskName ?? "nil") for a task that no longer exists")
    }
    if deletedStore.stored?.taskId == "\(U)/tasks/2" { ok("and disk holds the replacement, not the dead ref") }
    else { bad("disk holds \(deletedStore.stored?.taskName ?? "nil") after the dead ref was dropped") }

    // An empty tree (before the first refresh lands, or after a failed one) must not be read as
    // "everything was deleted" — that would wipe the remembered task on every cold launch.
    let coldStore = FakeMostRecentStore(stale)
    let cold = AppState(mostRecentStore: coldStore); cold.logIn()
    let (emptyStore, ts2) = makeStore(Stub()); defer { ts2.clear() }
    cold.reconcile(with: emptyStore)
    if cold.mostRecent != nil { ok("an unrefreshed store leaves the remembered task alone") }
    else { bad("a cold launch wiped the remembered task") }
}

@MainActor func s16() async throws {
    hdr(16, "A derived suggestion must follow history when the work moves on elsewhere")
    let stub = Stub()
    let taskA = slip(id: 800, task: 1, hours: "2.0", datedOn: "2026-08-18", timerStart: nil)
    baseRules(stub, running: nil, recent: "[\(taskA)]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    let disk = FakeMostRecentStore(nil)
    let app = AppState(mostRecentStore: disk); app.logIn()
    try await store.refresh()
    app.reconcile(with: store)
    print("   after launch: \(app.mostRecent?.taskName ?? "nil")")
    guard app.mostRecent?.taskId == "\(U)/tasks/1" else {
        bad("launch derived \(app.mostRecent?.taskName ?? "nil") instead of Task1"); return
    }
    ok("launch derives Task1 from history")
    if disk.stored?.taskId == "\(U)/tasks/1" { ok("and persists it, so a cold launch has an answer before its refresh lands") }
    else { bad("a derived suggestion never reached disk") }

    // The afternoon's work happens in the FreeAgent web app and this app only ever refreshes,
    // so the offer has to follow history on every refresh, not just seed from it once.
    let taskB = slip(id: 801, task: 2, hours: "3.0", datedOn: "2026-08-19", timerStart: nil)
    stub.setRule("timeslips?", body: #"{"timeslips":[\#(taskA),\#(taskB)]}"#)
    try await store.refresh()
    app.reconcile(with: store)
    print("   after a silent refresh that sees Task2: \(app.mostRecent?.taskName ?? "nil")")
    if app.mostRecent?.taskId == "\(U)/tasks/2" { ok("the offer follows history to Task2 within the session") }
    else { bad("still offering \(app.mostRecent?.taskName ?? "nil") after history moved on to Task2") }
    if disk.stored?.taskId == "\(U)/tasks/2" { ok("and disk followed it, so memory and disk agree") }
    else { bad("disk still holds \(disk.stored?.taskName ?? "nil")") }

    // A refresh still in flight when the user logs out lands afterwards. Its history belongs to
    // the account that just left, so it must not go back on disk.
    app.logOut()
    app.reconcile(with: store)
    if app.mostRecent == nil, disk.stored == nil { ok("a refresh landing after log out restores nothing") }
    else { bad("log out undone: memory=\(app.mostRecent?.taskName ?? "nil") disk=\(disk.stored?.taskName ?? "nil")") }
    // Likewise a start still in flight when the user logs out.
    app.startTracking(acmeRef)
    if app.trackingTask == nil, disk.stored == nil { ok("and neither does a start completing after it") }
    else { bad("a late start tracked \(app.trackingTask?.taskName ?? "nothing"), disk=\(disk.stored?.taskName ?? "nil")") }

    // An expired session is not a deliberate log out: the same account usually signs straight
    // back in, and should find its task still offered.
    let expiredDisk = FakeMostRecentStore(nil)
    let expired = AppState(mostRecentStore: expiredDisk); expired.logIn()
    expired.reconcile(with: store)
    expired.logOut(forgettingMostRecent: false)
    if expiredDisk.stored?.taskId == "\(U)/tasks/2", expired.mostRecent?.taskId == "\(U)/tasks/2" {
        ok("an expired session keeps the task for the next sign-in")
    } else {
        bad("an expired session lost the task: memory=\(expired.mostRecent?.taskName ?? "nil") disk=\(expiredDisk.stored?.taskName ?? "nil")")
    }
}

@MainActor func s17() async throws {
    hdr(17, "History must not out-rank the task whose timer is running")
    let stub = Stub()
    // FreeAgent doesn't reliably bump `updated_at` when it resumes an existing timeslip's timer,
    // so the entry that is running right now can sort behind an earlier one from the same day.
    let running = slip(id: 900, task: 2, hours: "0.0", datedOn: today(), timerStart: "2026-08-27T09:00:00Z")
    let earlier = slip(id: 901, task: 1, hours: "1.0", datedOn: today(), timerStart: nil,
                       updatedAt: "2026-08-27T11:00:00Z")
    baseRules(stub, running: running, recent: "[\(running),\(earlier)]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    let disk = FakeMostRecentStore(nil)
    let app = AppState(mostRecentStore: disk); app.logIn()
    try await store.refresh()
    app.reconcile(with: store)
    print("   newest resolvable history entry is Task1; the running timer is on Task2")
    if app.trackingTask?.taskId == "\(U)/tasks/2" { ok("tracking the running task") }
    else { bad("tracking \(app.trackingTask?.taskName ?? "nothing"), not the running Task2") }
    if app.mostRecent?.taskId == "\(U)/tasks/2" { ok("and Task2 stays most-recent despite Task1 sorting first") }
    else { bad("history overrode the running task: most-recent is \(app.mostRecent?.taskName ?? "nil")") }
    // The ~2-minute silent refresh is where the override would actually land.
    try await store.refresh()
    app.reconcile(with: store)
    if app.mostRecent?.taskId == "\(U)/tasks/2" { ok("and still does after a later refresh") }
    else { bad("a later refresh overrode it: \(app.mostRecent?.taskName ?? "nil")") }

    // The guard is narrow on purpose: with nothing running, history is authoritative again.
    stub.setRule("view=running", body: #"{"timeslips":[]}"#)
    try await store.refresh()
    app.reconcile(with: store)
    if app.trackingTask == nil, app.mostRecent?.taskId == "\(U)/tasks/1" {
        ok("once the timer stops, history takes over again")
    } else {
        bad("after the stop: tracking=\(app.trackingTask?.taskName ?? "nil") most-recent=\(app.mostRecent?.taskName ?? "nil")")
    }
}

@MainActor func s18() async throws {
    hdr(18, "A remembered task must be forgotten once its project or client leaves the tree")
    let stub = Stub()
    // No history at all, so nothing can replace the remembered ref and whatever happens to it is
    // the only thing on show.
    baseRules(stub, running: nil, recent: "[]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()

    // A refresh commits all or nothing, so projects/9 missing from it is a project FreeAgent no
    // longer lists, not a fetch that came back short.
    let remembered = TrackedTaskRef(clientId: "\(U)/contacts/1", clientName: "Acme",
                                    projectId: "\(U)/projects/9", projectName: "Site B",
                                    taskId: "\(U)/tasks/3", taskName: "Task3")
    let disk = FakeMostRecentStore(remembered)
    let app = AppState(mostRecentStore: disk); app.logIn()
    app.reconcile(with: store)
    print("   project missing -> memory=\(app.mostRecent?.taskName ?? "nil") disk=\(disk.stored?.taskName ?? "nil")")
    if case .idleNoHistory = app.screen { ok("a task whose project left the tree is no longer offered") }
    else { bad("still offering \(app.mostRecent?.taskName ?? "nil")") }
    if disk.stored == nil { ok("and it was cleared from disk") }
    else { bad("left on disk: \(disk.stored!.taskName)") }

    // One level up: a client missing entirely, as for a hidden contact, or a task remembered from
    // another account.
    let otherClient = TrackedTaskRef(clientId: "\(U)/contacts/9", clientName: "Beta",
                                     projectId: "\(U)/projects/9", projectName: "Site B",
                                     taskId: "\(U)/tasks/3", taskName: "Task3")
    let otherDisk = FakeMostRecentStore(otherClient)
    let other = AppState(mostRecentStore: otherDisk); other.logIn()
    other.reconcile(with: store)
    if other.mostRecent == nil, otherDisk.stored == nil { ok("a missing client is read the same way") }
    else { bad("a missing client kept the ref: memory=\(other.mostRecent?.taskName ?? "nil") disk=\(otherDisk.stored?.taskName ?? "nil")") }
}

@MainActor func s19() async throws {
    hdr(19, "A task genuinely absent from a fetched project must still be forgotten")
    let stub = Stub()
    baseRules(stub, running: nil, recent: "[]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()

    // projects/1 *is* in the tree and lists tasks 1 and 2, so its task list really was fetched:
    // tasks/99 is gone, not merely unseen.
    let dead = TrackedTaskRef(clientId: "\(U)/contacts/1", clientName: "Acme",
                              projectId: "\(U)/projects/1", projectName: "Site",
                              taskId: "\(U)/tasks/99", taskName: "Deleted task")
    let disk = FakeMostRecentStore(dead)
    let app = AppState(mostRecentStore: disk); app.logIn()
    app.reconcile(with: store)
    print("   screen: \(app.screen)")
    if case .idleNoHistory = app.screen { ok("no `Start tracking …` row for a task that would fail server-side") }
    else { bad("still offering \(app.mostRecent?.taskName ?? "nil")") }
    if disk.stored == nil { ok("and the dead ref was cleared from disk") }
    else { bad("dead ref left on disk: \(disk.stored!.taskName)") }
}

/// FreeAgent's timeslip store in miniature, for scenarios where a create has to land server-side
/// before anything goes wrong: `POST /timeslips` is applied first, then faults are injected, and
/// timeslip lists are answered from what was applied. A `PUT` to an entry it holds is merged into
/// it. Everything else falls through to `inner`.
@MainActor
final class TimeslipServer: FreeAgentTransport {
    enum CreateFault { case none, loseResponse, neverArrives, cannotConnect }
    let inner: Stub
    var createFault = CreateFault.none
    /// Faults for the next creates in turn, ahead of `createFault`.
    var createFaults: [CreateFault] = []
    /// After the next create is applied, drops its response and every request after it, as if
    /// the network went down with the response in flight and stayed down.
    var offlineAfterCreate = false
    var offline = false
    private(set) var slips: [[String: Any]] = []
    /// The `timeslip` object of every update applied, as sent.
    private(set) var puts: [[String: Any]] = []
    /// Every create sent, whether or not it arrived.
    private(set) var posts = 0
    private(set) var lookups = 0
    /// `lookups` as each create was sent, so a scenario can tell what each create waited for.
    private(set) var lookupsAtCreate: [Int] = []
    init(inner: Stub) { self.inner = inner }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let answer = try await answer(request) { return answer }
        return try await inner.send(request)
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse)? {
        let url = request.url!
        let isTimeslips = url.path.hasSuffix("/v2/timeslips")
        if isTimeslips, request.httpMethod == "POST" { posts += 1; lookupsAtCreate.append(lookups) }
        if offline { throw URLError(.notConnectedToInternet) }
        if request.httpMethod == "PUT", let index = ids.firstIndex(of: url.absoluteString) {
            let envelope = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: [String: Any]]
            let sent = envelope?["timeslip"] ?? [:]
            puts.append(sent)
            // FreeAgent changes only the attributes a PUT carries; an omitted one keeps its value.
            slips[index].merge(sent) { _, new in new }
            return try respond(request, ["timeslip": slips[index]], status: 200)
        }
        guard isTimeslips else { return nil }
        if request.httpMethod == "POST" {
            let createFault = createFaults.isEmpty ? createFault : createFaults.removeFirst()
            if createFault == .cannotConnect { throw URLError(.cannotConnectToHost) }
            if createFault == .neverArrives { throw URLError(.notConnectedToInternet) }
            let envelope = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: [String: Any]]
            var slip = envelope?["timeslip"] ?? [:]
            let now = ISO8601DateFormatter().string(from: Date())
            slip["url"] = "\(U)/timeslips/\(1000 + slips.count)"
            slip["timer"] = NSNull()
            slip["billed_on_invoice"] = NSNull()
            slip["created_at"] = now
            slip["updated_at"] = now
            slips.append(slip)
            if offlineAfterCreate { offline = true; throw URLError(.networkConnectionLost) }
            if createFault == .loseResponse { throw URLError(.networkConnectionLost) }
            return try respond(request, ["timeslip": slip], status: 201)
        }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        guard query["view"] == nil else { return nil }
        if query["task"] != nil { lookups += 1 }
        let listed = slips.filter { slip in
            let day = slip["dated_on"] as? String ?? ""
            return ["task", "project", "user"].allSatisfy { key in query[key].map { $0 == slip[key] as? String } ?? true }
                && (query["from_date"].map { day >= $0 } ?? true)
                && (query["to_date"].map { day <= $0 } ?? true)
        }
        return try respond(request, ["timeslips": listed], status: 200)
    }

    private func respond(_ request: URLRequest, _ object: Any, status: Int) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: object),
         HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    var ids: [String] { slips.compactMap { $0["url"] as? String } }
}

@MainActor
func logTask1(_ store: FreeAgentDataStore, on date: Date = Date()) async throws -> RatchetTimeslip {
    try await store.logTime(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1",
                            date: date, hours: 1.5, comment: "Wireframes")
}

@MainActor func s20() async throws {
    hdr(20, "A create whose response is lost must be adopted, not logged twice")
    let stub = Stub()
    baseRules(stub)
    let server = TimeslipServer(inner: stub)
    let (store, ts) = makeStore(server); defer { ts.clear() }
    try await store.refresh()

    server.createFault = .loseResponse
    let logged: RatchetTimeslip
    do { logged = try await logTask1(store) } catch {
        bad("the lost create surfaced as an error, so retrying it would log a duplicate: \(error)"); return
    }
    print("   server holds \(server.ids); logTime returned \(logged.id)")
    if server.slips.count == 1 { ok("exactly one entry exists server-side") }
    else { bad("\(server.slips.count) entries server-side") }
    if store.timeslips.map(\.id) == server.ids { ok("and the local cache holds it") }
    else { bad("local cache holds \(store.timeslips.map(\.id))") }

    server.createFault = .none
    _ = try await logTask1(store)
    if server.slips.count == 2 { ok("logging the same entry again on purpose still creates a second") }
    else { bad("a deliberate second identical entry left \(server.slips.count) server-side") }
}

@MainActor func s21() async throws {
    hdr(21, "A lost create that can't be checked must be checked before it is posted again")
    let stub = Stub()
    baseRules(stub)
    let server = TimeslipServer(inner: stub)
    let (store, ts) = makeStore(server); defer { ts.clear() }
    try await store.refresh()

    server.offlineAfterCreate = true
    do { _ = try await logTask1(store); bad("reported success with nothing confirmed") } catch {
        print("   still offline -> \(error)")
        if case DataStoreError.unconfirmed = error { ok("the error says the entry may exist, not that it failed") }
        else { bad("the error reads as a plain failure, inviting a blind retry") }
    }
    server.offlineAfterCreate = false
    do { _ = try await logTask1(store); bad("a retry while offline reported success") } catch {
        if server.posts == 1 { ok("a retry while still offline posts nothing") }
        else { bad("a retry while offline posted again (\(server.posts) POSTs)") }
    }

    // Back online. The same entry again is either the retry or a deliberate second, so the
    // user is told it was already there rather than shown a bare "Time Logged".
    server.offline = false
    do {
        let retried = try await logTask1(store)
        bad("reported \(retried.id) as newly logged, hiding that it was the earlier attempt's entry")
    } catch DataStoreError.alreadyLogged {
        ok("the retry reports the entry as already logged")
    } catch {
        bad("the retry threw \(error), not alreadyLogged")
    }
    print("   back online: server holds \(server.ids); POSTs \(server.posts)")
    if server.slips.count == 1, server.posts == 1 { ok("and adopted it instead of posting a duplicate") }
    else { bad("\(server.slips.count) entries server-side after the retry") }
    if store.timeslips.map(\.id) == server.ids { ok("and the local cache holds it") }
    else { bad("local cache holds \(store.timeslips.map(\.id))") }

    _ = try await logTask1(store)
    if server.slips.count == 2 { ok("once settled, the same entry can be logged again on purpose") }
    else { bad("\(server.slips.count) entries after a deliberate second") }
}

@MainActor func s22() async throws {
    hdr(22, "A create that never arrived must not adopt an identical entry logged just before it")
    let stub = Stub()
    baseRules(stub)
    let server = TimeslipServer(inner: stub)
    let (store, ts) = makeStore(server); defer { ts.clear() }
    try await store.refresh()

    let first = try await logTask1(store)
    server.createFault = .neverArrives
    do { _ = try await logTask1(store); bad("adopted \(first.id) as the second entry, which was never created") } catch {
        print("   second create never arrived -> \(error)")
        ok("the earlier identical entry was not mistaken for this one")
    }
    server.createFault = .none
    _ = try await logTask1(store)
    print("   after the retry: server holds \(server.ids)")
    if server.slips.count == 2 { ok("the retry logged the second entry") }
    else { bad("\(server.slips.count) entries server-side, expected 2") }

    // A failure to connect means nothing was sent, so there is nothing to look for.
    server.createFault = .cannotConnect
    let lookupsBefore = server.lookups
    _ = try? await logTask1(store)
    if server.lookups == lookupsBefore { ok("a create that couldn't connect isn't looked for") }
    else { bad("looked for the result of a create that was never sent") }

    // A back-dated entry falls outside refresh()'s window, so the next refresh drops it from the
    // cache; it is still Ratchet's own, and still not this request's.
    server.createFault = .none
    let monthAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
    let backDated = try await logTask1(store, on: monthAgo)
    try await store.refresh()
    server.createFault = .neverArrives
    do { _ = try await logTask1(store, on: monthAgo); bad("adopted the back-dated \(backDated.id), which left the cache at the refresh") }
    catch { ok("nor is a back-dated entry the cache no longer holds") }
}

@MainActor func s23() async throws {
    hdr(23, "An identical create sent while another is unsettled must wait for it, not race it")
    let stub = Stub()
    baseRules(stub)
    let server = TimeslipServer(inner: stub)
    let (store, ts) = makeStore(server); defer { ts.clear() }
    try await store.refresh()

    // The first never arrives; the second is submitted while the first is still in flight.
    server.createFaults = [.neverArrives]
    let first = Task { try await logTask1(store) }
    let second = Task { try await logTask1(store) }
    let firstResult = await first.result
    let secondResult = await second.result
    print("   creates sent after \(server.lookupsAtCreate) lookups; server holds \(server.ids)")

    if case .failure(DataStoreError.unconfirmed) = firstResult { ok("the first is reported unconfirmed") }
    else { bad("the first ended \(firstResult), not unconfirmed") }
    // Racing, the second posts before the first is settled: the first's lookup can then adopt
    // the second's entry, and the second's success clears the first's record.
    if server.lookupsAtCreate == [0, 2] { ok("the second was sent only after the first was settled and checked again") }
    else { bad("the second create raced the first (lookups at each create: \(server.lookupsAtCreate))") }
    if case .success(let logged) = secondResult, server.ids == [logged.id] { ok("and logged its own entry") }
    else { bad("the second ended \(secondResult) with \(server.ids) server-side") }
}

@MainActor func s24() async throws {
    hdr(24, "Clearing an entry's comment must clear it in FreeAgent")
    let stub = Stub()
    baseRules(stub)
    let server = TimeslipServer(inner: stub)
    let (store, ts) = makeStore(server); defer { ts.clear() }
    try await store.refresh()
    let logged = try await logTask1(store)

    // What the edit form passes once its comment field has been emptied.
    let edited = try await store.updateTimeslip(id: logged.id, taskId: logged.taskId, projectId: logged.projectId,
                                                clientId: logged.clientId, date: logged.day, hours: logged.hours,
                                                comment: TaskNameValidator.validate(""))
    func shown(_ value: Any?) -> String { value.map { $0 is String ? "\"\($0)\"" : "\($0)" } ?? "<absent>" }
    let sent = server.puts.last?["comment"]
    print("   PUT comment: \(shown(sent)); FreeAgent then holds \(shown(server.slips[0]["comment"]))")
    if sent as? String == "" { ok("the PUT carries the cleared comment") }
    else { bad("the PUT carries comment \(shown(sent)), so FreeAgent keeps the old one") }
    if (server.slips[0]["comment"] as? String).flatMap(TaskNameValidator.validate) == nil { ok("the comment is gone in FreeAgent") }
    else { bad("FreeAgent still holds the comment") }
    if edited.comment.flatMap(TaskNameValidator.validate) == nil { ok("and from the local cache") }
    else { bad("the local cache still shows \(edited.comment!)") }
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
        if want(11) { try await s11() }
        if want(12) { try await s12() }
        if want(13) { try await s13() }
        if want(14) { try await s14() }
        if want(15) { try await s15() }
        if want(16) { try await s16() }
        if want(17) { try await s17() }
        if want(18) { try await s18() }
        if want(19) { try await s19() }
        if want(20) { try await s20() }
        if want(21) { try await s21() }
        if want(22) { try await s22() }
        if want(23) { try await s23() }
        if want(24) { try await s24() }
    } catch { print("harness error: \(error)"); bugCount += 1 }
    print("\n\(bugCount == 0 ? "ALL CLEAR" : "\(bugCount) BUG LINE(S)")")
    exit(bugCount == 0 ? 0 : 1)
}
RunLoop.main.run()
