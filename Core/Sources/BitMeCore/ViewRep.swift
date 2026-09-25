import Foundation

/// The pure projection of machine state the UI (and CLI) subscribe to.
/// Screen-shaped, `Equatable` for change-detection, anchors in relay-clock
/// milliseconds so renderers interpolate countdowns locally.
public enum ViewRep: Equatable, Sendable, Codable {
    case onboarding(Onboarding)
    case bitCraftSignIn(BitCraftSignIn)
    case session(Session)

    public struct Onboarding: Equatable, Sendable, Codable {
        public var isResolving: Bool
        public var lookingUpName: String?
        public var error: String?
        /// The name resolved but the character is offline — usable hint.
        public var resolvedOfflineHint: Bool
        /// Email of the signed-in BitCraft account, when there is one.
        public var bitCraftAccountEmail: String?
    }

    /// The BitCraft account sign-in screen: emailed access code login
    /// (email → code → SpacetimeDB token).
    public struct BitCraftSignIn: Equatable, Sendable, Codable {
        public enum Phase: Equatable, Sendable, Codable {
            /// Email entry.
            case idle
            /// The code request is in flight.
            case requestingCode
            /// The code was emailed to `email`; the user is typing it.
            case awaitingCode(email: String)
            /// The code was submitted; authentication is in flight.
            case authenticating(email: String)
        }

        public var phase: Phase
        public var error: String?
    }

    public struct Session: Equatable, Sendable, Codable {
        public enum Connection: String, Equatable, Sendable, Codable {
            case ok
            case degraded
            case down
        }

        public struct Resource: Equatable, Sendable, Codable {
            public var name: String
            /// 0...1, nil while health is not yet tracked.
            public var harvestedPct: Double?
            /// Absolute relay-clock ms when the estimated depletion lands
            /// (health × learned pacing); nil until pacing is known.
            public var depletesAtMs: Double?
            /// Absolute relay-clock ms when a spawn-window despawn lands.
            public var windowEndsAtMs: Double?
        }

        public struct Citric: Equatable, Sendable, Codable {
            public var entityID: String
            public var name: String
            public var spawnedAtMs: Double
            public var expiresAtMs: Double
            public var isNewlySpawned: Bool
        }

        public struct Stamina: Equatable, Sendable, Codable {
            public var current: Double
            public var projected: Double
            public var max: Double
            public var pct: Double
            /// Relay-clock ms when `projected` reaches `max`; nil when there
            /// is no regen anchor or it is already full.
            public var fullAtMs: Double?
        }

        public struct LiveBuff: Equatable, Sendable, Codable {
            public var id: Int
            public var expiresAtSec: Int64
            /// buff_desc display name; nil when gamedata lacks this id.
            public var name: String?
            public var stats: [BuffStat]
        }

        /// An action in progress (`server_time_ms < ends_at_ms`) — one per
        /// layer, Base first. Feeds the Live Activity and the map HUD.
        public struct RunningAction: Equatable, Sendable, Codable {
            public var actionType: String
            /// "Base" or "UpperBody".
            public var layer: String
            /// Session target's name when it is this action's target.
            public var targetName: String?
            /// Relay-clock ms.
            public var startsAtMs: Double
            public var endsAtMs: Double
            public var durationMs: Double
        }

        public struct Food: Equatable, Sendable, Codable {
            /// False while gamedata has not loaded — classification unknown.
            public var configured: Bool
            public var active: Bool
            public var expiresAtSec: Int64?
            public var liveBuffs: [LiveBuff]
        }

        /// Live resource map around the player (relay §6–7 endpoints):
        /// nearby-resource counts from the BMR1 window plus the spawn /
        /// despawn feed maintained from the change stream. A compact,
        /// renderer-friendly projection — the raw tile words stay in state.
        public struct ResourceMap: Equatable, Sendable, Codable {
            public enum StreamStatus: String, Equatable, Sendable, Codable {
                case off
                case connecting
                case live
                case reconnecting
            }

