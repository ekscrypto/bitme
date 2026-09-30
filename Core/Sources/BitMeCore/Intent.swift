import Foundation

/// Namespace for concrete intents. Every `Intent.X` is a `Sendable` struct
/// conforming to `StateMutator` (fenex-light pattern). Public intents are the
/// UI-facing surface; internal ones are activity → machine feedback.
public enum Intent {
    /// User typed a character name on the onboarding screen.
    public struct ResolvePlayer: Sendable {
        public let name: String

        public init(name: String) {
            self.name = name
        }
    }

    /// User asked to forget the resolved character (stops the session loop).
    public struct SignOut: Sendable {
        public init() {}
    }

    // MARK: - BitCraft account sign-in

    /// User opened the sign-in screen (from onboarding).
    public struct ShowBitCraftSignIn: Sendable {
        public init() {}
    }

    /// User left the sign-in screen without completing it.
    public struct DismissBitCraftSignIn: Sendable {
        public init() {}
    }

    /// User submitted an email — request the access code.
    public struct StartBitCraftSignIn: Sendable {
        public let email: String

        public init(email: String) {
            self.email = email
        }
    }

    /// User submitted the emailed code.
    public struct SubmitAccessCode: Sendable {
        public let code: String

        public init(code: String) {
            self.code = code
        }
    }

    /// User tapped "use a different email" — back to email entry.
    public struct EditSignInEmail: Sendable {
        public init() {}
    }

    /// User asked to retry locating the signed-in account's player (the
    /// previous attempt failed — the account is verified, no new code
    /// needed). Account-driven apps only.
    public struct RetryAccountLink: Sendable {
        public init() {}
    }

    /// User tapped the pre-sign-in gate's action — sign the game session
    /// in (`CallReducer sign_in` on the game's global database, taking the
    /// account's one live session from whoever holds it). Only taken while
    /// the latest snapshot places the character inside a claim — without
    /// one (or without a snapshot at all) the machine refuses the action,
    /// mirroring the gate's disabled button. Account-driven apps only.
    public struct SignInGameSession: Sendable {
        public init() {}
    }

    /// User asked to forget the signed-in BitCraft account (deletes token).
    public struct ForgetBitCraftAccount: Sendable {
        public init() {}
    }

    // MARK: - Craft driver (Pocket Crafter)

    /// User tapped a craft's action button — drive it: walk the player to
    /// the station (v1: outdoor stations) and run the
    /// `craft_continue_start`/`craft_continue` loop until completion,
    /// pause, or refusal. The craft must be one the workstations list
    /// renders (own pending or another player's shared, not complete).
    public struct TapCraft: Sendable {
        public let craftEntityID: UInt64

        public init(craftEntityID: UInt64) {
            self.craftEntityID = craftEntityID
        }
    }

    /// User tapped Pause on the active craft — stops the loop; the craft
    /// suspends server-side (its station lock lapses) and resumes later
    /// via a fresh `craft_continue_start`.
    public struct PauseCraftDriver: Sendable {
        public init() {}
    }

    /// User tapped Resume on a paused craft — re-arms with
    /// `craft_continue_start` and continues the loop.
    public struct ResumeCraftDriver: Sendable {
        public init() {}
    }

    /// User tapped Stop on the active craft — cancels the loop and calls
    /// `craft_cancel` (best effort) to clear the bench craft.
    public struct StopCraftDriver: Sendable {
        public init() {}
    }

    /// User dismissed the completed/failed craft banner.
    public struct DismissCraftBanner: Sendable {
        public init() {}
    }

    /// The app left the foreground — a running drive pauses (iOS
    /// suspends the process; the client-paced loop cannot run), and a
    /// paused-on-background drive resumes when the app returns.
    public struct AppBackgrounded: Sendable {
        public init() {}
    }

    /// The app returned to the foreground — a drive paused by
    /// backgrounding resumes on its own.
    public struct AppForegrounded: Sendable {
        public init() {}
    }
}

// MARK: - Internal feedback intents (activities → machine)

extension Intent {
    /// Bootstrap activity finished restoring persisted identity.
    struct BootstrapCompleted: Sendable {
        let identity: StoredIdentity?
        let bitCraftAccount: BitCraftAccount?
    }

    // BitCraft sign-in feedback (activities → machine)

    struct AccessCodeRequested: Sendable {
        let email: String
    }

    struct AccessCodeRequestFailed: Sendable {
        let message: String
    }

    struct BitCraftAuthenticated: Sendable {
        let account: BitCraftAccount
    }

    struct BitCraftAuthenticationFailed: Sendable {
        let email: String
        let message: String
    }

    // Account link feedback (activity → machine) — the account's player was
    // located (or not) over the game's global database.

    struct AccountPlayerLinked: Sendable {
        let accountEmail: String
        let player: AccountPlayer
    }

    struct AccountPlayerLinkFailed: Sendable {
        let accountEmail: String
        let message: String
    }

    struct ResolveSucceeded: Sendable {
        let response: ResolveResponse
    }

    struct ResolveFailed: Sendable {
        let message: String
    }

    struct GamedataLoaded: Sendable {
        let gamedata: FoodBuffGamedata?
    }

    struct SessionPolled: Sendable {
        let snapshot: SessionSnapshot
        /// ADR-014 carrier: mutate stamps the loop's next delay here.
        let carrier: SessionLoopCarrier
        /// Local-clock ms at poll time — mutates stay clock-pure (the
        /// resource-window staleness/drift checks anchor on it).
        let polledAtMs: Double
    }

    struct SessionPollFailed: Sendable {
        let kind: PollFailure
        let message: String
        let carrier: SessionLoopCarrier

        enum PollFailure: Sendable {
            case notFound
            case transient
        }
    }

    // Resource map (docs/api.md §6–7) — feedback from the map activities.

    struct ResourceWindowFetched: Sendable {
        let window: ResourceWindow
        let fetchedAtMs: Double
    }

    struct ResourceWindowUnavailable: Sendable {
        enum Kind: Sendable {
            /// 202 — region still seeding; back off before retrying.
            case seeding
            /// Network error / 5xx; short backoff.
            case failed
        }

        let kind: Kind
        let atMs: Double
    }

