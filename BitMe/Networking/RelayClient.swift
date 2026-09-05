import Foundation

enum RelayError: Error, Equatable, Sendable {
    /// 404 — resolve miss, or the player is not present in any mirrored
    /// region right now (deploy reseed window / region coverage).
    case notFound
    /// 400 — malformed request parameter.
    case badRequest(String)
    case httpStatus(Int)
}

/// Thin async client for the relay Bit-Me API (docs/api.md). Plain HTTPS +
/// JSON; no auth, no websockets, no SpacetimeDB protocol.
struct RelayClient: Sendable {
    let baseURL: URL
    private let urlSession: URLSession

    static let production = RelayClient(
        baseURL: URL(string: "https://relay.bitcraftsync.app")!
    )

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - GET /bitme/resolve?name=

    /// Exact-match lowercase lookup. Throws `RelayError.notFound` on 404 —
    /// "no character with that exact name", not a search endpoint.
    func resolve(name: String) async throws -> ResolveResponse {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("bitme/resolve"),
                                             resolvingAgainstBaseURL: false) else {
            throw RelayError.badRequest("bad base URL")
        }
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else {
            throw RelayError.badRequest("bad name")
        }
        let payload = try await data(for: url)
        return try decode(ResolveResponse.self, from: payload)
    }

    // MARK: - GET /bitme/session/:entity_id

    /// One snapshot with everything the activity screens render. The GET is
    /// itself the session registration (15 min TTL) — poll at ~1 Hz.
    func session(entityID: String) async throws -> SessionSnapshot {
        let url = baseURL.appendingPathComponent("bitme/session/\(entityID)")
        let payload = try await data(for: url)
        return try decode(SessionSnapshot.self, from: payload)
    }

    // MARK: - GET /cache-health

    /// `false` (or a thrown error) ⇒ mirror is reseeding/degraded; treat all
    /// relay data as stale.
    func cacheReady() async -> Bool {
        let url = baseURL.appendingPathComponent("cache-health")
        guard let (data, _) = try? await urlSession.data(from: url),
              let health = try? JSONDecoder().decode(CacheHealth.self, from: data) else {
            return false
        }
        return health.ready
    }

    // MARK: - Plumbing

    private func data(for url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw RelayError.httpStatus(-1)
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: (Data, HTTPURLResponse)) throws -> T {
        let (data, http) = payload
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(T.self, from: data)
        case 400:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw RelayError.badRequest(message ?? "bad request")
        case 404:
            throw RelayError.notFound
        case let status:
            throw RelayError.httpStatus(status)
        }
    }

    private struct ErrorBody: Decodable, Sendable {
        let error: String
    }
}
