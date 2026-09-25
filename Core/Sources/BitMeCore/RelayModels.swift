import Foundation

// Codable encodings of the relay Bit-Me API (docs/api.md).
//
// Wire conventions that shape these types:
// - Every entity id is a JSON *string* (upstream u64s exceed JS 2^53) → String.
// - `*_ms` / `*_at_ms` fields are unix milliseconds; buff `start_timestamp` /
//   `duration` are unix *seconds*; `stamina.last_decrease_at` is RFC 3339.
// - Present-but-null means "unknown / not applicable"; every documented field
//   is always present on the wire, so optionals here mirror the API doc.

// MARK: - GET /bitme/resolve

public struct ResolveResponse: Codable, Equatable, Sendable {
    public let found: Bool
    public let entityID: String
    public let username: String
    public let usernameLowercase: String
    public let identity: String?
    public let regionID: Int?
    public let regionName: String?
    public let host: String?
    public let module: String?
    public let signedIn: Bool?

    enum CodingKeys: String, CodingKey {
        case found
        case entityID = "entity_id"
        case username
        case usernameLowercase = "username_lowercase"
        case identity
        case regionID = "region_id"
        case regionName = "region_name"
        case host
        case module
        case signedIn = "signed_in"
    }
}

// MARK: - GET /bitme/session/:entity_id

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let found: Bool
    public let playerEntityID: String
    public let username: String?
    public let signedIn: Bool?
    public let region: Int
    public let position: Position?
    public let claim: Claim?
    public let stamina: Stamina?
    public let buffs: [Buff]
    public let actions: [PlayerAction]
    public let target: Target?
    public let activitySpawns: [ActivitySpawn]
    public let serverTimeMs: Int64

    enum CodingKeys: String, CodingKey {
        case found
        case playerEntityID = "player_entity_id"
        case username
        case signedIn = "signed_in"
        case region
        case position
        case claim
        case stamina
        case buffs
        case actions
        case target
        case activitySpawns = "activity_spawns"
        case serverTimeMs = "server_time_ms"
    }
}

public struct Position: Codable, Equatable, Sendable {
    public let worldX: Double
    public let worldZ: Double
    public let tileX: Int
    public let tileZ: Int
    public let destinationWorldX: Double
    public let destinationWorldZ: Double
    /// 1 = overworld; > 1 = building/dungeon interior (claim is not resolved).
    public let dimension: Int
    public let isWalking: Bool
    public let timestampMs: Int64
    public let ageMs: Int64

    enum CodingKeys: String, CodingKey {
        case worldX = "world_x"
        case worldZ = "world_z"
        case tileX = "tile_x"
        case tileZ = "tile_z"
        case destinationWorldX = "destination_world_x"
        case destinationWorldZ = "destination_world_z"
        case dimension
        case isWalking = "is_walking"
        case timestampMs = "timestamp_ms"
        case ageMs = "age_ms"
    }
}

public struct Claim: Codable, Equatable, Sendable {
    public let entityID: String
    public let name: String
    public let ownerPlayerEntityID: String
    public let neutral: Bool

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case name
        case ownerPlayerEntityID = "owner_player_entity_id"
        case neutral
    }
}

public struct Stamina: Codable, Equatable, Sendable {
    public let current: Double
    public let max: Double
    public let maxHealth: Double
    /// RFC 3339, e.g. "2026-09-05T17:14:52.000Z". Null when never decreased.
    public let lastDecreaseAt: String?

    enum CodingKeys: String, CodingKey {
        case current
        case max
        case maxHealth = "max_health"
        case lastDecreaseAt = "last_decrease_at"
    }
}

/// Live buffs only (zeroed placeholder entries are filtered server-side).
/// Expired entries may linger upstream — check the countdown, not presence.
public struct Buff: Codable, Equatable, Sendable {
    public let buffID: Int
    /// Unix seconds.
    public let startTimestamp: Int64
    /// Unix seconds.
    public let duration: Int64
    public let values: [Double]

    enum CodingKeys: String, CodingKey {
        case buffID = "buff_id"
        case startTimestamp = "start_timestamp"
        case duration
        case values
    }

    public var expiresAtUnixSec: Int64 { startTimestamp + duration }
}

public struct PlayerAction: Codable, Equatable, Sendable {
    public let autoID: String
    /// "None" | "Attack" | "Extract" | "Craft" | "Build" | "Terraform" | …
    public let actionType: String
    /// "Base" | "UpperBody"
    public let layer: String
    public let startTimeMs: Int64
    public let durationMs: Int64
    public let endsAtMs: Int64
    public let targetEntityID: String?
    public let recipeID: Int?
    public let lastActionResult: String
    public let clientCancel: Bool

    enum CodingKeys: String, CodingKey {
        case autoID = "auto_id"
        case actionType = "action_type"
        case layer
        case startTimeMs = "start_time_ms"
        case durationMs = "duration_ms"
        case endsAtMs = "ends_at_ms"
        case targetEntityID = "target_entity_id"
        case recipeID = "recipe_id"
        case lastActionResult = "last_action_result"
        case clientCancel = "client_cancel"
    }
}

