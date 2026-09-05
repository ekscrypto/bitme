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

struct ResolveResponse: Codable, Equatable, Sendable {
    let found: Bool
    let entityID: String
    let username: String
    let usernameLowercase: String
    let identity: String?
    let regionID: Int?
    let regionName: String?
    let host: String?
    let module: String?
    let signedIn: Bool?

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

struct SessionSnapshot: Codable, Equatable, Sendable {
    let found: Bool
    let playerEntityID: String
    let username: String?
    let signedIn: Bool?
    let region: Int
    let position: Position?
    let claim: Claim?
    let stamina: Stamina?
    let buffs: [Buff]
    let actions: [PlayerAction]
    let target: Target?
    let activitySpawns: [ActivitySpawn]
    let serverTimeMs: Int64

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

struct Position: Codable, Equatable, Sendable {
    let worldX: Double
    let worldZ: Double
    let tileX: Int
    let tileZ: Int
    let destinationWorldX: Double
    let destinationWorldZ: Double
    /// 1 = overworld; > 1 = building/dungeon interior (claim is not resolved).
    let dimension: Int
    let isWalking: Bool
    let timestampMs: Int64
    let ageMs: Int64

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

struct Claim: Codable, Equatable, Sendable {
    let entityID: String
    let name: String
    let ownerPlayerEntityID: String
    let neutral: Bool

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case name
        case ownerPlayerEntityID = "owner_player_entity_id"
        case neutral
    }
}

struct Stamina: Codable, Equatable, Sendable {
    let current: Double
    let max: Double
    let maxHealth: Double
    /// RFC 3339, e.g. "2026-09-05T17:14:52.000Z". Null when never decreased.
    let lastDecreaseAt: String?

    enum CodingKeys: String, CodingKey {
        case current
        case max
        case maxHealth = "max_health"
        case lastDecreaseAt = "last_decrease_at"
    }
}

/// Live buffs only (zeroed placeholder entries are filtered server-side).
/// Expired entries may linger upstream — check the countdown, not presence.
struct Buff: Codable, Equatable, Sendable {
    let buffID: Int
    /// Unix seconds.
    let startTimestamp: Int64
    /// Unix seconds.
    let duration: Int64
    let values: [Double]

    enum CodingKeys: String, CodingKey {
        case buffID = "buff_id"
        case startTimestamp = "start_timestamp"
        case duration
        case values
    }

    var expiresAtUnixSec: Int64 { startTimestamp + duration }
}

struct PlayerAction: Codable, Equatable, Sendable {
    let autoID: String
    /// "None" | "Attack" | "Extract" | "Craft" | "Build" | "Terraform" | …
    let actionType: String
    /// "Base" | "UpperBody"
    let layer: String
    let startTimeMs: Int64
    let durationMs: Int64
    let endsAtMs: Int64
    let targetEntityID: String?
    let recipeID: Int?
    let lastActionResult: String
    let clientCancel: Bool

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
struct Target: Codable, Equatable, Sendable {
    let entityID: String
    let resourceID: Int?
    let name: String?
    /// Tracked server-side only while a session polls; null right after targeting.
    let health: Double?
    let maxHealth: Double?
    let despawnTimeSecs: Double?
    let respawnTimeSecs: Double?
    let location: TileLocation?

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case resourceID = "resource_id"
        case name
        case health
        case maxHealth = "max_health"
        case despawnTimeSecs = "despawn_time_secs"
        case respawnTimeSecs = "respawn_time_secs"
        case location
    }
}

/// Watched spawns in the player's claim/wilderness scope: destroy-yield
/// chains (Withering → Bountiful, depleted ore, baited schools) and the
/// Citric Giant berry bushes. This is the citric-detection signal.
struct ActivitySpawn: Codable, Equatable, Sendable {
    let entityID: String
    let resourceID: Int
    let name: String?
    /// Non-null means someone is already harvesting it.
    let health: Double?
    let maxHealth: Double?
    let location: TileLocation?
    let spawnedAtMs: Int64
    /// spawned_at_ms + despawn_time when gamedata has a timer; else null.
    let expiresAtMs: Int64?

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case resourceID = "resource_id"
        case name
        case health
        case maxHealth = "max_health"
        case location
        case spawnedAtMs = "spawned_at_ms"
        case expiresAtMs = "expires_at_ms"
    }
}

struct TileLocation: Codable, Equatable, Sendable {
    let tileX: Int
    let tileZ: Int

    enum CodingKeys: String, CodingKey {
        case tileX = "tile_x"
        case tileZ = "tile_z"
    }
}

// MARK: - GET /cache-health

struct CacheHealth: Codable, Sendable {
    let ready: Bool
}
