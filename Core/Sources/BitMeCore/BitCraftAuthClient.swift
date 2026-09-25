import Foundation

/// Errors from the BitCraft account API (api.bitcraftonline.com).
public enum BitCraftAuthError: Error, Equatable, Sendable {
    /// 400 — the API rejected a parameter (bad email, bad/expired code).
    case badRequest(String)
    /// 200 with a body that is not what the wire capture showed
    /// (`authenticate` must return a bare JSON string).
    case invalidResponse
    case httpStatus(Int)
}

/// Async client for the BitCraft account API. Shapes are taken verbatim from
/// the 2026-09-25 tap capture (docs/protocol/session-2026-09-25-tap-analysis.md):
/// parameters travel in the query string, bodies are empty, and
/// `authenticate` answers with the SpacetimeDB JWT as a bare JSON string.
struct BitCraftAuthClient: Sendable {
    let baseURL: URL
    private let urlSession: URLSession

    static let production = BitCraftAuthClient(
        baseURL: URL(string: "https://api.bitcraftonline.com")!
    )

    init(baseURL: URL, urlSession: URLSession? = nil) {
        self.baseURL = baseURL
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            self.urlSession = URLSession(configuration: config)
        }
    }

    // MARK: - POST /authentication/request-access-code?email=

    /// Emails a short access code to the account. Empty 200 on success.
    func requestAccessCode(email: String) async throws {
        let url = try url(path: "/authentication/request-access-code", query: [
            ("email", email),
        ])
        let (data, http) = try await post(url)
        try check(http: http, body: data)
    }

    // MARK: - POST /authentication/authenticate?email=&accessCode=

    /// Exchanges the emailed code for the account's SpacetimeDB token.
    /// The token does not expire (`exp: null`) and authorizes the game
    /// WebSockets as a Bearer credential.
    func authenticate(email: String, code: String) async throws -> String {
        let url = try url(path: "/authentication/authenticate", query: [
            ("email", email),
            ("accessCode", code),
        ])
        let (data, http) = try await post(url)
        try check(http: http, body: data)
        guard let token = try? JSONDecoder().decode(String.self, from: data), !token.isEmpty else {
            throw BitCraftAuthError.invalidResponse
        }
        return token
    }

    // MARK: - GET /global-module/get-connection-info

    /// Unauthenticated: where the game's global database lives
    /// (`{"uri": "https://…spacetimedb.com", "name": "bitcraft-live-global"}`).
    func connectionInfo() async throws -> BitCraftConnectionInfo {
        let url = try url(path: "/global-module/get-connection-info", query: [])
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw BitCraftAuthError.httpStatus(-1)
        }
        try check(http: http, body: data)
        do {
            return try JSONDecoder().decode(BitCraftConnectionInfo.self, from: data)
        } catch {
            throw BitCraftAuthError.invalidResponse
        }
    }

    // MARK: - Plumbing

    private func url(path: String, query: [(String, String)]) throws -> URL {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        ) else {
            throw BitCraftAuthError.badRequest("bad base URL")
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else {
            throw BitCraftAuthError.badRequest("bad request URL")
        }
        return url
    }

    private func post(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BitCraftAuthError.httpStatus(-1)
        }
        return (data, http)
    }

    private func check(http: HTTPURLResponse, body: Data) throws {
        switch http.statusCode {
        case 200:
            return
        case 400...499:
            throw BitCraftAuthError.badRequest(Self.errorMessage(from: body, status: http.statusCode))
        case let status:
            throw BitCraftAuthError.httpStatus(status)
        }
    }

    /// Extracts a human-readable message from the API's error bodies, whose
    /// shapes vary by endpoint (observed on the wire): RFC 7807 problem+json
    /// (`{"detail":…}` — the 401 "Access code is invalid"), `{"error":…}`
    /// JSON, and bare quoted strings (the 409 Steam-link conflict).
    private static func errorMessage(from body: Data, status: Int) -> String {
        struct Problem: Decodable { let detail: String? }
        struct ErrorBody: Decodable { let error: String? }
        if let problem = try? JSONDecoder().decode(Problem.self, from: body), let detail = problem.detail {
            return detail
        }
        if let errorBody = try? JSONDecoder().decode(ErrorBody.self, from: body), let error = errorBody.error {
            return error
        }
        if let bare = try? JSONDecoder().decode(String.self, from: body), !bare.isEmpty {
            return bare
        }
        return "request rejected (HTTP \(status))"
    }
}

/// `GET /global-module/get-connection-info` — the global database address the
/// official client connects to after login.
public struct BitCraftConnectionInfo: Decodable, Equatable, Sendable {
    public let uri: String
    public let name: String
}

/// A signed-in BitCraft account: the emailed-code login's SpacetimeDB token
/// plus the JWT claims worth showing (identity, issued-at). The token never
/// expires; treat it as a long-lived credential (Keychain storage).
public struct BitCraftAccount: Codable, Equatable, Sendable {
    public let email: String
    public let token: String
    /// `hex_identity` claim — the player's SpacetimeDB identity, used in
    /// per-identity subscription queries.
    public let identityHex: String?
    /// `sub` claim (account UUID).
    public let subject: String?
    /// `iat` claim.
    public let issuedAt: Date?

    public init(email: String, token: String) {
        self.email = email
        self.token = token
        let claims = BitCraftAccount.decodeClaims(token: token)
        self.identityHex = claims?.hexIdentity
        self.subject = claims?.sub
        self.issuedAt = claims?.iat.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Locally decodes the JWT payload (no signature verification — the token
    /// is only ever presented to BitCraft's servers, which verify it).
    private static func decodeClaims(token: String) -> (hexIdentity: String?, sub: String?, iat: Int64?)? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let payload = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        let hex = json["hex_identity"] as? String
        let sub = json["sub"] as? String
        let iat = (json["iat"] as? NSNumber)?.int64Value
        return (hex, sub, iat)
    }
}