    struct ResourceDictionaryLoaded: Sendable {
        let region: Int
        let dictionary: ResourceDictionary
    }

    struct TerrainPlaneFetched: Sendable {
        let plane: TerrainPlane
        let atMs: Double
    }

    struct ResourceStreamEventReceived: Sendable {
        let event: ResourceStreamEvent
        /// Local-clock ms at receipt; converted to relay clock in the mutate.
        let atMs: Double
    }

    struct ResourceStreamStatusChanged: Sendable {
        let status: EphemeralState.Session.ResourceMapState.StreamStatus
    }

    // Game session (account-driven apps) — feedback from the game-session
    // loop: the account's `sign_in` on the game's global database.

    struct GameSessionStatusChanged: Sendable {
        let status: EphemeralState.Session.GameSessionState.Status
        /// Set on `.rejected`; nil otherwise.
        let message: String?
    }

    /// The connection holding the game session ended — kicked by another
    /// sign_in (the desktop client), dropped, or refused. The machine
    /// returns to the pre-sign-in gate; the session is never re-taken
    /// automatically.
    struct GameSessionEnded: Sendable {
        /// Why the session ended, when the ending path knows — a failed
        /// connection attempt carries its error so the gate can say more
        /// than "ended". Nil falls back to what the machine last knew
        /// (a refusal message, or the generic ending).
        var notice: String?

        init(notice: String? = nil) {
            self.notice = notice
        }
    }

    // Claim buildings (account-driven apps) — feedback from the region leg.

    /// The game session's region-shard leg signed in: carries the live
    /// connection the claim-buildings sync subscribes on.
    struct GameSessionRegionLegReady: Sendable {
        let leg: RegionLeg
    }

    /// A pooled batch of claim-buildings sync events (row diffs, catalog
    /// loads, status changes) applied to the session's buildings state in
    /// one mutation — one ingest, one rep broadcast per ~0.5 s of rows.
    struct ClaimBuildingsChanged: Sendable {
        let events: [ClaimBuildingsEvent]
    }

    /// Player-vitals sync events (own-row diffs from the region leg)
    /// applied to the session's vitals state in one mutation.
    struct PlayerVitalsChanged: Sendable {
        let events: [PlayerVitalsEvent]
    }

    /// Prospection watch events (the own `prospecting_state` row off the
    /// region mirror) applied to the session's prospection state in one
    /// mutation.
    struct ProspectionChanged: Sendable {
        let events: [ProspectionEvent]
    }

    /// Craft-driver feedback: the loop's per-iteration outcome (effort
    /// from the receipt's craft row, stamina from its stamina row) and
    /// terminal states. Guarded on the craft entity id — a late event
    /// from a superseded drive must not move the new one's state.
    struct DriverEvent: Sendable {
        enum Outcome: Equatable, Sendable {
            /// A `craft_continue` completed: server-confirmed effort.
            case crafting(effortDone: Int, stamina: Float?)
            case paused(EphemeralState.Session.DriverState.PauseReason)
            /// The effort goal was reached — carries the final effort.
            case completed(effortDone: Int)
            case failed(String)
        }

        let craftEntityID: UInt64
        let outcome: Outcome
    }

    /// The walk stage's outcome from `Activity.WalkToStation` — the drive
    /// then either proceeds to the craft loop or ends.
    struct WalkOutcome: Sendable {
        enum Outcome: Equatable, Sendable {
            case arrived(positionX: Int32, positionZ: Int32)
            case failed(String)
        }

        let craftEntityID: UInt64
        let outcome: Outcome
    }
}

/// Reference carrier the session loop and the intents share (ADR-014: the
/// activity cannot read state; the mutate stamps the next delay into the
/// carrier the loop already holds).
final class SessionLoopCarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var _nextDelayMs: Double = 1_000

    var nextDelayMs: Double {
        get { lock.withLock { _nextDelayMs } }
        set { lock.withLock { _nextDelayMs = newValue } }
    }
}

// MARK: - Mutations

/// Starts (or replaces) the session loops for a freshly linked character.
/// A stale session for a *different* entity can be running when a late
/// bootstrap raced the resolve (the CLI's start → SignOut → resolve
/// sequence) — its loops are retired before fresh ones spawn. Returns the
/// session to store plus the loop activities to run. The game-session
/// loop is deliberately not among them: signing the game session in is a
/// user action (`Intent.SignInGameSession`), never a side effect of
/// linking.
private func startSession(
    entityID: String,
    in ephemeral: EphemeralState
) -> (session: EphemeralState.Session, activities: [any AsyncActivity]) {
    if let existing = ephemeral.session, existing.entityID == entityID {
        return (existing, [])
    }
    ephemeral.session?.loop.cancel()
    ephemeral.session?.streamLoop?.cancel()
    ephemeral.session?.gameSessionLoop?.cancel()
    ephemeral.session?.buildingsLoop?.cancel()
    ephemeral.session?.vitalsLoop?.cancel()
    ephemeral.session?.prospectionLoop?.cancel()
    let loop = CancellableTask()
    let streamLoop = CancellableTask()
    let session = EphemeralState.Session(entityID: entityID, loop: loop, streamLoop: streamLoop)
    var activities: [any AsyncActivity] = [Activity.SessionLoop(
        entityID: entityID, carrier: session.carrier, cancellable: loop
    )]
    if ephemeral.resourceMapEnabled {
        activities.append(Activity.ResourceStreamLoop(
            entityID: entityID, carrier: session.streamCarrier, cancellable: streamLoop
        ))
    }
    return (session, activities)
}

extension Intent.ResolvePlayer: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .noChange }
        var ephemeral = ephemeral
        ephemeral.onboarding = .resolving(name: name)
        ephemeral.resolveError = nil
        ephemeral.resolvedOfflineHint = false
        return StateChange(ephemeral: ephemeral, activities: [Activity.ResolvePlayer(name: name)])
    }
}

