import Foundation
import BSATN
import SpacetimeDB

// Region-database rows for the claim-buildings sync (Pocket Crafter).
// Field order is pinned to the game module's schema
// (docs/protocol/region-claim-buildings.md §3); the decoders read fields
// in declaration order and stop once everything needed is consumed.

/// `building_state` — one row per placed building; the claim's building
/// list arrives as the `WHERE claim_entity_id = <claim>` slice.
struct BuildingStateRow: BSATNTableWithPrimaryKey, Equatable {
    static let tableName = "building_state"

    let entityID: UInt64
    let claimEntityID: UInt64
    let directionIndex: Int32
    let buildingDescriptionID: Int32
    let constructedByPlayerEntityID: UInt64

    var primaryKey: UInt64 { entityID }

    init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        claimEntityID = try reader.read() as UInt64
        directionIndex = try reader.read() as Int32
        buildingDescriptionID = try reader.read() as Int32
        constructedByPlayerEntityID = try reader.read() as UInt64
    }

    init(
        entityID: UInt64, claimEntityID: UInt64, directionIndex: Int32,
        buildingDescriptionID: Int32, constructedByPlayerEntityID: UInt64
    ) {
        self.entityID = entityID
        self.claimEntityID = claimEntityID
        self.directionIndex = directionIndex
        self.buildingDescriptionID = buildingDescriptionID
        self.constructedByPlayerEntityID = constructedByPlayerEntityID
    }
}

/// `claim_state` — the pinned claim's header row.
struct ClaimStateRow: BSATNTableWithPrimaryKey, Equatable {
    static let tableName = "claim_state"

    let entityID: UInt64
    let ownerPlayerEntityID: UInt64
    let ownerBuildingEntityID: UInt64
    let name: String
    let neutral: Bool

    var primaryKey: UInt64 { entityID }

    init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        ownerPlayerEntityID = try reader.read() as UInt64
        ownerBuildingEntityID = try reader.read() as UInt64
        name = try reader.readString()
        neutral = try reader.readBool()
    }

    init(
        entityID: UInt64, ownerPlayerEntityID: UInt64,
        ownerBuildingEntityID: UInt64, name: String, neutral: Bool
    ) {
        self.entityID = entityID
        self.ownerPlayerEntityID = ownerPlayerEntityID
        self.ownerBuildingEntityID = ownerBuildingEntityID
        self.name = name
        self.neutral = neutral
    }
}

/// `building_nickname_state` — player-assigned building names.
struct BuildingNicknameRow: BSATNTableWithPrimaryKey, Equatable {
    static let tableName = "building_nickname_state"

    let entityID: UInt64
    let nickname: String

    var primaryKey: UInt64 { entityID }

    init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        nickname = try reader.readString()
    }

    init(entityID: UInt64, nickname: String) {
        self.entityID = entityID
        self.nickname = nickname
    }
}

/// `passive_craft_state.status` — declaration order Queued/Processing/Complete.
public enum PassiveCraftStatus: UInt8, Equatable, Sendable {
    case queued = 0
    case processing = 1
    case complete = 2
}

/// `passive_craft_state` — the queued/timed crafts at a station.
struct PassiveCraftRow: BSATNTableWithPrimaryKey, Equatable {
    static let tableName = "passive_craft_state"

    let entityID: UInt64
    let ownerEntityID: UInt64
    let recipeID: Int32
    let buildingEntityID: UInt64
    /// Craft start, microseconds since the Unix epoch.
    let startedAtMicros: Int64
    let status: PassiveCraftStatus
    let slot: UInt32?

    var primaryKey: UInt64 { entityID }

    init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        ownerEntityID = try reader.read() as UInt64
        recipeID = try reader.read() as Int32
        buildingEntityID = try reader.read() as UInt64
        startedAtMicros = try reader.read() as Int64
        status = PassiveCraftStatus(rawValue: try reader.read() as UInt8) ?? .processing
        slot = try reader.readOptional { try reader.read() as UInt32 }
    }

    init(
        entityID: UInt64, ownerEntityID: UInt64, recipeID: Int32,
        buildingEntityID: UInt64, startedAtMicros: Int64,
        status: PassiveCraftStatus, slot: UInt32?
    ) {
        self.entityID = entityID
        self.ownerEntityID = ownerEntityID
        self.recipeID = recipeID
        self.buildingEntityID = buildingEntityID
        self.startedAtMicros = startedAtMicros
        self.status = status
        self.slot = slot
    }
}

