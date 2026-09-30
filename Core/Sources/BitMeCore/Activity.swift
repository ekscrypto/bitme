import Foundation
import os

/// Namespace for concrete activities (fenex-light pattern).
enum Activity {}

let coreLog = Logger(subsystem: "life.encoded.bitme.ios", category: "core")
let authLog = Logger(subsystem: "life.encoded.bitme.ios", category: "auth")

// MARK: - Bootstrap

extension Activity {
    struct Bootstrap: Sendable {}
}

extension Activity.Bootstrap: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        async let identity = adapters.restoreIdentity()
        async let account = adapters.restoreBitCraftAccount()
        await ingestor.ingest(Intent.BootstrapCompleted(
            identity: await identity, bitCraftAccount: await account
        ))
    }
}

// MARK: - BitCraft sign-in

extension Activity {
    /// POST /authentication/request-access-code — emails the code.
    struct RequestAccessCode: Sendable {
        let email: String
    }
}

extension Activity.RequestAccessCode: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        authLog.info("requesting BitCraft access code for \(email, privacy: .private)")
        do {
            try await adapters.bitCraft.requestAccessCode(email)
            authLog.info("BitCraft access code emailed to \(email, privacy: .private)")
            await ingestor.ingest(Intent.AccessCodeRequested(email: email))
        } catch is CancellationError {
            // Shutdown — no feedback intent.
        } catch BitCraftAuthError.badRequest(let message) {
            authLog.error("access code request rejected: \(message, privacy: .public)")
            await ingestor.ingest(Intent.AccessCodeRequestFailed(
                message: message.isEmpty ? "That email was rejected — check it and try again." : message
            ))
        } catch {
            authLog.error("access code request failed: \(String(describing: error), privacy: .public)")
            await ingestor.ingest(Intent.AccessCodeRequestFailed(
                message: "BitCraft unreachable — check your connection and try again."
            ))
        }
    }
}

extension Activity {
    /// POST /authentication/authenticate — code for the SpacetimeDB token.
    struct Authenticate: Sendable {
        let email: String
        let code: String
    }
}

extension Activity.Authenticate: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        authLog.info("authenticating BitCraft access code for \(email, privacy: .private)")
        do {
            let token = try await adapters.bitCraft.authenticate(email, code)
            let account = BitCraftAccount(email: email, token: token)
            if let identity = account.identityHex {
                authLog.info("BitCraft authenticated \(email, privacy: .private) identity 0x\(identity.prefix(8), privacy: .public)… subject \(account.subject ?? "?", privacy: .public)")
            } else {
                authLog.info("BitCraft authenticated \(email, privacy: .private) (token payload undecoded)")
            }
            await ingestor.ingest(Intent.BitCraftAuthenticated(account: account))
        } catch is CancellationError {
            // Shutdown — no feedback intent.
        } catch BitCraftAuthError.badRequest(let message) {
            authLog.error("authentication rejected: \(message, privacy: .public)")
            await ingestor.ingest(Intent.BitCraftAuthenticationFailed(
                email: email,
                message: message.isEmpty ? "That code was rejected — codes expire quickly; request a new one." : message
            ))
        } catch {
            authLog.error("authentication failed: \(String(describing: error), privacy: .public)")
            await ingestor.ingest(Intent.BitCraftAuthenticationFailed(
                email: email,
                message: "BitCraft unreachable — check your connection and try again."
            ))
        }
    }
}

extension Activity {
    /// Locates the signed-in account's player over the game's global
    /// database (identity → entity/username/region — the same rows the real
    /// client subscribes after login; see GlobalPlayerResolver).
    struct LinkAccountPlayer: Sendable {
        let account: BitCraftAccount
    }
}

