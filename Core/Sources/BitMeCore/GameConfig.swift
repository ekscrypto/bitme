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
}
