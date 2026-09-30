import Foundation
import Testing
import BSATN
@testable import BitMeCore

/// The prospection watch (X-Ray's pending-prospection overlay): the
/// `prospecting_state` row decoder pinned byte-for-byte to rows streamed
/// live off the region mirror, the mutator/projection flow, and the poll
/// hook that starts and restarts the watch.
///
/// Field order and semantics are ground-truthed in
/// docs/protocol/prospecting.md (live session 2026-09-29/30, region 14).
@Suite struct ProspectionTests {

    // The player from the live watch session — same magnitude as the
    // captured region leg's own player.
    private static let player: UInt64 = 1_297_036_692_699_996_362

    /// Byte-level BSATN builder (field order = schema order).
    private struct Wire {
        var data = Data()
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        mutating func u64(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
        mutating func f32(_ v: Float) { u32(v.bitPattern) }
    }

    private static func stateRow(
        entityID: UInt64 = ProspectionTests.player,
        prospectingID: Int32 = 1_318_037_307, // Berserker Mushroom Hunt
        trail: UInt64 = 0x00E0_0001_03C3_8F12,
        completed: Int32 = 1, ongoing: Int32 = 1, total: Int32 = 5,
        angles: [Float] = [-0.23385617, 0.087734714],
        micros: Int64 = 1_790_728_513_575_000,
        contribution: Int32 = 3,
        toNextNode: Float = 40.992
    ) -> Data {
        var w = Wire()
        w.u64(entityID)
        w.i32(prospectingID)
        w.u64(trail)
        w.i32(completed)
        w.i32(ongoing)
        w.i32(total)
        w.u32(UInt32(angles.count))
        for a in angles { w.f32(a) }
        w.i64(micros)
        w.i32(contribution)
        w.f32(toNextNode)
        return w.data
    }

    // MARK: - Row decode

    @Test func prospectingStateRowDecodesInSchemaOrder() throws {
        let data = Self.stateRow()
        let row = try ProspectingStateRow(reader: BSATNReader(data: data))
        #expect(row.entityID == Self.player)
        #expect(row.prospectingID == 1_318_037_307)
        #expect(row.crumbTrailEntityID == 0x00E0_0001_03C3_8F12)
        #expect(row.completedSteps == 1)
        #expect(row.ongoingStep == 1)
        #expect(row.totalSteps == 5)
        #expect(row.nextCrumbAngles.count == 2)
        #expect(row.nextCrumbAngles[0] == -0.23385617)
        #expect(row.nextCrumbAngles[1] == 0.087734714)
        #expect(row.lastProspectionMicros == 1_790_728_513_575_000)
        #expect(row.contribution == 3)
        #expect(row.toNextNode == 40.992)
    }

    @Test func prospectingStateRowDecodeHandlesEmptyAngleArray() throws {
        // The mirror never sent an empty array in the verified sessions,
        // but the decoder must not trap if the server ever does.
        let data = Self.stateRow(angles: [])
        let row = try ProspectingStateRow(reader: BSATNReader(data: data))
        #expect(row.nextCrumbAngles.isEmpty)
        #expect(row.toNextNode == 40.992)
    }

    // MARK: - Mutator

    /// A session with the prospection watch already pinned to a region
    /// (the mutator's guard) — for the ProspectionChanged tests.
    private static func sessionWithProspection(
        region: Int = 14
    ) -> EphemeralState {
        var ephemeral = EphemeralState()
        var session = EphemeralState.Session(
            entityID: String(ProspectionTests.player), loop: CancellableTask(),
            streamLoop: CancellableTask()
        )
        session.prospectionRegion = region
        // The snapshot is the fix-origin source (the latest poll position).
        session.snapshot = pollSnapshot(region: region)
        ephemeral.session = session
        return ephemeral
    }

    /// A session whose watch has not started yet — for the poll-hook tests.
    private static func sessionForPoll() -> (EphemeralState, SessionSnapshot) {
        var ephemeral = EphemeralState()
        ephemeral.session = EphemeralState.Session(
            entityID: String(ProspectionTests.player), loop: CancellableTask(),
            streamLoop: CancellableTask()
        )
        return (ephemeral, pollSnapshot(region: 14))
    }

