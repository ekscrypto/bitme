import Testing
import Foundation
import BSATN
import SpacetimeDB
@testable import BitMeCore

/// The claim-buildings sync (Pocket Crafter's workstation domain): the
/// schema-pinned region row decoders, and the machine flow from the
/// region leg's arrival through the live workstation projection.
@Suite(.serialized) // staged collects share the main actor; no self-contention
@MainActor
struct ClaimBuildingsTests {

    // MARK: - BSATN fixtures

    /// Little-endian row builder — bytes appended in the wire order the
    /// decoders pin. (Mutation-style building keeps the type-checker out
    /// of long `Data + Data` chains.)
    private struct Wire {
        var data = Data()

        mutating func u64(_ v: UInt64) { le(v) }
        mutating func u32(_ v: UInt32) { le(v) }
        mutating func i32(_ v: Int32) { le(v) }
        mutating func i64(_ v: Int64) { le(v) }
        mutating func f32(_ v: Float) { le(v.bitPattern) }
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func boolean(_ v: Bool) { data.append(v ? 1 : 0) }
        mutating func string(_ s: String) {
            u32(UInt32(s.utf8.count))
            data.append(contentsOf: s.utf8)
        }

        private mutating func le<T: FixedWidthInteger>(_ v: T) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
    }

    /// A `building_desc.functions` element — all 15 fields, wire order.
    private static func functionEntry(
        into w: inout Wire,
        craftingSlots: Int32 = 0, storageSlots: Int32 = 0,
        cargoSlots: Int32 = 0, refiningSlots: Int32 = 0,
        refiningCargoSlots: Int32 = 0
    ) {
        w.i32(3) // function_type
        w.i32(1) // level
        w.i32(craftingSlots)
        w.i32(storageSlots)
        w.i32(cargoSlots)
        w.i32(refiningSlots)
        w.i32(refiningCargoSlots)
        w.i32(0) // item_slot_size
        w.i32(0) // cargo_slot_size
        w.i32(0) // trade_orders
        w.u32(0) // allowed_item_id_per_slot (empty array)
        w.i32(0) // concurrent_crafts_per_player
        w.boolean(false) // terraform
        w.i32(0) // housing_slots
        w.u32(0) // housing_income
    }

    /// A `building_desc` row body — id, functions, name; the trailing
    /// catalog fields stay absent, exactly where the decoder stops.
    private static func buildingDescRow(
        id: Int32, name: String,
        slots: [(crafting: Int32, storage: Int32, cargo: Int32, refining: Int32, refiningCargo: Int32)] = []
    ) -> Data {
        var w = Wire()
        w.i32(id)
        w.u32(UInt32(slots.count))
        for s in slots {
            functionEntry(
                into: &w,
                craftingSlots: s.crafting, storageSlots: s.storage,
                cargoSlots: s.cargo, refiningSlots: s.refining,
                refiningCargoSlots: s.refiningCargo
            )
        }
        w.string(name)
        return w.data
    }

    // MARK: - Decoder tests

    @Test func buildingStateRowDecodesInSchemaOrder() throws {
        var w = Wire()
        w.u64(3001); w.u64(2000); w.i32(2); w.i32(405); w.u64(1000)
        let row = try BuildingStateRow(reader: BSATNReader(data: w.data))
        #expect(row.entityID == 3001)
        #expect(row.claimEntityID == 2000)
        #expect(row.directionIndex == 2)
        #expect(row.buildingDescriptionID == 405)
        #expect(row.constructedByPlayerEntityID == 1000)
        #expect(row.primaryKey == 3001)
    }

    @Test func passiveCraftRowDecodesStatusAndOptionalSlot() throws {
        // slot = Some(2): tag 0 (some) + u32
        var withSlot = Wire()
        withSlot.u64(5001); withSlot.u64(1000); withSlot.i32(77); withSlot.u64(3001)
        withSlot.i64(1_788_600_000_000_000); withSlot.u8(1); withSlot.u8(0); withSlot.u32(2)
        let row = try PassiveCraftRow(reader: BSATNReader(data: withSlot.data))
        #expect(row.entityID == 5001)
        #expect(row.ownerEntityID == 1000)
        #expect(row.recipeID == 77)
        #expect(row.buildingEntityID == 3001)
        #expect(row.startedAtMicros == 1_788_600_000_000_000)
        #expect(row.status == .processing)
        #expect(row.slot == 2)

        // slot = None: tag 1, status tag 2 = complete
        var withoutSlot = Wire()
        withoutSlot.u64(5002); withoutSlot.u64(1000); withoutSlot.i32(77); withoutSlot.u64(3001)
        withoutSlot.i64(0); withoutSlot.u8(2); withoutSlot.u8(1)
        let noneRow = try PassiveCraftRow(reader: BSATNReader(data: withoutSlot.data))
        #expect(noneRow.status == .complete)
        #expect(noneRow.slot == nil)
    }

    @Test func buildingDescClassifiesCraftingAndStorage() throws {
        let hut = try RegionGamedataDecoder.buildingDesc(
            Self.buildingDescRow(id: 1007, name: "Storage Hut", slots: [(0, 18, 0, 0, 0)])
        )
        #expect(hut.id == 1007)
        #expect(hut.name == "Storage Hut")
        #expect(!hut.isCrafting)
        #expect(hut.isStorage)

        let refinery = try RegionGamedataDecoder.buildingDesc(
            Self.buildingDescRow(id: 1200, name: "Refinery", slots: [(0, 0, 0, 2, 4)])
        )
        #expect(refinery.isCrafting)
        #expect(!refinery.isStorage) // refining cargo is not item/cargo pockets

        let totem = try RegionGamedataDecoder.buildingDesc(
            Self.buildingDescRow(id: 405, name: "Settlement Totem")
        )
        #expect(!totem.isCrafting)
        #expect(!totem.isStorage)
    }

