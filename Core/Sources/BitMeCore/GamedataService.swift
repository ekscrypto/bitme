import Foundation
import os

let gamedataLog = Logger(subsystem: "life.encoded.bitme.ios", category: "gamedata")

/// Static gamedata fetched live from the relay's global mirror and cached in
/// the app for 48 h (per design: docs/tutorial + relay assessment §2 — the
/// local static-gamedata exports have gone stale before, so live fetch beats
/// bundling for tables the relay already serves).
public struct FoodBuffGamedata: Codable, Equatable, Sendable {
    public static let ttl: TimeInterval = 48 * 60 * 60

    /// `buff_desc.id` values whose `buff_type_id` resolves to a food type.
    public let foodBuffIDs: Set<Int>
    /// `buff_desc` display metadata by buff id — every buff, not just food:
    /// the food card names and details each live buff it lists.
    public let buffs: [Int: BuffInfo]
    public let fetchedAt: Date

    public init(foodBuffIDs: Set<Int>, buffs: [Int: BuffInfo] = [:], fetchedAt: Date) {
        self.foodBuffIDs = foodBuffIDs
        self.buffs = buffs
        self.fetchedAt = fetchedAt
    }

    public func isStale(now: Date = .now) -> Bool {
        now.timeIntervalSince(fetchedAt) >= FoodBuffGamedata.ttl
    }
}

/// One stat modifier of a buff (`buff_desc.stats` entries:
/// `[[stat_id, modifiers], value, is_percent]`).
public struct BuffStat: Codable, Equatable, Hashable, Sendable {
    public let statID: Int
    public let value: Double
    /// true → `value` is a fraction of the stat (0.041 = +4.1%); false → flat.
    public let isPercent: Bool

    public init(statID: Int, value: Double, isPercent: Bool) {
        self.statID = statID
        self.value = value
        self.isPercent = isPercent
    }

    /// Static stat id → label. The mirror serves no `stat_desc` table, so
    /// names come from the game's `CharacterStatType` enum (BitCraftPublic
    /// `static_data.rs`, 0-based; verified against live `buff_desc` rows —
    /// e.g. "Emperor's Gift of Stamina" +50 → stat 1, "Level 1 Combat
    /// Cooldown" +4.1% → stat 8). Unknown ids fall back to "Stat <id>".
    public var label: String {
        Self.statNames[statID] ?? "Stat \(statID)"
    }

    /// Player-facing stat names keyed by `CharacterStatType` ordinal. The
    /// professions repeat through the enum (speed 21–33, power 34–46, crit
    /// chance 55–66, crit multiplier 67–78) — but the crit blocks have no
    /// Cooking entry, so they're twelve long, not thirteen.
    private static let statNames: [Int: String] = {
        var names: [Int: String] = [
            0: "Max Health",
            1: "Max Stamina",
            2: "Health Regen",
            3: "Stamina Regen",
            4: "Movement Speed",
            5: "Sprint Speed", // deprecated
            6: "Sprint Stamina Drain", // deprecated
            7: "Armor",
            8: "Combat Cooldown",
            9: "Hunting Weapon Power",
            10: "Strength",
            11: "Cold Protection",
            12: "Heat Protection",
            13: "Evasion",
            14: "Toolbelt Slots",
            15: "Crafting Speed",
            16: "Gathering Speed",
            17: "Construction Speed",
            18: "Satiation Regen",
            19: "Max Satiation",
            20: "Defense Level",
            47: "Active Health Regen",
            48: "Active Stamina Regen",
            49: "Climb Proficiency",
            50: "Experience Rate",
            51: "Accuracy",
            52: "Max Teleport Energy",
            53: "Teleport Energy Regen",
            54: "Construction Power",
            79: "Hexite Gathering Power",
            80: "Hexite Gathering Speed",
            81: "Hexite Crit Chance",
            82: "Hexite Crit Multiplier",
            83: "Cart Speed",
            84: "Mount Speed",
            85: "Boat Speed",
        ]
        let professions = [
            "Forestry", "Carpentry", "Masonry", "Mining", "Smithing", "Scholar",
            "Leatherworking", "Hunting", "Tailoring", "Farming", "Fishing",
            "Cooking", "Foraging",
        ]
        let critProfessions = professions.filter { $0 != "Cooking" }
        for (offset, profession) in professions.enumerated() {
            names[21 + offset] = "\(profession) Speed"
            names[34 + offset] = "\(profession) Power"
        }
        for (offset, profession) in critProfessions.enumerated() {
            names[55 + offset] = "\(profession) Crit Chance"
            names[67 + offset] = "\(profession) Crit Multiplier"
        }
        return names
    }()