/// `progressive_action_state` — the at-the-bench crafts with live progress.
/// `progress` is cumulative *effort* (actions), not completed items: the
/// in-game bar's denominator is `craftCount × recipe.actions_required`
/// (live-verified 2026-09-28: 89300/129050 = 890 × 145 "Saw Exquisite
/// Stripped Wood"), so "complete" means `progress ≥ craftCount ×
/// actionsRequired` — never `progress ≥ craftCount`.
struct ProgressiveActionRow: BSATNTableWithPrimaryKey, Equatable {
    static let tableName = "progressive_action_state"

    let entityID: UInt64
    let buildingEntityID: UInt64
    let functionType: Int32
    let progress: Int32
    let recipeID: Int32
    let craftCount: Int32
    let lastCritOutcome: Int32
    let ownerEntityID: UInt64
    /// When the station's craft lock releases, microseconds since the epoch.
    let lockExpiresAtMicros: Int64
    let preparation: Bool

    var primaryKey: UInt64 { entityID }

    init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        buildingEntityID = try reader.read() as UInt64
        functionType = try reader.read() as Int32
        progress = try reader.read() as Int32
        recipeID = try reader.read() as Int32
        craftCount = try reader.read() as Int32
        lastCritOutcome = try reader.read() as Int32
        ownerEntityID = try reader.read() as UInt64
        lockExpiresAtMicros = try reader.read() as Int64
        preparation = try reader.readBool()
    }

    init(
        entityID: UInt64, buildingEntityID: UInt64, functionType: Int32,
        progress: Int32, recipeID: Int32, craftCount: Int32,
        lastCritOutcome: Int32, ownerEntityID: UInt64,
        lockExpiresAtMicros: Int64, preparation: Bool
    ) {
        self.entityID = entityID
        self.buildingEntityID = buildingEntityID
        self.functionType = functionType
        self.progress = progress
        self.recipeID = recipeID
        self.craftCount = craftCount
        self.lastCritOutcome = lastCritOutcome
        self.ownerEntityID = ownerEntityID
        self.lockExpiresAtMicros = lockExpiresAtMicros
        self.preparation = preparation
    }
}

/// `public_progressive_action_state` — the game's shared-craft projection:
/// one row per effort-based craft its owner opened to other players
/// (anyone may `craft_continue` it). A progressive craft is shared ⇔ its
/// entity id appears here. Orphans outlive their craft (rows linger after
/// collection), so membership alone never fabricates a row — the join is
/// always through `progressive_action_state`, and only not-yet-complete
/// crafts are actionable.
struct PublicProgressiveActionRow: BSATNTableWithPrimaryKey, Equatable {
    static let tableName = "public_progressive_action_state"

    let entityID: UInt64
    let buildingEntityID: UInt64
    let ownerEntityID: UInt64

    var primaryKey: UInt64 { entityID }

    init(reader: BSATNReader) throws {
        entityID = try reader.read() as UInt64
        buildingEntityID = try reader.read() as UInt64
        ownerEntityID = try reader.read() as UInt64
    }

    init(entityID: UInt64, buildingEntityID: UInt64, ownerEntityID: UInt64) {
        self.entityID = entityID
        self.buildingEntityID = buildingEntityID
        self.ownerEntityID = ownerEntityID
    }
}

// MARK: - Static catalogs (one-off decoded)

/// One `building_desc.functions` entry — only the slot counts the app
/// needs; the remaining catalog fields are consumed in order and dropped.
public struct BuildingFunctionInfo: Equatable, Codable, Sendable {
    let functionType: Int32
    let level: Int32
    let craftingSlots: Int32
    let storageSlots: Int32
    let cargoSlots: Int32
    let refiningSlots: Int32
    let refiningCargoSlots: Int32
}

