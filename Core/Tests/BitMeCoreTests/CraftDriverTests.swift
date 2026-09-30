import Testing
import Foundation
@testable import BitMeCore

/// Scripted craft-driver adapter double: answers `craft_continue*`,
/// `craft_cancel`, and `player_move` calls from queued results (default
/// success), recording every call for assertions. Lock-protected — the
/// loop runs off the test actor.
final class ScriptedCraftDriver: @unchecked Sendable {
    struct MoveCall: Equatable {
        let timestampMs: UInt64
        let destinationX: Int32
        let destinationZ: Int32
        let originX: Int32?
        let originZ: Int32?
        let durationSeconds: Float
        let moveType: Int32
    }

    private let lock = NSLock()
    private var _startResults: [Result<DriverReceipt, Error>] = []
    private var _continueResults: [Result<DriverReceipt, Error>] = []
    private var _moveResults: [Result<DriverReceipt, Error>] = []
    var stationLocation: LocationRow?
    var ownPosition: MobileEntityRow?
    private var _startCalls: [(entity: UInt64, timestampMs: UInt64)] = []
    private var _continueCalls: [(entity: UInt64, timestampMs: UInt64)] = []
    private var _moves: [MoveCall] = []
    private var _cancelCalls: [UInt64] = []
    private var _actionCancels = 0
    private var _allStamps: [UInt64] = []

    func queueStart(_ result: Result<DriverReceipt, Error>) {
        lock.withLock { _startResults.append(result) }
    }

    func queueContinue(_ result: Result<DriverReceipt, Error>) {
        lock.withLock { _continueResults.append(result) }
    }

    func queueMove(_ result: Result<DriverReceipt, Error>) {
        lock.withLock { _moveResults.append(result) }
    }

    var startCalls: [(entity: UInt64, timestampMs: UInt64)] { lock.withLock { _startCalls } }
    var continueCalls: [(entity: UInt64, timestampMs: UInt64)] { lock.withLock { _continueCalls } }
    var moves: [MoveCall] { lock.withLock { _moves } }
    var cancelCalls: [UInt64] { lock.withLock { _cancelCalls } }
    var actionCancels: Int { lock.withLock { _actionCancels } }
    /// Every request timestamp in call order (starts, completes, moves
    /// interleaved) — the monotonicity witness.
    var allStamps: [UInt64] { lock.withLock { _allStamps } }

    func start(_ entity: UInt64, _ timestampMs: UInt64) throws -> DriverReceipt {
        try lock.withLock {
            _startCalls.append((entity, timestampMs))
            _allStamps.append(timestampMs)
            if !_startResults.isEmpty {
                return try _startResults.removeFirst().get()
            }
            return DriverReceipt(serverTimeMs: 0)
        }
    }

    func complete(_ entity: UInt64, _ timestampMs: UInt64) throws -> DriverReceipt {
        try lock.withLock {
            _continueCalls.append((entity, timestampMs))
            _allStamps.append(timestampMs)
            return try _continueResults.removeFirst().get()
        }
    }

    func move(
        _ timestampMs: UInt64, _ destinationX: Int32, _ destinationZ: Int32,
        _ dimension: UInt32, _ originX: Int32?, _ originZ: Int32?,
        _ durationSeconds: Float, _ moveType: Int32
    ) throws -> DriverReceipt {
        try lock.withLock {
            _allStamps.append(timestampMs)
            _moves.append(MoveCall(
                timestampMs: timestampMs, destinationX: destinationX,
                destinationZ: destinationZ, originX: originX, originZ: originZ,
                durationSeconds: durationSeconds, moveType: moveType
            ))
            if !_moveResults.isEmpty {
                return try _moveResults.removeFirst().get()
            }
            return DriverReceipt(serverTimeMs: 0)
        }
    }

    func cancel(_ pocketID: UInt64) -> DriverReceipt {
        lock.withLock { _cancelCalls.append(pocketID) }
        return DriverReceipt(serverTimeMs: 0)
    }

    func actionCancel() -> DriverReceipt {
        lock.withLock { _actionCancels += 1 }
        return DriverReceipt(serverTimeMs: 0)
    }
}

