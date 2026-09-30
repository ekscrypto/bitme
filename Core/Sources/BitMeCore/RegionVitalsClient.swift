import Foundation
import SpacetimeDB

/// Events from the player-vitals subscription — the own-row slice of the
/// stamina/health/satiation/teleport pools, the materialized stat vector,
/// the server's action record, and the position truth. Own-action row
/// changes reach this stream only when the *server* wrote them (timers,
/// external effects); the actor's own reducer effects arrive via the
/// driver's per-call receipts instead (docs/protocol/
/// region-move-and-craft-continue.md §4).
public enum PlayerVitalsEvent: Equatable, Sendable {
    case stamina(Float)
    case health(Float)
    case satiation(Float)
    case teleportEnergy(Float)
    /// The full materialized stat vector (`character_stats_state.values`).
    case stats([Float])
    case action(PlayerActionRow)
    case position(MobileEntityRow)
    case failed(String)
}

/// The player's own rows on the game session's region leg — the exact
/// equality-grammar set the desktop client holds (captured reqId 120):
/// seven one-row queries, one subscription. Streams until the leg closes;
/// a terminal `.failed` event precedes the end when the setup itself
/// failed.
enum RegionVitalsClient {

    static func events(leg: RegionLeg, player: UInt64) -> AsyncStream<PlayerVitalsEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(client: leg.client, player: player) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    static func queries(player: UInt64) -> [String] {
        [
            "SELECT * FROM stamina_state WHERE entity_id = \(player);",
            "SELECT * FROM health_state WHERE entity_id = \(player);",
            "SELECT * FROM teleportation_energy_state WHERE entity_id = \(player);",
            "SELECT * FROM satiation_state WHERE entity_id = \(player);",
            "SELECT * FROM character_stats_state WHERE entity_id = \(player);",
            "SELECT * FROM player_action_state WHERE entity_id = \(player);",
            "SELECT * FROM mobile_entity_state WHERE entity_id = \(player);",
        ]
    }

    private static func run(
        client: SpacetimeDBClient,
        player: UInt64,
        emit: @escaping @Sendable (PlayerVitalsEvent) -> Void
    ) async {
        do {
            await client.registerTableRowDecoder(StaminaRow.self)
            await client.registerTableRowDecoder(HealthRow.self)
            await client.registerTableRowDecoder(TeleportEnergyRow.self)
            await client.registerTableRowDecoder(SatiationRow.self)
            await client.registerTableRowDecoder(CharacterStatsRow.self)
            await client.registerTableRowDecoder(PlayerActionRow.self)
            await client.registerTableRowDecoder(MobileEntityRow.self)

            // Attach the row streams before subscribing — the initial
            // snapshot fans out when SubscribeApplied lands.
            let staminaEvents = await client.tableEvents(named: StaminaRow.tableName)
            let healthEvents = await client.tableEvents(named: HealthRow.tableName)
            let teleportEvents = await client.tableEvents(named: TeleportEnergyRow.tableName)
            let satiationEvents = await client.tableEvents(named: SatiationRow.tableName)
            let statsEvents = await client.tableEvents(named: CharacterStatsRow.tableName)
            let actionEvents = await client.tableEvents(named: PlayerActionRow.tableName)
            let positionEvents = await client.tableEvents(named: MobileEntityRow.tableName)
            let connectionEvents = await client.connectionEvents

            let queries = queries(player: player)
            coreLog.info("player vitals: subscribing (\(queries.count) own-row queries)")
            let subscription = try await client.subscribe(queries)
            try await subscription.applied()
            coreLog.info("player vitals: live (player \(player, privacy: .public))")

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await Self.consume(staminaEvents, of: StaminaRow.self) {
                        emit(.stamina($0.stamina))
                    }
                }
                group.addTask {
                    await Self.consume(healthEvents, of: HealthRow.self) {
                        emit(.health($0.health))
                    }
                }
                group.addTask {
                    await Self.consume(teleportEvents, of: TeleportEnergyRow.self) {
                        emit(.teleportEnergy($0.energy))
                    }
                }
                group.addTask {
                    await Self.consume(satiationEvents, of: SatiationRow.self) {
                        emit(.satiation($0.satiation))
                    }
                }
                group.addTask {
                    await Self.consume(statsEvents, of: CharacterStatsRow.self) {
                        emit(.stats($0.values))
                    }
                }
                group.addTask {
                    var first = true
                    for await event in actionEvents {
                        guard event.tableName == PlayerActionRow.tableName else { continue }
                        // Two rows arrive per player (Base + UpperBody) —
                        // the Base layer carries the driving actions.
                        for insert in event.inserts {
                            if let row = insert as? PlayerActionRow, row.layer == 0 {
                                if first {
                                    coreLog.info("player vitals: action snapshot landed")
                                    first = false
                                }
                                emit(.action(row))
                            }
                        }
                    }
                }
                group.addTask {
                    await Self.consume(positionEvents, of: MobileEntityRow.self) {
                        emit(.position($0))
                    }
                }
                group.addTask {
                    for await event in connectionEvents {
                        switch event {
                        case .connected, .reconnecting:
                            continue
                        case .disconnected, .error:
                            coreLog.info("player vitals: region leg ended")
                            return
                        }
                    }
                }
                await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            // Shutdown — no terminal event.
        } catch {
            coreLog.error("player vitals: sync failed: \(String(describing: error), privacy: .public)")
            emit(.failed(Self.message(for: error)))
        }
    }

    private static func consume<R: BSATNTableWithPrimaryKey>(
        _ stream: AsyncStream<TableEvent>,
        of type: R.Type,
        emit: @escaping @Sendable (R) -> Void
    ) async where R.PrimaryKey == UInt64 {
        for await event in stream {
            guard event.tableName == R.tableName else { continue }
            for insert in event.inserts {
                if let row = insert as? R {
                    emit(row)
                }
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let reduced = error as? SpacetimeDBError {
            return String(describing: reduced)
        }
        return "the player vitals sync stopped (\(String(describing: error)))"
    }
}
