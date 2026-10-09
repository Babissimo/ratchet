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
// entry's comment, which FreeAgent must be told about; 25 and 26 cover the timer's start (a start
// FreeAgent reports as not running, and an edit whose reply carries no timer); 27-29 cover a
// refresh that overlaps a mutation: it waits for one in flight before it fetches (27, 29), and is
// discarded and fetched again if one begins before it commits, which the count of mutations in
// flight catches (28), or the epoch's bump on exit if the mutation ends first (1, 2); 30-32 cover
// a new client, project or task whose create response is lost, which a retry must adopt rather
// than make again without taking an earlier one of the same name for it, and a create FreeAgent
// refuses, which must read as refused; 33 covers a project or task FreeAgent makes after its
// parent has left the cache, which must not read as a failure either; 34-36 cover callers that
// rely on a refresh having committed whenever it returns (a start made before the launch refresh
// lands, a login while the last session's stop is in flight, and a manual refresh that joins an
// overtaken one); 37 covers a login while the last session's refresh is in flight, which it must
// not take as its own; 38-43 cover work a session leaves in flight as it logs out, which must not
// reach the next: a token refresh that would replace its sign-in, restore the one logged out, or
// fail its own (38), the company "Open FreeAgent" opens (39), a start or logged entry that would
// send with its sign-in (40-42), and a create left unsettled that would be looked for in its
// account (43). Each drives the real `FreeAgentDataStore` against a scriptable stub transport and
// asserts the *fixed* behaviour, so a `BUG` line means a regression. Exits non-zero if any
// scenario fails.
//
// This is an executable rather than an XCTest case so that it runs on a machine without Xcode,
// where `swift test` cannot (see CLAUDE.md); CI runs it as well. Run it after any change to
// `FreeAgentDataStore`, `AppState`, or `AppState.reconcile(with:)`:
//
//     swift run Antagonise          # all forty-three
//     ONLY=4 swift run Antagonise   # one scenario
//
// It writes throwaway Keychain items under `com.ratchet.antagonise.<uuid>`. Each scenario clears
// its own, and a run ended early by the watchdog or by SIGINT, SIGTERM, SIGHUP or SIGALRM clears
// the rest before it exits. A crash or SIGKILL can still leave some behind; sweep them with:
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
    var log: [(method: String, url: String, body: String, bearer: String)] = []

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await MainActor.run {
            let url = request.url!.absoluteString
            log.append((request.httpMethod ?? "?", url, String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "",
                        request.value(forHTTPHeaderField: "Authorization") ?? ""))
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

/// Holds the reply to the first request matching `gateMatch` (and `gateMethod`) until released, so
/// a user action and a refresh can be interleaved. The inner transport answers as the request is
/// sent, so a held reply describes FreeAgent as it was then, whatever the scenario changes
/// meanwhile; a request that gets no reply has its failure held instead. Gates stack, so two
/// requests can each be held and released separately.
@MainActor
final class GatedStub: FreeAgentTransport {
    let inner: any FreeAgentTransport & Sendable
    let gateMatch: String
    /// Limits the gate to one HTTP method (nil for any), for a `gateMatch` that is also part of
    /// another request's URL, as a timeslip's URL is of its timer's.
    let gateMethod: String?
    var armed = false
    private(set) var gateHit = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(inner: any FreeAgentTransport & Sendable, gateMatch: String, gateMethod: String? = nil) {
        self.inner = inner; self.gateMatch = gateMatch; self.gateMethod = gateMethod
    }

    /// Registers the continuation synchronously on the main actor, so `release()` can never run
    /// before the waiter is recorded — that ordering hole deadlocks instead of failing.
    private func waitIfGated(_ url: String, method: String?) async {
        guard armed, url.contains(gateMatch), gateMethod == nil || gateMethod == method, !gateHit else { return }
        gateHit = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiting.append(c) }
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Result<(Data, HTTPURLResponse), Error>
        do { reply = .success(try await inner.send(request)) } catch { reply = .failure(error) }
        await waitIfGated(request.url!.absoluteString, method: request.httpMethod)
        return try reply.get()
    }

    func release() { let w = waiting; waiting = []; w.forEach { $0.resume() } }
}

/// Records how a task ended, so a scenario can check whether it has yet and give up on one that
/// never does rather than hang on it.
@MainActor
final class Outcome<T: Sendable> {
    private(set) var result: Result<T, Error>?
    init(_ task: Task<T, Error>) { Task { @MainActor in self.result = await task.result } }
    func ended() async -> Bool { await eventually { result != nil } }
}

/// Long enough for work that should be held back to have run, had it not been, before a scenario
/// checks that it hasn't.
@MainActor
func settle() async { try? await Task.sleep(nanoseconds: 200_000_000) }

@MainActor
func awaitGate(_ gate: GatedStub) async -> Bool { await eventually { gate.gateHit } }

