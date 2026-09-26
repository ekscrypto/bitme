import Testing
import Foundation
@testable import BitMeCore

/// State machine flows driven through simulated adapters (fenex-light
/// ADR-002/003/008): no network, no real waiting — assertions observe the
/// published ViewRep stream, never machine internals (ADR-014).
@MainActor
struct StateMachineTests {

    /// Scripted relay: resolve answers in order; session snapshots answer in
    /// order, then keep returning the last one. Instant sleep.
    final class SimulatedRelay: @unchecked Sendable {
        let resolveResults: [ResolveOutcome]
        let snapshots: [SessionSnapshot]

        enum ResolveOutcome: Sendable {
            case found(ResolveResponse)
            case notFound
            case error
        }

        /// BMR1 window served to every fetch (nil → `.notFound`).
        var window: ResourceWindow?
        /// Thrown by window fetches instead of serving `window`.
        var windowError: RelayError?
        /// Dictionary served for any region (nil → `.notFound`).
        var dictionary: ResourceDictionary?
        /// BME1 terrain plane served to every fetch (nil → `.notFound`).
        var terrain: TerrainPlane?
        /// Scripted change-stream connections (nil → parked, eventless).
        var stream: StreamScript?

        private let lock = NSLock()
        private var resolveIndex = 0
        private var snapshotIndex = 0
        private var windowFetchCount = 0
        private var terrainFetchCount = 0

        init(resolveResults: [ResolveOutcome], snapshots: [SessionSnapshot] = []) {
            self.resolveResults = resolveResults
            self.snapshots = snapshots
        }

        var nextResolve: ResolveOutcome {
            lock.lock(); defer { lock.unlock() }
            defer { resolveIndex += 1 }
            return resolveIndex < resolveResults.count ? resolveResults[resolveIndex] : .notFound
        }

        var nextSnapshot: SessionSnapshot? {
            lock.lock(); defer { lock.unlock() }
            defer { snapshotIndex += 1 }
            return snapshotIndex < snapshots.count ? snapshots[snapshotIndex] : snapshots.last
        }

        func noteWindowFetch() {
            lock.lock(); defer { lock.unlock() }
            windowFetchCount += 1
        }

        var totalWindowFetches: Int {
            lock.lock(); defer { lock.unlock() }
            return windowFetchCount
        }

        func noteTerrainFetch() {
            lock.lock(); defer { lock.unlock() }
            terrainFetchCount += 1
        }

        var totalTerrainFetches: Int {
            lock.lock(); defer { lock.unlock() }
            return terrainFetchCount
        }
    }

    /// Scripted change-stream: each connection hands out one event list and
    /// then finishes (server close); exhausted scripts park open with no
    /// events, like an idle healthy socket.
    final class StreamScript: @unchecked Sendable {
        private let lock = NSLock()
        private let connections: [[ResourceStreamEvent]]
        private var index = 0
        private var connects = 0

        init(_ connections: [[ResourceStreamEvent]]) {
            self.connections = connections
        }

        var connectCount: Int {
            lock.lock(); defer { lock.unlock() }
            return connects
        }

        func next() -> AsyncStream<ResourceStreamEvent> {
            lock.lock(); defer { lock.unlock() }
            connects += 1
            let events = index < connections.count ? connections[index] : nil
            index += 1
            return AsyncStream { continuation in
                guard let events else { return } // parked — never finishes
                Task {
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
            }
        }
    }

    static let resolved = ResolveResponse(
        found: true,
        entityID: "1000",
        username: "Whisper",
        usernameLowercase: "whisper",
        identity: nil,
        regionID: 7,
        regionName: "Virexal",
        host: nil,
        module: nil,
        signedIn: true
    )

    static let nowMs: Int64 = 1_788_628_492_000

    static func snapshot(
        signedIn: Bool? = true,
        target: Target? = nil,
        stamina: Stamina? = nil,
        buffs: [Buff] = [],
        spawns: [ActivitySpawn] = [],
        actions: [PlayerAction] = [],
        position dimension: Int? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            found: true,
            playerEntityID: "1000",
            username: "Whisper",
            signedIn: signedIn,
            region: 7,
            position: dimension.map {
                Position(
                    worldX: 100, worldZ: 100, tileX: 100, tileZ: 100,
                    destinationWorldX: 100, destinationWorldZ: 100,
                    dimension: $0, isWalking: false,
                    timestampMs: nowMs, ageMs: 0
                )
            },
            claim: nil,
            stamina: stamina,
            buffs: buffs,
            actions: actions,
            target: target,
            activitySpawns: spawns,
            serverTimeMs: nowMs
        )
    }

