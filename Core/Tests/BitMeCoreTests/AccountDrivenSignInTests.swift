import Testing
import Foundation
@testable import BitMeCore

/// The account-driven sign-in model (Pocket Crafter's configuration): the
/// emailed-code screen is the app's root, and the tracked character is the
/// signed-in account's own player, located over the game's global database.
/// The only valid flow is email → access code → session → sign out — no
/// character-name onboarding exists in this mode.
@Suite(.serialized) // staged collects share the main actor; no self-contention
@MainActor
struct AccountDrivenSignInTests {

    nonisolated static let identityHex = "c200cbb8c1ae61237b879e0fa0bf9cd64f9174beb983ab61c88cbacff6f4d1bb"

    /// A three-part token whose payload carries `hex_identity` — enough for
    /// `BitCraftAccount` to decode the identity locally.
    nonisolated static func token(hexIdentity: String = identityHex) -> String {
        let payload = #"{"hex_identity":"\#(hexIdentity)","sub":"test-sub"}"#
        var base64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while base64.count % 4 != 0 { base64 += "=" }
        return "h.\(base64).s"
    }

    nonisolated static let player = AccountPlayer(entityID: "1000", username: "Maplesugar", regionID: 14)

    nonisolated static let nowMs: Int64 = 1_788_628_492_000

    nonisolated static var snapshot: SessionSnapshot {
        makeSnapshot(claim: Claim(entityID: "2000", name: "Emberfall", ownerPlayerEntityID: "1000", neutral: false))
    }

    /// The fixture snapshot with a swappable claim — `nil` stands the
    /// character outside every claim.
    nonisolated static func makeSnapshot(claim: Claim?) -> SessionSnapshot {
        SessionSnapshot(
            found: true, playerEntityID: "1000", username: "Maplesugar",
            signedIn: true, region: 14,
            position: Position(
                worldX: 11173.25, worldZ: 13848.5,
                tileX: 11173, tileZ: 13848,
                destinationWorldX: 0, destinationWorldZ: 0,
                dimension: 1, isWalking: false, timestampMs: nowMs - 500, ageMs: 500
            ),
            claim: claim, stamina: nil, buffs: [], actions: [], target: nil,
            activitySpawns: [], serverTimeMs: nowMs
        )
    }

    /// Scripted global-directory lookup: records the identities it was asked
    /// about and answers with a scripted outcome.
    final class SimulatedLink: @unchecked Sendable {
        enum Outcome: Sendable {
            case player(AccountPlayer)
            case noPlayer
            case unreachable
        }

        private let lock = NSLock()
        private var _outcome: Outcome
        private var _askedIdentities: [String] = []

        init(outcome: Outcome) {
            self._outcome = outcome
        }

        var outcome: Outcome {
            get { lock.withLock { _outcome } }
            set { lock.withLock { _outcome = newValue } }
        }

        var askedIdentities: [String] {
            lock.withLock { _askedIdentities }
        }

        func resolve(token: String, identityHex: String) async throws -> AccountPlayer {
            lock.withLock { _askedIdentities.append(identityHex) }
            switch outcome {
            case .player(let player): return player
            case .noPlayer: throw GlobalPlayerResolver.Error.noPlayer
            case .unreachable: throw URLError(.notConnectedToInternet)
            }
        }
    }

    /// Lock-protected persistence recorder — persist callbacks arrive on the
    /// serial actor off-main.
    final class AccountStore: @unchecked Sendable {
        private let lock = NSLock()
        private var _saved: [BitCraftAccount?] = []

        func record(_ account: BitCraftAccount?) {
            lock.withLock { _saved.append(account) }
        }

        var last: BitCraftAccount?? { lock.withLock { _saved.last } }
    }

    /// Lock-protected swap-in snapshot source — lets a test move the
    /// character (here, in and out of claims) between polls.
    final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _snapshot: SessionSnapshot

        init(_ snapshot: SessionSnapshot) { self._snapshot = snapshot }

