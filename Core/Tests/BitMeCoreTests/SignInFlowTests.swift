import Testing
import Foundation
@testable import BitMeCore

/// The BitCraft emailed-code sign-in flow through the machine: assertions
/// observe the published ViewRep stream (ADR-014), with a scripted BitCraft
/// auth adapter.
@MainActor
struct SignInFlowTests {

    // MARK: - Scripted auth

    final class SimulatedAuth: @unchecked Sendable {
        enum CodeOutcome: Sendable {
            case requested
            case rejected(String)
            case unreachable
        }
        enum TokenOutcome: Sendable {
            case token(String)
            case rejected(String)
            case unreachable
        }

        private let lock = NSLock()
        private var _codeOutcome: CodeOutcome = .requested
        private var _tokenOutcome: TokenOutcome = .token("jwt")
        private var _requestedEmails: [String] = []

        var codeOutcome: CodeOutcome {
            get { lock.withLock { _codeOutcome } }
            set { lock.withLock { _codeOutcome = newValue } }
        }

        var tokenOutcome: TokenOutcome {
            get { lock.withLock { _tokenOutcome } }
            set { lock.withLock { _tokenOutcome = newValue } }
        }

        var requestedEmails: [String] {
            lock.withLock { _requestedEmails }
        }

        func requestAccessCode(_ email: String) async throws {
            lock.withLock { _requestedEmails.append(email) }
            switch codeOutcome {
            case .requested: return
            case .rejected(let message): throw BitCraftAuthError.badRequest(message)
            case .unreachable: throw URLError(.notConnectedToInternet)
            }
        }

        func authenticate(email: String, code: String) async throws -> String {
            switch tokenOutcome {
            case .token(let token): return token
            case .rejected(let message): throw BitCraftAuthError.badRequest(message)
            case .unreachable: throw URLError(.notConnectedToInternet)
            }
        }
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

        var lastRep: ViewRep? {
            lock.withLock { reps.last }
        }
    }

    // MARK: - Harness

    private func makeMachine(
        auth: SimulatedAuth,
        restoredAccount: BitCraftAccount? = nil
    ) -> StateMachine {
        StateMachine(adapters: Adapters(
            relay: Adapters.Relay(
                resolve: { _ in throw RelayError.notFound },
                session: { _ in throw URLError(.badServerResponse) },
                sessionResources: { _ in throw RelayError.notFound },
                resourceDictionary: { _ in throw RelayError.notFound },
                worldElevation: { _, _ in throw RelayError.notFound },
                openResourceStream: { _ in AsyncStream { _ in } } // parked
            ),
            bitCraft: Adapters.BitCraft(
                requestAccessCode: { email in try await auth.requestAccessCode(email) },
                authenticate: { email, code in try await auth.authenticate(email: email, code: code) }
            ),
            loadFoodBuffGamedata: { nil },
            restoreIdentity: { nil },
            persistIdentity: { _ in },
            restoreBitCraftAccount: { restoredAccount },
            persistBitCraftAccount: { _ in },
            sleep: { _ in }
        ))
    }