extension Intent.ResolveSucceeded: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var persistent = persistent
        var ephemeral = ephemeral
        persistent.identity = StoredIdentity(
            entityID: response.entityID,
            username: response.username,
            regionID: response.regionID,
            resolvedAt: .now
        )
        ephemeral.onboarding = .idle
        ephemeral.resolvedOfflineHint = response.signedIn == false

        let started = startSession(
            entityID: response.entityID, in: ephemeral
        )
        ephemeral.session = started.session
        return StateChange(
            persistent: persistent, ephemeral: ephemeral,
            activities: [Activity.LoadGamedata()] + started.activities
        )
    }
}

extension Intent.ResolveFailed: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        ephemeral.onboarding = .idle
        ephemeral.resolveError = message
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.BootstrapCompleted: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var persistent = persistent
        var ephemeral = ephemeral
        var activities: [any AsyncActivity] = [Activity.LoadGamedata()]
        // Restore only when nothing newer is in flight or landed: a late
        // bootstrap (its restore raced a SignOut + resolve) must not
        // resurrect the previous character or clobber the new session.
        if let identity, ephemeral.session == nil,
           case .idle = ephemeral.onboarding {
            persistent.identity = identity
            let started = startSession(
                entityID: identity.entityID,
                in: ephemeral
            )
            ephemeral.session = started.session
            activities += started.activities
        }
        // The account restore has no races to guard: sign-in never runs
        // before bootstrap finishes (the machine processes intents serially,
        // and the screen is reachable only after the first rep).
        persistent.bitCraftAccount = bitCraftAccount
        // Account-driven apps: an account with no linked character resumes
        // the link (a previous link failed, or the identity file is gone).
        // With a character, the restore above already started the session.
        // A persisted JWT never re-opens the email screen — the gate shows
        // immediately in its resuming state while the link re-locates the
        // character over the global database.
        if ephemeral.accountDrivenSignIn, let bitCraftAccount,
           persistent.identity == nil, ephemeral.session == nil {
            ephemeral.signIn = EphemeralState.SignInState(
                phase: .linking(email: bitCraftAccount.email)
            )
            ephemeral.preSignInVisible = true
            ephemeral.resumingAccount = bitCraftAccount.email
            activities.append(Activity.LinkAccountPlayer(account: bitCraftAccount))
        } else if ephemeral.accountDrivenSignIn, persistent.identity != nil {
            // A restored launch lands on the pre-sign-in gate, not in a
            // held session — the game session is only ever user-taken.
            ephemeral.preSignInVisible = true
        }
        return StateChange(persistent: persistent, ephemeral: ephemeral, activities: activities)
    }
}

extension Intent.GamedataLoaded: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        ephemeral.gamedata = gamedata
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.SessionPolled: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        session.previous = session.snapshot
        session.snapshot = snapshot
        session.connection = .ok
        session.notFoundBackoffMs = 0
        session.errorBackoffMs = 0
        session.lastError = nil
        session.pacing.observe(target: snapshot.target, nowMs: Double(snapshot.serverTimeMs))
        session.carrier.nextDelayMs = 1_000
        session.lastPolledLocalMs = polledAtMs

        // Resource map: fetch a window while the player is live in the
        // overworld (deltas then keep it fresh; this is also the recovery
        // move), and gate the change stream on the same liveness. The whole
        // stack is skipped for apps that never render the map.
        let config = GameConfig.shared
        let live = snapshot.signedIn != false && (snapshot.position?.dimension ?? 1) == 1
        session.streamCarrier.wanted = live && ephemeral.resourceMapEnabled

        // Claim-buildings sync: stamp the claim the character stands in —
        // the entity id the pre-sign-in gate validated. The sync pins the
        // first value it sees (one claim per session, by product scope).
        if let idText = snapshot.claim?.entityID, let claimID = UInt64(idText) {
            session.claimCarrier.claimEntityID = claimID
        }
        var activities: [any AsyncActivity] = []
        if live, ephemeral.resourceMapEnabled {
            var need = session.resourceMap.window == nil
            if let window = session.resourceMap.window {
                if let position = snapshot.position {
                    let drift = max(
                        abs(position.tileX - window.centerX),
                        abs(position.tileZ - window.centerZ)
                    )
                    need = need || drift > config.mapDriftRefetchTiles
                }
                need = need || polledAtMs - session.resourceMap.windowFetchedAtMs > config.mapWindowStaleMs
            }
            if need,
               !session.resourceMap.fetchInFlight,
               polledAtMs > session.resourceMap.seedingUntilMs,
               polledAtMs > session.resourceMap.refetchNotBeforeMs {
                session.resourceMap.fetchInFlight = true
                activities.append(Activity.FetchResourceWindow(entityID: session.entityID))
            }

            // Prospection watch (X-Ray): the pending-prospection compass
            // row rides the region mirror anonymously, so it needs only the
            // region id — start it once the region is known, restart it if
            // the player region-transfers. Cheap single-row socket; the
            // row's presence *is* the pending state, and a lost connection
            // clears the overlay (a later poll re-arms a fresh watch).
            let region = snapshot.region > 0
                ? snapshot.region
                : (session.resourceMap.window?.region ?? persistent.identity?.regionID)
            if let region,
               let playerEntityID = UInt64(session.entityID),
               session.prospectionRegion != region {
                session.prospectionLoop?.cancel()
                let prospectionLoop = CancellableTask()
                session.prospectionLoop = prospectionLoop
                session.prospectionRegion = region
                // A transferred player's trail belongs to the old region —
                // never show a stale cone across a region boundary.
                session.prospection = EphemeralState.Session.ProspectionState()
                activities.append(Activity.ProspectionWatch(
                    playerEntityID: playerEntityID,
                    region: region,
                    cancellable: prospectionLoop
                ))
            }
        }
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral, activities: activities)
    }
}

extension Intent.SessionPollFailed: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        switch kind {
        case .notFound:
            // Deploy reseed windows last minutes — start at 30 s, cap 5 min.
            session.connection = .down
            session.notFoundBackoffMs = min(max(session.notFoundBackoffMs, 30_000) * 2, 300_000)
            session.carrier.nextDelayMs = session.notFoundBackoffMs
            session.lastError = "player not present in any mirrored region (or mirror reseeding)"
            // No point streaming a player no mirrored region knows.
            session.streamCarrier.wanted = false
        case .transient:
            // Network error / 5xx: degraded, not down. Start 5 s, cap 1 min.
            session.connection = .degraded
            session.errorBackoffMs = min(session.errorBackoffMs == 0 ? 5_000 : session.errorBackoffMs * 2, 60_000)
            session.carrier.nextDelayMs = session.errorBackoffMs
            session.lastError = message
        }
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