    private static func pollSnapshot(
        region: Int, signedIn: Bool = true, atX: Double = 24_404, atZ: Double = 21_227
    ) -> SessionSnapshot {
        let signedInJSON = signedIn ? "true" : "false"
        let position = signedIn
            ? """
            , "position": {"world_x": \(atX), "world_z": \(atZ), "tile_x": \(Int(atX)),
                           "tile_z": \(Int(atZ)), "destination_world_x": \(atX),
                           "destination_world_z": \(atZ), "dimension": 1,
                           "is_walking": false, "timestamp_ms": 1790728500000,
                           "age_ms": 0}
            """
            : ""
        let json = """
        {"found": true, "player_entity_id": "\(ProspectionTests.player)",
         "signed_in": \(signedInJSON), "region": \(region)\(position),
         "buffs": [], "actions": [], "activity_spawns": [],
         "server_time_ms": 1790728501000}
        """
        return try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    }

    @Test func prospectionUpdatePopulatesStateAndMapRep() {
        let ephemeral = Self.sessionWithProspection()
        let mutator = Intent.ProspectionChanged(events: [
            .updated(try! ProspectingStateRow(reader: BSATNReader(data: Self.stateRow()))),
        ])
        let change = mutator.mutate(persistent: PersistentState(), ephemeral: ephemeral)
        guard let session = change.ephemeralState?.session else {
            Issue.record("expected the session to survive the mutation")
            return
        }
        #expect(session.prospection.isActive)
        #expect(session.prospection.prospectingID == 1_318_037_307)
        #expect(session.prospection.totalSteps == 5)
        #expect(session.prospection.nextCrumbAngles.count == 2)
        #expect(session.prospection.lastProspectionMs == 1_790_728_513_575.0)
        // The fix origin: where the player stood at prospection time (the
        // snapshot position at row arrival), not a moving anchor.
        #expect(session.prospection.fixX == 24_404)
        #expect(session.prospection.fixZ == 21_227)

        // The map projection: cone out to the measured range, crumb-radius
        // circle, 1-based step counter.
        let rep = MapRep.from(ephemeral: change.ephemeralState ?? ephemeral)
        let prospect = rep.prospect
        #expect(prospect != nil)
        #expect(prospect!.fixX == 24_404)
        #expect(prospect!.fixZ == 21_227)
        #expect(abs(prospect!.bearingLo - Double(-0.23385617)) < 1e-6)
        #expect(abs(prospect!.bearingHi - Double(0.087734714)) < 1e-6)
        #expect(abs(prospect!.distance - 40.992) < 1e-4)
        #expect(prospect?.crumbRadius == GameConfig.shared.prospectCrumbRadius)
        #expect(prospect?.isFinalStep == false)
        #expect(prospect?.step == 2)
        #expect(prospect?.totalSteps == 5)
    }

    @Test func prospectionFinalStepIsPreciseNeedle() {
        let ephemeral = Self.sessionWithProspection()
        let mutator = Intent.ProspectionChanged(events: [
            .updated(try! ProspectingStateRow(reader: BSATNReader(data: Self.stateRow(
                completed: 3, ongoing: 3, total: 4,
                angles: [-2.951465], toNextNode: 40.039
            )))),
        ])
        let change = mutator.mutate(persistent: PersistentState(), ephemeral: ephemeral)
        let rep = MapRep.from(ephemeral: change.ephemeralState ?? ephemeral)
        #expect(rep.prospect?.isFinalStep == true)
        #expect(rep.prospect?.bearingLo == rep.prospect?.bearingHi)
        #expect(rep.prospect?.step == 4)
        #expect(rep.prospect?.totalSteps == 4)
    }

    @Test func prospectionFixStaysPutUntilTheNextFix() {
        let ephemeral = Self.sessionWithProspection()
        let apply = { (events: [ProspectionEvent], state: EphemeralState) in
            Intent.ProspectionChanged(events: events)
                .mutate(persistent: PersistentState(), ephemeral: state)
        }
        let rowAt = { (micros: Int64) in
            try! ProspectingStateRow(reader: BSATNReader(data: Self.stateRow(micros: micros)))
        }

        // Fix 1: captured at the snapshot position (24404, 21227).
        let micros1: Int64 = 1_790_728_500_000_000
        var change = apply([.updated(rowAt(micros1))], ephemeral)

        // The player walks on; the row is re-delivered (contribution-only
        // rewrite, same server timestamp) — the fix must not move.
        var walked = change.ephemeralState!
        if var session = walked.session {
            session.snapshot = Self.pollSnapshot(region: 14, atX: 24_500, atZ: 21_300)
            walked.session = session
        }
        change = apply([.updated(rowAt(micros1))], walked)
        #expect(change.ephemeralState?.session?.prospection.fixX == 24_404)
        #expect(MapRep.from(ephemeral: change.ephemeralState ?? walked).prospect?.fixX == 24_404)

        // The next prospection re-anchors at the new position.
        let micros2: Int64 = 1_790_728_504_000_000
        change = apply([.updated(rowAt(micros2))], change.ephemeralState ?? walked)
        #expect(change.ephemeralState?.session?.prospection.fixX == 24_500)
        #expect(change.ephemeralState?.session?.prospection.fixZ == 21_300)
        #expect(MapRep.from(ephemeral: change.ephemeralState ?? walked).prospect?.fixZ == 21_300)
    }

