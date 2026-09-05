import Foundation
import Observation

/// Owns the ~1 Hz `/bitme/session` poll loop for one player: snapshot
/// history, relay-clock offset, separate 404/network backoff ladders, and
/// the harvest-pacing estimate learned from target health ticks.
///
/// The poll keeps the server-side tracker alive (GET *is* the registration,
/// 15 min TTL). Target health and spawn tracking only accumulate while this
/// loop runs — after a long gap or a deploy reseed, expect one or two
/// snapshots with `health: null` and an empty `activity_spawns`.
@MainActor
@Observable
final class SessionMonitor {
    enum Connection: Equatable, Sendable {
        case ok
        /// Network error / 5xx — transient; UI stays alive on last data.
        case degraded
        /// 404 — deploy reseed or player left mirrored regions; back off hard.
        case down
    }

    let entityID: String

    private(set) var connection: Connection = .ok
    private(set) var snapshot: SessionSnapshot?
    /// Snapshot from one poll ago — the `prev` input to citric detection.
    private(set) var previous: SessionSnapshot?
    private(set) var lastError: String?

    /// Static gamedata (48 h cached, fetched over the mirror WebSocket) —
    /// loaded once per monitor lifetime, see `GamedataService`.
    private(set) var foodBuffGamedata: FoodBuffGamedata?

    /// ms of harvesting per point of target health, learned online
    /// (`HarvestStateEngine.PacingEstimator`); nil until two health ticks
    /// have been observed for the current target.
    private(set) var pacingMsPerHealthPoint: Double?

    private var pollTask: Task<Void, Never>?
    private var offsetMs: Double = 0
    private var notFoundBackoffMs: Double = 0
    private var errorBackoffMs: Double = 0
    private var pacing = HarvestStateEngine.PacingEstimator()

    private let client: RelayClient
    private let baseIntervalMs: Double

    init(client: RelayClient, entityID: String, baseIntervalMs: Double = 1_000) {
        self.client = client
        self.entityID = entityID
        self.baseIntervalMs = baseIntervalMs
    }

    /// Relay-clock "now" in unix ms — the only clock safe to compare against
    /// snapshot timestamps (device clocks drift; `server_time_ms` re-anchors
    /// `offsetMs` every poll).
    var nowRelayMs: Double {
        Date().timeIntervalSince1970 * 1_000 + offsetMs
    }

    var isRunning: Bool { pollTask != nil }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.loop()
        }
        Task { [weak self] in
            let gamedata = await GamedataService.loadFoodBuffGamedata()
            self?.foodBuffGamedata = gamedata
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            let delayMs = await pollOnce()
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
    }

    /// One request; returns the delay before the next.
    private func pollOnce() async -> Double {
        do {
            let snap = try await client.session(entityID: entityID)
            previous = snapshot
            snapshot = snap
            offsetMs = Double(snap.serverTimeMs) - Date().timeIntervalSince1970 * 1_000
            notFoundBackoffMs = 0
            errorBackoffMs = 0
            lastError = nil
            connection = .ok
            pacing.observe(target: snap.target, nowMs: nowRelayMs)
            pacingMsPerHealthPoint = pacing.msPerHealthPoint
            return baseIntervalMs
        } catch RelayError.notFound {
            // Deploy reseed windows last minutes — start at 30 s, cap at 5 min.
            connection = .down
            lastError = "player not present in any mirrored region (or mirror reseeding)"
            notFoundBackoffMs = min(max(notFoundBackoffMs, 30_000) * 2, 300_000)
            return notFoundBackoffMs
        } catch {
            // Network error / 5xx: degraded, not down. Start at 5 s, cap 1 min.
            connection = .degraded
            lastError = String(describing: error)
            errorBackoffMs = min(errorBackoffMs == 0 ? 5_000 : errorBackoffMs * 2, 60_000)
            return errorBackoffMs
        }
    }
}