extension Activity.LinkAccountPlayer: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        guard let identityHex = account.identityHex else {
            authLog.error("token carried no hex_identity — cannot locate the player")
            await ingestor.ingest(Intent.AccountPlayerLinkFailed(
                accountEmail: account.email,
                message: "The sign-in token did not identify a player — sign in again."
            ))
            return
        }
        authLog.info("locating the player for BitCraft account \(account.email, privacy: .private)")
        do {
            let player = try await adapters.bitCraft.resolveAccountPlayer(account.token, identityHex)
            authLog.info("BitCraft account \(account.email, privacy: .private) → player \(player.username ?? player.entityID, privacy: .public) (entity \(player.entityID, privacy: .public), region \(player.regionID.map(String.init) ?? "?", privacy: .public))")
            await ingestor.ingest(Intent.AccountPlayerLinked(accountEmail: account.email, player: player))
        } catch is CancellationError {
            // Shutdown — no feedback intent.
        } catch GlobalPlayerResolver.Error.noPlayer {
            await ingestor.ingest(Intent.AccountPlayerLinkFailed(
                accountEmail: account.email,
                message: "This BitCraft account has no character yet — create one in game, then sign in again."
            ))
        } catch GlobalPlayerResolver.Error.badIdentity {
            await ingestor.ingest(Intent.AccountPlayerLinkFailed(
                accountEmail: account.email,
                message: "The sign-in token did not identify a player — sign in again."
            ))
        } catch {
            authLog.error("account player lookup failed: \(String(describing: error), privacy: .public)")
            await ingestor.ingest(Intent.AccountPlayerLinkFailed(
                accountEmail: account.email,
                message: "BitCraft unreachable — check your connection and try again."
            ))
        }
    }
}

// MARK: - Gamedata

extension Activity {
    struct LoadGamedata: Sendable {}
}

extension Activity.LoadGamedata: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        let gamedata = await adapters.loadFoodBuffGamedata()
        await ingestor.ingest(Intent.GamedataLoaded(gamedata: gamedata))
    }
}

// MARK: - Resolve

extension Activity {
    struct ResolvePlayer: Sendable {
        let name: String
    }
}

extension Activity.ResolvePlayer: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        do {
            let resolved = try await adapters.relay.resolve(name)
            await ingestor.ingest(Intent.ResolveSucceeded(response: resolved))
        } catch RelayError.notFound {
            await ingestor.ingest(Intent.ResolveFailed(
                message: "No character found with the exact name “\(name)”."
            ))
        } catch let RelayError.badRequest(message) {
            await ingestor.ingest(Intent.ResolveFailed(message: message))
        } catch is CancellationError {
            // Shutdown — no feedback intent.
        } catch {
            await ingestor.ingest(Intent.ResolveFailed(
                message: "Relay unreachable — check your connection and try again."
            ))
        }
    }
}

// MARK: - Session loop

extension Activity {
    /// The 1 Hz session poll loop with backoff. Long-running: runs until its
    /// task is cancelled (`Intent.SignOut` / shutdown). The inter-poll delay
    /// is stamped into `carrier` by `Intent.SessionPolled`/`SessionPollFailed`
    /// (ADR-014 carrier pattern — the loop never reads machine state).
    struct SessionLoop: Sendable {
        let entityID: String
        let carrier: SessionLoopCarrier
        /// Machine-stamped with the spawned task; stored in session state by
        /// the starting intent so `Intent.SignOut` can cancel it.
        let cancellable: CancellableTask
    }
}

extension Activity.SessionLoop: AsyncActivity, StampableActivity {
    var stampTarget: CancellableTask { cancellable }

    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        coreLog.info("session loop started for \(self.entityID, privacy: .public)")
        var delayMs = 1_000.0
        while !Task.isCancelled {
            do {
                try await adapters.sleep(delayMs / 1_000)
            } catch {
                return // cancelled
            }
            guard !Task.isCancelled else { return }
            do {
                let snapshot = try await adapters.relay.session(entityID)
                await ingestor.ingest(Intent.SessionPolled(
                    snapshot: snapshot,
                    carrier: carrier,
                    polledAtMs: Date().timeIntervalSince1970 * 1_000
                ))
                delayMs = carrier.nextDelayMs
            } catch is CancellationError {
                return
            } catch RelayError.notFound {
                await ingestor.ingest(Intent.SessionPollFailed(
                    kind: .notFound,
                    message: "player not present in any mirrored region",
                    carrier: carrier
                ))
                delayMs = carrier.nextDelayMs
            } catch {
                await ingestor.ingest(Intent.SessionPollFailed(
                    kind: .transient,
                    message: String(describing: error),
                    carrier: carrier
                ))
                delayMs = carrier.nextDelayMs
            }
        }
    }
}

// MARK: - Resource map

