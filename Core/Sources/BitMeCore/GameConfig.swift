import Foundation

/// Bundled game-data constants and alert thresholds. Everything marked
/// TUNE is a client-side constant the relay does not own — confirm against
/// gamedata and playtests (tutorial 2, §4–5).
struct GameConfig: Sendable {
    static let shared = GameConfig()

    // From the relay's vendored `bitme_watched_resource_ids.json` + the
    // Bountiful family table in docs/api.md §3.7.
    let citricResourceIDs: Set<Int> = [
        1_688_062_540, // Citric Giant Strawberry Bush
        65_901_922,    // Citric Giant Savory Berry Bush
        1_875_092_977, // Citric Giant Zesty Berry Bush
    ]

    let bountifulResourceIDs: Set<Int> = [
        1_822_942_131, // Giant Bountiful Strawberry Bush
        353_689_546,   // Giant Bountiful Savory Berry Bush
        1_713_099_134, // Giant Bountiful Zesty Berry Bush
    ]

    /// TUNE: passive stamina regen constants (parameters_desc + playtests).
    let regen = HarvestStateEngine.RegenRules(
        delayAfterDecreaseMs: 10_000,
        tickMs: 1_000,
        perTick: 1
    )

    /// "Eat food" escalates when a food buff expires inside this window.
    let eatFoodWarnWindowMs: Double = 120_000

    /// The game's global database only admits a connection within 1 h of
    /// the account's last launcher login — the module-private
    /// `user_authentication_state` timestamp (BitCraftPublic
    /// `global_module/handlers/authentication.rs`, 3600 s; the region
    /// shards use 24 h). The relay's `last_login_timestamp`
    /// (`player_state.sign_in_timestamp`, public) is the readable proxy:
    /// older than this window ⇒ skip the global leg, region only.
    let globalAuthWindowSecs: Double = 3600

    /// Citric window fallback when the spawn entry has `expires_at_ms: null`.
    let citricFallbackWindowMs: Double = 30_000

    /// Alert hard (sound/vibration copy) for the first part of the window.
    let citricHotWindowMs: Double = 10_000

    // Resource map / change stream (docs/api.md §6–7) — cadences follow the
    // reference web client's guidance.
    /// Refetch an on-screen resource window this often (deltas keep it fresh
    /// in between; the refetch is the convergence move).
    let mapWindowStaleMs: Double = 60_000
    /// Player drift (tiles from the window center) that triggers a refetch.
    let mapDriftRefetchTiles: Int = 100
    /// 202 "seeding" backoff before retrying a window fetch.
    let mapSeedingBackoffMs: Double = 30_000
    /// Backoff after a failed window fetch (network error / 5xx).
    let mapFetchFailureBackoffMs: Double = 5_000
    /// Terrain plane TTL — terrain rarely changes (terraform bumps the
    /// plane generation instead).
    let mapTerrainStaleMs: Double = 600_000
    /// Spawn/despawn feed ring capacity (newest first).
    let mapFeedCapacity = 32
    /// Change-stream reconnect backoff: base × 2^attempt, capped.
    let mapStreamReconnectBaseSecs: Double = 2
    let mapStreamReconnectMaxSecs: Double = 30
    /// How long the pause loop sleeps between wanted-checks.
    let mapStreamPausePollSecs: Double = 1

    /// Prospection overlay (docs/protocol/prospecting.md): crumb acceptance
    /// radius in world units for the target circle — the desc ranges are
    /// 10–12 for most activities, 25 for hunts/hidden spots; the common
    /// case is drawn and the wedge carries the rest of the uncertainty.
    let prospectCrumbRadius: Double = 12

    // Craft driver (docs/protocol/region-move-and-craft-continue.md).
    /// Safety margin over the server-computed action delay: the cadence
    /// gate rejects completions under 95 % of the delay (80–95 % records
    /// a strike), so the driver fires at 102 % — never in the strike band.
    let craftDelayMargin: Double = 1.02
    /// Multiplier applied to the delay after a "Tried to … too quickly"
    /// rejection (server under-validation or clock skew) before re-arming.
    let craftTooFastBackoff: Double = 1.25
    /// Cap on that backoff, relative to the base delay.
    let craftTooFastBackoffCap: Double = 2.0
    /// The inter-iteration gap after `craft_continue` before the next
    /// `craft_continue_start` — the captured loop's 50–90 ms cadence.
    let craftInterIterationGapSecs: Double = 0.07
    /// How many reducer-level failures (unknown errors) end a drive.
    let craftMaxConsecutiveErrors = 3
    /// Measured overworld walk speed in raw milli-tile units per second
    /// (capture 2026-09-28: mean 5217, min 4852 across the captured
    /// player's segments). Hops are paced under it.
    let walkSpeedRawPerSec: Double = 5_100
    /// Duration safety multiplier per hop — the server rejects moves
    /// faster than its own speed math (`duration ≥ travel × 0.9 − 0.05`).
    let walkDurationMargin: Double = 1.15
    /// Longest acceptable one-hop distance, raw units (≈1 tile).
    let walkHopRawDistance: Double = 1_000
    /// Autowalk gives up after this many seconds.
    let walkTimeoutSecs: Double = 60
}
