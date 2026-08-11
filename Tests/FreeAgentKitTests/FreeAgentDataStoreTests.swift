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

final class FreeAgentDataStoreTests: XCTestCase {
    private func makeStore(transport: StubTransport) -> (FreeAgentDataStore, KeychainTokenStore) {
        let tokenStore = KeychainTokenStore(service: "com.ratchet.freeagent.test.\(UUID().uuidString)")
        tokenStore.save(FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: 3600)))
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: tokenStore, transport: transport)
        return (FreeAgentDataStore(apiClient: apiClient), tokenStore)
    }

    func test_refresh_assemblesClientProjectTaskTree() async throws {
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            (match: "users/me", status: 200, body: Data(#"{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[{"url":"https://api.sandbox.freeagent.com/v2/contacts/1","organisation_name":"Acme","first_name":null,"last_name":null,"email":null,"phone_number":null,"address1":null,"town":null,"postcode":null,"country":null}]}"#.utf8)),
            (match: "projects", status: 200, body: Data(#"{"projects":[{"url":"https://api.sandbox.freeagent.com/v2/projects/1","contact":"https://api.sandbox.freeagent.com/v2/contacts/1","name":"Website Redesign","status":"Active","currency":"GBP","budget":"0","budget_units":"Hours","hours_per_day":"8","normal_billing_rate":"0","billing_period":"hour","uses_project_invoice_sequence":false,"contract_po_reference":null,"starts_on":null,"ends_on":null}]}"#.utf8)),
            (match: "tasks", status: 200, body: Data(#"{"tasks":[{"url":"https://api.sandbox.freeagent.com/v2/tasks/1","project":"https://api.sandbox.freeagent.com/v2/projects/1","name":"Development","is_billable":true,"status":"Active","billing_rate":null,"billing_period":null}]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)

        try await store.refresh()

        XCTAssertEqual(store.accountEmail, "al@example.com")
        XCTAssertEqual(store.clients.map(\.name), ["Acme"])
        XCTAssertEqual(store.clients[0].projects.map(\.name), ["Website Redesign"])
        XCTAssertEqual(store.clients[0].projects[0].tasks.map(\.name), ["Development"])
        tokenStore.clear()
    }

    func test_startTimer_reusesExistingTimeslipForToday() async throws {
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            // The "find today's timeslip for this task" search — distinguished
            // from the create-POST (plain "timeslips", no query) by "task=".
            (match: "task=", status: 200, body: Data(#"{"timeslips":[{"url":"https://api.sandbox.freeagent.com/v2/timeslips/55","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"0.0","comment":null,"timer":null}]}"#.utf8)),
            // Starting the timer on the found timeslip.
            (match: "/timeslips/55/timer", status: 200, body: Data(#"{"url":"https://api.sandbox.freeagent.com/v2/timeslips/55","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"0.0","comment":null,"timer":{"running":true,"start_from":"2026-08-11T10:00:00Z"}}"#.utf8)),
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
            // Starting the timer on the newly-created timeslip.
            (match: "/timeslips/99/timer", status: 200, body: Data(#"{"url":"https://api.sandbox.freeagent.com/v2/timeslips/99","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"0.0","comment":null,"timer":{"running":true,"start_from":"2026-08-11T10:00:00Z"}}"#.utf8)),
            // Fallback: the plain create-POST to "timeslips" (no query).
            (match: "timeslips", status: 200, body: Data(#"{"url":"https://api.sandbox.freeagent.com/v2/timeslips/99","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"2026-08-11","hours":"0.0","comment":null,"timer":null}"#.utf8)),
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
            (match: "users/me", status: 200, body: Data(#"{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}"#.utf8)),
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

    func test_stopTimer_returnsNilWhenNothingIsRunning() async throws {
        let transport = StubTransport()
        let (store, tokenStore) = makeStore(transport: transport)

        let stopped = try await store.stopTimer()

        XCTAssertNil(stopped)
        XCTAssertTrue(transport.calls.isEmpty)
        tokenStore.clear()
    }
}
