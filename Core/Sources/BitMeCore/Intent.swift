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
        if ephemeral.session?.entityID != response.entityID {
            // A stale session for a *different* character can be running when
            // a late bootstrap raced this resolve (the CLI's start → SignOut
            // → resolve sequence) — retire its loops before starting fresh.
            ephemeral.session?.loop.cancel()
            ephemeral.session?.streamLoop?.cancel()
            let loop = CancellableTask()
            let streamLoop = CancellableTask()
            ephemeral.session = EphemeralState.Session(
                entityID: response.entityID, loop: loop, streamLoop: streamLoop
            )
            activities.append(Activity.SessionLoop(
                entityID: response.entityID,
                carrier: ephemeral.session!.carrier,
                cancellable: loop
            ))
            activities.append(Activity.ResourceStreamLoop(
                entityID: response.entityID,
                carrier: ephemeral.session!.streamCarrier,
                cancellable: streamLoop
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
        var ephemeral = ephemeral
        var activities: [any AsyncActivity] = [Activity.LoadGamedata()]
        // Restore only when nothing newer is in flight or landed: a late
        // bootstrap (its restore raced a SignOut + resolve) must not
        // resurrect the previous character or clobber the new session.
        if let identity, ephemeral.session == nil,
           case .idle = ephemeral.onboarding {
            persistent.identity = identity
            let loop = CancellableTask()
            let streamLoop = CancellableTask()
            ephemeral.session = EphemeralState.Session(
                entityID: identity.entityID, loop: loop, streamLoop: streamLoop
            )
            activities.append(Activity.SessionLoop(
                entityID: identity.entityID,
                carrier: ephemeral.session!.carrier,
                cancellable: loop
            ))
            activities.append(Activity.ResourceStreamLoop(
                entityID: identity.entityID,
                carrier: ephemeral.session!.streamCarrier,
                cancellable: streamLoop
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
        session.lastPolledLocalMs = polledAtMs

        // Resource map: fetch a window while the player is live in the
        // overworld (deltas then keep it fresh; this is also the recovery
        // move), and gate the change stream on the same liveness.
        let config = GameConfig.shared
        let live = snapshot.signedIn != false && (snapshot.position?.dimension ?? 1) == 1
        session.streamCarrier.wanted = live
        var activities: [any AsyncActivity] = []
        if live {
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

extension Intent.SignOut: StateMutator {
    func mutate(persistent: PersistentState, ephemeral: EphemeralState) -> StateChange {
        var persistent = persistent
        var ephemeral = ephemeral
        ephemeral.session?.loop.cancel()
        ephemeral.session?.streamLoop?.cancel()
        ephemeral.session = nil
        persistent.identity = nil
        return StateChange(persistent: persistent, ephemeral: ephemeral)
    }
}
