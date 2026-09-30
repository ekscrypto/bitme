import Foundation
import BSATN
import SpacetimeDB

// Region-database rows for the player-vitals subscription and the craft
// driver (Pocket Crafter). Field order is pinned to the game module's
// schema — declaration order verified 2026-09-28 against
// `bitcraft-mats/bitjita-schema-region.json` (digest companions) and the
// captured region leg (`tools/tap/captures/2026-09-28_00-24-16`,
// conn-02; the desktop client holds exactly these as own-row equality
// subscriptions). Decoders read fields in declaration order and may stop
// once everything needed is consumed — trailing fields stay unread.

// MARK: - Vitals rows

/// `stamina_state` — the player's stamina pool.
struct StaminaRow: BSATNTableWithPrimaryKey, Equatable {
    static let tableName = "stamina_state"

    let entityID: UInt64
    /// Last server-side decrease, microseconds since the Unix epoch.
    let lastDecreaseAtMicros: Int64
    let stamina: Float

    var primaryKey: UInt64 { entityID }

    init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        lastDecreaseAtMicros = try reader.read() as Int64
        stamina = try reader.read() as Float
    }

    init(entityID: UInt64, lastDecreaseAtMicros: Int64, stamina: Float) {
        self.entityID = entityID
        self.lastDecreaseAtMicros = lastDecreaseAtMicros
        self.stamina = stamina
    }
}

/// `health_state` — the player's health pool.
struct HealthRow: BSATNTableWithPrimaryKey, Equatable {
    static let tableName = "health_state"

    let entityID: UInt64
    /// Last server-side decrease, microseconds since the Unix epoch.
    let lastDecreaseAtMicros: Int64
    let health: Float
    let diedTimestamp: Int32

    var primaryKey: UInt64 { entityID }

    init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        lastDecreaseAtMicros = try reader.read() as Int64
        health = try reader.read() as Float
        diedTimestamp = try reader.read() as Int32
    }

    init(entityID: UInt64, lastDecreaseAtMicros: Int64, health: Float, diedTimestamp: Int32) {
        self.entityID = entityID
        self.lastDecreaseAtMicros = lastDecreaseAtMicros
        self.health = health
        self.diedTimestamp = diedTimestamp
    }
}

/// `teleportation_energy_state` — waystone teleport energy.
struct TeleportEnergyRow: BSATNTableWithPrimaryKey, Equatable {
    static let tableName = "teleportation_energy_state"

    let entityID: UInt64
    let energy: Float

    var primaryKey: UInt64 { entityID }

    init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        energy = try reader.read() as Float
    }

    init(entityID: UInt64, energy: Float) {
        self.entityID = entityID
        self.energy = energy
    }
}

/// `satiation_state` — the food/hunger pool ("food energy").
struct SatiationRow: BSATNTableWithPrimaryKey, Equatable {
    static let tableName = "satiation_state"

    let entityID: UInt64
    let satiation: Float

    var primaryKey: UInt64 { entityID }

    init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        satiation = try reader.read() as Float
    }

    init(entityID: UInt64, satiation: Float) {
        self.entityID = entityID
        self.satiation = satiation
    }
}

/// `character_stats_state` — the server-materialized stat vector: every
/// bonus source (equipment, buffs, mount, knowledges) already folded in by
/// the game (`PlayerState::collect_stats_with_uncommited_buffs`), so the
/// values the craft cooldown divides are exactly these. `values[i]` is
/// stat `i` — `CharacterStatIndex` below (schema typespace declaration
/// order; the captured row carries more elements than today's enum, so
/// accessors bounds-check).
struct CharacterStatsRow: BSATNTableWithPrimaryKey, Equatable {
    static let tableName = "character_stats_state"

    let entityID: UInt64
    let values: [Float]

    var primaryKey: UInt64 { entityID }

    init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        values = try reader.readTypedArray { try reader.read() as Float }
    }

    init(entityID: UInt64, values: [Float]) {
        self.entityID = entityID
        self.values = values
    }

    func stat(_ index: Int) -> Float? {
        guard index >= 0, index < values.count else { return nil }
        return values[index]
    }
}

/// `CharacterStatType` discriminants the app reads — declaration order in
/// the schema typespace (live-verified 2026-09-28; the enum continues past
/// `ConstructionPower` with the per-skill crit stats, which is why
/// `values` can outgrow this list). After a game update, re-pin per the
/// bsatn-schema-check skill before trusting the offsets.
enum CharacterStatIndex {
    static let maxHealth = 0
    static let maxStamina = 1
    static let movementMultiplier = 4
    static let craftingSpeed = 15
    static let gatheringSpeed = 16
    static let maxSatiation = 19
    static let maxTeleportationEnergy = 49

