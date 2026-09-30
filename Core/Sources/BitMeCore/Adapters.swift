import Foundation

/// System boundaries as closures (fenex-light ADR-005) — tests substitute
/// scripted doubles; production wires the real relay client and file paths.
public struct Adapters: Sendable {
    public struct Relay: Sendable {
        /// Exact-match, lowercase resolve. Throws `RelayError.notFound` on miss.
        public let resolve: @Sendable (_ name: String) async throws -> ResolveResponse
        /// One session snapshot; GET is also the server-side tracker registration.
        public let session: @Sendable (_ entityID: String) async throws -> SessionSnapshot
        /// BMR1 resource window around the player (session-anchored).
        /// Throws `RelayError.seeding` on 202, `.notFound` on 404.
        public let sessionResources: @Sendable (_ entityID: String) async throws -> ResourceWindow
        /// Region resource dictionary (tile-word indices → resource identity).
        public let resourceDictionary: @Sendable (_ regionID: Int) async throws -> ResourceDictionary
        /// BME1 terrain plane centered near a world tile (map background).
        public let worldElevation: @Sendable (_ centerX: Int, _ centerZ: Int) async throws -> TerrainPlane
        /// One change-stream connection. The returned stream ends when the
        /// socket closes; reconnection is the caller's policy.
        public let openResourceStream: @Sendable (_ entityID: String) -> AsyncStream<ResourceStreamEvent>
        /// Login/session timestamps (roads-side `/player/:id`). Consumed by
        /// the game-session pre-flight to decide whether the global leg is
        /// still worth attempting. Defaults to "no answer" so hosts and
        /// tests that never exercise the path stay silent.
        public let playerStatus: @Sendable (_ entityID: String) async throws -> PlayerStatus

        public init(
            resolve: @escaping @Sendable (String) async throws -> ResolveResponse,
            session: @escaping @Sendable (String) async throws -> SessionSnapshot,
            sessionResources: @escaping @Sendable (String) async throws -> ResourceWindow,
            resourceDictionary: @escaping @Sendable (Int) async throws -> ResourceDictionary,
            worldElevation: @escaping @Sendable (Int, Int) async throws -> TerrainPlane,
            openResourceStream: @escaping @Sendable (String) -> AsyncStream<ResourceStreamEvent>,
            playerStatus: (@Sendable (String) async throws -> PlayerStatus)? = nil
        ) {
            self.resolve = resolve
            self.session = session
            self.sessionResources = sessionResources
            self.resourceDictionary = resourceDictionary
            self.worldElevation = worldElevation
            self.openResourceStream = openResourceStream
            // The "no answer" default is built in the body — a public
            // default argument may only reference public declarations.
            self.playerStatus = playerStatus ?? { _ in throw RelayError.notFound }
        }
    }

    public let relay: Relay

