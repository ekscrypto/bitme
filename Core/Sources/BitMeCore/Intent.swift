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
}

// MARK: - Internal feedback intents (activities → machine)

extension Intent {
    /// Bootstrap activity finished restoring persisted identity.
    struct BootstrapCompleted: Sendable {
        let identity: StoredIdentity?
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

        var activities: [any AsyncActivity] = [Activity.LoadGamedata()]
        if ephemeral.session == nil {
            let loop = CancellableTask()
            ephemeral.session = EphemeralState.Session(entityID: response.entityID, loop: loop)
            activities.append(Activity.SessionLoop(
                entityID: response.entityID,
                carrier: ephemeral.session!.carrier,
                cancellable: loop
            ))
        }
        return StateChange(persistent: persistent, ephemeral: ephemeral, activities: activities)
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
        persistent.identity = identity
        var ephemeral = ephemeral
        var activities: [any AsyncActivity] = [Activity.LoadGamedata()]
        if let identity, ephemeral.session == nil {
            let loop = CancellableTask()
            ephemeral.session = EphemeralState.Session(entityID: identity.entityID, loop: loop)
            activities.append(Activity.SessionLoop(
                entityID: identity.entityID,
                carrier: ephemeral.session!.carrier,
                cancellable: loop
            ))
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
        ephemeral.session = session
        return StateChange(ephemeral: ephemeral)
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

extension Intent.SignOut: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var persistent = persistent
        var ephemeral = ephemeral
        ephemeral.session?.loop.cancel()
        ephemeral.session = nil
        persistent.identity = nil
        return StateChange(persistent: persistent, ephemeral: ephemeral)
    }
}