/// The craft driver (Pocket Crafter): the machine flow from tapping a
/// craft through the walk stage, the paced loop, the refusal paths, and
/// the banner projection.
@Suite(.serialized) // staged collects share the main actor; no self-contention
@MainActor
struct CraftDriverTests {

    private static let craftEntity: UInt64 = 5001
    private static let buildingEntity: UInt64 = 3001

    private static func receipt(progress: Int32, stamina: Float? = nil) -> DriverReceipt {
        DriverReceipt(
            serverTimeMs: 1_790_557_946_649,
            craft: ProgressiveActionRow(
                entityID: craftEntity, buildingEntityID: buildingEntity,
                functionType: 0, progress: progress, recipeID: 77,
                craftCount: 4, lastCritOutcome: 0, ownerEntityID: 1000,
                lockExpiresAtMicros: 0, preparation: false
            ),
            stamina: stamina.map { StaminaRow(entityID: 1000, lastDecreaseAtMicros: 0, stamina: $0) }
        )
    }

    /// The claim-buildings script carrying one drivable bench craft
    /// (4 items × 10 effort) at an outdoor station, with the recipe
    /// catalog entries the plan needs. `timeRequirement` 0.02 s keeps the
    /// paced loop test-fast even against real sleeps.
    private static func buildingsScript() -> SimulatedClaimBuildings.Script {
        let gamedata = BuildingGamedata(
            buildings: [
                1200: BuildingDescInfo(id: 1200, name: "Sawmill", functions: [
                    BuildingFunctionInfo(
                        functionType: 1, level: 2, craftingSlots: 4, storageSlots: 0,
                        cargoSlots: 0, refiningSlots: 0, refiningCargoSlots: 0
                    )
                ], unenterable: true, footprint: []),
            ],
            recipeNames: [77: "Oak Plank"],
            recipeActionsRequired: [77: 10],
            recipeTimeRequirement: [77: 0.02],
            recipeStaminaRequirement: [77: 2.5]
        )
        return .init(events: [
            .gamedata(gamedata),
            .live,
            .claim(ClaimHeader(entityID: 2000, name: "Emberfall", ownerPlayerEntityID: 1000, neutral: false)),
            .buildingChanged(RegionBuilding(
                entityID: Self.buildingEntity, claimEntityID: 2000, buildingDescriptionID: 1200
            )),
            .craftChanged(RegionCraft(
                entityID: craftEntity, ownerEntityID: 1000,
                buildingEntityID: buildingEntity, recipeID: 77,
                kind: .active(progress: 5, craftCount: 4, preparation: false, lockExpiresAtMicros: 0)
            )),
        ], hold: false)
    }

    private func makeMachine(
        driver: ScriptedCraftDriver,
        claimBuildings: SimulatedClaimBuildings
    ) -> StateMachine {
        AccountDrivenSignInTests().makeMachine(
            link: .init(outcome: .player(AccountDrivenSignInTests.player)),
            globalSession: AccountDrivenSignInTests.SimulatedGlobalSession(
                scripts: [.init(events: [.regionLeg(ClaimBuildingsTests.makeLeg()), .established], hold: true)]
            ),
            claimBuildings: claimBuildings,
            driver: driver
        )
    }

    /// Signs the game session in and waits for the workstations list to
    /// carry the craft — the drive's precondition.
    private func signInAndSync(_ machine: StateMachine) async {
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
        _ = await RepCollecting.collect(machine.workstationsRep, until: { $0.crafts.count == 1 })
    }

    nonisolated private static func banner(of rep: CrafterRep) -> CrafterRep.Session.CraftBanner? {
        if case .session(let session) = rep { return session.craftBanner }
        return nil
    }

    // MARK: - The loop

