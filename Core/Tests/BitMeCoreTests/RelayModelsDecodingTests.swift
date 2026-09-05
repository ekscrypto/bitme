import Testing
import Foundation
@testable import BitMeCore

/// Locks the Codable wire format against the exact JSON shapes documented in
/// docs/api.md (which mirror the relay's BITME-API.md). If the relay changes
/// field names or shapes, these fail first.
struct RelayModelsDecodingTests {

    private let resolveJSON = """
    {
      "found": true,
      "entity_id": "504403158290646123",
      "username": "Whisper",
      "username_lowercase": "whisper",
      "identity": "c2003111fc31ca323b17ed6063f1522a6a446f1384d78eadb23449b6cb9ce4a6",
      "region_id": 7,
      "region_name": "Virexal",
      "host": "https://bitcraft-early-access.spacetimedb.com",
      "module": "bitcraft-live-7",
      "signed_in": true
    }
    """

    private let sessionJSON = """
    {
      "found": true,
      "player_entity_id": "504403158290646123",
      "username": "Whisper",
      "signed_in": true,
      "region": 7,
      "position": {
        "world_x": 11173.0, "world_z": 13848.002,
        "tile_x": 11173, "tile_z": 13848,
        "destination_world_x": 11173.0, "destination_world_z": 13848.002,
        "dimension": 1, "is_walking": false,
        "timestamp_ms": 1788628340546, "age_ms": 152127
      },
      "claim": {
        "entity_id": "504403158281321768",
        "name": "Hex and Highwater Port",
        "owner_player_entity_id": "1008806316547466858",
        "neutral": false
      },
      "stamina": {
        "current": 370.5, "max": 471.0, "max_health": 210.0,
        "last_decrease_at": "2026-09-05T17:14:52.000Z"
      },
      "buffs": [
        {"buff_id": 5887916, "start_timestamp": 1788627036, "duration": 3600,
         "values": [0.092, 0.092]}
      ],
      "actions": [
        {"auto_id": "122145", "action_type": "Craft", "layer": "Base",
         "start_time_ms": 1788628492480, "duration_ms": 1088,
         "ends_at_ms": 1788628493568, "target_entity_id": "504403158308175117",
         "recipe_id": 109007, "last_action_result": "Success", "client_cancel": false}
      ],
      "target": {
        "entity_id": "504403158302441789",
        "resource_id": 38,
        "name": "Flint Pile",
        "health": 2398,
        "max_health": 10000,
        "despawn_time_secs": 0.0,
        "respawn_time_secs": 600.0,
        "location": {"tile_x": 10213, "tile_z": 12367}
      },
      "activity_spawns": [
        {"entity_id": "504403163787158939", "resource_id": 2089325907,
         "name": "Baited School Of Muddy Auratus",
         "health": null, "max_health": 3000,
         "location": {"tile_x": 11448, "tile_z": 11357},
         "spawned_at_ms": 1788622724778, "expires_at_ms": null}
      ],
      "server_time_ms": 1788628492673
    }
    """

    @Test func resolveDecodes() throws {
        let resolved = try JSONDecoder().decode(ResolveResponse.self, from: Data(resolveJSON.utf8))
        #expect(resolved.entityID == "504403158290646123")
        #expect(resolved.username == "Whisper")
        #expect(resolved.regionID == 7)
        #expect(resolved.regionName == "Virexal")
        #expect(resolved.signedIn == true)
        #expect(resolved.identity?.hasPrefix("c2003111") == true)
    }

    @Test func sessionDecodesWithDocumentedFieldNames() throws {
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(sessionJSON.utf8))

        #expect(snapshot.playerEntityID == "504403158290646123")
        #expect(snapshot.region == 7)
        #expect(snapshot.serverTimeMs == 1_788_628_492_673)

        let position = try #require(snapshot.position)
        #expect(position.tileX == 11_173)
        #expect(position.dimension == 1)
        #expect(position.ageMs == 152_127)

        let claim = try #require(snapshot.claim)
        #expect(claim.name == "Hex and Highwater Port")

        let stamina = try #require(snapshot.stamina)
        #expect(stamina.current == 370.5)
        #expect(stamina.max == 471.0)
        #expect(stamina.lastDecreaseAt == "2026-09-05T17:14:52.000Z")

        let buff = try #require(snapshot.buffs.first)
        #expect(buff.expiresAtUnixSec == 1_788_627_036 + 3_600)

        let action = try #require(snapshot.actions.first)
        #expect(action.actionType == "Craft")
        #expect(action.layer == "Base")
        #expect(action.endsAtMs == action.startTimeMs + action.durationMs)
        #expect(action.clientCancel == false)

        let target = try #require(snapshot.target)
        #expect(target.resourceID == 38)
        #expect(target.health == 2398)
        #expect(target.maxHealth == 10_000)
        #expect(target.respawnTimeSecs == 600.0)
        #expect(target.location?.tileX == 10_213)

        let spawn = try #require(snapshot.activitySpawns.first)
        #expect(spawn.resourceID == 2_089_325_907)
        #expect(spawn.health == nil)
        #expect(spawn.expiresAtMs == nil)
    }

    @Test func nullableFieldsDecodeAsNil() throws {
        // Minimal snapshot where every nullable documented field is null.
        let json = """
        {
          "found": true,
          "player_entity_id": "1",
          "username": null,
          "signed_in": null,
          "region": 3,
          "position": null,
          "claim": null,
          "stamina": null,
          "buffs": [],
          "actions": [],
          "target": null,
          "activity_spawns": [],
          "server_time_ms": 1
        }
        """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.username == nil)
        #expect(snapshot.signedIn == nil)
        #expect(snapshot.position == nil)
        #expect(snapshot.target == nil)
        #expect(snapshot.buffs.isEmpty)
    }
}
