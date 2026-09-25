import Foundation
import os

/// Namespace for concrete activities (fenex-light pattern).
enum Activity {}

let coreLog = Logger(subsystem: "life.encoded.bitme.ios", category: "core")

// MARK: - Bootstrap

extension Activity {
    struct Bootstrap: Sendable {}
}

extension Activity.Bootstrap: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        let identity = await adapters.restoreIdentity()
        await ingestor.ingest(Intent.BootstrapCompleted(identity: identity))
    }
}

// MARK: - Gamedata

extension Activity {
    struct LoadGamedata: Sendable {}
}

extension Activity.LoadGamedata: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        let gamedata = await adapters.loadFoodBuffGamedata()
        await ingestor.ingest(Intent.GamedataLoaded(gamedata: gamedata))
    }
}

// MARK: - Resolve

extension Activity {
    struct ResolvePlayer: Sendable {
        let name: String
    }
}

extension Activity.ResolvePlayer: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        do {
            let resolved = try await adapters.relay.resolve(name)
            await ingestor.ingest(Intent.ResolveSucceeded(response: resolved))
        } catch RelayError.notFound {
            await ingestor.ingest(Intent.ResolveFailed(
                message: "No character found with the exact name “\(name)”."
            ))
        } catch let RelayError.badRequest(message) {
            await ingestor.ingest(Intent.ResolveFailed(message: message))
        } catch is CancellationError {
            // Shutdown — no feedback intent.
        } catch {
            await ingestor.ingest(Intent.ResolveFailed(
                message: "Relay unreachable — check your connection and try again."
            ))
        }
    }
}

// MARK: - Session loop

extension Activity {
    /// The 1 Hz session poll loop with backoff. Long-running: runs until its
    /// task is cancelled (`Intent.SignOut` / shutdown). The inter-poll delay
    /// is stamped into `carrier` by `Intent.SessionPolled`/`SessionPollFailed`
    /// (ADR-014 carrier pattern — the loop never reads machine state).
    struct SessionLoop: Sendable {
        let entityID: String
        let carrier: SessionLoopCarrier
        /// Machine-stamped with the spawned task; stored in session state by
        /// the starting intent so `Intent.SignOut` can cancel it.
        let cancellable: CancellableTask
    }
}

extension Activity.SessionLoop: AsyncActivity, StampableActivity {
    var stampTarget: CancellableTask { cancellable }

    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        coreLog.info("session loop started for \(self.entityID, privacy: .public)")
        var delayMs = 1_000.0
        while !Task.isCancelled {
            do {
                try await adapters.sleep(delayMs / 1_000)
            } catch {
                return // cancelled
            }
            guard !Task.isCancelled else { return }
            do {
                let snapshot = try await adapters.relay.session(entityID)
                await ingestor.ingest(Intent.SessionPolled(
                    snapshot: snapshot,
                    carrier: carrier,
                    polledAtMs: Date().timeIntervalSince1970 * 1_000
                ))
                delayMs = carrier.nextDelayMs
            } catch is CancellationError {
                return
            } catch RelayError.notFound {
                await ingestor.ingest(Intent.SessionPollFailed(
                    kind: .notFound,
                    message: "player not present in any mirrored region",
                    carrier: carrier
                ))
                delayMs = carrier.nextDelayMs
            } catch {
                await ingestor.ingest(Intent.SessionPollFailed(
                    kind: .transient,
                    message: String(describing: error),
                    carrier: carrier
                ))
                delayMs = carrier.nextDelayMs
            }
        }
    }
}

// MARK: - Resource map

extension Activity {
    /// One session-anchored BMR1 window fetch (drift/staleness-triggered by
    /// `Intent.SessionPolled`, or a resync recovery from the stream).
    struct FetchResourceWindow: Sendable {
        let entityID: String
    }
}

extension Activity.FetchResourceWindow: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        let atMs = Date().timeIntervalSince1970 * 1_000
        do {
            let window = try await adapters.relay.sessionResources(entityID)
            await ingestor.ingest(Intent.ResourceWindowFetched(window: window, fetchedAtMs: atMs))
        } catch is CancellationError {
            // Shutdown — no feedback intent.
        } catch RelayError.seeding {
            await ingestor.ingest(Intent.ResourceWindowUnavailable(kind: .seeding, atMs: atMs))
        } catch {
            await ingestor.ingest(Intent.ResourceWindowUnavailable(kind: .failed, atMs: atMs))
        }
    }
}