            public struct NearbyResource: Equatable, Sendable, Codable {
                public var resourceID: Int?
                /// nil while the region dictionary has not loaded yet.
                public var name: String?
                public var count: Int
                public var harvestable: Bool?
            }

            public struct FeedEvent: Equatable, Sendable, Codable {
                public var resourceID: Int?
                /// nil while the region dictionary has not loaded yet.
                public var name: String?
                public var tileX: Int
                public var tileZ: Int
                /// False = despawned / the tile emptied.
                public var spawned: Bool
                /// Relay-clock ms (best effort — see the stream loop).
                public var atMs: Double
            }

            public var region: Int?
            /// Top-left tile of the window (`anchor − width/2`).
            public var originTileX: Int?
            public var originTileZ: Int?
            public var width: Int?
            /// Window center the stream subscription is anchored to.
            public var anchorTileX: Int?
            public var anchorTileZ: Int?
            /// Populated resource tiles in the window (nonzero, non-paving).
            public var populatedTiles: Int
            public var stream: StreamStatus
            /// Resource ids aggregated from the window tally, count-sorted.
            public var nearby: [NearbyResource]
            /// Newest-first spawn/despawn events (capped for rendering).
            public var feed: [FeedEvent]

            static let empty = ResourceMap(
                region: nil, originTileX: nil, originTileZ: nil, width: nil,
                anchorTileX: nil, anchorTileZ: nil, populatedTiles: 0,
                stream: .off, nearby: [], feed: []
            )
        }

        public var username: String?
        public var entityID: String?
        public var region: Int?
        /// Email of the signed-in BitCraft account, when there is one —
        /// drives the session header's account entry.
        public var bitCraftAccountEmail: String?
        public var signedIn: Bool?
        public var connection: Connection
        public var claimName: String?
        /// Relay clock at snapshot time — the interpolation anchor.
        public var nowMs: Double?
        public var bush: Resource?
        public var citric: Citric?
        public var stamina: Stamina?
        public var food: Food
        public var actions: [RunningAction]
        public var resourceMap: ResourceMap
    }

