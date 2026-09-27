import Testing
import Foundation
import BSATN
import SpacetimeDB
@testable import BitMeCore

/// The claim-buildings sync (Pocket Crafter's workstation domain): the
/// schema-pinned region row decoders, and the machine flow from the
/// region leg's arrival through the live workstation projection.
@Suite(.serialized) // staged collects share the main actor; no self-contention
@MainActor
struct ClaimBuildingsTests {

    // MARK: - BSATN fixtures

    /// Little-endian row builder — bytes appended in the wire order the
    /// decoders pin. (Mutation-style building keeps the type-checker out
    /// of long `Data + Data` chains.)
    private struct Wire {
        var data = Data()

        mutating func u64(_ v: UInt64) { le(v) }
        mutating func u32(_ v: UInt32) { le(v) }
        mutating func i32(_ v: Int32) { le(v) }
        mutating func i64(_ v: Int64) { le(v) }
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func boolean(_ v: Bool) { data.append(v ? 1 : 0) }
        mutating func string(_ s: String) {
            u32(UInt32(s.utf8.count))
            data.append(contentsOf: s.utf8)
        }

        private mutating func le<T: FixedWidthInteger>(_ v: T) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
    }

    /// A `building_desc.functions` element — all 15 fields, wire order.
    private static func functionEntry(
        into w: inout Wire,
        craftingSlots: Int32 = 0, storageSlots: Int32 = 0,
        cargoSlots: Int32 = 0, refiningSlots: Int32 = 0,
        refiningCargoSlots: Int32 = 0
    ) {
        w.i32(3) // function_type
        w.i32(1) // level
        w.i32(craftingSlots)
        w.i32(storageSlots)
        w.i32(cargoSlots)
        w.i32(refiningSlots)
        w.i32(refiningCargoSlots)
        w.i32(0) // item_slot_size
        w.i32(0) // cargo_slot_size
        w.i32(0) // trade_orders
        w.u32(0) // allowed_item_id_per_slot (empty array)
        w.i32(0) // concurrent_crafts_per_player
        w.boolean(false) // terraform
        w.i32(0) // housing_slots
        w.u32(0) // housing_income
    }

    /// A `building_desc` row body — id, functions, name; the trailing
    /// catalog fields stay absent, exactly where the decoder stops.
    private static func buildingDescRow(
        id: Int32, name: String,
        slots: [(crafting: Int32, storage: Int32, cargo: Int32, refining: Int32, refiningCargo: Int32)] = []
    ) -> Data {
        var w = Wire()
        w.i32(id)
        w.u32(UInt32(slots.count))
        for s in slots {
            functionEntry(
                into: &w,
                craftingSlots: s.crafting, storageSlots: s.storage,
                cargoSlots: s.cargo, refiningSlots: s.refining,
                refiningCargoSlots: s.refiningCargo
            )
        }
        w.string(name)
        return w.data
    }

    // MARK: - Decoder tests

    @Test func buildingStateRowDecodesInSchemaOrder() throws {
        var w = Wire()
        w.u64(3001); w.u64(2000); w.i32(2); w.i32(405); w.u64(1000)
        let row = try BuildingStateRow(reader: BSATNReader(data: w.data))
        #expect(row.entityID == 3001)
        #expect(row.claimEntityID == 2000)
        #expect(row.directionIndex == 2)
        #expect(row.buildingDescriptionID == 405)
        #expect(row.constructedByPlayerEntityID == 1000)
        #expect(row.primaryKey == 3001)
    }

