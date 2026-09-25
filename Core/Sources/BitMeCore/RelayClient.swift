import Foundation

enum RelayError: Error, Equatable, Sendable {
    /// 404 — resolve miss, or the player is not present in any mirrored
    /// region right now (deploy reseed window / region coverage).
    case notFound
    /// 400 — malformed request parameter.
    case badRequest(String)
    /// 202 — the region is still seeding; retry later (30 s guidance).
    case seeding
    case httpStatus(Int)
}

/// Thin async client for the relay Bit-Me API (docs/api.md). Plain HTTPS +
/// JSON + the binary resource-map formats; no auth, no SpacetimeDB protocol.
/// The one WebSocket surface (the change stream) lives in
/// `ResourceStreamClient`.
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

    // MARK: - Resource map (docs/api.md §6)

    /// BMR1 window around the player (session-anchored, 400×400). The
    /// session's own GET registration is what the window tracks — keep the
    /// 1 Hz session poll running alongside. Throws `.seeding` on 202.
    func sessionResources(entityID: String) async throws -> ResourceWindow {
        let url = baseURL.appendingPathComponent("bitme/session/\(entityID)/resources")
        return try ResourceWindow(data: await binary(for: url))
    }

    /// BMR1 window anchored at a world tile (the anchor is the window's
    /// center; origin = anchor − width/2). 404 outside the covered regions.
    func worldResources(centerX: Int, centerZ: Int) async throws -> ResourceWindow {
        let url = baseURL.appendingPathComponent("bitme/world/\(centerX)/\(centerZ)/resources")
        return try ResourceWindow(data: await binary(for: url))
    }

    /// BME1 super-hex terrain plane centered near a world tile. Terrain
    /// rarely changes — cache aggressively (10 min guidance).
    func worldElevation(centerX: Int, centerZ: Int) async throws -> TerrainPlane {
        let url = baseURL.appendingPathComponent("bitme/world/\(centerX)/\(centerZ)/elevation")
        return try TerrainPlane(data: await binary(for: url))
    }

    /// Dictionary for the tile-word indices of a region's windows/deltas.
    func resourceDictionary(regionID: Int) async throws -> ResourceDictionary {
        let url = baseURL.appendingPathComponent("bitme/region/\(regionID)/resource-dictionary")
        let payload = try await data(for: url)
        let (bytes, http) = payload
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(ResourceDictionary.self, from: bytes)
        case 202:
            throw RelayError.seeding
        default:
            throw mapError(status: http.statusCode, body: bytes)
        }
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
            throw RelayError.badRequest(Self.errorBody(from: data))
        case 404:
            throw RelayError.notFound
        case 202:
            throw RelayError.seeding
        case let status:
            throw RelayError.httpStatus(status)
        }
    }

    /// Binary variant of `decode`: 200 passes raw bytes through, 202 means
    /// the region is seeding.
    private func binary(for url: URL) async throws -> Data {
        let (data, http) = try await data(for: url)
        switch http.statusCode {
        case 200:
            return data
        case 202:
            throw RelayError.seeding
        default:
            throw mapError(status: http.statusCode, body: data)
        }
    }

    private func mapError(status: Int, body: Data) -> RelayError {
        switch status {
        case 400: return .badRequest(Self.errorBody(from: body))
        case 404: return .notFound
        default: return .httpStatus(status)
        }
    }

    private static func errorBody(from data: Data) -> String {
        (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "bad request"
    }

    private struct ErrorBody: Decodable, Sendable {
        let error: String
    }
}
