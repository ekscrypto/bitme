import Testing
import Foundation
@testable import BitMeCore

/// State machine flows driven through simulated adapters (fenex-light
/// ADR-002/003/008): no network, no real waiting — assertions observe the
/// published ViewRep stream, never machine internals (ADR-014).
@MainActor
struct StateMachineTests {

    /// Scripted relay: resolve answers in order; session snapshots answer in
    /// order, then keep returning the last one. Instant sleep.
    final class SimulatedRelay: @unchecked Sendable {
        let resolveResults: [ResolveOutcome]
        let snapshots: [SessionSnapshot]

        enum ResolveOutcome: Sendable {
            case found(ResolveResponse)
            case notFound
            case error
        }

        private let lock = NSLock()
        private var resolveIndex = 0
        private var snapshotIndex = 0

        init(resolveResults: [ResolveOutcome], snapshots: [SessionSnapshot] = []) {
            self.resolveResults = resolveResults
            self.snapshots = snapshots
        }

        var nextResolve: ResolveOutcome {
            lock.lock(); defer { lock.unlock() }
            defer { resolveIndex += 1 }
            return resolveIndex < resolveResults.count ? resolveResults[resolveIndex] : .notFound
        }

        var nextSnapshot: SessionSnapshot? {
            lock.lock(); defer { lock.unlock() }
            defer { snapshotIndex += 1 }
            return snapshotIndex < snapshots.count ? snapshots[snapshotIndex] : snapshots.last
        }
    }

    static let resolved = ResolveResponse(
        found: true,
        entityID: "1000",
        username: "Whisper",
        usernameLowercase: "whisper",
        identity: nil,
        regionID: 7,
        regionName: "Virexal",
        host: nil,
        module: nil,
        signedIn: true
    )

    static let nowMs: Int64 = 1_788_628_492_000

    static func snapshot(
        signedIn: Bool? = true,
        target: Target? = nil,
        stamina: Stamina? = nil,
        buffs: [Buff] = [],
        spawns: [ActivitySpawn] = []
    ) -> SessionSnapshot {
        SessionSnapshot(
            found: true,
            playerEntityID: "1000",
            username: "Whisper",
            signedIn: signedIn,
            region: 7,
            position: nil,
            claim: nil,
            stamina: stamina,
            buffs: buffs,
            actions: [],
            target: target,
            activitySpawns: spawns,
            serverTimeMs: nowMs
        )
    }

    // MARK: - Harness

    func makeMachine(
        relay: SimulatedRelay,
        identity: StoredIdentity? = nil,
        gamedata: FoodBuffGamedata? = FoodBuffGamedata(
            foodBuffIDs: [42], fetchedAt: .now
        )
    ) -> StateMachine {
        StateMachine(adapters: Adapters(
            relay: Adapters.Relay(
                resolve: { name in
                    switch relay.nextResolve {
                    case .found(let response): return response
                    case .notFound: throw RelayError.notFound
                    case .error: throw URLError(.badServerResponse)
                    }
                },
                session: { _ in
                    if let snapshot = relay.nextSnapshot { return snapshot }
                    throw URLError(.badServerResponse)
                }
            ),
            loadFoodBuffGamedata: { gamedata },
            restoreIdentity: { identity },
            persistIdentity: { _ in },
            sleep: { _ in } // instant — flows run at task speed
        ))
    }

    /// Lock-protected ViewRep collector — sink callbacks arrive off-main.
    final class RepCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var reps: [ViewRep] = []

        func append(_ rep: ViewRep) {
            lock.withLock { reps.append(rep) }
        }

        func contains(_ predicate: (ViewRep) -> Bool) -> Bool {
            lock.withLock { reps.contains(where: predicate) }
        }

        func last(where predicate: (ViewRep) -> Bool) -> ViewRep? {
            lock.withLock { reps.last(where: predicate) }
        }

        func first(where predicate: (ViewRep) -> Bool) -> ViewRep? {
            lock.withLock { reps.first(where: predicate) }
        }

