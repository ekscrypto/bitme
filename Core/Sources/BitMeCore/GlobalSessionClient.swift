import Foundation
import SpacetimeDB
import BSATN
import os

/// `user_state` as the region leg exposes it (live schema: PUBLIC, pk
/// `entity_id`). Field order pinned to the 2026-09-28 tap capture of the
/// desktop client's sign-in: identity(32B) + entity_id(8B) +
/// can_sign_in(1B) — the 41-byte row. `can_sign_in` is the queue gate:
/// `sign_in` refuses with "You must join the queue first." while it is
/// false, and `player_queue_join` flips it true (instantly on a
/// non-congested server; via `process_queue` when queued).
struct UserStateRow: BSATNTableWithPrimaryKey, Equatable {
    static let tableName = "user_state"

    let identity: Identity
    let entityID: UInt64
    let canSignIn: Bool

    var primaryKey: UInt64 { entityID }

    init(reader: BSATNReader) throws {
        identity = try Identity(reader: reader)
        entityID = try reader.read() as UInt64
        canSignIn = try reader.readBool()
    }

    init(identity: Identity, entityID: UInt64, canSignIn: Bool) {
        self.identity = identity
        self.entityID = entityID
        self.canSignIn = canSignIn
    }
}

/// Events from the game-session connection: the account's legs to the
/// game's databases, each holding a `sign_in` — the wire action behind
/// the game's one-live-session-per-account rule (a `sign_in` takes the
/// slot and kicks whatever held it; holding the connection keeps it).
/// The **region shard is the load-bearing leg** (its `sign_in` is what
/// contests an active gameplay session, and the claim-buildings sync
/// rides it); the **global leg is best-effort presence** — the global
/// database only admits connections within an hour of the account's last
/// launcher login (module-private `user_authentication_state`, 3600 s;
/// region shards use 24 h), so it can legitimately refuse a token the
/// region just accepted. Its failure degrades the session, never ends
/// it. `skipGlobal` (the pre-flight's call when the relay's
/// last-login proxy is older than that window) never opens it at all.
public enum GlobalSessionEvent: Equatable, Sendable {
    /// The session is live — every load-bearing leg committed (at
    /// minimum the region leg; the global leg, when attempted, is still
    /// working towards this point and reports separately).
    case established
    /// The region-shard leg's `sign_in` committed. Carries the leg so the
    /// claim-buildings sync can subscribe on the same websocket — the game
    /// allows one live session per account per database, so region traffic
    /// must share this connection. Yielded before `.established`.
    case regionLeg(RegionLeg)
    /// The best-effort global leg was refused, failed, or dropped after
    /// the session went live. The session continues region-only — the
    /// stream does **not** end. Not yielded when `skipGlobal` skipped the
    /// leg (nothing was attempted, nothing to report).
    case globalLegFailed(String)
    /// The server (or the protocol) refused a load-bearing leg's
    /// sign-in. The stream finishes right after this event.
    case rejected(String)
    /// A load-bearing attempt died before any session existed — transport
    /// loss mid handshake, the sign-in deadline (the server answers
    /// `sign_in` in ~200 ms; silence past the deadline is a dead
    /// connection, not slowness), or an unresolvable server address. The
    /// stream finishes right after this event. Distinct from `.rejected`,
    /// where the server answered with a refusal.
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
    /// The region leg connects first and `.established` fires when it
    /// commits; the global leg is attempted after that and its failure
    /// only degrades (`.globalLegFailed`). The stream ends when a
    /// load-bearing leg ends (kicked by another sign_in, dropped), any
    /// load-bearing sign-in fails (`.failed`/`.rejected` then end), or the
    /// consumer cancels. No auto-reconnect — re-taking is a user action.
    ///
    /// `identityHex` (the token's `hex_identity` claim) arms the queue
    /// join on the region leg: `sign_in` is only admitted while the
    /// account's `user_state.can_sign_in` is true, which expires with the
    /// server's sign-in grace period after logout — the desktop client
    /// always calls `player_queue_join` (0-arg) first and waits for the
    /// own-row subscription to report admission (tap capture
    /// 2026-09-28_00-24-16, conn-02: subscribe `user_state WHERE
    /// identity=…` → join → can_sign_in 0→1 in the join's own
    /// transaction → `sign_in`). Nil/invalid falls back to a bare
    /// `sign_in` (the pre-queue behavior).
    static func events(
        token: String,
        entityID: UInt64,
        regionID: Int?,
        skipGlobal: Bool = false,
        identityHex: String? = nil
    ) -> AsyncStream<GlobalSessionEvent> {
        // Skipping the global leg only makes sense when there is a region
        // leg to carry the session — region-less sessions still need it.
        let skipGlobal = skipGlobal && regionID != nil
        // The queue join needs the account's identity for the own-row
        // subscription; normalized to the canonical lowercase hex.
        let queueIdentityHex = identityHex
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { Identity(hex: $0)?.hex }
        return AsyncStream { continuation in
            let task = Task {
                // Every exit path must end the stream: a failure that only
                // logs leaves the consumer suspended in `.connecting`
                // forever — the loop's `for await` never returns, and the
                // app hangs on a dead handshake with no event, no finish.
                defer { continuation.finish() }
                coreLog.info("game session: resolving the global database address")
                guard let connection = try? await BitCraftAuthClient.production.connectionInfo() else {
                    coreLog.error("global database lookup failed for the game session")
                    continuation.yield(.failed("Could not resolve the game server address."))
                    return
                }
                let arguments = signInArguments(entityID: entityID)
                coreLog.info("game session: connecting legs at \(connection.uri, privacy: .public) (databases: \(self.databases(regionID: regionID).joined(separator: ", "), privacy: .public))")
                if skipGlobal {
                    coreLog.info("game session: global leg skipped (login past the admission window)")
                }

                // Legs in connect order: the load-bearing region shard
                // first, then the best-effort global leg.
                var legs: [(database: String, loadBearing: Bool)] = []
                if let regionID {
                    legs.append(("bitcraft-live-\(regionID)", true))
                }
                if !skipGlobal {
                    legs.append(("bitcraft-live-global", regionID == nil))
                }

                var clients: [SpacetimeDBClient] = []
                // The open legs with their weight — the session ends when a
                // load-bearing one drops; a best-effort leg dropping only
                // degrades. (Built alongside `clients` because a refused
                // best-effort leg never joins either.)
                var openLegs: [(client: SpacetimeDBClient, loadBearing: Bool)] = []
                for leg in legs {
                    do {
                        let client = try await connectLeg(
                            host: connection.uri, database: leg.database,
                            token: token, arguments: arguments,
                            queueIdentityHex: leg.database == "bitcraft-live-global" ? nil : queueIdentityHex
                        )
                        clients.append(client)
                        openLegs.append((client, leg.loadBearing))
                        if leg.loadBearing {
                            if leg.database != "bitcraft-live-global" {
                                // The shard leg is live: hand it to the machine
                                // so the claim-buildings sync can ride it.
                                coreLog.info("game session: region leg live — starting the claim-buildings sync")
                                continuation.yield(.regionLeg(RegionLeg(client: client)))
                            }
                            coreLog.info("game session established — this device owns the account's live session")
                            continuation.yield(.established)
                        }
                    } catch let failure as LegFailure {
                        if leg.loadBearing {
                            // The session never existed — report and stop.
                            switch failure {
                            case .refused(let message), .tokenRefused(let message):
                                coreLog.error("game session sign_in rejected: \(message, privacy: .public)")
                                continuation.yield(.rejected(message))
                            case .died(let message):
                                coreLog.error("game session dead handshake: \(message, privacy: .public)")
                                continuation.yield(.failed(message))
                            }
                            Self.tearDown(clients: clients)
                            return
                        }
                        // A best-effort leg failing must not end the
                        // session — note it and carry on region-only.
                        // (The tokenRefused payload is the load-bearing
                        // action prompt; on a live region session the same
                        // token just committed, so the note stays neutral.)
                        let reason: String
                        switch failure {
                        case .refused(let message): reason = "the server refused the sign-in (\(message))"
                        case .tokenRefused: reason = "the saved sign-in token was refused"
                        case .died(let message): reason = message
                        }
                        coreLog.error("game session global leg failed (\(reason, privacy: .public)) — continuing region-only")
                        continuation.yield(.globalLegFailed(reason))
                    }
                }

                // Hold the open legs; the session ends when a load-bearing
                // one drops. (Cancelling the session task — SignOut — also
                // lands here and must not report a degradation.)
                await withTaskGroup(of: Bool.self) { group in
                    for leg in openLegs {
                        group.addTask {
                            let events = await leg.client.connectionEvents
                            for await event in events {
                                switch event {
                                case .connected, .reconnecting:
                                    continue
                                case .disconnected, .error:
                                    coreLog.info("game session leg ended (\(String(describing: event), privacy: .public))")
                                    return leg.loadBearing
                                }
                            }
                            return leg.loadBearing
                        }
                    }
                    while let loadBearingEnded = await group.next() {
                        if loadBearingEnded {
                            group.cancelAll()
                            break
                        }
                        // A best-effort leg dropped with the session still
                        // standing — note the degradation and keep holding.
                        if !Task.isCancelled {
                            continuation.yield(.globalLegFailed("the global connection dropped"))
                        }
                    }
                }
                Self.tearDown(clients: clients)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Connects one leg and drives its `sign_in` to commit. Throws a
    /// classified `LegFailure` on refusal or death; the caller decides
    /// what the failure means for the session shape.
    ///
    /// With `queueIdentityHex` (region legs, when the account's identity
    /// is known): subscribe the own `user_state` row first, call
    /// `player_queue_join` (no arguments), wait for the row to report
    /// `can_sign_in == true`, and only then `sign_in` — the desktop
    /// client's exact sequence (tap 2026-09-28_00-24-16). On a congested
    /// server the admission wait is unbounded by design (the loop stays
    /// in its connecting state, like the game's queue screen); leg death
    /// or cancellation ends it.
    private static func connectLeg(
        host: String,
        database: String,
        token: String,
        arguments: Data,
        queueIdentityHex: String? = nil
    ) async throws -> SpacetimeDBClient {
        let client = try SpacetimeDBClient(host: host, db: database)
        // This leg's last transport failure text (e.g. the 401 from a
        // rejected token) — the lifecycle task records it, the failure
        // catch classifies on it. Verified live 2026-09-27: the game
        // servers keep authenticated websockets and kill anonymous ones
        // after the upgrade, and a stale token is refused with 401 — both
        // must be told apart from network loss for the gate to say what
        // to do next.
        let transportFailure = FailureReason()
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
        defer { lifecycle.cancel() }
        // The SDK's connect() returns before the websocket handshake
        // completes; the lifecycle above is the truth: `.connected` = the
        // server's InitialConnection (handshake + token accepted + first
        // frame decoded).
        coreLog.info("game session: opening leg \(database, privacy: .public) (handshake in progress)")
        do {
            try await client.connect(
                token: AuthenticationToken(rawValue: token),
                enableAutoReconnect: false
            )
            if let queueIdentityHex {
                try await joinQueue(client: client, database: database, identityHex: queueIdentityHex)
            }
            coreLog.info("game session: calling sign_in on leg \(database, privacy: .public)")
            _ = try await Self.withTimeout(seconds: 20) {
                try await client.callReducer(
                    name: "sign_in",
                    encodedArguments: arguments
                )
            }
            coreLog.info("game session leg committed: \(database, privacy: .public)")
            return client
        } catch let error as ReducerCallError {
            throw LegFailure.refused(Self.message(for: error))
        } catch Timeout.timedOut(let detail) {
            throw LegFailure.died("The game server never answered the sign-in (\(detail)).")
        } catch {
            // A token the game no longer accepts is a refusal, not a
            // network fault — the gate must send the user to sign in
            // again, not to check their connection. The transport's
            // failure text lands on the lifecycle task's stream a beat
            // after the call fails, so give it a moment before deciding
            // this was a plain connection loss.
            var reason = transportFailure.reason
            if reason == nil {
                for _ in 0..<10 where transportFailure.reason == nil {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                reason = transportFailure.reason
            }
            if let reason, reason.contains("401") {
                throw LegFailure.tokenRefused(
                    "The game rejected the saved sign-in token — sign in with your BitCraft account again."
                )
            }
            let detail = reason.map { " (\($0))" } ?? ""
            throw LegFailure.died("The game connection failed\(detail).")
        }
    }

    /// A leg attempt's classified failure.
    private enum LegFailure: Error {
        /// The server answered the sign-in with a refusal (reducer error).
        case refused(String)
        /// The transport refused the saved token (websocket 401). Carries
        /// the load-bearing phrasing — a best-effort caller rephrases.
        case tokenRefused(String)
        /// The attempt died before any session existed (dead handshake,
        /// transport loss). Carries the load-bearing phrasing.
        case died(String)
    }

    /// The region leg's queue join (tap 2026-09-28_00-24-16, conn-02):
    /// subscribe the own `user_state` row, call `player_queue_join`, wait
    /// for the row's `can_sign_in` to flip true, and return — `sign_in`
    /// after this is admitted. The events stream is attached before
    /// subscribing (SDK rule: the initial snapshot is otherwise missed);
    /// AsyncStream buffering keeps rows that arrive while the reducer
    /// call is in flight.
    private static func joinQueue(
        client: SpacetimeDBClient,
        database: String,
        identityHex: String
    ) async throws {
        await client.registerTableRowDecoder(UserStateRow.self)
        let userStateEvents = await client.tableEvents(named: UserStateRow.tableName)

        // Latest admission verdicts as a stream: the consumer task decodes
        // row inserts and yields canSignIn; the loop below waits on it.
        // Finishing the stream when the events end (leg death) unblocks the
        // waiter instead of hanging it.
        let admission = AsyncStream<Bool> { continuation in
            let consumer = Task {
                for await event in userStateEvents {
                    guard event.tableName == UserStateRow.tableName else { continue }
                    for case let row as UserStateRow in event.inserts {
                        continuation.yield(row.canSignIn)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                consumer.cancel()
            }
        }

        coreLog.info("game session: subscribing user_state on leg \(database, privacy: .public) (queue gate)")
        let subscription = try await client.subscribe([
            "SELECT * FROM user_state WHERE identity=0x\(identityHex);"
        ])
        try await subscription.applied()

        coreLog.info("game session: calling player_queue_join on leg \(database, privacy: .public)")
        do {
            _ = try await Self.withTimeout(seconds: 20) {
                try await client.callReducer(name: "player_queue_join", encodedArguments: Data())
            }
        } catch let error as ReducerCallError {
            throw LegFailure.refused(Self.message(for: error))
        } catch Timeout.timedOut(let detail) {
            throw LegFailure.died("The game server never answered the queue join (\(detail)).")
        }

        // Wait for admission. Already true (grace period active) → instant;
        // genuinely queued (congested server) → unbounded by design; leg
        // death or cancellation ends the stream without a verdict.
        for await canSignIn in admission {
            if canSignIn {
                coreLog.info("game session: queue admission granted on leg \(database, privacy: .public)")
                return
            }
            coreLog.info("game session: queued on leg \(database, privacy: .public) — waiting for admission")
        }
        throw LegFailure.died("The connection to the game was lost while waiting for sign-in approval.")
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
