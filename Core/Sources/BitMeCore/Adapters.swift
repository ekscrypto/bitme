import Foundation

/// System boundaries as closures (fenex-light ADR-005) — tests substitute
/// scripted doubles; production wires the real relay client and file paths.
public struct Adapters: Sendable {
    public struct Relay: Sendable {
        /// Exact-match, lowercase resolve. Throws `RelayError.notFound` on miss.
        public let resolve: @Sendable (_ name: String) async throws -> ResolveResponse
        /// One session snapshot; GET is also the server-side tracker registration.
        public let session: @Sendable (_ entityID: String) async throws -> SessionSnapshot

        public init(
            resolve: @escaping @Sendable (String) async throws -> ResolveResponse,
            session: @escaping @Sendable (String) async throws -> SessionSnapshot
        ) {
            self.resolve = resolve
            self.session = session
        }
    }

    public let relay: Relay
    /// Food-buff gamedata over the mirror WebSocket, 48 h cached. Failing
    /// adapters return the stale cache (or nil) instead of throwing.
    public let loadFoodBuffGamedata: @Sendable () async -> FoodBuffGamedata?
    /// Identity persistence (nil deletes). Called on the serial actor after
    /// every persistent mutation.
    public let restoreIdentity: @Sendable () async -> StoredIdentity?
    public let persistIdentity: @Sendable (StoredIdentity?) async -> Void
    /// The session loop's inter-poll wait. Production sleeps; tests pass an
    /// instant no-op so flows run deterministically.
    public let sleep: @Sendable (_ seconds: Double) async throws -> Void

    public init(
        relay: Relay,
        loadFoodBuffGamedata: @escaping @Sendable () async -> FoodBuffGamedata?,
        restoreIdentity: @escaping @Sendable () async -> StoredIdentity?,
        persistIdentity: @escaping @Sendable (StoredIdentity?) async -> Void,
        sleep: @escaping @Sendable (Double) async throws -> Void
    ) {
        self.relay = relay
        self.loadFoodBuffGamedata = loadFoodBuffGamedata
        self.restoreIdentity = restoreIdentity
        self.persistIdentity = persistIdentity
        self.sleep = sleep
    }

    /// Real relay + on-disk persistence + real waiting.
    public static func production() -> Adapters {
        Adapters(
            relay: Relay(
                resolve: { name in try await RelayClient.production.resolve(name: name) },
                session: { entityID in try await RelayClient.production.session(entityID: entityID) }
            ),
            loadFoodBuffGamedata: { await GamedataService.loadFoodBuffGamedata() },
            restoreIdentity: { Self.restoreIdentity() },
            persistIdentity: { Self.persistIdentity($0) },
            sleep: { seconds in try await Task.sleep(for: .seconds(seconds)) }
        )
    }

    // MARK: - Identity file (Application Support/BitMe/identity.json)

    private static let identityFileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("BitMe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("identity.json")
    }()

    private static func restoreIdentity() -> StoredIdentity? {
        guard let data = try? Data(contentsOf: identityFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoredIdentity.self, from: data)
    }

    private static func persistIdentity(_ identity: StoredIdentity?) {
        guard let identity else {
            try? FileManager.default.removeItem(at: identityFileURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(identity) else { return }
        try? data.write(to: identityFileURL, options: .atomic)
    }
}
