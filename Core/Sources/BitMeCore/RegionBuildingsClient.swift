import Foundation
import SpacetimeDB
import os

/// The signed-in region-shard leg of the game session — the websocket the
/// claim-buildings sync subscribes on. `GlobalSessionClient` yields it
/// right after the shard's `sign_in` commits; all region traffic shares
/// this one connection because the game allows one live session per
/// account per database. Equal by identity.
public final class RegionLeg: Sendable, Equatable {
    let client: SpacetimeDBClient

    init(client: SpacetimeDBClient) {
        self.client = client
    }

    public static func == (lhs: RegionLeg, rhs: RegionLeg) -> Bool {
        lhs === rhs
    }
}

// MARK: - Sync vocabulary

/// The pinned claim's header row (`claim_state`).
public struct ClaimHeader: Equatable, Sendable {
    public let entityID: UInt64
    public let name: String
    public let ownerPlayerEntityID: UInt64
    public let neutral: Bool

    init(entityID: UInt64, name: String, ownerPlayerEntityID: UInt64, neutral: Bool) {
        self.entityID = entityID
        self.name = name
        self.ownerPlayerEntityID = ownerPlayerEntityID
        self.neutral = neutral
    }
}

/// The static catalogs the join needs, fetched once per sync
/// (`building_desc`, `crafting_recipe_desc`, `tool_type_desc`,
/// `item_desc`, `cargo_desc`) and cached on disk for 48 h (the food-buff
/// gamedata policy): a relaunch paints names and classification from the
/// cache instead of waiting on the leg's one-offs. Game updates land on
/// the first session after the TTL lapses. (A cache written before a
/// field was added fails to decode and self-refetches — one cold load
/// per schema change.)
public struct BuildingGamedata: Equatable, Sendable, Codable {
    public static let ttl: TimeInterval = 48 * 60 * 60

    public let buildings: [Int32: BuildingDescInfo]
    public let recipeNames: [Int32: String]
    /// Recipe id → profession (game skill id), resolved at load: the
    /// recipe's own `level_requirements` skill when present, else its
    /// tool type's skill via `tool_type_desc` (e.g. the Machete →
    /// Foraging). Feeds `WorkstationsRep.Craft.profession`.
    public let recipeSkills: [Int32: Int32]
    /// Recipe id → first `consumed_item_stacks` entry — the name
    /// template's {1}.
    public let recipeInputs: [Int32: ItemStackRef]
    /// Recipe id → first `crafted_item_stacks` entry — the name
    /// template's {0}.
    public let recipeOutputs: [Int32: ItemStackRef]
    /// Recipe id → `actions_required`, the per-item effort of bench
    /// crafts. A progressive craft's progress bar denominator is
    /// `craftCount × actionsRequired` (live-verified 2026-09-28), and
    /// "complete" is `progress ≥` that product — never `progress ≥
    /// craftCount`.
    public let recipeActionsRequired: [Int32: Int32]
    /// `item_desc` id → name — resolves Item-typed stack refs.
    public let itemNames: [Int32: String]
    /// `cargo_desc` id → name — resolves Cargo-typed stack refs.
    public let cargoNames: [Int32: String]
    public let fetchedAt: Date

    init(
        buildings: [Int32: BuildingDescInfo] = [:],
        recipeNames: [Int32: String] = [:],
        recipeSkills: [Int32: Int32] = [:],
        recipeInputs: [Int32: ItemStackRef] = [:],
        recipeOutputs: [Int32: ItemStackRef] = [:],
        recipeActionsRequired: [Int32: Int32] = [:],
        itemNames: [Int32: String] = [:],
        cargoNames: [Int32: String] = [:],
        fetchedAt: Date = .now
    ) {
        self.buildings = buildings
        self.recipeNames = recipeNames
        self.recipeSkills = recipeSkills
        self.recipeInputs = recipeInputs
        self.recipeOutputs = recipeOutputs
        self.recipeActionsRequired = recipeActionsRequired
        self.itemNames = itemNames
        self.cargoNames = cargoNames
        self.fetchedAt = fetchedAt
    }