    /// Stats stored as fractions of a base (0.05 = 5%), so a *flat* modifier
    /// is in percentage points and renders with a "%" too ("Deep Roots"
    /// +0.1 Foraging Crit Chance → "+10%").
    private static let fractionScaleStats: Set<Int> = {
        var ids: Set<Int> = [4, 8, 13, 50, 81, 82, 83, 84, 85]
        ids.formUnion(55...78)
        return ids
    }()

    /// "+19" for a flat bonus, "+4.1%" for a fractional one, "-60%" for a
    /// penalty (sign comes from the value, never doubled).
    public var displayValue: String {
        let asPercent = isPercent || Self.fractionScaleStats.contains(statID)
        let scaled = asPercent ? value * 100 : value
        let sign = scaled < 0 ? "-" : "+"
        return "\(sign)\(Self.trimmed(abs(scaled)))\(asPercent ? "%" : "")"
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    /// Food-card order: stamina regen before health regen (the shape players
    /// know from the game's food tooltip); everything else keeps row order.
    public static func sortedForDisplay(_ stats: [BuffStat]) -> [BuffStat] {
        let rank: [Int: Int] = [3: 0, 2: 1]
        return stats.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.statID] ?? .max
            let r = rank[rhs.element.statID] ?? .max
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }
}

/// `buff_desc` display metadata for one buff id: the human name and the stat
/// modifiers shown under its countdown on the food card.
public struct BuffInfo: Codable, Equatable, Sendable {
    public let name: String
    public let stats: [BuffStat]

    public init(name: String, stats: [BuffStat]) {
        self.name = name
        self.stats = stats
    }
}

public enum GamedataService {
    public static let client = SpacetimeSubscribeClient(
        hostPort: "relay.bitcraftsync.app:3000",
        database: "bitcraft-live-global"
    )

    public static var cacheURL: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bitme-food-buff-gamedata.json")
    }

    /// Cache-first: return the cached set when fresh; otherwise fetch over
    /// the mirror WebSocket and re-cache. If the fetch fails (deploy reseed,
    /// offline), a stale cache is still returned — classifying with old
    /// gamedata beats not classifying at all.
    public static func loadFoodBuffGamedata(now: Date = .now) async -> FoodBuffGamedata? {
        let cached = cachedFoodBuffGamedata()
        if let cached, !cached.isStale(now: now) {
            gamedataLog.info("gamedata cache fresh (\(cached.foodBuffIDs.count) ids)")
            return cached
        }
        do {
            gamedataLog.info("fetching buff gamedata over mirror WS…")
            let fresh = try await fetchFoodBuffGamedata()
            writeCache(fresh)
            gamedataLog.info("gamedata fetched: \(fresh.foodBuffIDs.count) food buff ids")
            return fresh
        } catch {
            gamedataLog.error("gamedata fetch failed: \(String(describing: error), privacy: .public); cached=\(cached != nil)")
            return cached
        }
    }

    public static func fetchFoodBuffGamedata() async throws -> FoodBuffGamedata {
        let rows = try await client.fetchRows(tables: ["buff_type_desc", "buff_desc"])
        let types = try rows["buff_type_desc", default: []].map { try JSONDecoder().decode(BuffTypeDescRow.self, from: $0) }
        let buffs = try rows["buff_desc", default: []].map { try JSONDecoder().decode(BuffDescRow.self, from: $0) }
        var infos: [Int: BuffInfo] = [:]
        for row in buffs {
            guard let name = row.name else { continue }
            infos[row.id] = BuffInfo(name: name, stats: row.stats)
        }
        return FoodBuffGamedata(
            foodBuffIDs: FoodBuffClassification.foodBuffIDs(types: types, buffs: buffs),
            buffs: infos,
            fetchedAt: .now
        )
    }

    // MARK: - Cache I/O

    public static func cachedFoodBuffGamedata(at url: URL = cacheURL) -> FoodBuffGamedata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FoodBuffGamedata.self, from: data)
    }

    public static func writeCache(_ gamedata: FoodBuffGamedata, at url: URL = cacheURL) {
        guard let data = try? JSONEncoder().encode(gamedata) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
