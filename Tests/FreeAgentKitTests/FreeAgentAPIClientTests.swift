// SPDX-License-Identifier: GPL-3.0-or-later
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

// Exercises @MainActor-isolated types (see DataStore's isolation), so the whole case is pinned
// to the main actor rather than annotating every test method.
@MainActor
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
            (200, Data(#"{"items":["#.utf8) + Data(fullPage.utf8) + Data("]}".utf8)),
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

    func test_exchangeAuthorizationCode_sendsOnlyTheCodeAndVerifierToTheSignInService() async throws {
        let transport = StubTransport()
        transport.responses = [(200, Data(#"{"access_token":"a","refresh_token":"r","expires_in":3600}"#.utf8))]
        let store = KeychainTokenStore(service: "unused-in-this-test")
        let client = FreeAgentAPIClient(environment: .production, tokenStore: store, transport: transport)

        let tokens = try await client.exchangeAuthorizationCode("c0de/+=", codeVerifier: "v3r1f13r~")

        XCTAssertEqual(tokens.accessToken, "a")
        let request = transport.calls[0].request
        XCTAssertEqual(request.url, FreeAgentEnvironment.production.tokenURL)
        XCTAssertEqual(request.url?.host, "auth.ratchet.babissimo.net")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "the app must not carry client credentials")
        XCTAssertEqual(formFields(of: request), [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: "c0de/+="),
            URLQueryItem(name: "code_verifier", value: "v3r1f13r~"),
        ])
    }

    func test_refreshTokens_sendsOnlyTheRefreshTokenToTheSignInService() async throws {
        let transport = StubTransport()
        transport.responses = [(200, Data(#"{"access_token":"a2","refresh_token":"r2","expires_in":3600}"#.utf8))]
        let store = KeychainTokenStore(service: "unused-in-this-test")
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        _ = try await client.refreshTokens("r1")

        let request = transport.calls[0].request
        XCTAssertEqual(request.url, FreeAgentEnvironment.sandbox.tokenURL)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.httpBody.map { String(decoding: $0, as: UTF8.self) }, "grant_type=refresh_token&refresh_token=r1")
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

    func test_post_wrapsBodyInEnvelopeKeyAndUnwrapsTheResponseEnvelope() async throws {
        struct CreateBody: Encodable { let name: String }
        struct Created: Decodable, Equatable { let name: String }
        let transport = StubTransport()
        // FreeAgent wraps single-resource responses under the same key as the request body,
        // e.g. POST /contacts -> {"contact": {...}}, not a bare object.
        transport.responses = [(201, Data(#"{"thing":{"name":"new thing"}}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        let result = try await client.post("things", envelopeKey: "thing", body: CreateBody(name: "new thing")) as Created

        XCTAssertEqual(result, Created(name: "new thing"))
        let sentBody = transport.calls[0].request.httpBody!
        let json = try JSONSerialization.jsonObject(with: sentBody) as! [String: Any]
        XCTAssertNotNil(json["thing"])
        store.clear()
    }

    func test_post_withResponseEnvelopeKey_unwrapsUnderADifferentKeyThanTheRequest() async throws {
        // Regression test for POST /timeslips/:id/timer specifically: the request is
        // conventionally wrapped as {"timer": {}}, but observed against the real sandbox API,
        // the response comes back wrapped as {"timeslip": {...}} — the request and response
        // envelope keys aren't always the same.
        struct EmptyBody: Encodable {}
        struct Timeslip: Decodable, Equatable { let hours: String }
        let transport = StubTransport()
        transport.responses = [(200, Data(#"{"timeslip":{"hours":"0.5"}}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        let result = try await client.post(
            "timeslips/1/timer", envelopeKey: "timer", responseEnvelopeKey: "timeslip", body: EmptyBody()
        ) as Timeslip

        XCTAssertEqual(result, Timeslip(hours: "0.5"))
        let sentBody = transport.calls[0].request.httpBody!
        let json = try JSONSerialization.jsonObject(with: sentBody) as! [String: Any]
        XCTAssertNotNil(json["timer"], "request body should still use envelopeKey, not responseEnvelopeKey")
        store.clear()
    }

    func test_put_sendsPUTAndWrapsBodyInEnvelopeKey() async throws {
        struct UpdateBody: Encodable { let name: String }
        struct Updated: Decodable, Equatable { let name: String }
        let transport = StubTransport()
        transport.responses = [(200, Data(#"{"thing":{"name":"renamed"}}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        let result = try await client.put("things/1", envelopeKey: "thing", body: UpdateBody(name: "renamed")) as Updated

        XCTAssertEqual(result, Updated(name: "renamed"))
        XCTAssertEqual(transport.calls[0].request.httpMethod, "PUT")
        let sentBody = transport.calls[0].request.httpBody!
        let json = try JSONSerialization.jsonObject(with: sentBody) as! [String: Any]
        XCTAssertNotNil(json["thing"])
        store.clear()
    }

    func test_get_withEnvelopeKey_unwrapsSingleResourceResponse() async throws {
        struct User: Decodable, Equatable { let email: String }
        let transport = StubTransport()
        transport.responses = [(200, Data(#"{"user":{"email":"al@example.com"}}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        let result: User = try await client.get("users/me", envelopeKey: "user")

        XCTAssertEqual(result, User(email: "al@example.com"))
        store.clear()
    }

    func test_get_withEnvelopeKey_throwsDecodingErrorWhenKeyMissing() async {
        struct User: Decodable { let email: String }
        let transport = StubTransport()
        transport.responses = [(200, Data(#"{"wrong_key":{"email":"al@example.com"}}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        do {
            _ = try await client.get("users/me", envelopeKey: "user") as User
            XCTFail("expected FreeAgentError.decoding")
        } catch FreeAgentError.decoding {
            // expected
        } catch {
            XCTFail("expected FreeAgentError.decoding, got \(error)")
        }
        store.clear()
    }

    func test_get_decodesISO8601DatesWithFractionalSeconds() async throws {
        // FreeAgent's timer `start_from` comes back with fractional seconds
        // (e.g. "2026-08-12T15:51:37.435Z"), which plain JSONDecoder.dateDecodingStrategy
        // = .iso8601 rejects — regression test for that.
        struct Timestamped: Decodable { let at: Date }
        let transport = StubTransport()
        transport.responses = [(200, Data(#"{"at":"2026-08-12T15:51:37.435Z"}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        let result: Timestamped = try await client.get("things/1")

        // Truncate to millisecond precision for comparison — floating point round-tripping
        // through TimeInterval can differ in the sub-millisecond range.
        let expected = ISO8601DateFormatter()
        expected.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            result.at.timeIntervalSince1970.rounded(),
            expected.date(from: "2026-08-12T15:51:37.435Z")!.timeIntervalSince1970.rounded()
        )
        store.clear()
    }

    func test_getList_throwsWhenTheListKeyIsAbsent() async {
        // A silent `?? []` here meant a renamed/rewrapped envelope read as "you have no clients",
        // which refresh() then committed as success — emptying every menu with nothing to retry.
        let transport = StubTransport()
        transport.responses = [(200, Data(#"{"data":[]}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        do {
            let _: [FreeAgentContactDTO] = try await client.getList("contacts", listKey: "contacts")
            XCTFail("expected a decoding error for the missing \"contacts\" key")
        } catch FreeAgentError.decoding {
            // expected
        } catch {
            XCTFail("expected FreeAgentError.decoding, got \(error)")
        }
        store.clear()
    }

    func test_getList_stillReturnsAnEmptyListWhenTheKeyIsPresentButEmpty() async throws {
        let transport = StubTransport()
        transport.responses = [(200, Data(#"{"contacts":[]}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        let contacts: [FreeAgentContactDTO] = try await client.getList("contacts", listKey: "contacts")

        XCTAssertTrue(contacts.isEmpty)
        store.clear()
    }

    func test_get_stillDecodesISO8601DatesWithoutFractionalSeconds() async throws {
        struct Timestamped: Decodable { let at: Date }
        let transport = StubTransport()
        transport.responses = [(200, Data(#"{"at":"2026-08-12T15:51:37Z"}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        let result: Timestamped = try await client.get("things/1")

        XCTAssertEqual(result.at, ISO8601DateFormatter().date(from: "2026-08-12T15:51:37Z"))
        store.clear()
    }

    /// Decodes a form body the way the sign-in service's `URLSearchParams` does, so a test pins
    /// the values it receives rather than one of the encodings that produce them (`/` may go out
    /// literally or as `%2F`). `+` decodes to a space, which is what makes escaping it matter.
    private func formFields(of request: URLRequest) -> [URLQueryItem] {
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
                $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            return URLQueryItem(name: parts[0], value: parts.count > 1 ? parts[1] : nil)
        }
    }
}
