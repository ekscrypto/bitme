import Foundation
import BSATN
import SpacetimeDB

/// What the adapters' driver defaults throw — a host or test that never
/// wired the craft driver asked to drive.
public struct DriverUnavailableError: Error, Sendable {
    public init() {}
}

/// Region-leg reducer calls for the craft driver — thin wrappers over
/// `callReducer` that encode the pinned argument layouts
/// (`RegionReducerArgs`), decode the receipt's own-action row effects
/// (`DriverReceipt` — self-caused transactions arrive via the result, not
/// the subscription broadcast), and surface the game's error strings
/// verbatim ("Not enough stamina.", "Tried to … too quickly") so callers
/// classify them.
enum RegionDriverClient {

    /// One awaited reducer call: receipt on success, the game's message
    /// on a reducer-level failure, other errors as-is (transport loss —
    /// the leg is dying and the game-session loop owns the outcome).
    public enum CallError: Error, Equatable, Sendable {
        case refused(String)
        case transport(String)
    }

    static func call(
        client: SpacetimeDBClient,
        name: String,
        arguments: Data
    ) async throws -> DriverReceipt {
        do {
            let success = try await client.callReducer(name: name, encodedArguments: arguments)
            return DriverReceipt(success)
        } catch let error as ReducerCallError {
            throw CallError.refused(Self.message(for: error))
        } catch {
            throw CallError.transport(String(describing: error))
        }
    }

    static func craftContinueStart(
        client: SpacetimeDBClient, progressiveActionEntityID: UInt64, timestampMs: UInt64
    ) async throws -> DriverReceipt {
        try await call(
            client: client,
            name: "craft_continue_start",
            arguments: RegionReducerArgs.craftContinue(
                progressiveActionEntityID: progressiveActionEntityID,
                timestampMs: timestampMs
            )
        )
    }

    static func craftContinue(
        client: SpacetimeDBClient, progressiveActionEntityID: UInt64, timestampMs: UInt64
    ) async throws -> DriverReceipt {
        try await call(
            client: client,
            name: "craft_continue",
            arguments: RegionReducerArgs.craftContinue(
                progressiveActionEntityID: progressiveActionEntityID,
                timestampMs: timestampMs
            )
        )
    }

    static func craftCancel(
        client: SpacetimeDBClient, pocketID: UInt64
    ) async throws -> DriverReceipt {
        try await call(
            client: client,
            name: "craft_cancel",
            arguments: RegionReducerArgs.craftCancel(pocketID: pocketID)
        )
    }

    static func playerActionCancel(client: SpacetimeDBClient) async throws -> DriverReceipt {
        try await call(
            client: client,
            name: "player_action_cancel",
            arguments: RegionReducerArgs.playerActionCancel()
        )
    }

    static func playerMove(
        client: SpacetimeDBClient,
        timestampMs: UInt64,
        destinationX: Int32, destinationZ: Int32, dimension: UInt32,
        originX: Int32?, originZ: Int32?,
        durationSeconds: Float, moveType: Int32
    ) async throws -> DriverReceipt {
        try await call(
            client: client,
            name: "player_move",
            arguments: RegionReducerArgs.playerMove(
                timestampMs: timestampMs,
                destinationX: destinationX, destinationZ: destinationZ, dimension: dimension,
                originX: originX, originZ: originZ,
                durationSeconds: durationSeconds, moveType: moveType
            )
        )
    }

    /// One-off own-row lookups the driver plans against (PK equality —
    /// guardrail-safe).
    static func stationLocation(client: SpacetimeDBClient, building: UInt64) async throws -> LocationRow? {
        let tables = try await client.oneOffQuery(
            "SELECT * FROM location_state WHERE entity_id = \(building);",
            timeout: 10
        )
        for table in tables where table.tableName == LocationRow.tableName {
            for row in table.rows.rows {
                if let location = try? LocationRow(reader: BSATNReader(data: row)) {
                    return location
                }
            }
        }
        return nil
    }

    static func ownPosition(client: SpacetimeDBClient, player: UInt64) async throws -> MobileEntityRow? {
        let tables = try await client.oneOffQuery(
            "SELECT * FROM mobile_entity_state WHERE entity_id = \(player);",
            timeout: 10
        )
        for table in tables where table.tableName == MobileEntityRow.tableName {
            for row in table.rows.rows {
                if let position = try? MobileEntityRow(reader: BSATNReader(data: row)) {
                    return position
                }
            }
        }
        return nil
    }

    /// Best-effort readable text from a rejected reducer call (the
    /// GlobalSessionClient pattern): BitCraft errors carry a BSATN string
    /// payload — u32 length prefix + UTF-8.
    static func message(for error: ReducerCallError) -> String {
        switch error {
        case .internalError(let message):
            return message
        case .executionError(let bytes):
            if bytes.count >= 4,
               let length = try? BSATNReader(data: bytes.prefix(4)).read() as UInt32,
               Int(length) <= bytes.count - 4,
               let text = String(data: bytes.dropFirst(4).prefix(Int(length)), encoding: .utf8) {
                return text
            }
            return "the game refused the action"
        }
    }
}

/// Classification of the game's cadence/permission refusals — the driver
/// loop's decision table (messages verbatim from the module source).
enum DriverRefusal: Equatable, Sendable {
    case outOfStamina        // "Not enough stamina."
    case tooQuickly          // "Tried to {action} too quickly" (cadence gate)
    case craftGone           // "Craft no longer exists" / already complete
    case tooFar              // "Too far" / not inside the building
    case other(String)

    static func classify(_ message: String) -> DriverRefusal {
        if message.contains("Not enough stamina") { return .outOfStamina }
        if message.contains("too quickly") { return .tooQuickly }
        if message.contains("no longer exists") || message.contains("already complete") {
            return .craftGone
        }
        if message.contains("Too far") || message.contains("inside a building") { return .tooFar }
        return .other(message)
    }
}