    /// The recipe's display name. All but ~50 of the ~7.8k recipes carry
    /// a .NET-style `name` template — "Braid {0} from {1}" — whose {0} is
    /// the first crafted stack's item and {1} the first consumed one;
    /// resolved against the item/cargo name catalogs. Literal names pass
    /// through, and a template whose referenced stack is missing falls
    /// back to the raw column rather than half-substituting.
    public func recipeDisplayName(_ recipeID: Int32) -> String? {
        guard let template = recipeNames[recipeID] else { return nil }
        var name = template
        if name.contains("{0}") {
            guard let output = recipeOutputs[recipeID].flatMap({ itemName(of: $0) }) else {
                return template
            }
            name = name.replacingOccurrences(of: "{0}", with: output)
        }
        if name.contains("{1}") {
            guard let input = recipeInputs[recipeID].flatMap({ itemName(of: $0) }) else {
                return template
            }
            name = name.replacingOccurrences(of: "{1}", with: input)
        }
        return name
    }

    private func itemName(of stack: ItemStackRef) -> String? {
        stack.isCargo ? cargoNames[stack.id] : itemNames[stack.id]
    }

    public func isStale(now: Date = .now) -> Bool {
        now.timeIntervalSince(fetchedAt) >= Self.ttl
    }

    /// `fetchedAt` is the distant past so empty always reads as stale —
    /// nothing may be "fresh" about not having the catalogs.
    public static let empty = BuildingGamedata(fetchedAt: .distantPast)
}

/// One placed building of the pinned claim (`building_state` slice).
public struct RegionBuilding: Equatable, Sendable {
    public let entityID: UInt64
    public let claimEntityID: UInt64
    public let buildingDescriptionID: Int32

    init(entityID: UInt64, claimEntityID: UInt64, buildingDescriptionID: Int32) {
        self.entityID = entityID
        self.claimEntityID = claimEntityID
        self.buildingDescriptionID = buildingDescriptionID
    }
}

/// One craft task — a queued/timed passive craft or an at-the-bench
/// progressive craft, normalized for the workstation list.
public struct RegionCraft: Equatable, Sendable {
    public let entityID: UInt64
    public let ownerEntityID: UInt64
    public let buildingEntityID: UInt64
    public let recipeID: Int32
    public let kind: Kind

    public enum Kind: Equatable, Sendable {
        case passive(status: PassiveCraftStatus, startedAtMicros: Int64)
        case active(progress: Int32, craftCount: Int32, preparation: Bool, lockExpiresAtMicros: Int64)
    }

    init(entityID: UInt64, ownerEntityID: UInt64, buildingEntityID: UInt64, recipeID: Int32, kind: Kind) {
        self.entityID = entityID
        self.ownerEntityID = ownerEntityID
        self.buildingEntityID = buildingEntityID
        self.recipeID = recipeID
        self.kind = kind
    }
}

/// Events from the claim-buildings sync, delivered as coalesced arrays
/// (one array per flush — see `EventBuffer`): a busy claim's snapshot is
/// thousands of row diffs, and one ingest per diff would flood the
/// machine. The stream always ends with the region leg: a terminal
/// `.failed` event precedes the end when the sync itself gave up (setup
/// failure, connection lost mid-stream).
public enum ClaimBuildingsEvent: Equatable, Sendable {
    /// Subscriptions are out; the initial snapshot is landing.
    case syncing
    /// The initial snapshot landed (`SubscribeApplied`).
    case live
    case claim(ClaimHeader)
    case gamedata(BuildingGamedata)
    case buildingChanged(RegionBuilding)
    case buildingRemoved(UInt64)
    case nicknameChanged(entityID: UInt64, nickname: String)
    case nicknameRemoved(UInt64)
    case craftChanged(RegionCraft)
    case craftRemoved(UInt64)
    /// A progressive craft entered the game's shared projection
    /// (`public_progressive_action_state`) — other players may contribute
    /// effort to it. Carries the craft's entity id; the craft's own row
    /// arrives (or already sits) in `.craftChanged`.
    case sharedCraftChanged(UInt64)
    /// The shared projection dropped a craft (unshared or collected).
    /// Orphaned ids that never had a craft row are harmless.
    case sharedCraftRemoved(UInt64)
    case failed(String)
}

// MARK: - Client

