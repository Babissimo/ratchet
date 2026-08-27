// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import FreeAgentKit
import RatchetCore

private final class StubTransport: FreeAgentTransport {
    var responsesByPathSubstring: [(match: String, status: Int, body: Data)] = []
    var calls: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.append(request)
        let path = request.url!.absoluteString
        guard let entry = responsesByPathSubstring.first(where: { path.contains($0.match) }) else {
            fatalError("No stubbed response matches \(path)")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: entry.status, httpVersion: nil, headerFields: nil)!
        return (entry.body, response)
    }
}

/// A `StubTransport` that can hold the first request matching `gateMatch` open until released,
/// so a test can interleave a user action with a refresh that is still in flight.
@MainActor
private final class GatedStubTransport: FreeAgentTransport {
    var responsesByPathSubstring: [(match: String, status: Int, body: Data)] = []
    private let gateMatch: String
    private var armed = false
    private var gateHit = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(gateMatch: String) { self.gateMatch = gateMatch }

    func arm() { armed = true }

    func release() {
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
    }

    /// Returns `true` once the gate is hit, `false` if it times out first. The caller must check
    /// this before doing anything else — proceeding after a `false` means the interleaving under
    /// test never happened (a query-parameter rename, say, breaking `gateMatch`), so the test
    /// would go on to pass vacuously without exercising the race at all. It's also the only safe
    /// way to avoid a hang: `release()` on an empty `waiting` array is a no-op, so if the gate is
    /// then hit *after* this times out, that later `waitIfGated` call registers a continuation
    /// nobody will ever resume, and anything still awaiting the gated task hangs forever.
    func waitForGate() async -> Bool {
        for _ in 0..<2000 {
            if gateHit { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }

    /// Registers the continuation synchronously on the main actor, so `release()` can never run
    /// before the waiter has been recorded — that ordering hole deadlocks the test.
    private func waitIfGated(_ url: String) async {
        guard armed, url.contains(gateMatch), !gateHit else { return }
        gateHit = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
        }
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!.absoluteString
        await waitIfGated(url)
        return try await MainActor.run {
            guard let entry = responsesByPathSubstring.first(where: { url.contains($0.match) }) else {
                fatalError("No stubbed response matches \(url)")
            }
            return (entry.body, HTTPURLResponse(url: request.url!, statusCode: entry.status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

// Exercises @MainActor-isolated types (see DataStore's isolation), so the whole case is pinned
// to the main actor rather than annotating every test method.
@MainActor
final class FreeAgentDataStoreTests: XCTestCase {
    private func makeStore(transport: any FreeAgentTransport) -> (FreeAgentDataStore, KeychainTokenStore) {
        let tokenStore = KeychainTokenStore(service: "com.ratchet.freeagent.test.\(UUID().uuidString)")
        tokenStore.save(FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: 3600)))
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: tokenStore, transport: transport)
        return (FreeAgentDataStore(apiClient: apiClient, environment: .sandbox), tokenStore)
    }

    func test_refresh_assemblesClientProjectTaskTree() async throws {
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            // Single-resource GETs are wrapped under their resource-name key, same as POST responses.
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme-test"}}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[{"url":"https://api.sandbox.freeagent.com/v2/contacts/1","organisation_name":"Acme","first_name":null,"last_name":null,"email":null,"phone_number":null,"address1":null,"town":null,"postcode":null,"country":null}]}"#.utf8)),
            (match: "projects", status: 200, body: Data(#"{"projects":[{"url":"https://api.sandbox.freeagent.com/v2/projects/1","contact":"https://api.sandbox.freeagent.com/v2/contacts/1","name":"Website Redesign","status":"Active","currency":"GBP","budget":"0","budget_units":"Hours","hours_per_day":"8","normal_billing_rate":"0","billing_period":"hour","uses_project_invoice_sequence":false,"contract_po_reference":null,"starts_on":null,"ends_on":null}]}"#.utf8)),
            (match: "tasks", status: 200, body: Data(#"{"tasks":[{"url":"https://api.sandbox.freeagent.com/v2/tasks/1","project":"https://api.sandbox.freeagent.com/v2/projects/1","name":"Development","is_billable":true,"status":"Active","billing_rate":null,"billing_period":null}]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)

        try await store.refresh()

        XCTAssertEqual(store.accountEmail, "al@example.com")
        XCTAssertEqual(store.webAppURL, URL(string: "https://acme-test.sandbox.freeagent.com"))
        XCTAssertEqual(store.clients.map(\.name), ["Acme"])
        XCTAssertEqual(store.clients[0].projects.map(\.name), ["Website Redesign"])
        XCTAssertEqual(store.clients[0].projects[0].tasks.map(\.name), ["Development"])
        tokenStore.clear()
    }

    func test_refresh_succeedsEvenWhenCompanyFetchFails() async throws {
        // "Open FreeAgent" is a menu convenience — a company-endpoint hiccup shouldn't fail
        // the whole refresh (and thus the login/data-load flow) over it.
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 404, body: Data()),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)

        try await store.refresh()

        XCTAssertEqual(store.accountEmail, "al@example.com")
        XCTAssertNil(store.webAppURL)
        tokenStore.clear()
    }

    func test_startTimer_reusesExistingTimeslipForToday() async throws {
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            // Priming refresh() — requireUserURL() gates every startTimer/stopTimer/
            // updateTimeslip/runningTimeslip call now, and currentUserURL is only ever set by a
            // successful refresh(). "view=running" doubles as both refresh's own running-check
            // and startTimer's — both want "nothing running" here.
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme-test"}}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects?", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks?", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
            // The authoritative "is anything running at all" check startTimer now does first —
            // nothing running, so it falls through to the today-scoped search below.
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
            // The "find today's timeslip for this task" search — distinguished
            // from the create-POST (plain "timeslips", no query) by "task=".
            (match: "task=", status: 200, body: Data(#"{"timeslips":[{"url":"https://api.sandbox.freeagent.com/v2/timeslips/55","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"0.0","comment":null,"timer":null}]}"#.utf8)),
            // Starting the timer on the found timeslip. Observed against the sandbox API: this
            // response is wrapped as "timeslip", not "timer" like the request body — the timer
            // POST returns the updated timeslip, not a "timer" resource.
            (match: "/timeslips/55/timer", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/55","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"0.0","comment":null,"timer":{"running":true,"start_from":"2026-08-11T10:00:00Z"}}}"#.utf8)),
            // Refresh's own windowed "recent timeslips" fetch — kept last so the more specific
            // "task="/"view=running" matches above win for the URLs that also contain "timeslips?".
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        try await store.refresh()
        transport.calls = []

        let result = try await store.startTimer(
            taskId: "https://api.sandbox.freeagent.com/v2/tasks/1",
            projectId: "https://api.sandbox.freeagent.com/v2/projects/1",
            clientId: "https://api.sandbox.freeagent.com/v2/contacts/1"
        )

        XCTAssertEqual(result.id, "https://api.sandbox.freeagent.com/v2/timeslips/55")
        XCTAssertEqual(result.clientId, "https://api.sandbox.freeagent.com/v2/contacts/1")
        XCTAssertEqual(store.currentRunningTimeslip?.id, "https://api.sandbox.freeagent.com/v2/timeslips/55")
        // Running-check + today-search + timer-start — no create-POST, since a
        // timeslip for today already existed.
        XCTAssertEqual(transport.calls.count, 3)
        XCTAssertTrue(transport.calls[2].url!.absoluteString.contains("/timer"))
        XCTAssertEqual(transport.calls[2].httpMethod, "POST")
        tokenStore.clear()
    }

    func test_startTimer_resumesAlreadyRunningTimeslipForSameTaskWithoutDuplicating() async throws {
        // The bug this guards against: a timer started before midnight is still running
        // server-side under yesterday's `dated_on`, so the today-scoped "existing timeslip for
        // this task" search (matched on "task=" below) would never find it. Before the fix,
        // startTimer used only that today-scoped search, so calling it again for the same task
        // (e.g. app restart while the timer is still running) created a second, duplicate
        // timeslip dated today. It must resolve via the "is anything running" check up front and
        // resume the existing running timeslip — with no today-scoped search and no timer-start
        // POST, since it's already running.
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            // Priming refresh() — see the comment on the previous test. This "view=running" body
            // (already running for task 1) doubles as refresh's own running-check, so the store
            // already has this timeslip cached before startTimer is called again — exactly the
            // "app restart while the timer is still running" scenario this test exercises.
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme-test"}}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects?", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks?", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[{"url":"https://api.sandbox.freeagent.com/v2/timeslips/55","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-16","hours":"2.0","comment":null,"timer":{"running":true,"start_from":"2026-08-16T23:30:00Z"}}]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        try await store.refresh()
        transport.calls = []

        let result = try await store.startTimer(
            taskId: "https://api.sandbox.freeagent.com/v2/tasks/1",
            projectId: "https://api.sandbox.freeagent.com/v2/projects/1",
            clientId: "https://api.sandbox.freeagent.com/v2/contacts/1"
        )

        XCTAssertEqual(result.id, "https://api.sandbox.freeagent.com/v2/timeslips/55")
        XCTAssertEqual(store.currentRunningTimeslip?.id, "https://api.sandbox.freeagent.com/v2/timeslips/55")
        // Only the running-check call — no today-scoped search, no create, no timer-start.
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertTrue(transport.calls[0].url!.absoluteString.contains("view=running"))
        tokenStore.clear()
    }

    func test_startTimer_reVerifiesWithServerRatherThanTrustingACachedRunningTimeslip() async throws {
        // The bug this guards against: once `currentRunningTimeslip` was populated (by an
        // earlier startTimer call, or by refresh()), a later startTimer for the *same* task
        // trusted that cached entry outright and skipped the running-check network call
        // entirely. If the cached timeslip had since stopped running server-side — e.g. it was
        // yesterday's, and the day rolled over while nothing re-synced — the caller got back a
        // "success" without FreeAgent ever being contacted: the menu showed tracking locally
        // while nothing was running remotely. startTimer must re-verify with the server every
        // time, not just when the cache is empty.
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            // Priming refresh() — see the comment on the first startTimer test above.
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme-test"}}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects?", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks?", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[{"url":"https://api.sandbox.freeagent.com/v2/timeslips/55","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-18","hours":"2.0","comment":null,"timer":{"running":true,"start_from":"2026-08-18T23:30:00Z"}}]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        try await store.refresh()
        transport.calls = []

        _ = try await store.startTimer(
            taskId: "https://api.sandbox.freeagent.com/v2/tasks/1",
            projectId: "https://api.sandbox.freeagent.com/v2/projects/1",
            clientId: "https://api.sandbox.freeagent.com/v2/contacts/1"
        )
        XCTAssertEqual(store.currentRunningTimeslip?.id, "https://api.sandbox.freeagent.com/v2/timeslips/55")

        // Yesterday's timer has since stopped server-side, so the running-check now reports
        // nothing running — but the cache still holds yesterday's now-stale entry. Inserted at
        // 0 so `first(where:)` prefers it over the original "view=running" stub above.
        transport.responsesByPathSubstring.insert(
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)), at: 0
        )
        transport.responsesByPathSubstring.append(
            (match: "task=", status: 200, body: Data(#"{"timeslips":[]}"#.utf8))
        )
        transport.responsesByPathSubstring.append(
            (match: "/timeslips/99/timer", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/99","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-19","hours":"0.0","comment":null,"timer":{"running":true,"start_from":"2026-08-19T09:00:00Z"}}}"#.utf8))
        )
        transport.responsesByPathSubstring.append(
            (match: "timeslips", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/99","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-19","hours":"0.0","comment":null,"timer":null}}"#.utf8))
        )

        let result = try await store.startTimer(
            taskId: "https://api.sandbox.freeagent.com/v2/tasks/1",
            projectId: "https://api.sandbox.freeagent.com/v2/projects/1",
            clientId: "https://api.sandbox.freeagent.com/v2/contacts/1"
        )

        // A brand-new timeslip for today, not a silent resume of the stale cached one.
        XCTAssertEqual(result.id, "https://api.sandbox.freeagent.com/v2/timeslips/99")
        XCTAssertEqual(store.currentRunningTimeslip?.id, "https://api.sandbox.freeagent.com/v2/timeslips/99")
        // First startTimer: 1 call. Second startTimer: running-check + today-search +
        // create-POST + timer-start = 4 more calls.
        XCTAssertEqual(transport.calls.count, 5)
        XCTAssertTrue(transport.calls[1].url!.absoluteString.contains("view=running"))
        XCTAssertTrue(transport.calls.last!.url!.absoluteString.contains("/timeslips/99/timer"))
        XCTAssertEqual(transport.calls.last!.httpMethod, "POST")
        tokenStore.clear()
    }

    func test_startTimer_throwsWhenAnotherTaskIsAlreadyRunning() async throws {
        // The app enforces single-timer-at-a-time in the UI (the tracking screen's menu offers
        // only "Stop", never another "Start"), so a running timeslip for a *different* task here
        // means local/server state has drifted, not a normal call path. startTimer must not
        // silently stop the other task's timer to start this one.
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            // Priming refresh() — see the comment on the first startTimer test above. Its own
            // running-check must report *nothing* running (unlike this test's actual scenario)
            // so it doesn't itself throw the same "another task" error before the test's own
            // startTimer call gets a chance to.
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme-test"}}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects?", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks?", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
            // Refresh's own running-check must report nothing running, so refresh() itself
            // doesn't trip the same "another task" error before the test's own call gets to.
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        try await store.refresh()
        transport.calls = []

        // Only now does the running-check report a different task running — inserted ahead of
        // the "nothing running" rule above so it shadows it for the test's own startTimer call.
        transport.responsesByPathSubstring.insert(
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[{"url":"https://api.sandbox.freeagent.com/v2/timeslips/55","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/2","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-16","hours":"2.0","comment":null,"timer":{"running":true,"start_from":"2026-08-16T23:30:00Z"}}]}"#.utf8)),
            at: 0
        )

        do {
            _ = try await store.startTimer(
                taskId: "https://api.sandbox.freeagent.com/v2/tasks/1",
                projectId: "https://api.sandbox.freeagent.com/v2/projects/1",
                clientId: "https://api.sandbox.freeagent.com/v2/contacts/1"
            )
            XCTFail("expected startTimer to throw when a different task is already running")
        } catch let error as DataStoreError {
            // Pinned to the exact message, not just the case — `requireUserURL()`'s failure is
            // also `.underlying`, and a bare `catch DataStoreError.underlying {}` let this test
            // pass vacuously against the wrong error (and a call count of 0, not 1) once that
            // guard started firing before a priming refresh.
            XCTAssertEqual(error, DataStoreError.underlying("A timer is already running for another task elsewhere. Choose Refresh, then stop it from there."))
        } catch {
            XCTFail("expected DataStoreError.underlying, got \(error)")
        }
        XCTAssertNil(store.currentRunningTimeslip)
        XCTAssertEqual(transport.calls.count, 1)
        tokenStore.clear()
    }

    func test_startTimer_createsTimeslipWhenNoneExistsForToday() async throws {
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            // Priming refresh() — see the comment on the first startTimer test above.
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme-test"}}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects?", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks?", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
            // The authoritative "is anything running at all" check startTimer now does first.
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
            // Search finds nothing for today.
            (match: "task=", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
            // Starting the timer on the newly-created timeslip — wrapped as "timeslip" (see the
            // matching comment on the /timeslips/55/timer stub above).
            (match: "/timeslips/99/timer", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/99","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"0.0","comment":null,"timer":{"running":true,"start_from":"2026-08-11T10:00:00Z"}}}"#.utf8)),
            // Refresh's own windowed "recent timeslips" fetch — has a "?" (query params), so it's
            // distinguished from the plain create-POST URL below by "timeslips?" vs "timeslips".
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
            // Fallback: the plain create-POST to "timeslips" (no query).
            (match: "timeslips", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/99","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"0.0","comment":null,"timer":null}}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        try await store.refresh()
        transport.calls = []

        let result = try await store.startTimer(
            taskId: "https://api.sandbox.freeagent.com/v2/tasks/1",
            projectId: "https://api.sandbox.freeagent.com/v2/projects/1",
            clientId: "https://api.sandbox.freeagent.com/v2/contacts/1"
        )

        XCTAssertEqual(result.id, "https://api.sandbox.freeagent.com/v2/timeslips/99")
        XCTAssertEqual(store.currentRunningTimeslip?.id, "https://api.sandbox.freeagent.com/v2/timeslips/99")
        // Running-check + today-search + create-POST + timer-start = 4 calls.
        XCTAssertEqual(transport.calls.count, 4)
        XCTAssertEqual(transport.calls[0].httpMethod, "GET")
        XCTAssertTrue(transport.calls[0].url!.absoluteString.contains("view=running"))
        XCTAssertEqual(transport.calls[1].httpMethod, "GET")
        XCTAssertEqual(transport.calls[2].httpMethod, "POST")
        XCTAssertFalse(transport.calls[2].url!.absoluteString.contains("/timer"))
        XCTAssertEqual(transport.calls[3].httpMethod, "POST")
        XCTAssertTrue(transport.calls[3].url!.absoluteString.contains("/timer"))
        tokenStore.clear()
    }

    func test_stopTimer_deletesTimerOnRunningTimeslip() async throws {
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme-test"}}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
            // Specific match for the running-timer query, checked before the
            // generic "timeslips?" fallback used for today's timeslips.
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[{"url":"https://api.sandbox.freeagent.com/v2/timeslips/77","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"1.5","comment":null,"timer":{"running":true,"start_from":"2026-08-11T09:00:00Z"}}]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        try await store.refresh()
        XCTAssertEqual(store.currentRunningTimeslip?.id, "https://api.sandbox.freeagent.com/v2/timeslips/77")

        // Stopping hits timeslip 77 twice: the DELETE that stops the timer, then a read-back of
        // the bare resource. Order matters and is not interchangeable — `send` takes the first
        // rule whose substring occurs in the URL, and "/timeslips/77" occurs in the DELETE's URL
        // as well, so the reverse order would answer the DELETE with the settled body.
        transport.responsesByPathSubstring.insert(contentsOf: [
            (match: "/timeslips/77/timer", status: 200, body: Data()),
            // Higher hours than the running fixture's 1.5, and no timer object: FreeAgent leaves
            // a running timeslip's `hours` at its last pause, so the stop is the first moment the
            // server holds the real total. That gap is the entire reason for the read-back.
            (match: "/timeslips/77", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/77","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"2.25","comment":null,"timer":null,"billed_on_invoice":null}}"#.utf8)),
        ], at: 0)

        let stopped = try await store.stopTimer()

        XCTAssertEqual(stopped?.id, "https://api.sandbox.freeagent.com/v2/timeslips/77")
        // The settled total from the read-back, not the 1.5 the running copy still reported, and
        // no start instant left behind for the elapsed-time display to count up from.
        XCTAssertEqual(stopped?.hours, 2.25)
        XCTAssertNil(stopped?.timerStartedAt)
        XCTAssertNil(store.currentRunningTimeslip)
        // A timeslip started and stopped between two refreshes exists nowhere else locally, and
        // "Recent time entries" is built from this cache — so it has to land here immediately.
        XCTAssertEqual(store.timeslips.map(\.id), ["https://api.sandbox.freeagent.com/v2/timeslips/77"])
        XCTAssertEqual(store.timeslips.first?.hours, 2.25)
        // Indexed from the end rather than `.last`, which is the read-back: the DELETE has to
        // come first, since a read-back issued before the stop would capture the stale hours.
        let deleteCall = transport.calls[transport.calls.count - 2]
        XCTAssertEqual(deleteCall.httpMethod, "DELETE")
        XCTAssertTrue(deleteCall.url!.absoluteString.contains("/timeslips/77/timer"))
        let readBack = transport.calls.last!
        XCTAssertEqual(readBack.httpMethod, "GET")
        XCTAssertEqual(readBack.url!.absoluteString, "https://api.sandbox.freeagent.com/v2/timeslips/77")
        tokenStore.clear()
    }

    func test_updateTimeslip_putsTheFullRecordAndReplacesTheCachedEntry() async throws {
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme-test"}}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[{"url":"https://api.sandbox.freeagent.com/v2/timeslips/42","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-10","hours":"1.0","comment":null,"timer":null}]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        try await store.refresh()
        XCTAssertEqual(store.timeslips.count, 1)

        transport.responsesByPathSubstring.insert(
            (match: "/timeslips/42", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/42","project":"https://api.sandbox.freeagent.com/v2/projects/2","task":"https://api.sandbox.freeagent.com/v2/tasks/2","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"2.5","comment":"Reassigned","timer":null}}"#.utf8)),
            at: 0
        )

        let updated = try await store.updateTimeslip(
            id: "https://api.sandbox.freeagent.com/v2/timeslips/42",
            taskId: "https://api.sandbox.freeagent.com/v2/tasks/2",
            projectId: "https://api.sandbox.freeagent.com/v2/projects/2",
            clientId: "https://api.sandbox.freeagent.com/v2/contacts/2",
            date: CalendarDay.day(from: "2026-08-11")!,
            hours: 2.5,
            comment: "Reassigned"
        )

        XCTAssertEqual(updated.taskId, "https://api.sandbox.freeagent.com/v2/tasks/2")
        XCTAssertEqual(updated.hours, 2.5)
        XCTAssertEqual(updated.comment, "Reassigned")
        // Replaced in the local cache, not appended alongside the stale entry.
        XCTAssertEqual(store.timeslips.count, 1)
        XCTAssertEqual(store.timeslips[0], updated)

        let putCall = transport.calls.last!
        XCTAssertEqual(putCall.httpMethod, "PUT")
        XCTAssertTrue(putCall.url!.absoluteString.contains("/timeslips/42"))
        tokenStore.clear()
    }

    func test_updateTimeslip_onTheRunningEntry_updatesCurrentRunningTimeslipToo() async throws {
        // "Switch task" edits a *running* timeslip's task in place (rather than stopping and
        // starting a new one) so the timer keeps counting continuously — `currentRunningTimeslip`
        // is a separate stored property from `timeslips`, so without this fix it would keep
        // pointing at the pre-edit task/project/client until the next `refresh()`.
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            // Priming refresh() — requireUserURL() gates startTimer and updateTimeslip both.
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme-test"}}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects?", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks?", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[{"url":"https://api.sandbox.freeagent.com/v2/timeslips/55","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-16","hours":"2.0","comment":null,"timer":{"running":true,"start_from":"2026-08-16T23:30:00Z"}}]}"#.utf8)),
            (match: "/timeslips/55", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/55","project":"https://api.sandbox.freeagent.com/v2/projects/2","task":"https://api.sandbox.freeagent.com/v2/tasks/2","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-16","hours":"2.0","comment":null,"timer":{"running":true,"start_from":"2026-08-16T23:30:00Z"}}}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        try await store.refresh()
        transport.calls = []

        _ = try await store.startTimer(
            taskId: "https://api.sandbox.freeagent.com/v2/tasks/1",
            projectId: "https://api.sandbox.freeagent.com/v2/projects/1",
            clientId: "https://api.sandbox.freeagent.com/v2/contacts/1"
        )
        XCTAssertEqual(store.currentRunningTimeslip?.taskId, "https://api.sandbox.freeagent.com/v2/tasks/1")

        _ = try await store.updateTimeslip(
            id: "https://api.sandbox.freeagent.com/v2/timeslips/55",
            taskId: "https://api.sandbox.freeagent.com/v2/tasks/2",
            projectId: "https://api.sandbox.freeagent.com/v2/projects/2",
            clientId: "https://api.sandbox.freeagent.com/v2/contacts/2",
            date: CalendarDay.day(from: "2026-08-16")!,
            hours: 2.0,
            comment: nil
        )

        XCTAssertEqual(store.currentRunningTimeslip?.taskId, "https://api.sandbox.freeagent.com/v2/tasks/2")
        XCTAssertEqual(store.currentRunningTimeslip?.id, "https://api.sandbox.freeagent.com/v2/timeslips/55")
        tokenStore.clear()
    }

    func test_stopTimer_queriesServerAndReturnsNilWhenCacheIsEmptyAndNothingIsRunning() async throws {
        // `stopTimer()` queries the server unconditionally, never trusting the cache either way
        // — this covers the "cache empty" half of that: an empty `currentRunningTimeslip` isn't
        // proof nothing is running (a timer could have started elsewhere since the last refresh),
        // so stopTimer() must still check before reporting nothing to stop.
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            // Priming refresh() — requireUserURL() gates stopTimer() too, since it resolves the
            // running timeslip through the same server query as everything else.
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme-test"}}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        try await store.refresh()
        XCTAssertNil(store.currentRunningTimeslip)
        transport.calls = []

        let stopped = try await store.stopTimer()

        XCTAssertNil(stopped)
        // Exactly one call after the priming refresh — the running-timeslip query — confirming
        // stopTimer() checked the server itself rather than trusting the already-empty cache.
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertTrue(transport.calls[0].url!.absoluteString.contains("view=running"))
        tokenStore.clear()
    }

    func test_startTimer_neverReportsAStartInstantHoursInThePast() async throws {
        // The regression this guards: when the POST /timer response carried no `timer` object,
        // the start instant fell back to local midnight, so a timer begun seconds ago displayed
        // as many hours elapsed as had passed since midnight.
        let transport = StubTransport()
        let today = CalendarDay.dayString(from: Date())
        transport.responsesByPathSubstring = [
            // Priming refresh() — requireUserURL() gates startTimer now. "projects?"/"tasks?"
            // (not the bare "projects"/"tasks" used elsewhere in this file) so these don't shadow
            // the today-scoped search below, whose query embeds the task/project *URLs* — each of
            // which contains the substrings "projects" and "tasks" in its own right.
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme-test"}}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects?", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks?", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[{"url":"https://api.sandbox.freeagent.com/v2/timeslips/1","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"\#(today)","hours":"0.0","comment":null,"timer":null,"billed_on_invoice":null}]}"#.utf8)),
            (match: "/timer", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/1","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"\#(today)","hours":"0.0","comment":null,"timer":null,"billed_on_invoice":null}}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        defer { tokenStore.clear() }
        try await store.refresh()

        let started = try await store.startTimer(
            taskId: "https://api.sandbox.freeagent.com/v2/tasks/1",
            projectId: "https://api.sandbox.freeagent.com/v2/projects/1",
            clientId: "https://api.sandbox.freeagent.com/v2/contacts/1"
        )
        let startedAt = try XCTUnwrap(started.timerStartedAt)
        XCTAssertLessThan(abs(startedAt.timeIntervalSinceNow), 5)
    }

    func test_refresh_commitsNothingWhenAnyFetchFails() async throws {
        let today = CalendarDay.dayString(from: Date())
        let runningBody = #"{"url":"https://api.sandbox.freeagent.com/v2/timeslips/400","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"\#(today)","hours":"1.0","comment":null,"timer":{"running":true,"start_from":"2026-08-19T09:00:00Z"},"billed_on_invoice":null}"#
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme"}}"#.utf8)),
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[\#(runningBody)]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[\#(runningBody)]}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[{"url":"https://api.sandbox.freeagent.com/v2/contacts/1","organisation_name":"Acme","first_name":null,"last_name":null,"email":null,"phone_number":null,"address1":null,"town":null,"postcode":null,"country":null}]}"#.utf8)),
            (match: "projects", status: 200, body: Data(#"{"projects":[{"url":"https://api.sandbox.freeagent.com/v2/projects/1","contact":"https://api.sandbox.freeagent.com/v2/contacts/1","name":"Site","status":"Active","currency":"GBP","budget":"0","budget_units":"Hours","hours_per_day":"8","normal_billing_rate":"0","billing_period":"hour","uses_project_invoice_sequence":false,"contract_po_reference":null,"starts_on":null,"ends_on":null}]}"#.utf8)),
            (match: "tasks", status: 200, body: Data(#"{"tasks":[{"url":"https://api.sandbox.freeagent.com/v2/tasks/1","project":"https://api.sandbox.freeagent.com/v2/projects/1","name":"Dev","is_billable":true,"status":"Active","billing_rate":null,"billing_period":null}]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        defer { tokenStore.clear() }
        try await store.refresh()
        XCTAssertEqual(store.clients.count, 1)
        let firstRefreshAt = store.lastRefreshedAt

        // Second refresh: the contact list now comes back empty and the timeslip window 500s.
        // A partial commit here is what leaves a live running timeslip pointing into an empty
        // client tree — the state that strands a running timer with no way to stop it.
        transport.responsesByPathSubstring[4] = (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8))
        transport.responsesByPathSubstring[3] = (match: "timeslips?", status: 500, body: Data(#"{"error":"boom"}"#.utf8))

        do { try await store.refresh(); XCTFail("expected the refresh to throw") } catch {}

        XCTAssertEqual(store.clients.count, 1, "clients must not be committed by a failed refresh")
        XCTAssertEqual(store.timeslips.count, 1)
        XCTAssertNotNil(store.currentRunningTimeslip)
        XCTAssertEqual(store.lastRefreshedAt, firstRefreshAt, "a failed refresh must not stamp lastRefreshedAt")
    }

    func test_refresh_doesNotResurrectATimerStoppedWhileItWasInFlight() async throws {
        // The interleaving is the ordinary one: menuWillOpen fires a silent refresh, the user
        // clicks "Stop tracking" a second later, and the refresh's already-computed answer
        // ("timeslip 9 is running") lands afterwards. Before the epoch guard that answer won,
        // and the menu showed a green tray and a climbing clock for a stopped timer.
        let today = CalendarDay.dayString(from: Date())
        let runningBody = #"{"url":"https://api.sandbox.freeagent.com/v2/timeslips/9","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"\#(today)","hours":"0.0","comment":null,"timer":{"running":true,"start_from":"2026-08-19T09:00:00Z"},"billed_on_invoice":null}"#
        let transport = GatedStubTransport(gateMatch: "view=running")
        transport.responsesByPathSubstring = [
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme"}}"#.utf8)),
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[\#(runningBody)]}"#.utf8)),
            (match: "timeslips/9/timer", status: 200, body: Data("{}".utf8)),
            // The read-back stopTimer does once the DELETE lands, for the hours the server
            // settled on. Kept immediately after the "/timer" rule above and before the
            // "timeslips?" one: `send` takes the first substring match, so this rule would
            // otherwise swallow the DELETE's URL, which contains "timeslips/9" too.
            (match: "timeslips/9", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/9","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"\#(today)","hours":"0.75","comment":null,"timer":null,"billed_on_invoice":null}}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[\#(runningBody)]}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        defer { tokenStore.clear() }
        try await store.refresh()
        XCTAssertNotNil(store.currentRunningTimeslip)

        transport.arm()
        let inFlight = Task { @MainActor in try? await store.refresh() }
        // Bail out here rather than proceeding on a timeout: proceeding would mean either the
        // interleaving under test never happened (the refresh ran to completion unblocked, so
        // both assertions below pass without exercising the race at all) or, worse, calling
        // `release()` on nothing and then awaiting `inFlight` while a *later* gate hit registers
        // a continuation nobody will ever resume — a hang instead of a clean failure.
        guard await transport.waitForGate() else {
            XCTFail("refresh's view=running request never hit the gate — the interleaving this test exercises did not happen")
            return
        }
        let stopped = try await store.stopTimer()
        XCTAssertEqual(stopped?.hours, 0.75)
        XCTAssertNil(stopped?.timerStartedAt)
        XCTAssertNil(store.currentRunningTimeslip)
        transport.release()
        _ = await inFlight.value

        XCTAssertNil(store.currentRunningTimeslip, "the stale in-flight refresh must not resurrect the stopped timer")
        // The same staleness reaches the cached entry: the refresh's window fetch still describes
        // timeslip 9 as running with 0.0 hours, so committing it would undo the settled total too.
        XCTAssertEqual(store.timeslips.map(\.hours), [0.75])
        XCTAssertNil(store.timeslips.first?.timerStartedAt)
    }

    func test_stopTimer_stopsWhatIsActuallyRunningNotWhatWasCached() async throws {
        // Cache says 100; the server says 200 is running (100 was stopped from the web app and a
        // new one started). Trusting the cache stopped an already-stopped timeslip, reported
        // success, and left 200 billing with the menu showing idle.
        let today = CalendarDay.dayString(from: Date())
        func body(_ id: Int, _ start: String) -> String {
            #"{"url":"https://api.sandbox.freeagent.com/v2/timeslips/\#(id)","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"\#(today)","hours":"0.0","comment":null,"timer":{"running":true,"start_from":"\#(start)"},"billed_on_invoice":null}"#
        }
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
            (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme"}}"#.utf8)),
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[\#(body(100, "2026-08-19T09:00:00Z"))]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
            (match: "projects", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
            (match: "tasks", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
            // Catches both per-timeslip calls the stop makes: the DELETE, whose body is ignored,
            // and the settled-hours read-back after it. `{}` has no "timeslip" envelope, so the
            // read-back's decode fails and stopTimer takes its pre-stop-copy fallback — which is
            // what this test wants, since the identity of the stopped timeslip is its subject and
            // the fallback preserves it. Don't drop this rule: an unmatched URL is a fatalError.
            (match: "timeslips/", status: 200, body: Data("{}".utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)
        defer { tokenStore.clear() }
        try await store.refresh()
        XCTAssertEqual(store.currentRunningTimeslip?.id, "https://api.sandbox.freeagent.com/v2/timeslips/100")

        transport.responsesByPathSubstring[2] = (match: "view=running", status: 200, body: Data(#"{"timeslips":[\#(body(200, "2026-08-19T11:00:00Z"))]}"#.utf8))
        transport.calls = []
        let stopped = try await store.stopTimer()

        XCTAssertEqual(stopped?.id, "https://api.sandbox.freeagent.com/v2/timeslips/200")
        let deletes = transport.calls.filter { $0.httpMethod == "DELETE" }.map { $0.url!.absoluteString }
        XCTAssertEqual(deletes, ["https://api.sandbox.freeagent.com/v2/timeslips/200/timer"])
    }

    func test_logTime_refusesBeforeARefreshHasIdentifiedTheUser() async throws {
        // Every write interpolates currentUserURL into the body or query. Before the first
        // successful refresh it is "", which asks FreeAgent to file the entry against no user at
        // all — or, for the running-timeslip query, against every user in the company.
        let transport = StubTransport()
        transport.responsesByPathSubstring = [(match: "", status: 200, body: Data("{}".utf8))]
        let (store, tokenStore) = makeStore(transport: transport)
        defer { tokenStore.clear() }

        do {
            _ = try await store.logTime(taskId: "t", projectId: "p", clientId: "c", date: Date(), hours: 1, comment: nil)
            XCTFail("expected a refusal before the first refresh")
        } catch let error as DataStoreError {
            XCTAssertEqual(error, DataStoreError.underlying("Ratchet hasn't loaded your FreeAgent account yet — choose Refresh and try again."))
        }
    }
}