        var snapshot: SessionSnapshot {
            get { lock.withLock { _snapshot } }
            set { lock.withLock { _snapshot = newValue } }
        }
    }

    /// Scripted game-session socket (the `sign_in` connection to the game's
    /// global database): records the credentials of every connection and
    /// answers each from a queued script — the events to deliver, and
    /// whether the connection then holds open (a healthy held session) or
    /// ends (drives the loop's reconnect). Connections beyond the script
    /// queue hold an established session, like a healthy production run.
    final class SimulatedGlobalSession: @unchecked Sendable {
        struct Connection: Equatable {
            let token: String
            let entityID: String
            let regionID: Int?
        }

        struct Script: Sendable {
            let events: [GlobalSessionEvent]
            let hold: Bool

            static let established = Script(events: [.established], hold: true)
        }

        private let lock = NSLock()
        private var _connections: [Connection] = []
        private var _scripts: [Script]
        private var _terminated = 0
        private var _held: [AsyncStream<GlobalSessionEvent>.Continuation] = []

        init(scripts: [Script]) {
            self._scripts = scripts
        }

        var connections: [Connection] { lock.withLock { _connections } }
        /// Connections whose stream terminated (loop cancellation or close).
        var terminated: Int { lock.withLock { _terminated } }

        /// Ends every held-open connection — what the server does to this
        /// app's socket when another client signs the account in.
        /// The continuations finish outside the lock: `finish()` runs the
        /// stream's onTermination inline, and that handler takes the same
        /// (non-reentrant) lock.
        func endHeld() {
            let held = lock.withLock {
                let copy = _held
                _held.removeAll()
                return copy
            }
            held.forEach { $0.finish() }
        }

        func open(token: String, entityID: String, regionID: Int?) -> AsyncStream<GlobalSessionEvent> {
            let script = lock.withLock {
                _connections.append(Connection(token: token, entityID: entityID, regionID: regionID))
                return _scripts.isEmpty ? Script.established : _scripts.removeFirst()
            }
            return AsyncStream { continuation in
                for event in script.events {
                    continuation.yield(event)
                }
                if script.hold {
                    lock.withLock { _held.append(continuation) }
                } else {
                    continuation.finish()
                }
                continuation.onTermination = { [self] _ in
                    lock.withLock { _terminated += 1 }
                }
            }
        }
    }

    // MARK: - Harness

    func makeMachine(
        link: SimulatedLink,
        globalSession: SimulatedGlobalSession = SimulatedGlobalSession(scripts: [.established]),
        claimBuildings: SimulatedClaimBuildings = SimulatedClaimBuildings(),
        restoredAccount: BitCraftAccount? = nil,
        restoredIdentity: StoredIdentity? = nil,
        accountStore: AccountStore? = nil,
        // What the relay's session poll answers; throwing models a poll
        // that has not landed an answer yet.
        sessionSnapshot: @escaping @Sendable () throws -> SessionSnapshot = {
            AccountDrivenSignInTests.snapshot
        }
    ) -> StateMachine {
        StateMachine(adapters: Adapters(
            relay: Adapters.Relay(
                resolve: { _ in throw RelayError.notFound }, // never used in this mode
                session: { _ in try sessionSnapshot() },
                sessionResources: { _ in throw RelayError.notFound },
                resourceDictionary: { _ in throw RelayError.notFound },
                worldElevation: { _, _ in throw RelayError.notFound },
                openResourceStream: { _ in AsyncStream { _ in } } // parked
            ),
            bitCraft: Adapters.BitCraft(
                requestAccessCode: { _ in },
                authenticate: { _, _ in Self.token() },
                resolveAccountPlayer: { token, identityHex in
                    try await link.resolve(token: token, identityHex: identityHex)
                },
                openGlobalSession: { token, entityID, regionID in
                    globalSession.open(token: token, entityID: entityID, regionID: regionID)
                },
                syncClaimBuildings: { leg, claim, player in
                    claimBuildings.open(leg: leg, claim: claim, player: player)
                }
            ),
            loadFoodBuffGamedata: { nil },
            restoreIdentity: { restoredIdentity },
            persistIdentity: { _ in },
            restoreBitCraftAccount: { restoredAccount },
            persistBitCraftAccount: { accountStore?.record($0) },
            // Real (tiny) sleeps — these tests reach the session loop, and
            // the instant no-op sleep turns its 1 Hz poll into a hot spin
            // that starves the machine and rep broadcaster.
            sleep: { _ in try await Task.sleep(for: .milliseconds(2)) }
        ), configuration: StateMachine.Configuration(
            resourceMapEnabled: false, accountDrivenSignIn: true
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

        var lastRep: ViewRep? {
            lock.withLock { reps.last }
        }


    }

    /// Collects ViewReps until `finished` matches, with a timeout backstop.
    private func collect(
        _ machine: StateMachine,
        dispatch: (@Sendable () async -> Void)? = nil,
        until finished: @Sendable @escaping (ViewRep) -> Bool,
        // Full-suite parallelism can starve the staged waits past the 5 s
        // default (same as StateMachineTests' replacement-session test);
        // solo, every flow here finishes in milliseconds.
        timeout: TimeInterval = 20
    ) async -> RepCollector {
        let collector = RepCollector()
        let task = machine.viewRep.sink { collector.append($0) }
        await dispatch?()
        // Poll off the main actor — under full-suite load the main actor's
        // queue can starve a Task.sleep-based loop past any deadline.
        await Task.detached(priority: .high) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if collector.contains(finished) { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }.value
        task.cancel()
        return collector
    }

    // MARK: - Tests

    /// The machine's very first rep is email entry — the character-name
    /// onboarding screen is never projected in this mode.
    @Test func initialRepIsEmailEntry() async {
        let machine = makeMachine(link: SimulatedLink(outcome: .player(Self.player)))
        let reps = await collect(machine, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep else { return false }
            return signIn.phase == .idle
        })
        #expect(reps.contains { rep in
            if case .onboarding = rep { return true }
            return false
        } == false)
        guard case .bitCraftSignIn(let signIn)? = reps.lastRep else {
            Issue.record("expected the email sign-in rep")
            return
        }
        #expect(signIn.canDismiss == false)
        #expect(signIn.error == nil)
    }

    /// email → access code → link lands on the pre-sign-in gate with the
    /// character card (name, N/E, claim, presence), and the gate's action
    /// enters the held session.
    @Test func emailCodeLinkFlowsIntoTheGateThenTheSession() async {
        let link = SimulatedLink(outcome: .player(Self.player))
        let machine = makeMachine(link: link)
        await machine.start()

        await collect(machine, dispatch: {
            await machine.ingest(Intent.StartBitCraftSignIn(email: " Maplesugar@Gmail.com "))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .awaitingCode(let email) = signIn.phase else { return false }
            return email == "maplesugar@gmail.com"
        })

        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.SubmitAccessCode(code: "GOOD12"))
        }, until: { rep in
            guard case .gameSessionPrompt(let prompt) = rep else { return false }
            return prompt.signedInElsewhere != nil // first poll landed
        })
        // The linking step was published between authentication and the gate.
        #expect(reps.contains { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .linking(let email) = signIn.phase else { return false }
            return email == "maplesugar@gmail.com" && signIn.error == nil
        })
        guard case .gameSessionPrompt(let prompt)? = reps.last(where: { rep in
            if case .gameSessionPrompt = rep { return true }
            return false
        }) else {
            Issue.record("expected the pre-sign-in gate rep")
            return
        }
        #expect(prompt.username == "Maplesugar")
        #expect(prompt.entityID == "1000")
        #expect(prompt.region == 14)
        #expect(prompt.bitCraftAccountEmail == "maplesugar@gmail.com")
        // Super-hex N/E of the fixture's position (tile 11173, 13848).
        #expect(prompt.north == 4616)
        #expect(prompt.east == 3724)
        #expect(prompt.claimName == "Emberfall")
        #expect(prompt.signedInElsewhere == true) // the relay sees a session elsewhere
        #expect(link.askedIdentities == [Self.identityHex])

        // The action takes the session and shows the home view.
        let signedIn = await collect(machine, dispatch: {
            await machine.ingest(Intent.SignInGameSession())
        }, until: { rep in
            guard case .session(let session) = rep else { return false }
            return session.gameSession?.status == .live
        })
        guard case .session(let session)? = signedIn.last(where: { rep in
            if case .session = rep { return true }
            return false
        }) else {
            Issue.record("expected a session rep after the sign-in tap")
            return
        }
        #expect(session.username == "Maplesugar")
        #expect(session.entityID == "1000")
        #expect(session.gameSession?.status == .live)
        await machine.ingest(Intent.SignOut()) // retire the poll loop
    }

    /// Signing out forgets the account (token out of the store) and returns
    /// to fresh email entry.
    @Test func signOutForgetsAccountAndReturnsToEmailEntry() async {
        let link = SimulatedLink(outcome: .player(Self.player))
        let store = AccountStore()
        let machine = makeMachine(link: link, accountStore: store)
        await machine.start()
        await collect(machine, dispatch: {
            await machine.ingest(Intent.StartBitCraftSignIn(email: "a@b.c"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .awaitingCode = signIn.phase else { return false }
            return true
        })
        await collect(machine, dispatch: {
            await machine.ingest(Intent.SubmitAccessCode(code: "GOOD12"))
        }, until: { rep in
            if case .gameSessionPrompt = rep { return true }
            return false
        })
        guard case .some(.some) = store.last else {
            Issue.record("expected the account to be persisted at sign-in")
            return
        }

        let after = await collect(machine, dispatch: {
            await machine.ingest(Intent.SignOut())
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep else { return false }
            return signIn.phase == .idle && signIn.error == nil && signIn.canDismiss == false
        })
        #expect(after.contains { rep in
            if case .bitCraftSignIn(let signIn) = rep, case .idle = signIn.phase {
                return signIn.canDismiss == false
            }
            return false
        })
        guard case .some(.none) = store.last else {
            Issue.record("expected the account to be deleted from the store")
            return
        }
    }

    /// A link failure keeps the verified account on the linking step with
    /// the error; retrying needs no new code.
    @Test func linkFailureWaitsOnLinkingStepAndRetryRecovers() async {
        let link = SimulatedLink(outcome: .unreachable)
        let machine = makeMachine(link: link)
        await machine.start()
        await collect(machine, dispatch: {
            await machine.ingest(Intent.StartBitCraftSignIn(email: "a@b.c"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .awaitingCode = signIn.phase else { return false }
            return true
        })
        await collect(machine, dispatch: {
            await machine.ingest(Intent.SubmitAccessCode(code: "GOOD12"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .linking = signIn.phase else { return false }
            return signIn.error != nil
        })

        link.outcome = .player(Self.player)
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.RetryAccountLink())
        }, until: { rep in
            if case .gameSessionPrompt = rep { return true }
            return false
        })
        #expect(reps.contains { rep in
            if case .gameSessionPrompt(let prompt) = rep { return prompt.username == "Maplesugar" }
            return false
        })
        #expect(link.askedIdentities.count == 2)
        await machine.ingest(Intent.SignOut()) // retire the poll loop
    }

    /// An account whose player row is missing gets a targeted message.
    @Test func noPlayerAccountSurfacesTargetedError() async {
        let link = SimulatedLink(outcome: .noPlayer)
        let machine = makeMachine(link: link)
        await machine.start()
        await collect(machine, dispatch: {
            await machine.ingest(Intent.StartBitCraftSignIn(email: "a@b.c"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .awaitingCode = signIn.phase else { return false }
            return true
        })
        let reps = await collect(machine, dispatch: {
            await machine.ingest(Intent.SubmitAccessCode(code: "GOOD12"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .linking = signIn.phase else { return false }
            return signIn.error?.contains("no character yet") == true
        })
        #expect(reps.contains { rep in
            if case .bitCraftSignIn(let signIn) = rep { return signIn.error?.contains("no character yet") == true }
            return false
        })
    }

    /// Relaunch with an account but no linked character (previous link
    /// failed / identity file gone): bootstrap resumes the link.
    @Test func bootstrapResumesTheLinkForAnUnlinkedAccount() async {
        let link = SimulatedLink(outcome: .player(Self.player))
        let machine = makeMachine(
            link: link,
            restoredAccount: BitCraftAccount(email: "a@b.c", token: Self.token())
        )
        // Let the sink attach before the (instant) bootstrap runs, so the
        // replayed initial rep is the email screen, not the final gate.
        let reps = await collect(machine, dispatch: {
            try? await Task.sleep(for: .milliseconds(50))
            await machine.start()
        }, until: { rep in
            if case .gameSessionPrompt = rep { return true }
            return false
        })
        #expect(reps.contains { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .linking(let email) = signIn.phase else { return false }
            return email == "a@b.c"
        })
        #expect(reps.contains { rep in
            if case .gameSessionPrompt(let prompt) = rep { return prompt.username == "Maplesugar" }
            return false
        })
        await machine.ingest(Intent.SignOut()) // retire the poll loop
    }

    /// Relaunch with a linked character: straight into the session, the link
    /// is never re-run.
    @Test func bootstrapWithCharacterSkipsTheLink() async {
        let link = SimulatedLink(outcome: .player(Self.player))
        let machine = makeMachine(
            link: link,
            restoredAccount: BitCraftAccount(email: "a@b.c", token: Self.token()),
            restoredIdentity: StoredIdentity(
                entityID: "1000", username: "Maplesugar", regionID: 14, resolvedAt: .distantPast
            )
        )
        // Let the sink attach before the (instant) bootstrap runs, so the
        // replayed initial rep is the email screen, not the final gate.
        let reps = await collect(machine, dispatch: {
            try? await Task.sleep(for: .milliseconds(50))
            await machine.start()
        }, until: { rep in
            if case .gameSessionPrompt = rep { return true }
            return false
        })
        #expect(link.askedIdentities.isEmpty)
        #expect(reps.contains { rep in
            if case .gameSessionPrompt(let prompt) = rep { return prompt.username == "Maplesugar" }
            return false
        })
        await machine.ingest(Intent.SignOut()) // retire the poll loop
    }

    // MARK: - Game session (the `sign_in` held on the game's global database)

    /// Drives email → code → link and returns once the pre-sign-in gate has
    /// live presence data. Shared harness for the game-session tests.
    private func driveToGate(_ machine: StateMachine) async {
        await collect(machine, dispatch: {
            await machine.ingest(Intent.StartBitCraftSignIn(email: "a@b.c"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .awaitingCode = signIn.phase else { return false }
            return true
        })
        await collect(machine, dispatch: {
            await machine.ingest(Intent.SubmitAccessCode(code: "GOOD12"))
        }, until: { rep in
            guard case .gameSessionPrompt(let prompt) = rep else { return false }
            return prompt.signedInElsewhere != nil
        })
    }

    /// From the gate, taps the sign-in action and collects until the game
    /// session reaches `status`.
    private func signInUntilGameSession(
        _ machine: StateMachine, status: ViewRep.Session.GameSession.Status
    ) async -> RepCollector {
        await collect(machine, dispatch: {
            await machine.ingest(Intent.SignInGameSession())
        }, until: { rep in
            guard case .session(let session) = rep else { return false }
            return session.gameSession?.status == status
        })
    }

    /// The gate's action establishes the game session — the `sign_in`
    /// connection that owns the account's one live session, with the
    /// account's own token and the resolved player's entity id.
    @Test func gateActionEstablishesTheGameSession() async {
        let gameSession = SimulatedGlobalSession(scripts: [.established])
        let machine = makeMachine(link: SimulatedLink(outcome: .player(Self.player)), globalSession: gameSession)
        await machine.start()
        await driveToGate(machine)

        let reps = await signInUntilGameSession(machine, status: .live)
        #expect(gameSession.connections == [
            SimulatedGlobalSession.Connection(token: Self.token(), entityID: "1000", regionID: 14)
        ])
        guard case .session(let session)? = reps.last(where: { rep in
            guard case .session = rep else { return false }
            return true
        }) else {
            Issue.record("expected a session rep")
            return
        }
        #expect(session.gameSession?.status == .live)
        #expect(session.gameSession?.error == nil)
        await machine.ingest(Intent.SignOut()) // retire the loops
    }

    /// The game session is never a side effect of linking — no connection
    /// opens until the user acts.
    @Test func linkAloneOpensNoGameSession() async {
        let gameSession = SimulatedGlobalSession(scripts: [.established])
        let machine = makeMachine(link: SimulatedLink(outcome: .player(Self.player)), globalSession: gameSession)
        await machine.start()
        await driveToGate(machine)
        #expect(gameSession.connections.isEmpty)
        await machine.ingest(Intent.SignOut()) // retire the loops
    }

    /// The gate's action is refused while no snapshot has landed — without
    /// the relay's answer we don't know where the character stands, so no
    /// `sign_in` connection may open.
    @Test func signInRefusedWhileNoSnapshotHasLanded() async {
        let gameSession = SimulatedGlobalSession(scripts: [.established])
        let machine = makeMachine(
            link: SimulatedLink(outcome: .player(Self.player)),
            globalSession: gameSession,
            sessionSnapshot: { throw RelayError.notFound } // the poll never answers
        )
        await machine.start()
        await collect(machine, dispatch: {
            await machine.ingest(Intent.StartBitCraftSignIn(email: "a@b.c"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .awaitingCode = signIn.phase else { return false }
            return true
        })
        let gate = await collect(machine, dispatch: {
            await machine.ingest(Intent.SubmitAccessCode(code: "GOOD12"))
        }, until: { rep in
            guard case .gameSessionPrompt(let prompt) = rep else { return false }
            return prompt.username != nil // link done; the gate is up
        })
        guard case .gameSessionPrompt(let prompt)? = gate.lastRep else {
            Issue.record("expected the pre-sign-in gate rep")
            return
        }
        #expect(prompt.claimName == nil && prompt.signedInElsewhere == nil) // nothing landed

        await machine.ingest(Intent.SignInGameSession())
        try? await Task.sleep(for: .milliseconds(300)) // a refused action spawns nothing
        #expect(gameSession.connections.isEmpty)
        await machine.ingest(Intent.SignOut()) // retire the poll loop
    }

    /// The gate's action is refused while the snapshot places the character
    /// outside every claim — and takes the session once a later snapshot
    /// places them inside one.
    @Test func signInRefusedOutsideAClaimUntilASnapshotPlacesThemInOne() async {
        let gameSession = SimulatedGlobalSession(scripts: [.established])
        let whereTheyStand = SnapshotBox(Self.makeSnapshot(claim: nil))
        let machine = makeMachine(
            link: SimulatedLink(outcome: .player(Self.player)),
            globalSession: gameSession,
            sessionSnapshot: { whereTheyStand.snapshot }
        )
        await machine.start()
        await driveToGate(machine)

        await machine.ingest(Intent.SignInGameSession())
        try? await Task.sleep(for: .milliseconds(300)) // a refused action spawns nothing
        #expect(gameSession.connections.isEmpty)

        // They walk into their claim; the next poll sees it…
        whereTheyStand.snapshot = Self.snapshot
        await collect(machine, until: { rep in
            guard case .gameSessionPrompt(let prompt) = rep else { return false }
            return prompt.claimName == "Emberfall"
        })
        // …and the same action now takes the session.
        _ = await signInUntilGameSession(machine, status: .live)
        #expect(gameSession.connections.count == 1)
        await machine.ingest(Intent.SignOut()) // retire the loops
    }

    /// A refused `sign_in` returns to the gate with the server's message;
    /// acting again takes the session.
    @Test func rejectedSignInReturnsToTheGateAndRetryTakesIt() async {
        let gameSession = SimulatedGlobalSession(scripts: [
            SimulatedGlobalSession.Script(events: [.rejected("nope")], hold: false),
            .established,
        ])
        let machine = makeMachine(link: SimulatedLink(outcome: .player(Self.player)), globalSession: gameSession)
        await machine.start()
        await driveToGate(machine)

        let refused = await collect(machine, dispatch: {
            await machine.ingest(Intent.SignInGameSession())
        }, until: { rep in
            guard case .gameSessionPrompt(let prompt) = rep else { return false }
            return prompt.notice?.contains("nope") == true
        })
        // The refusal was visible on the session before the return to the
        // gate, and the gate carries the server's message.
        #expect(refused.contains { rep in
            guard case .session(let session) = rep else { return false }
            return session.gameSession?.status == .rejected && session.gameSession?.error == "nope"
        })
        #expect(refused.contains { rep in
            guard case .gameSessionPrompt(let prompt) = rep else { return false }
            return prompt.notice?.contains("nope") == true
        })
        #expect(gameSession.connections.count == 1)
        // Acting again takes the session.
        _ = await signInUntilGameSession(machine, status: .live)
        #expect(gameSession.connections.count == 2)
        await machine.ingest(Intent.SignOut()) // retire the loops
    }

    /// A kicked (or dropped) session returns to the gate and is NOT
    /// re-taken automatically — a second connection opens only when the
    /// user acts again.
    @Test func kickedSessionReturnsToTheGateWithoutRetaking() async {
        let gameSession = SimulatedGlobalSession(scripts: [.established])
        let machine = makeMachine(link: SimulatedLink(outcome: .player(Self.player)), globalSession: gameSession)
        await machine.start()
        await driveToGate(machine)
        _ = await signInUntilGameSession(machine, status: .live)

        // The server closes our socket — another client signed the
        // account in.
        gameSession.endHeld()
        let kicked = await collect(machine, until: { rep in
            guard case .gameSessionPrompt(let prompt) = rep else { return false }
            return prompt.notice != nil
        })
        #expect(kicked.contains { rep in
            guard case .gameSessionPrompt(let prompt) = rep else { return false }
            return prompt.notice == "The game session ended."
        })
        // No automatic retake: still exactly one connection.
        #expect(gameSession.connections.count == 1)
        // The user can take it back from the gate.
        _ = await signInUntilGameSession(machine, status: .live)
        #expect(gameSession.connections.count == 2)
        await machine.ingest(Intent.SignOut()) // retire the loops
    }

    /// Signing out retires the game-session loop: the socket it held is
    /// terminated, freeing the account's session slot (the desktop client
    /// can sign in again).
    @Test func signOutEndsTheHeldGameSession() async {
        let gameSession = SimulatedGlobalSession(scripts: [.established])
        let machine = makeMachine(link: SimulatedLink(outcome: .player(Self.player)), globalSession: gameSession)
        await machine.start()
        await driveToGate(machine)
        _ = await signInUntilGameSession(machine, status: .live)

        await machine.ingest(Intent.SignOut())
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && gameSession.terminated < 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(gameSession.terminated == 1)
    }

    /// A restored launch lands on the gate too — the game session is only
    /// ever user-taken, relaunch included.
    @Test func bootstrapLandsOnTheGateWithoutSigningIn() async {
        let gameSession = SimulatedGlobalSession(scripts: [.established])
        let machine = makeMachine(
            link: SimulatedLink(outcome: .player(Self.player)),
            globalSession: gameSession,
            restoredAccount: BitCraftAccount(email: "a@b.c", token: Self.token()),
            restoredIdentity: StoredIdentity(
                entityID: "1000", username: "Maplesugar", regionID: 14, resolvedAt: .distantPast
            )
        )
        // Let the sink attach before the (instant) bootstrap runs.
        let reps = await collect(machine, dispatch: {
            try? await Task.sleep(for: .milliseconds(50))
            await machine.start()
        }, until: { rep in
            guard case .gameSessionPrompt(let prompt) = rep else { return false }
            return prompt.signedInElsewhere != nil
        })
        #expect(gameSession.connections.isEmpty) // no session without the user
        #expect(reps.contains { rep in
            if case .gameSessionPrompt(let prompt) = rep {
                return prompt.username == "Maplesugar" && prompt.bitCraftAccountEmail == "a@b.c"
            }
            return false
        })
        // The restored token still works when the user acts.
        _ = await signInUntilGameSession(machine, status: .live)
        #expect(gameSession.connections == [
            SimulatedGlobalSession.Connection(token: Self.token(), entityID: "1000", regionID: 14)
        ])
        await machine.ingest(Intent.SignOut()) // retire the loops
    }
}