    @Test func projectionDropsCompletedCraftsAndCapsOwnList() {
        var session = EphemeralState.Session(
            entityID: "1000", loop: CancellableTask(), streamLoop: CancellableTask()
        )
        session.buildings.status = .live
        session.buildings.playerEntityID = 1000
        session.buildings.buildings = [
            3001: RegionBuilding(entityID: 3001, claimEntityID: 2000, buildingDescriptionID: 1200)
        ]
        var crafts: [UInt64: RegionCraft] = [
            // Own completed passive craft — collected in game, never listed
            // or counted.
            1: RegionCraft(
                entityID: 1, ownerEntityID: 1000, buildingEntityID: 3001, recipeID: 77,
                kind: .passive(status: .complete, startedAtMicros: 0)
            )
        ]
        for id: UInt64 in 2...6 {
            crafts[id] = RegionCraft(
                entityID: id, ownerEntityID: 1000, buildingEntityID: 3001, recipeID: 77,
                kind: .passive(status: .queued, startedAtMicros: 0)
            )
        }
        for id: UInt64 in 7...14 {
            crafts[id] = RegionCraft(
                entityID: id, ownerEntityID: 2002, buildingEntityID: 3001, recipeID: 77,
                kind: .passive(status: .queued, startedAtMicros: 0)
            )
        }
        session.buildings.crafts = crafts

        let projected = WorkstationsRep.from(session: session, cap: 3)
        // The completed craft is dropped everywhere; the station's pill
        // counts the player's 5 pending, and only own crafts become rows:
        // 3 fit the cap, 2 overflow. The neighbors' 8 queued passive
        // crafts surface nowhere (private, like the game shows them).
        #expect(projected.buildings[0].myCraftCount == 5)
        #expect(projected.crafts.count == 3)
        #expect(!projected.crafts.contains { $0.phase == .complete })
        #expect(projected.craftsOverflow == 2)
    }

    @Test func projectionRendersOwnAndSharedCraftsOnly() {
        var session = EphemeralState.Session(
            entityID: "1000", loop: CancellableTask(), streamLoop: CancellableTask()
        )
        session.buildings.status = .live
        session.buildings.playerEntityID = 1000
        session.buildings.buildings = [
            3001: RegionBuilding(entityID: 3001, claimEntityID: 2000, buildingDescriptionID: 1200),
            3002: RegionBuilding(entityID: 3002, claimEntityID: 2000, buildingDescriptionID: 1200)
        ]
        session.buildings.gamedata = BuildingGamedata(
            // Live-verified shapes: "Saw Exquisite Stripped Wood" carries
            // 145 effort per item — 890 items is a 129,050-effort goal.
            recipeActionsRequired: [2079251095: 145]
        )
        session.buildings.crafts = [
            // Neighbor's shared bench craft, still open — renders a row.
            10: RegionCraft(
                entityID: 10, ownerEntityID: 2002, buildingEntityID: 3001, recipeID: 2079251095,
                kind: .active(progress: 89300, craftCount: 890, preparation: false, lockExpiresAtMicros: 0)
            ),
            // Neighbor's shared bench craft, effort goal reached — the
            // game's station list drops it; so does the projection.
            11: RegionCraft(
                entityID: 11, ownerEntityID: 2002, buildingEntityID: 3001, recipeID: 2079251095,
                kind: .active(progress: 129050, craftCount: 890, preparation: false, lockExpiresAtMicros: 0)
            ),
            // Neighbor's private bench craft — never a row, only "in use".
            12: RegionCraft(
                entityID: 12, ownerEntityID: 2002, buildingEntityID: 3002, recipeID: 2079251095,
                kind: .active(progress: 100, craftCount: 890, preparation: true, lockExpiresAtMicros: 0)
            ),
            // Neighbor's passive queue — private by game design, "in use".
            13: RegionCraft(
                entityID: 13, ownerEntityID: 2002, buildingEntityID: 3002, recipeID: 77,
                kind: .passive(status: .processing, startedAtMicros: 0)
            ),
            // Own craft at a station outside the claim — still a row.
            14: RegionCraft(
                entityID: 14, ownerEntityID: 1000, buildingEntityID: 9001, recipeID: 77,
                kind: .passive(status: .queued, startedAtMicros: 0)
            ),
            // Own bench craft at a claim station — nests under the station.
            15: RegionCraft(
                entityID: 15, ownerEntityID: 1000, buildingEntityID: 3002, recipeID: 77,
                kind: .active(progress: 20, craftCount: 4, preparation: false, lockExpiresAtMicros: 0)
            ),
        ]
        session.buildings.sharedCraftIDs = [10, 11]

        let projected = WorkstationsRep.from(session: session)
        // Rows: the shared-open craft, the own passive away craft, and the
        // own bench craft. Station-then-own-first order.
        #expect(projected.crafts.map(\.entityID) == ["10", "15", "14"])
        #expect(projected.crafts.map(\.mine) == [false, true, true])
        // The effort math the game's bar shows: 89300 of 890 × 145.
        let shared = projected.crafts[0]
        #expect(shared.progress == 89300)
        #expect(shared.progressTotal == 129050)
        #expect(shared.itemCount == 890)
        #expect(shared.phase == .active)
        // Own bench craft without a resolved recipe — no effort goal.
        let own = projected.crafts[1]
        #expect(own.progress == 20)
        #expect(own.progressTotal == nil)
        #expect(own.buildingEntityID == "3002")

        // Station counts: only the player's own crafts pill — others'
        // work (shared-finished, private, abandoned) surfaces nowhere.
        guard let s1 = projected.buildings.first(where: { $0.entityID == "3001" }),
              let s2 = projected.buildings.first(where: { $0.entityID == "3002" }) else {
            Issue.record("expected both stations in the projection")
            return
        }
        #expect(s1.myCraftCount == 0)
        #expect(s2.myCraftCount == 1)
    }

    @Test func projectionFormatsRecipeTemplateNames() {
        var session = EphemeralState.Session(
            entityID: "1000", loop: CancellableTask(), streamLoop: CancellableTask()
        )
        session.buildings.status = .live
        session.buildings.playerEntityID = 1000
        session.buildings.buildings = [
            3001: RegionBuilding(entityID: 3001, claimEntityID: 2000, buildingDescriptionID: 1200)
        ]
        session.buildings.crafts = [
            1: RegionCraft(
                entityID: 1, ownerEntityID: 1000, buildingEntityID: 3001, recipeID: 109005,
                kind: .passive(status: .processing, startedAtMicros: 0)
            )
        ]
        session.buildings.gamedata = BuildingGamedata(
            recipeNames: [109005: "Braid {0} from {1}"],
            recipeInputs: [109005: ItemStackRef(id: 1_464_553_255, isCargo: false)],
            recipeOutputs: [109005: ItemStackRef(id: 1_090_004, isCargo: false)],
            itemNames: [1_090_004: "Rough Rope", 1_464_553_255: "Rough Cloth Strip"]
        )

        let projected = WorkstationsRep.from(session: session)
        #expect(projected.crafts.count == 1)
        #expect(projected.crafts.first?.recipeName == "Braid Rough Rope from Rough Cloth Strip")
    }