    @Test func passiveCraftRowDecodesStatusAndOptionalSlot() throws {
        // slot = Some(2): tag 0 (some) + u32
        var withSlot = Wire()
        withSlot.u64(5001); withSlot.u64(1000); withSlot.i32(77); withSlot.u64(3001)
        withSlot.i64(1_788_600_000_000_000); withSlot.u8(1); withSlot.u8(0); withSlot.u32(2)
        let row = try PassiveCraftRow(reader: BSATNReader(data: withSlot.data))
        #expect(row.entityID == 5001)
        #expect(row.ownerEntityID == 1000)
        #expect(row.recipeID == 77)
        #expect(row.buildingEntityID == 3001)
        #expect(row.startedAtMicros == 1_788_600_000_000_000)
        #expect(row.status == .processing)
        #expect(row.slot == 2)

        // slot = None: tag 1, status tag 2 = complete
        var withoutSlot = Wire()
        withoutSlot.u64(5002); withoutSlot.u64(1000); withoutSlot.i32(77); withoutSlot.u64(3001)
        withoutSlot.i64(0); withoutSlot.u8(2); withoutSlot.u8(1)
        let noneRow = try PassiveCraftRow(reader: BSATNReader(data: withoutSlot.data))
        #expect(noneRow.status == .complete)
        #expect(noneRow.slot == nil)
    }

    @Test func buildingDescClassifiesCraftingAndStorage() throws {
        let hut = try RegionGamedataDecoder.buildingDesc(
            Self.buildingDescRow(id: 1007, name: "Storage Hut", slots: [(0, 18, 0, 0, 0)])
        )
        #expect(hut.id == 1007)
        #expect(hut.name == "Storage Hut")
        #expect(!hut.isCrafting)
        #expect(hut.isStorage)

        let refinery = try RegionGamedataDecoder.buildingDesc(
            Self.buildingDescRow(id: 1200, name: "Refinery", slots: [(0, 0, 0, 2, 4)])
        )
        #expect(refinery.isCrafting)
        #expect(!refinery.isStorage) // refining cargo is not item/cargo pockets

        let totem = try RegionGamedataDecoder.buildingDesc(
            Self.buildingDescRow(id: 405, name: "Settlement Totem")
        )
        #expect(!totem.isCrafting)
        #expect(!totem.isStorage)
    }

    @Test func projectionDropsCompletedCraftsAndCapsTheList() {
        var session = EphemeralState.Session(
            entityID: "1000", loop: CancellableTask(), streamLoop: CancellableTask()
        )
        session.buildings.status = .live
        session.buildings.playerEntityID = 1000
        session.buildings.buildings = [
            3001: RegionBuilding(entityID: 3001, claimEntityID: 2000, buildingDescriptionID: 1200)
        ]
        var crafts: [UInt64: RegionCraft] = [
            1: RegionCraft(
                entityID: 1, ownerEntityID: 1000, buildingEntityID: 3001, recipeID: 77,
                kind: .passive(status: .complete, startedAtMicros: 0)
            )
        ]
        for id: UInt64 in 2...12 {
            crafts[id] = RegionCraft(
                entityID: id, ownerEntityID: 2002, buildingEntityID: 3001, recipeID: 77,
                kind: .passive(status: .queued, startedAtMicros: 0)
            )
        }
        session.buildings.crafts = crafts

        let projected = ViewRep.workstations(from: session, cap: 3)
        // The completed craft is dropped everywhere; 11 queued survive the
        // filter, 3 fit the cap, 8 overflow.
        #expect(projected.buildings[0].craftCount == 11)
        #expect(projected.crafts.count == 3)
        #expect(!projected.crafts.contains { $0.phase == .complete })
        #expect(projected.craftsOverflow == 8)
    }

    @Test func eventBufferPoolsRowEventsAndFlushesStatusEvents() async {
        // Lock-protected collector — flush callbacks arrive on timer tasks.
        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private var _flushes: [[ClaimBuildingsEvent]] = []
            func append(_ events: [ClaimBuildingsEvent]) { lock.withLock { _flushes.append(events) } }
            var all: [ClaimBuildingsEvent] { lock.withLock { _flushes.flatMap { $0 } } }
            var count: Int { lock.withLock { _flushes.count } }
        }
        let collected = Collector()
        let buffer = RegionBuildingsClient.EventBuffer(flushDelay: 0.05) { events in
            collected.append(events)
        }

