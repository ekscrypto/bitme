import Foundation
import SpacetimeDB

/// Events from the tracked player's prospection watch — the own-row slice
/// of `prospecting_state` (docs/protocol/prospecting.md).
public enum ProspectionEvent: Equatable, Sendable {
    /// A row snapshot or delta — the pending prospection's compass state.
    case updated(ProspectingStateRow)
    /// The row was deleted: the trail completed or was abandoned.
    case ended
    /// The watch itself failed (setup or the reconnect budget ran out);
    /// the stream finishes right after.
    case failed(String)
}

/// Watches the tracked player's `prospecting_state` row on the region
/// mirror — an anonymous read (the mirror serves public tables without
/// credentials; the game's own servers would kill the socket, the mirror
/// doesn't). X-Ray is name-driven: it holds no game session, so the mirror
/// is its only window into the region leg. The SDK reconnects the transport
/// itself but does not re-establish subscriptions, so each `.connected`
/// re-subscribes; when the reconnect budget is exhausted the stream ends
/// (a stale overlay must never linger — a later poll re-arms the watch).
///
/// The subscription's initial snapshot is dropped: a prospection already
/// pending when the watch armed was measured from where the player stood
/// at some unknowable earlier moment, so anchoring its cone at the current
/// poll position would draw it from the wrong spot. The overlay starts
/// only from prospections the watch witnesses live.
enum RegionProspectClient {

    /// The mirror's region port is `3000 + region` (verified live:
    /// `bitcraft-live-14` answers on `:3014`).
    static func mirrorHost(region: Int) -> String {
        "https://relay.bitcraftsync.app:\(3000 + region)"
    }

    static func query(entityID: UInt64) -> String {
        "SELECT * FROM prospecting_state WHERE entity_id = \(entityID);"
    }

    static func events(entityID: UInt64, region: Int) -> AsyncStream<ProspectionEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(entityID: entityID, region: region) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func run(
        entityID: UInt64,
        region: Int,
        emit: @escaping @Sendable (ProspectionEvent) -> Void
    ) async {
        let client: SpacetimeDBClient
        do {
            client = try SpacetimeDBClient(host: mirrorHost(region: region), db: "bitcraft-live-\(region)")
            // Anonymous: no token — the mirror is a read replica.
            try await client.connect(token: nil, enableAutoReconnect: true)
        } catch {
            emit(.failed("prospection watch could not reach the mirror (\(String(describing: error)))"))
            return
        }
        defer { Task { await client.disconnect() } }

        await client.registerTableRowDecoder(ProspectingStateRow.self)
        let connectionEvents = await client.connectionEvents

        await withTaskGroup(of: Void.self) { group in
            var watchingRows = false
            for await event in connectionEvents {
                guard !Task.isCancelled else { break }
                switch event {
                case .connected:
                    // Initial connection and every transport reconnect:
                    // (re-)establish the subscription.
                    do {
                        let subscription = try await client.subscribe([
                            Self.query(entityID: entityID),
                        ])
                        try await subscription.applied()
                    } catch {
                        if !Task.isCancelled {
                            emit(.failed("prospection subscription failed (\(String(describing: error)))"))
                        }
                        group.cancelAll()
                        return
                    }
                    guard !watchingRows else { continue }
                    watchingRows = true
                    // The row stream attaches only here, after the first
                    // subscription applies — the one deliberate exception
                    // to "attach tableEvents before subscribe" (see the
                    // type comment). The SDK dispatches the snapshot rows
                    // before resolving `applied()`, and a late attachment
                    // never sees prior emissions, so the first row that
                    // flows is one this watch witnessed live — or a
                    // reconnect re-delivery, bounded by the transport gap,
                    // which the mutator's timestamp check already handles.
                    let rowEvents = await client.tableEvents(named: ProspectingStateRow.tableName)
                    group.addTask {
                        for await event in rowEvents {
                            guard event.tableName == ProspectingStateRow.tableName else { continue }
                            for insert in event.inserts {
                                if let row = insert as? ProspectingStateRow {
                                    emit(.updated(row))
                                }
                            }
                            if event.inserts.isEmpty, !event.deletes.isEmpty {
                                emit(.ended)
                            }
                        }
                    }
                case .reconnecting:
                    continue
                case .disconnected, .error:
                    // The SDK either reconnects (the next `.connected`
                    // re-subscribes) or has exhausted its budget —
                    // either way the stale overlay must go.
                    emit(.ended)
                    group.cancelAll()
                    return
                }
            }
            group.cancelAll()
        }
    }
}