/// One `building_desc.footprint` entry — a tile offset from the building's
/// center. `kind` is the `FootprintType` u8 tag (0 hitbox, 1 walkable,
/// 2 perimeter, 3 walkable-resource).
public struct FootprintTileInfo: Equatable, Codable, Sendable {
    let x: Int32
    let z: Int32
    let kind: UInt8

    init(x: Int32, z: Int32, kind: UInt8) {
        self.x = x
        self.z = z
        self.kind = kind
    }
}

/// Axial hex distance between two tile offsets — the game's own metric
/// (`HexCoordinates::distance_to`: `(|dx| + |dy| + |dz|) / 2` with
/// `y = -x - z`). Footprint offsets rotate around the center when a
/// building is placed, but rotation preserves each tile's distance from
/// the center — so the max over the raw deltas is direction-invariant.
func hexTileDistance(dx: Int32, dz: Int32) -> Int32 {
    (abs(dx) + abs(dx + dz) + abs(dz)) / 2
}

/// `building_desc` — the building catalog: display name plus the function
/// entries that decide what a building is. Classification follows the
/// relay's rule (`relay-cache/src/decode.rs::functions_is_storage`):
/// crafting ⇔ crafting/refining slots, storage ⇔ item/cargo pockets.
/// `unenterable` and the footprint tiles drive the craft driver: an
/// unenterable station crafts from ≤2 tiles of its footprint, and the
/// footprint's max radius picks the stand-point.
public struct BuildingDescInfo: Equatable, Codable, Sendable {
    let id: Int32
    let name: String
    let functions: [BuildingFunctionInfo]
    /// True when crafting happens from outside (≤2 tiles of footprint);
    /// false means the crafter must stand inside an interior — out of the
    /// driver's v1 scope.
    let unenterable: Bool
    /// Footprint tile offsets from the building's center (unrotated).
    let footprint: [FootprintTileInfo]

    /// The footprint's largest tile-distance from the center — invariant
    /// under the placement rotation. Standing this +2 tiles from the
    /// center is ≤2 tiles from every footprint tile (and never on one).
    var footprintRadiusTiles: Int32 {
        footprint.isEmpty ? 0 : footprint.map { hexTileDistance(dx: $0.x, dz: $0.z) }.max() ?? 0
    }

    init(
        id: Int32, name: String, functions: [BuildingFunctionInfo],
        unenterable: Bool = true, footprint: [FootprintTileInfo] = []
    ) {
        self.id = id
        self.name = name
        self.functions = functions
        self.unenterable = unenterable
        self.footprint = footprint
    }

    var isCrafting: Bool {
        functions.contains { $0.craftingSlots > 0 || $0.refiningSlots > 0 }
    }

    var isStorage: Bool {
        functions.contains { $0.storageSlots > 0 || $0.cargoSlots > 0 }
    }
}

/// A recipe stack entry's identity half — the id plus which catalog
/// names it (`item_type` tag: Item → `item_desc`, Cargo → `cargo_desc`).
public struct ItemStackRef: Equatable, Codable, Sendable {
    let id: Int32
    let isCargo: Bool

    init(id: Int32, isCargo: Bool) {
        self.id = id
        self.isCargo = isCargo
    }
}

/// `crafting_recipe_desc` row → the fields the workstation join needs:
/// id, name, the profession signals — the first `level_requirements`
/// skill id (the profession gate), else the first `tool_requirements` tool
/// type (e.g. Foraging's Machete; resolved against `tool_type_desc` at
/// load) — the first consumed/crafted stack entries, the arguments
/// the `name` template's {1}/{0} refer to, and `actions_required` (the
/// per-item effort of bench crafts: the progress bar's denominator is
/// `craftCount × actionsRequired`). Reads through `actions_required`
/// (field 14) and stops; trailing fields stay unread in the row buffer.
public struct RecipeInfo: Equatable, Codable, Sendable {
    let id: Int32
    let name: String
    /// `time_requirement` — the per-action cooldown base: the server paces
    /// actions at `time_requirement / (CraftingSpeed + skill_speed − 1)`
    /// seconds (craft.rs::event_delay).
    let timeRequirement: Float?
    /// `stamina_requirement` — charged per completed craft action.
    let staminaRequirement: Float?
    /// First `level_requirements` entry's `skill_id` — an id in the game's
    /// `skill_desc` catalog (0/1 sentinels, 2 Forestry … 13 Cooking,
    /// 14 Foraging; see `Profession.from(skillID:)`).
    let skillID: Int32?
    /// First `tool_requirements` entry's `tool_type` — nil for hand recipes.
    let toolTypeID: Int32?
    /// First `consumed_item_stacks` entry — the name template's {1}.
    let input: ItemStackRef?
    /// First `crafted_item_stacks` entry — the name template's {0}.
    let output: ItemStackRef?
    /// `actions_required` — effort per crafted item (progressive crafts).
    let actionsRequired: Int32?
}

