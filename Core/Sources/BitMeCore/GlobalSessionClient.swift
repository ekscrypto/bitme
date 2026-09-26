import Foundation
import SpacetimeDB
import BSATN
import os

/// Events from the game-session connection: one WebSocket to the game's
/// global database (`bitcraft-live-global`) that signs the account in and
/// then holds the connection open. That sign-in is the wire action behind
/// the game's one-live-session-per-account rule — every time the desktop
/// client connects it calls `sign_in`, taking the session slot (and
/// kicking whatever held it); holding the connection is what keeps it
/// (docs/protocol/session-2026-09-25-tap-analysis.md §4).
public enum GlobalSessionEvent: Equatable, Sendable {
    /// `sign_in` committed — this connection owns the account's session.
    case established
    /// The reducer (or the protocol) refused the sign-in. The stream
    /// finishes right after this event.
    case rejected(String)
}

/// The account's game session: connections to the game's databases that
/// sign the account in and hold open. The desktop client holds **two
/// legs** — `bitcraft-live-global` (social/presence) and its region shard
/// `bitcraft-live-<N>` (gameplay) — calling `sign_in` on each. The
/// one-session slot is enforced per database: presence
/// (`signed_in_player_state`) is keyed by the `owner_entity_id`, clients
/// validate against it, and a `sign_in` on a leg takes that leg's slot.
/// Signing in on the shard is what contests an active gameplay session;
/// global-only leaves the other device playing (verified live, 2026-09-26).
struct GlobalSessionClient: Sendable {
    /// The `sign_in` argument: `owner_entity_id` — the account's user
    /// entity from `user_state` (`AccountPlayer.entityID`). Verified
    /// against the 2026-09-25 tap capture: the desktop's 8 BSATN bytes are
    /// exactly this id, little-endian. The shard's `sign_in` takes the
    /// same shape (schema Ref 730 ≡ global Ref 508).
    static func signInArguments(entityID: UInt64) -> Data {
        withUnsafeBytes(of: entityID.littleEndian) { Data($0) }
    }

    /// Database names for the session's legs: the global DB plus the
    /// account's region shard when one is known.
    static func databases(regionID: Int?) -> [String] {
        var names = ["bitcraft-live-global"]
        if let regionID {
            names.append("bitcraft-live-\(regionID)")
        }
        return names
    }

    /// Production entry: resolves the global database address (unauth
    /// REST), connects every leg, signs each in, and holds all of them.
    /// The stream yields `.established` once every leg has committed, and
    /// ends when any leg ends (kicked by another sign_in, dropped) or the
    /// consumer cancels. No auto-reconnect — re-taking is a user action.
    static func events(token: String, entityID: UInt64, regionID: Int?) -> AsyncStream<GlobalSessionEvent> {
        AsyncStream { continuation in
            let task = Task {
                guard let connection = try? await BitCraftAuthClient.production.connectionInfo() else {
                    coreLog.error("global database lookup failed for the game session")
                    continuation.finish()
                    return
                }
                let arguments = signInArguments(entityID: entityID)

                var clients: [SpacetimeDBClient] = []
                do {
                    for database in databases(regionID: regionID) {
                        let client = try SpacetimeDBClient(host: connection.uri, db: database)
                        try await client.connect(
                            token: AuthenticationToken(rawValue: token),
                            enableAutoReconnect: false
                        )
                        _ = try await client.callReducer(
                            name: "sign_in",
                            encodedArguments: arguments
                        )
                        clients.append(client)
                        coreLog.info("game session leg committed: \(database, privacy: .public)")
                    }
                } catch let error as ReducerCallError {
                    coreLog.error("game session sign_in rejected: \(String(describing: error), privacy: .public)")
                    continuation.yield(.rejected(Self.message(for: error)))
                    Self.tearDown(clients: clients)
                    return
                } catch {
                    coreLog.error("game session connection failed: \(String(describing: error), privacy: .public)")
                    Self.tearDown(clients: clients)
                    return
                }

                coreLog.info("game session established — this device owns the account's live session")
                continuation.yield(.established)

                // Hold every leg; the first one that ends ends the session.
                await withTaskGroup(of: Void.self) { group in
                    for client in clients {
                        group.addTask {
                            let events = await client.connectionEvents
                            for await event in events {
                                switch event {
                                case .connected, .reconnecting:
                                    continue
                                case .disconnected, .error:
                                    coreLog.info("game session leg ended (\(String(describing: event), privacy: .public))")
                                    return
                                }
                            }
                        }
                    }
                    // First leg down settles the race and ends the hold;
                    // cancelling the group (or the session task itself,
                    // via SignOut) tears the remaining legs down.
                    await group.next()
                    group.cancelAll()
                }
                Self.tearDown(clients: clients)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func tearDown(clients: [SpacetimeDBClient]) {
        for client in clients {
            Task { await client.disconnect() }
        }
    }

    /// Best-effort readable text from a rejected reducer call. BitCraft
    /// reducer errors carry a BSATN string payload; host-level failures
    /// already are strings.
    private static func message(for error: ReducerCallError) -> String {
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
            return "the game refused the sign-in"
        }
    }
}
