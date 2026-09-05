import Foundation

/// A serial mutation unit processed by `StateMachine`. Every concrete
/// `Intent.*` conforms. `mutate(persistent:ephemeral:)` is a pure function
/// over its inputs: no I/O, no task spawning, no clock reads — build new
/// state and/or activities and return them in a `StateChange`.
/// (fenex-light ADR-001/ADR-014.)
protocol StateMutator: Sendable {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange
}

/// Receives intents from UI actions or asynchronous activities. Production
/// implementation is the `StateMachine`; tests may substitute a stub.
protocol IntentIngestor: Sendable {
    func ingest(_ intent: Sendable) async
}

/// The result of an `Intent` mutation: optionally new state on either side
/// (nil = unchanged — the machine skips persistence/broadcast for it), plus
/// zero or more activities for the machine to spawn.
struct StateChange {
    var persistentState: PersistentState?
    var ephemeralState: EphemeralState?
    var activities: [any AsyncActivity]

    static var noChange: StateChange { StateChange() }

    init(
        persistent persistentState: PersistentState? = nil,
        ephemeral ephemeralState: EphemeralState? = nil,
        activities: [any AsyncActivity] = []
    ) {
        self.persistentState = persistentState
        self.ephemeralState = ephemeralState
        self.activities = activities
    }
}

/// A unit of async work spawned by the state machine after an intent's
/// `mutate` returns it. Does the real I/O (relay HTTP, mirror WebSocket)
/// and feeds results back by ingesting more intents.
protocol AsyncActivity: Sendable {
    func start(ingestor: IntentIngestor, adapters: Adapters) async
}