    /// The per-skill speed stat for a `skill_desc` skill id
    /// (2 Forestry … 13 Cooking, 14 Foraging): ForestrySpeed=21 …
    /// CookingSpeed=32, ForagingSpeed=33 — i.e. `skillID + 19`.
    static func skillSpeed(skillID: Int32) -> Int? {
        guard skillID >= 2, skillID <= 14 else { return nil }
        return Int(skillID) + 19
    }
}

// MARK: - Action & position rows

/// `player_action_state.action_type` — u8 declaration-order tags
/// (BitCraftPublic `messages/components.rs`). Only the kinds the banner
/// names are modeled; unknown tags pass through as `.other` so a game
/// update degrades to "Idle" instead of a decode crash.
public enum PlayerActionKind: UInt8, Equatable, Sendable {
    case none = 0
    case extract = 4
    case climb = 18
    case craft = 20
    case playerMove = 22
    case other = 255

    public init(raw: UInt8) {
        self = PlayerActionKind(rawValue: raw) ?? .other
    }

    /// The banner's activity label.
    public var displayName: String {
        switch self {
        case .extract: "Gathering"
        case .climb: "Climbing"
        case .craft: "Crafting"
        case .playerMove: "Walking"
        case .none, .other: "Idle"
        }
    }
}

/// `player_action_state.last_action_result` — 0 Success, 1 TimingFail,
/// 2 Fail, 3 Cancel (declaration order).
public enum PlayerActionResult: UInt8, Equatable, Sendable {
    case success = 0
    case timingFail = 1
    case fail = 2
    case cancel = 3
}

/// `player_action_state` — the server's own record of what the player is
/// doing (one Base and one UpperBody row per player). The own-row
/// subscription is also the TimingFail tripwire: a cadence rejection
/// lands here as `last_actionResult = .timingFail`
/// (docs/protocol/region-move-and-craft-continue.md, "Strike
/// observability").
public struct PlayerActionRow: BSATNTableWithPrimaryKey, Equatable, Sendable {
    public static let tableName = "player_action_state"

    let autoID: UInt64
    let chunkIndex: UInt64
    let entityID: UInt64
    /// Action start, milliseconds since the Unix epoch (server clock).
    let startAtMs: UInt64
    /// The server-computed action duration, milliseconds.
    let durationMs: UInt64
    let target: UInt64?
    let recipeID: Int32?
    let actionType: PlayerActionKind
    let layer: UInt8
    let lastActionResult: PlayerActionResult
    let wasConsumed: Bool

    public var primaryKey: UInt64 { entityID }

    public init(reader: BSATNReader) throws {
        autoID = try reader.read() as UInt64
        chunkIndex = try reader.read() as UInt64
        entityID = try reader.read() as UInt64
        startAtMs = try reader.read() as UInt64
        durationMs = try reader.read() as UInt64
        target = try reader.readOptional { try reader.read() as UInt64 }
        recipeID = try reader.readOptional { try reader.read() as Int32 }
        actionType = PlayerActionKind(raw: try reader.read() as UInt8)
        layer = try reader.read() as UInt8
        lastActionResult = PlayerActionResult(rawValue: try reader.read() as UInt8) ?? .fail
        _ = try reader.readBool() // client_cancel
        wasConsumed = try reader.readBool()
        // Trailing `_pad1.._pad3` stay unread.
    }

    public init(
        autoID: UInt64, chunkIndex: UInt64, entityID: UInt64,
        startAtMs: UInt64, durationMs: UInt64, target: UInt64?,
        recipeID: Int32?, actionType: PlayerActionKind, layer: UInt8,
        lastActionResult: PlayerActionResult, wasConsumed: Bool
    ) {
        self.autoID = autoID
        self.chunkIndex = chunkIndex
        self.entityID = entityID
        self.startAtMs = startAtMs
        self.durationMs = durationMs
        self.target = target
        self.recipeID = recipeID
        self.actionType = actionType
        self.layer = layer
        self.lastActionResult = lastActionResult
        self.wasConsumed = wasConsumed
    }
}

/// `mobile_entity_state` — the player's own position truth. Coordinates
/// are fixed-point milli-tiles in i32 (`location_x ≈ 23_997_002` is tile
/// 23997.002); `timestamp` is the server-side move-validation baseline
/// (epoch ms of the last accepted move).
public struct MobileEntityRow: BSATNTableWithPrimaryKey, Equatable, Sendable {
    public static let tableName = "mobile_entity_state"

    let entityID: UInt64
    let chunkIndex: UInt64
    let timestampMs: UInt64
    let locationX: Int32
    let locationZ: Int32
    let destinationX: Int32
    let destinationZ: Int32
    let dimension: UInt32

    public var primaryKey: UInt64 { entityID }