    /// Collects ViewReps until `finished` matches, with a timeout backstop.
    /// `dispatch` runs after subscribing so no intermediate rep is missed.
    private func collect(
        _ machine: StateMachine,
        dispatch: (@Sendable () async -> Void)? = nil,
        until finished: @Sendable @escaping (ViewRep) -> Bool,
        timeout: TimeInterval = 5
    ) async -> RepCollector {
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

    @Test func happyPathStoresAccountAndDismisses() async {
        let auth = SimulatedAuth()
        let machine = makeMachine(auth: auth)
        await machine.start()

        // Email step: the code request lands and the phase flips to awaiting.
        await collect(machine, dispatch: {
            await machine.ingest(Intent.ShowBitCraftSignIn())
            await machine.ingest(Intent.StartBitCraftSignIn(email: "  Ekscrypto@Gmail.com "))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .awaitingCode(let email) = signIn.phase else { return false }
            return email == "ekscrypto@gmail.com" && signIn.error == nil
        })

        // Code step: authentication stores the account and dismisses to
        // onboarding, which now shows the signed-in email.
        let done = await collect(machine, dispatch: {
            await machine.ingest(Intent.SubmitAccessCode(code: " mab9l6 "))
        }, until: { rep in
            guard case .onboarding(let onboarding) = rep else { return false }
            return onboarding.bitCraftAccountEmail == "ekscrypto@gmail.com"
        })
        #expect(done.contains { rep in
            if case .onboarding(let o) = rep { return o.bitCraftAccountEmail == "ekscrypto@gmail.com" }
            return false
        })
        #expect(auth.requestedEmails == ["ekscrypto@gmail.com"])
    }

    @Test func invalidEmailShowsErrorWithoutNetwork() async {
        let auth = SimulatedAuth()
        let machine = makeMachine(auth: auth)
        await machine.start()

        let collector = await collect(machine, dispatch: {
            await machine.ingest(Intent.ShowBitCraftSignIn())
            await machine.ingest(Intent.StartBitCraftSignIn(email: "not-an-email"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep else { return false }
            return signIn.error != nil
        })
        guard case .bitCraftSignIn(let signIn) = collector.lastRep else {
            Issue.record("expected sign-in rep")
            return
        }
        #expect(signIn.error == "Enter a valid email address.")
        #expect(auth.requestedEmails.isEmpty)
    }

    @Test func wrongCodeReturnsToCodeEntryForRetry() async {
        let auth = SimulatedAuth()
        auth.tokenOutcome = .rejected("invalid access code")
        let machine = makeMachine(auth: auth)
        await machine.start()

        await collect(machine, dispatch: {
            await machine.ingest(Intent.ShowBitCraftSignIn())
            await machine.ingest(Intent.StartBitCraftSignIn(email: "a@b.c"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .awaitingCode = signIn.phase else { return false }
            return true
        })

        // Wrong code: back to code entry with the server's message.
        await collect(machine, dispatch: {
            await machine.ingest(Intent.SubmitAccessCode(code: "WRONG1"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .awaitingCode = signIn.phase else { return false }
            return signIn.error == "invalid access code"
        })

        // Retry with a good code succeeds.
        auth.tokenOutcome = .token("jwt-2")
        await collect(machine, dispatch: {
            await machine.ingest(Intent.SubmitAccessCode(code: "GOOD12"))
        }, until: { rep in
            guard case .onboarding(let onboarding) = rep else { return false }
            return onboarding.bitCraftAccountEmail == "a@b.c"
        })
    }

    @Test func codeRequestUnreachableShowsErrorAndRecovers() async {
        let auth = SimulatedAuth()
        auth.codeOutcome = .unreachable
        let machine = makeMachine(auth: auth)
        await machine.start()

        await collect(machine, dispatch: {
            await machine.ingest(Intent.ShowBitCraftSignIn())
            await machine.ingest(Intent.StartBitCraftSignIn(email: "a@b.c"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .idle = signIn.phase else { return false }
            return signIn.error != nil
        })

        // Same email again once the network is back.
        auth.codeOutcome = .requested
        await collect(machine, dispatch: {
            await machine.ingest(Intent.StartBitCraftSignIn(email: "a@b.c"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .awaitingCode = signIn.phase else { return false }
            return true
        })
        #expect(auth.requestedEmails.count == 2)
    }

    @Test func restoredAccountAppearsOnOnboardingRep() async {
        let account = BitCraftAccount(email: "ekscrypto@gmail.com", token: "jwt")
        let auth = SimulatedAuth()
        let machine = makeMachine(auth: auth, restoredAccount: account)
        await collect(machine, until: { rep in
            guard case .onboarding(let onboarding) = rep else { return false }
            return onboarding.bitCraftAccountEmail == "ekscrypto@gmail.com"
        })
    }

    @Test func forgetAccountClearsOnboardingRep() async {
        let account = BitCraftAccount(email: "ekscrypto@gmail.com", token: "jwt")
        let auth = SimulatedAuth()
        let machine = makeMachine(auth: auth, restoredAccount: account)
        await machine.start()
        await collect(machine, until: { rep in
            guard case .onboarding(let onboarding) = rep else { return false }
            return onboarding.bitCraftAccountEmail != nil
        })
        await collect(machine, dispatch: {
            await machine.ingest(Intent.ForgetBitCraftAccount())
        }, until: { rep in
            guard case .onboarding(let onboarding) = rep else { return false }
            return onboarding.bitCraftAccountEmail == nil
        })
    }

    @Test func staleFeedbackIsIgnoredAfterNewEmailRequest() async {
        let auth = SimulatedAuth()
        let machine = makeMachine(auth: auth)
        await machine.start()

        await collect(machine, dispatch: {
            await machine.ingest(Intent.ShowBitCraftSignIn())
            await machine.ingest(Intent.StartBitCraftSignIn(email: "first@b.c"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .awaitingCode = signIn.phase else { return false }
            return true
        })

        // A second email request; the first request's late reply must not
        // flip the phase for the wrong email (if it did, the legit reply for
        // the second email would then be a no-op and the phase would stick
        // on the first address).
        await collect(machine, dispatch: {
            await machine.ingest(Intent.StartBitCraftSignIn(email: "second@b.c"))
            await machine.ingest(Intent.AccessCodeRequested(email: "first@b.c"))
            await machine.ingest(Intent.AccessCodeRequested(email: "second@b.c"))
        }, until: { rep in
            guard case .bitCraftSignIn(let signIn) = rep,
                  case .awaitingCode(let email) = signIn.phase else { return false }
            return email == "second@b.c"
        })
        guard case .bitCraftSignIn(let signIn) = await lastRep(of: machine) else {
            Issue.record("expected sign-in rep")
            return
        }
        guard case .awaitingCode(let email) = signIn.phase else {
            Issue.record("expected awaitingCode phase")
            return
        }
        #expect(email == "second@b.c")
    }

    @Test func sessionRepCarriesBitCraftAccountEmail() {
        var persistent = PersistentState()
        persistent.identity = StoredIdentity(
            entityID: "1000", username: "Whisper", regionID: 7, resolvedAt: .now
        )
        persistent.bitCraftAccount = BitCraftAccount(email: "a@b.c", token: "jwt")
        let rep = ViewRep.from(persistent: persistent, ephemeral: EphemeralState())
        guard case .session(let session) = rep else {
            Issue.record("expected session rep")
            return
        }
        #expect(session.bitCraftAccountEmail == "a@b.c")
    }

    /// The sign-in screen is reachable while a character session is active —
    /// `signInVisible` takes priority over the session projection.
    @Test func signInScreenTakesPriorityOverSession() {
        var persistent = PersistentState()
        persistent.identity = StoredIdentity(
            entityID: "1000", username: "Whisper", regionID: 7, resolvedAt: .now
        )
        var ephemeral = EphemeralState()
        ephemeral.signInVisible = true
        guard case .bitCraftSignIn = ViewRep.from(persistent: persistent, ephemeral: ephemeral) else {
            Issue.record("expected sign-in rep over session")
            return
        }
    }

    private func lastRep(of machine: StateMachine) async -> ViewRep? {
        let collector = RepCollector()
        let task = machine.viewRep.sink { collector.append($0) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        return collector.lastRep
    }
}
