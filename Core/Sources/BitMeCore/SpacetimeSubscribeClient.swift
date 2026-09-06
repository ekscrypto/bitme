import Foundation

/// Typed rows for the two static gamedata tables Bit-Me consumes over the
/// relay's mirror WebSocket. Unknown columns are ignored.
public struct BuffTypeDescRow: Decodable, Equatable, Sendable {
    public let id: Int
    public let name: String
}

public struct BuffDescRow: Decodable, Equatable, Sendable {
    public let id: Int
    public let buffTypeID: Int
    /// Human buff name (wire column `description`).
    public let name: String?
    /// Stat modifiers; [] when absent or shaped unexpectedly.
    public let stats: [BuffStat]

    enum CodingKeys: String, CodingKey {
        case id
        case buffTypeID = "buff_type_id"
        case name = "description"
        case stats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        buffTypeID = try container.decode(Int.self, forKey: .buffTypeID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        stats = (try? Self.decodeStats(container)) ?? []
    }

    /// Entry shape: `[[stat_id, modifiers], value, is_percent]`. The
    /// modifiers list is always empty on the wire; its container is consumed
    /// but not iterated so a future non-empty shape can't fail the row.
    private static func decodeStats(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [BuffStat] {
        var entries = try container.nestedUnkeyedContainer(forKey: .stats)
        var stats: [BuffStat] = []
        while !entries.isAtEnd {
            var entry = try entries.nestedUnkeyedContainer()
            var key = try entry.nestedUnkeyedContainer()
            let statID = try key.decode(Int.self)
            _ = try key.nestedUnkeyedContainer()
            let value = try entry.decode(Double.self)
            let isPercent = try entry.decode(Bool.self)
            stats.append(BuffStat(statID: statID, value: value, isPercent: isPercent))
        }
        return stats
    }
}

public enum FoodBuffClassification {
    /// `buff_type_desc` names whose member buffs count as "food" for the
    /// eat-food indicator. Name-based because `category` is 1 (generic) for
    /// most combat-unrelated types. Adjust here as game knowledge grows.
    public static let foodTypeNames: Set<String> = ["Food Buffs", "Food Regen", "Teas"]

    public static func foodBuffIDs(
        types: [BuffTypeDescRow],
        buffs: [BuffDescRow]
    ) -> Set<Int> {
        let typeIDs = Set(types.filter { foodTypeNames.contains($0.name) }.map(\.id))
        return Set(buffs.filter { typeIDs.contains($0.buffTypeID) }.map(\.id))
    }
}

/// Minimal one-shot client for the relay mirror's SpacetimeDB JSON
/// subscription endpoint (`v1.json.spacetimedb`): connect → `SubscribeSingle`
/// per table → collect each `SubscribeApplied` snapshot → close. No
/// reconnects, no deltas, no reducers — Bit-Me polls HTTP for live data;
/// this exists only for small static tables (`buff_desc`, `buff_type_desc`).
///
/// Wire facts (relay-verified): the first message is an anonymous
/// `IdentityToken`; `query_id` must be an object `{"id": n}` (a bare number
/// hard-closes the socket); literals are inlined in the SQL; u64 ids arrive
/// as raw JSON numbers (fine for Swift Int64); rows arrive as JSON *strings*
/// inside `SubscribeApplied.rows.table_rows.updates[].Uncompressed.inserts`.
public struct SpacetimeSubscribeClient: Sendable {
    enum ClientError: Error, Equatable, Sendable {
        case timeout(String)
        case protocolError(String)
        case connectionClosed
    }

    let hostPort: String
    let database: String
    /// Overall budget for the whole fetch (handshake + all snapshots).
    let timeout: TimeInterval

    init(hostPort: String, database: String, timeout: TimeInterval = 30) {
        self.hostPort = hostPort
        self.database = database
        self.timeout = timeout
    }

    /// Fetch the full snapshot of each table. Row order is not defined.
    func fetchRows(tables: [String]) async throws -> [String: [Data]] {
        var request = URLRequest(
            url: URL(string: "wss://\(hostPort)/v1/database/\(database)/subscribe")!
        )
        request.setValue("v1.json.spacetimedb", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        let task = URLSession(configuration: config).webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let deadline = Date().addingTimeInterval(timeout)

        // 1. Handshake: first message is the anonymous IdentityToken.
        guard let first = try await receiveString(task) else {
            throw ClientError.connectionClosed
        }
        guard let identity = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              identity["IdentityToken"] != nil else {
            throw ClientError.protocolError("first message was not IdentityToken")
        }

        // 2. Subscribe to every table (distinct query ids; inline literals).
        for (index, table) in tables.enumerated() {
            let payload: [String: Any] = [
                "SubscribeSingle": [
                    "query": "SELECT * FROM \(table);",
                    "request_id": index + 1,
                    "query_id": ["id": index + 1],
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            try await send(task, .string(String(data: data, encoding: .utf8)!))
        }

        // 3. Collect one SubscribeApplied per table.
        var result: [String: [Data]] = [:]
        while result.count < tables.count {
            if Date() > deadline {
                throw ClientError.timeout("waiting for \(tables.count - result.count) snapshot(s)")
            }
            guard let text = try await receiveString(task) else {
                throw ClientError.connectionClosed
            }
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                continue
            }
            if json["SubscriptionError"] != nil {
                throw ClientError.protocolError("\(json["SubscriptionError"]!)")
            }
            guard let applied = json["SubscribeApplied"] as? [String: Any],
                  let rows = applied["rows"] as? [String: Any],
                  let tableRows = rows["table_rows"] as? [String: Any],
                  let updates = tableRows["updates"] as? [[String: Any]] else {
                continue
            }
            let queryID = (applied["query_id"] as? [String: Any])?["id"] as? Int ?? 0
            let table = tables.indices.contains(queryID - 1) ? tables[queryID - 1] : "unknown-\(queryID)"
            var inserted: [Data] = result[table, default: []]
            for update in updates {
                let uncompressed = (update["Uncompressed"] as? [String: Any]) ?? update
                for insert in uncompressed["inserts"] as? [Any] ?? [] {
                    if let string = insert as? String {
                        inserted.append(Data(string.utf8))
                    } else if let object = try? JSONSerialization.data(withJSONObject: insert) {
                        inserted.append(object)
                    }
                }
            }
            result[table] = inserted
        }
        return result
    }

    // MARK: - WebSocket plumbing

    private func receiveString(_ task: URLSessionWebSocketTask) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            task.receive { result in
                switch result {
                case .failure(let error):
                    continuation.resume(throwing: error)
                case .success(let message):
                    switch message {
                    case .string(let text):
                        continuation.resume(returning: text)
                    case .data(let data):
                        continuation.resume(returning: String(data: data, encoding: .utf8))
                    @unknown default:
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    private func send(_ task: URLSessionWebSocketTask, _ message: URLSessionWebSocketTask.Message) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(message) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
