import Foundation

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

public final class FreeAgentAPIClient {
    private let environment: FreeAgentEnvironment
    private let tokenStore: KeychainTokenStore
    private let transport: FreeAgentTransport
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder

    public init(environment: FreeAgentEnvironment, tokenStore: KeychainTokenStore, transport: FreeAgentTransport = URLSessionTransport()) {
        self.environment = environment
        self.tokenStore = tokenStore
        self.transport = transport
        self.jsonDecoder = JSONDecoder()
        self.jsonDecoder.dateDecodingStrategy = .iso8601
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Authenticated requests

    public func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await authenticatedRequest(path: path, method: "GET", query: query, body: Data?.none)
        return try decode(data)
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
            let items = envelope[listKey] ?? []
            all.append(contentsOf: items)
            if items.count < perPage { break }
            page += 1
        }
        return all
    }

    public func post<T: Decodable, Body: Encodable>(_ path: String, envelopeKey: String, query: [URLQueryItem] = [], body: Body) async throws -> T {
        let bodyData = try jsonEncoder.encode([envelopeKey: body])
        let data = try await authenticatedRequest(path: path, method: "POST", query: query, body: bodyData)
        return try decode(data)
    }

    public func delete(_ path: String) async throws {
        _ = try await authenticatedRequest(path: path, method: "DELETE", query: [], body: Data?.none)
    }

    // MARK: - OAuth token exchange (unauthenticated)

    public func exchangeAuthorizationCode(_ code: String, redirectURI: String) async throws -> FreeAgentTokens {
        var request = URLRequest(url: environment.tokenURL)
        request.httpMethod = "POST"
        let credentials = "\(FreeAgentSecrets.clientID):\(FreeAgentSecrets.clientSecret)"
        let encodedCredentials = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encodedCredentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "grant_type=authorization_code&code=\(urlEncoded(code))&redirect_uri=\(urlEncoded(redirectURI))"
        request.httpBody = Data(form.utf8)

        let (data, response) = try await send(request)
        try throwIfError(status: response.statusCode, data: data)
        return try decodeTokenResponse(data)
    }

    public func refreshTokens(_ refreshToken: String) async throws -> FreeAgentTokens {
        var request = URLRequest(url: environment.tokenURL)
        request.httpMethod = "POST"
        let credentials = "\(FreeAgentSecrets.clientID):\(FreeAgentSecrets.clientSecret)"
        let encodedCredentials = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encodedCredentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "grant_type=refresh_token&refresh_token=\(urlEncoded(refreshToken))"
        request.httpBody = Data(form.utf8)

        let (data, response) = try await send(request)
        try throwIfError(status: response.statusCode, data: data)
        return try decodeTokenResponse(data)
    }

    // MARK: - Private helpers

    private func authenticatedRequest(path: String, method: String, query: [URLQueryItem], body: Data?, isRetry: Bool = false) async throws -> Data {
        guard var tokens = tokenStore.load() else { throw FreeAgentError.unauthorized }
        if tokens.isExpired {
            tokens = try await refreshTokens(tokens.refreshToken)
            tokenStore.save(tokens)
        }

        var url = path.hasPrefix("http") ? URL(string: path)! : environment.apiBaseURL.appendingPathComponent(path)
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = query
            url = components.url!
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await send(request)

        if response.statusCode == 401 && !isRetry {
            let refreshed = try await refreshTokens(tokens.refreshToken)
            tokenStore.save(refreshed)
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
        let message = (try? decode(data, as: [String: String].self))?["error"]
        throw FreeAgentError.apiError(status: status, message: message)
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