    @Test func driveRunsToCompletionThroughThePacedLoop() async throws {
        let driver = ScriptedCraftDriver()
        // Already standing in craft range: station at tile (100,100), the
        // player one tile off — the walk stage skips.
        driver.stationLocation = LocationRow(
            entityID: Self.buildingEntity, chunkIndex: 200_250, x: 100_000, z: 100_000, dimension: 1
        )
        driver.ownPosition = MobileEntityRow(
            entityID: 1000, chunkIndex: 200_250, timestampMs: 1,
            locationX: 101_000, locationZ: 101_000,
            destinationX: 101_000, destinationZ: 101_000, dimension: 1
        )
        driver.queueContinue(.success(Self.receipt(progress: 15, stamina: 300)))
        driver.queueContinue(.success(Self.receipt(progress: 25, stamina: 295)))
        driver.queueContinue(.success(Self.receipt(progress: 40, stamina: 290))) // 4×10 = goal
        let claimBuildings = SimulatedClaimBuildings(
            scripts: [Self.buildingsScript()]
        )
        let machine = makeMachine(driver: driver, claimBuildings: claimBuildings)
        await signInAndSync(machine)

        await machine.ingest(Intent.TapCraft(craftEntityID: Self.craftEntity))
        let rep = await ClaimBuildingsTests().collectUntil(machine) { rep in
            Self.banner(of: rep)?.state == .completed
        }
        guard let rep else {
            Issue.record("expected a completed-craft banner")
            await machine.ingest(Intent.SignOut())
            return
        }
        let banner = Self.banner(of: rep)
        #expect(banner?.recipeName == "Oak Plank")
        #expect(banner?.effortDone == 40)
        #expect(banner?.effortTotal == 40)
        // The loop's shape: arm → (pace) → complete, three iterations.
        #expect(driver.startCalls.count == 3)
        #expect(driver.continueCalls.map(\.entity) == [Self.craftEntity, Self.craftEntity, Self.craftEntity])
        // Timestamps are monotonic across every request, interleaved in
        // call order (arm, pace, complete, arm, …).
        #expect(driver.allStamps == driver.allStamps.sorted())

        // Dismiss clears the banner.
        await machine.ingest(Intent.DismissCraftBanner())
        _ = await ClaimBuildingsTests().collectUntil(machine) { rep in
            if case .session(let session) = rep { return session.craftBanner == nil }
            return false
        }
        await machine.ingest(Intent.SignOut())
    }

    @Test func staminaRefusalPausesTheDrive() async throws {
        let driver = ScriptedCraftDriver()
        driver.stationLocation = LocationRow(
            entityID: Self.buildingEntity, chunkIndex: 0, x: 100_000, z: 100_000, dimension: 1
        )
        driver.ownPosition = MobileEntityRow(
            entityID: 1000, chunkIndex: 0, timestampMs: 1,
            locationX: 101_000, locationZ: 101_000,
            destinationX: 101_000, destinationZ: 101_000, dimension: 1
        )
        driver.queueContinue(.success(Self.receipt(progress: 15, stamina: 2)))
        driver.queueContinue(.failure(RegionDriverClient.CallError.refused("Not enough stamina.")))
        let machine = makeMachine(
            driver: driver,
            claimBuildings: SimulatedClaimBuildings(scripts: [Self.buildingsScript()])
        )
        await signInAndSync(machine)

        await machine.ingest(Intent.TapCraft(craftEntityID: Self.craftEntity))
        let rep = await ClaimBuildingsTests().collectUntil(machine) { rep in
            if case .session(let session) = rep, let banner = session.craftBanner,
               case .paused(let outOfStamina) = banner.state {
                return outOfStamina
            }
            return false
        }
        if case .session(let session) = rep, let banner = session.craftBanner,
           case .paused(let outOfStamina) = banner.state {
            #expect(outOfStamina)
            #expect(banner.effortDone == 15)
        }
        // The banner's vitals carry the receipt's stamina (the own-action
        // feedback channel — subscriptions never echo it).
        if case .session(let session) = rep {
            #expect(session.vitals?.stamina == 2)
        }

        // Resume re-arms: the loop's first call is craft_continue_start.
        driver.queueContinue(.success(Self.receipt(progress: 20, stamina: 4)))
        driver.queueContinue(.success(Self.receipt(progress: 40, stamina: 2)))
        let resumeStamps = driver.startCalls.count
        await machine.ingest(Intent.ResumeCraftDriver())
        _ = await ClaimBuildingsTests().collectUntil(machine) { rep in
            Self.banner(of: rep)?.state == .completed
        }
        #expect(driver.startCalls.count == resumeStamps + 2)
        await machine.ingest(Intent.SignOut())
    }

