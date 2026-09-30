import Testing
import Foundation
@testable import BitMeCore

/// The player-vitals sync (Pocket Crafter's status banner): the machine
/// flow from the region leg's arrival through the banner projection, and
/// the pure projections themselves.
@Suite(.serialized) // staged collects share the main actor; no self-contention
@MainActor
struct PlayerVitalsTests {

    // MARK: - Doubles

    /// Scripted own-row stream: answers one connection from the queued
    /// events (held open like a live leg), recording who it was asked for.
    final class SimulatedPlayerVitals: @unchecked Sendable {
        struct Request: Equatable {
            let leg: RegionLeg
            let player: UInt64
        }

        private let lock = NSLock()
        private var _requests: [Request] = []
        private let events: [PlayerVitalsEvent]

        init(events: [PlayerVitalsEvent]) {
            self.events = events
        }

        var requests: [Request] { lock.withLock { _requests } }

        func open(leg: RegionLeg, player: UInt64) -> AsyncStream<PlayerVitalsEvent> {
            lock.withLock { _requests.append(Request(leg: leg, player: player)) }
            return AsyncStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                // Hold open like a live leg (the machine-flow test ends it
                // by tearing the session down).
            }
        }
    }

    private static func actionRow(
        kind: PlayerActionKind, recipeID: Int32? = nil, layer: UInt8 = 0
    ) -> PlayerActionRow {
        PlayerActionRow(
            autoID: 1, chunkIndex: 200_250, entityID: 1000,
            startAtMs: 1_790_557_962_820, durationMs: 1_689, target: 3001,
            recipeID: recipeID, actionType: kind, layer: layer,
            lastActionResult: .success, wasConsumed: false
        )
    }

    private static func positionRow() -> MobileEntityRow {
        MobileEntityRow(
            entityID: 1000, chunkIndex: 200_250, timestampMs: 1_790_557_942_319,
            locationX: 23_996_784, locationZ: 19_259_184,
            destinationX: 23_997_002, destinationZ: 19_258_982, dimension: 1
        )
    }

    // MARK: - Projection

    @Test func vitalsMutationPopulatesStateAndRep() async throws {
        let leg = ClaimBuildingsTests.makeLeg()
        let vitals = SimulatedPlayerVitals(events: [
            .stamina(312.5),
            .health(150),
            .teleportEnergy(42),
            .satiation(78.5),
            // 50 stats — maxes at the pinned indices (1, 0, 19, 49).
            .stats((0..<50).map { Float($0 == 0 ? 160 : $0 == 1 ? 340 : $0 == 19 ? 100 : $0 == 49 ? 100 : 0) }),
            .action(Self.actionRow(kind: .craft, recipeID: 77)),
            .position(Self.positionRow()),
        ])
        let globalSession = AccountDrivenSignInTests.SimulatedGlobalSession(
            scripts: [.init(events: [.regionLeg(leg), .established], hold: true)]
        )
        let machine = AccountDrivenSignInTests().makeMachine(
            link: .init(outcome: .player(AccountDrivenSignInTests.player)),
            globalSession: globalSession,
            playerVitals: { leg, player in vitals.open(leg: leg, player: player) }
        )

        await machine.start()
        await machine.ingest(Intent.StartBitCraftSignIn(email: "crafter@example.com"))
        _ = await ClaimBuildingsTests().collectUntil(machine) { rep in
            if case .signIn(let signIn) = rep, case .awaitingCode = signIn.phase { return true }
            return false
        }
        await machine.ingest(Intent.SubmitAccessCode(code: "123456"))
        _ = await ClaimBuildingsTests().collectUntil(machine) { rep in
            if case .gameSessionPrompt(let prompt) = rep, prompt.claimName != nil { return true }
            return false
        }
        await machine.ingest(Intent.SignInGameSession())

        // The banner appears once the vitals events have flowed: activity
        // from the action record, all four pools with maxes.
        let rep = await ClaimBuildingsTests().collectUntil(machine) { rep in
            if case .session(let session) = rep, let vitals = session.vitals {
                return vitals.activity == "Crafting" && vitals.stamina == 312.5
            }
            return false
        }
        guard case .session(let session) = rep, let banner = session.vitals else {
            Issue.record("expected a session rep with vitals")
            return
        }
        #expect(banner.activity == "Crafting")
        #expect(banner.stamina == 312.5)
        #expect(banner.maxStamina == 340)
        #expect(banner.health == 150)
        #expect(banner.maxHealth == 160)
        #expect(banner.teleportEnergy == 42)
        #expect(banner.maxTeleportEnergy == 100)
        #expect(banner.satiation == 78.5)
        #expect(banner.maxSatiation == 100)
        #expect(vitals.requests.map { $0.player } == [1000])

        // Session teardown cancels the vitals sync with the rest.
        globalSession.endHeld()
        _ = await ClaimBuildingsTests().collectUntil(machine) { rep in
            if case .gameSessionPrompt(let prompt) = rep, prompt.claimName != nil { return true }
            return false
        }
        await machine.ingest(Intent.SignOut())
    }

    @Test func noVitalsBeforeTheGameSessionIsHeld() async throws {
        // The gate and sign-in screens carry no banner: the vitals sync
        // rides the game session's region leg, which does not exist yet.
        final class SawSession: @unchecked Sendable {
            private let lock = NSLock()
            private var _saw = false
            var saw: Bool { lock.withLock { _saw } }
            func mark() { lock.withLock { _saw = true } }
        }
        let sawSession = SawSession()
        let machine = AccountDrivenSignInTests().makeMachine(
            link: .init(outcome: .player(AccountDrivenSignInTests.player))
        )
        await machine.start()
        await machine.ingest(Intent.StartBitCraftSignIn(email: "crafter@example.com"))
        _ = await ClaimBuildingsTests().collectUntil(machine) { rep in
            if case .signIn(let signIn) = rep, case .awaitingCode = signIn.phase { return true }
            return false
        }
        await machine.ingest(Intent.SubmitAccessCode(code: "123456"))
        // Wait for the gate to settle (the poll has landed the claim),
        // watching every rep on the way — a session screen must never
        // appear before the user signs the game session in.
        _ = await RepCollecting.collect(
            machine.crafterRep,
            onRep: { rep in
                if case .session = rep { sawSession.mark() }
            },
            until: { rep in
                if case .gameSessionPrompt(let prompt) = rep { return prompt.claimName != nil }
                return false
            }
        )
        await machine.ingest(Intent.SignOut())
        #expect(!sawSession.saw)
    }
}
