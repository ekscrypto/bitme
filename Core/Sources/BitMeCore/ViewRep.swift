import Foundation

/// The pure projection of machine state the UI (and CLI) subscribe to.
/// Screen-shaped, `Equatable` for change-detection, anchors in relay-clock
/// milliseconds so renderers interpolate countdowns locally.
public enum ViewRep: Equatable, Sendable, Codable {
    case onboarding(Onboarding)
    case session(Session)

    public struct Onboarding: Equatable, Sendable, Codable {
        public var isResolving: Bool
        public var lookingUpName: String?
        public var error: String?
        /// The name resolved but the character is offline — usable hint.
        public var resolvedOfflineHint: Bool
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
        }

        public struct Food: Equatable, Sendable, Codable {
            /// False while gamedata has not loaded — classification unknown.
            public var configured: Bool
            public var active: Bool
            public var expiresAtSec: Int64?
            public var liveBuffs: [LiveBuff]
        }

        public var username: String?
        public var entityID: String?
        public var region: Int?
        public var signedIn: Bool?
        public var connection: Connection
        public var claimName: String?
        /// Relay clock at snapshot time — the interpolation anchor.
        public var nowMs: Double?
        public var bush: Resource?
        public var citric: Citric?
        public var stamina: Stamina?
        public var food: Food
    }

    static func from(persistent: PersistentState, ephemeral: EphemeralState) -> ViewRep {
        guard persistent.identity != nil else {
            let resolving: String? = {
                if case .resolving(let name) = ephemeral.onboarding { return name }
                return nil
            }()
            return .onboarding(Onboarding(
                isResolving: resolving != nil,
                lookingUpName: resolving,
                error: ephemeral.resolveError,
                resolvedOfflineHint: ephemeral.resolvedOfflineHint
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
                in: snapshot, resourceID: target.resourceID ?? -1, nowMs: now
            ) {
                windowEndsAtMs = now + windowIn
            } else if let despawn = target.despawnTimeSecs, despawn > 0 {
                // No live spawn entry — anchor from passthrough gamedata.
                windowEndsAtMs = now + despawn * 1_000
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
                .map { Session.LiveBuff(id: $0.buffID, expiresAtSec: $0.expiresAtUnixSec) }
            food = Session.Food(
                configured: ephemeral.gamedata != nil,
                active: state.active,
                expiresAtSec: state.expiresAtUnixSec,
                liveBuffs: live
            )
        } else {
            food = Session.Food(configured: ephemeral.gamedata != nil, active: false, expiresAtSec: nil, liveBuffs: [])
        }

        return .session(Session(
            username: persistent.identity?.username,
            entityID: persistent.identity?.entityID,
            region: ephemeral.session?.snapshot?.region ?? persistent.identity?.regionID,
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
            food: food
        ))
    }
}