    @Test func stopCancelsTheCraftServerSide() async throws {
        let driver = ScriptedCraftDriver()
        driver.stationLocation = LocationRow(
            entityID: Self.buildingEntity, chunkIndex: 0, x: 100_000, z: 100_000, dimension: 1
        )
        driver.ownPosition = MobileEntityRow(
            entityID: 1000, chunkIndex: 0, timestampMs: 1,
            locationX: 101_000, locationZ: 101_000,
            destinationX: 101_000, destinationZ: 101_000, dimension: 1
        )
        driver.queueContinue(.success(Self.receipt(progress: 15)))
        driver.queueContinue(.success(Self.receipt(progress: 25)))
        // The third iteration never answers — Stop cancels mid-pace.
        driver.queueContinue(.success(Self.receipt(progress: 35)))
        let machine = makeMachine(
            driver: driver,
            claimBuildings: SimulatedClaimBuildings(scripts: [Self.buildingsScript()])
        )
        await signInAndSync(machine)

        await machine.ingest(Intent.TapCraft(craftEntityID: Self.craftEntity))
        _ = await ClaimBuildingsTests().collectUntil(machine) { rep in
            Self.banner(of: rep)?.effortDone == 25
        }
        await machine.ingest(Intent.StopCraftDriver())
        _ = await ClaimBuildingsTests().collectUntil(machine) { rep in
            if case .session(let session) = rep { return session.craftBanner == nil }
            return false
        }
        // craft_cancel carries the pocket id; player_action_cancel rode along.
        _ = await RepCollecting.collect(machine.crafterRep, until: { _ in false }, timeout: 0.1)
        #expect(driver.cancelCalls == [Self.craftEntity])
        #expect(driver.actionCancels == 1)
        await machine.ingest(Intent.SignOut())
    }

    // MARK: - The walk stage

    @Test func walkHopsToTheStandPointThenCrafts() async throws {
        let driver = ScriptedCraftDriver()
        // The player stands 10 tiles out: station (100,100), player
        // (110,110) — hex distance (10+20+10)/2 = 20 tiles.
        driver.stationLocation = LocationRow(
            entityID: Self.buildingEntity, chunkIndex: 0, x: 100_000, z: 100_000, dimension: 1
        )
        driver.ownPosition = MobileEntityRow(
            entityID: 1000, chunkIndex: 0, timestampMs: 1,
            locationX: 110_000, locationZ: 110_000,
            destinationX: 110_000, destinationZ: 110_000, dimension: 1
        )
        driver.queueContinue(.success(Self.receipt(progress: 40))) // one iteration finishes it
        let machine = makeMachine(
            driver: driver,
            claimBuildings: SimulatedClaimBuildings(scripts: [Self.buildingsScript()])
        )
        await signInAndSync(machine)

        await machine.ingest(Intent.TapCraft(craftEntityID: Self.craftEntity))
        // The banner walks first, then crafts to completion.
        let rep = await ClaimBuildingsTests().collectUntil(machine) { rep in
            Self.banner(of: rep)?.state == .completed
        }

        // The walk: ~1-tile hops (moveType 2) then a zero-duration stop
        // (moveType 1) at the stand-point — footprint radius 0 + 2 tiles
        // from the station center, along the line toward the player.
        let moves = driver.moves
        #expect(!moves.isEmpty)
        #expect(moves.dropLast().allSatisfy { $0.moveType == 2 })
        #expect(moves.last?.moveType == 1)
        #expect(moves.last?.durationSeconds == 0)
        let stop = moves.last!
        // Stand-point ≈ center + 2 tiles toward (110,110): distance in raw
        // units from the station center to the stop ≈ 2000, well under the
        // 20-tile gap the walk started from.
        let dx = Double(stop.destinationX - 100_000)
        let dz = Double(stop.destinationZ - 100_000)
        let stopDistance = (dx * dx + dz * dz).squareRoot()
        #expect(stopDistance > 1_000 && stopDistance < 3_000)
        // Every hop is paced under the walk speed with the safety margin.
        #expect(moves.dropLast().allSatisfy { $0.durationSeconds > 0 })
        // Origins chain: hop N's origin is hop N−1's destination.
        for (previous, hop) in zip(moves, moves.dropFirst()) {
            #expect(hop.originX == previous.destinationX)
            #expect(hop.originZ == previous.destinationZ)
        }
        _ = rep
        await machine.ingest(Intent.SignOut())
    }