extension Activity {
    /// Loads a region's resource dictionary when a window/delta's
    /// `dict_version` is not covered by the cached one.
    struct LoadResourceDictionary: Sendable {
        let region: Int
        let neededVersion: Int
    }
}

extension Activity.LoadResourceDictionary: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        do {
            let dictionary = try await adapters.relay.resourceDictionary(region)
            await ingestor.ingest(Intent.ResourceDictionaryLoaded(region: region, dictionary: dictionary))
        } catch is CancellationError {
            // Shutdown — no feedback intent.
        } catch {
            coreLog.info("resource dictionary load failed (region \(self.region)): \(String(describing: error), privacy: .public)")
            // Not fatal — the next window fetch or subscribed message re-attempts.
        }
    }
}

extension Activity {
    /// Loads the BME1 terrain plane behind a window (drift/TTL-triggered by
    /// `Intent.ResourceWindowFetched`). Terrain rarely changes — 10 min TTL.
    struct FetchTerrain: Sendable {
        let centerX: Int
        let centerZ: Int
    }
}

extension Activity.FetchTerrain: AsyncActivity {
    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        let atMs = Date().timeIntervalSince1970 * 1_000
        do {
            let plane = try await adapters.relay.worldElevation(centerX, centerZ)
            await ingestor.ingest(Intent.TerrainPlaneFetched(plane: plane, atMs: atMs))
        } catch is CancellationError {
            // Shutdown — no feedback intent.
        } catch {
            coreLog.info("terrain plane fetch failed (\(self.centerX), \(self.centerZ)): \(String(describing: error), privacy: .public)")
            // Not fatal — the next window fetch re-attempts.
        }
    }
}

extension Activity {
    /// The resource change-stream loop. Long-running: connects when the
    /// machine wants the stream (live player, overworld — stamped into the
    /// carrier by `Intent.SessionPolled`), forwards events as intents, and
    /// reconnects with exponential backoff when a connection ends (server
    /// close, error, zombie watchdog in `ResourceStreamClient`).
    struct ResourceStreamLoop: Sendable {
        let entityID: String
        let carrier: ResourceStreamCarrier
        /// Machine-stamped with the spawned task; stored in session state by
        /// the starting intent so `Intent.SignOut` can cancel it.
        let cancellable: CancellableTask
    }
}

extension Activity.ResourceStreamLoop: AsyncActivity, StampableActivity {
    var stampTarget: CancellableTask { cancellable }

    func start(ingestor: IntentIngestor, adapters: Adapters) async {
        let config = GameConfig.shared
        coreLog.info("resource stream loop started for \(self.entityID, privacy: .public)")
        var attempt = 0
        while !Task.isCancelled {
            // Hold off until the machine wants the stream (live + overworld).
            while !Task.isCancelled && !carrier.wanted {
                await ingestor.ingest(Intent.ResourceStreamStatusChanged(status: .off))
                do {
                    try await adapters.sleep(config.mapStreamPausePollSecs)
                } catch {
                    return // cancelled
                }
            }
            guard !Task.isCancelled else { return }

            await ingestor.ingest(Intent.ResourceStreamStatusChanged(status: .connecting))
            var subscribed = false
            for await event in adapters.relay.openResourceStream(entityID) {
                if Task.isCancelled || !carrier.wanted { break }
                if case .subscribed = event {
                    subscribed = true
                    attempt = 0
                }
                await ingestor.ingest(Intent.ResourceStreamEventReceived(
                    event: event,
                    atMs: Date().timeIntervalSince1970 * 1_000
                ))
            }
            if Task.isCancelled { return }

            // Socket ended (close / error / watchdog / "gone") — back off,
            // then let the loop head decide whether to reconnect.
            await ingestor.ingest(Intent.ResourceStreamStatusChanged(
                status: subscribed ? .reconnecting : .connecting
            ))
            attempt = min(5, attempt + 1)
            let delay = min(
                config.mapStreamReconnectMaxSecs,
                config.mapStreamReconnectBaseSecs * pow(2, Double(attempt - 1))
            )
            do {
                try await adapters.sleep(delay)
            } catch {
                return // cancelled
            }
        }
    }
}