        var count: Int { lock.withLock { reps.count } }
    }

    /// Collects ViewReps until `finished` matches, with a timeout backstop.
    /// `dispatch` runs after subscribing so no intermediate rep is missed
    /// (the broadcaster replays only the latest value).
    func collect(_ machine: StateMachine, dispatch: (@Sendable () async -> Void)? = nil,
                 until finished: @Sendable @escaping (ViewRep) -> Bool,
                 timeout: TimeInterval = 5) async -> RepCollector {
        let collector = RepCollector()
        let task = machine.viewRep.sink { rep in
            collector.append(rep)
        }
        await dispatch?()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if collector.contains(finished) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        return collector
    }

    // MARK: - Tests

    @Test func resolveNotFoundSurfacesError() async {
        let machine = makeMachine(relay: SimulatedRelay(
            resolveResults: [.notFound], snapshots: [Self.snapshot()]
        ))
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: {
            if case .onboarding(let o) = $0 { return o.error != nil }
            return false
        })
        let errorRep = reps.last { rep in
            if case .onboarding(let o) = rep { return o.error != nil }
            return false
        }
        guard case .onboarding(let onboarding)? = errorRep else {
            Issue.record("expected an onboarding error rep")
            return
        }
        #expect(onboarding.error?.contains("No character found") == true)
        // The resolving phase was published before the error.
        #expect(reps.contains { rep in
            if case .onboarding(let o) = rep { return o.isResolving }
            return false
        })
    }

    @Test func resolveSuccessStartsSessionAndPolls() async {
        let bush = Target(
            entityID: "5000", resourceID: 38, name: "Flint Pile",
            health: 2398, maxHealth: 10_000,
            despawnTimeSecs: nil, respawnTimeSecs: nil, location: nil
        )
        let machine = makeMachine(relay: SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(target: bush)]
        ))
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: { rep in
            if case .session(let s) = rep { return s.nowMs != nil && s.bush != nil }
            return false
        })
        guard case .session(let session)? = reps.last(where: {
            if case .session = $0 { return true }
            return false
        }) else {
            Issue.record("expected a session rep")
            return
        }
        #expect(session.username == "Whisper")
        #expect(session.entityID == "1000")
        #expect(session.connection == .ok)
        #expect(session.food.configured) // gamedata adapter supplied
        #expect(session.bush?.name == "Flint Pile")
        // Depletion anchor needs the learned pacing — nil on the first poll.
        #expect(session.bush?.depletesAtMs == nil)
        #expect(session.bush?.harvestedPct != nil)
    }

    @Test func restoredIdentitySkipsOnboarding() async {
        let identity = StoredIdentity(
            entityID: "1000", username: "Whisper", regionID: 7, resolvedAt: .distantPast
        )
        let machine = makeMachine(
            relay: SimulatedRelay(resolveResults: [], snapshots: [Self.snapshot()]),
            identity: identity
        )
        await machine.start()
        let reps = await collect(machine, until: { rep in
            if case .session(let s) = rep { return s.nowMs != nil }
            return false
        })
        // The bootstrap must transition straight into a session.
        guard case .session(let session)? = reps.last(where: {
            if case .session = $0 { return true }
            return false
        }) else {
            Issue.record("expected a session rep without resolving")
            return
        }
        #expect(session.username == "Whisper")
        #expect(reps.contains { rep in
            if case .onboarding(let o) = rep { return o.isResolving }
            return false
        } == false)
    }

    @Test func citricSpawnAppearsInViewRep() async {
        let citric = ActivitySpawn(
            entityID: "9000", resourceID: 1_688_062_540, name: "Citric Giant Strawberry Bush",
            health: nil, maxHealth: 500, location: nil,
            spawnedAtMs: Self.nowMs, expiresAtMs: Self.nowMs + 30_000
        )
        let machine = makeMachine(relay: SimulatedRelay(
            resolveResults: [.found(Self.resolved)],
            snapshots: [Self.snapshot(), Self.snapshot(spawns: [citric])]
        ))
        await machine.start()
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.ResolvePlayer(name: "whisper"))
        }, until: { rep in
            if case .session(let s) = rep { return s.citric != nil }
            return false
        })
        guard case .session(let session)? = reps.first(where: { rep in
            if case .session(let s) = rep { return s.citric != nil }
            return false
        }), let citricRep = session.citric else {
            Issue.record("expected a citric rep")
            return
        }
        #expect(citricRep.entityID == "9000")
        #expect(citricRep.isNewlySpawned == true)
    }

    @Test func signOutClearsIdentity() async {
        let identity = StoredIdentity(
            entityID: "1000", username: "Whisper", regionID: 7, resolvedAt: .distantPast
        )
        let machine = makeMachine(
            relay: SimulatedRelay(resolveResults: [], snapshots: [Self.snapshot()]),
            identity: identity
        )
        await machine.start()
        let live = await collect(machine, until: { rep in
            if case .session(let s) = rep { return s.nowMs != nil }
            return false
        })
        #expect(live.count > 0)
        await machine.ingest(Intent.SignOut())
        let after = await collect(machine, until: { rep in
            if case .onboarding = rep { return true }
            return false
        }, timeout: 2)
        #expect(after.contains { rep in
            if case .onboarding(let o) = rep { return !o.isResolving && o.error == nil }
            return false
        })
    }
}
