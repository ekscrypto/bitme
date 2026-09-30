import Foundation
import Testing
import BSATN
@testable import BitMeCore

/// Byte-level wire tests for the player-vitals rows and the driver's
/// reducer-argument encoders — fixtures pinned to the captured region leg
/// (`tools/tap/captures/2026-09-28_00-24-16`, conn-02; see
/// docs/protocol/region-move-and-craft-continue.md).
private struct Wire {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func u64(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func string(_ s: String) {
        u32(UInt32(s.utf8.count))
        data.append(contentsOf: Array(s.utf8))
    }
}

@Suite struct PlayerRowsTests {

    // The captured player (conn-02's own player) and the first captured
    // walk segment — the encoder test must reproduce its bytes exactly.
    private static let player: UInt64 = 1_297_036_692_699_996_362 // 0x120000000107E0CA

    @Test func vitalsRowsDecodeInSchemaOrder() throws {
        var stamina = Wire()
        stamina.u64(Self.player)
        stamina.i64(1_790_557_900_000_000) // µs
        stamina.f32(312.5)
        let staminaRow = try StaminaRow(reader: BSATNReader(data: stamina.data))
        #expect(staminaRow.entityID == Self.player)
        #expect(staminaRow.stamina == 312.5)

        var health = Wire()
        health.u64(Self.player); health.i64(0); health.f32(150.0); health.i32(0)
        let healthRow = try HealthRow(reader: BSATNReader(data: health.data))
        #expect(healthRow.health == 150.0)

        var teleport = Wire()
        teleport.u64(Self.player); teleport.f32(42.0)
        #expect(try TeleportEnergyRow(reader: BSATNReader(data: teleport.data)).energy == 42.0)

        var satiation = Wire()
        satiation.u64(Self.player); satiation.f32(78.5)
        #expect(try SatiationRow(reader: BSATNReader(data: satiation.data)).satiation == 78.5)
    }

    @Test func characterStatsRowDecodesVectorAndBoundsChecks() throws {
        var w = Wire()
        w.u64(Self.player)
        w.u32(3)
        w.f32(160.0)  // MaxHealth
        w.f32(340.0)  // MaxStamina
        w.f32(1.0)    // PassiveHealthRegenRate
        let row = try CharacterStatsRow(reader: BSATNReader(data: w.data))
        #expect(row.values.count == 3)
        #expect(row.stat(CharacterStatIndex.maxHealth) == 160.0)
        #expect(row.stat(CharacterStatIndex.maxStamina) == 340.0)
        #expect(row.stat(CharacterStatIndex.movementMultiplier) == nil) // out of range
        #expect(row.stat(-1) == nil)
    }

    @Test func statIndexMappingMatchesSchema() {
        #expect(CharacterStatIndex.maxHealth == 0)
        #expect(CharacterStatIndex.maxStamina == 1)
        #expect(CharacterStatIndex.movementMultiplier == 4)
        #expect(CharacterStatIndex.craftingSpeed == 15)
        #expect(CharacterStatIndex.gatheringSpeed == 16)
        #expect(CharacterStatIndex.maxSatiation == 19)
        #expect(CharacterStatIndex.maxTeleportationEnergy == 49)
        // skill_desc ids 2 Forestry … 13 Cooking, 14 Foraging → +19.
        #expect(CharacterStatIndex.skillSpeed(skillID: 2) == 21)   // ForestrySpeed
        #expect(CharacterStatIndex.skillSpeed(skillID: 13) == 32)  // CookingSpeed
        #expect(CharacterStatIndex.skillSpeed(skillID: 14) == 33)  // ForagingSpeed
        #expect(CharacterStatIndex.skillSpeed(skillID: 1) == nil)  // ANY sentinel
    }

    @Test func playerActionRowDecodesEnumsAndOptions() throws {
        var w = Wire()
        w.u64(178_717)          // auto_id
        w.u64(200_250)          // chunk_index
        w.u64(Self.player)      // entity_id
        w.u64(1_790_557_962_820) // start_time (ms)
        w.u64(1_689)            // duration (ms)
        w.u8(0); w.u64(3001)    // target = some(building)
        w.u8(0); w.i32(77)      // recipe_id = some(77)
        w.u8(20)                // action_type = Craft
        w.u8(0)                 // layer = Base
        w.u8(1)                 // last_action_result = TimingFail
        w.u8(0)                 // client_cancel
        w.u8(1)                 // was_consumed
        let row = try PlayerActionRow(reader: BSATNReader(data: w.data))
        #expect(row.actionType == .craft)
        #expect(row.actionType.displayName == "Crafting")
        #expect(row.lastActionResult == .timingFail)
        #expect(row.target == 3001)
        #expect(row.recipeID == 77)
        #expect(row.wasConsumed)
        #expect(row.durationMs == 1_689)
        // Unknown action tags degrade instead of crashing. The action_type
        // byte sits 5 from the end (layer, result, cancel, consumed trail).
        var odd = w
        odd.data[odd.data.count - 5] = 33 // unknown action_type byte
        let oddRow = try PlayerActionRow(reader: BSATNReader(data: odd.data))
        #expect(oddRow.actionType == .other)
        #expect(oddRow.actionType.displayName == "Idle")
    }

