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

// Exercises @MainActor-isolated types (see DataStore's isolation), so the whole case is pinned
// to the main actor rather than annotating every test method.
@MainActor
final class FreeAgentDataStoreTests: XCTestCase {
    private func makeStore(transport: StubTransport) -> (FreeAgentDataStore, KeychainTokenStore) {
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
            // The "find today's timeslip for this task" search — distinguished
            // from the create-POST (plain "timeslips", no query) by "task=".
            (match: "task=", status: 200, body: Data(#"{"timeslips":[{"url":"https://api.sandbox.freeagent.com/v2/timeslips/55","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"0.0","comment":null,"timer":null}]}"#.utf8)),
            // Starting the timer on the found timeslip. Observed against the sandbox API: this
            // response is wrapped as "timeslip", not "timer" like the request body — the timer
            // POST returns the updated timeslip, not a "timer" resource.
            (match: "/timeslips/55/timer", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/55","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"0.0","comment":null,"timer":{"running":true,"start_from":"2026-08-11T10:00:00Z"}}}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)

        let result = try await store.startTimer(
            taskId: "https://api.sandbox.freeagent.com/v2/tasks/1",
            projectId: "https://api.sandbox.freeagent.com/v2/projects/1",
            clientId: "https://api.sandbox.freeagent.com/v2/contacts/1"
        )

        XCTAssertEqual(result.id, "https://api.sandbox.freeagent.com/v2/timeslips/55")
        XCTAssertEqual(result.clientId, "https://api.sandbox.freeagent.com/v2/contacts/1")
        XCTAssertEqual(store.currentRunningTimeslip?.id, "https://api.sandbox.freeagent.com/v2/timeslips/55")
        // Only the search + timer-start calls — no create-POST, since a
        // timeslip for today already existed.
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertTrue(transport.calls[1].url!.absoluteString.contains("/timer"))
        XCTAssertEqual(transport.calls[1].httpMethod, "POST")
        tokenStore.clear()
    }

    func test_startTimer_createsTimeslipWhenNoneExistsForToday() async throws {
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            // Search finds nothing for today.
            (match: "task=", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
            // Starting the timer on the newly-created timeslip — wrapped as "timeslip" (see the
            // matching comment on the /timeslips/55/timer stub above).
            (match: "/timeslips/99/timer", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/99","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"0.0","comment":null,"timer":{"running":true,"start_from":"2026-08-11T10:00:00Z"}}}"#.utf8)),
            // Fallback: the plain create-POST to "timeslips" (no query).
            (match: "timeslips", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/99","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"0.0","comment":null,"timer":null}}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)

        let result = try await store.startTimer(
            taskId: "https://api.sandbox.freeagent.com/v2/tasks/1",
            projectId: "https://api.sandbox.freeagent.com/v2/projects/1",
            clientId: "https://api.sandbox.freeagent.com/v2/contacts/1"
        )

        XCTAssertEqual(result.id, "https://api.sandbox.freeagent.com/v2/timeslips/99")
        XCTAssertEqual(store.currentRunningTimeslip?.id, "https://api.sandbox.freeagent.com/v2/timeslips/99")
        // Search + create-POST + timer-start = 3 calls.
        XCTAssertEqual(transport.calls.count, 3)
        XCTAssertEqual(transport.calls[0].httpMethod, "GET")
        XCTAssertEqual(transport.calls[1].httpMethod, "POST")
        XCTAssertFalse(transport.calls[1].url!.absoluteString.contains("/timer"))
        XCTAssertEqual(transport.calls[2].httpMethod, "POST")
        XCTAssertTrue(transport.calls[2].url!.absoluteString.contains("/timer"))
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

        // Stub the DELETE call the running timeslip's timer stop makes.
        transport.responsesByPathSubstring.insert(
            (match: "/timeslips/77/timer", status: 200, body: Data()), at: 0
        )

        let stopped = try await store.stopTimer()

        XCTAssertEqual(stopped?.id, "https://api.sandbox.freeagent.com/v2/timeslips/77")
        XCTAssertNil(store.currentRunningTimeslip)
        let deleteCall = transport.calls.last!
        XCTAssertEqual(deleteCall.httpMethod, "DELETE")
        XCTAssertTrue(deleteCall.url!.absoluteString.contains("/timeslips/77/timer"))
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

    func test_stopTimer_queriesServerAndReturnsNilWhenCacheIsEmptyAndNothingIsRunning() async throws {
        // No `refresh()` here, so `currentRunningTimeslip` starts nil — the case the
        // server-fallback in `stopTimer()` exists for (see its doc comment): an empty cache
        // isn't proof nothing is running, so it must check before giving up.
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            (match: "view=running", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)

        let stopped = try await store.stopTimer()

        XCTAssertNil(stopped)
        // Exactly one call — the fallback running-timeslip query — confirming the fallback
        // fired rather than the old no-op path that never touched the network.
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertTrue(transport.calls[0].url!.absoluteString.contains("view=running"))
        tokenStore.clear()
    }
}
