import XCTest
@testable import FreeAgentKit

private final class StubTransport: FreeAgentTransport {
    struct Call {
        let request: URLRequest
    }
    var calls: [Call] = []
    /// Queue of (statusCode, body) pairs returned in order, one per call.
    var responses: [(Int, Data)] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.append(Call(request: request))
        guard !responses.isEmpty else {
            fatalError("StubTransport ran out of queued responses")
        }
        let (status, body) = responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

final class FreeAgentAPIClientTests: XCTestCase {
    private func makeStore(expired: Bool = false) -> KeychainTokenStore {
        let store = KeychainTokenStore(service: "com.ratchet.freeagent.test.\(UUID().uuidString)")
        store.save(FreeAgentTokens(
            accessToken: "valid-access-token",
            refreshToken: "valid-refresh-token",
            expiresAt: Date(timeIntervalSinceNow: expired ? -10 : 3600)
        ))
        return store
    }

    func test_get_sendsBearerTokenAndDecodesJSON() async throws {
        struct Thing: Decodable, Equatable { let name: String }
        let transport = StubTransport()
        transport.responses = [(200, Data(#"{"name":"hello"}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        let result: Thing = try await client.get("things/1")

        XCTAssertEqual(result, Thing(name: "hello"))
        XCTAssertEqual(transport.calls[0].request.value(forHTTPHeaderField: "Authorization"), "Bearer valid-access-token")
        store.clear()
    }

    func test_getList_followsPaginationUntilShortPage() async throws {
        struct Item: Decodable, Equatable { let id: Int }
        let transport = StubTransport()
        let fullPage = (1...100).map { "{\"id\":\($0)}" }.joined(separator: ",")
        transport.responses = [
            (200, Data(#"{"items":["#.utf8 + Data(fullPage.utf8) + Data("]}".utf8)),
            (200, Data(#"{"items":[{"id":101}]}"#.utf8)),
        ]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        let result: [Item] = try await client.getList("items", listKey: "items")

        XCTAssertEqual(result.count, 101)
        XCTAssertEqual(transport.calls.count, 2)
        store.clear()
    }

    func test_authenticatedRequest_refreshesExpiredTokenBeforeSending() async throws {
        struct Thing: Decodable { let name: String }
        let transport = StubTransport()
        transport.responses = [
            (200, Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)), // refresh
            (200, Data(#"{"name":"hello"}"#.utf8)), // actual request
        ]
        let store = makeStore(expired: true)
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        _ = try await client.get("things/1") as Thing

        XCTAssertEqual(transport.calls[1].request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
        XCTAssertEqual(store.load()?.accessToken, "new-access")
        store.clear()
    }

    func test_authenticatedRequest_retriesOnceOn401ThenSucceeds() async throws {
        struct Thing: Decodable { let name: String }
        let transport = StubTransport()
        transport.responses = [
            (401, Data()), // first attempt rejected
            (200, Data(#"{"access_token":"refreshed","refresh_token":"refreshed-r","expires_in":3600}"#.utf8)), // refresh
            (200, Data(#"{"name":"hello"}"#.utf8)), // retried request
        ]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        _ = try await client.get("things/1") as Thing

        XCTAssertEqual(transport.calls.count, 3)
        store.clear()
    }

    func test_authenticatedRequest_stopsAfterOneRetryAndThrowsUnauthorizedOnSecond401() async {
        struct Thing: Decodable {}
        let transport = StubTransport()
        transport.responses = [
            (401, Data()), // first attempt rejected
            (200, Data(#"{"access_token":"refreshed","refresh_token":"refreshed-r","expires_in":3600}"#.utf8)), // refresh
            (401, Data()), // retried request rejected again
        ]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        do {
            _ = try await client.get("things/1") as Thing
            XCTFail("expected an error")
        } catch FreeAgentError.unauthorized {
            // expected
        } catch {
            XCTFail("expected FreeAgentError.unauthorized, got \(error)")
        }
        XCTAssertEqual(transport.calls.count, 3)
        store.clear()
    }

    func test_apiError_forNon401FailureStatus_throwsApiErrorWithMessage() async {
        let transport = StubTransport()
        transport.responses = [(422, Data(#"{"error":"Name can't be blank"}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        do {
            struct Thing: Decodable {}
            _ = try await client.get("things/1") as Thing
            XCTFail("expected an error")
        } catch let FreeAgentError.apiError(status, message) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(message, "Name can't be blank")
        } catch {
            XCTFail("expected FreeAgentError.apiError, got \(error)")
        }
        store.clear()
    }

    func test_post_wrapsBodyInEnvelopeKey() async throws {
        struct CreateBody: Encodable { let name: String }
        struct Created: Decodable { let name: String }
        let transport = StubTransport()
        transport.responses = [(201, Data(#"{"name":"new thing"}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        _ = try await client.post("things", envelopeKey: "thing", body: CreateBody(name: "new thing")) as Created

        let sentBody = transport.calls[0].request.httpBody!
        let json = try JSONSerialization.jsonObject(with: sentBody) as! [String: Any]
        XCTAssertNotNil(json["thing"])
        store.clear()
    }
}