// MARK: - Resource map mutations

extension Intent.ResourceWindowFetched: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        let (counts, populated) = ResourceMapEngine.tally(of: window)
        session.resourceMap.window = window
        session.resourceMap.windowFetchedAtMs = fetchedAtMs
        session.resourceMap.fetchInFlight = false
        session.resourceMap.tally = counts
        session.resourceMap.populatedTiles = populated
        session.resourceMap.tileVersion += 1
        var activities: [any AsyncActivity] = []
        if let need = session.resourceMap.needsDictionary {
            activities.append(Activity.LoadResourceDictionary(region: need.region, neededVersion: need.version))
        }
        // Terrain behind the window: fetch when missing, when it no longer
        // covers the window (drift), or past its TTL. A generation bump on
        // an arriving plane is the terraform signal — the fetch refreshes it.
        let config = GameConfig.shared
        let needsTerrain: Bool
        if let plane = session.resourceMap.terrain {
            needsTerrain = plane.region != window.region
                || !plane.coversTile(x: window.centerX, z: window.centerZ)
                || fetchedAtMs - session.resourceMap.terrainFetchedAtMs > config.mapTerrainStaleMs
        } else {
            needsTerrain = true
        }
        if needsTerrain {
            activities.append(Activity.FetchTerrain(centerX: window.centerX, centerZ: window.centerZ))
        }
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral, activities: activities)
    }
}

extension Intent.ResourceWindowUnavailable: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        let config = GameConfig.shared
        switch kind {
        case .seeding:
            session.resourceMap.seedingUntilMs = atMs + config.mapSeedingBackoffMs
        case .failed:
            session.resourceMap.refetchNotBeforeMs = atMs + config.mapFetchFailureBackoffMs
        }
        session.resourceMap.fetchInFlight = false
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.ResourceDictionaryLoaded: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        // A ready answer is at least as fresh as the request that asked for
        // it; windows and deltas re-check versions on use.
        guard dictionary.ready, dictionary.region == region else { return .noChange }
        session.resourceMap.dictionary = dictionary
        session.resourceMap.entryByIndex = dictionary.entryByIndex
        session.resourceMap.tileVersion += 1
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.TerrainPlaneFetched: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        // Only terrain for the window's region is useful; anything else is a
        // stale response from before a drift refetch.
        guard let window = session.resourceMap.window, plane.region == window.region else {
            return .noChange
        }
        session.resourceMap.terrain = plane
        session.resourceMap.terrainFetchedAtMs = atMs
        session.resourceMap.tileVersion += 1
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.ResourceStreamEventReceived: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        switch event {
        case let .subscribed(anchorX, anchorZ, _, region, dictVersion):
            session.resourceMap.streamStatus = .live
            session.resourceMap.anchorX = anchorX
            session.resourceMap.anchorZ = anchorZ
            var activities: [any AsyncActivity] = []
            if session.resourceMap.dictionary?.region != region
                || session.resourceMap.dictionary?.dictVersion != dictVersion {
                activities.append(Activity.LoadResourceDictionary(region: region, neededVersion: dictVersion))
            }
            ephemeral.session = session
            return StateChange(ephemeral: ephemeral, activities: activities)

        case let .delta(delta):
            guard let window = session.resourceMap.window else { return .noChange }
            guard let applied = ResourceMapEngine.applying(delta, to: window) else {
                // The stream's dictionary generation raced the window fetch —
                // mark stale so the next poll refetches (converges both).
                session.resourceMap.windowFetchedAtMs = 0
                ephemeral.session = session
                return StateChange(ephemeral: ephemeral)
            }
            guard !applied.transitions.isEmpty else { return .noChange }
            session.resourceMap.window = applied.window
            session.resourceMap.tileVersion += 1
            // Best-effort relay-clock timestamp: local receipt corrected by
            // the last snapshot's clock offset.
            var relayOffset: Double = 0
            if let snapshot = session.snapshot, session.lastPolledLocalMs > 0 {
                relayOffset = Double(snapshot.serverTimeMs) - session.lastPolledLocalMs
            }
            var entries: [EphemeralState.Session.ResourceMapState.FeedEntry] = []
            for t in applied.transitions {
                if TileWord.hasResource(t.oldWord) {
                    session.resourceMap.tally[t.oldIndex, default: 0] -= 1
                    session.resourceMap.populatedTiles -= 1
                    entries.append(.init(
                        tileX: t.x, tileZ: t.z, dictIndex: t.oldIndex,
                        spawned: false, atMs: atMs + relayOffset
                    ))
                }
                if TileWord.hasResource(t.newWord) {
                    session.resourceMap.tally[t.newIndex, default: 0] += 1
                    session.resourceMap.populatedTiles += 1
                    entries.append(.init(
                        tileX: t.x, tileZ: t.z, dictIndex: t.newIndex,
                        spawned: true, atMs: atMs + relayOffset
                    ))
                }
            }
            if !entries.isEmpty {
                let capacity = GameConfig.shared.mapFeedCapacity
                // Newest first: later transitions land ahead of earlier ones.
                session.resourceMap.feed = Array((entries.reversed() + session.resourceMap.feed).prefix(capacity))
            }
            ephemeral.session = session
            return StateChange(ephemeral: ephemeral)

        case .resync, .moved:
            // Universal recovery move: refetch the window.
            session.resourceMap.windowFetchedAtMs = 0
            var activities: [any AsyncActivity] = []
            if !session.resourceMap.fetchInFlight {
                session.resourceMap.fetchInFlight = true
                activities.append(Activity.FetchResourceWindow(entityID: session.entityID))
            }
            ephemeral.session = session
            return StateChange(ephemeral: ephemeral, activities: activities)

        case .heartbeat:
            // Proof of life only — the watchdog lives in the client.
            return .noChange
        }
    }
}

extension Intent.ResourceStreamStatusChanged: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        guard session.resourceMap.streamStatus != status else { return .noChange }
        session.resourceMap.streamStatus = status
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