    @Test func mobileEntityAndLocationRowsDecode() throws {
        var mobile = Wire()
        mobile.u64(Self.player); mobile.u64(200_250); mobile.u64(1_790_557_942_319)
        mobile.i32(23_996_784); mobile.i32(19_259_184)
        mobile.i32(23_997_002); mobile.i32(19_258_982)
        mobile.u32(1); mobile.u8(1) // dimension overworld, is_walking
        let m = try MobileEntityRow(reader: BSATNReader(data: mobile.data))
        #expect(m.locationX == 23_996_784)
        #expect(m.destinationZ == 19_258_982)
        #expect(m.dimension == 1)

        var loc = Wire()
        loc.u64(3001); loc.u64(200_250); loc.i32(23_997_000); loc.i32(19_259_000); loc.u32(1)
        let l = try LocationRow(reader: BSATNReader(data: loc.data))
        #expect(l.entityID == 3001)
        #expect(l.dimension == 1)
    }

    // MARK: - Argument encoders (byte-exact against the capture)

    @Test func craftContinueArgsMatchCapturedBytes() {
        // The loop's first craft_continue_start (requestId 11): entity
        // 0x0E000000FFEA2831, client timestamp 1790557946649 ms.
        let args = RegionReducerArgs.craftContinue(
            progressiveActionEntityID: 1_008_806_320_824_526_897,
            timestampMs: 1_790_557_946_649
        )
        let expected: [UInt8] = [
            0x31, 0x28, 0xea, 0xff, 0x00, 0x00, 0x00, 0x0e,
            0x19, 0x03, 0x92, 0xe5, 0xa0, 0x01, 0x00, 0x00,
        ]
        #expect(Array(args) == expected)
        #expect(
            Array(RegionReducerArgs.craftCancel(pocketID: 1_008_806_320_824_526_897))
                == Array(expected[0..<8])
        )
        #expect(Array(RegionReducerArgs.playerActionCancel()) == [0x01])
    }

    @Test func playerMoveArgsMatchCapturedBytes() {
        // Captured call #0 (01:12:22.319): dest (23997002, 19258982),
        // origin (23996784, 19259184), dimension 1, duration bits
        // 0x3D685E35, move_type 2 — 43 bytes, some tags 0x00.
        let args = RegionReducerArgs.playerMove(
            timestampMs: 1_790_557_942_319,
            destinationX: 23_997_002, destinationZ: 19_258_982, dimension: 1,
            originX: 23_996_784, originZ: 19_259_184,
            durationSeconds: Float(bitPattern: 0x3D68_5E35),
            moveType: 2
        )
        let expected: [UInt8] = [
            0x2f, 0xf2, 0x91, 0xe5, 0xa0, 0x01, 0x00, 0x00, // timestamp ms
            0x00,                                           // destination some
            0x4a, 0x2a, 0x6e, 0x01,                         // x
            0x66, 0xde, 0x25, 0x01,                         // z
            0x01, 0x00, 0x00, 0x00,                         // dimension
            0x00,                                           // origin some
            0x70, 0x29, 0x6e, 0x01,
            0x30, 0xdf, 0x25, 0x01,
            0x01, 0x00, 0x00, 0x00,
            0x35, 0x5e, 0x68, 0x3d,                         // duration f32
            0x02, 0x00, 0x00, 0x00,                         // move_type
            0x00,                                           // is_rp_walk
        ]
        #expect(args.count == 43)
        #expect(Array(args) == expected)
    }

    @Test func playerMoveNoneOriginTakesTheOneByteTag() {
        let args = RegionReducerArgs.playerMove(
            timestampMs: 1, destinationX: 0, destinationZ: 0, dimension: 1,
            originX: nil, originZ: nil,
            durationSeconds: 0, moveType: 1
        )
        // ts 8 + dest 13 + origin-none 1 + f32 4 + i32 4 + bool 1 = 31.
        #expect(args.count == 31)
        #expect(args[21] == 0x01) // none tag, right after the destination
    }

    @Test func hexTileDistanceMatchesGameMetric() {
        // (|dx| + |dx+dz| + |dz|) / 2 — axial hex distance.
        #expect(hexTileDistance(dx: 0, dz: 0) == 0)
        #expect(hexTileDistance(dx: 1, dz: 0) == 1)
        #expect(hexTileDistance(dx: 3, dz: -3) == 3)
        #expect(hexTileDistance(dx: 2, dz: 1) == 3)
        #expect(hexTileDistance(dx: -2, dz: -2) == 4)
    }

    @Test func buildingFootprintRadiusIsRotationInvariantMetric() {
        let single = BuildingDescInfo(
            id: 1, name: "Firepit", functions: [],
            footprint: [FootprintTileInfo(x: 0, z: 0, kind: 0)]
        )
        #expect(single.footprintRadiusTiles == 0)

        let threeTile = BuildingDescInfo(
            id: 2, name: "Workbench", functions: [],
            footprint: [
                FootprintTileInfo(x: 0, z: 0, kind: 0),
                FootprintTileInfo(x: 1, z: 0, kind: 0),
                FootprintTileInfo(x: 0, z: 1, kind: 2),
            ]
        )
        #expect(threeTile.footprintRadiusTiles == 1)

        let empty = BuildingDescInfo(id: 3, name: "X", functions: [])
        #expect(empty.footprintRadiusTiles == 0)
    }
}