    // MARK: - Harness

    func makeMachine(
        relay: SimulatedRelay,
        identity: StoredIdentity? = nil,
        gamedata: FoodBuffGamedata? = FoodBuffGamedata(
            foodBuffIDs: [42], fetchedAt: .now
        ),
        restoreIdentity: (@Sendable () async -> StoredIdentity?)? = nil,
        bitCraftAccount: BitCraftAccount? = nil,
        sleep: (@Sendable (Double) async throws -> Void)? = nil,
        configuration: StateMachine.Configuration = .standard
    ) -> StateMachine {
        StateMachine(adapters: Adapters(
            relay: Adapters.Relay(
                resolve: { name in
                    switch relay.nextResolve {
                    case .found(let response): return response
                    case .notFound: throw RelayError.notFound
                    case .error: throw URLError(.badServerResponse)
                    }
                },
                session: { _ in
                    if let snapshot = relay.nextSnapshot { return snapshot }
                    throw URLError(.badServerResponse)
                },
                sessionResources: { _ in
                    relay.noteWindowFetch()
                    if let windowError = relay.windowError { throw windowError }
                    if let window = relay.window { return window }
                    throw RelayError.notFound
                },
                resourceDictionary: { _ in
                    if let dictionary = relay.dictionary { return dictionary }
                    throw RelayError.notFound
                },
                worldElevation: { _, _ in
                    relay.noteTerrainFetch()
                    if let terrain = relay.terrain { return terrain }
                    throw RelayError.notFound
                },
                openResourceStream: { _ in
                    relay.stream?.next() ?? AsyncStream { _ in } // parked
                }
            ),
            bitCraft: Adapters.BitCraft(
                requestAccessCode: { _ in },
                authenticate: { _, _ in "test-token" }
            ),
            loadFoodBuffGamedata: { gamedata },
            restoreIdentity: restoreIdentity ?? { identity },
            persistIdentity: { _ in },
            restoreBitCraftAccount: { bitCraftAccount },
            persistBitCraftAccount: { _ in },
            sleep: sleep ?? { _ in } // instant — flows run at task speed
        ), configuration: configuration)
    }

    /// Lock-protected ViewRep collector — sink callbacks arrive off-main.
    final class RepCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var reps: [ViewRep] = []

        func append(_ rep: ViewRep) {
            lock.withLock { reps.append(rep) }
        }

        func contains(_ predicate: (ViewRep) -> Bool) -> Bool {
            lock.withLock { reps.contains(where: predicate) }
        }

        func last(where predicate: (ViewRep) -> Bool) -> ViewRep? {
            lock.withLock { reps.last(where: predicate) }
        }

        func first(where predicate: (ViewRep) -> Bool) -> ViewRep? {
            lock.withLock { reps.first(where: predicate) }
        }