// MARK: - Game session mutations (account-driven apps)

extension Intent.GameSessionStatusChanged: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        guard session.gameSession.status != status
            || session.gameSession.lastError != message else {
            return .noChange
        }
        session.gameSession.status = status
        session.gameSession.lastError = message
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.SignInGameSession: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard ephemeral.accountDrivenSignIn,
              let account = persistent.bitCraftAccount,
              let identity = persistent.identity,
              var session = ephemeral.session,
              session.gameSessionLoop == nil,
              // The character must stand in a claim — and a snapshot must
              // say so; without one the state is unknown, which refuses.
              session.snapshot?.claim != nil else {
            return .noChange
        }
        let gameSessionLoop = CancellableTask()
        session.gameSessionLoop = gameSessionLoop
        session.gameSession = EphemeralState.Session.GameSessionState()
        ephemeral.session = session
        ephemeral.preSignInVisible = false
        ephemeral.gameSessionNotice = nil
        return StateChange(ephemeral: ephemeral, activities: [
            Activity.GameSessionLoop(
                token: account.token,
                entityID: identity.entityID,
                regionID: identity.regionID,
                identityHex: account.identityHex,
                cancellable: gameSessionLoop
            )
        ])
    }
}

extension Intent.GameSessionEnded: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        // What the machine knows decides the gate's notice: a refused
        // sign-in carries the server's message; an ended-path notice (a
        // failed connection attempt) wins over both; anything else is
        // simply a session that ended (the gate's live presence line tells
        // the user whether another device now holds it).
        let notice: String
        if let endedNotice = self.notice {
            notice = endedNotice
        } else if session.gameSession.status == .rejected, let error = session.gameSession.lastError {
            notice = "The game refused the sign-in: \(error)"
        } else {
            notice = "The game session ended."
        }
        session.gameSessionLoop?.cancel()
        session.gameSessionLoop = nil
        session.gameSession = EphemeralState.Session.GameSessionState()
        // The region leg (and its buildings/vitals syncs) died with the
        // session — the craft driver's reducer calls die with it too.
        session.buildingsLoop?.cancel()
        session.buildingsLoop = nil
        session.vitalsLoop?.cancel()
        session.vitalsLoop = nil
        session.vitals = EphemeralState.Session.VitalsState()
        session.driverLoop?.cancel()
        session.driverLoop = nil
        session.driver = EphemeralState.Session.DriverState()
        session.regionLeg = nil
        var cleared = EphemeralState.Session.BuildingsState()
        cleared.version = session.buildings.version + 1 // monotonic across resets
        session.buildings = cleared
        session.claimCarrier.claimEntityID = nil
        ephemeral.session = session
        ephemeral.preSignInVisible = true
        ephemeral.gameSessionNotice = notice
        return StateChange(ephemeral: ephemeral)
    }
}

// MARK: - Claim-buildings mutations (account-driven apps)

extension Intent.GameSessionRegionLegReady: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session,
              // Only a held game session owns a region leg — a late arrival
              // after GameSessionEnded must not resurrect the sync.
              session.gameSessionLoop != nil,
              session.regionLeg == nil,
              let playerEntityID = UInt64(session.entityID) else {
            return .noChange
        }
        session.regionLeg = leg
        var buildings = EphemeralState.Session.BuildingsState()
        buildings.playerEntityID = playerEntityID
        buildings.status = .syncing
        buildings.version = session.buildings.version + 1 // monotonic across resets
        session.buildings = buildings
        session.vitals = EphemeralState.Session.VitalsState()
        let buildingsLoop = CancellableTask()
        session.buildingsLoop = buildingsLoop
        let vitalsLoop = CancellableTask()
        session.vitalsLoop = vitalsLoop
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral, activities: [
            Activity.ClaimBuildingsLoop(
                leg: leg,
                playerEntityID: playerEntityID,
                claimCarrier: session.claimCarrier,
                cancellable: buildingsLoop
            ),
            Activity.PlayerVitalsLoop(
                leg: leg,
                playerEntityID: playerEntityID,
                cancellable: vitalsLoop
            ),
        ])
    }
}

extension Intent.ClaimBuildingsChanged: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        for event in events {
            switch event {
            case .syncing:
                session.buildings.status = .syncing
            case .live:
                session.buildings.status = .live
                session.buildings.lastError = nil
            case .claim(let header):
                session.buildings.claim = header
            case .gamedata(let gamedata):
                session.buildings.gamedata = gamedata
            case .buildingChanged(let building):
                session.buildings.buildings[building.entityID] = building
            case .buildingRemoved(let entityID):
                session.buildings.buildings[entityID] = nil
            case .nicknameChanged(let entityID, let nickname):
                session.buildings.nicknames[entityID] = nickname
            case .nicknameRemoved(let entityID):
                session.buildings.nicknames[entityID] = nil
            case .craftChanged(let craft):
                session.buildings.crafts[craft.entityID] = craft
            case .craftRemoved(let entityID):
                session.buildings.crafts[entityID] = nil
            case .sharedCraftChanged(let entityID):
                session.buildings.sharedCraftIDs.insert(entityID)
            case .sharedCraftRemoved(let entityID):
                session.buildings.sharedCraftIDs.remove(entityID)
            case .failed(let message):
                session.buildings.status = .failed
                session.buildings.lastError = message
            }
        }
        session.buildings.version += 1
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

// MARK: - Player-vitals mutations (account-driven apps)

extension Intent.PlayerVitalsChanged: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        for event in events {
            switch event {
            case .stamina(let value):
                session.vitals.stamina = value
            case .health(let value):
                session.vitals.health = value
            case .satiation(let value):
                session.vitals.satiation = value
            case .teleportEnergy(let value):
                session.vitals.teleportEnergy = value
            case .stats(let values):
                session.vitals.stats = values
            case .action(let row):
                session.vitals.action = row.actionType
                session.vitals.actionRecipeID = row.recipeID
            case .position(let row):
                session.vitals.positionX = row.locationX
                session.vitals.positionZ = row.locationZ
                session.vitals.dimension = row.dimension
            case .failed:
                // The stream ends with the leg; the game-session loop owns
                // the user-visible outcome. Nothing to mutate.
                continue
            }
        }
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