    /// BitCraft account API (api.bitcraftonline.com): the emailed-code login.
    public struct BitCraft: Sendable {
        /// Emails an access code. Empty 200 on success.
        public let requestAccessCode: @Sendable (_ email: String) async throws -> Void
        /// Exchanges the code for the account's SpacetimeDB token.
        public let authenticate: @Sendable (_ email: String, _ code: String) async throws -> String
        /// Resolves a signed-in account (token + identity) to its player over
        /// the game's global database.
        public let resolveAccountPlayer: @Sendable (_ token: String, _ identityHex: String) async throws -> AccountPlayer
        /// One game-session connection set: signs the account in
        /// (`CallReducer sign_in`) on the account's region shard — the
        /// load-bearing leg the claim-buildings sync rides — and then, best
        /// effort, on the global database. The region leg is the session:
        /// its failure fails the attempt, while the global leg (presence,
        /// 1 h admission window) failing or dropping only degrades it.
        /// `skipGlobal` (set by the pre-flight when the last login is
        /// older than the window) never opens the global leg at all.
        /// `identityHex` (the token's `hex_identity` claim) arms the
        /// region leg's queue join (`player_queue_join` → own-row
        /// `user_state.can_sign_in` → `sign_in`). The returned stream ends
        /// when a load-bearing leg ends; reconnection is the caller's
        /// policy (`Activity.GameSessionLoop`).
        public let openGlobalSession: @Sendable (_ token: String, _ entityID: String, _ regionID: Int?, _ skipGlobal: Bool, _ identityHex: String?) -> AsyncStream<GlobalSessionEvent>
        /// Live claim-buildings sync over the game session's region leg
        /// (docs/protocol/region-claim-buildings.md): static catalogs via
        /// one-off queries, then subscriptions for the claim's buildings,
        /// the claim header, nicknames, and the scoped craft tables. Row
        /// events arrive coalesced — one array per ~0.5 s pool, one intent
        /// per array. The returned stream ends when the leg closes or the
        /// sync fails — a terminal `.failed` event always precedes a sync
        /// failure's end.
        public let syncClaimBuildings: @Sendable (_ leg: RegionLeg, _ claimEntityID: UInt64, _ playerEntityID: UInt64) -> AsyncStream<[ClaimBuildingsEvent]>
        /// Claim-resolution fallback (protocol doc §2): one-off
        /// `claim_member_state WHERE player_entity_id = <own>` on the
        /// region leg, for sign-ins where the relay never answers the
        /// claim. Nil = no answer. Defaults to "no fallback" so hosts and
        /// tests that never exercise the path stay silent.
        public let resolveOwnClaimMembership: @Sendable (_ leg: RegionLeg, _ playerEntityID: UInt64) async -> UInt64?
        /// Live player-vitals sync over the game session's region leg
        /// (`RegionVitalsClient`): the own-row subscription set (pools,
        /// stats, action record, position). The returned stream ends when
        /// the leg closes or the setup fails — a terminal `.failed` event
        /// always precedes a setup failure's end. Defaults to "no vitals"
        /// so hosts and tests that never exercise the path stay silent.
        public let syncPlayerVitals: @Sendable (_ leg: RegionLeg, _ playerEntityID: UInt64) -> AsyncStream<PlayerVitalsEvent>
        /// Prospection watch (`RegionProspectClient`): the tracked player's
        /// own `prospecting_state` row, read anonymously off the region
        /// mirror (name-driven hosts hold no game session, so the mirror is
        /// their only region window). Ends on watch failure; `.ended`
        /// events mark a finished/abandoned trail or a lost connection.
        /// Defaults to "no prospection" so hosts and tests stay silent.
        public let syncProspection: @Sendable (_ playerEntityID: UInt64, _ region: Int) -> AsyncStream<ProspectionEvent>
        /// Craft-driver reducer calls (`RegionDriverClient`): each returns
        /// the receipt's own-action row effects, or throws the game's
        /// refusal text. Defaults refuse everything, so hosts and tests
        /// that never drive stay silent.
        public let craftContinueStart: @Sendable (_ leg: RegionLeg, _ progressiveActionEntityID: UInt64, _ timestampMs: UInt64) async throws -> DriverReceipt
        public let craftContinue: @Sendable (_ leg: RegionLeg, _ progressiveActionEntityID: UInt64, _ timestampMs: UInt64) async throws -> DriverReceipt
        public let craftCancel: @Sendable (_ leg: RegionLeg, _ pocketID: UInt64) async throws -> DriverReceipt
        public let playerActionCancel: @Sendable (_ leg: RegionLeg) async throws -> DriverReceipt
        public let movePlayer: @Sendable (_ leg: RegionLeg, _ timestampMs: UInt64, _ destinationX: Int32, _ destinationZ: Int32, _ dimension: UInt32, _ originX: Int32?, _ originZ: Int32?, _ durationSeconds: Float, _ moveType: Int32) async throws -> DriverReceipt
        /// One-off station location (`location_state` PK equality).
        public let stationLocation: @Sendable (_ leg: RegionLeg, _ buildingEntityID: UInt64) async throws -> LocationRow?
        /// One-off own-position read (`mobile_entity_state` PK equality).
        public let ownPosition: @Sendable (_ leg: RegionLeg, _ playerEntityID: UInt64) async throws -> MobileEntityRow?

