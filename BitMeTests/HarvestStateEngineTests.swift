import Testing
import Foundation
@testable import BitMe

/// The tutorial-2 checklist as executable tests: action liveness, citric
/// insert detection, lingering-buff exclusion, stamina projection, pacing.
struct HarvestStateEngineTests {

    private let config = GameConfig.shared

    // MARK: - Fixtures

    private func snapshot(
        actions: [PlayerAction] = [],
        buffs: [Buff] = [],
        stamina: Stamina? = nil,
        target: Target? = nil,
        spawns: [ActivitySpawn] = []
    ) -> SessionSnapshot {
        SessionSnapshot(
            found: true,
            playerEntityID: "1000",
            username: "Whisper",
            signedIn: true,
            region: 7,
            position: nil,
            claim: nil,
            stamina: stamina,
            buffs: buffs,
            actions: actions,
            target: target,
            activitySpawns: spawns,
            serverTimeMs: 0
        )
    }

    private func action(
        type: String = "Extract",
        start: Int64,
        duration: Int64,
        target: String? = "5000",
        result: String = "Success",
        cancelled: Bool = false
    ) -> PlayerAction {
        PlayerAction(
            autoID: "1", actionType: type, layer: "Base",
            startTimeMs: start, durationMs: duration,
            endsAtMs: start + duration, targetEntityID: target,
            recipeID: nil, lastActionResult: result, clientCancel: cancelled
        )
    }

    private func spawn(
        id: String,
        resource: Int,
        expiresAt: Int64?,
        spawnedAt: Int64 = 1_000_000
    ) -> ActivitySpawn {
        ActivitySpawn(
            entityID: id, resourceID: resource, name: "test",
            health: nil, maxHealth: 500, location: nil,
            spawnedAtMs: spawnedAt, expiresAtMs: expiresAt
        )
    }

    // MARK: - Action lifecycle

    @Test func completedActionIsNotLive() {
        let now = 10_000.0
        // Ended 5s ago.
        let finished = action(start: 4_000, duration: 1_000)
        let actions = HarvestStateEngine.liveActions(in: snapshot(actions: [finished]), nowMs: now)
        #expect(actions.isEmpty)
        #expect(!HarvestStateEngine.isHarvesting(actions))
    }

    @Test func runningExtractIsLive() {
        let now = 4_500.0
        let running = action(start: 4_000, duration: 1_000)
        let actions = HarvestStateEngine.liveActions(in: snapshot(actions: [running]), nowMs: now)
        #expect(actions.count == 1)
        #expect(HarvestStateEngine.isHarvesting(actions))
        #expect(actions[0].progress > 0.4 && actions[0].progress < 0.6)
    }

    @Test func cancelledOrFailedActionIsNotLive() {
        let now = 4_500.0
        let cancelled = action(start: 4_000, duration: 1_000, cancelled: true)
        let failed = action(start: 4_000, duration: 1_000, result: "Failure")
        let actions = HarvestStateEngine.liveActions(
            in: snapshot(actions: [cancelled, failed]), nowMs: now)
        #expect(actions.isEmpty)
    }

    // MARK: - Pacing estimator

    @Test func pacingLearnsFromHealthTicks() throws {
        var pacing = HarvestStateEngine.PacingEstimator()
        // 10 points drained per second, steady → estimate should converge
        // near 100 ms/point.
        var now = 0.0
        var health = 500.0
        pacing.observe(target: makeTarget(entity: "5000", health: health), nowMs: now)
        for _ in 0..<20 {
            now += 1_000
            health -= 10
            pacing.observe(target: makeTarget(entity: "5000", health: health), nowMs: now)
        }
        let estimate = try #require(pacing.msPerHealthPoint)
        #expect(abs(estimate - 100.0) < 5.0)
    }

    @Test func pacingSurvivesNullHealthPollAndResetsOnTargetSwitch() {
        var pacing = HarvestStateEngine.PacingEstimator()
        pacing.observe(target: makeTarget(entity: "5000", health: 500), nowMs: 0)
        pacing.observe(target: makeTarget(entity: "5000", health: 490), nowMs: 1_000)
        // First poll after targeting a new entity: null health (documented
        // relay behavior) — then the estimate restarts from the new target.
        pacing.observe(target: makeTarget(entity: "6000", health: nil), nowMs: 2_000)
        pacing.observe(target: makeTarget(entity: "6000", health: 300), nowMs: 3_000)
        pacing.observe(target: makeTarget(entity: "6000", health: 290), nowMs: 4_000)
        #expect(pacing.msPerHealthPoint != nil)
    }

    private func makeTarget(entity: String, health: Double?) -> Target {
        Target(
            entityID: entity, resourceID: 38, name: "bush",
            health: health, maxHealth: 500,
            despawnTimeSecs: nil, respawnTimeSecs: nil, location: nil
        )
    }

    // MARK: - Citric detection

    @Test func citricInsertIsDetected() {
        let citric = spawn(id: "9000", resource: 1_688_062_540, expiresAt: 1_030_000)
        let current = snapshot(spawns: [citric])
        let now = 1_005_000.0

        // Insert: not present in the previous snapshot.
        let alert = HarvestStateEngine.detectCitric(
            previous: nil, current: current,
            citricResourceIDs: config.citricResourceIDs,
            fallbackWindowMs: config.citricFallbackWindowMs,
            nowMs: now
        )
        #expect(alert != nil)
        #expect(alert?.isNewlySpawned == true)
        #expect(alert?.remainingMs(nowMs: now) == 25_000)
    }