/// Live claim-buildings sync over the game session's region leg
/// (docs/protocol/region-claim-buildings.md):
///
/// 1. one-off queries load the static catalogs (`building_desc`,
///    `crafting_recipe_desc`, `tool_type_desc`, plus `item_desc` and
///    `cargo_desc` for the recipe-name templates) — names/classification
///    for the join;
/// 2. one subscription set covers the claim slice (`building_state WHERE
///    claim_entity_id`, `claim_state`, whole-table `building_nickname_state`
///    — low churn, the relay mirror subscribes it the same way) plus the
///    player's own crafts on both craft tables;
/// 3. as building batches arrive, one debounced additive query set
///    subscribes the new buildings' craft rows (`WHERE building_entity_id
///    = …`), keeping the high-churn craft tables scoped instead of
///    whole-table.
///
/// Row consumption rides the batched per-table streams (`tableEvents`) —
/// updates arrive as delete+insert pairs in one event, applied
/// delete-first so a pair lands as an upsert — and events flush to the
/// consumer in coalesced arrays.
enum RegionBuildingsClient {

    /// Coalesces single events into array flushes, one ingest per flush.
    /// Status-flavored events (`.live`, `.failed`, …) flush immediately;
    /// row diffs pool for `flushDelay` (0.5 s — the intent granularity the
    /// product wants) or until the cap, so a snapshot burst of thousands
    /// of diffs becomes a couple of ingests and live craft ticks land at
    /// most twice a second. Each drain also logs one debug line with the
    /// pooled per-table row deltas — the log cadence matches the ingest
    /// cadence instead of the raw event rate.
    final class EventBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: [ClaimBuildingsEvent] = []
        private var rowDeltas: [String: (inserts: Int, deletes: Int)] = [:]
        private var drainPending = false
        private let flushDelay: TimeInterval
        private let flush: @Sendable ([ClaimBuildingsEvent]) -> Void

        init(flushDelay: TimeInterval, flush: @escaping @Sendable ([ClaimBuildingsEvent]) -> Void) {
            self.flushDelay = flushDelay
            self.flush = flush
        }

