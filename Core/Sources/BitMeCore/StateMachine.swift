import Foundation
import os

/// The single source of truth (fenex-light ADR-001): a `final actor` owning
/// all `PersistentState` and `EphemeralState`, processing intents serially
/// (the actor's isolation is the guarantee — no locks), spawning activities
/// for async work, and publishing the derived screen rep the UI subscribes
/// to: `viewRep` (name-driven — X-Ray, the CLI) or `crafterRep`
/// (account-driven — Pocket Crafter), chosen by configuration.
///
/// Internal state is not queryable (ADR-014): it is read only inside intent
/// mutations and the rep projections. Observers use the channel's `.values`.
public final actor StateMachine: IntentIngestor {
    /// Optional subsystems an app host turns on or off at construction.
    /// Seeded into ephemeral state once; intents gate their activity spawns
    /// on it (the machine never re-reads the struct afterwards).
    public struct Configuration: Sendable {
        /// The resource-map stack: BMR1 window fetches, terrain, dictionary,
        /// and the change-stream websocket. Apps that never render the hex
        /// map (Pocket Crafter) disable it to skip the traffic entirely.
        public var resourceMapEnabled: Bool
        /// The account-driven sign-in model: the emailed-code screen is the
        /// app's root, and every resolved character comes from the signed-in
        /// account's own identity (never a typed name). Pocket Crafter uses
        /// it; X-Ray and the CLI resolve by character name instead.
        public var accountDrivenSignIn: Bool

        public static let standard = Configuration(resourceMapEnabled: true)

        public init(resourceMapEnabled: Bool, accountDrivenSignIn: Bool = false) {
            self.resourceMapEnabled = resourceMapEnabled
            self.accountDrivenSignIn = accountDrivenSignIn
        }
    }

    /// The screen channel name-driven hosts (X-Ray, the CLI) subscribe to.
    /// `nonisolated` so callers can reach `.values` without an actor hop.
    public nonisolated let viewRep: ViewRepBroadcaster
    /// The screen channel for the account-driven host (Pocket Crafter) —
    /// same broadcaster, its own projection (`CrafterRep`). Exactly one of
    /// the two screen channels is ever published: the configuration picks
    /// it at construction, and the other keeps its bootstrap rep forever.
    public nonisolated let crafterRep: CrafterRepBroadcaster
    /// Tile-data channel for the hex-grid map renderer (`MapRep`) — the raw
    /// window/terrain/dictionary state, published only when it changes.
    /// Same `nonisolated` reasoning as `viewRep`.
    public nonisolated let mapRep: RepBroadcaster<MapRep>
    /// Claim-buildings channel (`WorkstationsRep`) — the workstations join,
    /// published only when the buildings state moves (the `mapRep`
    /// precedent): stamina ticks and poll-only ingests neither re-run the
    /// join nor rebroadcast it. Account-driven hosts render this channel
    /// directly — the session rep does not carry a copy.
    public nonisolated let workstationsRep: RepBroadcaster<WorkstationsRep>

    private let adapters: Adapters
    private var persistentState = PersistentState()
    private var ephemeralState = EphemeralState()
    private var started = false
    private var lastMapRep: MapRep = .empty
    /// The cached workstations projection and the buildings-state version it
    /// was computed from (see `ingest`).
    private var lastWorkstationsRep: WorkstationsRep = .empty
    private var lastWorkstationsVersion = 0
    /// Opt-in ingest diagnostics (off by default) — see `setIngestTracer`.
    private var ingestTracer: (@Sendable (String) -> Void)?

    public init(adapters: Adapters, configuration: Configuration = .standard) {
        self.adapters = adapters
        self.ephemeralState.resourceMapEnabled = configuration.resourceMapEnabled
        self.ephemeralState.accountDrivenSignIn = configuration.accountDrivenSignIn
        // Bootstrap reps: the first frame an app renders. Name-driven
        // hosts open on name entry; account-driven hosts on email entry
        // (a restored account/character takes over on bootstrap — or the
        // link resumes — within a frame or two). The channel the other
        // flow would use keeps its bootstrap rep; it is never published.
        self.viewRep = ViewRepBroadcaster(initial: .onboarding(ViewRep.Onboarding(
            isResolving: false, lookingUpName: nil, error: nil, resolvedOfflineHint: false
        )))
        self.crafterRep = CrafterRepBroadcaster(initial: .signIn(BitCraftSignIn(
            phase: .idle, error: nil, canDismiss: false
        )))
        self.mapRep = RepBroadcaster<MapRep>(initial: .empty)
        self.workstationsRep = RepBroadcaster<WorkstationsRep>(initial: .empty)
    }

    /// Idempotent bootstrap: restore persisted identity, then load gamedata
    /// and (if a character is known) start the session loop.
    public func start() async {
        guard !started else { return }
        started = true
        await runActivities([Activity.Bootstrap()])
    }

    /// Serial entry point for user actions and activity feedback.
    public func ingest(_ intent: Sendable) async {
        guard let mutator = intent as? StateMutator else {
            coreLog.error("intent is not a StateMutator: \(String(describing: type(of: intent)), privacy: .public)")
            return
        }
        let change = mutator.mutate(persistent: persistentState, ephemeral: ephemeralState)
        // Apply before the first await: the actor is reentrant across await
        // points, and a change held across the persistence adapters would be
        // a stale snapshot that clobbers whatever an interleaved ingest
        // applied in the meantime (bootstrap racing a sign-in submission).
        let mutatesPersistentState = change.persistentState != nil
        if let persistent = change.persistentState {
            persistentState = persistent
        }
        if let ephemeral = change.ephemeralState {
            ephemeralState = ephemeral
        }
        // Fired before the rep broadcast so the line names exactly the state
        // the next `ViewRep` projects (see `setIngestTracer`).
        if let tracer = ingestTracer {
            let summary = Self.traceSummary(
                persistent: persistentState, ephemeral: ephemeralState,
                activityCount: change.activities.count
            )
            tracer("\(String(describing: type(of: mutator))) → \(summary)")
        }
        // The workstations join (a busy claim's buildings + capped crafts,
        // sorted) re-runs only when the buildings-state version moved — a
        // pooled-events ingest, a leg reset, or teardown. Everything else
        // (polls, stamina, stream ticks) reuses the cached projection for
        // the workstations channel. (Name-driven machines never move the
        // buildings state — no game session, no region leg — so the join
        // never runs for them.)
        let workstations: WorkstationsRep
        if let session = ephemeralState.session, session.buildings.version != lastWorkstationsVersion {
            lastWorkstationsVersion = session.buildings.version
            workstations = WorkstationsRep.from(session: session)
        } else if ephemeralState.session == nil {
            workstations = .empty
        } else {
            workstations = lastWorkstationsRep
        }
        // The configuration picks the screen channel: the account-driven
        // projection for Pocket Crafter, the name-driven one for X-Ray and
        // the CLI. The unpublished channel keeps its bootstrap rep.
        if ephemeralState.accountDrivenSignIn {
            await crafterRep.send(CrafterRep.from(
                persistent: persistentState, ephemeral: ephemeralState
            ))
        } else {
            await viewRep.send(ViewRep.from(
                persistent: persistentState, ephemeral: ephemeralState
            ))
        }
        if workstations != lastWorkstationsRep {
            lastWorkstationsRep = workstations
            await workstationsRep.send(workstations)
        }
        if mutatesPersistentState {
            await adapters.persistIdentity(persistentState.identity)
            await adapters.persistBitCraftAccount(persistentState.bitCraftAccount)
        }
        let map = MapRep.from(ephemeral: ephemeralState)
        if map != lastMapRep {
            // Equality on 160k words is a memcmp — cheap next to a poll.
            lastMapRep = map
            await mapRep.send(map)
        }
        await runActivities(change.activities)
    }

    private func runActivities(_ activities: [any AsyncActivity]) async {
        for activity in activities {
            let task = Task {
                await activity.start(ingestor: self, adapters: adapters)
            }
            if let stampable = activity as? any StampableActivity {
                stampable.stampTarget.task = task
            }
        }
    }

    // MARK: - Ingest trace (opt-in diagnostics)

    /// Installs (or removes) the ingest tracer: every intent then passes one
    /// line to the hook — the intent's type name plus a one-line summary of
    /// the state its mutation produced. The line fires after state
    /// application and before the rep broadcast, so it describes exactly
    /// what the UI is about to be told. Mutators stay pure (no logging, no
    /// clocks — the machine is the logging layer); the summary reads only
    /// applied state. Off by default.
    public func setIngestTracer(_ tracer: (@Sendable (String) -> Void)?) {
        ingestTracer = tracer
    }

    /// Routes the ingest trace to `coreLog` at debug level (the built-in
    /// hook — hosts call this to turn live diagnostics on).
    public func setIngestTracing(_ enabled: Bool) {
        if enabled {
            ingestTracer = { line in coreLog.debug("\(line, privacy: .public)") }
        } else {
            ingestTracer = nil
        }
    }

    /// The trace's one-line state summary. Deliberately broad rather than
    /// intent-specific: the incidents it exists to make visible (the silent
    /// sign-in hang, the empty-workstations report) needed different slices,
    /// so every line carries the screen, the game session, the
    /// claim-buildings sync, and the map stream. Buildings counts are raw
    /// state (completed passive crafts included) — the projection's
    /// filtered/capped view is the ViewRep's business.
    nonisolated static func traceSummary(
        persistent: PersistentState,
        ephemeral: EphemeralState,
        activityCount: Int
    ) -> String {
        var parts: [String]
        if ephemeral.signInVisible || (ephemeral.accountDrivenSignIn && persistent.identity == nil) {
            parts = ["screen=signin", "phase=\(name(ephemeral.signIn.phase))"]
            if let error = ephemeral.signIn.error { parts.append("error=\(quoted(error))") }
        } else if persistent.identity == nil {
            var onboardingPhase = "idle"
            if case .resolving = ephemeral.onboarding { onboardingPhase = "resolving" }
            parts = ["screen=onboarding", "phase=\(onboardingPhase)"]
            if let error = ephemeral.resolveError { parts.append("error=\(quoted(error))") }
        } else if ephemeral.accountDrivenSignIn, ephemeral.preSignInVisible {
            parts = ["screen=gate"]
            if let notice = ephemeral.gameSessionNotice { parts.append("notice=\(quoted(notice))") }
        } else if let session = ephemeral.session {
            parts = ["screen=session", "conn=\(name(session.connection))"]
            parts.append("game=\(name(session.gameSession.status))")
            if let error = session.gameSession.lastError { parts.append("gameError=\(quoted(error))") }
            parts.append("snap=\(session.snapshot == nil ? "none" : "yes")")
            let buildings = session.buildings
            parts.append("wks=\(name(buildings.status))")
            if let error = buildings.lastError { parts.append("wksError=\(quoted(error))") }
            if buildings.status != .idle {
                parts.append("claim=\(quoted(buildings.claim?.name ?? "?"))")
                parts.append("b=\(buildings.buildings.count)")
                parts.append("c=\(buildings.crafts.count)")
                parts.append("descs=\(buildings.gamedata.buildings.count)")
                parts.append("recipes=\(buildings.gamedata.recipeNames.count)")
                // The classification split — the empty-workstations
                // forensics hinge: b>0 with wkCraft=0 wkStore=0 means the
                // catalogs never landed (descs=0) or the rows all fell to
                // the unclassified bucket, not "no rows arrived".
                var wkCraft = 0
                var wkStore = 0
                for building in buildings.buildings.values {
                    let desc = buildings.gamedata.buildings[building.buildingDescriptionID]
                    if desc?.isCrafting == true { wkCraft += 1 }
                    if desc?.isStorage == true { wkStore += 1 }
                }
                parts.append("wkCraft=\(wkCraft)")
                parts.append("wkStore=\(wkStore)")
            }
            parts.append("map=\(name(session.resourceMap.streamStatus))")
        } else {
            parts = ["screen=idle"]
        }
        if activityCount > 0 { parts.append("acts=\(activityCount)") }
        return parts.joined(separator: " ")
    }

    private nonisolated static func quoted(_ text: String) -> String { "\"\(text)\"" }

    private nonisolated static func name(_ phase: EphemeralState.SignInState.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .requestingCode: "requestingCode"
        case .awaitingCode: "awaitingCode"
        case .authenticating: "authenticating"
        case .linking: "linking"
        }
    }

    private nonisolated static func name(_ connection: EphemeralState.Session.Connection) -> String {
        switch connection {
        case .ok: "ok"
        case .degraded: "degraded"
        case .down: "down"
        }
    }

    private nonisolated static func name(_ status: EphemeralState.Session.GameSessionState.Status) -> String {
        switch status {
        case .connecting: "connecting"
        case .live: "live"
        case .reconnecting: "reconnecting"
        case .rejected: "rejected"
        }
    }

    private nonisolated static func name(_ status: EphemeralState.Session.BuildingsState.Status) -> String {
        switch status {
        case .idle: "idle"
        case .syncing: "syncing"
        case .live: "live"
        case .failed: "failed"
        }
    }

    private nonisolated static func name(_ status: EphemeralState.Session.ResourceMapState.StreamStatus) -> String {
        switch status {
        case .off: "off"
        case .connecting: "connecting"
        case .live: "live"
        case .reconnecting: "reconnecting"
        }
    }
}

/// Activities that carry a `CancellableTask` box the machine stamps with the
/// spawned task (fenex-light `CancellableAsyncActivity`). The box is created
/// by the mutate that starts the activity and stored in state, so later
/// intents (e.g. `Intent.SignOut`) can cancel the loop.
protocol StampableActivity: AsyncActivity {
    var stampTarget: CancellableTask { get }
}