    public init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        chunkIndex = try reader.read() as UInt64
        timestampMs = try reader.read() as UInt64
        locationX = try reader.read() as Int32
        locationZ = try reader.read() as Int32
        destinationX = try reader.read() as Int32
        destinationZ = try reader.read() as Int32
        dimension = try reader.read() as UInt32
        // Trailing `is_walking`, `_pad1..3` stay unread.
    }

    public init(
        entityID: UInt64, chunkIndex: UInt64, timestampMs: UInt64,
        locationX: Int32, locationZ: Int32, destinationX: Int32,
        destinationZ: Int32, dimension: UInt32
    ) {
        self.entityID = entityID
        self.chunkIndex = chunkIndex
        self.timestampMs = timestampMs
        self.locationX = locationX
        self.locationZ = locationZ
        self.destinationX = destinationX
        self.destinationZ = destinationZ
        self.dimension = dimension
    }
}

/// `prospecting_state` — the live prospection compass projection, one row
/// per active prospector (deleted when the trail completes or is
/// abandoned). Field order pinned 2026-09-29 against the live mirror schema
/// (`/v1/database/bitcraft-live-14/schema?version=9`) and verified against
/// real rows streamed off the mirror — bearings, distances, and step
/// progression checked end-to-end against a player's actual walk
/// (docs/protocol/prospecting.md). `next_crumb_angle` carries one or two
/// radians: two = a `[lo, hi]` cone whose midpoint is the true bearing;
/// one = the final step's precise bearing to the prize. `to_next_node` is
/// the player→target distance in world units.
public struct ProspectingStateRow: BSATNTableWithPrimaryKey, Equatable, Sendable {
    public static let tableName = "prospecting_state"

    public let entityID: UInt64
    public let prospectingID: Int32
    public let crumbTrailEntityID: UInt64
    public let completedSteps: Int32
    public let ongoingStep: Int32
    public let totalSteps: Int32
    public let nextCrumbAngles: [Float]
    /// Last prospection, microseconds since the Unix epoch.
    public let lastProspectionMicros: Int64
    public let contribution: Int32
    public let toNextNode: Float

    public var primaryKey: UInt64 { entityID }

    public init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        prospectingID = try reader.read() as Int32
        crumbTrailEntityID = try reader.read() as UInt64
        completedSteps = try reader.read() as Int32
        ongoingStep = try reader.read() as Int32
        totalSteps = try reader.read() as Int32
        nextCrumbAngles = try reader.readTypedArray { try reader.read() as Float }
        lastProspectionMicros = try reader.read() as Int64
        contribution = try reader.read() as Int32
        toNextNode = try reader.read() as Float
    }

    public init(
        entityID: UInt64, prospectingID: Int32, crumbTrailEntityID: UInt64,
        completedSteps: Int32, ongoingStep: Int32, totalSteps: Int32,
        nextCrumbAngles: [Float], lastProspectionMicros: Int64,
        contribution: Int32, toNextNode: Float
    ) {
        self.entityID = entityID
        self.prospectingID = prospectingID
        self.crumbTrailEntityID = crumbTrailEntityID
        self.completedSteps = completedSteps
        self.ongoingStep = ongoingStep
        self.totalSteps = totalSteps
        self.nextCrumbAngles = nextCrumbAngles
        self.lastProspectionMicros = lastProspectionMicros
        self.contribution = contribution
        self.toNextNode = toNextNode
    }
}

/// `location_state` — any entity's tile (buildings included). Consumed as
/// a one-off (`WHERE entity_id = <building>` — PK equality, guardrail-
/// safe) to locate the station the driver walks to. Overworld dimension
/// is 1; interior stations report their interior's dimension and are out
/// of the driver's v1 scope.
public struct LocationRow: BSATNTableWithPrimaryKey, Equatable {
    public static let tableName = "location_state"

    let entityID: UInt64
    let chunkIndex: UInt64
    let x: Int32
    let z: Int32
    let dimension: UInt32

    public var primaryKey: UInt64 { entityID }

    public init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        chunkIndex = try reader.read() as UInt64
        x = try reader.read() as Int32
        z = try reader.read() as Int32
        dimension = try reader.read() as UInt32
    }

    init(entityID: UInt64, chunkIndex: UInt64, x: Int32, z: Int32, dimension: UInt32) {
        self.entityID = entityID
        self.chunkIndex = chunkIndex
        self.x = x
        self.z = z
        self.dimension = dimension
    }
}

// MARK: - Reducer arguments (BSATN encoders)

/// Wire encoders for the driver's reducers — argument layouts pinned to
/// the captured region leg (docs/protocol/region-move-and-craft-continue.md).
/// All request `timestamp` fields are **milliseconds** since the Unix
/// epoch, monotonic across calls; the position options are declared Sums
/// with variants `[some, none]` — **some = 0x00, none = 0x01**.
enum RegionReducerArgs {