    @Test func eventBufferPoolsRowEventsAndFlushesStatusEvents() async {
        // Lock-protected collector — flush callbacks arrive on timer tasks.
        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private var _flushes: [[ClaimBuildingsEvent]] = []
            func append(_ events: [ClaimBuildingsEvent]) { lock.withLock { _flushes.append(events) } }
            var all: [ClaimBuildingsEvent] { lock.withLock { _flushes.flatMap { $0 } } }
            var count: Int { lock.withLock { _flushes.count } }
        }
        let collected = Collector()
        let buffer = RegionBuildingsClient.EventBuffer(flushDelay: 0.05) { events in
            collected.append(events)
        }

        // Row events pool until a status event flushes immediately — and
        // the flush carries them, proving they were held back rather than
        // delivered per push. (No wall-clock "nothing yet" probe: this
        // suite's parallel load stalls tasks unpredictably.)
        buffer.push(.buildingChanged(RegionBuilding(entityID: 3001, claimEntityID: 2000, buildingDescriptionID: 1200)))
        buffer.push(.craftChanged(RegionCraft(
            entityID: 5001, ownerEntityID: 1000, buildingEntityID: 3001, recipeID: 77,
            kind: .passive(status: .processing, startedAtMicros: 0)
        )))
        buffer.push(.live)
        #expect(collected.count == 1)
        #expect(collected.all.count == 3)
        #expect(collected.all.contains(.live))