    @Test func interiorStationIsRefusedAtTapTime() async throws {
        let driver = ScriptedCraftDriver()
        driver.stationLocation = LocationRow(
            entityID: Self.buildingEntity, chunkIndex: 0, x: 100_000, z: 100_000, dimension: 7 // interior
        )
        driver.ownPosition = MobileEntityRow(
            entityID: 1000, chunkIndex: 0, timestampMs: 1,
            locationX: 101_000, locationZ: 101_000,
            destinationX: 101_000, destinationZ: 101_000, dimension: 1
        )
        let machine = makeMachine(
            driver: driver,
            claimBuildings: SimulatedClaimBuildings(scripts: [Self.buildingsScript()])
        )
        await signInAndSync(machine)

        await machine.ingest(Intent.TapCraft(craftEntityID: Self.craftEntity))
        let rep = await ClaimBuildingsTests().collectUntil(machine) { rep in
            if case .session(let session) = rep, let banner = session.craftBanner,
               case .failed = banner.state { return true }
            return false
        }
        if case .session(let session) = rep, let banner = session.craftBanner,
           case .failed(let message) = banner.state {
            #expect(message.contains("Interior stations"))
        }
        #expect(driver.moves.isEmpty) // no move was attempted
        #expect(driver.startCalls.isEmpty)
        await machine.ingest(Intent.SignOut())
    }
}

extension CraftDriverTests {

    /// Backgrounding pauses a running drive; foregrounding resumes it —
    /// but only the background-paused one (user/stamina pauses stay).
    @Test func backgroundingPausesAndForegroundResumes() async throws {
        let driver = ScriptedCraftDriver()
        driver.stationLocation = LocationRow(
            entityID: Self.buildingEntity, chunkIndex: 0, x: 100_000, z: 100_000, dimension: 1
        )
        driver.ownPosition = MobileEntityRow(
            entityID: 1000, chunkIndex: 0, timestampMs: 1,
            locationX: 101_000, locationZ: 101_000,
            destinationX: 101_000, destinationZ: 101_000, dimension: 1
        )
        driver.queueContinue(.success(Self.receipt(progress: 15)))
        driver.queueContinue(.success(Self.receipt(progress: 25)))
        driver.queueContinue(.success(Self.receipt(progress: 40)))
        let machine = makeMachine(
            driver: driver,
            claimBuildings: SimulatedClaimBuildings(scripts: [Self.buildingsScript()])
        )
        await signInAndSync(machine)

        await machine.ingest(Intent.TapCraft(craftEntityID: Self.craftEntity))
        _ = await ClaimBuildingsTests().collectUntil(machine) { rep in
            Self.banner(of: rep)?.effortDone == 15
        }

        // Background mid-drive: the loop cancels, the banner shows a
        // user-resumable pause.
        await machine.ingest(Intent.AppBackgrounded())
        _ = await ClaimBuildingsTests().collectUntil(machine) { rep in
            if case .session(let session) = rep, let banner = session.craftBanner,
               case .paused(false) = banner.state { return true }
            return false
        }
        let pausedStarts = driver.startCalls.count

        // Foreground: the drive picks up on its own and finishes.
        await machine.ingest(Intent.AppForegrounded())
        _ = await ClaimBuildingsTests().collectUntil(machine) { rep in
            Self.banner(of: rep)?.state == .completed
        }
        #expect(driver.startCalls.count > pausedStarts)
        await machine.ingest(Intent.SignOut())
    }
}
