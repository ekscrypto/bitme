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
                await ingestor.ingest(Intent.SessionPolled(snapshot: snapshot, carrier: carrier))
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
