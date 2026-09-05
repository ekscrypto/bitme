import Testing
import Foundation
@testable import BitMe

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
      {"id": 478954807, "buff_type_id": 861783812, "duration": 180, "beneficial": true},
      {"id": 37, "buff_type_id": 861783812, "duration": 60, "beneficial": true},
      {"id": 123, "buff_type_id": 1790361536, "duration": 60},
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