        // Row events pool until a status event flushes immediately — and
        // the flush carries them, proving they were held back rather than
        // delivered per push. (No wall-clock "nothing yet" probe: this
        // suite's parallel load stalls tasks unpredictably.)
        buffer.push(.buildingChanged(RegionBuilding(entityID: 3001, claimEntityID: 2000, buildingDescriptionID: 1200)))
        buffer.push(.craftChanged(RegionCraft(
            entityID: 5001, ownerEntityID: 1000, buildingEntityID: 3001, recipeID: 77,
            kind: .passive(status: .processing, startedAtMicros: 0)
        )))
        buffer.push(.live)
        #expect(collected.count == 1)
        #expect(collected.all.count == 3)
        #expect(collected.all.contains(.live))

        // Later row events flush on the window (deadline generous for the
        // same load reasons).
        buffer.push(.nicknameChanged(entityID: 3001, nickname: "Millie"))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && collected.count < 2 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(collected.count == 2)
        #expect(collected.all.last == .nicknameChanged(entityID: 3001, nickname: "Millie"))
    }

    @Test func recipeRowStopsAfterName() throws {
        var w = Wire()
        w.i32(77); w.string("Oak Plank")
        let decoded = try RegionGamedataDecoder.recipe(w.data)
        #expect(decoded.id == 77)
        #expect(decoded.name == "Oak Plank")
    }

    // MARK: - Machine flow

    /// A fabricated region leg — a not-connected SDK client is enough; the
    /// identity is all the machine flow needs.
    private static func makeLeg() -> RegionLeg {
        let client = try! SpacetimeDBClient(host: "wss://region.test.invalid", db: "bitcraft-live-14")
        return RegionLeg(client: client)
    }

    private static func syncScript() -> SimulatedClaimBuildings.Script {
        let gamedata = BuildingGamedata(
            buildings: [
                1007: BuildingDescInfo(id: 1007, name: "Storage Hut", functions: [
                    BuildingFunctionInfo(
                        functionType: 3, level: 1, craftingSlots: 0, storageSlots: 18,
                        cargoSlots: 0, refiningSlots: 0, refiningCargoSlots: 0
                    )
                ]),
                1200: BuildingDescInfo(id: 1200, name: "Sawmill", functions: [
                    BuildingFunctionInfo(
                        functionType: 1, level: 2, craftingSlots: 4, storageSlots: 0,
                        cargoSlots: 0, refiningSlots: 0, refiningCargoSlots: 0
                    )
                ]),
            ],
            recipeNames: [77: "Oak Plank"]
        )
        return SimulatedClaimBuildings.Script(events: [
            .gamedata(gamedata),
            .syncing,
            .live,
            .claim(ClaimHeader(entityID: 2000, name: "Emberfall", ownerPlayerEntityID: 1000, neutral: false)),
            .buildingChanged(RegionBuilding(entityID: 3001, claimEntityID: 2000, buildingDescriptionID: 1200)),
            .buildingChanged(RegionBuilding(entityID: 3002, claimEntityID: 2000, buildingDescriptionID: 1007)),
            .buildingChanged(RegionBuilding(entityID: 3003, claimEntityID: 2000, buildingDescriptionID: 999)),
            .nicknameChanged(entityID: 3001, nickname: "Millie"),
            .craftChanged(RegionCraft(
                entityID: 5001, ownerEntityID: 1000, buildingEntityID: 3001, recipeID: 77,
                kind: .passive(status: .processing, startedAtMicros: 0)
            )),
            .craftChanged(RegionCraft(
                entityID: 5002, ownerEntityID: 2002, buildingEntityID: 3001, recipeID: 77,
                kind: .active(progress: 3, craftCount: 5, preparation: false, lockExpiresAtMicros: 0)
            )),
            // Completed passive crafts are collected in game — the
            // projection drops them instead of listing them.
            .craftChanged(RegionCraft(
                entityID: 5003, ownerEntityID: 1000, buildingEntityID: 3001, recipeID: 77,
                kind: .passive(status: .complete, startedAtMicros: 0)
            )),
        ], hold: true)
    }

    @Test func regionLegStartsTheSyncAndProjectsTheWorkstations() async throws {
        let leg = Self.makeLeg()
        let claimBuildings = SimulatedClaimBuildings(scripts: [Self.syncScript()])
        let globalSession = AccountDrivenSignInTests.SimulatedGlobalSession(
            scripts: [.init(events: [.regionLeg(leg), .established], hold: true)]
        )
        let machine = AccountDrivenSignInTests().makeMachine(
            link: .init(outcome: .player(AccountDrivenSignInTests.player)),
            globalSession: globalSession,
            claimBuildings: claimBuildings
        )

        await machine.start()

        // Email → code → the account link lands on the gate. The code can
        // only be submitted once the request has landed it in `awaitingCode`
        // (the mutate no-ops otherwise, like the real screen's disabled form).
        await machine.ingest(Intent.StartBitCraftSignIn(email: "crafter@example.com"))
        _ = await collectUntil(machine) { rep in
            if case .bitCraftSignIn(let signIn) = rep, case .awaitingCode = signIn.phase { return true }
            return false
        }
        await machine.ingest(Intent.SubmitAccessCode(code: "123456"))
        _ = await collectUntil(machine) { rep in
            if case .gameSessionPrompt(let prompt) = rep, prompt.claimName != nil { return true }
            return false
        }

        // Take the game session: the region leg arrives, the sync starts,
        // and the joined workstations land in the session projection. Events
        // arrive as individual intents (one rep each) — wait for the
        // script's terminal state, not the first `.live`.
        await machine.ingest(Intent.SignInGameSession())
        let matched = await collectUntil(machine) { rep in
            if case .session(let s) = rep, s.workstations.crafts.count == 2 { return true }
            return false
        }
        guard case .session(let sessionRep)? = matched else {
            Issue.record("expected a session rep with the projected workstations")
            return
        }
        let stations = sessionRep.workstations
        #expect(stations.status == .live)

        // The sync was asked about the claim the character stands in
        // (relay snapshot's entity id) and the account's own player.
        #expect(claimBuildings.requests == [.init(claim: 2000, player: 1000)])
        #expect(claimBuildings.legs == [ObjectIdentifier(leg)])

        // Buildings: crafting first (nickname wins), then storage; the
        // unknown catalog id falls back to "Building <id>".
        #expect(stations.buildings.map(\.name) == ["Millie", "Storage Hut", "Building 3003"])
        #expect(stations.buildings.map(\.isCrafting) == [true, false, false])
        guard stations.buildings.count == 3 else {
            Issue.record("expected all three buildings in the projection")
            return
        }
        #expect(stations.buildings[0].craftCount == 2)
        #expect(stations.buildings[1].craftCount == 0)

        // Crafts: the player's own first, recipe and station joined; the
        // completed craft is excluded.
        #expect(stations.crafts.count == 2)
        #expect(!stations.crafts.contains { $0.phase == .complete })
        #expect(stations.crafts[0].mine == true)
        #expect(stations.crafts[0].recipeName == "Oak Plank")
        #expect(stations.crafts[0].stationName == "Millie")
        #expect(stations.crafts[0].phase == .processing)
        #expect(stations.crafts[1].mine == false)
        #expect(stations.crafts[1].phase == .active)
        #expect(stations.crafts[1].progress == 3)
        #expect(stations.crafts[1].craftCount == 5)
        await machine.ingest(Intent.SignOut()) // retire the loops
    }

    @Test func endedSessionTearsDownTheSync() async throws {
        let leg = Self.makeLeg()
        let claimBuildings = SimulatedClaimBuildings(scripts: [Self.syncScript()])
        let globalSession = AccountDrivenSignInTests.SimulatedGlobalSession(
            scripts: [.init(events: [.regionLeg(leg), .established], hold: true)]
        )
        let machine = AccountDrivenSignInTests().makeMachine(
            link: .init(outcome: .player(AccountDrivenSignInTests.player)),
            globalSession: globalSession,
            claimBuildings: claimBuildings
        )

        await machine.start()
        await machine.ingest(Intent.StartBitCraftSignIn(email: "crafter@example.com"))
        _ = await collectUntil(machine) { rep in
            if case .bitCraftSignIn(let signIn) = rep, case .awaitingCode = signIn.phase { return true }
            return false
        }
        await machine.ingest(Intent.SubmitAccessCode(code: "123456"))
        _ = await collectUntil(machine) { rep in
            if case .gameSessionPrompt(let prompt) = rep, prompt.claimName != nil { return true }
            return false
        }
        await machine.ingest(Intent.SignInGameSession())
        _ = await collectUntil(machine) { rep in
            if case .session(let s) = rep, s.workstations.crafts.count == 2 { return true }
            return false
        }

        // Another device takes the account's session: every held socket
        // closes, the app returns to the gate, and the buildings sync is
        // cancelled with it.
        globalSession.endHeld()
        _ = await collectUntil(machine) { rep in
            if case .gameSessionPrompt(let prompt) = rep, prompt.claimName != nil { return true }
            return false
        }
        #expect(await Self.waitForTermination(of: claimBuildings))
        await machine.ingest(Intent.SignOut()) // retire the loops
    }

    // MARK: - Helpers

    /// Collects ViewReps until `finished` matches (event-driven — see
    /// `RepCollecting.collect`; the timeout is a broken-flow backstop);
    /// returns the first matching rep.
    private func collectUntil(
        _ machine: StateMachine,
        until finished: @Sendable @escaping (ViewRep) -> Bool,
        timeout: TimeInterval = 10
    ) async -> ViewRep? {
        let collector = AccountDrivenSignInTests.RepCollector()
        await RepCollecting.collect(
            machine,
            onRep: { collector.append($0) },
            until: finished, timeout: timeout
        )
        return collector.last(where: finished)
    }

    private static func waitForTermination(
        of sync: SimulatedClaimBuildings, timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sync.terminated > 0 { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return sync.terminated > 0
    }
}