extension Activity {
    /// One session-anchored BMR1 window fetch (drift/staleness-triggered by
    /// `Intent.SessionPolled`, or a resync recovery from the stream).
    struct FetchResourceWindow: Sendable {
        let entityID: String
    }
}

extension Activity.FetchResourceWindow: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        let atMs = Date().timeIntervalSince1970 * 1_000
        do {
            let window = try await adapters.relay.sessionResources(entityID)
            await ingestor.ingest(Intent.ResourceWindowFetched(window: window, fetchedAtMs: atMs))
        } catch is CancellationError {
            // Shutdown — no feedback intent.
        } catch RelayError.seeding {
            await ingestor.ingest(Intent.ResourceWindowUnavailable(kind: .seeding, atMs: atMs))
        } catch {
            await ingestor.ingest(Intent.ResourceWindowUnavailable(kind: .failed, atMs: atMs))
        }
    }
}

extension Activity {
    /// Loads a region's resource dictionary when a window/delta's
    /// `dict_version` is not covered by the cached one.
    struct LoadResourceDictionary: Sendable {
        let region: Int
        let neededVersion: Int
    }
}

extension Activity.LoadResourceDictionary: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        do {
            let dictionary = try await adapters.relay.resourceDictionary(region)
            await ingestor.ingest(Intent.ResourceDictionaryLoaded(region: region, dictionary: dictionary))
        } catch is CancellationError {
            // Shutdown — no feedback intent.
        } catch {
            coreLog.info("resource dictionary load failed (region \(self.region)): \(String(describing: error), privacy: .public)")
            // Not fatal — the next window fetch or subscribed message re-attempts.
        }
    }
}

extension Activity {
    /// Loads the BME1 terrain plane behind a window (drift/TTL-triggered by
    /// `Intent.ResourceWindowFetched`). Terrain rarely changes — 10 min TTL.
    struct FetchTerrain: Sendable {
        let centerX: Int
        let centerZ: Int
    }
}

extension Activity.FetchTerrain: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        let atMs = Date().timeIntervalSince1970 * 1_000
        do {
            let plane = try await adapters.relay.worldElevation(centerX, centerZ)
            await ingestor.ingest(Intent.TerrainPlaneFetched(plane: plane, atMs: atMs))
        } catch is CancellationError {
            // Shutdown — no feedback intent.
        } catch {
            coreLog.info("terrain plane fetch failed (\(self.centerX), \(self.centerZ)): \(String(describing: error), privacy: .public)")
            // Not fatal — the next window fetch re-attempts.
        }
    }
}

extension Activity {
    /// The resource change-stream loop. Long-running: connects when the
    /// machine wants the stream (live player, overworld — stamped into the
    /// carrier by `Intent.SessionPolled`), forwards events as intents, and
    /// reconnects with exponential backoff when a connection ends (server
    /// close, error, zombie watchdog in `ResourceStreamClient`).
    struct ResourceStreamLoop: Sendable {
        let entityID: String
        let carrier: ResourceStreamCarrier
        /// Machine-stamped with the spawned task; stored in session state by
        /// the starting intent so `Intent.SignOut` can cancel it.
        let cancellable: CancellableTask
    }
}

extension Activity.ResourceStreamLoop: AsyncActivity, StampableActivity {
    var stampTarget: CancellableTask { cancellable }

    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        let config = GameConfig.shared
        coreLog.info("resource stream loop started for \(self.entityID, privacy: .public)")
        var attempt = 0
        while !Task.isCancelled {
            // Hold off until the machine wants the stream (live + overworld).
            while !Task.isCancelled && !carrier.wanted {
                await ingestor.ingest(Intent.ResourceStreamStatusChanged(status: .off))
                do {
                    try await adapters.sleep(config.mapStreamPausePollSecs)
                } catch {
                    return // cancelled
                }
            }
            guard !Task.isCancelled else { return }

            await ingestor.ingest(Intent.ResourceStreamStatusChanged(status: .connecting))
            var subscribed = false
            for await event in adapters.relay.openResourceStream(entityID) {
                if Task.isCancelled || !carrier.wanted { break }
                if case .subscribed = event {
                    subscribed = true
                    attempt = 0
                }
                await ingestor.ingest(Intent.ResourceStreamEventReceived(
                    event: event,
                    atMs: Date().timeIntervalSince1970 * 1_000
                ))
            }
            if Task.isCancelled { return }

            // Socket ended (close / error / watchdog / "gone") — back off,
            // then let the loop head decide whether to reconnect.
            await ingestor.ingest(Intent.ResourceStreamStatusChanged(
                status: subscribed ? .reconnecting : .connecting
            ))
            attempt = min(5, attempt + 1)
            let delay = min(
                config.mapStreamReconnectMaxSecs,
                config.mapStreamReconnectBaseSecs * pow(2, Double(attempt - 1))
            )
            do {
                try await adapters.sleep(delay)
            } catch {
                return // cancelled
            }
        }
    }
}