// MARK: - Prospection mutations (X-Ray map overlay)

extension Intent.ProspectionChanged: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session, session.prospectionRegion != nil else {
            return .noChange
        }
        for event in events {
            switch event {
            case .updated(let row):
                // The fix origin: the server measured the bearing from
                // where the player stood at `last_prospection_timestamp`,
                // so it is captured once per prospection and frozen. Rows
                // also rewrite for contribution-only changes and get
                // re-delivered on watch reconnects — the server timestamp
                // tells those apart from a genuine new fix. The first row
                // after arming is always one the watch witnessed live (or
                // a reconnect re-delivery, bounded by the transport gap):
                // `RegionProspectClient` drops the subscription snapshot,
                // whose fix origin would be unknowable. (The position is
                // the latest poll snapshot, ≤1 s old; prospection is a
                // stationary channel, so that is the same spot the server
                // measured from.)
                let prospectionMs = Double(row.lastProspectionMicros) / 1_000
                let isNewFix = session.prospection.lastProspectionMs == nil
                    || prospectionMs > session.prospection.lastProspectionMs!
                    || session.prospection.fixX == nil
                if isNewFix, let position = session.snapshot?.position {
                    session.prospection.fixX = position.worldX
                    session.prospection.fixZ = position.worldZ
                }
                session.prospection.prospectingID = row.prospectingID
                session.prospection.trailEntityID = row.crumbTrailEntityID
                session.prospection.completedSteps = Int(row.completedSteps)
                session.prospection.ongoingStep = Int(row.ongoingStep)
                session.prospection.totalSteps = Int(row.totalSteps)
                session.prospection.nextCrumbAngles = row.nextCrumbAngles
                session.prospection.toNextNode = row.toNextNode
                session.prospection.lastProspectionMs = prospectionMs
            case .ended, .failed:
                // Trail done/abandoned, or the watch died — a stale cone
                // must never linger. A later poll re-arms the watch.
                session.prospection = EphemeralState.Session.ProspectionState()
            }
        }
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.SignOut: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var persistent = persistent
        var ephemeral = ephemeral
        ephemeral.session?.loop.cancel()
        ephemeral.session?.streamLoop?.cancel()
        ephemeral.session?.gameSessionLoop?.cancel()
        ephemeral.session?.buildingsLoop?.cancel()
        ephemeral.session?.vitalsLoop?.cancel()
        ephemeral.session?.prospectionLoop?.cancel()
        ephemeral.session = nil
        persistent.identity = nil
        if ephemeral.accountDrivenSignIn {
            // Signing out means the account too: its token leaves the
            // Keychain and the app returns to fresh email entry.
            persistent.bitCraftAccount = nil
            ephemeral.signIn = EphemeralState.SignInState()
            ephemeral.signInVisible = false
            ephemeral.preSignInVisible = false
            ephemeral.gameSessionNotice = nil
        }
        return StateChange(persistent: persistent, ephemeral: ephemeral)
    }
}

// MARK: - BitCraft sign-in mutations

extension Intent.ShowBitCraftSignIn: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        ephemeral.signInVisible = true
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.DismissBitCraftSignIn: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        // An in-flight code request or authentication is allowed to finish;
        // its feedback intents tolerate the screen being closed (an
        // authentication that completes while hidden still stores the
        // account — that is the user's signed-in outcome, not presentation).
        ephemeral.signInVisible = false
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.StartBitCraftSignIn: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Cheap local validation; the server is the authority.
        guard email.contains("@"), email.contains("."), !email.hasSuffix("."), !email.hasPrefix("@") else {
            var ephemeral = ephemeral
            ephemeral.signIn.error = "Enter a valid email address."
            return StateChange(ephemeral: ephemeral)
        }
        var ephemeral = ephemeral
        ephemeral.signIn = EphemeralState.SignInState(
            phase: .requestingCode(email: email), error: nil
        )
        return StateChange(ephemeral: ephemeral, activities: [Activity.RequestAccessCode(email: email)])
    }
}

extension Intent.AccessCodeRequested: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        // Only the newest request counts — a late reply from a superseded
        // email must not flip the phase back.
        guard case .requestingCode(email: let pending) = ephemeral.signIn.phase, pending == email else {
            return .noChange
        }
        ephemeral.signIn.phase = .awaitingCode(email: email)
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.AccessCodeRequestFailed: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard case .requestingCode = ephemeral.signIn.phase else { return .noChange }
        ephemeral.signIn.phase = .idle
        ephemeral.signIn.error = message
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.SubmitAccessCode: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard case .awaitingCode(email: let email) = ephemeral.signIn.phase, !code.isEmpty else {
            return .noChange
        }
        var ephemeral = ephemeral
        ephemeral.signIn.phase = .authenticating(email: email, code: code)
        ephemeral.signIn.error = nil
        return StateChange(ephemeral: ephemeral, activities: [Activity.Authenticate(email: email, code: code)])
    }
}

extension Intent.BitCraftAuthenticated: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var persistent = persistent
        var ephemeral = ephemeral
        guard case .authenticating = ephemeral.signIn.phase else { return .noChange }
        persistent.bitCraftAccount = account
        if ephemeral.accountDrivenSignIn {
            // The account is verified; locate its player before any session.
            // The screen stays up through the link (`linking` phase).
            ephemeral.signIn = EphemeralState.SignInState(phase: .linking(email: account.email))
            ephemeral.signInVisible = true
            return StateChange(
                persistent: persistent, ephemeral: ephemeral,
                activities: [Activity.LinkAccountPlayer(account: account)]
            )
        }
        ephemeral.signIn = EphemeralState.SignInState()
        ephemeral.signInVisible = false
        return StateChange(persistent: persistent, ephemeral: ephemeral)
    }
}