/// `tool_type_desc` row → the tool→skill join (e.g. Machete → Foraging).
public struct ToolTypeInfo: Equatable, Codable, Sendable {
    let id: Int32
    let name: String
    let skillID: Int32
}

/// Manual one-off decoders for the static catalog rows. `building_desc`
/// carries `functions` (an array of 15-field products) before `name`, so
/// the whole function list is walked field-by-field; everything after
/// `name` is not needed and left unread.
enum RegionGamedataDecoder {
    /// `building_desc` row → catalog info. Reads `id`, `functions`, `name`,
    /// then walks the fixed catalog fields to `footprint` (description,
    /// rested-buff duration, light radius, model/icon asset names,
    /// unenterable, wilderness) and stops — trailing fields stay unread.
    static func buildingDesc(_ data: Data) throws -> BuildingDescInfo {
        let reader = BSATNReader(data: data)
        let id = try reader.read() as Int32
        let functions = try reader.readTypedArray { () -> BuildingFunctionInfo in
            // Every catalog field is consumed in declaration order; the
            // ones the app doesn't keep are read and dropped.
            let functionType = try reader.read() as Int32
            let level = try reader.read() as Int32
            let craftingSlots = try reader.read() as Int32
            let storageSlots = try reader.read() as Int32
            let cargoSlots = try reader.read() as Int32
            let refiningSlots = try reader.read() as Int32
            let refiningCargoSlots = try reader.read() as Int32
            _ = try reader.read() as Int32 // item_slot_size
            _ = try reader.read() as Int32 // cargo_slot_size
            _ = try reader.read() as Int32 // trade_orders
            _ = try reader.readTypedArray { try reader.read() as Int32 } // allowed_item_id_per_slot
            _ = try reader.read() as Int32 // concurrent_crafts_per_player
            _ = try reader.readBool() // terraform
            _ = try reader.read() as Int32 // housing_slots
            _ = try reader.read() as UInt32 // housing_income
            return BuildingFunctionInfo(
                functionType: functionType,
                level: level,
                craftingSlots: craftingSlots,
                storageSlots: storageSlots,
                cargoSlots: cargoSlots,
                refiningSlots: refiningSlots,
                refiningCargoSlots: refiningCargoSlots
            )
        }
        let name = try reader.readString()
        _ = try reader.readString() // description
        _ = try reader.read() as Int32 // rested_buff_duration
        _ = try reader.read() as Int32 // light_radius
        _ = try reader.readString() // model_asset_name
        _ = try reader.readString() // icon_asset_name
        let unenterable = try reader.readBool()
        _ = try reader.readBool() // wilderness
        let footprint = try reader.readTypedArray { () -> FootprintTileInfo in
            let x = try reader.read() as Int32
            let z = try reader.read() as Int32
            let kind = try reader.read() as UInt8 // FootprintType tag
            return FootprintTileInfo(x: x, z: z, kind: kind)
        }
        return BuildingDescInfo(
            id: id, name: name, functions: functions,
            unenterable: unenterable, footprint: footprint
        )
    }