// MARK: - Game session

extension Activity {
    /// The account's game session on the game's databases: holds the
    /// `sign_in`s that own the game's one-live-session-per-account slot
    /// (`GlobalSessionClient` — the region shard, load-bearing, plus the
    /// best-effort global leg the pre-flight may skip past the game's 1 h
    /// admission window). One connection set per user action
    /// (`Intent.SignInGameSession`). There is deliberately no reconnect —
    /// when a leg is kicked (the desktop client signing in), dropped, or
    /// refused, the machine returns to the pre-sign-in gate and only the
    /// user takes the session back.
    struct GameSessionLoop: Sendable {
        let token: String
        let entityID: String
        /// The account's region — selects the shard leg.
        let regionID: Int?
        /// The token's `hex_identity` claim — arms the region leg's queue
        /// join (`player_queue_join` before `sign_in`).
        let identityHex: String?
        /// Machine-stamped with the spawned task; stored in session state by
        /// the starting intent so `Intent.SignOut` can cancel it.
        let cancellable: CancellableTask
    }
}

extension Activity.GameSessionLoop: AsyncActivity, StampableActivity {
    var stampTarget: CancellableTask { cancellable }

    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        coreLog.info("game session connecting for \(self.entityID, privacy: .public)")
        await ingestor.ingest(Intent.GameSessionStatusChanged(status: .connecting, message: nil))
        // Pre-flight over the public relay (anonymous; only seconds behind
        // live). The game's global database refuses connections once more
        // than an hour has passed since the account's last launcher login
        // (module-private `user_authentication_state`), and the relay's
        // `last_login_timestamp` — the public `player_state` field the
        // session's first `sign_in` stamps — is the readable proxy: older
        // than the window ⇒ don't bother with the global leg, region only.
        // No answer (unmirrored region, relay down) ⇒ attempt both legs —
        // the handshake itself is the ground truth.
        var skipGlobal = false
        if let status = try? await adapters.relay.playerStatus(entityID),
           let lastLogin = status.lastLoginTimestamp {
            let elapsed = Date().timeIntervalSince1970 - Double(lastLogin)
            skipGlobal = elapsed > GameConfig.shared.globalAuthWindowSecs
            if skipGlobal {
                coreLog.info("game session: last game login \(Int(elapsed), privacy: .public) s ago — past the global admission window, skipping the global leg")
            }
        }
        for await event in adapters.bitCraft.openGlobalSession(token, entityID, regionID, skipGlobal, identityHex) {
                if Task.isCancelled { return }
                switch event {
                case .regionLeg(let leg):
                    // The shard leg is live — hand it to the machine, which
                    // starts the claim-buildings sync on this connection.
                    await ingestor.ingest(Intent.GameSessionRegionLegReady(leg: leg))
                case .established:
                    coreLog.info("game session holding for \(self.entityID, privacy: .public)")
                    await ingestor.ingest(Intent.GameSessionStatusChanged(status: .live, message: nil))
                case .globalLegFailed(let message):
                    // The best-effort global leg is offline while the region
                    // session stands — surface it as a note on the live
                    // session, never as a failure.
                    coreLog.error("game session global leg offline: \(message, privacy: .public)")
                    await ingestor.ingest(Intent.GameSessionStatusChanged(
                        status: .live,
                        message: "Connected to your region; the game's global server is offline for this session (\(message))."
                    ))
                case .rejected(let message):
                    coreLog.error("game session sign_in rejected: \(message, privacy: .public)")
                    await ingestor.ingest(Intent.GameSessionStatusChanged(status: .rejected, message: message))
                case .failed(let message):
                    // No session ever existed — transport loss or a dead
                    // handshake. Return to the gate carrying the reason
                    // (and skip the loop-end ingest below: this path ends
                    // the stream itself, and a second GameSessionEnded
                    // would overwrite the notice with the generic text).
                    coreLog.error("game session attempt failed: \(message, privacy: .public)")
                    await ingestor.ingest(Intent.GameSessionEnded(notice: message))
                    return
                }
            }
        guard !Task.isCancelled else { return }
        // The connection that held the session ended. No automatic retake,
        // by design — report it and stop; the gate decides what happens
        // next.
        await ingestor.ingest(Intent.GameSessionEnded())
    }
}