        public init(
            requestAccessCode: @escaping @Sendable (String) async throws -> Void,
            authenticate: @escaping @Sendable (String, String) async throws -> String,
            resolveAccountPlayer: @escaping @Sendable (String, String) async throws -> AccountPlayer,
            openGlobalSession: @escaping @Sendable (String, String, Int?, Bool, String?) -> AsyncStream<GlobalSessionEvent>,
            syncClaimBuildings: @escaping @Sendable (RegionLeg, UInt64, UInt64) -> AsyncStream<[ClaimBuildingsEvent]>,
            resolveOwnClaimMembership: @escaping @Sendable (RegionLeg, UInt64) async -> UInt64? = { _, _ in nil },
            syncPlayerVitals: @escaping @Sendable (RegionLeg, UInt64) -> AsyncStream<PlayerVitalsEvent> = { _, _ in AsyncStream { $0.finish() } },
            syncProspection: @escaping @Sendable (UInt64, Int) -> AsyncStream<ProspectionEvent> = { _, _ in AsyncStream { $0.finish() } },
            craftContinueStart: @escaping @Sendable (RegionLeg, UInt64, UInt64) async throws -> DriverReceipt = { _, _, _ in
                throw DriverUnavailableError()
            },
            craftContinue: @escaping @Sendable (RegionLeg, UInt64, UInt64) async throws -> DriverReceipt = { _, _, _ in
                throw DriverUnavailableError()
            },
            craftCancel: @escaping @Sendable (RegionLeg, UInt64) async throws -> DriverReceipt = { _, _ in
                throw DriverUnavailableError()
            },
            playerActionCancel: @escaping @Sendable (RegionLeg) async throws -> DriverReceipt = { _ in
                throw DriverUnavailableError()
            },
            movePlayer: @escaping @Sendable (RegionLeg, UInt64, Int32, Int32, UInt32, Int32?, Int32?, Float, Int32) async throws -> DriverReceipt = { _, _, _, _, _, _, _, _, _ in
                throw DriverUnavailableError()
            },
            stationLocation: @escaping @Sendable (RegionLeg, UInt64) async throws -> LocationRow? = { _, _ in nil },
            ownPosition: @escaping @Sendable (RegionLeg, UInt64) async throws -> MobileEntityRow? = { _, _ in nil }
        ) {
            self.requestAccessCode = requestAccessCode
            self.authenticate = authenticate
            self.resolveAccountPlayer = resolveAccountPlayer
            self.openGlobalSession = openGlobalSession
            self.syncClaimBuildings = syncClaimBuildings
            self.resolveOwnClaimMembership = resolveOwnClaimMembership
            self.syncPlayerVitals = syncPlayerVitals
            self.syncProspection = syncProspection
            self.craftContinueStart = craftContinueStart
            self.craftContinue = craftContinue
            self.craftCancel = craftCancel
            self.playerActionCancel = playerActionCancel
            self.movePlayer = movePlayer
            self.stationLocation = stationLocation
            self.ownPosition = ownPosition
        }
    }

    public let bitCraft: BitCraft
    /// Food-buff gamedata over the mirror WebSocket, 48 h cached. Failing
    /// adapters return the stale cache (or nil) instead of throwing.
    public let loadFoodBuffGamedata: @Sendable () async -> FoodBuffGamedata?
    /// Identity persistence (nil deletes). Called on the serial actor after
    /// every persistent mutation.
    public let restoreIdentity: @Sendable () async -> StoredIdentity?
    public let persistIdentity: @Sendable (StoredIdentity?) async -> Void
    /// BitCraft account persistence (nil deletes) — Keychain in production.
    public let restoreBitCraftAccount: @Sendable () async -> BitCraftAccount?
    public let persistBitCraftAccount: @Sendable (BitCraftAccount?) async -> Void
    /// The session loop's inter-poll wait. Production sleeps; tests pass an
    /// instant no-op so flows run deterministically.
    public let sleep: @Sendable (_ seconds: Double) async throws -> Void

    public init(
        relay: Relay,
        bitCraft: BitCraft,
        loadFoodBuffGamedata: @escaping @Sendable () async -> FoodBuffGamedata?,
        restoreIdentity: @escaping @Sendable () async -> StoredIdentity?,
        persistIdentity: @escaping @Sendable (StoredIdentity?) async -> Void,
        restoreBitCraftAccount: @escaping @Sendable () async -> BitCraftAccount?,
        persistBitCraftAccount: @escaping @Sendable (BitCraftAccount?) async -> Void,
        sleep: @escaping @Sendable (Double) async throws -> Void
    ) {
        self.relay = relay
        self.bitCraft = bitCraft
        self.loadFoodBuffGamedata = loadFoodBuffGamedata
        self.restoreIdentity = restoreIdentity
        self.persistIdentity = persistIdentity
        self.restoreBitCraftAccount = restoreBitCraftAccount
        self.persistBitCraftAccount = persistBitCraftAccount
        self.sleep = sleep
    }