    @Test func citricKnownFromPreviousSnapshotIsNotNew() {
        let citric = spawn(id: "9000", resource: 1_688_062_540, expiresAt: 1_030_000)
        let prev = snapshot(spawns: [citric])
        let current = snapshot(spawns: [citric])
        let alert = HarvestStateEngine.detectCitric(
            previous: prev, current: current,
            citricResourceIDs: config.citricResourceIDs,
            fallbackWindowMs: config.citricFallbackWindowMs,
            nowMs: 1_006_000
        )
        #expect(alert?.isNewlySpawned == false)
    }

    @Test func expiredCitricIsIgnoredAndFallbackWindowApplies() {
        // No expires_at_ms on the wire → fallback window from spawn time.
        let noTimer = spawn(id: "9001", resource: 65_901_922, expiresAt: nil, spawnedAt: 1_000_000)
        let expired = spawn(id: "9002", resource: 1_688_062_540, expiresAt: 1_000_500)
        let current = snapshot(spawns: [noTimer, expired])
        let alert = HarvestStateEngine.detectCitric(
            previous: nil, current: current,
            citricResourceIDs: config.citricResourceIDs,
            fallbackWindowMs: 30_000,
            nowMs: 1_020_000
        )
        #expect(alert?.entityID == "9001")
        #expect(alert?.remainingMs(nowMs: 1_020_000) == 10_000)
    }

    @Test func nonCitricSpawnsDoNotAlert() {
        let bountiful = spawn(id: "8000", resource: 1_822_942_131, expiresAt: nil)
        let current = snapshot(spawns: [bountiful])
        let alert = HarvestStateEngine.detectCitric(
            previous: nil, current: current,
            citricResourceIDs: config.citricResourceIDs,
            fallbackWindowMs: 30_000,
            nowMs: 1_000_001
        )
        #expect(alert == nil)
    }

    // MARK: - Food buffs

    @Test func expiredLingeringBuffDoesNotCountAsActive() {
        let nowMs = 2_000_000.0
        let expiredLingering = Buff(
            buffID: 42, startTimestamp: 1_000,
            duration: 500, values: [] // expired long ago
        )
        let state = HarvestStateEngine.foodBuffState(
            in: snapshot(buffs: [expiredLingering]),
            foodBuffIDs: [42], nowMs: nowMs
        )
        #expect(state.active == false)
    }

    @Test func stackedFoodBuffsTakeLatestExpiry() {
        // Realistic anchor: relay now = 1_788_628_492_000 ms; buffs started
        // at unix sec 1_788_628_492, expiring after 60 s and 600 s.
        let nowMs = 1_788_628_492_000.0
        let startSec: Int64 = 1_788_628_492
        let soon = Buff(buffID: 42, startTimestamp: startSec, duration: 60, values: [])
        let later = Buff(buffID: 42, startTimestamp: startSec, duration: 600, values: [])
        let state = HarvestStateEngine.foodBuffState(
            in: snapshot(buffs: [soon, later]),
            foodBuffIDs: [42], nowMs: nowMs
        )
        #expect(state.active == true)
        #expect(state.expiresAtUnixSec == startSec + 600)
        #expect(abs(state.remainingMs! - 600_000) < 1_000) // formatter ms rounding
    }

    @Test func unrelatedBuffIdsAreIgnored() {
        let other = Buff(buffID: 999, startTimestamp: 2_000_000, duration: 600, values: [])
        let state = HarvestStateEngine.foodBuffState(
            in: snapshot(buffs: [other]), foodBuffIDs: [42], nowMs: 2_000_000
        )
        #expect(state.active == false)
    }

    // MARK: - Stamina projection

    @Test func staminaProjectsForwardToFullAt() throws {
        let nowMs = 1_788_628_492_000.0
        // Anchor: decreased 60s ago at 300/500; regen 1/sec after a 10s
        // delay → projected 300 + 50 = 350; full 150 ticks later.
        let rules = HarvestStateEngine.RegenRules(
            delayAfterDecreaseMs: 10_000, tickMs: 1_000, perTick: 1
        )
        let anchorMs = nowMs - 60_000
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let anchorString = formatter.string(
            from: Date(timeIntervalSince1970: anchorMs / 1_000)
        )
        let parsed = try #require(RFC3339.msSinceEpoch(anchorString))
        #expect(abs(parsed - anchorMs) < 1_000) // formatter rounds to ms

        let projection = HarvestStateEngine.staminaProjection(
            in: snapshot(stamina: Stamina(
                current: 300, max: 500, maxHealth: 200, lastDecreaseAt: anchorString
            )),
            rules: rules, nowMs: nowMs
        )
        let result = try #require(projection)
        #expect(result.projected == 350) // 50 regen ticks elapsed after delay
        #expect(result.fullAtMs == nowMs + 150_000)
    }

    @Test func staminaFullAndAnchorlessCases() {
        let rules = HarvestStateEngine.RegenRules(
            delayAfterDecreaseMs: 10_000, tickMs: 1_000, perTick: 1
        )
        let now = 5_000.0
        let full = HarvestStateEngine.staminaProjection(
            in: snapshot(stamina: Stamina(
                current: 500, max: 500, maxHealth: 200, lastDecreaseAt: nil)),
            rules: rules, nowMs: now
        )
        #expect(full?.pct == 1)

        let noAnchor = HarvestStateEngine.staminaProjection(
            in: snapshot(stamina: Stamina(
                current: 100, max: 500, maxHealth: 200, lastDecreaseAt: nil)),
            rules: rules, nowMs: now
        )
        #expect(noAnchor?.fullAtMs == nil)
        #expect(noAnchor?.projected == 100)

        #expect(HarvestStateEngine.staminaProjection(
            in: snapshot(stamina: nil), rules: rules, nowMs: now
        ) == nil)
    }
}
