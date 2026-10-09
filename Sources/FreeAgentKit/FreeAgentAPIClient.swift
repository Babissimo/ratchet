// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Thrown by `decodeEnveloped` when the response's top-level key doesn't match what was expected
/// (e.g. requesting `envelopeKey: "user"` but the server returned some other top-level key).
///
/// `LocalizedError` conformance matters here, not just `CustomStringConvertible`: this reaches
/// the user through `FreeAgentError.decoding`'s description, which reads `error.localizedDescription`
/// — and for a plain struct that only conforms to `Error`, that bridges through `NSError` to a
/// generic "The operation couldn't be completed" wrapper, discarding this type's own message.
/// `errorDescription` is what `localizedDescription` actually consults before falling back to
/// that bridge, so mirroring `description` into it is what makes the real text show up.
private struct MissingEnvelopeKey: Error, CustomStringConvertible, LocalizedError {
    let envelopeKey: String
    var description: String { "expected top-level key \"\(envelopeKey)\" in the response" }
    var errorDescription: String? { description }
}

/// Abstraction over "send an HTTP request, get back a response" so tests
/// can inject a stub instead of hitting the network.
public protocol FreeAgentTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: FreeAgentTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FreeAgentError.network(URLError(.badServerResponse))
        }
        return (data, httpResponse)
    }
}

/// The session a store call began in, which every request it makes carries, including those of the
/// tasks it starts.
private enum Bound {
    @TaskLocal static var session: (client: ObjectIdentifier, generation: UInt64)?
}

/// `@MainActor`-isolated for the same reason as `DataStore` (its only consumers are the
/// main-actor `FreeAgentDataStore` and the login flow), and because `inFlightRefresh` below is
/// mutable shared state that must not be read/written concurrently. Only the `await`s on the
/// transport actually suspend, so this costs nothing in practice.
@MainActor
public final class FreeAgentAPIClient {
    private let environment: FreeAgentEnvironment
    private let tokenStore: KeychainTokenStore
    private let transport: FreeAgentTransport
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder

    // Read-only after init (used only for parsing, in a decode closure that may run off the
    // main actor) — safe to share across isolation contexts despite ISO8601DateFormatter not
    // being Sendable.
    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(environment: FreeAgentEnvironment, tokenStore: KeychainTokenStore, transport: FreeAgentTransport = URLSessionTransport()) {
        self.environment = environment
        self.tokenStore = tokenStore
        self.transport = transport
        self.jsonDecoder = JSONDecoder()
        // Plain `.iso8601` uses ISO8601DateFormatter's default options, which reject fractional
        // seconds — but FreeAgent's timer `start_from` comes back as e.g.
        // "2026-08-12T15:51:37.435Z", which has them. Try strict first (cheaper, no fractional
        // formatter allocation), fall back to fractional-seconds parsing.
        self.jsonDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = FreeAgentAPIClient.iso8601Formatter.date(from: string) {
                return date
            }
            if let date = FreeAgentAPIClient.iso8601FractionalFormatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO8601-formatted date, got \"\(string)\"")
        }
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Sessions

    /// Bumped by `endSession()`.
    private var session: UInt64 = 0

    /// Called on logging out. Work begun in the session through `inSession` sends nothing more.
    public func endSession() {
        session &+= 1
    }

    /// Runs `body` tied to the current session, or to the one its caller is tied to already.
    public func inSession<T>(_ body: () async throws -> T) async rethrows -> T {
        try await Bound.$session.withValue((ObjectIdentifier(self), callerSession), operation: body)
    }

    /// Throws `.sessionEnded` if the caller is tied to a session that has ended.
    public func requireSession() throws {
        if callerSession != session { throw FreeAgentError.sessionEnded }
    }

    /// The session the caller is tied to: the current one, unless it was tied to an earlier one.
    private var callerSession: UInt64 {
        guard let bound = Bound.session, bound.client == ObjectIdentifier(self) else { return session }
        return bound.generation
    }

    // MARK: - Authenticated requests

    /// `envelopeKey`, when given, unwraps a single-resource response the same way FreeAgent
    /// wraps list responses (`getList` below) — e.g. `GET /users/me` returns `{"user": {...}}`,
    /// not a bare object. Omit it for the rare endpoint that returns an unwrapped body.
    public func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], envelopeKey: String? = nil) async throws -> T {
        let data = try await authenticatedRequest(path: path, method: "GET", query: query, body: Data?.none)
        guard let envelopeKey else { return try decode(data) }
        return try decodeEnveloped(data, envelopeKey: envelopeKey)
    }

    /// Follows FreeAgent's `page`/`per_page` pagination until a page comes
    /// back with fewer than `per_page` items, collecting the full list.
    public func getList<T: Decodable>(_ path: String, query: [URLQueryItem] = [], listKey: String) async throws -> [T] {
        var page = 1
        let perPage = 100
        var all: [T] = []
        while true {
            var pageQuery = query
            pageQuery.append(URLQueryItem(name: "page", value: String(page)))
            pageQuery.append(URLQueryItem(name: "per_page", value: String(perPage)))
            let data = try await authenticatedRequest(path: path, method: "GET", query: pageQuery, body: Data?.none)
            let envelope = try decode(data, as: [String: [T]].self)
            // `?? []` here read a renamed or rewrapped envelope as "the account has none of
            // these", which `refresh()` then committed as a successful, empty refresh — every
            // menu blank, `lastRefreshedAt` stamped fresh, and nothing left to trigger a retry.
            // An absent key is a response Ratchet doesn't understand, not an empty account.
            guard let items = envelope[listKey] else {
                throw FreeAgentError.decoding(MissingEnvelopeKey(envelopeKey: listKey))
            }
            all.append(contentsOf: items)
            if items.count < perPage { break }
            page += 1
        }
        return all
    }

    /// `responseEnvelopeKey` defaults to `envelopeKey` — the response is usually wrapped under
    /// the same key as the request body (e.g. POST /contacts with `{"contact": {...}}` gets
    /// `{"contact": {...full record...}}` back). It's a separate parameter because at least one
    /// action endpoint breaks that symmetry: `POST /timeslips/:id/timer`'s request is
    /// conventionally wrapped as `{"timer": {}}`, but the response is the updated timeslip,
    /// wrapped as `{"timeslip": {...}}` — observed directly against the sandbox API.
    public func post<T: Decodable, Body: Encodable>(
        _ path: String, envelopeKey: String, responseEnvelopeKey: String? = nil, query: [URLQueryItem] = [], body: Body
    ) async throws -> T {
        let bodyData = try jsonEncoder.encode([envelopeKey: body])
        let data = try await authenticatedRequest(path: path, method: "POST", query: query, body: bodyData)
        return try decodeEnveloped(data, envelopeKey: responseEnvelopeKey ?? envelopeKey)
    }

    /// Same enveloping rules as `post` above (see its doc comment), but for endpoints that
    /// update an existing resource in place rather than creating a new one — FreeAgent's
    /// timeslip update is `PUT /timeslips/:id`, not a POST.
    public func put<T: Decodable, Body: Encodable>(
        _ path: String, envelopeKey: String, responseEnvelopeKey: String? = nil, query: [URLQueryItem] = [], body: Body
    ) async throws -> T {
        let bodyData = try jsonEncoder.encode([envelopeKey: body])
        let data = try await authenticatedRequest(path: path, method: "PUT", query: query, body: bodyData)
        return try decodeEnveloped(data, envelopeKey: responseEnvelopeKey ?? envelopeKey)
    }

    public func delete(_ path: String) async throws {
        _ = try await authenticatedRequest(path: path, method: "DELETE", query: [], body: Data?.none)
    }

    // MARK: - OAuth token exchange (unauthenticated)

    /// Sent to Ratchet's sign-in service rather than FreeAgent: FreeAgent wants the client
    /// credentials on every token request, and the service holds them (see
    /// `FreeAgentEnvironment.tokenURL`). The service redeemed FreeAgent's code before the callback
    /// arrived; `code` is the tokens it sealed, which it hands over only for `codeVerifier`.
    public func exchangeAuthorizationCode(_ code: String, codeVerifier: String) async throws -> FreeAgentTokens {
        try await requestTokens(
            form: "grant_type=authorization_code&code=\(urlEncoded(code))&code_verifier=\(urlEncoded(codeVerifier))"
        )
    }

    public func refreshTokens(_ refreshToken: String) async throws -> FreeAgentTokens {
        try await requestTokens(form: "grant_type=refresh_token&refresh_token=\(urlEncoded(refreshToken))")
    }

    private func requestTokens(form: String) async throws -> FreeAgentTokens {
        var request = URLRequest(url: environment.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.utf8)

        let (data, response) = try await send(request)
        try throwIfError(status: response.statusCode, data: data)
        return try decodeTokenResponse(data)
    }

    // MARK: - Private helpers

    /// Tracks an in-flight token refresh so concurrent callers share one exchange.
    ///
    /// FreeAgent rotates the refresh token on every use, so if several in-flight requests each
    /// kicked off their own `refreshTokens` call, only the first would succeed — the rest would
    /// get `invalid_grant`, and a late loser could overwrite the good tokens in the Keychain and
    /// log the user out. Every refresh now goes through `refreshTokensShared`, which starts at
    /// most one exchange at a time for each session.
    private var inFlightRefresh: (session: UInt64, task: Task<FreeAgentTokens, Error>)?

    /// Serializing point for token refresh. If an exchange is already running, awaits it instead
    /// of starting a second one. Callers pass the refresh token they *saw*; if it's stale (the
    /// shared refresh already rotated it), the freshly stored tokens are returned instead of
    /// burning the rotated token a second time.
    private func refreshTokensShared(currentRefreshToken: String) async throws -> FreeAgentTokens {
        try requireSession()
        // Joined only within its session: one an ended session left out ends in `.sessionEnded`.
        if let existing = inFlightRefresh, existing.session == session {
            return try await existing.task.value
        }
        // Another caller may have completed a refresh between our token load and now, in which
        // case the stored refresh token has already rotated away from ours — reuse theirs.
        if let stored = tokenStore.load(), stored.refreshToken != currentRefreshToken, !stored.isExpired {
            return stored
        }
        let startedIn = session
        let task = Task<FreeAgentTokens, Error> { [self] in
            let refreshed = try await refreshTokens(currentRefreshToken)
            // The session may have ended while the exchange was out, leaving no sign-in stored or
            // another account's. Not `.unauthorized`, which signs out whoever is signed in now.
            switch tokenStore.loadResult() {
            case .found(let stored) where stored.refreshToken != currentRefreshToken: throw FreeAgentError.sessionEnded
            // Cleared by a logout, which ends the session; lost any other way, which the save repairs.
            case .missing: if session != startedIn { throw FreeAgentError.sessionEnded }
            // Unreadable says nothing either way, and refusing would lose the rotated token for certain.
            case .found, .unavailable: break
            }
            // A failed persist is fatal to the session even though `refreshed` is valid right
            // now: every request reloads from the Keychain, so the next one would pick up the
            // old refresh token that FreeAgent has already rotated away and 401. Failing here
            // with an accurate message beats succeeding once and then reporting a mysterious
            // "session expired" on the following request.
            guard tokenStore.save(refreshed) else { throw FreeAgentError.credentialStorageFailed }
            return refreshed
        }
        inFlightRefresh = (startedIn, task)
        defer { if inFlightRefresh?.task == task { inFlightRefresh = nil } }
        return try await task.value
    }

    /// Refreshes an expired access token now rather than as part of the next request, so that
    /// refresh failing can't be mistaken for the request failing in flight.
    public func prepareTokens() async throws {
        _ = try await freshTokens()
    }

    private func freshTokens() async throws -> FreeAgentTokens {
        // Before the load, which finds no tokens once a logout has cleared them: `.unauthorized`
        // would read as this session expiring.
        try requireSession()
        let tokens: FreeAgentTokens
        switch tokenStore.loadResult() {
        case .found(let stored):
            tokens = stored
        case .missing:
            throw FreeAgentError.unauthorized
        case .unavailable(let status):
            // Not `.unauthorized`: that routes to handleSessionExpired(), which clears the
            // Keychain. Doing that because the Keychain was momentarily unreadable destroys the
            // very credentials this request was trying to use.
            throw FreeAgentError.credentialStoreUnavailable(status)
        }
        guard tokens.isExpired else { return tokens }
        return try await refreshTokensShared(currentRefreshToken: tokens.refreshToken)
    }

    private func authenticatedRequest(path: String, method: String, query: [URLQueryItem], body: Data?, isRetry: Bool = false) async throws -> Data {
        let tokens = try await freshTokens()

        // Thrown rather than force-unwrapped: `path` is frequently a resource URL taken verbatim
        // from a FreeAgent response body (see FreeAgentDTOs), so a single malformed value in an
        // API response would otherwise take down the whole menu-bar app instead of surfacing a
        // recoverable error.
        var url: URL
        if path.hasPrefix("http") {
            guard let parsed = URL(string: path) else { throw FreeAgentError.invalidURL(path) }
            url = parsed
        } else {
            url = environment.apiBaseURL.appendingPathComponent(path)
        }
        if !query.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw FreeAgentError.invalidURL(url.absoluteString)
            }
            components.queryItems = query
            guard let queried = components.url else { throw FreeAgentError.invalidURL(url.absoluteString) }
            url = queried
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // A token refresh above may have outlasted the session.
        try requireSession()
        let (data, response) = try await send(request)

        if response.statusCode == 401 && !isRetry {
            _ = try await refreshTokensShared(currentRefreshToken: tokens.refreshToken)
            return try await authenticatedRequest(path: path, method: method, query: query, body: body, isRetry: true)
        }
        try throwIfError(status: response.statusCode, data: data)
        return data
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as FreeAgentError {
            throw error
        } catch {
            throw FreeAgentError.network(error)
        }
    }

    private func throwIfError(status: Int, data: Data) throws {
        guard status >= 400 else { return }
        if status == 401 { throw FreeAgentError.unauthorized }
        throw FreeAgentError.apiError(status: status, message: Self.errorMessage(from: data))
    }

    /// Best-effort extraction of a human-readable reason from an error body. FreeAgent isn't
    /// consistent: the OAuth token endpoint returns a flat `{"error": "..."}`, while API
    /// validation failures (the 422s the create-client/project/task forms hit) nest the message
    /// under `errors`. Both shapes are tried, plus a bare top-level `message`; anything
    /// unrecognised yields nil so the caller falls back to "status NNN".
    nonisolated private static func errorMessage(from data: Data) -> String? {
        /// `{"errors": {"error": {"message": "..."}}}` — the nested validation-error shape.
        struct NestedErrors: Decodable {
            struct Errors: Decodable {
                struct Detail: Decodable { let message: String }
                let error: Detail
            }
            let errors: Errors
        }
        /// `{"errors": [{"message": "..."}, ...]}` — the multi-error variant.
        struct NestedErrorList: Decodable {
            struct Detail: Decodable { let message: String }
            let errors: [Detail]
        }
        /// `{"error": "..."}` (OAuth) or `{"message": "..."}` (occasional plain shape).
        struct Flat: Decodable {
            let error: String?
            let message: String?
            let errorDescription: String?

            enum CodingKeys: String, CodingKey {
                case error, message
                case errorDescription = "error_description"
            }
        }

        let decoder = JSONDecoder()
        if let nested = try? decoder.decode(NestedErrors.self, from: data) {
            return nested.errors.error.message
        }
        if let list = try? decoder.decode(NestedErrorList.self, from: data), !list.errors.isEmpty {
            return list.errors.map(\.message).joined(separator: "\n")
        }
        if let flat = try? decoder.decode(Flat.self, from: data) {
            // `error_description` is the more descriptive half of an OAuth error pair.
            if let description = flat.errorDescription, let error = flat.error {
                return "\(error): \(description)"
            }
            return flat.errorDescription ?? flat.error ?? flat.message
        }
        return nil
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try decode(data, as: T.self)
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try jsonDecoder.decode(type, from: data)
        } catch {
            throw FreeAgentError.decoding(error)
        }
    }

    /// Unwraps a single-resource envelope, e.g. `{"contact": {...}}` -> the contact.
    private func decodeEnveloped<T: Decodable>(_ data: Data, envelopeKey: String) throws -> T {
        let envelope: [String: T] = try decode(data, as: [String: T].self)
        guard let value = envelope[envelopeKey] else {
            throw FreeAgentError.decoding(MissingEnvelopeKey(envelopeKey: envelopeKey))
        }
        return value
    }

    private func decodeTokenResponse(_ data: Data) throws -> FreeAgentTokens {
        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String
            let expiresIn: Double

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        let response = try decode(data, as: TokenResponse.self)
        return FreeAgentTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date(timeIntervalSinceNow: response.expiresIn)
        )
    }

    private func urlEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+")
        return set
    }()
}
