import Testing
import Foundation
@testable import BitMeCore

/// GamedataService pieces: wire-row decoding, food classification against
/// real live rows (captured 2026-09-05 from `bitcraft-live-global`), 48 h
/// cache staleness, and cache round-trip.
struct GamedataServiceTests {

    // Real live rows: 478954807 is a "Food Buffs" buff seen live on an
    // active player; 5887916 is "Level 6 Deluxe Action Speed" (NOT food —
    // the api.md example buff that proves classification must be type-based);
    // 37 is a short food buff from the Food Buffs family.
    private let typesJSON = """
    [
      {"id": 861783812, "name": "Food Buffs", "category": 1},
      {"id": 1790361536, "name": "Food Regen", "category": 1},
      {"id": 2041496537, "name": "Teas", "category": 1},
      {"id": 351703766, "name": "Accuracy", "category": 1},
      {"id": 2, "name": "Rested", "category": 2}
    ]
    """

    private let buffsJSON = """
    [
      {"id": 478954807, "buff_type_id": 861783812, "description": "Level 7 Deluxe Action Speed", "duration": 180, "beneficial": true, "stats": [[[15,[]],0.094,true],[[16,[]],0.094,true]]},
      {"id": 37, "buff_type_id": 861783812, "duration": 60, "beneficial": true},
      {"id": 123, "buff_type_id": 1790361536, "description": "Level 8 Food Regen", "duration": 60, "stats": [[[2,[]],10.0,false],[[3,[]],19.0,false]]},
      {"id": 5887916, "buff_type_id": 351703766, "duration": 3600},
      {"id": 999, "buff_type_id": 2, "duration": 1500}
    ]
    """

    @Test func decodingReadsSnakeCaseKeysAndIgnoresUnknownColumns() throws {
        let row = try JSONDecoder().decode(
            BuffDescRow.self,
            from: Data(#"{"id": 478954807, "buff_type_id": 861783812, "duration": 180, "beneficial": true}"#.utf8)
        )
        #expect(row.id == 478_954_807)
        #expect(row.buffTypeID == 861_783_812)
        // Columns we don't model yet, plus absent description/stats, are tolerated.
        #expect(row.name == nil)
        #expect(row.stats.isEmpty)
    }

    @Test func decodingReadsNameAndStatsEntries() throws {
        let row = try JSONDecoder().decode(
            BuffDescRow.self,
            from: Data(#"{"id": 1249248521, "buff_type_id": 1790361536, "description": "Level 8 Food Regen", "stats": [[[2,[]],10.0,false],[[3,[]],19.0,false]]}"#.utf8)
        )
        #expect(row.name == "Level 8 Food Regen")
        #expect(row.stats == [
            BuffStat(statID: 2, value: 10.0, isPercent: false),
            BuffStat(statID: 3, value: 19.0, isPercent: false),
        ])
    }

    @Test func statLabelsValuesAndDisplayOrder() {
        let stamina = BuffStat(statID: 3, value: 19, isPercent: false)
        let health = BuffStat(statID: 2, value: 10, isPercent: false)
        let percent = BuffStat(statID: 15, value: 0.094, isPercent: true)
        let unknown = BuffStat(statID: 601, value: 1, isPercent: false)

        #expect(stamina.label == "Stamina Regen" && stamina.displayValue == "+19")
        #expect(health.label == "Health Regen" && health.displayValue == "+10")
        #expect(percent.label == "Crafting Speed" && percent.displayValue == "+9.4%")
        #expect(unknown.label == "Stat 601")

        // Stamina before health; unknown/other stats keep row order.
        let sorted = BuffStat.sortedForDisplay([health, percent, stamina, unknown])
        #expect(sorted.map(\.statID) == [3, 2, 15, 601])
    }

    @Test func deepRootsAndPenaltyDisplay() {
        // "Deep Roots" (Foraging Charm) carries flat modifiers on
        // fraction-scale stats — +0.1 crit chance / +0.25 crit multiplier.
        let critChance = BuffStat(statID: 66, value: 0.1, isPercent: false)
        let critMultiplier = BuffStat(statID: 78, value: 0.25, isPercent: false)
        #expect(critChance.label == "Foraging Crit Chance" && critChance.displayValue == "+10%")
        #expect(critMultiplier.label == "Foraging Crit Multiplier" && critMultiplier.displayValue == "+25%")

        // "Exquisite Reckless Poison": -60% Max Stamina renders one sign.
        let poison = BuffStat(statID: 1, value: -0.6, isPercent: true)
        #expect(poison.label == "Max Stamina" && poison.displayValue == "-60%")

        // A percent-speed penalty likewise ("Foraging Pie" -0.1).
        let pie = BuffStat(statID: 33, value: -0.1, isPercent: true)
        #expect(pie.label == "Foraging Speed" && pie.displayValue == "-10%")
    }

    @Test func gamedataCarriesBuffMetadata() {
        let gamedata = FoodBuffGamedata(
            foodBuffIDs: [37],
            buffs: [37: BuffInfo(name: "Level 1 Food Buff", stats: [BuffStat(statID: 3, value: 5, isPercent: false)])],
            fetchedAt: .now
        )
        #expect(gamedata.buffs[37]?.name == "Level 1 Food Buff")
        #expect(gamedata.buffs[37]?.stats.first?.displayValue == "+5")
        #expect(gamedata.buffs[999] == nil)
    }

    @Test func classificationPicksFoodTypesOnly() throws {
        let types = try JSONDecoder().decode([BuffTypeDescRow].self, from: Data(typesJSON.utf8))
        let buffs = try JSONDecoder().decode([BuffDescRow].self, from: Data(buffsJSON.utf8))
        let food = FoodBuffClassification.foodBuffIDs(types: types, buffs: buffs)
        #expect(food == [478_954_807, 37, 123])
        #expect(!food.contains(588_7916)) // Action Speed — not food
        #expect(!food.contains(999))      // Rested — not food
    }

    @Test func staleAfter48Hours() {
        let fresh = FoodBuffGamedata(foodBuffIDs: [1], fetchedAt: .now)
        #expect(!fresh.isStale())

        let old = FoodBuffGamedata(foodBuffIDs: [1], fetchedAt: .now.addingTimeInterval(-49 * 3_600))
        #expect(old.isStale())

        let boundary = FoodBuffGamedata(foodBuffIDs: [1], fetchedAt: .now.addingTimeInterval(-48 * 3_600))
        #expect(boundary.isStale())
    }

    @Test func cacheRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitme-test-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = FoodBuffGamedata(foodBuffIDs: [478_954_807, 37], fetchedAt: .now)
        GamedataService.writeCache(original, at: url)

        let loaded = GamedataService.cachedFoodBuffGamedata(at: url)
        #expect(loaded == original)

        // Missing file → nil, not a crash.
        #expect(GamedataService.cachedFoodBuffGamedata(
            at: url.deletingLastPathComponent().appendingPathComponent("does-not-exist.json")
        ) == nil)
    }
}