    @Test func prospectionEndedClearsOverlay() {
        let ephemeral = Self.sessionWithProspection()
        let mutator = Intent.ProspectionChanged(events: [
            .updated(try! ProspectingStateRow(reader: BSATNReader(data: Self.stateRow()))),
        ])
        var change = mutator.mutate(persistent: PersistentState(), ephemeral: ephemeral)
        #expect(change.ephemeralState?.session?.prospection.isActive == true)

        let ended = Intent.ProspectionChanged(events: [.ended])
        change = ended.mutate(persistent: PersistentState(), ephemeral: change.ephemeralState ?? ephemeral)
        guard let session = change.ephemeralState?.session else {
            Issue.record("expected the session to survive the mutation")
            return
        }
        #expect(!session.prospection.isActive)
        #expect(MapRep.from(ephemeral: change.ephemeralState ?? ephemeral).prospect == nil)
    }

    // MARK: - Poll hook (watch start / region restart)

    private static func polledIntent(_ snapshot: SessionSnapshot) -> Intent.SessionPolled {
        Intent.SessionPolled(
            snapshot: snapshot,
            carrier: SessionLoopCarrier(),
            polledAtMs: 1_790_728_501_000
        )
    }

    @Test func pollStartsWatchOncePerRegion() {
        let (ephemeral, snapshot) = Self.sessionForPoll()
        let mutator = Self.polledIntent(snapshot)

        let first = mutator.mutate(persistent: PersistentState(), ephemeral: ephemeral)
        guard let session = first.ephemeralState?.session else {
            Issue.record("expected the session to survive the poll")
            return
        }
        #expect(session.prospectionRegion == 14)
        #expect(session.prospectionLoop != nil)
        let started = first.activities.compactMap { $0 as? Activity.ProspectionWatch }
        #expect(started.count == 1)
        #expect(started.first?.region == 14)
        #expect(started.first?.playerEntityID == Self.player)

        // Same region again: no restart, no second watch.
        let second = mutator.mutate(persistent: PersistentState(), ephemeral: first.ephemeralState!)
        #expect(second.ephemeralState?.session?.prospectionRegion == 14)
        #expect(second.activities.compactMap { $0 as? Activity.ProspectionWatch }.isEmpty)

        // A region transfer restarts the watch.
        var moved = snapshot
        let movedJSON = """
        {"found": true, "player_entity_id": "\(ProspectionTests.player)",
         "signed_in": true, "region": 3,
         "position": {"world_x": 100.0, "world_z": 100.0, "tile_x": 100,
                      "tile_z": 100, "destination_world_x": 100.0,
                      "destination_world_z": 100.0, "dimension": 1,
                      "is_walking": false, "timestamp_ms": 1790728500000,
                      "age_ms": 0},
         "buffs": [], "actions": [], "activity_spawns": [], "server_time_ms": 1790728502000}
        """
        moved = try! JSONDecoder().decode(SessionSnapshot.self, from: Data(movedJSON.utf8))
        let third = Self.polledIntent(moved).mutate(
            persistent: PersistentState(), ephemeral: second.ephemeralState!
        )
        let restarted = third.activities.compactMap { $0 as? Activity.ProspectionWatch }
        #expect(restarted.count == 1)
        #expect(restarted.first?.region == 3)
        #expect(third.ephemeralState?.session?.prospectionRegion == 3)
    }

    @Test func offlinePollDoesNotStartWatch() {
        let (ephemeral, _) = Self.sessionForPoll()
        let offline = Self.pollSnapshot(region: 14, signedIn: false)
        let change = Self.polledIntent(offline).mutate(persistent: PersistentState(), ephemeral: ephemeral)
        #expect(change.ephemeralState?.session?.prospectionRegion == nil)
        #expect(change.activities.compactMap { $0 as? Activity.ProspectionWatch }.isEmpty)
    }
}
