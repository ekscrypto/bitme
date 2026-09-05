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
    public let fetchedAt: Date

    public func isStale(now: Date = .now) -> Bool {
        now.timeIntervalSince(fetchedAt) >= FoodBuffGamedata.ttl
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
        return FoodBuffGamedata(
            foodBuffIDs: FoodBuffClassification.foodBuffIDs(types: types, buffs: buffs),
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
