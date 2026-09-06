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
    /// names come from live `buff_desc` rows whose description names a single
    /// stat (e.g. "Level 1 Combat Cooldown" → stat 8, "Level 1 Food Regen"
    /// → stats 2/3). Unknown ids fall back to "Stat <id>".
    public var label: String {
        switch statID {
        case 2: return "Health Regen"
        case 3: return "Stamina Regen"
        case 4: return "Movement Speed"
        case 8: return "Combat Cooldown"
        case 15: return "Crafting Speed"
        case 16: return "Gathering Speed"
        case 17: return "Construction Speed"
        case 47: return "Active Health Regen"
        case 48: return "Active Stamina Regen"
        default: return "Stat \(statID)"
        }
    }

    /// "+19" for a flat bonus, "+4.1%" for a fractional one.
    public var displayValue: String {
        "+\(Self.trimmed(isPercent ? value * 100 : value))\(isPercent ? "%" : "")"
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
