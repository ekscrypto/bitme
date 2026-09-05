import Foundation

/// Pure snapshot → screen-state logic (see docs/tutorial-harvest-session.md).
/// No clock reads, no network, no UI — every function takes `nowMs` on the
/// relay clock so results are deterministic and testable.
enum HarvestStateEngine {

    // MARK: - Action lifecycle

    struct LiveAction: Equatable, Sendable {
        let actionType: String
        let layer: String
        let targetEntityID: String?
        let recipeID: Int?
        let progress: Double // 0...1
        let endsInMs: Double
    }

    /// `actions` rows persist after completion — they are the *last* action
    /// on each layer, not necessarily a running one. Liveness is derived,
    /// never assumed.
    static func liveActions(in snapshot: SessionSnapshot, nowMs: Double) -> [LiveAction] {
        snapshot.actions
            .filter { action in
                action.lastActionResult == "Success"
                    && !action.clientCancel
                    && Double(action.endsAtMs) > nowMs
            }
            .map { action in
                LiveAction(
                    actionType: action.actionType,
                    layer: action.layer,
                    targetEntityID: action.targetEntityID,
                    recipeID: action.recipeID,
                    progress: clamp01((nowMs - Double(action.startTimeMs)) / Double(action.durationMs)),
                    endsInMs: Double(action.endsAtMs) - nowMs
                )
            }
    }

    static func isHarvesting(_ actions: [LiveAction]) -> Bool {
        actions.contains { $0.actionType == "Extract" }
    }

    // MARK: - Harvest pacing (learned, not configured)

    /// Rolling estimate of ms-per-health-point for the current target, from
    /// observed extract ticks. A few ticks in, the estimate is stable; until
    /// then the UI should show a percentage instead of a time.
    struct PacingEstimator: Sendable {
        private(set) var msPerHealthPoint: Double?

        private var lastEntityID: String?
        private var lastHealth: Double?
        private var lastTimeMs: Double?

        /// Reasonable bounds so one garbage tick can't poison the estimate.
        private static let bounds = 1.0...100_000.0
        private static let emaAlpha = 0.3

        mutating func observe(target: Target?, nowMs: Double) {
            guard let target, let health = target.health else {
                // First poll after targeting reports null health; also reset
                // when the player switches targets.
                if target?.entityID != lastEntityID { reset() }
                return
            }
            defer {
                lastEntityID = target.entityID
                lastHealth = health
                lastTimeMs = nowMs
            }
            guard target.entityID == lastEntityID,
                  let lastHealth, let lastTimeMs,
                  health < lastHealth, nowMs > lastTimeMs else {
                return
            }
            let sample = (nowMs - lastTimeMs) / (lastHealth - health)
            guard Self.bounds.contains(sample) else { return }
            if let current = msPerHealthPoint {
                msPerHealthPoint = current + (sample - current) * Self.emaAlpha
            } else {
                msPerHealthPoint = sample
            }
        }

        mutating func reset() {
            lastEntityID = nil
            lastHealth = nil
            lastTimeMs = nil
        }
    }

    // MARK: - The big countdown

    /// Health-based estimate of time left on the target, via the learned
    /// pacing. Nil when health is not yet tracked or pacing is unknown.
    static func depletionCountdownMs(
        target: Target?,
        msPerHealthPoint: Double?
    ) -> Double? {
        guard let target, let health = target.health else { return nil }
        guard let msPerHealthPoint else { return nil }
        return health * msPerHealthPoint
    }

    /// Clock-based countdown for a resource that arrived as a watched spawn
    /// (its whole despawn window is on the wire). Nil when not present or no
    /// server-side despawn timer.
    static func spawnWindowRemainingMs(
        in snapshot: SessionSnapshot,
        resourceID: Int,
        nowMs: Double
    ) -> Double? {
        guard let spawn = snapshot.activitySpawns.first(where: { $0.resourceID == resourceID }),
              let expiresAtMs = spawn.expiresAtMs else { return nil }
        return Double(expiresAtMs) - nowMs
    }

    // MARK: - Citric detection

    struct CitricAlert: Equatable, Sendable {
        let entityID: String
        let resourceName: String
        let location: TileLocation?
        let spawnedAtMs: Double
        let expiresAtMs: Double
        let isNewlySpawned: Bool

        func remainingMs(nowMs: Double) -> Double { expiresAtMs - nowMs }
    }