    /// `craft_continue_start` / `craft_continue` —
    /// `(progressive_action_entity_id: u64, timestamp: u64)`, 16 bytes.
    static func craftContinue(progressiveActionEntityID: UInt64, timestampMs: UInt64) -> Data {
        var data = Data()
        data.appendLE(progressiveActionEntityID)
        data.appendLE(timestampMs)
        return data
    }

    /// `craft_cancel` — `(pocket_id: u64)`, 8 bytes. The pocket id is the
    /// progressive action's entity id.
    static func craftCancel(pocketID: UInt64) -> Data {
        var data = Data()
        data.appendLE(pocketID)
        return data
    }

    /// `player_action_cancel` — `(client_cancel: bool)`, 1 byte.
    static func playerActionCancel() -> Data {
        Data([0x01])
    }

    /// `player_move` —
    /// `(timestamp: u64, destination: Option<Pos>, origin: Option<Pos>,
    ///   duration: f32, move_type: i32, is_rp_walk: bool)` where
    /// `Pos = (x: i32, z: i32, dimension: u32)` and the option tags are
    /// some=0x00 / none=0x01. 43 bytes with both positions present.
    static func playerMove(
        timestampMs: UInt64,
        destinationX: Int32, destinationZ: Int32, dimension: UInt32,
        originX: Int32?, originZ: Int32?,
        durationSeconds: Float, moveType: Int32, isRPWalk: Bool = false
    ) -> Data {
        var data = Data()
        data.appendLE(timestampMs)
        // destination — the driver always knows where it is going.
        data.append(0x00) // some
        data.appendLE(destinationX)
        data.appendLE(destinationZ)
        data.appendLE(dimension)
        if let originX, let originZ {
            data.append(0x00) // some
            data.appendLE(originX)
            data.appendLE(originZ)
            data.appendLE(dimension)
        } else {
            data.append(0x01) // none
        }
        data.appendLE(durationSeconds.bitPattern)
        data.appendLE(moveType)
        data.append(isRPWalk ? 0x01 : 0x00)
        return data
    }
}

extension Data {
    mutating func appendLE<T>(_ value: T) {
        Swift.withUnsafeBytes(of: value) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) {
        Swift.withUnsafeBytes(of: value.bitPattern) { append(contentsOf: $0) }
    }
}

// MARK: - Receipts

/// The own-action feedback channel: every awaited `callReducer` receipt
/// carries this client's own transaction row diffs
/// (`ReducerSuccess.transactionUpdate` — the server routes self-caused
/// effects through the result, not the subscription broadcast; the
/// captured desktop leg confirms own-action broadcasts never stream
/// back). Decoded with the same row types the subscriptions use.
public struct DriverReceipt: Equatable, Sendable {
    /// Server timestamp of the reducer's execution.
    let serverTimeMs: Double
    /// The craft row after the transaction (progress is the effort done).
    let craft: ProgressiveActionRow?
    let stamina: StaminaRow?
    let satiation: SatiationRow?
    let action: PlayerActionRow?
    let position: MobileEntityRow?

    init(
        serverTimeMs: Double,
        craft: ProgressiveActionRow? = nil,
        stamina: StaminaRow? = nil,
        satiation: SatiationRow? = nil,
        action: PlayerActionRow? = nil,
        position: MobileEntityRow? = nil
    ) {
        self.serverTimeMs = serverTimeMs
        self.craft = craft
        self.stamina = stamina
        self.satiation = satiation
        self.action = action
        self.position = position
    }

    init(_ success: ReducerSuccess) {
        var craft: ProgressiveActionRow?
        var stamina: StaminaRow?
        var satiation: SatiationRow?
        var action: PlayerActionRow?
        var position: MobileEntityRow?
        for set in success.transactionUpdate.querySets {
            for table in set.tables {
                for row in table.allInserts {
                    switch table.tableName {
                    case ProgressiveActionRow.tableName:
                        if craft == nil { craft = try? ProgressiveActionRow(reader: BSATNReader(data: row)) }
                    case StaminaRow.tableName:
                        if stamina == nil { stamina = try? StaminaRow(reader: BSATNReader(data: row)) }
                    case SatiationRow.tableName:
                        if satiation == nil { satiation = try? SatiationRow(reader: BSATNReader(data: row)) }
                    case PlayerActionRow.tableName:
                        if action == nil { action = try? PlayerActionRow(reader: BSATNReader(data: row)) }
                    case MobileEntityRow.tableName:
                        if position == nil { position = try? MobileEntityRow(reader: BSATNReader(data: row)) }
                    default:
                        break
                    }
                }
            }
        }
        self.init(
            serverTimeMs: success.timestamp.timeIntervalSince1970 * 1_000,
            craft: craft, stamina: stamina, satiation: satiation,
            action: action, position: position
        )
    }
}
