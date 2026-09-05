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
    /// The UI subscribes here. `nonisolated` so callers can reach `.values`
    /// without an actor hop.
    public nonisolated let viewRep: ViewRepBroadcaster

    private let adapters: Adapters
    private var persistentState = PersistentState()
    private var ephemeralState = EphemeralState()
    private var started = false

    public init(adapters: Adapters) {
        self.adapters = adapters
        self.viewRep = ViewRepBroadcaster(initial: .onboarding(ViewRep.Onboarding(
            isResolving: false, lookingUpName: nil, error: nil, resolvedOfflineHint: false
        )))
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
        if let persistent = change.persistentState {
            persistentState = persistent
            await adapters.persistIdentity(persistent.identity)
        }
        if let ephemeral = change.ephemeralState {
            ephemeralState = ephemeral
        }
        await viewRep.send(ViewRep.from(persistent: persistentState, ephemeral: ephemeralState))
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