/// The acted-on entity, enriched. Primary target = Extract target, else the
/// Base-layer target (e.g. a crafting station, which has resourceID == nil).
public struct Target: Codable, Equatable, Sendable {
    public let entityID: String
    public let resourceID: Int?
    public let name: String?
    /// Tracked server-side only while a session polls; null right after targeting.
    public let health: Double?
    public let maxHealth: Double?
    public let despawnTimeSecs: Double?
    public let respawnTimeSecs: Double?
    /// Server-authoritative end of the target's current growth stage (relay
    /// unix ms): the exact clock the in-game target frame counts down for
    /// growth-stage resources (T2 event berry bushes: 600 s Bountiful,
    /// 30 s Citric). Null when the entity has no live growth timer.
    public let growthEndsAtMs: Int64?
    public let location: TileLocation?

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case resourceID = "resource_id"
        case name
        case health
        case maxHealth = "max_health"
        case despawnTimeSecs = "despawn_time_secs"
        case respawnTimeSecs = "respawn_time_secs"
        case growthEndsAtMs = "growth_ends_at_ms"
        case location
    }
}

/// Watched spawns in the player's claim/wilderness scope: destroy-yield
/// chains (Withering → Bountiful, depleted ore, baited schools) and the
/// Citric Giant berry bushes. This is the citric-detection signal.
public struct ActivitySpawn: Codable, Equatable, Sendable {
    public let entityID: String
    public let resourceID: Int
    public let name: String?
    /// Non-null means someone is already harvesting it.
    public let health: Double?
    public let maxHealth: Double?
    public let location: TileLocation?
    public let spawnedAtMs: Int64
    /// spawned_at_ms + despawn_time when gamedata has a timer; else null.
    public let expiresAtMs: Int64?
    /// Server-authoritative growth-stage end (relay unix ms) — the exact
    /// despawn/wither/transition clock for growth-stage resources; else null.
    public let growthEndsAtMs: Int64?

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case resourceID = "resource_id"
        case name
        case health
        case maxHealth = "max_health"
        case location
        case spawnedAtMs = "spawned_at_ms"
        case expiresAtMs = "expires_at_ms"
        case growthEndsAtMs = "growth_ends_at_ms"
    }

    /// Best known stage-end clock: the server-authoritative growth timer
    /// when present, else the gamedata despawn estimate.
    public var effectiveExpiresAtMs: Int64? { growthEndsAtMs ?? expiresAtMs }
}

public struct TileLocation: Codable, Equatable, Sendable {
    public let tileX: Int
    public let tileZ: Int

    enum CodingKeys: String, CodingKey {
        case tileX = "tile_x"
        case tileZ = "tile_z"
    }
}

// MARK: - GET /bitme/region/:region_id/resource-dictionary

/// Per-region dictionary mapping the BMR1/BMD1 tile-word dictionary index
/// (bits 0–9) to resource identity. Rotates as the region's resource mix
/// changes — windows and deltas carry the `dict_version` they were built
/// against; a mismatch means re-fetch before trusting indices.
public struct ResourceDictionary: Codable, Equatable, Sendable {
    public let ready: Bool
    public let region: Int
    public let dictVersion: Int
    public let entries: [Entry]

    enum CodingKeys: String, CodingKey {
        case ready
        case region
        case dictVersion = "dict_version"
        case entries
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let index: Int
        public let name: String?
        /// False / absent on paving entries.
        public let harvestable: Bool?
        public let paving: Bool?
        /// Null on paving entries (they carry `paving_type_id` instead).
        public let resourceID: Int?
        public let pavingTypeID: Int?
        public let maxHealth: Double?
        public let respawnTimeSecs: Double?
        public let despawnTimeSecs: Double?

        enum CodingKeys: String, CodingKey {
            case index
            case name
            case harvestable
            case paving
            case resourceID = "resource_id"
            case pavingTypeID = "paving_type_id"
            case maxHealth = "max_health"
            case respawnTimeSecs = "respawn_time_secs"
            case despawnTimeSecs = "despawn_time_secs"
        }

        public init(
            index: Int, name: String?, harvestable: Bool?, paving: Bool?,
            resourceID: Int?, pavingTypeID: Int?, maxHealth: Double?,
            respawnTimeSecs: Double?, despawnTimeSecs: Double?
        ) {
            self.index = index
            self.name = name
            self.harvestable = harvestable
            self.paving = paving
            self.resourceID = resourceID
            self.pavingTypeID = pavingTypeID
            self.maxHealth = maxHealth
            self.respawnTimeSecs = respawnTimeSecs
            self.despawnTimeSecs = despawnTimeSecs
        }
    }

    public init(ready: Bool, region: Int, dictVersion: Int, entries: [Entry]) {
        self.ready = ready
        self.region = region
        self.dictVersion = dictVersion
        self.entries = entries
    }

    /// Index → entry lookup (indices are unique within a dictionary).
    public var entryByIndex: [Int: Entry] {
        Dictionary(entries.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - GET /cache-health

public struct CacheHealth: Codable, Sendable {
    public let ready: Bool
}