@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if condition() { return true }
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
/// nil, which sorts as `distantPast`. `timerRunning` needs a `timerStart`; without one the timer
/// is null.
func slip(id: Int, task: Int, hours: String, datedOn: String, timerStart: String?, timerRunning: Bool = true,
          updatedAt: String? = nil) -> String {
    let timer = timerStart.map { #""timer":{"running":\#(timerRunning),"start_from":"\#($0)"}"# } ?? #""timer":null"#
    let updated = updatedAt.map { #","updated_at":"\#($0)""# } ?? ""
    return #"{"url":"\#(U)/timeslips/\#(id)","project":"\#(U)/projects/1","task":"\#(U)/tasks/\#(task)","user":"\#(U)/users/1","dated_on":"\#(datedOn)","hours":"\#(hours)","comment":null,\#(timer),"billed_on_invoice":null\#(updated)}"#
}
func today() -> String { CalendarDay.dayString(from: Date()) }

/// Every store `makeStore` has made. `exit` and a fatal signal end the process without unwinding,
/// so a scenario cut short never reaches its `defer { ts.clear() }`; `clearMadeTokenStores()`
/// clears these instead. Locked, because the signal handlers run off the main thread.
var madeTokenStores: [KeychainTokenStore] = []
let madeTokenStoresLock = NSLock()

func clearMadeTokenStores() {
    madeTokenStoresLock.lock(); defer { madeTokenStoresLock.unlock() }
    madeTokenStores.forEach { $0.clear() }
}

@MainActor
func makeStore(_ transport: FreeAgentTransport) -> (FreeAgentDataStore, KeychainTokenStore) {
    let ts = KeychainTokenStore(service: "com.ratchet.antagonise.\(UUID().uuidString)")
    madeTokenStoresLock.lock(); madeTokenStores.append(ts); madeTokenStoresLock.unlock()
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
    let stopped = slip(id: 9, task: 1, hours: "0.75", datedOn: today(), timerStart: nil)
    baseRules(stub, running: running, recent: "[\(running)]")
    stub.setRule("timeslips/9/timer", body: "{}")
    // `stopTimer` re-reads the settled timeslip after the DELETE, to pick up the hours the
    // server finally recorded — see its comment.
    stub.setRule("timeslips/9", body: #"{"timeslip":\#(stopped)}"#)
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
    // FreeAgent has the timer stopped now; only the held reply predates that.
    stub.setRule("view=running", body: #"{"timeslips":[]}"#)
    stub.setRule("timeslips?", body: #"{"timeslips":[\#(stopped)]}"#)
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
    let runningSlip = slip(id: 42, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z")
    stub.setRule("timeslips?", body: #"{"timeslips":[]}"#)
    stub.setRule("/timer", body: #"{"timeslip":\#(runningSlip)}"#)
    let started = try await store.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    app.startTracking(acmeRef, startedAt: started.timerStartedAt ?? Date())
    print("   user started: running = \(store.currentRunningTimeslip?.id ?? "nil")")
    // FreeAgent has the timer running now; only the held reply predates that.
    stub.setRule("view=running", body: #"{"timeslips":[\#(runningSlip)]}"#)
    stub.setRule("timeslips?", body: #"{"timeslips":[\#(runningSlip)]}"#)
    gate.release()
    _ = await inFlight.value
    app.reconcile(with: store)
    if store.currentRunningTimeslip != nil, app.trackingTask != nil { ok("the start survived the concurrent refresh") }
    else { bad("in-flight refresh erased the just-started timer") }

    // A start that throws may still have changed FreeAgent, so its exit counts as well.
    let failing = Stub()
    baseRules(failing, running: nil, recent: "[]")
    let created = slip(id: 44, task: 1, hours: "0.0", datedOn: today(), timerStart: nil)
    failing.setRule("v2/timeslips", body: #"{"timeslip":\#(created)}"#)
    failing.setRule("/timer", body: "{}", status: 500)
    let failingGate = GatedStub(inner: failing, gateMatch: "view=running")
    let (failingStore, ts2) = makeStore(failingGate); defer { ts2.clear() }
    try await failingStore.refresh()
    let setUpAt = failingStore.lastRefreshedAt
    failingGate.armed = true
    let failingRefresh = Outcome(Task { @MainActor in try await failingStore.refresh() })
    guard await awaitGate(failingGate) else { bad("gate never fired"); return }
    do {
        _ = try await failingStore.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
        bad("the start succeeded, so its failure path went untested"); return
    } catch {}
    // FreeAgent keeps the timeslip the start created before its timer failed.
    failing.setRule("timeslips?", body: #"{"timeslips":[\#(created)]}"#)
    failingGate.release()
    guard await failingRefresh.ended() else { bad("the refresh never returned, so the failed start still counts as in flight"); return }
    if case .failure(let error) = failingRefresh.result! { bad("the refresh threw: \(error)"); return }
    let ids = failingStore.timeslips.map(\.id)
    if ids == ["\(U)/timeslips/44"] { ok("and one in flight across a failed start commits what the start left") }
    else if failingStore.lastRefreshedAt == setUpAt { bad("a refresh in flight across a failed start returned without committing") }
    else { bad("a refresh in flight across a failed start committed what it heard before it: \(ids)") }
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
    refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {}, sendFeedback: {}, addTask: { _, _ in },
    addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in },
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
        if case DataStoreError.unconfirmed(.timeslip) = error { ok("the error says the entry may exist, not that it failed") }
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

    if case .failure(DataStoreError.unconfirmed(.timeslip)) = firstResult { ok("the first is reported unconfirmed") }
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

@MainActor func s25() async throws {
    hdr(25, "A timer-start response saying the timer isn't running must fail the start")
    let stub = Stub()
    baseRules(stub, running: nil, recent: "[]")
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()
    stub.setRule("timeslips?", body: #"{"timeslips":[\#(slip(id: 56, task: 1, hours: "0.0", datedOn: today(), timerStart: nil))]}"#)
    // A `timer` object that is present but stopped, where scenario 5's is null.
    stub.setRule("/timer", body: #"{"timeslip":\#(slip(id: 56, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z", timerRunning: false))}"#)
    do {
        let started = try await store.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
        bad("a timer FreeAgent reports as stopped was shown as running since \(started.timerStartedAt.map { "\($0)" } ?? "nothing")")
    } catch DataStoreError.underlying(let message) where stub.log.contains(where: { $0.url.hasSuffix("/timer") }) {
        ok("the start failed on FreeAgent's answer: \(message)")
    } catch {
        bad("the start failed for another reason: \(error)")
    }
    if store.currentRunningTimeslip == nil { ok("and nothing is cached as running") }
    else { bad("\(store.currentRunningTimeslip!.id) is cached as running") }
}

@MainActor func s26() async throws {
    hdr(26, "Switch task must keep the timer's start when FreeAgent's reply carries no timer")
    let stub = Stub()
    let start = "2026-08-19T09:00:00Z"
    let startedAt = ISO8601DateFormatter().date(from: start)!
    let running = slip(id: 700, task: 1, hours: "1.0", datedOn: today(), timerStart: start)
    baseRules(stub, running: running, recent: "[\(running)]")
    // The timer never stopped, but the PUT's reply carries none.
    stub.setRule("timeslips/700", body: #"{"timeslip":\#(slip(id: 700, task: 2, hours: "1.0", datedOn: today(), timerStart: nil))}"#)
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()
    let adoptedAtRefresh = store.currentRunningTimeslip?.timerStartedAt
    guard adoptedAtRefresh == startedAt else {
        bad("the refresh adopted \(adoptedAtRefresh.map { "\($0)" } ?? "no start"), not \(startedAt)"); return
    }
    guard let fresh = try await store.runningTimeslip() else { bad("no running timeslip"); return }
    _ = try await store.updateTimeslip(id: fresh.id, taskId: "\(U)/tasks/2", projectId: "\(U)/projects/1",
                                       clientId: "\(U)/contacts/1", date: fresh.day, hours: fresh.hours, comment: fresh.comment)
    let switched = store.currentRunningTimeslip
    print("   started \(startedAt); after the switch the store holds \(switched?.timerStartedAt.map { "\($0)" } ?? "no start")")
    if switched?.taskId == "\(U)/tasks/2" { ok("the running entry is on the new task") }
    else { bad("the running entry is still on \(switched?.taskId ?? "nothing")") }
    if switched?.timerStartedAt == startedAt { ok("and keeps its timer start") }
    else { bad("the switch replaced the timer start \(startedAt) with \(switched?.timerStartedAt.map { "\($0)" } ?? "nothing")") }

    // `reconcile(with:)` counts from this start whenever it adopts the timer without one of its own.
    let now = startedAt.addingTimeInterval(3 * 60 * 60)
    let app = AppState(clock: { now }); app.logIn()
    app.reconcile(with: store)
    let adopted = app.trackingStartedAtForTesting
    if app.trackingTask?.taskId == "\(U)/tasks/2", adopted == startedAt { ok("so a fresh adoption counts from it too") }
    else { bad("a fresh adoption tracks \(app.trackingTask?.taskName ?? "nothing") from \(adopted.map { "\($0)" } ?? "nothing"), not Task2 from \(startedAt)") }
}

@MainActor func s27() async throws {
    hdr(27, "A refresh asked for while a start is in flight must wait for it, then commit")
    // The start is held on its `POST /timer`, before which FreeAgent would say nothing is running.
    // A refresh fetching then is bound to be discarded, so it must not fetch until the start ends.
    var tokenStores: [KeychainTokenStore] = []
    defer { tokenStores.forEach { $0.clear() } }
    @MainActor func race(timerStatus: Int) async throws
        -> (store: FreeAgentDataStore, setUpAt: Date?, start: Result<RatchetTimeslip, Error>)? {
        let stub = Stub()
        baseRules(stub, running: nil, recent: "[]")
        let created = slip(id: 43, task: 1, hours: "0.0", datedOn: today(), timerStart: nil)
        let started = slip(id: 43, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z")
        stub.setRule("v2/timeslips", body: #"{"timeslip":\#(created)}"#)
        stub.setRule("/timer", body: #"{"timeslip":\#(started)}"#, status: timerStatus)
        let startGate = GatedStub(inner: stub, gateMatch: "/timer")
        let (store, ts) = makeStore(startGate); tokenStores.append(ts)
        try await store.refresh()
        let setUpAt = store.lastRefreshedAt
        func refreshFetches() -> Int { stub.log.filter { $0.url.contains("users/me") }.count }
        let fetchesAtSetUp = refreshFetches()

        startGate.armed = true
        let start = Task { @MainActor in
            try await store.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
        }
        guard await awaitGate(startGate) else { bad("start gate never fired"); return nil }
        let refresh = Outcome(Task { @MainActor in try await store.refresh() })
        await settle()
        if refreshFetches() == fetchesAtSetUp { ok("the refresh fetches nothing while the start is in flight") }
        else { bad("the refresh fetched while the start was in flight, so its answer was bound to be discarded") }
        let ran = timerStatus == 200 ? started : created
        stub.setRule("view=running", body: #"{"timeslips":[\#(timerStatus == 200 ? started : "")]}"#)
        stub.setRule("timeslips?", body: #"{"timeslips":[\#(ran)]}"#)
        startGate.release()
        let startResult = await start.result
        // A start that throws may still have changed FreeAgent.
        if case .failure = startResult, !store.hasLocalWritesSinceRefresh {
            bad("the failed start left the cache looking fresh, so a menu open would skip refreshing")
        }
        // A start still counted as in flight would hold the refresh back for good.
        guard await refresh.ended() else { bad("the refresh never ran, so the start still counts as in flight"); return nil }
        if case .failure(let error) = refresh.result! { bad("the refresh threw: \(error)"); return nil }
        return (store, setUpAt, startResult)
    }

    guard let succeeded = try await race(timerStatus: 200) else { return }
    switch succeeded.start {
    case .failure(let error):
        bad("the start failed, so the race went untested: \(error)")
    case .success(let started):
        let running = succeeded.store.currentRunningTimeslip
        if running?.id == started.id, succeeded.store.lastRefreshedAt != succeeded.setUpAt {
            ok("then commits, with the timer the start began running")
        } else {
            bad("the refresh left running=\(running?.id ?? "nil"), refreshed=\(succeeded.store.lastRefreshedAt != succeeded.setUpAt)")
        }
    }

    guard let failed = try await race(timerStatus: 500) else { return }
    guard case .failure = failed.start else { bad("the start succeeded, so its failure path went untested"); return }
    if failed.store.lastRefreshedAt != failed.setUpAt, !failed.store.hasLocalWritesSinceRefresh {
        ok("and one asked for during a failed start commits once it has ended")
    } else {
        bad("the refresh asked for during a failed start never committed")
    }
}

@MainActor func s28() async throws {
    hdr(28, "A refresh already in flight when a stop begins must neither commit nor return mid-stop")
    let stub = Stub()
    let running = slip(id: 9, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z")
    let stopped = slip(id: 9, task: 1, hours: "0.75", datedOn: today(), timerStart: nil)
    baseRules(stub, running: running, recent: "[\(running)]")
    stub.setRule("timeslips/9", body: #"{"timeslip":\#(stopped)}"#)
    // `stopTimer` clears the running timer once its DELETE lands, then suspends on this read-back.
    let readBackGate = GatedStub(inner: stub, gateMatch: "timeslips/9", gateMethod: "GET")
    // `contacts` is fetched only by a refresh.
    let refreshGate = GatedStub(inner: readBackGate, gateMatch: "contacts?")
    let (store, ts) = makeStore(refreshGate); defer { ts.clear() }
    try await store.refresh()
    let setUpAt = store.lastRefreshedAt
    func runningChecks() -> Int { stub.log.filter { $0.url.contains("view=running") }.count }
    let checksAtSetUp = runningChecks()

    // FreeAgent tells the refresh the timer is running, before the stop begins, and the refresh
    // reaches its commit while the stop waits on its read-back.
    refreshGate.armed = true
    let refresh = Outcome(Task { @MainActor in try await store.refresh() })
    guard await awaitGate(refreshGate) else { bad("refresh gate never fired"); return }
    guard await eventually({ runningChecks() == checksAtSetUp + 1 }) else {
        bad("the refresh's running check never landed before the stop"); return
    }
    readBackGate.armed = true
    let stop = Task { @MainActor in try await store.stopTimer() }
    guard await awaitGate(readBackGate) else { bad("read-back gate never fired"); return }
    stub.setRule("view=running", body: #"{"timeslips":[]}"#)
    stub.setRule("timeslips?", body: #"{"timeslips":[\#(stopped)]}"#)
    refreshGate.release()
    await settle()
    if store.lastRefreshedAt == setUpAt, store.currentRunningTimeslip == nil { ok("the refresh that landed mid-stop was discarded") }
    else { bad("the refresh that landed mid-stop was taken as current: running=\(store.currentRunningTimeslip?.id ?? "nil")") }
    // Its caller reconciles the menu as it returns, and mid-stop that would show the stop done.
    if refresh.result == nil { ok("and has not returned") }
    else { bad("the refresh returned mid-stop, so its caller reconciles against a stop half done") }
    readBackGate.release()
    if case .failure(let error) = await stop.result { bad("the stop failed, so the race went untested: \(error)"); return }
    guard await refresh.ended() else { bad("the refresh never returned after the stop"); return }
    if case .failure(let error) = refresh.result! { bad("the refresh threw: \(error)"); return }
    if store.lastRefreshedAt != setUpAt, store.currentRunningTimeslip == nil, store.timeslips.map(\.hours) == [0.75] {
        ok("it fetched again once the stop had ended, and committed the timer stopped")
    } else {
        bad("after the stop: refreshed=\(store.lastRefreshedAt != setUpAt), running=\(store.currentRunningTimeslip?.id ?? "nil"), hours=\(store.timeslips.map(\.hours))")
    }
}

@MainActor func s29() async throws {
    hdr(29, "A refresh asked for during a stop must wait for it, then commit")
    let stub = Stub()
    let running = slip(id: 9, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z")
    let stopped = slip(id: 9, task: 1, hours: "0.75", datedOn: today(), timerStart: nil)
    baseRules(stub, running: running, recent: "[\(running)]")
    stub.setRule("timeslips/9", body: #"{"timeslip":\#(stopped)}"#)
    let readBackGate = GatedStub(inner: stub, gateMatch: "timeslips/9", gateMethod: "GET")
    let (store, ts) = makeStore(readBackGate); defer { ts.clear() }
    try await store.refresh()
    let setUpAt = store.lastRefreshedAt
    func refreshFetches() -> Int { stub.log.filter { $0.url.contains("users/me") }.count }
    let fetchesAtSetUp = refreshFetches()

    // The stop's DELETE has landed and its read-back is held for longer than a whole refresh
    // takes, so a refresh fetching now would begin and end inside the stop.
    readBackGate.armed = true
    let stop = Task { @MainActor in try await store.stopTimer() }
    guard await awaitGate(readBackGate) else { bad("read-back gate never fired"); return }
    stub.setRule("view=running", body: #"{"timeslips":[]}"#)
    stub.setRule("timeslips?", body: #"{"timeslips":[\#(stopped)]}"#)
    let refresh = Outcome(Task { @MainActor in try await store.refresh() })
    await settle()
    if refreshFetches() == fetchesAtSetUp { ok("the refresh fetches nothing while the stop is in flight") }
    else { bad("the refresh fetched during the stop, though its answer was bound to be discarded") }
    readBackGate.release()
    if case .failure(let error) = await stop.result { bad("the stop failed, so the race went untested: \(error)"); return }
    guard await refresh.ended() else { bad("the refresh never returned after the stop"); return }
    if case .failure(let error) = refresh.result! { bad("the refresh threw: \(error)"); return }
    if store.lastRefreshedAt != setUpAt, store.currentRunningTimeslip == nil, store.timeslips.map(\.hours) == [0.75] {
        ok("then commits once the stop has ended")
    } else {
        bad("the refresh asked for during the stop was dropped: refreshed=\(store.lastRefreshedAt != setUpAt)")
    }
}


/// FreeAgent's contacts, projects and tasks in miniature, as `TimeslipServer` is its timeslips:
/// a create is applied before faults are injected, and lists are answered from what is held,
/// filtered as FreeAgent documents. It starts out holding the client, project and tasks
/// `baseRules` describes. Everything else falls through to `inner`.
@MainActor
final class ResourceServer: FreeAgentTransport {
    enum Kind: String, CaseIterable {
        case contacts, projects, tasks
        var envelopeKey: String { String(rawValue.dropLast()) }
        /// The documented list filter a lookup narrows by, which a refresh never sends.
        var lookupFilter: String {
            switch self {
            case .contacts: return "updated_since"
            case .projects: return "contact"
            case .tasks: return "project"
            }
        }
    }
    /// `refused` is a 422 and `unavailable` a 503, neither of them applied.
    enum CreateFault { case none, loseResponse, neverArrives, refused, unavailable }
    let inner: Stub
    var createFault = CreateFault.none
    /// When set, the status every projects list that names a `view` is answered with.
    var projectViewStatus: Int?
    /// After the next create is applied, drops its response and every request after it.
    var offlineAfterCreate = false
    var offline = false
    /// Contacts hidden in the web app: the contacts list's default `active` view leaves them out,
    /// but they can still be given projects.
    var hiddenContacts: Set<String> = []
    private(set) var held: [Kind: [[String: Any]]] = [:]
    /// Every create sent, whether or not it arrived.
    private(set) var posts: [Kind: Int] = [:]
    private(set) var lookups: [Kind: Int] = [:]

    init(inner: Stub) {
        self.inner = inner
        let longAgo = Date(timeIntervalSince1970: 1_767_225_600)
        add(.contacts, ["organisation_name": "Acme"], createdAt: longAgo, url: "\(U)/contacts/1")
        add(.projects, projectRecord("Site"), createdAt: longAgo, url: "\(U)/projects/1")
        for n in [1, 2] { add(.tasks, taskRecord("Task\(n)"), createdAt: longAgo, url: "\(U)/tasks/\(n)") }
    }

    func ids(_ kind: Kind) -> [String] { (held[kind] ?? []).compactMap { $0["url"] as? String } }

    /// Holds `record` as though FreeAgent had created it at `createdAt`, and returns its id.
    @discardableResult
    func add(_ kind: Kind, _ record: [String: Any], createdAt: Date, updatedAt: Date? = nil, url: String? = nil) -> String {
        var record = record
        let url = url ?? "\(U)/\(kind.rawValue)/\(100 + ids(kind).count)"
        record["url"] = url
        record["created_at"] = ISO8601DateFormatter().string(from: createdAt)
        record["updated_at"] = ISO8601DateFormatter().string(from: updatedAt ?? createdAt)
        held[kind, default: []].append(record)
        return url
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let answer = try await answer(request) { return answer }
        return try await inner.send(request)
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse)? {
        let url = request.url!
        let kind = Kind.allCases.first { url.path.hasSuffix("/v2/\($0.rawValue)") }
        if let kind, request.httpMethod == "POST" { posts[kind, default: 0] += 1 }
        if offline { throw URLError(.notConnectedToInternet) }
        guard let kind else { return nil }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        if request.httpMethod == "POST" {
            switch createFault {
            case .neverArrives: throw URLError(.notConnectedToInternet)
            case .refused: return try respond(request, ["errors": ["error": ["message": "Name is invalid"]]], status: 422)
            case .unavailable: return try respond(request, [String: Any](), status: 503)
            case .none, .loseResponse: break
            }
            let envelope = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: [String: Any]]
            var record = envelope?[kind.envelopeKey] ?? [:]
            // A task's project travels in the create's query, not its body.
            if kind == .tasks { record["project"] = query["project"] }
            add(kind, record, createdAt: Date())
            if offlineAfterCreate { offline = true; throw URLError(.networkConnectionLost) }
            if createFault == .loseResponse { throw URLError(.networkConnectionLost) }
            return try respond(request, [kind.envelopeKey: held[kind]!.last!], status: 201)
        }
        var listed = held[kind] ?? []
        if kind == .contacts { listed = listed.filter { !hiddenContacts.contains($0["url"] as? String ?? "") } }
        if let value = query[kind.lookupFilter] {
            lookups[kind, default: 0] += 1
            listed = listed.filter { record in
                guard kind == .contacts else { return record[kind.lookupFilter] as? String == value }
                let formatter = ISO8601DateFormatter()
                guard let updated = formatter.date(from: record["updated_at"] as? String ?? ""),
                      let since = formatter.date(from: value) else { return true }
                return updated >= since
            }
        }
        // FreeAgent doesn't document the projects list's default view, so this takes the
        // narrowest reading: active projects only, unless `view` names another status.
        if kind == .projects {
            if let status = projectViewStatus, query["view"] != nil { return try respond(request, [String: Any](), status: status) }
            let view = query["view"] ?? "active"
            listed = listed.filter { ($0["status"] as? String)?.lowercased() == view }
        }
        return try respond(request, [kind.rawValue: listed], status: 200)
    }

    private func respond(_ request: URLRequest, _ object: Any, status: Int) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: object),
         HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

func projectRecord(_ name: String) -> [String: Any] {
    ["contact": "\(U)/contacts/1", "name": name, "status": "Active", "currency": "GBP", "budget": "0",
     "budget_units": "Hours", "hours_per_day": "8", "normal_billing_rate": "0", "billing_period": "hour",
     "uses_project_invoice_sequence": false]
}

func taskRecord(_ name: String) -> [String: Any] {
    ["project": "\(U)/projects/1", "name": name, "is_billable": true, "status": "Active"]
}

@MainActor
func makeClient(_ store: FreeAgentDataStore, _ name: String) async throws -> String {
    try await store.addClient(organisationName: name, firstName: nil, lastName: nil, email: nil, phoneNumber: nil,
                              address1: nil, town: nil, postcode: nil, country: nil).id
}

@MainActor
func makeProject(
    _ store: FreeAgentDataStore, _ name: String, for client: String = "\(U)/contacts/1", status: ProjectStatus = .active
) async throws -> String {
    try await store.addProject(name: name, clientId: client, status: status, currency: "GBP", budget: 0,
                               budgetUnits: .hours, hoursPerDay: 8, normalBillingRate: 0, billingPeriod: .hour,
                               usesProjectInvoiceSequence: false, contractPoReference: nil, startsOn: nil, endsOn: nil).id
}

@MainActor
func makeTask(_ store: FreeAgentDataStore, _ name: String, in project: String = "\(U)/projects/1") async throws -> String {
    try await store.addTask(name: name, projectId: project, clientId: "\(U)/contacts/1", isBillable: true,
                            status: .active, billingRate: nil, billingPeriod: nil).id
}

/// A client, project or task as the scenarios below make it: by name, as its form would, under
/// Acme's Site project where it needs a parent.
struct Creatable {
    let noun: String
    let kind: ResourceServer.Kind
    let resource: DataStoreError.Resource
    /// A record FreeAgent might hold under `name`, where `create` would put one.
    let record: (String) -> [String: Any]
    /// Makes one named `name` and returns its id.
    let create: @MainActor (FreeAgentDataStore, String) async throws -> String
    /// The ids of every one the store has cached.
    let cached: @MainActor (FreeAgentDataStore) -> [String]
    /// Adds a project to a client, or a task to a project, and returns its id.
    let addChild: (@MainActor (FreeAgentDataStore, _ parent: String) async throws -> String)?
}

let projectIds: @MainActor (FreeAgentDataStore) -> [String] = { $0.clients.flatMap(\.projects).map(\.id) }
let taskIds: @MainActor (FreeAgentDataStore) -> [String] = { $0.clients.flatMap(\.projects).flatMap(\.tasks).map(\.id) }

let creatables = [
    Creatable(noun: "client", kind: .contacts, resource: .client, record: { ["organisation_name": $0] },
              create: makeClient, cached: { $0.clients.map(\.id) },
              addChild: { store, client in try await makeProject(store, "Kappa", for: client) }),
    Creatable(noun: "project", kind: .projects, resource: .project, record: projectRecord,
              create: { try await makeProject($0, $1) }, cached: projectIds,
              addChild: { store, project in try await makeTask(store, "Kappa", in: project) }),
    Creatable(noun: "task", kind: .tasks, resource: .task, record: taskRecord,
              create: { try await makeTask($0, $1) }, cached: taskIds, addChild: nil),
]

@MainActor
func resourceStore() -> (ResourceServer, FreeAgentDataStore, KeychainTokenStore) {
    let stub = Stub()
    baseRules(stub)
    let server = ResourceServer(inner: stub)
    let (store, ts) = makeStore(server)
    return (server, store, ts)
}

@MainActor func s30() async throws {
    hdr(30, "A client, project or task whose create response is lost must be adopted, not made twice")
    for made in creatables {
        let (server, store, ts) = resourceStore(); defer { ts.clear() }
        try await store.refresh()
        let before = server.ids(made.kind).count

        server.createFault = .loseResponse
        do {
            let id = try await made.create(store, "Gamma")
            if server.ids(made.kind).count == before + 1, server.ids(made.kind).last == id,
               made.cached(store).filter({ $0 == id }).count == 1 {
                ok("a lost \(made.noun) is found and adopted at once")
            } else {
                bad("adopted \(id) with \(server.ids(made.kind)) server-side and \(made.cached(store)) cached")
            }
        } catch {
            bad("the lost \(made.noun) surfaced as \(error), so retrying it would make a second")
        }

        // Applied, then the network stays down, so nothing can be checked until it is back.
        server.createFault = .none
        server.offlineAfterCreate = true
        do { _ = try await made.create(store, "Delta"); bad("an unchecked \(made.noun) was reported as made") }
        catch let error as DataStoreError where error == .unconfirmed(made.resource) { ok("an uncheckable \(made.noun) is reported unconfirmed") }
        catch { bad("an uncheckable \(made.noun) is reported as \(error), which reads as not made and invites a blind retry") }
        server.offlineAfterCreate = false
        let posts = server.posts[made.kind]
        _ = try? await made.create(store, "Delta")
        if server.posts[made.kind] == posts { ok("a retry while still offline posts nothing") }
        else { bad("a retry while offline posted again") }

        // Back online, a refresh shows what the lost create made, and something is added to it
        // before the retry, whose name is retyped with a stray space.
        server.offline = false
        try await store.refresh()
        let child = try await made.addChild?(store, server.ids(made.kind).last!)
        do {
            let id = try await made.create(store, "Delta ")
            print("   \(made.noun) retried online: server holds \(server.ids(made.kind)); returned \(id)")
            if server.posts[made.kind] == posts, server.ids(made.kind).count == before + 2, server.ids(made.kind).last == id {
                ok("the retry adopts what the lost create made rather than posting it again")
            } else {
                bad("the retry left \(server.ids(made.kind).count - before) new server-side")
            }
            if made.cached(store).filter({ $0 == id }).count == 1 { ok("and the local cache holds it once") }
            else { bad("the local cache holds \(made.cached(store))") }
            if let child {
                if (projectIds(store) + taskIds(store)).contains(child) { ok("with what was added to it") }
                else { bad("adopting it dropped \(child) from the local cache") }
            }
        } catch {
            bad("the retry failed: \(error)")
        }
    }

    // Lost before the first refresh has named the account, as when the launch refresh failed.
    let (server, store, ts) = resourceStore(); defer { ts.clear() }
    server.offlineAfterCreate = true
    _ = try? await makeClient(store, "Omega")
    server.offlineAfterCreate = false
    server.offline = false
    try await store.refresh()
    let posts = server.posts[.contacts]
    do {
        let id = try await makeClient(store, "Omega")
        if server.posts[.contacts] == posts, server.ids(.contacts).last == id { ok("so is a client lost before the first refresh, by a retry after it") }
        else { bad("a client lost before the first refresh was posted again by its retry: \(server.ids(.contacts))") }
    } catch {
        bad("a retry after the first refresh failed: \(error)")
    }

    // Made Hidden, which the projects list may leave out by default, then retried as Active.
    server.offlineAfterCreate = true
    _ = try? await makeProject(store, "Archive", status: .hidden)
    server.offlineAfterCreate = false
    server.offline = false
    let projectPosts = server.posts[.projects]
    do {
        let id = try await makeProject(store, "Archive")
        if server.posts[.projects] == projectPosts, server.ids(.projects).last == id { ok("so is a project made Hidden, by a retry made Active") }
        else { bad("a project made Hidden was posted again by a retry made Active: \(server.ids(.projects))") }
    } catch {
        bad("a retry made Active failed: \(error)")
    }

    // An organisation, retried without the contact person it was first sent with.
    server.offlineAfterCreate = true
    _ = try? await store.addClient(organisationName: "Theta", firstName: "Jane", lastName: "Doe", email: nil,
                                   phoneNumber: nil, address1: nil, town: nil, postcode: nil, country: nil)
    server.offlineAfterCreate = false
    server.offline = false
    let clientPosts = server.posts[.contacts]
    do {
        let id = try await makeClient(store, "Theta")
        if server.posts[.contacts] == clientPosts, server.ids(.contacts).last == id { ok("and an organisation, by a retry without its contact person") }
        else { bad("an organisation was posted again by a retry without its contact person: \(server.ids(.contacts))") }
    } catch {
        bad("a retry without the contact person failed: \(error)")
    }

    // A status view FreeAgent refuses says nothing about the project; one it rate-limits might
    // have listed it.
    server.createFault = .loseResponse
    server.projectViewStatus = 422
    do {
        let id = try await makeProject(store, "Lambda")
        if server.ids(.projects).last == id { ok("a status view FreeAgent refuses doesn't stop the look") }
        else { bad("with the status views refused, adopted \(id), not \(server.ids(.projects).last ?? "nothing")") }
    } catch {
        bad("with the status views refused, the lost project surfaced as \(error)")
    }
    server.projectViewStatus = 429
    do { _ = try await makeProject(store, "Mu"); bad("a lost project was reported as made with its status views unanswered") }
    catch let error as DataStoreError where error == .unconfirmed(.project) { ok("but one left unanswered leaves the create unconfirmed") }
    catch { bad("with a status view unanswered, the lost project surfaced as \(error)") }
    server.createFault = .none
    server.projectViewStatus = nil
}

@MainActor func s31() async throws {
    hdr(31, "A client, project or task create must not adopt a same-name one that existed before it was sent")
    for made in creatables {
        let (server, store, ts) = resourceStore(); defer { ts.clear() }
        // Made a minute before the send, so its `created_at` alone can't rule it out, but cached.
        let recent = server.add(made.kind, made.record("Beta"), createdAt: Date().addingTimeInterval(-60))
        try await store.refresh()
        // Made an hour ago and edited just now, so it isn't cached, and a contacts lookup's
        // `updated_since` still lists it.
        let old = server.add(made.kind, made.record("Beta"), createdAt: Date().addingTimeInterval(-3600), updatedAt: Date())

        server.createFault = .neverArrives
        do {
            let id = try await made.create(store, "Beta")
            bad("adopted \(id == recent ? "the cached" : id == old ? "the hour-old" : "an unknown") \(made.noun) for one never made")
        } catch let error as DataStoreError where error == .unconfirmed(made.resource) {
            ok("neither earlier \(made.noun) is taken for the one that never arrived")
        } catch {
            bad("a \(made.noun) that never arrived is reported as \(error), which reads as not made")
        }

        server.createFault = .none
        do {
            let id = try await made.create(store, "Beta")
            if ![recent, old].contains(id), server.ids(made.kind).last == id { ok("its retry makes a \(made.noun) of its own") }
            else { bad("its retry returned \(id) with \(server.ids(made.kind)) server-side") }
        } catch {
            bad("its retry failed: \(error)")
        }
    }
}

@MainActor func s32() async throws {
    hdr(32, "A refused client, project or task create must be reported as refused, not unconfirmed")
    for made in creatables {
        let (server, store, ts) = resourceStore(); defer { ts.clear() }
        try await store.refresh()
        let before = server.ids(made.kind).count

        server.createFault = .refused
        do {
            _ = try await made.create(store, "Epsilon")
            bad("a refused \(made.noun) was reported as made")
        } catch FreeAgentError.apiError(status: 422, _) {
            ok("a 422 is reported as FreeAgent's refusal")
        } catch {
            bad("a 422 is reported as \(error), not as FreeAgent's refusal")
        }
        if server.lookups[made.kind] == nil { ok("and nothing is looked for") }
        else { bad("looked for a \(made.noun) FreeAgent said it didn't make") }

        // A gateway answering 503 can't say whether FreeAgent went on to make it.
        server.createFault = .unavailable
        do { _ = try await made.create(store, "Epsilon"); bad("a 503 was reported as made") }
        catch let error as DataStoreError where error == .unconfirmed(made.resource) { ok("a 503 is reported unconfirmed") }
        catch { bad("a 503 is reported as \(error), which reads as not made") }

        server.createFault = .none
        do {
            let id = try await made.create(store, "Epsilon")
            if server.ids(made.kind).count == before + 1, server.ids(made.kind).last == id { ok("its retry makes the \(made.noun) once") }
            else { bad("its retry left \(server.ids(made.kind).count - before) new server-side") }
        } catch {
            bad("its retry failed: \(error)")
        }
    }
}

@MainActor func s33() async throws {
    hdr(33, "A project or task FreeAgent made must not be reported as failed when its parent has left the cache")
    let (server, store, ts) = resourceStore(); defer { ts.clear() }
    // Acme hidden in the web app: the next refresh drops it, and Site with it, from the cache.
    server.hiddenContacts = ["\(U)/contacts/1"]
    try await store.refresh()
    for made in creatables where made.kind != .contacts {
        do {
            let id = try await made.create(store, "Lambda")
            if server.ids(made.kind).last == id { ok("the \(made.noun) FreeAgent made is returned") }
            else { bad("returned \(id), not the \(made.noun) FreeAgent made") }
        } catch {
            bad("the \(made.noun) FreeAgent made is reported as \(error), which invites making a second")
        }
    }
}

/// Adding a client needs no account, so of the writes the menu offers it is the one that can land
/// before the launch refresh does.
@MainActor
func addGlobex(_ stub: Stub, _ store: FreeAgentDataStore) async throws {
    stub.setRule("v2/contacts", body: #"{"contact":{"url":"\#(U)/contacts/2","organisation_name":"Globex","first_name":null,"last_name":null,"email":null,"phone_number":null,"address1":null,"town":null,"postcode":null,"country":null}}"#)
    _ = try await store.addClient(organisationName: "Globex", firstName: nil, lastName: nil, email: nil,
                                  phoneNumber: nil, address1: nil, town: nil, postcode: nil, country: nil)
}

@MainActor func s34() async throws {
    hdr(34, "A start made before the launch refresh lands must succeed though a write overtakes that refresh")
    let stub = Stub()
    baseRules(stub, running: nil, recent: "[]")
    stub.setRule("v2/timeslips", body: #"{"timeslip":\#(slip(id: 104, task: 1, hours: "0.0", datedOn: today(), timerStart: nil))}"#)
    stub.setRule("/timer", body: #"{"timeslip":\#(slip(id: 104, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T14:00:00Z"))}"#)
    // `contacts?` is a refresh's fetch, not the create's POST.
    let gate = GatedStub(inner: stub, gateMatch: "contacts?")
    let (store, ts) = makeStore(gate); defer { ts.clear() }
    gate.armed = true
    let launchRefresh = Task { @MainActor in try? await store.refresh() }
    guard await awaitGate(gate) else { bad("gate never fired"); return }
    // The start joins the launch refresh for the account it needs.
    let start = Task { @MainActor in
        try await store.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    }
    for _ in 0..<5 { await Task.yield() }
    try await addGlobex(stub, store)
    gate.release()
    _ = await launchRefresh.value
    do {
        _ = try await start.value
        ok("the start fetches the account again and succeeds")
    } catch {
        bad("the start failed, though only its refresh had been overtaken: \(error)")
    }
}

@MainActor func s35() async throws {
    hdr(35, "Logging in must replace the last session's account though that session's stop is still in flight")
    let stub = Stub()
    let running = slip(id: 9, task: 1, hours: "0.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z")
    baseRules(stub, running: running, recent: "[\(running)]")
    stub.setRule("timeslips/9", body: #"{"timeslip":\#(slip(id: 9, task: 1, hours: "0.75", datedOn: today(), timerStart: nil))}"#)
    let readBackGate = GatedStub(inner: stub, gateMatch: "timeslips/9", gateMethod: "GET")
    let (store, ts) = makeStore(readBackGate); defer { ts.clear() }
    try await store.refresh()
    let app = AppState(); app.logIn(); app.reconcile(with: store)

    // The stop is slow to finish, and logging out doesn't wait for it.
    readBackGate.armed = true
    let stop = Task { @MainActor in try await store.stopTimer() }
    guard await awaitGate(readBackGate) else { bad("read-back gate never fired"); return }
    app.logOut()
    // Someone else signs in, so FreeAgent answers for their account.
    stub.setRule("users/me", body: #"{"user":{"url":"\#(U)/users/2","email":"bo@example.com"}}"#)
    stub.setRule("view=running", body: #"{"timeslips":[]}"#)
    stub.setRule("timeslips?", body: #"{"timeslips":[]}"#)
    // Exactly the login path: refresh, then log in and reconcile.
    let login = Outcome(Task { @MainActor in try await store.refreshForNewSession() })
    await settle()
    readBackGate.release()
    _ = await stop.result
    guard await login.ended() else { bad("the login refresh never returned"); return }
    if case .failure(let error) = login.result! { bad("the login refresh threw: \(error)"); return }
    app.logIn(); app.reconcile(with: store)
    if store.accountEmail == "bo@example.com", store.timeslips.isEmpty { ok("the menu shows the new account's state") }
    else { bad("login kept the last session's state: account \(store.accountEmail), entries \(store.timeslips.map(\.id))") }
}

@MainActor func s36() async throws {
    hdr(36, "A manual refresh that joins one a write has overtaken must still bring FreeAgent's state")
    let stub = Stub()
    baseRules(stub, running: nil, recent: "[]")
    let gate = GatedStub(inner: stub, gateMatch: "contacts?")
    let (store, ts) = makeStore(gate); defer { ts.clear() }
    try await store.refresh()

    gate.armed = true
    let silent = Task { @MainActor in try? await store.refresh() }
    guard await awaitGate(gate) else { bad("gate never fired"); return }
    try await addGlobex(stub, store)
    // Meanwhile an entry is logged in the FreeAgent web app, which only a fetch can show.
    stub.setRule("timeslips?", body: #"{"timeslips":[\#(slip(id: 60, task: 2, hours: "1.0", datedOn: today(), timerStart: nil))]}"#)
    let manual = Task { @MainActor in try await store.refresh() }
    for _ in 0..<5 { await Task.yield() }
    gate.release()
    _ = await silent.value
    if case .failure(let error) = await manual.result { bad("the manual refresh threw: \(error)"); return }
    if store.timeslips.map(\.id) == ["\(U)/timeslips/60"] { ok("it shows the entry logged elsewhere") }
    else { bad("the manual refresh returned without fetching: entries \(store.timeslips.map(\.id))") }
}

@MainActor func s37() async throws {
    hdr(37, "Logging in must not take a refresh the last session left in flight as its own")
    let stub = Stub()
    baseRules(stub)
    let server = TimeslipServer(inner: stub)
    // `contacts?` is answered after `users/me`, so the held refresh already knows its account.
    let gate = GatedStub(inner: server, gateMatch: "contacts?")
    let (store, ts) = makeStore(gate); defer { ts.clear() }
    try await store.refresh()
    _ = try await logTask1(store)

    gate.armed = true
    let silent = Task { @MainActor in try? await store.refresh() }
    guard await awaitGate(gate) else { bad("gate never fired"); return }
    // Log out, and someone else signs in.
    ts.clear()
    _ = ts.save(FreeAgentTokens(accessToken: "b", refreshToken: "rb", expiresAt: Date(timeIntervalSinceNow: 3600)))
    stub.setRule("users/me", body: #"{"user":{"url":"\#(U)/users/2","email":"bo@example.com"}}"#)
    let login = Outcome(Task { @MainActor in try await store.refreshForNewSession() })
    await settle()
    gate.release()
    _ = await silent.value
    guard await login.ended() else { bad("the login refresh never returned"); return }
    if case .failure(let error) = login.result! { bad("the login refresh threw: \(error)"); return }
    if store.accountEmail == "bo@example.com", store.timeslips.isEmpty { ok("the menu shows the new account's state") }
    else { bad("login took the last session's refresh: account \(store.accountEmail), entries \(store.timeslips.map(\.id))") }
    _ = try await logTask1(store)
    let filedTo = server.slips.last?["user"] as? String ?? "nothing"
    if filedTo == "\(U)/users/2" { ok("and its first entry is filed against it") }
    else { bad("the new account's entry was filed against \(filedTo)") }
}

/// Ends Al's session as `StatusItemController.performLogOut` does, and signs Bo in.
@MainActor
func signInAsBo(_ store: FreeAgentDataStore, _ ts: KeychainTokenStore, _ stub: Stub) {
    store.endSession()
    ts.clear()
    _ = ts.save(FreeAgentTokens(accessToken: "b", refreshToken: "rb", expiresAt: Date(timeIntervalSinceNow: 3600)))
    stub.setRule("users/me", body: #"{"user":{"url":"\#(U)/users/2","email":"bo@example.com"}}"#)
}

/// Whether a request names Al as its user, in its query or in a body JSONEncoder wrote.
func namesAl(_ entry: (method: String, url: String, body: String, bearer: String)) -> Bool {
    entry.url.contains("users/1") || entry.body.contains(#"users\/1"#)
}

@MainActor func s38() async throws {
    hdr(38, "A token refresh the last session left in flight must not outlive it")
    let stub = Stub()
    baseRules(stub)
    stub.setRule("/token", body: #"{"access_token":"a2","refresh_token":"r2","expires_in":3600}"#)
    let gate = GatedStub(inner: stub, gateMatch: "/token")
    let (store, ts) = makeStore(gate); defer { ts.clear() }
    try await store.refresh()
    // Al's access token has expired, so the next request exchanges the refresh token first.
    _ = ts.save(FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: -10)))

    gate.armed = true
    let silent = Outcome(Task { @MainActor in try await store.refresh() })
    guard await awaitGate(gate) else { bad("gate never fired"); return }
    signInAsBo(store, ts, stub)
    stub.log = []
    let login = Outcome(Task { @MainActor in try await store.refreshForNewSession() })
    await settle()
    gate.release()
    guard await login.ended() else { bad("the login refresh never returned"); return }
    if case .failure(let error) = login.result! { bad("the login refresh threw: \(error)"); return }
    let stored = ts.load()?.refreshToken ?? "nothing"
    if stored == "rb" { ok("Bo's sign-in is still the one stored") }
    else { bad("the last session's token refresh stored \(stored) over Bo's sign-in") }
    let bearers = Set(stub.log.filter { $0.url.contains("/v2/") }.map(\.bearer))
    if bearers == ["Bearer b"] { ok("and Bo's login fetched with Bo's token") }
    else { bad("Bo's login fetched with \(bearers.sorted())") }
    guard await silent.ended() else { bad("the last session's refresh never returned"); return }
    if case .failure(let error) = silent.result!, error.indicatesSessionExpired {
        bad("the last session's refresh failed as an expired session, which signs out whoever is signed in")
    } else {
        ok("and the last session's refresh doesn't fail as an expired session")
    }

    // Nobody has signed in by the time Al's exchange returns.
    let alone = Stub()
    baseRules(alone)
    alone.setRule("/token", body: #"{"access_token":"a2","refresh_token":"r2","expires_in":3600}"#)
    let aloneGate = GatedStub(inner: alone, gateMatch: "/token")
    let (aloneStore, aloneTs) = makeStore(aloneGate); defer { aloneTs.clear() }
    try await aloneStore.refresh()
    _ = aloneTs.save(FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: -10)))
    aloneGate.armed = true
    let aloneRefresh = Outcome(Task { @MainActor in try await aloneStore.refresh() })
    guard await awaitGate(aloneGate) else { bad("gate never fired"); return }
    aloneStore.endSession()
    aloneTs.clear()
    aloneGate.release()
    guard await aloneRefresh.ended() else { bad("the last session's refresh never returned"); return }
    if aloneTs.load() == nil { ok("a logout with nobody signed in since stays logged out") }
    else { bad("the last session's token refresh stored its tokens again after the logout") }

    // Al's exchange is still out when Bo's own token needs refreshing.
    let both = Stub()
    baseRules(both)
    both.setRule("/token", body: #"{"access_token":"a2","refresh_token":"r2","expires_in":3600}"#)
    let bothGate = GatedStub(inner: both, gateMatch: "/token")
    let (bothStore, bothTs) = makeStore(bothGate); defer { bothTs.clear() }
    try await bothStore.refresh()
    _ = bothTs.save(FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: -10)))
    bothGate.armed = true
    // Switch task's read of the running timer, which a login doesn't wait for as it does a refresh.
    let read = Task { @MainActor in try? await bothStore.runningTimeslip() }
    guard await awaitGate(bothGate) else { bad("gate never fired"); return }
    signInAsBo(bothStore, bothTs, both)
    _ = bothTs.save(FreeAgentTokens(accessToken: "b", refreshToken: "rb", expiresAt: Date(timeIntervalSinceNow: -10)))
    both.setRule("/token", body: #"{"access_token":"b2","refresh_token":"rb2","expires_in":3600}"#)
    let bothLogin = Outcome(Task { @MainActor in try await bothStore.refreshForNewSession() })
    await settle()
    bothGate.release()
    _ = await read.value
    guard await bothLogin.ended() else { bad("the login refresh never returned"); return }
    if case .failure(let error) = bothLogin.result! { bad("Bo's login joined the last session's token refresh and failed with it: \(error)") }
    else if bothTs.load()?.refreshToken == "rb2", bothStore.accountEmail == "bo@example.com" { ok("and Bo's own token refresh doesn't join it") }
    else { bad("Bo's login stored \(bothTs.load()?.refreshToken ?? "nothing") for \(bothStore.accountEmail)") }
}

@MainActor func s39() async throws {
    hdr(39, "Open FreeAgent must not open the last session's company when the next one's can't be fetched")
    let stub = Stub()
    baseRules(stub)
    let (store, ts) = makeStore(stub); defer { ts.clear() }
    try await store.refresh()
    signInAsBo(store, ts, stub)
    stub.setRule("/company", body: "{}", status: 500)
    try await store.refreshForNewSession()
    if store.webAppURL == nil { ok("logging out forgets the last session's company") }
    else { bad("Bo's Open FreeAgent opens \(store.webAppURL!)") }

    // Al's refresh is in flight across the logout, with its company already fetched.
    let late = Stub()
    baseRules(late)
    let gate = GatedStub(inner: late, gateMatch: "contacts?")
    let (lateStore, lateTs) = makeStore(gate); defer { lateTs.clear() }
    gate.armed = true
    let silent = Task { @MainActor in try? await lateStore.refresh() }
    guard await awaitGate(gate) else { bad("gate never fired"); return }
    // Every other fetch is answered by now, so only the commit is left once the gate opens.
    await settle()
    signInAsBo(lateStore, lateTs, late)
    late.setRule("/company", body: "{}", status: 500)
    let login = Outcome(Task { @MainActor in try await lateStore.refreshForNewSession() })
    await settle()
    gate.release()
    _ = await silent.value
    guard await login.ended() else { bad("the login refresh never returned"); return }
    if case .failure(let error) = login.result! { bad("the login refresh threw: \(error)"); return }
    if lateStore.webAppURL == nil { ok("nor does a refresh the last session left in flight bring it back") }
    else { bad("the last session's refresh committed its company after the logout: \(lateStore.webAppURL!)") }
}

@MainActor func s40() async throws {
    hdr(40, "A start the last session left in flight or queued must send nothing more once it has ended")
    let stub = Stub()
    baseRules(stub)
    stub.setRule("v2/timeslips", body: #"{"timeslip":\#(slip(id: 70, task: 1, hours: "0.0", datedOn: today(), timerStart: nil))}"#)
    let gate = GatedStub(inner: stub, gateMatch: "view=running")
    let (store, ts) = makeStore(gate); defer { ts.clear() }
    try await store.refresh()

    gate.armed = true
    let inFlight = Outcome(Task { @MainActor in
        try await store.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    })
    guard await awaitGate(gate) else { bad("gate never fired"); return }
    let queued = Outcome(Task { @MainActor in
        try await store.startTimer(taskId: "\(U)/tasks/2", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    })
    for _ in 0..<5 { await Task.yield() }
    signInAsBo(store, ts, stub)
    stub.log = []
    let login = Outcome(Task { @MainActor in try await store.refreshForNewSession() })
    gate.release()
    guard await inFlight.ended(), await queued.ended() else { bad("a start never returned"); return }
    guard await login.ended() else { bad("the login refresh never returned"); return }
    if case .failure(let error) = login.result! { bad("the login refresh threw: \(error)"); return }
    let forAl = stub.log.filter(namesAl)
    if forAl.isEmpty { ok("nothing more is sent for Al") }
    else { bad("sent for Al with Bo's sign-in: \(forAl.map { "\($0.method) \($0.url) (\($0.bearer))" })") }
    let posts = stub.log.filter { $0.method == "POST" }.map(\.url)
    if posts.isEmpty, store.currentRunningTimeslip == nil { ok("and nothing is started in Bo's account") }
    else { bad("Al's starts went on in Bo's account: \(posts)") }
    if !store.hasLocalWritesSinceRefresh { ok("nor counted as a write in Bo's session") }
    else { bad("Al's queued start counted as a write in Bo's session") }
    for (name, start) in [("in flight", inFlight), ("queued", queued)] {
        if case .failure(let error) = start.result!, error.indicatesSessionExpired {
            bad("the \(name) start failed as an expired session, which signs out whoever is signed in")
        }
    }
}

@MainActor func s41() async throws {
    hdr(41, "An entry the last session left in flight must send nothing more once it has ended")
    for boSignsIn in [true, false] {
        let stub = Stub()
        baseRules(stub)
        let server = TimeslipServer(inner: stub)
        // `task=` is a lookup for an earlier attempt; a refresh's fetch doesn't filter by task.
        let gate = GatedStub(inner: server, gateMatch: "task=", gateMethod: "GET")
        let (store, ts) = makeStore(gate); defer { ts.clear() }
        try await store.refresh()
        // Al's first attempt never arrives, so the retry looks for it before posting again.
        server.createFault = .neverArrives
        _ = try? await logTask1(store)
        server.createFault = .none
        let posts = server.posts

        gate.armed = true
        let retry = Outcome(Task { @MainActor in try await logTask1(store) })
        guard await awaitGate(gate) else { bad("gate never fired"); return }
        if boSignsIn { signInAsBo(store, ts, stub) } else { store.endSession(); ts.clear() }
        gate.release()
        guard await retry.ended() else { bad("the retry never returned"); return }
        let when = boSignsIn ? "once Bo has signed in" : "before anyone signs in"
        if server.posts == posts { ok("the retry posts nothing \(when)") }
        else { bad("the retry posted Al's entry \(when), filed against \(server.slips.last?["user"] ?? "nothing")") }
        if case .failure(let error) = retry.result!, error.indicatesSessionExpired {
            bad("the retry \(when) failed as an expired session, which signs out whoever is signed in")
        }
    }
}

@MainActor func s42() async throws {
    hdr(42, "An entry whose response is lost as its session ends must not be looked for, nor reported unconfirmed")
    let stub = Stub()
    baseRules(stub)
    let server = TimeslipServer(inner: stub)
    let gate = GatedStub(inner: server, gateMatch: "v2/timeslips", gateMethod: "POST")
    let (store, ts) = makeStore(gate); defer { ts.clear() }
    try await store.refresh()

    // FreeAgent logs the entry, and the response is lost after Al has logged out.
    server.createFault = .loseResponse
    gate.armed = true
    let entry = Outcome(Task { @MainActor in try await logTask1(store) })
    guard await awaitGate(gate) else { bad("gate never fired"); return }
    let lookups = server.lookups
    signInAsBo(store, ts, stub)
    gate.release()
    guard await entry.ended() else { bad("the entry never returned"); return }
    if server.lookups == lookups { ok("Al's entry isn't looked for with Bo's sign-in") }
    else { bad("Al's entry was looked for with Bo's sign-in") }
    switch entry.result! {
    case .failure(FreeAgentError.sessionEnded): ok("and it fails as ended, which no alert reports")
    case .failure(let error): bad("it fails as \(error), which an alert reports to whoever is signed in now")
    case .success(let slip): bad("it reports \(slip.id) as logged")
    }
}

@MainActor func s43() async throws {
    hdr(43, "A create the last session left unsettled must not be looked for in the next one's account")
    let (server, store, ts) = resourceStore(); defer { ts.clear() }
    try await store.refresh()
    // Al's Globex never arrives, and can't be confirmed.
    server.createFault = .neverArrives
    _ = try? await makeClient(store, "Globex")
    server.createFault = .none
    signInAsBo(store, ts, server.inner)
    try await store.refreshForNewSession()
    // Bo's account has a Globex of its own, made in the web app since.
    server.add(.contacts, ["organisation_name": "Globex"], createdAt: Date())
    let lookups = server.lookups[.contacts, default: 0], posts = server.posts[.contacts, default: 0]
    let made = try await makeClient(store, "Globex")
    if server.lookups[.contacts, default: 0] == lookups, server.posts[.contacts, default: 0] == posts + 1 {
        ok("Bo's create is posted, not settled against Al's attempt")
    } else {
        bad("Bo's create looked for Al's attempt and returned \(made) without posting")
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let only = ProcessInfo.processInfo.environment["ONLY"].flatMap(Int.init)
var current = (scenario: 0, since: Date())
func want(_ n: Int) -> Bool {
    guard only == nil || only == n else { return false }
    current = (n, Date())
    return true
}

func finish(_ status: Int32) -> Never {
    clearMadeTokenStores()
    exit(status)
}

// A run stopped from outside (Ctrl-C, `timeout`, an alarm) clears up the same way, then dies of the
// signal rather than exiting, so a shell loop running the harness still stops on Ctrl-C. Handled
// off the main queue, which a scenario that wedges the main thread would never let them reach.
let stopSignals = [SIGINT, SIGTERM, SIGHUP, SIGALRM].map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler {
        clearMadeTokenStores()
        signal(sig, SIG_DFL)
        raise(sig)
    }
    source.resume()
    return source
}

// A refresh waits for every write in flight, so a store that loses count of one leaves the next
// refresh waiting for good. A scenario that runs that long fails rather than hanging the run.
Task { @MainActor in
    while true {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard Date().timeIntervalSince(current.since) > 30 else { continue }
        bad("scenario \(current.scenario) never finished")
        print("\n\(bugCount) BUG LINE(S)")
        finish(1)
    }
}

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
        if want(25) { try await s25() }
        if want(26) { try await s26() }
        if want(27) { try await s27() }
        if want(28) { try await s28() }
        if want(29) { try await s29() }
        if want(30) { try await s30() }
        if want(31) { try await s31() }
        if want(32) { try await s32() }
        if want(33) { try await s33() }
        if want(34) { try await s34() }
        if want(35) { try await s35() }
        if want(36) { try await s36() }
        if want(37) { try await s37() }
        if want(38) { try await s38() }
        if want(39) { try await s39() }
        if want(40) { try await s40() }
        if want(41) { try await s41() }
        if want(42) { try await s42() }
        if want(43) { try await s43() }
    } catch { print("harness error: \(error)"); bugCount += 1 }
    print("\n\(bugCount == 0 ? "ALL CLEAR" : "\(bugCount) BUG LINE(S)")")
    finish(bugCount == 0 ? 0 : 1)
}
RunLoop.main.run()