    static func from(persistent: PersistentState, ephemeral: EphemeralState) -> ViewRep {
        if ephemeral.signInVisible {
            let phase: BitCraftSignIn.Phase
            switch ephemeral.signIn.phase {
            case .idle: phase = .idle
            case .requestingCode: phase = .requestingCode
            case .awaitingCode(let email): phase = .awaitingCode(email: email)
            case .authenticating(let email, _): phase = .authenticating(email: email)
            }
            return .bitCraftSignIn(BitCraftSignIn(
                phase: phase, error: ephemeral.signIn.error
            ))
        }
        guard persistent.identity != nil else {
            let resolving: String? = {
                if case .resolving(let name) = ephemeral.onboarding { return name }
                return nil
            }()
            return .onboarding(Onboarding(
                isResolving: resolving != nil,
                lookingUpName: resolving,
                error: ephemeral.resolveError,
                resolvedOfflineHint: ephemeral.resolvedOfflineHint,
                bitCraftAccountEmail: persistent.bitCraftAccount?.email
            ))
        }

        let config = GameConfig.shared
        let nowMs = ephemeral.session?.snapshot.map { Double($0.serverTimeMs) }

        // -- bush countdown ------------------------------------------------
        var bush: Session.Resource?
        if let snapshot = ephemeral.session?.snapshot,
           let target = snapshot.target, target.resourceID != nil {
            let now = nowMs ?? 0
            let depleteIn = HarvestStateEngine.depletionCountdownMs(
                target: target, msPerHealthPoint: ephemeral.session?.pacing.msPerHealthPoint
            )
            var windowEndsAtMs: Double?
            if let windowIn = HarvestStateEngine.spawnWindowRemainingMs(
                in: snapshot,
                targetEntityID: target.entityID,
                resourceID: target.resourceID ?? -1,
                nowMs: now
            ) {
                windowEndsAtMs = now + windowIn
            } else if let growthEndsMs = target.growthEndsAtMs, growthEndsMs > 0 {
                // Target carries its own growth-stage clock but no matching
                // spawn entry (e.g. outside the watched-spawn scope).
                windowEndsAtMs = Double(growthEndsMs)
            }
            bush = Session.Resource(
                name: target.name ?? "Unknown resource",
                harvestedPct: {
                    guard let health = target.health, let max = target.maxHealth, max > 0 else { return nil }
                    return HarvestStateEngine.clamp01(1 - health / max)
                }(),
                depletesAtMs: depleteIn.map { now + $0 },
                windowEndsAtMs: windowEndsAtMs
            )
        }

        // -- citric ---------------------------------------------------------
        let citric: Session.Citric?
        if let snapshot = ephemeral.session?.snapshot {
            citric = HarvestStateEngine.detectCitric(
                previous: ephemeral.session?.previous,
                current: snapshot,
                citricResourceIDs: config.citricResourceIDs,
                fallbackWindowMs: config.citricFallbackWindowMs,
                nowMs: nowMs ?? 0
            ).map {
                Session.Citric(
                    entityID: $0.entityID,
                    name: $0.resourceName,
                    spawnedAtMs: $0.spawnedAtMs,
                    expiresAtMs: $0.expiresAtMs,
                    isNewlySpawned: $0.isNewlySpawned
                )
            }
        } else {
            citric = nil
        }

        // -- stamina / food ---------------------------------------------------
        let stamina: Session.Stamina?
        if let snapshot = ephemeral.session?.snapshot {
            stamina = HarvestStateEngine.staminaProjection(
                in: snapshot, rules: config.regen, nowMs: nowMs ?? 0
            ).map {
                Session.Stamina(
                    current: $0.current, projected: $0.projected,
                    max: $0.max, pct: $0.pct, fullAtMs: $0.fullAtMs
                )
            }
        } else {
            stamina = nil
        }

        let food: Session.Food
        if let snapshot = ephemeral.session?.snapshot {
            let foodBuffIDs = ephemeral.gamedata?.foodBuffIDs ?? []
            let state = HarvestStateEngine.foodBuffState(
                in: snapshot, foodBuffIDs: foodBuffIDs, nowMs: nowMs ?? 0
            )
            let live = snapshot.buffs
                .filter { Double($0.expiresAtUnixSec) * 1_000 > (nowMs ?? 0) }
                .sorted { $0.expiresAtUnixSec > $1.expiresAtUnixSec }
                .prefix(4)
                .map { buff in
                    let info = ephemeral.gamedata?.buffs[buff.buffID]
                    return Session.LiveBuff(
                        id: buff.buffID,
                        expiresAtSec: buff.expiresAtUnixSec,
                        name: info?.name,
                        stats: BuffStat.sortedForDisplay(info?.stats ?? [])
                    )
                }
            food = Session.Food(
                configured: ephemeral.gamedata != nil,
                active: state.active,
                expiresAtSec: state.expiresAtUnixSec,
                liveBuffs: live
            )
        } else {
            food = Session.Food(configured: ephemeral.gamedata != nil, active: false, expiresAtSec: nil, liveBuffs: [])
        }

        // -- running actions --------------------------------------------------
        let actions: [Session.RunningAction]
        if let snapshot = ephemeral.session?.snapshot {
            let now = Double(snapshot.serverTimeMs)
            actions = snapshot.actions
                .filter { $0.durationMs > 0 && Double($0.endsAtMs) > now }
                .sorted { lhs, rhs in
                    if lhs.layer == rhs.layer { return lhs.layer < rhs.layer }
                    return lhs.layer == "Base" // Base layer first
                }
                .map { action in
                    Session.RunningAction(
                        actionType: action.actionType,
                        layer: action.layer,
                        targetName: action.targetEntityID.flatMap { targetID in
                            snapshot.target?.entityID == targetID ? snapshot.target?.name : nil
                        },
                        startsAtMs: Double(action.startTimeMs),
                        endsAtMs: Double(action.endsAtMs),
                        durationMs: Double(action.durationMs)
                    )
                }
        } else {
            actions = []
        }

        return .session(Session(
            username: persistent.identity?.username,
            entityID: persistent.identity?.entityID,
            region: ephemeral.session?.snapshot?.region ?? persistent.identity?.regionID,
            bitCraftAccountEmail: persistent.bitCraftAccount?.email,
            signedIn: ephemeral.session?.snapshot?.signedIn,
            connection: (ephemeral.session?.connection).map { rep in
                switch rep {
                case .ok: return .ok
                case .degraded: return .degraded
                case .down: return .down
                }
            } ?? .ok,
            claimName: ephemeral.session?.snapshot?.claim?.name,
            nowMs: nowMs,
            bush: bush,
            citric: citric,
            stamina: stamina,
            food: food,
            actions: actions,
            resourceMap: resourceMap(from: ephemeral.session)
        ))
    }