    /// `crafting_recipe_desc` row → id, name, the profession signals, and
    /// the name-template stack refs. Reads fields in schema order through
    /// `crafted_item_stacks`: the `building_requirement` option (some:
    /// building_type + tier) and the stack `durability` option ride tag
    /// bytes, exactly like the craft-row's optional slot; the stack
    /// `item_type` is a tag too (declaration order: 0 Item, 1 Cargo).
    static func recipe(_ data: Data) throws -> RecipeInfo {
        let reader = BSATNReader(data: data)
        let id = try reader.read() as Int32
        let name = try reader.readString()
        let timeRequirement = try reader.read() as Float
        let staminaRequirement = try reader.read() as Float
        _ = try reader.read() as Int32 // tool_durability_lost
        _ = try reader.readOptional { () throws -> (Int32, Int32) in
            (try reader.read() as Int32, try reader.read() as Int32) // building_type, tier
        }
        let skillID = try reader.readTypedArray { () throws -> Int32 in
            let skill = try reader.read() as Int32 // skill_id
            _ = try reader.read() as Int32 // level
            return skill
        }.first
        let toolTypeID = try reader.readTypedArray { () throws -> Int32 in
            let tool = try reader.read() as Int32 // tool_type
            _ = try reader.read() as Int32 // level
            _ = try reader.read() as Int32 // power
            return tool
        }.first
        let input = try reader.readTypedArray { () throws -> ItemStackRef in
            let itemID = try reader.read() as Int32 // item_id
            _ = try reader.read() as Int32 // quantity
            let isCargo = try reader.read() as UInt8 == 1 // item_type tag
            _ = try reader.read() as Int32 // discovery_score
            _ = try reader.read() as Float // consumption_chance
            return ItemStackRef(id: itemID, isCargo: isCargo)
        }.first
        _ = try reader.readTypedArray { try reader.read() as Int32 } // discovery_triggers
        _ = try reader.read() as Int32 // required_claim_tech_id
        _ = try reader.read() as Int32 // full_discovery_score
        _ = try reader.readTypedArray { () throws -> Void in
            _ = try reader.read() as Int32 // skill_id
            _ = try reader.read() as Float // quantity
        } // experience_per_progress
        let output = try reader.readTypedArray { () throws -> ItemStackRef in
            let itemID = try reader.read() as Int32 // item_id
            _ = try reader.read() as Int32 // quantity
            let isCargo = try reader.read() as UInt8 == 1 // item_type tag
            _ = try reader.readOptional { () throws -> Int32 in try reader.read() as Int32 } // durability
            return ItemStackRef(id: itemID, isCargo: isCargo)
        }.first
        let actionsRequired = try reader.read() as Int32 // actions_required
        return RecipeInfo(
            id: id, name: name,
            timeRequirement: timeRequirement,
            staminaRequirement: staminaRequirement,
            skillID: skillID, toolTypeID: toolTypeID,
            input: input, output: output, actionsRequired: actionsRequired
        )
    }

    /// `item_desc` / `cargo_desc` row head → id and name. Both catalogs
    /// open with the same two fields; the rest stays unread.
    static func idName(_ data: Data) throws -> (id: Int32, name: String) {
        let reader = BSATNReader(data: data)
        let id = try reader.read() as Int32
        let name = try reader.readString()
        return (id, name)
    }

    /// `tool_type_desc` row → id, name, skill_id (the first three fields).
    static func toolTypeDesc(_ data: Data) throws -> ToolTypeInfo {
        let reader = BSATNReader(data: data)
        let id = try reader.read() as Int32
        let name = try reader.readString()
        let skillID = try reader.read() as Int32
        return ToolTypeInfo(id: id, name: name, skillID: skillID)
    }

    /// `claim_member_state` row → the player's own membership (the
    /// claim-resolution fallback, protocol doc §2). Reads `entity_id`,
    /// `claim_entity_id`, `player_entity_id` and stops — `user_name` and
    /// the permission flags stay unread.
    static func claimMembership(_ data: Data) throws -> (entityID: UInt64, claimEntityID: UInt64, playerEntityID: UInt64) {
        let reader = BSATNReader(data: data)
        let entityID = try reader.read() as UInt64
        let claimEntityID = try reader.read() as UInt64
        let playerEntityID = try reader.read() as UInt64
        return (entityID, claimEntityID, playerEntityID)
    }
}