// MARK: - Claim buildings

extension Activity {
    /// The claim-buildings sync on the game session's region leg
    /// (`RegionBuildingsClient`): catalogs, then the pinned claim's
    /// buildings and crafts, streamed as pooled row-event batches (one
    /// ingest per ~0.5 s of rows). Runs for the life of the leg — the
    /// sync pins the first claim the carrier names (the one the
    /// pre-sign-in gate validated) and follows it live; buildings placed
    /// or deconstructed mid-session arrive as row diffs.
    struct ClaimBuildingsLoop: Sendable {
        let leg: RegionLeg
        let playerEntityID: UInt64
        /// Stamped by `Intent.SessionPolled` with the relay's claim answer.
        let claimCarrier: ClaimCarrier
        /// Machine-stamped with the spawned task; stored in session state by
        /// the starting intent so session teardown can cancel it.
        let cancellable: CancellableTask
    }
}

extension Activity.ClaimBuildingsLoop: AsyncActivity, StampableActivity {
    var stampTarget: CancellableTask { cancellable }

    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        // Wait for the relay's claim answer. The gate already refused
        // sign-in without one, so this normally resolves immediately; the
        // wait only closes the ordering gap after a launch-restore session
        // where the first poll may still be in flight. If the relay still
        // has not answered after a few poll cycles, the fallback (protocol
        // doc §2) asks the region leg directly — membership, not the
        // relay's claim name, is the safe key.
        coreLog.info("claim buildings loop started — waiting for the relay's claim answer")
        guard let claim = await Self.resolveClaim(
            carrier: claimCarrier, leg: leg, playerEntityID: playerEntityID, adapters: adapters
        ) else { return } // cancelled
        coreLog.info("claim buildings loop syncing claim \(claim, privacy: .public) for player \(self.playerEntityID, privacy: .public)")
        for await events in adapters.bitCraft.syncClaimBuildings(leg, claim, playerEntityID) {
            if Task.isCancelled { return }
            coreLog.debug("claim buildings loop received \(events.count, privacy: .public) pooled event(s)")
            await ingestor.ingest(Intent.ClaimBuildingsChanged(events: events))
        }
        // The stream always carries its own terminal event (`.failed`
        // precedes the end on a sync failure; the leg closing ends both
        // this loop and the game-session loop) — nothing to report here.
    }

    /// Resolves the claim to sync: the relay's carrier answer when it has
    /// one, else — after ~5 s of unanswered carrier checks — a one-off
    /// membership lookup on the region leg, re-attempted on the same
    /// cadence until either side answers. Patience is unbounded (the relay
    /// may answer late) and the work is bounded (one indexed one-off per
    /// cadence); cancellation is the session teardown's job.
    private static func resolveClaim(
        carrier: ClaimCarrier,
        leg: RegionLeg,
        playerEntityID: UInt64,
        adapters: Adapters
    ) async -> UInt64? {
        // Carrier checks ride the 0.5 s sleep cadence; the fallback fires
        // on every 10th unanswered check (~5 s in production, near-instant
        // under the tests' scripted sleep).
        var checks = 0
        while true {
            if Task.isCancelled { return nil }
            if let stamped = carrier.claimEntityID { return stamped }
            checks += 1
            if checks.isMultiple(of: 10) {
                if let membership = await adapters.bitCraft.resolveOwnClaimMembership(leg, playerEntityID) {
                    coreLog.info("claim buildings loop: relay had no claim answer — membership resolves to claim \(membership, privacy: .public)")
                    return membership
                }
            }
            do {
                try await adapters.sleep(0.5)
            } catch {
                return nil // cancelled
            }
        }
    }
}