        // Later row events flush on the window (deadline generous for the
        // same load reasons).
        buffer.push(.nicknameChanged(entityID: 3001, nickname: "Millie"))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && collected.count < 2 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(collected.count == 2)
        #expect(collected.all.last == .nicknameChanged(entityID: 3001, nickname: "Millie"))
    }

    /// A `crafting_recipe_desc` row body — id and name, then exactly the
    /// field prefix the decoder walks: floats, durability, the
    /// building_requirement option, level_requirements, tool_requirements,
    /// consumed_item_stacks, the skip fields, experience_per_progress,
    /// crafted_item_stacks.
    private static func recipeRow(
        id: Int32, name: String,
        levelSkills: [Int32] = [], toolTypes: [Int32] = [],
        inputs: [(id: Int32, isCargo: Bool)] = [],
        outputs: [(id: Int32, isCargo: Bool)] = []
    ) -> Data {
        var w = Wire()
        w.i32(id)
        w.string(name)
        w.f32(2) // time_requirement
        w.f32(3.5) // stamina_requirement
        w.i32(1) // tool_durability_lost
        w.u8(1) // building_requirement: none
        w.u32(UInt32(levelSkills.count))
        for skill in levelSkills {
            w.i32(skill); w.i32(10) // skill_id, level
        }
        w.u32(UInt32(toolTypes.count))
        for tool in toolTypes {
            w.i32(tool); w.i32(3); w.i32(20) // tool_type, level, power
        }
        w.u32(UInt32(inputs.count)) // consumed_item_stacks
        for input in inputs {
            w.i32(input.id); w.i32(1) // item_id, quantity
            w.u8(input.isCargo ? 1 : 0) // item_type tag: 0 Item, 1 Cargo
            w.i32(0) // discovery_score
            w.f32(1) // consumption_chance
        }
        w.u32(0) // discovery_triggers
        w.i32(0) // required_claim_tech_id
        w.i32(0) // full_discovery_score
        w.u32(1) // experience_per_progress
        w.i32(3); w.f32(0.5) // skill_id, quantity
        w.u32(UInt32(outputs.count)) // crafted_item_stacks
        for output in outputs {
            w.i32(output.id); w.i32(1) // item_id, quantity
            w.u8(output.isCargo ? 1 : 0) // item_type tag: 0 Item, 1 Cargo
            w.u8(1) // durability: none
        }
        w.i32(50) // actions_required
        return w.data
    }

    @Test func recipeRowDecodesProfessionSignals() throws {
        // Level-requirement skill wins; the tool type rides along.
        let gated = try RegionGamedataDecoder.recipe(
            Self.recipeRow(id: 77, name: "Oak Plank", levelSkills: [5], toolTypes: [9])
        )
        #expect(gated.id == 77)
        #expect(gated.name == "Oak Plank")
        #expect(gated.skillID == 5)
        #expect(gated.toolTypeID == 9)
        #expect(gated.actionsRequired == 50)

        // Hand recipes: no level gate, profession comes from the tool
        // (e.g. Foraging's Machete) alone.
        let tooled = try RegionGamedataDecoder.recipe(
            Self.recipeRow(id: 78, name: "Plant Fiber", toolTypes: [12])
        )
        #expect(tooled.skillID == nil)
        #expect(tooled.toolTypeID == 12)
    }

    @Test func publicProgressiveActionRowDecodes() throws {
        var w = Wire()
        w.u64(5002); w.u64(3001); w.u64(2002) // entity, building, owner
        let row = try PublicProgressiveActionRow(reader: BSATNReader(data: w.data))
        #expect(row.entityID == 5002)
        #expect(row.buildingEntityID == 3001)
        #expect(row.ownerEntityID == 2002)
        #expect(row.primaryKey == 5002)
        #expect(PublicProgressiveActionRow.tableName == "public_progressive_action_state")
    }

    @Test func recipeRowDecodesTemplateStackRefs() throws {
        // Real shapes from the catalogs: the braid crafts Rough Rope (item
        // 1090004) from Rough Cloth Strip (1464553255)…
        let braid = try RegionGamedataDecoder.recipe(
            Self.recipeRow(
                id: 109005, name: "Braid {0} from {1}", toolTypes: [8],
                inputs: [(id: 1_464_553_255, isCargo: false)],
                outputs: [(id: 1_090_004, isCargo: false)]
            )
        )
        #expect(braid.input == ItemStackRef(id: 1_464_553_255, isCargo: false))
        #expect(braid.output == ItemStackRef(id: 1_090_004, isCargo: false))

        // …and package recipes craft cargo (Rough Wood Log Package,
        // cargo 150000) from an item.
        let pack = try RegionGamedataDecoder.recipe(
            Self.recipeRow(
                id: 60001, name: "Package {1} into {0}",
                inputs: [(id: 1_010_001, isCargo: false)],
                outputs: [(id: 150_000, isCargo: true)]
            )
        )
        #expect(pack.input == ItemStackRef(id: 1_010_001, isCargo: false))
        #expect(pack.output == ItemStackRef(id: 150_000, isCargo: true))

        // No stacks on file → nil refs, the raw-name passthrough case.
        let bare = try RegionGamedataDecoder.recipe(
            Self.recipeRow(id: 79, name: "Scrap {1}", toolTypes: [4])
        )
        #expect(bare.input == nil)
        #expect(bare.output == nil)
    }

    @Test func idNameDecodesItemAndCargoHeads() throws {
        // `item_desc` and `cargo_desc` open with the same id/name pair.
        var w = Wire()
        w.i32(1_090_004); w.string("Rough Rope")
        let item = try RegionGamedataDecoder.idName(w.data)
        #expect(item.id == 1_090_004)
        #expect(item.name == "Rough Rope")

        var c = Wire()
        c.i32(150_000); c.string("Rough Wood Log Package")
        let cargo = try RegionGamedataDecoder.idName(c.data)
        #expect(cargo.id == 150_000)
        #expect(cargo.name == "Rough Wood Log Package")
    }

    @Test func recipeDisplayNamesResolveTemplates() {
        let gamedata = BuildingGamedata(
            recipeNames: [
                109005: "Braid {0} from {1}",
                14000: "Craft {0}",
                60001: "Package {1} into {0}",
                77: "Oak Plank",
                78: "Scrap {1}"
            ],
            recipeInputs: [
                109005: ItemStackRef(id: 1_464_553_255, isCargo: false),
                60001: ItemStackRef(id: 1_010_001, isCargo: false)
            ],
            recipeOutputs: [
                109005: ItemStackRef(id: 1_090_004, isCargo: false),
                14000: ItemStackRef(id: 11_014, isCargo: false),
                60001: ItemStackRef(id: 150_000, isCargo: true)
            ],
            itemNames: [
                1_090_004: "Rough Rope", 1_464_553_255: "Rough Cloth Strip",
                11_014: "Flint Axe", 1_010_001: "Rough Wood Log"
            ],
            cargoNames: [150_000: "Rough Wood Log Package"]
        )
        #expect(gamedata.recipeDisplayName(109005) == "Braid Rough Rope from Rough Cloth Strip")
        #expect(gamedata.recipeDisplayName(14000) == "Craft Flint Axe")
        #expect(gamedata.recipeDisplayName(60001) == "Package Rough Wood Log into Rough Wood Log Package")
        // Literal names pass through untouched.
        #expect(gamedata.recipeDisplayName(77) == "Oak Plank")
        // Unknown recipe → nil (the view's "Recipe <id>" fallback).
        #expect(gamedata.recipeDisplayName(999) == nil)
        // A template whose referenced stack is missing keeps the raw
        // column — never a half-substituted string.
        #expect(gamedata.recipeDisplayName(78) == "Scrap {1}")
    }

    @Test func toolTypeDescRowDecodes() throws {
        var w = Wire()
        w.i32(12); w.string("Machete"); w.i32(14) // id, name, skill_id (Foraging)
        let tool = try RegionGamedataDecoder.toolTypeDesc(w.data)
        #expect(tool.id == 12)
        #expect(tool.name == "Machete")
        #expect(tool.skillID == 14)
    }

    @Test func skillIDsResolveToProfessions() {
        // The live `skill_desc` catalog (relay region mirror, 2026-09-27).
        let cases: [(Int32, Profession?)] = [
            (0, nil), // no-skill sentinel (Mallet)
            (1, nil), // ANY
            (2, .forestry),
            (3, .carpentry),
            (4, .masonry),
            (5, .mining), // the Smash-stone recipes' skill
            (6, .smithing),
            (7, .scholar),
            (8, .leatherworking),
            (9, .hunting),
            (10, .tailoring),
            (11, .farming),
            (12, .fishing),
            (13, nil), // Cooking — no group of its own
            (14, .foraging),
            (15, nil), // Construction
            (17, nil), // Taming
            (22, nil), // Hexite Gathering
        ]
        for (skill, expected) in cases {
            #expect(Profession.from(skillID: skill) == expected, "skill \(skill) → \(String(describing: expected))")
        }
    }

    @Test func stationNamesResolveToProfessions() {
        // One name per family, straight from the building_desc catalog —
        // tiered stations, ancient variants, and the classical workstations.
        let cases: [(String, Profession?)] = [
            ("Simple Carpentry Station", .carpentry),
            ("Ancient Forestry Station", .forestry),
            ("Peerless Masonry Station", .masonry),
            ("Ancient Kiln", .masonry),
            ("Rough Grinder", .masonry),
            ("Exquisite Mining Station", .mining),
            ("Flawless Smelter", .smithing),
            ("Smithing Station", .smithing),
            ("Fine Scholar Station", .scholar),
            ("Sturdy Tanning Tub", .leatherworking),
            ("Leatherworking Station", .leatherworking),
            ("Magnificent Hunting Station", .hunting),
            ("Ornate Loom", .tailoring),
            ("Tailoring Station", .tailoring),
            ("Farming Station", .farming),
            ("Large Farming Field", .farming),
            ("Farmer's Garden", .farming),
            ("Simple Fishing Station", .fishing),
            ("Foraging Station", .foraging),
            // No group of their own — the tab files these under Other.
            ("Cooking Station", nil),
            ("Ancient Oven", nil),
            ("Crude Workbench", nil),
            ("Taming Station", nil),
            ("Sailing Station", nil),
            ("Construction Station", nil),
            ("Ancient Well", nil),
        ]
        for (name, expected) in cases {
            #expect(Profession.from(stationName: name) == expected, "\(name) → \(String(describing: expected))")
        }
    }

    @Test func projectionCarriesProfessions() {
        var session = EphemeralState.Session(
            entityID: "1000", loop: CancellableTask(), streamLoop: CancellableTask()
        )
        session.buildings.status = .live
        session.buildings.playerEntityID = 1000
        session.buildings.gamedata = BuildingGamedata(
            buildings: [
                1200: BuildingDescInfo(id: 1200, name: "Simple Masonry Station", functions: [
                    BuildingFunctionInfo(
                        functionType: 22, level: 1, craftingSlots: 2, storageSlots: 0,
                        cargoSlots: 0, refiningSlots: 0, refiningCargoSlots: 0
                    )
                ])
            ],
            recipeNames: [77: "Rough Brick"],
            recipeSkills: [77: 4] // Masonry (skill_desc id)
        )
        session.buildings.buildings = [
            3001: RegionBuilding(entityID: 3001, claimEntityID: 2000, buildingDescriptionID: 1200)
        ]
        session.buildings.crafts = [
            5001: RegionCraft(
                entityID: 5001, ownerEntityID: 1000, buildingEntityID: 3001, recipeID: 77,
                kind: .passive(status: .processing, startedAtMicros: 0)
            ),
            // A recipe the catalog never resolved — stays nil (→ Other).
            5002: RegionCraft(
                entityID: 5002, ownerEntityID: 1000, buildingEntityID: 3001, recipeID: 999,
                kind: .passive(status: .queued, startedAtMicros: 0)
            )
        ]

        let projected = WorkstationsRep.from(session: session)
        #expect(projected.buildings[0].profession == .masonry)
        let brick = projected.crafts.first { $0.entityID == "5001" }
        #expect(brick?.profession == .masonry)
        #expect(brick?.buildingEntityID == "3001")
        let unresolved = projected.crafts.first { $0.entityID == "5002" }
        #expect(unresolved?.profession == nil)
    }

    // MARK: - Machine flow

    /// A fabricated region leg — a not-connected SDK client is enough; the
    /// identity is all the machine flow needs.
    private static func makeLeg() -> RegionLeg {
        let client = try! SpacetimeDBClient(host: "wss://region.test.invalid", db: "bitcraft-live-14")
        return RegionLeg(client: client)
    }

    private static func syncScript() -> SimulatedClaimBuildings.Script {
        let gamedata = BuildingGamedata(
            buildings: [
                1007: BuildingDescInfo(id: 1007, name: "Storage Hut", functions: [
                    BuildingFunctionInfo(
                        functionType: 3, level: 1, craftingSlots: 0, storageSlots: 18,
                        cargoSlots: 0, refiningSlots: 0, refiningCargoSlots: 0
                    )
                ]),
                1200: BuildingDescInfo(id: 1200, name: "Sawmill", functions: [
                    BuildingFunctionInfo(
                        functionType: 1, level: 2, craftingSlots: 4, storageSlots: 0,
                        cargoSlots: 0, refiningSlots: 0, refiningCargoSlots: 0
                    )
                ]),
            ],
            recipeNames: [77: "Oak Plank"]
        )
        return SimulatedClaimBuildings.Script(events: [
            .gamedata(gamedata),
            .syncing,
            .live,
            .claim(ClaimHeader(entityID: 2000, name: "Emberfall", ownerPlayerEntityID: 1000, neutral: false)),
            .buildingChanged(RegionBuilding(entityID: 3001, claimEntityID: 2000, buildingDescriptionID: 1200)),
            .buildingChanged(RegionBuilding(entityID: 3002, claimEntityID: 2000, buildingDescriptionID: 1007)),
            .buildingChanged(RegionBuilding(entityID: 3003, claimEntityID: 2000, buildingDescriptionID: 999)),
            .nicknameChanged(entityID: 3001, nickname: "Millie"),
            .craftChanged(RegionCraft(
                entityID: 5001, ownerEntityID: 1000, buildingEntityID: 3001, recipeID: 77,
                kind: .passive(status: .processing, startedAtMicros: 0)
            )),
            .craftChanged(RegionCraft(
                entityID: 5002, ownerEntityID: 2002, buildingEntityID: 3001, recipeID: 77,
                kind: .active(progress: 3, craftCount: 5, preparation: false, lockExpiresAtMicros: 0)
            )),
            // The neighbor opens the same bench craft to the claim — it
            // enters the game's shared projection and becomes a row.
            .sharedCraftChanged(5002),
            // Completed passive crafts are collected in game — the
            // projection drops them instead of listing them.
            .craftChanged(RegionCraft(
                entityID: 5003, ownerEntityID: 1000, buildingEntityID: 3001, recipeID: 77,
                kind: .passive(status: .complete, startedAtMicros: 0)
            )),
        ], hold: true)
    }

    @Test func regionLegStartsTheSyncAndProjectsTheWorkstations() async throws {
        let leg = Self.makeLeg()
        let claimBuildings = SimulatedClaimBuildings(scripts: [Self.syncScript()])
        let globalSession = AccountDrivenSignInTests.SimulatedGlobalSession(
            scripts: [.init(events: [.regionLeg(leg), .established], hold: true)]
        )
        let machine = AccountDrivenSignInTests().makeMachine(
            link: .init(outcome: .player(AccountDrivenSignInTests.player)),
            globalSession: globalSession,
            claimBuildings: claimBuildings
        )

        await machine.start()

        // Email → code → the account link lands on the gate. The code can
        // only be submitted once the request has landed it in `awaitingCode`
        // (the mutate no-ops otherwise, like the real screen's disabled form).
        await machine.ingest(Intent.StartBitCraftSignIn(email: "crafter@example.com"))
        _ = await collectUntil(machine) { rep in
            if case .signIn(let signIn) = rep, case .awaitingCode = signIn.phase { return true }
            return false
        }
        await machine.ingest(Intent.SubmitAccessCode(code: "123456"))
        _ = await collectUntil(machine) { rep in
            if case .gameSessionPrompt(let prompt) = rep, prompt.claimName != nil { return true }
            return false
        }

        // Take the game session: the region leg arrives, the sync starts,
        // and the joined workstations land on the workstations channel
        // (`workstationsRep` — the session rep does not carry a copy).
        await machine.ingest(Intent.SignInGameSession())
        // Events arrive as individual intents (one rep each) — wait for the
        // script's terminal state, not the first `.live`: the shared-craft
        // event is the last one that moves the craft rows.
        guard let stations = await RepCollecting.collect(
            machine.workstationsRep,
            until: { $0.crafts.count == 2 && $0.buildings.first?.myCraftCount == 1 }
        ) else {
            Issue.record("expected the projected workstations on the channel")
            return
        }
        #expect(stations.status == .live)

        // The sync was asked about the claim the character stands in
        // (relay snapshot's entity id) and the account's own player.
        #expect(claimBuildings.requests == [.init(claim: 2000, player: 1000)])
        #expect(claimBuildings.legs == [ObjectIdentifier(leg)])

        // Buildings: crafting first (nickname wins), then storage; the
        // unknown catalog id falls back to "Building <id>".
        #expect(stations.buildings.map(\.name) == ["Millie", "Storage Hut", "Building 3003"])
        #expect(stations.buildings.map(\.isCrafting) == [true, false, false])
        guard stations.buildings.count == 3 else {
            Issue.record("expected all three buildings in the projection")
            return
        }
        // Millie carries the player's own processing craft (the pill); the
        // neighbor's bench craft entered the shared projection, so it
        // renders as a row too. The completed craft is excluded from
        // everything.
        #expect(stations.buildings[0].myCraftCount == 1)
        #expect(stations.buildings[1].myCraftCount == 0)

        // Craft rows: the player's own first, then the neighbor's shared
        // bench craft (marked not-mine; no effort goal — the catalog
        // script carries no `actions_required`).
        #expect(stations.crafts.count == 2)
        let own = stations.crafts[0]
        #expect(own.mine == true)
        #expect(own.recipeName == "Oak Plank")
        #expect(own.stationName == "Millie")
        #expect(own.buildingEntityID == "3001")
        #expect(own.phase == .processing)
        let shared = stations.crafts[1]
        #expect(shared.mine == false)
        #expect(shared.phase == .active)
        #expect(shared.progress == 3)
        #expect(shared.itemCount == 5)
        #expect(shared.progressTotal == nil)
        await machine.ingest(Intent.SignOut()) // retire the loops
    }

    @Test func endedSessionTearsDownTheSync() async throws {
        let leg = Self.makeLeg()
        let claimBuildings = SimulatedClaimBuildings(scripts: [Self.syncScript()])
        let globalSession = AccountDrivenSignInTests.SimulatedGlobalSession(
            scripts: [.init(events: [.regionLeg(leg), .established], hold: true)]
        )
        let machine = AccountDrivenSignInTests().makeMachine(
            link: .init(outcome: .player(AccountDrivenSignInTests.player)),
            globalSession: globalSession,
            claimBuildings: claimBuildings
        )

        await machine.start()
        await machine.ingest(Intent.StartBitCraftSignIn(email: "crafter@example.com"))
        _ = await collectUntil(machine) { rep in
            if case .signIn(let signIn) = rep, case .awaitingCode = signIn.phase { return true }
            return false
        }
        await machine.ingest(Intent.SubmitAccessCode(code: "123456"))
        _ = await collectUntil(machine) { rep in
            if case .gameSessionPrompt(let prompt) = rep, prompt.claimName != nil { return true }
            return false
        }
        await machine.ingest(Intent.SignInGameSession())
        _ = await RepCollecting.collect(machine.workstationsRep, until: { $0.crafts.count == 2 })

        // Another device takes the account's session: every held socket
        // closes, the app returns to the gate, and the buildings sync is
        // cancelled with it.
        globalSession.endHeld()
        _ = await collectUntil(machine) { rep in
            if case .gameSessionPrompt(let prompt) = rep, prompt.claimName != nil { return true }
            return false
        }
        #expect(await Self.waitForTermination(of: claimBuildings))
        await machine.ingest(Intent.SignOut()) // retire the loops
    }

    /// The opt-in ingest trace (`StateMachine.setIngestTracer`): one line
    /// per intent naming the state its mutation produced. The line is the
    /// one-run answer to "the UI shows X but the wire said Y" — here it
    /// must surface the sign-in phases as they happen and the raw
    /// buildings/crafts/catalog counts (projection filtering is not its
    /// business).
    @Test func ingestTracerSummarizesStatePerIntent() async throws {
        final class TraceCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var _lines: [String] = []
            func append(_ line: String) { lock.withLock { _lines.append(line) } }
            var lines: [String] { lock.withLock { _lines } }
        }
        let traces = TraceCollector()
        let leg = Self.makeLeg()
        let claimBuildings = SimulatedClaimBuildings(scripts: [Self.syncScript()])
        let globalSession = AccountDrivenSignInTests.SimulatedGlobalSession(
            scripts: [.init(events: [.regionLeg(leg), .established], hold: true)]
        )
        let machine = AccountDrivenSignInTests().makeMachine(
            link: .init(outcome: .player(AccountDrivenSignInTests.player)),
            globalSession: globalSession,
            claimBuildings: claimBuildings
        )
        await machine.setIngestTracer { traces.append($0) }

        await machine.start()
        await machine.ingest(Intent.StartBitCraftSignIn(email: "crafter@example.com"))
        _ = await collectUntil(machine) { rep in
            if case .signIn(let signIn) = rep, case .awaitingCode = signIn.phase { return true }
            return false
        }
        await machine.ingest(Intent.SubmitAccessCode(code: "123456"))
        _ = await collectUntil(machine) { rep in
            if case .gameSessionPrompt(let prompt) = rep, prompt.claimName != nil { return true }
            return false
        }
        await machine.ingest(Intent.SignInGameSession())
        _ = await RepCollecting.collect(machine.workstationsRep, until: { $0.crafts.count == 2 })
        await machine.ingest(Intent.SignOut()) // retire the loops

        let lines = traces.lines
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { $0.contains(" → screen=") })

        // The sign-in flow's phases are visible as they happen.
        #expect(lines.contains {
            $0.hasPrefix("StartBitCraftSignIn → screen=signin phase=requestingCode acts=1")
        })
        #expect(lines.contains {
            $0.hasPrefix("SubmitAccessCode → screen=signin phase=authenticating acts=1")
        })

        // The buildings summary: raw counts (the completed craft included)
        // plus catalog coverage — descs=0 here would name the
        // empty-workstations bug class in one glance.
        guard let last = lines.last(where: { $0.hasPrefix("ClaimBuildingsChanged →") }) else {
            Issue.record("expected a ClaimBuildingsChanged trace line")
            return
        }
        #expect(last.contains("wks=live"))
        #expect(last.contains("claim=\"Emberfall\""))
        #expect(last.contains("b=3"))
        #expect(last.contains("c=3"))
        #expect(last.contains("descs=2"))
        #expect(last.contains("recipes=1"))
        // The classification split: one crafting station (the Sawmill), one
        // storage hut, one unclassified — the empty-workstations tell.
        #expect(last.contains("wkCraft=1"))
        #expect(last.contains("wkStore=1"))
        #expect(last.contains("map=off"))
    }

    @Test func claimMembershipDecodesInSchemaOrder() throws {
        // entity_id, claim_entity_id, player_entity_id, user_name, four
        // permission flags — declaration order (bitjita-schema-region.json).
        var w = Wire()
        w.u64(7001); w.u64(2000); w.u64(1000)
        w.string("Maplesugar")
        w.boolean(true); w.boolean(true); w.boolean(false); w.boolean(false)
        let member = try RegionGamedataDecoder.claimMembership(w.data)
        #expect(member.entityID == 7001)
        #expect(member.claimEntityID == 2000)
        #expect(member.playerEntityID == 1000)
    }

    // MARK: - Claim-resolution fallback (protocol doc §2)

    /// Collecting ingestor + fallback counter for the loop-level tests.
    private final class LoopHarness: @unchecked Sendable {
        final class Ingested: IntentIngestor, @unchecked Sendable {
            private let lock = NSLock()
            private var _pooledEventCounts: [Int] = []
            func ingest(_ intent: Sendable) async {
                guard let changed = intent as? Intent.ClaimBuildingsChanged else { return }
                lock.withLock { _pooledEventCounts.append(changed.events.count) }
            }
            var pooledEventCounts: [Int] { lock.withLock { _pooledEventCounts } }
        }

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _calls: [UInt64] = []
            func record(_ player: UInt64) { lock.withLock { _calls.append(player) } }
            var calls: [UInt64] { lock.withLock { _calls } }
        }

        let ingested = Ingested()
        let fallbackCalls = Counter()

        func adapters(claimBuildings: SimulatedClaimBuildings, membership: UInt64?) -> Adapters {
            let fallbackCalls = fallbackCalls
            return Adapters(
                relay: .init(
                    resolve: { _ in throw RelayError.notFound },
                    session: { _ in throw RelayError.notFound },
                    sessionResources: { _ in throw RelayError.notFound },
                    resourceDictionary: { _ in throw RelayError.notFound },
                    worldElevation: { _, _ in throw RelayError.notFound },
                    openResourceStream: { _ in AsyncStream { _ in } }
                ),
                bitCraft: .init(
                    requestAccessCode: { _ in },
                    authenticate: { _, _ in "test-token" },
                    resolveAccountPlayer: { _, _ in throw URLError(.badServerResponse) },
                    openGlobalSession: { _, _, _, _, _ in AsyncStream { _ in } },
                    syncClaimBuildings: { leg, claim, player in
                        claimBuildings.open(leg: leg, claim: claim, player: player)
                    },
                    resolveOwnClaimMembership: { _, player in
                        fallbackCalls.record(player)
                        return membership
                    }
                ),
                loadFoodBuffGamedata: { nil },
                restoreIdentity: { nil },
                persistIdentity: { _ in },
                restoreBitCraftAccount: { nil },
                persistBitCraftAccount: { _ in },
                sleep: { _ in } // instant — the wait spins at task speed
            )
        }
    }

    /// The relay never answers the claim: after the carrier wait lapses,
    /// the loop asks the leg for the player's own membership and syncs the
    /// claim it names.
    @Test func claimResolutionFallsBackToMembershipWhenTheRelayNeverAnswers() async {
        let leg = Self.makeLeg()
        let claimBuildings = SimulatedClaimBuildings(scripts: [
            .init(events: [.live, .claim(ClaimHeader(
                entityID: 2000, name: "Emberfall", ownerPlayerEntityID: 1000, neutral: false
            ))], hold: false)
        ])
        let harness = LoopHarness()
        let carrier = ClaimCarrier() // never stamped — the relay never answers
        await Activity.ClaimBuildingsLoop(
            leg: leg, playerEntityID: 1000, claimCarrier: carrier, cancellable: CancellableTask()
        ).start(
            ingestor: harness.ingested,
            adapters: harness.adapters(claimBuildings: claimBuildings, membership: 2000)
        )

        #expect(claimBuildings.requests == [.init(claim: 2000, player: 1000)])
        #expect(harness.fallbackCalls.calls == [1000])
        #expect(!harness.ingested.pooledEventCounts.isEmpty)
    }

    /// The relay's answer wins: a stamped carrier means the fallback is
    /// never asked.
    @Test func claimResolutionPrefersTheRelayAnswerOverTheFallback() async {
        let leg = Self.makeLeg()
        let claimBuildings = SimulatedClaimBuildings(scripts: [
            .init(events: [.live], hold: false)
        ])
        let harness = LoopHarness()
        let carrier = ClaimCarrier()
        carrier.claimEntityID = 2001 // the relay already answered
        await Activity.ClaimBuildingsLoop(
            leg: leg, playerEntityID: 1000, claimCarrier: carrier, cancellable: CancellableTask()
        ).start(
            ingestor: harness.ingested,
            adapters: harness.adapters(claimBuildings: claimBuildings, membership: 2000)
        )

        #expect(claimBuildings.requests == [.init(claim: 2001, player: 1000)])
        #expect(harness.fallbackCalls.calls.isEmpty)
    }

    // MARK: - Catalog cache (48 h TTL, the food-buff gamedata policy)

    @Test func buildingGamedataCacheRoundTripsAndExpires() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitme-test-region-gamedata-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let gamedata = BuildingGamedata(
            buildings: [
                1200: BuildingDescInfo(id: 1200, name: "Sawmill", functions: [
                    BuildingFunctionInfo(
                        functionType: 1, level: 2, craftingSlots: 4, storageSlots: 0,
                        cargoSlots: 0, refiningSlots: 0, refiningCargoSlots: 0
                    )
                ])
            ],
            recipeNames: [77: "Oak Plank"],
            fetchedAt: .now
        )
        RegionBuildingsClient.writeBuildingGamedataCache(gamedata, at: url)

        let loaded = RegionBuildingsClient.cachedBuildingGamedata(at: url)
        #expect(loaded == gamedata)
        #expect(loaded?.isStale() == false)
        #expect(loaded?.buildings[1200]?.isCrafting == true)
        #expect(loaded?.recipeNames[77] == "Oak Plank")

        // The 48 h TTL boundary (inclusive, like FoodBuffGamedata).
        #expect(gamedata.isStale(now: .now.addingTimeInterval(48 * 3_600)) == true)
        #expect(gamedata.isStale(now: .now.addingTimeInterval(47 * 3_600)) == false)

        // Missing file → nil, not a crash.
        #expect(RegionBuildingsClient.cachedBuildingGamedata(
            at: url.deletingLastPathComponent().appendingPathComponent("does-not-exist.json")
        ) == nil)

        // Empty reads as always-stale — nothing may be "fresh" about not
        // having the catalogs.
        #expect(BuildingGamedata.empty.isStale())
    }

    /// The workstations channel (`machine.workstationsRep`, the `mapRep`
    /// precedent): the join's projection publishes when the buildings state
    /// moves — and only then. Poll-only ingests (stamina ticks, snapshot
    /// refreshes) land in between without rebroadcasting it; teardown
    /// publishes the empty projection once.
    @Test func workstationsChannelPublishesOnlyOnBuildingsChanges() async throws {
        final class ChannelCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var _reps: [WorkstationsRep] = []
            func append(_ rep: WorkstationsRep) { lock.withLock { _reps.append(rep) } }
            var count: Int { lock.withLock { _reps.count } }
            var reps: [WorkstationsRep] { lock.withLock { _reps } }
        }
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            func bump() { lock.withLock { _count += 1 } }
            var count: Int { lock.withLock { _count } }
        }

        let leg = Self.makeLeg()
        let claimBuildings = SimulatedClaimBuildings(scripts: [Self.syncScript()])
        let globalSession = AccountDrivenSignInTests.SimulatedGlobalSession(
            scripts: [.init(events: [.regionLeg(leg), .established], hold: true)]
        )
        let machine = AccountDrivenSignInTests().makeMachine(
            link: .init(outcome: .player(AccountDrivenSignInTests.player)),
            globalSession: globalSession,
            claimBuildings: claimBuildings
        )
        let traceCount = Counter()
        await machine.setIngestTracer { _ in traceCount.bump() }
        let channel = ChannelCollector()
        let sinkTask = machine.workstationsRep.sink { channel.append($0) }
        defer { sinkTask.cancel() }

        await machine.start()
        await machine.ingest(Intent.StartBitCraftSignIn(email: "crafter@example.com"))
        _ = await collectUntil(machine) { rep in
            if case .signIn(let signIn) = rep, case .awaitingCode = signIn.phase { return true }
            return false
        }
        await machine.ingest(Intent.SubmitAccessCode(code: "123456"))
        _ = await collectUntil(machine) { rep in
            if case .gameSessionPrompt(let prompt) = rep, prompt.claimName != nil { return true }
            return false
        }
        await machine.ingest(Intent.SignInGameSession())
        // The channel replays .empty on subscribe, then carries the live
        // projection once the buildings state lands.
        await Self.waitFor { channel.reps.contains { $0.status == .live && $0.crafts.count == 2 } }
        let channelCount = channel.count
        let ingestBaseline = traceCount.count

        // Session polls keep ingesting (stamina/snapshot-only changes) —
        // after five of them, not one rebroadcast the channel.
        await Self.waitFor { traceCount.count - ingestBaseline >= 5 }
        #expect(channel.count == channelCount)

        // Teardown is a buildings-state move: exactly one more publish,
        // the empty projection.
        await machine.ingest(Intent.SignOut())
        await Self.waitFor { channel.reps.last == .empty }
        #expect(channel.count == channelCount + 1)
    }

    // MARK: - Helpers

    /// Polls a condition with a timeout backstop (positive waits only —
    /// negative assertions are made only after their causes were observed).
    private static func waitFor(
        _ condition: @Sendable () -> Bool,
        timeout: TimeInterval = 10
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Collects CrafterReps until `finished` matches (event-driven — see
    /// `RepCollecting.collect`; the timeout is a broken-flow backstop);
    /// returns the first matching rep.
    private func collectUntil(
        _ machine: StateMachine,
        until finished: @Sendable @escaping (CrafterRep) -> Bool,
        timeout: TimeInterval = 10
    ) async -> CrafterRep? {
        let collector = AccountDrivenSignInTests.RepCollector()
        await RepCollecting.collect(
            machine.crafterRep,
            onRep: { collector.append($0) },
            until: finished, timeout: timeout
        )
        return collector.last(where: finished)
    }

    private static func waitForTermination(
        of sync: SimulatedClaimBuildings, timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sync.terminated > 0 { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return sync.terminated > 0
    }
}

/// Scripted claim-buildings sync (the region-leg subscription stream):
/// records the leg/claim/player it was asked about and answers from a
/// queued script; connections beyond the script queue hold silently.
final class SimulatedClaimBuildings: @unchecked Sendable {
    struct Request: Equatable {
        let claim: UInt64
        let player: UInt64
    }

    struct Script: Sendable {
        let events: [ClaimBuildingsEvent]
        let hold: Bool
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _legs: [ObjectIdentifier] = []
    private var _scripts: [Script]
    private var _terminated = 0
    private var _held: [AsyncStream<[ClaimBuildingsEvent]>.Continuation] = []

    init(scripts: [Script] = []) {
        self._scripts = scripts
    }

    var requests: [Request] { lock.withLock { _requests } }
    var legs: [ObjectIdentifier] { lock.withLock { _legs } }
    var terminated: Int { lock.withLock { _terminated } }

    func endHeld() {
        let held = lock.withLock {
            let copy = _held
            _held.removeAll()
            return copy
        }
        held.forEach { $0.finish() }
    }

    func open(leg: RegionLeg, claim: UInt64, player: UInt64) -> AsyncStream<[ClaimBuildingsEvent]> {
        let script = lock.withLock {
            _requests.append(Request(claim: claim, player: player))
            _legs.append(ObjectIdentifier(leg))
            return _scripts.isEmpty
                ? Script(events: [.live], hold: true)
                : _scripts.removeFirst()
        }
        return AsyncStream { continuation in
            for event in script.events {
                // One event per array — the production client pools ~0.5 s
                // of rows per flush; batching is invisible to these flows.
                continuation.yield([event])
            }
            if script.hold {
                lock.withLock { _held.append(continuation) }
            } else {
                continuation.finish()
            }
            continuation.onTermination = { [self] _ in
                lock.withLock { _terminated += 1 }
            }
        }
    }
}

