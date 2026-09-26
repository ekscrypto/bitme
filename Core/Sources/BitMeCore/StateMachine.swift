import Foundation
import os

/// The single source of truth (fenex-light ADR-001): a `final actor` owning
/// all `PersistentState` and `EphemeralState`, processing intents serially
/// (the actor's isolation is the guarantee — no locks), spawning activities
/// for async work, and publishing a derived `ViewRep` the UI subscribes to.
///
/// Internal state is not queryable (ADR-014): it is read only inside intent
/// mutations and `ViewRep.from`. Observers use `viewRep.values`.
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

    /// The UI subscribes here. `nonisolated` so callers can reach `.values`
    /// without an actor hop.
    public nonisolated let viewRep: ViewRepBroadcaster
    /// Tile-data channel for the hex-grid map renderer (`MapRep`) — the raw
    /// window/terrain/dictionary state, published only when it changes.
    /// Same `nonisolated` reasoning as `viewRep`.
    public nonisolated let mapRep: RepBroadcaster<MapRep>

    private let adapters: Adapters
    private var persistentState = PersistentState()
    private var ephemeralState = EphemeralState()
    private var started = false
    private var lastMapRep: MapRep = .empty

    public init(adapters: Adapters, configuration: Configuration = .standard) {
        self.adapters = adapters
        self.ephemeralState.resourceMapEnabled = configuration.resourceMapEnabled
        self.ephemeralState.accountDrivenSignIn = configuration.accountDrivenSignIn
        // Bootstrap rep: the first frame an app renders. Account-driven apps
        // open on email entry; a restored account/character takes over on
        // bootstrap (or the link resumes) within a frame or two.
        self.viewRep = ViewRepBroadcaster(initial: configuration.accountDrivenSignIn
            ? .bitCraftSignIn(ViewRep.BitCraftSignIn(phase: .idle, error: nil, canDismiss: false))
            : .onboarding(ViewRep.Onboarding(
                isResolving: false, lookingUpName: nil, error: nil, resolvedOfflineHint: false
              )))
        self.mapRep = RepBroadcaster<MapRep>(initial: .empty)
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
        await viewRep.send(ViewRep.from(persistent: persistentState, ephemeral: ephemeralState))
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
}

/// Activities that carry a `CancellableTask` box the machine stamps with the
/// spawned task (fenex-light `CancellableAsyncActivity`). The box is created
/// by the mutate that starts the activity and stored in state, so later
/// intents (e.g. `Intent.SignOut`) can cancel the loop.
protocol StampableActivity: AsyncActivity {
    var stampTarget: CancellableTask { get }
}