extension Intent.BitCraftAuthenticationFailed: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard case .authenticating(email: let pending, code: _) = ephemeral.signIn.phase, pending == email else {
            return .noChange
        }
        // Back to code entry — the user can retry the same email (codes are
        // short-lived; a stale one fails again with the server's message).
        ephemeral.signIn.phase = .awaitingCode(email: email)
        ephemeral.signIn.error = message
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.EditSignInEmail: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        switch ephemeral.signIn.phase {
        case .awaitingCode, .linking:
            break
        default:
            return .noChange
        }
        var persistent = persistent
        if case .linking = ephemeral.signIn.phase, ephemeral.accountDrivenSignIn {
            // Abandoning a verified account mid-link — forget it, so a
            // relaunch doesn't auto-resume a link the user rejected.
            persistent.bitCraftAccount = nil
        }
        ephemeral.signIn.phase = .idle
        ephemeral.signIn.error = nil
        return StateChange(persistent: persistent, ephemeral: ephemeral)
    }
}

// MARK: - Account link mutations (account-driven apps)

extension Intent.AccountPlayerLinked: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var persistent = persistent
        var ephemeral = ephemeral
        // Only the live link counts: the newest account wins, and a link
        // whose screen was left (sign-in closed, or the startup resume
        // gave way to something else) drops.
        guard ephemeral.accountDrivenSignIn,
              persistent.bitCraftAccount?.email == accountEmail,
              ephemeral.signInVisible || ephemeral.resumingAccount == accountEmail,
              case .linking(let pending) = ephemeral.signIn.phase, pending == accountEmail else {
            return .noChange
        }
        persistent.identity = StoredIdentity(
            entityID: player.entityID,
            username: player.username ?? player.entityID,
            regionID: player.regionID,
            resolvedAt: .now
        )
        ephemeral.signIn = EphemeralState.SignInState()
        ephemeral.signInVisible = false
        ephemeral.resumingAccount = nil
        let started = startSession(
            entityID: player.entityID,
            in: ephemeral
        )
        ephemeral.session = started.session
        // The link answers "who is this account" — the game session is a
        // separate, explicit step. Land on the pre-sign-in gate (character
        // card + presence), where Sign in / Take over session lives.
        ephemeral.preSignInVisible = true
        ephemeral.gameSessionNotice = nil
        return StateChange(
            persistent: persistent, ephemeral: ephemeral,
            activities: [Activity.LoadGamedata()] + started.activities
        )
    }
}

extension Intent.AccountPlayerLinkFailed: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard ephemeral.accountDrivenSignIn,
              persistent.bitCraftAccount?.email == accountEmail,
              ephemeral.signInVisible || ephemeral.resumingAccount == accountEmail,
              case .linking(let pending) = ephemeral.signIn.phase, pending == accountEmail else {
            return .noChange
        }
        // A failed startup resume falls back to the sign-in screen (the
        // account is verified, so its error + retry live on the linking
        // step); a link the user is watching fails in place.
        if ephemeral.resumingAccount == accountEmail {
            ephemeral.resumingAccount = nil
            ephemeral.preSignInVisible = false
            ephemeral.signInVisible = true
        }
        // Stay on the linking step with the error — the account is already
        // verified, so retrying needs no new code.
        ephemeral.signIn.error = message
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.RetryAccountLink: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard ephemeral.accountDrivenSignIn,
              let account = persistent.bitCraftAccount,
              persistent.identity == nil,
              case .linking(let pending) = ephemeral.signIn.phase, pending == account.email else {
            return .noChange
        }
        ephemeral.signIn.error = nil
        return StateChange(ephemeral: ephemeral, activities: [Activity.LinkAccountPlayer(account: account)])
    }
}

extension Intent.ForgetBitCraftAccount: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var persistent = persistent
        guard persistent.bitCraftAccount != nil else { return .noChange }
        persistent.bitCraftAccount = nil
        return StateChange(persistent: persistent)
    }
}

// MARK: - Craft-driver mutations (account-driven apps)

/// Builds the craft plan from the buildings state (recipe pacing/stamina
/// from the catalogs, speeds from the materialized stats) or explains why
/// the craft cannot be driven. Nil plan + nil failure = guards failed
/// silently (not a renderable craft, no session).
private func buildCraftPlan(
    craftEntityID: UInt64,
    session: EphemeralState.Session
) -> (plan: EphemeralState.Session.CraftPlan?, failure: String?) {
    guard let craft = session.buildings.crafts[craftEntityID],
          case .active(let progress, let craftCount, _, _) = craft.kind else {
        return (nil, nil) // not a renderable progressive craft
    }
    let gamedata = session.buildings.gamedata
    let recipeName = gamedata.recipeDisplayName(craft.recipeID)
    let actionsRequired = gamedata.recipeActionsRequired[craft.recipeID]
    let effortTotal = actionsRequired.map { Int($0) * Int(craftCount) } ?? 0
    if let actionsRequired, progress >= actionsRequired * craftCount {
        return (nil, nil) // already complete — the list stops rendering it
    }

    // Pacing: the server's own delay formula over the materialized stats
    // (`time_requirement / (CraftingSpeed + skill_speed − 1)`), with the
    // ≥95 % cadence-gate margin. A recipe the catalog can't pace is a
    // refusal, not a guess.
    guard let timeRequirement = gamedata.recipeTimeRequirement[craft.recipeID] else {
        return (nil, "Recipe pacing unknown — the catalog hasn't landed for it.")
    }
    let config = GameConfig.shared
    let speedStat = session.vitals.craftingSpeed ?? 1.0
    let skillID = gamedata.recipeSkills[craft.recipeID]
    let skillSpeedStat = skillID.flatMap { session.vitals.skillSpeed(skillID: $0) } ?? 1.0
    // The server's multiplier denominator (`event_delay`: CraftingSpeed +
    // skill_speed − 1); each speed defaults to 1.0 when the stats vector
    // hasn't landed (no stat ⇒ neutral, the module source's own fallback).
    let denominator = max(0.1, Double(speedStat + skillSpeedStat - 1.0))
    let delayMs = Double(timeRequirement) / denominator * 1_000 * config.craftDelayMargin
    let staminaPerAction = gamedata.recipeStaminaRequirement[craft.recipeID] ?? 0

    // Station stand-off: footprint radius +2 tiles guarantees ≤2 tiles
    // from every footprint tile (rotation-invariant metric). Interior
    // (enterable) stations are out of v1 scope.
    let buildingDescID = session.buildings.buildings[craft.buildingEntityID]?.buildingDescriptionID
    let desc = buildingDescID.flatMap { gamedata.buildings[$0] }
    if let desc, !desc.unenterable {
        return (nil, "Interior stations aren't supported yet — craft there in game.")
    }
    let standDistanceTiles = (desc?.footprintRadiusTiles ?? 0) + 2
    let walkSpeed = config.walkSpeedRawPerSec * Double(session.vitals.movementMultiplier ?? 1.0)

    let stationName = session.buildings.nicknames[craft.buildingEntityID]
        ?? desc?.name
        ?? session.buildings.buildings[craft.buildingEntityID].map { "Building \($0.entityID)" }

    let plan = EphemeralState.Session.CraftPlan(
        progressiveActionEntityID: craftEntityID,
        buildingEntityID: craft.buildingEntityID,
        recipeID: craft.recipeID,
        recipeName: recipeName,
        stationName: stationName,
        effortTotal: effortTotal,
        effortDone: Int(progress),
        staminaPerAction: staminaPerAction,
        delayMs: delayMs,
        standDistanceTiles: standDistanceTiles,
        walkSpeedRawPerSec: max(1_000, walkSpeed)
    )
    return (plan, nil)
}