/// Scripted claim-buildings sync (the region-leg subscription stream):
/// records the leg/claim/player it was asked about and answers from a
/// queued script; connections beyond the script queue hold silently.
final class SimulatedClaimBuildings: @unchecked Sendable {
    struct Request: Equatable {
        let claim: UInt64
        let player: UInt64
    }

    struct Script: Sendable {
        let events: [ClaimBuildingsEvent]
        let hold: Bool
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _legs: [ObjectIdentifier] = []
    private var _scripts: [Script]
    private var _terminated = 0
    private var _held: [AsyncStream<[ClaimBuildingsEvent]>.Continuation] = []

    init(scripts: [Script] = []) {
        self._scripts = scripts
    }

    var requests: [Request] { lock.withLock { _requests } }
    var legs: [ObjectIdentifier] { lock.withLock { _legs } }
    var terminated: Int { lock.withLock { _terminated } }

    func endHeld() {
        let held = lock.withLock {
            let copy = _held
            _held.removeAll()
            return copy
        }
        held.forEach { $0.finish() }
    }

    func open(leg: RegionLeg, claim: UInt64, player: UInt64) -> AsyncStream<[ClaimBuildingsEvent]> {
        let script = lock.withLock {
            _requests.append(Request(claim: claim, player: player))
            _legs.append(ObjectIdentifier(leg))
            return _scripts.isEmpty
                ? Script(events: [.live], hold: true)
                : _scripts.removeFirst()
        }
        return AsyncStream { continuation in
            for event in script.events {
                // One event per array — the production client pools ~0.5 s
                // of rows per flush; batching is invisible to these flows.
                continuation.yield([event])
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