    /// Real relay + on-disk persistence + real waiting.
    public static func production() -> Adapters {
        let relay = RelayClient.production
        let auth = BitCraftAuthClient.production
        return Adapters(
            relay: Relay(
                resolve: { name in try await relay.resolve(name: name) },
                session: { entityID in try await relay.session(entityID: entityID) },
                sessionResources: { entityID in try await relay.sessionResources(entityID: entityID) },
                resourceDictionary: { regionID in try await relay.resourceDictionary(regionID: regionID) },
                worldElevation: { centerX, centerZ in
                    try await relay.worldElevation(centerX: centerX, centerZ: centerZ)
                },
                openResourceStream: { entityID in
                    ResourceStreamClient.production.events(entityID: entityID)
                },
                playerStatus: { entityID in
                    try await relay.playerStatus(entityID: entityID)
                }
            ),
            bitCraft: BitCraft(
                requestAccessCode: { email in try await auth.requestAccessCode(email: email) },
                authenticate: { email, code in try await auth.authenticate(email: email, code: code) },
                resolveAccountPlayer: { token, identityHex in
                    try await GlobalPlayerResolver.resolve(token: token, identityHex: identityHex)
                },
                openGlobalSession: { token, entityID, regionID, skipGlobal, identityHex in
                    guard let entity = UInt64(entityID) else {
                        coreLog.error("game session: malformed entity id \(entityID, privacy: .public)")
                        return AsyncStream { $0.finish() }
                    }
                    return GlobalSessionClient.events(
                        token: token, entityID: entity, regionID: regionID,
                        skipGlobal: skipGlobal, identityHex: identityHex
                    )
                },
                syncClaimBuildings: { leg, claim, player in
                    RegionBuildingsClient.events(leg: leg, claim: claim, player: player)
                },
                resolveOwnClaimMembership: { leg, player in
                    await RegionBuildingsClient.resolveOwnClaim(client: leg.client, player: player)
                },
                syncPlayerVitals: { leg, player in
                    RegionVitalsClient.events(leg: leg, player: player)
                },
                syncProspection: { player, region in
                    RegionProspectClient.events(entityID: player, region: region)
                },
                craftContinueStart: { leg, entity, timestampMs in
                    try await RegionDriverClient.craftContinueStart(
                        client: leg.client,
                        progressiveActionEntityID: entity, timestampMs: timestampMs
                    )
                },
                craftContinue: { leg, entity, timestampMs in
                    try await RegionDriverClient.craftContinue(
                        client: leg.client,
                        progressiveActionEntityID: entity, timestampMs: timestampMs
                    )
                },
                craftCancel: { leg, pocketID in
                    try await RegionDriverClient.craftCancel(client: leg.client, pocketID: pocketID)
                },
                playerActionCancel: { leg in
                    try await RegionDriverClient.playerActionCancel(client: leg.client)
                },
                movePlayer: { leg, timestampMs, destinationX, destinationZ, dimension, originX, originZ, durationSeconds, moveType in
                    try await RegionDriverClient.playerMove(
                        client: leg.client,
                        timestampMs: timestampMs,
                        destinationX: destinationX, destinationZ: destinationZ, dimension: dimension,
                        originX: originX, originZ: originZ,
                        durationSeconds: durationSeconds, moveType: moveType
                    )
                },
                stationLocation: { leg, building in
                    try await RegionDriverClient.stationLocation(client: leg.client, building: building)
                },
                ownPosition: { leg, player in
                    try await RegionDriverClient.ownPosition(client: leg.client, player: player)
                }
            ),
            loadFoodBuffGamedata: { await GamedataService.loadFoodBuffGamedata() },
            restoreIdentity: { Self.restoreIdentity() },
            persistIdentity: { Self.persistIdentity($0) },
            restoreBitCraftAccount: {
                if let account = BitCraftTokenStore.load() {
                    authLog.info("restored BitCraft account \(account.email, privacy: .private) from Keychain")
                    return account
                }
                authLog.info("no stored BitCraft account")
                return nil
            },
            persistBitCraftAccount: { account in
                if let account {
                    BitCraftTokenStore.save(account)
                    authLog.info("stored BitCraft account \(account.email, privacy: .private) in Keychain")
                } else {
                    BitCraftTokenStore.delete()
                    authLog.info("removed BitCraft account from Keychain")
                }
            },
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