        func push(_ event: ClaimBuildingsEvent) {
            var flushNow = false
            var scheduleDrain = false
            lock.withLock {
                buffer.append(event)
                switch event {
                case .syncing, .live, .claim, .gamedata, .failed:
                    flushNow = true
                default:
                    flushNow = buffer.count >= 512
                    if !flushNow && !drainPending {
                        drainPending = true
                        scheduleDrain = true
                    }
                }
            }
            if flushNow {
                drain()
            } else if scheduleDrain {
                let delay = flushDelay
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    self?.drain()
                }
            }
        }

        /// Accumulates per-table row counts for the next drain's summary
        /// log. Called by the table consumers per batch — cheap counter
        /// work, no logging until the drain.
        func recordDelta(table: String, inserts: Int, deletes: Int) {
            guard inserts > 0 || deletes > 0 else { return }
            lock.withLock {
                let current = rowDeltas[table] ?? (inserts: 0, deletes: 0)
                rowDeltas[table] = (current.inserts + inserts, current.deletes + deletes)
            }
        }

        /// Swap out and deliver whatever is buffered, logging the pooled
        /// row deltas as one line.
        func drain() {
            let (events, deltas) = lock.withLock {
                drainPending = false
                let events = buffer
                buffer = []
                let deltas = rowDeltas
                rowDeltas = [:]
                return (events, deltas)
            }
            guard !events.isEmpty else { return }
            if !deltas.isEmpty {
                let summary = deltas
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key) +\($0.value.inserts) −\($0.value.deletes)" }
                    .joined(separator: ", ")
                coreLog.debug("claim buildings: pool \(summary)")
            }
            flush(events)
        }
    }

    /// Lock-protected building-set tracker — decides when an additive
    /// craft subscription is due. Fresh ids accumulate and flush as one
    /// debounced subscribe (the snapshot arrives as many batches; one
    /// Subscribe per building would spam the server).
    private final class BuildingSet: @unchecked Sendable {
        private let lock = NSLock()
        private var known: Set<UInt64> = []
        private var subscribed: Set<UInt64> = []
        private var pending: Set<UInt64> = []
        private var flushTask: Task<Void, Never>?

        func added(_ ids: Set<UInt64>, debounce: TimeInterval, flush: @escaping @Sendable (Set<UInt64>) -> Void) {
            lock.withLock {
                let fresh = ids.subtracting(known)
                guard !fresh.isEmpty else { return }
                known.formUnion(ids)
                let unsubscribed = fresh.subtracting(subscribed)
                guard !unsubscribed.isEmpty else { return }
                subscribed.formUnion(unsubscribed)
                pending.formUnion(unsubscribed)
                flushTask?.cancel()
                flushTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(debounce))
                    guard let self, !Task.isCancelled else { return }
                    self.drain(flush: flush)
                }
            }
        }

        func removed(_ ids: Set<UInt64>) {
            lock.withLock {
                known.subtract(ids)
                subscribed.subtract(ids)
                pending.subtract(ids)
            }
        }

        private func drain(flush: @escaping @Sendable (Set<UInt64>) -> Void) {
            let ids = lock.withLock {
                let ids = pending
                pending = []
                flushTask = nil
                return ids
            }
            if !ids.isEmpty {
                flush(ids)
            }
        }
    }

    static func events(leg: RegionLeg, claim: UInt64, player: UInt64) -> AsyncStream<[ClaimBuildingsEvent]> {
        AsyncStream { continuation in
            let task = Task {
                let buffer = EventBuffer(flushDelay: 0.5) { events in
                    continuation.yield(events)
                }
                await run(client: leg.client, claim: claim, player: player, buffer: buffer)
                buffer.drain()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func run(
        client: SpacetimeDBClient,
        claim: UInt64,
        player: UInt64,
        buffer: EventBuffer
    ) async {
        let emit = buffer.push
        do {
            // 1. Static catalogs first so building/recipe names resolve from
            //    the very first row event on — cache-first (48 h TTL, the
            //    food-buff gamedata policy): a relaunch paints from the cache
            //    instead of waiting on the leg's one-offs, and a failed fetch
            //    still serves a stale cache — old catalog data beats none.
            let gamedata = await loadGamedata(client: client)
            emit(.gamedata(gamedata))

            await client.registerTableRowDecoder(BuildingStateRow.self)
            await client.registerTableRowDecoder(ClaimStateRow.self)
            await client.registerTableRowDecoder(BuildingNicknameRow.self)
            await client.registerTableRowDecoder(PassiveCraftRow.self)
            await client.registerTableRowDecoder(ProgressiveActionRow.self)
            await client.registerTableRowDecoder(PublicProgressiveActionRow.self)

            // 2. Attach the batched row streams before subscribing: the
            // initial snapshot fans out when SubscribeApplied lands, so a
            // stream attached afterwards would miss it.
            let buildingEvents = await client.tableEvents(named: BuildingStateRow.tableName)
            let claimEvents = await client.tableEvents(named: ClaimStateRow.tableName)
            let nicknameEvents = await client.tableEvents(named: BuildingNicknameRow.tableName)
            let passiveCraftEvents = await client.tableEvents(named: PassiveCraftRow.tableName)
            let progressiveEvents = await client.tableEvents(named: ProgressiveActionRow.tableName)
            let sharedEvents = await client.tableEvents(named: PublicProgressiveActionRow.tableName)
            let connectionEvents = await client.connectionEvents

            emit(.syncing)
            let queries = baseQueries(claim: claim, player: player)
            coreLog.info("claim buildings: subscribing (\(queries.count) queries): \(queries.joined(separator: " | "), privacy: .public)")
            let base = try await client.subscribe(queries)
            try await base.applied()
            emit(.live)
            coreLog.info("claim buildings: live (claim \(claim, privacy: .public))")

            // 3. Consume the row streams until the leg closes.
            let buildings = BuildingSet()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await Self.consume(buildingEvents, of: BuildingStateRow.self) { row in
                        emit(.buildingChanged(RegionBuilding(
                            entityID: row.entityID,
                            claimEntityID: row.claimEntityID,
                            buildingDescriptionID: row.buildingDescriptionID
                        )))
                    } onRemove: { entityID in
                        emit(.buildingRemoved(entityID))
                    } onBatch: { inserted, deleted in
                        buffer.recordDelta(table: BuildingStateRow.tableName, inserts: inserted.count, deletes: deleted.count)
                        if !deleted.isEmpty {
                            buildings.removed(deleted)
                        }
                        if !inserted.isEmpty {
                            buildings.added(inserted, debounce: 0.25) { fresh in
                                Self.subscribeCrafts(client: client, buildings: fresh)
                            }
                        }
                    }
                }
                group.addTask {
                    await Self.consume(claimEvents, of: ClaimStateRow.self) { row in
                        emit(.claim(ClaimHeader(
                            entityID: row.entityID,
                            name: row.name,
                            ownerPlayerEntityID: row.ownerPlayerEntityID,
                            neutral: row.neutral
                        )))
                    } onRemove: { _ in } onBatch: { inserted, deleted in
                        buffer.recordDelta(table: ClaimStateRow.tableName, inserts: inserted.count, deletes: deleted.count)
                    }
                }
                group.addTask {
                    await Self.consume(nicknameEvents, of: BuildingNicknameRow.self) { row in
                        emit(.nicknameChanged(entityID: row.entityID, nickname: row.nickname))
                    } onRemove: { entityID in
                        emit(.nicknameRemoved(entityID))
                    } onBatch: { inserted, deleted in
                        buffer.recordDelta(table: BuildingNicknameRow.tableName, inserts: inserted.count, deletes: deleted.count)
                    }
                }
                group.addTask {
                    await Self.consume(passiveCraftEvents, of: PassiveCraftRow.self) { row in
                        emit(.craftChanged(RegionCraft(
                            entityID: row.entityID,
                            ownerEntityID: row.ownerEntityID,
                            buildingEntityID: row.buildingEntityID,
                            recipeID: row.recipeID,
                            kind: .passive(status: row.status, startedAtMicros: row.startedAtMicros)
                        )))
                    } onRemove: { entityID in
                        emit(.craftRemoved(entityID))
                    } onBatch: { inserted, deleted in
                        buffer.recordDelta(table: PassiveCraftRow.tableName, inserts: inserted.count, deletes: deleted.count)
                    }
                }
                group.addTask {
                    await Self.consume(progressiveEvents, of: ProgressiveActionRow.self) { row in
                        emit(.craftChanged(RegionCraft(
                            entityID: row.entityID,
                            ownerEntityID: row.ownerEntityID,
                            buildingEntityID: row.buildingEntityID,
                            recipeID: row.recipeID,
                            kind: .active(
                                progress: row.progress,
                                craftCount: row.craftCount,
                                preparation: row.preparation,
                                lockExpiresAtMicros: row.lockExpiresAtMicros
                            )
                        )))
                    } onRemove: { entityID in
                        emit(.craftRemoved(entityID))
                    } onBatch: { inserted, deleted in
                        buffer.recordDelta(table: ProgressiveActionRow.tableName, inserts: inserted.count, deletes: deleted.count)
                    }
                }
                group.addTask {
                    await Self.consume(sharedEvents, of: PublicProgressiveActionRow.self) { row in
                        emit(.sharedCraftChanged(row.entityID))
                    } onRemove: { entityID in
                        emit(.sharedCraftRemoved(entityID))
                    } onBatch: { inserted, deleted in
                        buffer.recordDelta(table: PublicProgressiveActionRow.tableName, inserts: inserted.count, deletes: deleted.count)
                    }
                }
                group.addTask {
                    for await event in connectionEvents {
                        switch event {
                        case .connected, .reconnecting:
                            continue
                        case .disconnected, .error:
                            // The leg closed — the game-session loop sees the
                            // same close and returns the app to the gate.
                            coreLog.info("claim buildings: region leg ended")
                            return
                        }
                    }
                }
                // First consumer done (the leg closed and drained its
                // streams) settles the group; cancelling tears the rest down.
                await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            // Shutdown — no terminal event.
        } catch {
            coreLog.error("claim buildings: sync failed: \(String(describing: error), privacy: .public)")
            emit(.failed(Self.message(for: error)))
        }
    }

    // MARK: - Queries

    private static func baseQueries(claim: UInt64, player: UInt64) -> [String] {
        [
            "SELECT * FROM building_state WHERE claim_entity_id = \(claim);",
            "SELECT * FROM claim_state WHERE entity_id = \(claim);",
            // Whole table: nickname rows are tiny and change rarely; the
            // relay mirror subscribes it the same way.
            "SELECT * FROM building_nickname_state;",
            "SELECT * FROM passive_craft_state WHERE owner_entity_id = \(player);",
            "SELECT * FROM progressive_action_state WHERE owner_entity_id = \(player);",
        ]
    }

    /// Additive craft subscription for freshly-arrived claim buildings —
    /// the mirror's hexite pattern (a second query set after entity ids
    /// are known), debounced into one Subscribe per arrival burst. Covers
    /// both craft tables plus the game's shared-craft projection (whose
    /// membership decides whether other players' bench crafts render).
    /// Errors are logged, not fatal: the rows simply stop arriving, and
    /// the next building change re-attempts the delta.
    private static func subscribeCrafts(client: SpacetimeDBClient, buildings: Set<UInt64>) {
        Task {
            do {
                var queries: [String] = []
                for id in buildings.sorted() {
                    queries.append("SELECT * FROM passive_craft_state WHERE building_entity_id = \(id);")
                    queries.append("SELECT * FROM progressive_action_state WHERE building_entity_id = \(id);")
                    queries.append("SELECT * FROM public_progressive_action_state WHERE building_entity_id = \(id);")
                }
                coreLog.info("claim buildings: additive craft subscription for \(buildings.count) building(s)")
                _ = try await client.subscribe(queries)
            } catch {
                coreLog.error("claim buildings: additive craft subscribe failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Catalog cache

    static var cacheURL: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bitme-region-building-gamedata.json")
    }

    static func cachedBuildingGamedata(at url: URL = cacheURL) -> BuildingGamedata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BuildingGamedata.self, from: data)
    }

    static func writeBuildingGamedataCache(_ gamedata: BuildingGamedata, at url: URL = cacheURL) {
        guard let data = try? JSONEncoder().encode(gamedata) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Cache-first catalog load: a fresh cache skips the leg's one-offs
    /// entirely; otherwise fetch over the leg and re-cache. An empty
    /// answer is a server-side anomaly, not "no catalogs" — it is never
    /// pinned over a (possibly stale) cache, and a failed fetch serves
    /// whatever cache exists.
    private static func loadGamedata(client: SpacetimeDBClient) async -> BuildingGamedata {
        let cached = cachedBuildingGamedata()
        if let cached, !cached.isStale() {
            coreLog.info("claim buildings: catalogs served from cache (\(cached.buildings.count) buildings, \(cached.recipeNames.count) recipes)")
            return cached
        }
        do {
            async let descTables = client.oneOffQuery("SELECT * FROM building_desc;", timeout: 20)
            async let recipeTables = client.oneOffQuery("SELECT * FROM crafting_recipe_desc;", timeout: 20)
            async let toolTables = client.oneOffQuery("SELECT * FROM tool_type_desc;", timeout: 20)
            async let itemTables = client.oneOffQuery("SELECT * FROM item_desc;", timeout: 20)
            async let cargoTables = client.oneOffQuery("SELECT * FROM cargo_desc;", timeout: 20)

            var buildings: [Int32: BuildingDescInfo] = [:]
            for table in try await descTables where table.tableName == "building_desc" {
                for row in table.rows.rows {
                    if let info = try? RegionGamedataDecoder.buildingDesc(row) {
                        buildings[info.id] = info
                    }
                }
            }
            var toolSkillByType: [Int32: Int32] = [:]
            for table in try await toolTables where table.tableName == "tool_type_desc" {
                for row in table.rows.rows {
                    if let info = try? RegionGamedataDecoder.toolTypeDesc(row) {
                        toolSkillByType[info.id] = info.skillID
                    }
                }
            }
            var recipes: [Int32: String] = [:]
            var recipeSkills: [Int32: Int32] = [:]
            var recipeInputs: [Int32: ItemStackRef] = [:]
            var recipeOutputs: [Int32: ItemStackRef] = [:]
            var recipeActionsRequired: [Int32: Int32] = [:]
            for table in try await recipeTables where table.tableName == "crafting_recipe_desc" {
                for row in table.rows.rows {
                    if let recipe = try? RegionGamedataDecoder.recipe(row) {
                        recipes[recipe.id] = recipe.name
                        recipeSkills[recipe.id] = recipe.skillID
                            ?? recipe.toolTypeID.flatMap { toolSkillByType[$0] }
                        if let input = recipe.input { recipeInputs[recipe.id] = input }
                        if let output = recipe.output { recipeOutputs[recipe.id] = output }
                        if let actions = recipe.actionsRequired {
                            recipeActionsRequired[recipe.id] = actions
                        }
                    }
                }
            }
            // The name catalogs resolve the recipe templates' stack refs —
            // `item_desc` covers Item-typed entries, `cargo_desc` the
            // Cargo-typed ones (package recipes craft cargo).
            var itemNames: [Int32: String] = [:]
            for table in try await itemTables where table.tableName == "item_desc" {
                for row in table.rows.rows {
                    if let entry = try? RegionGamedataDecoder.idName(row) {
                        itemNames[entry.id] = entry.name
                    }
                }
            }
            var cargoNames: [Int32: String] = [:]
            for table in try await cargoTables where table.tableName == "cargo_desc" {
                for row in table.rows.rows {
                    if let entry = try? RegionGamedataDecoder.idName(row) {
                        cargoNames[entry.id] = entry.name
                    }
                }
            }
            coreLog.info("claim buildings: catalogs loaded (\(buildings.count) buildings, \(recipes.count) recipes, \(toolSkillByType.count) tool types, \(itemNames.count) items, \(cargoNames.count) cargo)")
            if buildings.isEmpty && recipes.isEmpty, let cached {
                return cached
            }
            let fresh = BuildingGamedata(
                buildings: buildings, recipeNames: recipes, recipeSkills: recipeSkills,
                recipeInputs: recipeInputs, recipeOutputs: recipeOutputs,
                recipeActionsRequired: recipeActionsRequired,
                itemNames: itemNames, cargoNames: cargoNames, fetchedAt: .now
            )
            if !buildings.isEmpty || !recipes.isEmpty {
                writeBuildingGamedataCache(fresh)
            }
            return fresh
        } catch {
            coreLog.error("claim buildings: catalog fetch failed: \(String(describing: error), privacy: .public); cached=\(cached != nil)")
            return cached ?? BuildingGamedata.empty
        }
    }

    /// The claim-resolution fallback (protocol doc §2): the player's own
    /// `claim_member_state` row over the region leg — used when the relay
    /// never answered the claim at sign-in. Membership is the safe key
    /// (claim names are not unique); a player is normally a member of
    /// exactly one claim, and several rows resolve to the first rather
    /// than guessing by name. Nil = no answer (leg error or not a member).
    static func resolveOwnClaim(client: SpacetimeDBClient, player: UInt64) async -> UInt64? {
        do {
            let tables = try await client.oneOffQuery(
                "SELECT * FROM claim_member_state WHERE player_entity_id = \(player);",
                timeout: 20
            )
            for table in tables where table.tableName == "claim_member_state" {
                for row in table.rows.rows {
                    if let member = try? RegionGamedataDecoder.claimMembership(row),
                       member.playerEntityID == player {
                        return member.claimEntityID
                    }
                }
            }
        } catch {
            coreLog.error("claim buildings: membership lookup failed: \(String(describing: error), privacy: .public)")
        }
        return nil
    }

    // MARK: - Row helpers

    /// Drains one table's batched stream: each `TableEvent` carries the
    /// transaction's full delete/insert arrays for the table. Deletes are
    /// applied before inserts so an update's delete+insert pair lands as
    /// an upsert. The first batch (the subscription's initial snapshot)
    /// logs its row counts at info — the "did we receive the buildings"
    /// signal; later diffs are counted by the caller into the event
    /// buffer's pooled summary log.
    private static func consume<R: BSATNTableWithPrimaryKey>(
        _ stream: AsyncStream<TableEvent>,
        of type: R.Type,
        onChange: @Sendable (R) -> Void,
        onRemove: @Sendable (R.PrimaryKey) -> Void,
        onBatch: @Sendable (_ inserted: Set<R.PrimaryKey>, _ deleted: Set<R.PrimaryKey>) -> Void
    ) async where R.PrimaryKey == UInt64 {
        var firstBatch = true
        for await event in stream {
            guard event.tableName == R.tableName else { continue }
            let changed = event.inserts.compactMap { $0 as? R }
            let removed = event.deletes.compactMap { ($0 as? R)?.primaryKey }
            if firstBatch {
                coreLog.info("claim buildings: \(R.tableName, privacy: .public) snapshot: \(changed.count) rows, \(removed.count) deletes")
                firstBatch = false
            }
            for id in removed {
                onRemove(id)
            }
            changed.forEach(onChange)
            onBatch(Set(changed.map(\.primaryKey)), Set(removed))
        }
    }

    private static func message(for error: Error) -> String {
        if let reduced = error as? SpacetimeDBError {
            return String(describing: reduced)
        }
        return "the region sync stopped (\(String(describing: error)))"
    }
}