    /// The citric bush is a *new* entity — it never appears as the player's
    /// `target` until they switch to it. Watch for its insert into
    /// `activity_spawns`. Returns the live alert (remaining > 0) if any.
    static func detectCitric(
        previous: SessionSnapshot?,
        current: SessionSnapshot,
        citricResourceIDs: Set<Int>,
        fallbackWindowMs: Double,
        nowMs: Double
    ) -> CitricAlert? {
        for spawn in current.activitySpawns {
            guard citricResourceIDs.contains(spawn.resourceID) else { continue }
            let expiresAtMs = Double(
                spawn.expiresAtMs ?? spawn.spawnedAtMs + Int64(fallbackWindowMs)
            )
            let alert = CitricAlert(
                entityID: spawn.entityID,
                resourceName: spawn.name ?? "Citric Giant Berry Bush",
                location: spawn.location,
                spawnedAtMs: Double(spawn.spawnedAtMs),
                expiresAtMs: expiresAtMs,
                isNewlySpawned: !(previous?.activitySpawns.contains { $0.entityID == spawn.entityID } ?? false)
            )
            if alert.remainingMs(nowMs: nowMs) > 0 {
                return alert
            }
        }
        return nil
    }

    // MARK: - Food buff watch

    struct FoodBuffState: Equatable, Sendable {
        let active: Bool
        /// Unix seconds; nil when inactive.
        let expiresAtUnixSec: Int64?
        let remainingMs: Double?
    }

    /// Multiple food buffs can stack; the latest expiry is the one that
    /// matters. Expired-but-lingering rows are excluded by the countdown
    /// math, not by presence.
    static func foodBuffState(
        in snapshot: SessionSnapshot,
        foodBuffIDs: Set<Int>,
        nowMs: Double
    ) -> FoodBuffState {
        let nowSec = nowMs / 1_000
        let expiries = snapshot.buffs
            .filter { foodBuffIDs.contains($0.buffID) }
            .map { $0.expiresAtUnixSec }
            .filter { Double($0) > nowSec }
        guard let latest = expiries.max() else {
            return FoodBuffState(active: false, expiresAtUnixSec: nil, remainingMs: nil)
        }
        return FoodBuffState(
            active: true,
            expiresAtUnixSec: latest,
            remainingMs: Double(latest) * 1_000 - nowMs
        )
    }

    // MARK: - Stamina projection

    struct RegenRules: Equatable, Sendable {
        /// Delay after the last stamina decrease before regen begins.
        var delayAfterDecreaseMs: Double
        var tickMs: Double
        var perTick: Double
    }

    struct StaminaProjection: Equatable, Sendable {
        let current: Double
        let projected: Double
        let max: Double
        let pct: Double
        /// Relay-clock ms when `projected` reaches `max`; nil when unknown
        /// (no `last_decrease_at`) or already full.
        let fullAtMs: Double?
    }

    /// Projects stamina forward from the last known anchor. The relay does
    /// not simulate regen server-side — `rules` constants come from bundled
    /// gamedata and are confirmed in playtests (see tutorial §5 caveats).
    static func staminaProjection(
        in snapshot: SessionSnapshot,
        rules: RegenRules,
        nowMs: Double
    ) -> StaminaProjection? {
        guard let stamina = snapshot.stamina else { return nil }
        guard stamina.current < stamina.max else {
            return StaminaProjection(
                current: stamina.current, projected: stamina.current,
                max: stamina.max, pct: 1, fullAtMs: nil
            )
        }
        guard let lastDecreaseAt = stamina.lastDecreaseAt,
              let lastDecreaseMs = RFC3339.msSinceEpoch(lastDecreaseAt) else {
            // No anchor: report the raw value without projecting.
            return StaminaProjection(
                current: stamina.current, projected: stamina.current,
                max: stamina.max, pct: stamina.current / max(stamina.max, 1),
                fullAtMs: nil
            )
        }
        let regenStartMs = lastDecreaseMs + rules.delayAfterDecreaseMs
        let elapsed = max(0, nowMs - regenStartMs)
        let ticks = floor(elapsed / rules.tickMs)
        let projected = min(stamina.max, stamina.current + ticks * rules.perTick)
        let missing = stamina.max - projected
        let fullAtMs: Double? = missing <= 0
            ? nowMs
            : nowMs + ceil(missing / rules.perTick) * rules.tickMs
        return StaminaProjection(
            current: stamina.current,
            projected: projected,
            max: stamina.max,
            pct: projected / max(stamina.max, 1),
            fullAtMs: fullAtMs
        )
    }

    // MARK: - Helpers

    static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

enum RFC3339 {
    /// Parses "2026-09-05T17:14:52.000Z" (and the non-fractional variant).
    static func msSinceEpoch(_ string: String) -> Double? {
        if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: string) {
            return date.timeIntervalSince1970 * 1_000
        }
        if let date = ISO8601DateFormatter.plain.date(from: string) {
            return date.timeIntervalSince1970 * 1_000
        }
        return nil
    }
}

extension ISO8601DateFormatter {
    // Formatters are expensive to build per call and immutable after
    // configuration; shared instances are safe in practice, hence the
    // deliberate sendability opt-out.
    nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
