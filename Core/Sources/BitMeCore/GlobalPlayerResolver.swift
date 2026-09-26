import Foundation
import SpacetimeDB
import BSATN

/// The player behind a signed-in BitCraft account, read from the game's
/// global database. This is what lets an account-driven app (Pocket
/// Crafter) skip character-name onboarding entirely: the emailed-code login
/// already proves which human is asking, and the global DB names their
/// character.
public struct AccountPlayer: Equatable, Sendable {
    /// Player entity id — the key for the relay's `/bitme/session/:id` and
    /// the `sign_in` reducer's `owner_entity_id`.
    public let entityID: String
    public let username: String?
    public let regionID: Int?
    /// `user_state.can_sign_in` at lookup time (the game's own preflight
    /// answer; `false` while the account holds a session elsewhere).
    public let canSignIn: Bool?

    public init(entityID: String, username: String?, regionID: Int?, canSignIn: Bool? = nil) {
        self.entityID = entityID
        self.username = username
        self.regionID = regionID
        self.canSignIn = canSignIn
    }
}

/// Resolves a BitCraft account (SpacetimeDB token) to its player over the
/// game's global database (`bitcraft-live-global`), the same rows the real
/// client reads after login (docs/protocol/session-2026-09-25-tap-analysis.md
/// §2.1: `user_state WHERE identity = 0x…`, then per-entity queries).
///
/// Rides our spacetimedb-swift-sdk (v2.bsatn over the SDK's HTTP/1.1
/// websocket transport) with the account token as the Bearer credential —
/// verified against the live host on 2026-09-26.
///
/// Row layouts (module schema, `GET /v1/database/<db>/schema?version=9`):
/// - `user_state`: identity (32 B) + entity_id (u64) + can_sign_in (bool)
/// - `user_region_state`: identity (32 B) + region_id (u8)
/// - `player_username_state`: entity_id (u64) + username (string)
enum GlobalPlayerResolver {
    enum Error: Swift.Error, Equatable, Sendable {
        /// `user_state` has no row for the identity — the account exists but
        /// has never created a character.
        case noPlayer
        /// The token's `hex_identity` claim is missing or malformed.
        case badIdentity
    }

    static func resolve(token: String, identityHex: String) async throws -> AccountPlayer {
        let trimmed = identityHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        let hex = bare.lowercased()
        guard !hex.isEmpty, hex.allSatisfy({ $0.isHexDigit }), hex.count % 2 == 0 else {
            throw Error.badIdentity
        }

        let connection = try await BitCraftAuthClient.production.connectionInfo()
        let client = try SpacetimeDBClient(host: connection.uri, db: connection.name)
        try await client.connect(
            token: AuthenticationToken(rawValue: token),
            enableAutoReconnect: false
        )
        defer { Task { await client.disconnect() } }

        let identity = "0x\(hex)"
        let userStateTables = try await client.oneOffQuery(
            "SELECT * FROM user_state WHERE identity = \(identity);", timeout: 15
        )
        guard let userStateRow = userStateTables.first(where: { $0.tableName == "user_state" })?
            .rows.rows.first,
            let userState = try? UserStateRow(userStateRow) else {
            throw Error.noPlayer
        }

        let regionID: Int?
        if let regionRow = try await client.oneOffQuery(
            "SELECT * FROM user_region_state WHERE identity = \(identity);", timeout: 15
        ).first(where: { $0.tableName == "user_region_state" })?.rows.rows.first {
            regionID = try? RegionRow(regionRow).regionID
        } else {
            regionID = nil
        }

        let username: String?
        if let usernameRow = try await client.oneOffQuery(
            "SELECT * FROM player_username_state WHERE entity_id = \(userState.entityID);", timeout: 15
        ).first(where: { $0.tableName == "player_username_state" })?.rows.rows.first {
            username = try? UsernameRow(usernameRow).username
        } else {
            username = nil
        }

        return AccountPlayer(
            entityID: String(userState.entityID),
            username: username,
            regionID: regionID,
            canSignIn: userState.canSignIn
        )
    }

    // MARK: - BSATN row decoders (schema-pinned field order)

    private struct UserStateRow {
        let entityID: UInt64
        let canSignIn: Bool?

        init(_ data: Data) throws {
            let reader = BSATNReader(data: data)
            _ = try reader.readBytes(32) // identity — already proven by the query
            entityID = try reader.read() as UInt64
            canSignIn = try? reader.readBool()
        }
    }

    private struct RegionRow {
        let regionID: Int

        init(_ data: Data) throws {
            let reader = BSATNReader(data: data)
            _ = try reader.readBytes(32) // identity
            regionID = Int(try reader.read() as UInt8)
        }
    }

    private struct UsernameRow {
        let username: String

        init(_ data: Data) throws {
            let reader = BSATNReader(data: data)
            _ = try reader.read() as UInt64 // entity_id
            username = try reader.readString()
        }
    }
}