    /// Projects the session's resource-map state: aggregates the tile tally
    /// through the dictionary into per-resource nearby counts, and resolves
    /// feed entries' dictionary indices into names. Indices missing from the
    /// dictionary (rotation race) are dropped — the refetch converges them.
    private static func resourceMap(from session: EphemeralState.Session?) -> Session.ResourceMap {
        guard let session else { return .empty }
        let map = session.resourceMap
        let entries = map.dictionary?.entryByIndex ?? [:]

        struct Aggregate {
            var count = 0
            var resourceID: Int?
            var name: String?
            var harvestable: Bool?
        }
        var byResource: [Int: Aggregate] = [:]
        for (index, count) in map.tally where count > 0 {
            guard let entry = entries[index], entry.paving != true else { continue }
            // Dictionary indices repeat per resource id; entries without a
            // resource id still count, grouped per-index.
            let key = entry.resourceID ?? -(1_000_000 + index)
            var aggregate = byResource[key] ?? Aggregate()
            aggregate.count += count
            if aggregate.name == nil {
                aggregate.resourceID = entry.resourceID
                aggregate.name = entry.name
                aggregate.harvestable = entry.harvestable
            }
            byResource[key] = aggregate
        }
        let nearby = byResource.values
            .sorted {
                $0.count != $1.count ? $0.count > $1.count
                    : ($0.name ?? "") < ($1.name ?? "")
            }
            .prefix(12)
            .map {
                Session.ResourceMap.NearbyResource(
                    resourceID: $0.resourceID, name: $0.name,
                    count: $0.count, harvestable: $0.harvestable
                )
            }

        let feed = map.feed.prefix(10).map { entry in
            let resolved = entries[entry.dictIndex]
            return Session.ResourceMap.FeedEvent(
                resourceID: resolved?.resourceID,
                name: resolved?.name,
                tileX: entry.tileX,
                tileZ: entry.tileZ,
                spawned: entry.spawned,
                atMs: entry.atMs
            )
        }

        let stream: Session.ResourceMap.StreamStatus
        switch map.streamStatus {
        case .off: stream = .off
        case .connecting: stream = .connecting
        case .live: stream = .live
        case .reconnecting: stream = .reconnecting
        }
        return Session.ResourceMap(
            region: map.window?.region,
            originTileX: map.window?.originX,
            originTileZ: map.window?.originZ,
            width: map.window?.width,
            anchorTileX: map.anchorX,
            anchorTileZ: map.anchorZ,
            populatedTiles: map.populatedTiles,
            stream: stream,
            nearby: Array(nearby),
            feed: Array(feed)
        )
    }
}
