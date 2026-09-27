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
    /// The region-shard leg's `sign_in` committed. Carries the leg so the
    /// claim-buildings sync can subscribe on the same websocket — the game
    /// allows one live session per account per database, so region traffic
    /// must share this connection. Yielded before `.established`.
    case regionLeg(RegionLeg)
    /// The reducer (or the protocol) refused the sign-in. The stream
    /// finishes right after this event.
    case rejected(String)
    /// The attempt died before any session existed — transport loss mid
    /// handshake, the sign-in deadline (the server answers `sign_in` in
    /// ~200 ms; silence past the deadline is a dead connection, not
    /// slowness), or an unresolvable server address. The stream finishes
    /// right after this event. Distinct from `.rejected`, where the
    /// server answered with a refusal.
    case failed(String)
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
    /// ends when any leg ends (kicked by another sign_in, dropped), any
    /// sign-in attempt fails (`.failed`/`.rejected` then end), or the
    /// consumer cancels. No auto-reconnect — re-taking is a user action.
    static func events(token: String, entityID: UInt64, regionID: Int?) -> AsyncStream<GlobalSessionEvent> {
        AsyncStream { continuation in
            let task = Task {
                // Every exit path must end the stream: a failure that only
                // logs leaves the consumer suspended in `.connecting`
                // forever — the loop's `for await` never returns, and the
                // app hangs on a dead handshake with no event, no finish.
                defer { continuation.finish() }
                // The leg's last transport failure text (e.g. the 401 from
                // a rejected token) — the lifecycle task records it, the
                // failure catch classifies on it. Verified live 2026-09-27:
                // the game servers keep authenticated websockets and kill
                // anonymous ones after the upgrade, and a stale token is
                // refused with 401 — both must be told apart from network
                // loss for the gate to say what to do next.
                let transportFailure = FailureReason()
                coreLog.info("game session: resolving the global database address")
                guard let connection = try? await BitCraftAuthClient.production.connectionInfo() else {
                    coreLog.error("global database lookup failed for the game session")
                    continuation.yield(.failed("Could not resolve the game server address."))
                    return
                }
                let arguments = signInArguments(entityID: entityID)
                coreLog.info("game session: connecting legs at \(connection.uri, privacy: .public) (databases: \(self.databases(regionID: regionID).joined(separator: ", "), privacy: .public))")

                var clients: [SpacetimeDBClient] = []
                do {
                    for database in databases(regionID: regionID) {
                        let client = try SpacetimeDBClient(host: connection.uri, db: database)
                        // The SDK's connect() returns before the websocket
                        // handshake completes; the lifecycle below is the
                        // truth: `.connected` = the server's InitialConnection
                        // (handshake + token accepted + first frame decoded).
                        let lifecycle = Task {
                            for await event in await client.connectionEvents {
                                switch event {
                                case .connected(let identity, _, _):
                                    coreLog.info("game session: leg \(database, privacy: .public) InitialConnection (identity \(String(describing: identity), privacy: .public))")
                                case .reconnecting(let attempt):
                                    coreLog.info("game session: leg \(database, privacy: .public) reconnecting (attempt \(attempt, privacy: .public))")
                                case .disconnected(let reason):
                                    coreLog.error("game session: leg \(database, privacy: .public) connection lost (\(reason ?? "no reason", privacy: .public))")
                                    transportFailure.record(reason)
                                    return
                                case .error(let message):
                                    coreLog.error("game session: leg \(database, privacy: .public) connection error (\(message, privacy: .public))")
                                    transportFailure.record(message)
                                    return
                                }
                            }
                        }
                        coreLog.info("game session: opening leg \(database, privacy: .public) (handshake in progress)")
                        try await client.connect(
                            token: AuthenticationToken(rawValue: token),
                            enableAutoReconnect: false
                        )
                        coreLog.info("game session: calling sign_in on leg \(database, privacy: .public)")
                        _ = try await Self.withTimeout(seconds: 20) {
                            try await client.callReducer(
                                name: "sign_in",
                                encodedArguments: arguments
                            )
                        }
                        lifecycle.cancel()
                        clients.append(client)
                        coreLog.info("game session leg committed: \(database, privacy: .public)")
                        if database != "bitcraft-live-global" {
                            // The shard leg is live: hand it to the machine
                            // so the claim-buildings sync can ride it.
                            coreLog.info("game session: region leg live — starting the claim-buildings sync")
                            continuation.yield(.regionLeg(RegionLeg(client: client)))
                        }
                    }
                } catch let error as ReducerCallError {
                    coreLog.error("game session sign_in rejected: \(String(describing: error), privacy: .public)")
                    continuation.yield(.rejected(Self.message(for: error)))
                    Self.tearDown(clients: clients)
                    return
                } catch Timeout.timedOut(let detail) {
                    coreLog.error("game session dead handshake: \(detail, privacy: .public)")
                    continuation.yield(.failed("The game server never answered the sign-in (\(detail))."))
                    Self.tearDown(clients: clients)
                    return
                } catch {
                    coreLog.error("game session connection failed: \(String(describing: error), privacy: .public)")
                    // A token the game no longer accepts is a refusal, not a
                    // network fault — the gate must send the user to sign in
                    // again, not to check their connection. The transport's
                    // failure text lands on the lifecycle task's stream a
                    // beat after the call fails, so give it a moment before
                    // deciding this was a plain connection loss.
                    var reason = transportFailure.reason
                    if reason == nil {
                        for _ in 0..<10 where transportFailure.reason == nil {
                            try? await Task.sleep(for: .milliseconds(30))
                        }
                        reason = transportFailure.reason
                    }
                    if let reason, reason.contains("401") {
                        continuation.yield(.rejected(
                            "The game rejected the saved sign-in token — sign in with your BitCraft account again."
                        ))
                    } else {
                        let detail = reason.map { " (\($0))" } ?? ""
                        continuation.yield(.failed("The game connection failed\(detail)."))
                    }
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

    /// Lock-protected hand-off of a leg's last transport failure text from
    /// its lifecycle task to the sign-in failure catch.
    private final class FailureReason: @unchecked Sendable {
        private let lock = NSLock()
        private var _reason: String?

        func record(_ reason: String?) {
            guard let reason else { return }
            lock.withLock {
                if _reason == nil { _reason = reason }
            }
        }

        var reason: String? {
            lock.withLock { _reason }
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

    // MARK: - Sign-in deadline

    private enum Timeout: Error {
        case timedOut(String)
    }

    /// A `callReducer` whose result can never arrive (handshake that never
    /// completed, server silence) suspends forever — the SDK resolves
    /// pending calls when the transport *fails*, not when it stalls. Race
    /// the sign-in against a deadline so a zombie connection surfaces as
    /// a logged failure instead of a silent hang.
    private static func withTimeout<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            guard let first else {
                throw Timeout.timedOut("no sign_in answer within \(Int(seconds)) s")
            }
            return first
        }
    }
}