extension Intent.TapCraft: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session,
              let leg = session.regionLeg,
              // A finished/failed banner must be dismissed before a new
              // drive; an active/paused drive is not replaceable either.
              session.driver.phase == .idle,
              let playerEntityID = UInt64(session.entityID) else {
            return .noChange
        }
        let built = buildCraftPlan(craftEntityID: craftEntityID, session: session)
        if let failure = built.failure {
            session.driver.phase = .failed(message: failure)
            session.driver.plan = nil
            ephemeral.session = session
            return StateChange(ephemeral: ephemeral)
        }
        guard let plan = built.plan else { return .noChange }
        session.driver.phase = .walking(stationName: plan.stationName)
        session.driver.plan = plan
        let driverLoop = CancellableTask()
        session.driverLoop = driverLoop
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral, activities: [
            Activity.CraftDriverLoop(
                leg: leg,
                playerEntityID: playerEntityID,
                plan: plan,
                cancellable: driverLoop
            )
        ])
    }
}

extension Intent.PauseCraftDriver: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        switch session.driver.phase {
        case .walking, .crafting:
            break
        default:
            return .noChange
        }
        session.driverLoop?.cancel()
        session.driverLoop = nil
        session.driver.phase = .paused(.byUser)
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.ResumeCraftDriver: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session,
              let leg = session.regionLeg,
              case .paused = session.driver.phase,
              let plan = session.driver.plan,
              session.driverLoop == nil,
              let playerEntityID = UInt64(session.entityID) else {
            return .noChange
        }
        session.driver.phase = .crafting
        let driverLoop = CancellableTask()
        session.driverLoop = driverLoop
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral, activities: [
            Activity.CraftDriverLoop(
                leg: leg,
                playerEntityID: playerEntityID,
                plan: plan,
                cancellable: driverLoop
            )
        ])
    }
}

extension Intent.StopCraftDriver: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        guard session.driver.phase != .idle else { return .noChange }
        let plan = session.driver.plan
        session.driverLoop?.cancel()
        session.driverLoop = nil
        session.driver = EphemeralState.Session.DriverState()
        ephemeral.session = session
        guard let plan, let leg = session.regionLeg else {
            return StateChange(ephemeral: ephemeral)
        }
        return StateChange(ephemeral: ephemeral, activities: [
            Activity.StopCraft(leg: leg, pocketID: plan.progressiveActionEntityID)
        ])
    }
}

extension Intent.DismissCraftBanner: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        switch session.driver.phase {
        case .completed, .failed:
            session.driver = EphemeralState.Session.DriverState()
        default:
            return .noChange
        }
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.DriverEvent: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session,
              session.driver.plan?.progressiveActionEntityID == craftEntityID else {
            return .noChange
        }
        switch outcome {
        case .crafting(let effortDone, let stamina):
            session.driver.phase = .crafting
            session.driver.plan?.effortDone = effortDone
            if let stamina {
                session.vitals.stamina = stamina
            }
        case .paused(let reason):
            session.driverLoop?.cancel()
            session.driverLoop = nil
            session.driver.phase = .paused(reason)
        case .completed(let effortDone):
            session.driverLoop?.cancel()
            session.driverLoop = nil
            session.driver.plan?.effortDone = effortDone
            session.driver.phase = .completed(recipeName: session.driver.plan?.recipeName)
        case .failed(let message):
            session.driverLoop?.cancel()
            session.driverLoop = nil
            session.driver.phase = .failed(message: message)
        }
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

// MARK: - App lifecycle mutations

extension Intent.AppBackgrounded: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session else { return .noChange }
        switch session.driver.phase {
        case .walking, .crafting:
            session.driverLoop?.cancel()
            session.driverLoop = nil
            session.driver.phase = .paused(.backgrounded)
        default:
            return .noChange
        }
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}

extension Intent.AppForegrounded: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session,
              let leg = session.regionLeg,
              case .paused(.backgrounded) = session.driver.phase,
              let plan = session.driver.plan,
              session.driverLoop == nil,
              let playerEntityID = UInt64(session.entityID) else {
            return .noChange
        }
        session.driver.phase = .crafting
        let driverLoop = CancellableTask()
        session.driverLoop = driverLoop
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral, activities: [
            Activity.CraftDriverLoop(
                leg: leg,
                playerEntityID: playerEntityID,
                plan: plan,
                cancellable: driverLoop
            )
        ])
    }
}

extension Intent.WalkOutcome: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var ephemeral = ephemeral
        guard var session = ephemeral.session,
              session.driver.plan?.progressiveActionEntityID == craftEntityID else {
            return .noChange
        }
        switch outcome {
        case .arrived(let x, let z):
            guard case .walking = session.driver.phase else { return .noChange }
            session.driver.phase = .crafting
            session.vitals.positionX = x
            session.vitals.positionZ = z
        case .failed(let message):
            session.driverLoop?.cancel()
            session.driverLoop = nil
            session.driver.phase = .failed(message: message)
        }
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
    }
}