// MARK: - Player vitals

extension Activity {
    /// The player-vitals sync on the game session's region leg
    /// (`RegionVitalsClient`): the own-row subscription set for the
    /// stamina/health/satiation/teleport pools, the materialized stats,
    /// the action record, and position. Runs for the life of the leg,
    /// forwarding each event as one intent — vitals are low-rate (the
    /// pools tick at most ~1 Hz), so no pooling.
    struct PlayerVitalsLoop: Sendable {
        let leg: RegionLeg
        let playerEntityID: UInt64
        /// Machine-stamped with the spawned task; stored in session state
        /// by the starting intent so session teardown can cancel it.
        let cancellable: CancellableTask
    }
}

extension Activity.PlayerVitalsLoop: AsyncActivity, StampableActivity {
    var stampTarget: CancellableTask { cancellable }

    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        for await event in adapters.bitCraft.syncPlayerVitals(leg, playerEntityID) {
            if Task.isCancelled { return }
            await ingestor.ingest(Intent.PlayerVitalsChanged(events: [event]))
        }
        // The stream ends with the leg (its terminal `.failed` event, if
        // any, already flowed through as an intent) — nothing to report.
    }
}

// MARK: - Prospection watch

extension Activity {
    /// The prospection watch on the region mirror (`RegionProspectClient`):
    /// the tracked player's own `prospecting_state` row, read anonymously —
    /// name-driven hosts hold no game session, so the mirror is their only
    /// region window. Low-rate (rows move only on re-prospection), so each
    /// event is one intent; the loop runs until cancelled (session
    /// teardown, sign-out, or a region change restart).
    struct ProspectionWatch: Sendable {
        let playerEntityID: UInt64
        let region: Int
        /// Machine-stamped with the spawned task; stored in session state
        /// by the starting intent so teardown and restarts can cancel it.
        let cancellable: CancellableTask
    }
}

extension Activity.ProspectionWatch: AsyncActivity, StampableActivity {
    var stampTarget: CancellableTask { cancellable }

    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        for await event in adapters.bitCraft.syncProspection(playerEntityID, region) {
            if Task.isCancelled { return }
            await ingestor.ingest(Intent.ProspectionChanged(events: [event]))
        }
        // The stream ends on watch failure (its `.failed` event already
        // flowed through) — a later poll re-arms a fresh watch.
    }
}

// MARK: - Craft driver

extension Activity {
    /// The craft driver: walks the player to a stand-point by the tapped
    /// craft's station (v1: outdoor stations — the mutation already
    /// refused interior ones), then runs the client-paced
    /// `craft_continue_start` → `craft_continue` loop until the effort
    /// goal, a refusal, or cancellation. Pacing honors the server's own
    /// delay formula with the ≥95 % cadence margin (the plan carries it);
    /// every awaited call's receipt is the own-action feedback channel
    /// (effort, stamina, position). Pause cancels the loop (the server
    /// suspends the craft when its lock lapses); resume re-arms with a
    /// fresh `craft_continue_start`.
    struct CraftDriverLoop: Sendable {
        let leg: RegionLeg
        let playerEntityID: UInt64
        let plan: EphemeralState.Session.CraftPlan
        /// Machine-stamped with the spawned task; stored in session state
        /// by the starting intent so pause/stop/teardown can cancel it.
        let cancellable: CancellableTask
    }

    /// Best-effort stop: `craft_cancel` + `player_action_cancel` after the
    /// user tapped Stop. Failures are logged only — the craft may already
    /// be gone, and the banner has already moved on.
    struct StopCraft: Sendable {
        let leg: RegionLeg
        let pocketID: UInt64
    }
}

extension Activity.CraftDriverLoop: AsyncActivity, StampableActivity {
    var stampTarget: CancellableTask { cancellable }

    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        let config = GameConfig.shared
        let entity = plan.progressiveActionEntityID

        // Monotonic client clock for the request timestamps (epoch ms —
        // the wire format; the server sanity-clamps +1 s/−8 s).
        var lastTimestampMs: UInt64 = 0
        func nextTimestampMs() -> UInt64 {
            let now = UInt64(Date().timeIntervalSince1970 * 1_000)
            lastTimestampMs = max(lastTimestampMs + 1, now)
            return lastTimestampMs
        }