        var count: Int { lock.withLock { reps.count } }
    }

    /// Collects ViewReps until `finished` matches, with a timeout backstop.
    /// `dispatch` runs after subscribing so no intermediate rep is missed
    /// (the broadcaster replays only the latest value).
    func collect(_ machine: StateMachine, dispatch: (@Sendable () async -> Void)? = nil,
                 until finished: @Sendable @escaping (ViewRep) -> Bool,
                 timeout: TimeInterval = 5) async -> RepCollector {
        let collector = RepCollector()
        let task = machine.viewRep.sink { rep in
            collector.append(rep)
        }
        await dispatch?()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if collector.contains(finished) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        return collector
    }

    // MARK: - Tests

    @Test func resolveNotFoundSurfacesError() async {
        let machine = makeMachine(relay: SimulatedRelay(
            resolveResults: [.notFound], snapshots: [Self.snapshot()]
        ))
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: {
            if case .onboarding(let o) = $0 { return o.error != nil }
            return false
        })
        let errorRep = reps.last { rep in
            if case .onboarding(let o) = rep { return o.error != nil }
            return false
        }
        guard case .onboarding(let onboarding)? = errorRep else {
            Issue.record("expected an onboarding error rep")
            return
        }
        #expect(onboarding.error?.contains("No character found") == true)
        // The resolving phase was published before the error.
        #expect(reps.contains { rep in
            if case .onboarding(let o) = rep { return o.isResolving }
            return false
        })
    }

    @Test func resolveSuccessStartsSessionAndPolls() async {
        let bush = Target(
            entityID: "5000", resourceID: 38, name: "Flint Pile",
            health: 2398, maxHealth: 10_000,
            despawnTimeSecs: nil, respawnTimeSecs: nil,
            growthEndsAtMs: nil, location: nil
        )
        let machine = makeMachine(relay: SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(target: bush)]
        ))
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: { rep in
            if case .session(let s) = rep { return s.nowMs != nil && s.bush != nil }
            return false
        })
        guard case .session(let session)? = reps.last(where: {
            if case .session = $0 { return true }
            return false
        }) else {
            Issue.record("expected a session rep")
            return
        }
        #expect(session.username == "Whisper")
        #expect(session.entityID == "1000")
        #expect(session.connection == .ok)
        #expect(session.food.configured) // gamedata adapter supplied
        #expect(session.bush?.name == "Flint Pile")
        // Depletion anchor needs the learned pacing — nil on the first poll.
        #expect(session.bush?.depletesAtMs == nil)
        #expect(session.bush?.harvestedPct != nil)
    }

    /// 2026-09 playtest regression: T2 event berry bushes report null health
    /// until the first tracked tick and their gamedata despawn is 0, but the
    /// relay carries the bush's growth window — the card must count down from
    /// it (the game's "8m") instead of showing "Waiting for health data…".
    @Test func growthWindowShowsCountdownWithoutHealth() async {
        let bush = Target(
            entityID: "9001", resourceID: 353_689_546,
            name: "Giant Bountiful Savory Berry Bush",
            health: nil, maxHealth: 500,
            despawnTimeSecs: 0.0, respawnTimeSecs: 0.0,
            growthEndsAtMs: Self.nowMs + 480_000, location: nil
        )
        let machine = makeMachine(relay: SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(target: bush)]
        ))
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: { rep in
            if case .session(let s) = rep { return s.bush != nil }
            return false
        })
        guard case .session(let session)? = reps.last(where: { rep in
            if case .session(let s) = rep { return s.bush != nil }
            return false
        }), let bushRep = session.bush else {
            Issue.record("expected a session rep with a bush")
            return
        }
        #expect(bushRep.harvestedPct == nil)
        #expect(bushRep.depletesAtMs == nil)
        #expect(bushRep.windowEndsAtMs == Double(Self.nowMs + 480_000))
    }

    @Test func restoredIdentitySkipsOnboarding() async {
        let identity = StoredIdentity(
            entityID: "1000", username: "Whisper", regionID: 7, resolvedAt: .distantPast
        )
        let machine = makeMachine(
            relay: SimulatedRelay(resolveResults: [], snapshots: [Self.snapshot()]),
            identity: identity
        )
        await machine.start()
        let reps = await collect(machine, until: { rep in
            if case .session(let s) = rep { return s.nowMs != nil }
            return false
        })
        // The bootstrap must transition straight into a session.
        guard case .session(let session)? = reps.last(where: {
            if case .session = $0 { return true }
            return false
        }) else {
            Issue.record("expected a session rep without resolving")
            return
        }
        #expect(session.username == "Whisper")
        #expect(reps.contains { rep in
            if case .onboarding(let o) = rep { return o.isResolving }
            return false
        } == false)
    }

    @Test func citricSpawnAppearsInViewRep() async {
        let citric = ActivitySpawn(
            entityID: "9000", resourceID: 1_688_062_540, name: "Citric Giant Strawberry Bush",
            health: nil, maxHealth: 500, location: nil,
            spawnedAtMs: Self.nowMs, expiresAtMs: Self.nowMs + 30_000,
            growthEndsAtMs: nil
        )
        let machine = makeMachine(relay: SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(), Self.snapshot(spawns: [citric])]
        ))
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: { rep in
            if case .session(let s) = rep { return s.citric != nil }
            return false
        })
        guard case .session(let session)? = reps.first(where: { rep in
            if case .session(let s) = rep { return s.citric != nil }
            return false
        }), let citricRep = session.citric else {
            Issue.record("expected a citric rep")
            return
        }
        #expect(citricRep.entityID == "9000")
        #expect(citricRep.isNewlySpawned == true)
    }

    @Test func liveBuffsCarryGamedataNamesAndStats() async {
        let gamedata = FoodBuffGamedata(
            foodBuffIDs: [42],
            buffs: [
                124_924_8521: BuffInfo(
                    name: "Level 8 Food Regen",
                    stats: [
                        BuffStat(statID: 2, value: 10, isPercent: false),
                        BuffStat(statID: 3, value: 19, isPercent: false),
                    ]
                )
            ],
            fetchedAt: .now
        )
        let live = Buff(
            buffID: 124_924_8521,
            startTimestamp: Self.nowMs / 1_000,
            duration: 2_400,
            values: [10, 19]
        )
        let machine = makeMachine(
            relay: SimulatedRelay(
                resolveResults: [.found(Self.resolved)],
                snapshots: [Self.snapshot(buffs: [live])]
            ),
            gamedata: gamedata
        )
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: { rep in
            if case .session(let s) = rep { return !(s.food.liveBuffs.isEmpty) }
            return false
        })
        guard case .session(let session)? = reps.last(where: {
            if case .session = $0 { return true }
            return false
        }), let rep = session.food.liveBuffs.first else {
            Issue.record("expected a session rep with live buffs")
            return
        }
        #expect(rep.name == "Level 8 Food Regen")
        // Stamina regen sorts ahead of health regen for display.
        #expect(rep.stats.map(\.statID) == [3, 2])
        #expect(rep.stats.first?.displayValue == "+19")
    }

    @Test func signOutClearsIdentity() async {
        let identity = StoredIdentity(
            entityID: "1000", username: "Whisper", regionID: 7, resolvedAt: .distantPast
        )
        let machine = makeMachine(
            relay: SimulatedRelay(resolveResults: [], snapshots: [Self.snapshot()]),
            identity: identity
        )
        await machine.start()
        let live = await collect(machine, until: { rep in
            if case .session(let s) = rep { return s.nowMs != nil }
            return false
        })
        #expect(live.count > 0)
        await machine.ingest(Intent.SignOut())
        let after = await collect(machine, until: { rep in
            if case .onboarding = rep { return true }
            return false
        }, timeout: 2)
        #expect(after.contains { rep in
            if case .onboarding(let o) = rep { return !o.isResolving && o.error == nil }
            return false
        })
    }

    // MARK: - Resource map (relay §6–7 integration)

    /// Window centered on the scripted position (100, 100): resources 3×2,
    /// 5×1 (on water), one paving word.
    static var mapWindow: ResourceWindow {
        var words = [UInt16](repeating: 0, count: 16)
        words[0] = 0x0003
        words[1] = 0x0003
        words[15] = 0x8005
        return ResourceWindow(region: 7, dictVersion: 5, originX: 98, originZ: 98, width: 4, words: words)
    }

    static var mapDictionary: ResourceDictionary {
        ResourceDictionary(ready: true, region: 7, dictVersion: 5, entries: [
            ResourceDictionary.Entry(
                index: 3, name: "Flint Pile", harvestable: true, paving: false,
                resourceID: 38, pavingTypeID: nil, maxHealth: 10_000,
                respawnTimeSecs: 0, despawnTimeSecs: 0
            ),
            ResourceDictionary.Entry(
                index: 5, name: "Baited School Of Muddy Auratus", harvestable: true, paving: false,
                resourceID: 2_089_325_907, pavingTypeID: nil, maxHealth: 3_000,
                respawnTimeSecs: 0, despawnTimeSecs: 0
            ),
            ResourceDictionary.Entry(
                index: 6, name: "Giant Bountiful Strawberry Bush", harvestable: true, paving: false,
                resourceID: 1_822_942_131, pavingTypeID: nil, maxHealth: 500,
                respawnTimeSecs: 0, despawnTimeSecs: 0
            ),
            ResourceDictionary.Entry(
                index: 9, name: "Dirt Road", harvestable: nil, paving: true,
                resourceID: nil, pavingTypeID: 895_904_764, maxHealth: nil,
                respawnTimeSecs: nil, despawnTimeSecs: nil
            ),
        ])
    }

    @Test func liveSessionFetchesWindowAndBuildsNearbyCounts() async {
        let relay = SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(position: 1)]
        )
        relay.window = Self.mapWindow
        relay.dictionary = Self.mapDictionary
        let machine = makeMachine(relay: relay)
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: { rep in
            sessionRep(rep)?.resourceMap.nearby.isEmpty == false
        })
        guard case .session(let session)? = reps.last(where: { sessionRep($0) != nil }) else {
            Issue.record("expected a session rep with nearby resources")
            return
        }
        let map = session.resourceMap
        #expect(map.region == 7)
        #expect(map.width == 4)
        #expect(map.originTileX == 98)
        #expect(map.originTileZ == 98)
        #expect(map.populatedTiles == 3)
        // Count-sorted, names resolved through the dictionary; paving never
        // appears.
        #expect(map.nearby.map { "\($0.name ?? "?")×\($0.count)" } == ["Flint Pile×2", "Baited School Of Muddy Auratus×1"])
        #expect(map.nearby.first?.resourceID == 38)
        // No stream scripted — the parked connection never goes live.
        #expect(map.stream != .live)
    }

    @Test func streamDeltasMaintainTallyAndSpawnFeed() async {
        let relay = SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(position: 1)]
        )
        relay.window = Self.mapWindow
        relay.dictionary = Self.mapDictionary
        relay.stream = StreamScript([[
            .subscribed(anchorX: 100, anchorZ: 100, width: 4, region: 7, dictVersion: 5),
            .delta(ResourceTileDelta(region: 7, dictVersion: 5, changes: [
                // Replace resource 3 with a Bountiful bush (withering →
                // bountiful transition) and despawn the other resource 3.
                ResourceTileDelta.TileChange(x: 99, z: 98, word: 0x0006),
                ResourceTileDelta.TileChange(x: 98, z: 98, word: 0x0000),
            ])),
        ]])
        let machine = makeMachine(relay: relay)
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: { rep in
            guard let session = sessionRep(rep) else { return false }
            return session.resourceMap.feed.count >= 3
        })
        // The scripted connection goes live, delivers the delta, then closes —
        // assert against the rep captured while live (later reps show the
        // reconnecting status).
        guard case .session(let session)? = reps.last(where: { rep in
            guard let session = sessionRep(rep) else { return false }
            return session.resourceMap.feed.count >= 3 && session.resourceMap.stream == .live
        }) else {
            Issue.record("expected a live session rep with feed entries")
            return
        }
        let map = session.resourceMap
        #expect(map.anchorTileX == 100)
        #expect(map.anchorTileZ == 100)
        // Replacement emits despawn(old)+spawn(new); plain despawn emits one
        // entry. Newest first.
        #expect(map.feed.map { "\($0.name ?? "?")|\($0.spawned)" } == [
            "Flint Pile|false",                     // despawn at (98, 98)
            "Giant Bountiful Strawberry Bush|true", // spawn at (99, 98)
            "Flint Pile|false",                     // replaced tile's old resource
        ])
        #expect(map.feed.first?.tileX == 98)
        #expect(map.feed[1].tileX == 99)
        // Tally: Flint 2→0, Bountiful +1, Baited unchanged.
        #expect(map.nearby.map { "\($0.name ?? "?")×\($0.count)" }
                == ["Baited School Of Muddy Auratus×1", "Giant Bountiful Strawberry Bush×1"])
        #expect(map.populatedTiles == 2)
    }

    @Test func resyncRefetchesTheWindow() async {
        let relay = SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(position: 1)]
        )
        relay.window = Self.mapWindow
        relay.dictionary = Self.mapDictionary
        relay.stream = StreamScript([[
            .subscribed(anchorX: 100, anchorZ: 100, width: 4, region: 7, dictVersion: 5),
            .resync,
        ]])
        let machine = makeMachine(relay: relay)
        await machine.start()
        await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        await waitFor { relay.totalWindowFetches >= 2 }
        #expect(relay.totalWindowFetches >= 2)
    }

    @Test func deltaFromAMismatchedDictionaryRefetches() async {
        let relay = SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(position: 1)]
        )
        relay.window = Self.mapWindow // dictVersion 5
        relay.dictionary = Self.mapDictionary
        relay.stream = StreamScript([[
            .subscribed(anchorX: 100, anchorZ: 100, width: 4, region: 7, dictVersion: 5),
            // Dictionary rotated mid-connection — the delta's generation no
            // longer matches the window; convergence is a refetch.
            .delta(ResourceTileDelta(region: 7, dictVersion: 6, changes: [
                ResourceTileDelta.TileChange(x: 98, z: 98, word: 0x0000),
            ])),
        ]])
        let machine = makeMachine(relay: relay)
        await machine.start()
        await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        await waitFor { relay.totalWindowFetches >= 2 }
        #expect(relay.totalWindowFetches >= 2)
    }

    @Test func streamStaysOffWhilePlayerNotLive() async {
        let relay = SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(signedIn: false)]
        )
        relay.window = Self.mapWindow
        relay.stream = StreamScript([[
            .subscribed(anchorX: 100, anchorZ: 100, width: 4, region: 7, dictVersion: 5),
        ]])
        // Real (small) sleeps keep the pause-wait loop off a hot spin.
        let machine = makeMachine(relay: relay, sleep: { _ in
            try await Task.sleep(for: .milliseconds(2))
        })
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: { rep in
            sessionRep(rep)?.nowMs != nil
        })
        // Give the (never-connecting) stream loop time to misbehave.
        try? await Task.sleep(for: .milliseconds(200))
        guard case .session(let session)? = reps.last(where: { sessionRep($0) != nil }) else {
            Issue.record("expected a session rep")
            return
        }
        #expect(relay.stream?.connectCount == 0)
        #expect(session.resourceMap.stream == .off)
    }

    /// Pocket-Crafter configuration: a live overworld player, but the map
    /// stack stays off — no window/terrain fetches, no stream connections.
    @Test func resourceMapDisabledSkipsWindowFetchAndStream() async {
        let relay = SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(position: 1)]
        )
        // Everything is scripted — any fetch or connection is a failure.
        relay.window = Self.mapWindow
        relay.dictionary = Self.mapDictionary
        relay.terrain = Self.mapTerrain
        relay.stream = StreamScript([[
            .subscribed(anchorX: 100, anchorZ: 100, width: 4, region: 7, dictVersion: 5),
        ]])
        // Real (small) sleeps keep a misbehaving pause-wait loop off a hot spin.
        let machine = makeMachine(relay: relay, sleep: { _ in
            try await Task.sleep(for: .milliseconds(2))
        }, configuration: StateMachine.Configuration(resourceMapEnabled: false))
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: { rep in
            sessionRep(rep)?.nowMs != nil
        })
        // Give the (never-spawned) map activities time to misbehave.
        try? await Task.sleep(for: .milliseconds(200))
        guard case .session(let session)? = reps.last(where: { sessionRep($0) != nil }) else {
            Issue.record("expected a session rep")
            return
        }
        #expect(relay.totalWindowFetches == 0)
        #expect(relay.totalTerrainFetches == 0)
        #expect(relay.stream?.connectCount == 0)
        #expect(session.resourceMap.stream == .off)
        #expect(session.resourceMap.nearby.isEmpty)
    }

    /// Terrain plane whose super grid covers the fixture window's center
    /// (tile (100, 100) → super (24, 33)).
    static var mapTerrain: TerrainPlane {
        TerrainPlane(
            region: 7, generation: 1,
            originSuperX: 20, originSuperZ: 30, width: 10, height: 10,
            lo: Array(repeating: 40, count: 100),
            hi: Array(repeating: UInt32(UInt16(bitPattern: TerrainPlane.waterNone)), count: 100)
        )
    }

    final class MapRepCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var reps: [MapRep] = []

        func append(_ rep: MapRep) {
            lock.withLock { reps.append(rep) }
        }

        func contains(_ predicate: (MapRep) -> Bool) -> Bool {
            lock.withLock { reps.contains(where: predicate) }
        }

        var compactVersions: [Int] {
            lock.withLock { reps.map(\.tileVersion) }
        }
    }

    @Test func mapRepCarriesTilesTerrainPlayerAndLiveDeltas() async {
        let relay = SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(position: 1)]
        )
        relay.window = Self.mapWindow
        relay.dictionary = Self.mapDictionary
        relay.terrain = Self.mapTerrain
        relay.stream = StreamScript([[
            .subscribed(anchorX: 100, anchorZ: 100, width: 4, region: 7, dictVersion: 5),
            .delta(ResourceTileDelta(region: 7, dictVersion: 5, changes: [
                ResourceTileDelta.TileChange(x: 98, z: 98, word: 0x0000), // despawn
            ])),
        ]])
        let machine = makeMachine(relay: relay)
        await machine.start()
        let collector = MapRepCollector()
        let task = machine.mapRep.sink { collector.append($0) }
        defer { task.cancel() }
        await machine.ingest(Intent.ResolvePlayer(name: "whisper"))

        // Window + dictionary + terrain all land in the tile channel.
        await waitFor { collector.contains { $0.terrain != nil && $0.words.count == 16 } }
        let seeded = collector.contains {
            $0.terrain != nil && $0.words.first == 0x0003
                && $0.entries[3]?.name == "Flint Pile"
                && $0.player?.tileX == 100
                && $0.player?.dimension == 1
                // The filter panel's nearby counts ride along (dict index →
                // populated tiles).
                && $0.tally == [3: 2, 5: 1]
        }
        #expect(seeded)
        #expect(relay.totalTerrainFetches >= 1)

        // The change-stream delta rewrites the published word grid.
        await waitFor { collector.contains { $0.words.first == 0x0000 } }
        #expect(collector.contains { $0.words.first == 0x0000 })
        // Deltas keep the tally live: one of the two resource-3 tiles emptied.
        #expect(collector.contains { $0.tally[3] == 1 })
        // The stream's anchor rides along once subscribed.
        #expect(collector.contains { $0.anchorX == 100 && $0.anchorZ == 100 })
    }

    /// Regression for the render cache key: tile-affecting changes bump
    /// `tileVersion`; position-only polls do not.
    @Test func mapRepTileVersionBumpsOnlyOnTileChanges() async {
        let relay = SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(position: 1)]
        )
        relay.window = Self.mapWindow
        relay.dictionary = Self.mapDictionary
        let machine = makeMachine(relay: relay)
        await machine.start()
        let collector = MapRepCollector()
        let task = machine.mapRep.sink { collector.append($0) }
        defer { task.cancel() }
        await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        await waitFor { collector.contains { !$0.words.isEmpty } }
        // Let several identical polls land — the tile version must hold.
        try? await Task.sleep(for: .milliseconds(150))
        let versions = collector.compactVersions
        #expect(versions.count >= 1)
        #expect(versions.max()! - versions.min()! <= 2) // window + dictionary bumps only
    }

    @Test func runningActionsSurfaceBaseFirstWithResolvedTargets() async {
        let bush = Target(
            entityID: "5000", resourceID: 38, name: "Flint Pile",
            health: 2398, maxHealth: 10_000,
            despawnTimeSecs: nil, respawnTimeSecs: nil,
            growthEndsAtMs: nil, location: nil
        )
        let extract = PlayerAction(
            autoID: "1", actionType: "Extract", layer: "Base",
            startTimeMs: Self.nowMs - 2_000, durationMs: 6_000, endsAtMs: Self.nowMs + 4_000,
            targetEntityID: "5000", recipeID: nil,
            lastActionResult: "Success", clientCancel: false
        )
        let craft = PlayerAction(
            autoID: "2", actionType: "Craft", layer: "UpperBody",
            startTimeMs: Self.nowMs - 1_000, durationMs: 5_000, endsAtMs: Self.nowMs + 4_000,
            targetEntityID: nil, recipeID: 5,
            lastActionResult: "Success", clientCancel: false
        )
        // Rows persist after completion — only in-progress ones surface.
        let finished = PlayerAction(
            autoID: "3", actionType: "Extract", layer: "Base",
            startTimeMs: Self.nowMs - 10_000, durationMs: 5_000, endsAtMs: Self.nowMs - 5_000,
            targetEntityID: "5000", recipeID: nil,
            lastActionResult: "Success", clientCancel: false
        )
        let machine = makeMachine(relay: SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(target: bush, actions: [finished, craft, extract])]
        ))
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: { rep in
            guard let session = sessionRep(rep) else { return false }
            return !session.actions.isEmpty
        })
        guard case .session(let session)? = reps.last(where: { !(sessionRep($0)?.actions.isEmpty ?? true) }) else {
            Issue.record("expected a session rep with running actions")
            return
        }
        // Base layer first; the finished action is filtered out; the
        // Extract's target resolves to the snapshot target's name.
        #expect(session.actions.map(\.actionType) == ["Extract", "Craft"])
        #expect(session.actions.first?.targetName == "Flint Pile")
        #expect(session.actions.last?.targetName == nil)
        #expect(session.actions.first?.endsAtMs == Double(Self.nowMs + 4_000))
    }

    /// Polls a condition with a timeout backstop (for effects visible only
    /// outside the ViewRep, like relay-side fetch counts).
    private func waitFor(
        _ condition: @Sendable () -> Bool,
        timeout: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Session hand-off races (CLI start → SignOut → resolve)

    /// Regression: a slow identity restore that lands after the CLI-style
    /// SignOut + resolve sequence must not resurrect the previous character
    /// on top of the newly-resolved session.
    @Test func lateBootstrapDoesNotResurrectThePreviousCharacter() async {
        let previous = StoredIdentity(
            entityID: "2000", username: "Teya", regionID: 7, resolvedAt: .distantPast
        )
        let relay = SimulatedRelay(
            resolveResults: [.found(Self.resolved)], // entity 1000, Whisper
            snapshots: [Self.snapshot()]
        )
        relay.window = Self.mapWindow
        let machine = makeMachine(
            relay: relay,
            restoreIdentity: {
                // Slow read — lands well after the resolve completed.
                try? await Task.sleep(for: .milliseconds(120))
                return previous
            }
        )
        await machine.start()
        await machine.ingest(Intent.SignOut())
        await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        try? await Task.sleep(for: .milliseconds(400))
        let reps = await collect(machine, until: { _ in false }, timeout: 0.2)
        guard case .session(let session)? = reps.last(where: { sessionRep($0) != nil }) else {
            Issue.record("expected a session rep")
            return
        }
        #expect(session.entityID == "1000")
        #expect(session.username == "Whisper")
        #expect(!reps.contains { sessionRep($0)?.entityID == "2000" })
    }

    /// Regression: resolving a *different* character while a session is
    /// already running must retire the old loops and poll the new entity.
    @Test func resolvingANewCharacterReplacesTheRunningSession() async {
        let other = ResolveResponse(
            found: true, entityID: "3000", username: "Other",
            usernameLowercase: "other", identity: nil, regionID: 7,
            regionName: nil, host: nil, module: nil, signedIn: true
        )
        let relay = SimulatedRelay(
            resolveResults: [.found(Self.resolved), .found(other)],
            snapshots: [Self.snapshot(position: 1)]
        )
        relay.window = Self.mapWindow
        relay.dictionary = Self.mapDictionary
        let machine = makeMachine(relay: relay)
        await machine.start()
        let first = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: { rep in
            sessionRep(rep)?.entityID == "1000"
        })
        #expect(first.contains { sessionRep($0)?.entityID == "1000" })
        let second = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "other"))
        }, until: { rep in
            guard let session = sessionRep(rep) else { return false }
            return session.entityID == "3000" && !session.resourceMap.nearby.isEmpty
        }, timeout: 15) // full-suite parallelism can starve this chain
                         // (poll → window fetch → dictionary) past the 5 s
                         // default; solo it finishes in milliseconds.
        guard case .session(let session)? = second.last(where: {
            sessionRep($0)?.entityID == "3000"
        }) else {
            Issue.record("expected the replacement session")
            return
        }
        #expect(session.username == "Other")
        // The replacement carries its own resource map (window refetched for
        // the new entity, not inherited stale state).
        #expect(session.resourceMap.nearby.isEmpty == false)
    }
}


/// Nonisolated ViewRep.Session extractor — used inside @Sendable collect
/// predicates (the test struct is @MainActor).
private func sessionRep(_ rep: ViewRep) -> ViewRep.Session? {
    if case .session(let session) = rep { return session }
    return nil
}