        // 1. Walk stage — skipped when already in craft range.
        switch await Self.walkToStation(
            leg: leg, plan: plan, playerEntityID: playerEntityID,
            adapters: adapters, nextTimestampMs: nextTimestampMs
        ) {
        case .arrived(let x, let z):
            await ingestor.ingest(Intent.WalkOutcome(
                craftEntityID: entity, outcome: .arrived(positionX: x, positionZ: z)
            ))
        case .failed(let message):
            await ingestor.ingest(Intent.WalkOutcome(
                craftEntityID: entity, outcome: .failed(message)
            ))
            return
        case .cancelled:
            return
        }

        // 2. Craft loop.
        await ingestor.ingest(Intent.DriverEvent(
            craftEntityID: entity,
            outcome: .crafting(effortDone: plan.effortDone, stamina: nil)
        ))
        var delayMs = plan.delayMs
        var effortDone = plan.effortDone
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                // Arm the iteration, pace the server's delay, complete it.
                _ = try await adapters.bitCraft.craftContinueStart(leg, entity, nextTimestampMs())
                try await adapters.sleep(delayMs / 1_000)
                let receipt = try await adapters.bitCraft.craftContinue(leg, entity, nextTimestampMs())
                consecutiveFailures = 0
                if let craft = receipt.craft {
                    effortDone = Int(craft.progress)
                }
                if plan.effortTotal > 0, effortDone >= plan.effortTotal {
                    await ingestor.ingest(Intent.DriverEvent(
                        craftEntityID: entity, outcome: .completed(effortDone: effortDone)
                    ))
                    return
                }
                await ingestor.ingest(Intent.DriverEvent(
                    craftEntityID: entity,
                    outcome: .crafting(effortDone: effortDone, stamina: receipt.stamina?.stamina)
                ))
                try await adapters.sleep(config.craftInterIterationGapSecs)
            } catch let error as RegionDriverClient.CallError {
                guard case .refused(let message) = error else {
                    // Transport-class failure (the leg may be dying — the
                    // game-session loop owns the user-visible outcome):
                    // a few retries, then end the drive.
                    consecutiveFailures += 1
                    if consecutiveFailures >= config.craftMaxConsecutiveErrors {
                        await ingestor.ingest(Intent.DriverEvent(
                            craftEntityID: entity,
                            outcome: .failed("the region connection stopped responding")
                        ))
                        return
                    }
                    try? await adapters.sleep(0.5)
                    if Task.isCancelled { return }
                    continue
                }
                switch DriverRefusal.classify(message) {
                case .outOfStamina:
                    await ingestor.ingest(Intent.DriverEvent(
                        craftEntityID: entity, outcome: .paused(.outOfStamina)
                    ))
                    return
                case .tooQuickly:
                    // The cadence gate caught us under 95 % — widen the
                    // delay and let the loop head re-arm via _start.
                    delayMs = min(
                        delayMs * config.craftTooFastBackoff,
                        plan.delayMs * config.craftTooFastBackoffCap
                    )
                    continue
                case .craftGone, .tooFar, .other:
                    await ingestor.ingest(Intent.DriverEvent(
                        craftEntityID: entity, outcome: .failed(message)
                    ))
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                // Transport-class failure: the leg may be dying (the
                // game-session loop owns the user-visible outcome) — a few
                // retries, then end the drive.
                consecutiveFailures += 1
                if consecutiveFailures >= config.craftMaxConsecutiveErrors {
                    await ingestor.ingest(Intent.DriverEvent(
                        craftEntityID: entity,
                        outcome: .failed("the region connection stopped responding")
                    ))
                    return
                }
                try? await adapters.sleep(0.5)
                if Task.isCancelled { return }
            }
        }
    }

    // MARK: Walk stage

    private enum WalkOutcome2 {
        case arrived(Int32, Int32)
        case failed(String)
        case cancelled
    }

    /// Walks to the stand-point — straight-line hops of ≤1 tile paced
    /// under the measured walk speed, each confirmed by its receipt; a
    /// rejected hop halves once, then fails. Already-in-range skips the
    /// walk entirely (the common resume case).
    private static func walkToStation(
        leg: RegionLeg,
        plan: EphemeralState.Session.CraftPlan,
        playerEntityID: UInt64,
        adapters: Adapters,
        nextTimestampMs: () -> UInt64
    ) async -> WalkOutcome2 {
        let config = GameConfig.shared
        let leg = leg // capture clarity in the closures below
        do {
            guard let station = try await adapters.bitCraft.stationLocation(leg, plan.buildingEntityID) else {
                return .failed("Station location unknown — try again in a moment.")
            }
            guard station.dimension == 1 else {
                return .failed("Interior stations aren't supported yet — craft there in game.")
            }
            guard let own = try await adapters.bitCraft.ownPosition(leg, playerEntityID) else {
                return .failed("Player position unknown — try again in a moment.")
            }

            let stationTile = (
                x: Int32((Double(station.x) / 1_000).rounded()),
                z: Int32((Double(station.z) / 1_000).rounded())
            )
            let ownTile = (
                x: Int32((Double(own.locationX) / 1_000).rounded()),
                z: Int32((Double(own.locationZ) / 1_000).rounded())
            )
            let tileDistance = hexTileDistance(
                dx: ownTile.x - stationTile.x, dz: ownTile.z - stationTile.z
            )
            if tileDistance <= plan.standDistanceTiles {
                return .arrived(own.locationX, own.locationZ)
            }

            // Stand-point: the station's center shifted toward the player
            // by the stand-off distance, in raw milli-tile units.
            let dx = Double(own.locationX - station.x)
            let dz = Double(own.locationZ - station.z)
            let length = (dx * dx + dz * dz).squareRoot()
            let offset = Double(plan.standDistanceTiles) * 1_000
            let target = (
                x: Int32((Double(station.x) + dx / length * offset).rounded()),
                z: Int32((Double(station.z) + dz / length * offset).rounded())
            )

            var current = (x: Double(own.locationX), z: Double(own.locationZ))
            var origin: (x: Int32, z: Int32)? = (own.locationX, own.locationZ)
            let deadline = Date().addingTimeInterval(config.walkTimeoutSecs)
            var hopScale = 1.0
            while Date() < deadline {
                if Task.isCancelled { return .cancelled }
                let rx = Double(target.x) - current.x
                let rz = Double(target.z) - current.z
                let remaining = (rx * rx + rz * rz).squareRoot()
                if remaining < 10 { // within a hundredth of a tile
                    // The final zero-duration stop call anchors the
                    // position server-side (the captured client's pattern).
                    _ = try await adapters.bitCraft.movePlayer(
                        leg, nextTimestampMs(),
                        target.x, target.z, 1,
                        target.x, target.z,
                        0, 1
                    )
                    return .arrived(target.x, target.z)
                }
                let hopLength = min(config.walkHopRawDistance * hopScale, remaining)
                let nx = current.x + rx / remaining * hopLength
                let nz = current.z + rz / remaining * hopLength
                let duration = Float(hopLength / plan.walkSpeedRawPerSec * config.walkDurationMargin)
                do {
                    _ = try await adapters.bitCraft.movePlayer(
                        leg, nextTimestampMs(),
                        Int32(nx.rounded()), Int32(nz.rounded()), 1,
                        origin?.x, origin?.z,
                        duration, 2
                    )
                    hopScale = 1.0
                } catch let error as RegionDriverClient.CallError {
                    guard case .refused(let message) = error else { throw error }
                    if hopScale > 0.45 {
                        hopScale /= 2 // one halving retry for a rejected hop
                        continue
                    }
                    return .failed("The walk was refused: \(message)")
                }
                origin = (Int32(nx.rounded()), Int32(nz.rounded()))
                current = (nx, nz)
            }
            return .failed("The walk took too long — try again closer to the station.")
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed("The region connection dropped while walking.")
        }
    }
}

extension Activity.StopCraft: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        do {
            _ = try await adapters.bitCraft.craftCancel(leg, pocketID)
            coreLog.info("craft driver: craft \(pocketID, privacy: .public) cancelled")
        } catch {
            coreLog.info("craft driver: craft_cancel best-effort failed: \(String(describing: error), privacy: .public)")
        }
        // Clear any in-flight action lock too — both best-effort.
        _ = try? await adapters.bitCraft.playerActionCancel(leg)
    }
}
