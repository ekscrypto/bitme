# Region claim-buildings sync — data source & subscription design

Reference for the Pocket Crafter workstation list: which region-database
tables hold a claim's buildings (crafting, storage, other) and how to
subscribe to them live. Researched 2026-09-26 against the game module
schema (`bitcraft-mats/bitjita-schema-region.json`, schema version pinned
there) and the relay mirror's live subscriptions
(`relay-bitcraftsync-app/spacetimedb-bitcraft-mirror`, `shard.rs` +
`USED-TABLES.md`). The official client's region leg has never been
captured (tap analysis §6), so the query set below is derived from schema
+ relay practice — both verified against the same server build.

## 1. Where buildings live

Gameplay data — buildings, claims, inventories, crafts — is on the
player's **region shard** `bitcraft-live-<N>` (`N` = `user_region_state.
region_id`, already resolved by `GlobalPlayerResolver`). Same host, same
Bearer token, same v2.bsatn websocket as the global leg. The app already
connects and signs in on this leg in `GlobalSessionClient.events`.

**Subscribe on the existing region-leg `SpacetimeDBClient`; never open a
second region connection.** The game enforces one live session per
account per database (second connection: close code 4000).

All tables below are `Public` with **no row-level security**; every
filter rides an existing BTree index.

## 2. Claim resolution (name → entity id)

The gate's `claimName` is a display string from the relay. The reliable
key is the player's own membership row:

```sql
SELECT * FROM claim_member_state WHERE player_entity_id = <own entity id>
-- { entity_id: u64, claim_entity_id: u64, player_entity_id: u64,
--   user_name: string, inventory_permission: bool, build_permission: bool,
--   officer_permission: bool, co_owner_permission: bool }
```

Indexed on `player_entity_id`; also hands you the permission flags. A
player is normally a member of exactly one claim; if several rows come
back, disambiguate against the gate's claim name (`claim_state` is
name-indexed, but names are not a safe unique key — membership is).

## 3. The subscription set

```sql
-- live, claim-scoped (indexed on claim_entity_id)
SELECT * FROM building_state      WHERE claim_entity_id = <claim>
SELECT * FROM claim_state         WHERE entity_id = <claim>
SELECT * FROM claim_local_state   WHERE entity_id = <claim>   -- supplies, upkeep, treasury

-- static catalogs (small; subscribe whole)
SELECT * FROM building_desc
SELECT * FROM building_type_desc
SELECT * FROM building_function_type_mapping_desc
SELECT * FROM crafting_recipe_desc
SELECT * FROM building_nickname_state

-- craft tasks: per-building equality for each building id in the claim
-- (re-issued when the building set changes), or whole-table + client filter
SELECT * FROM passive_craft_state       WHERE building_entity_id = <b>   -- …per building
SELECT * FROM progressive_action_state  WHERE building_entity_id = <b>   -- …per building
SELECT * FROM passive_craft_state       WHERE owner_entity_id = <me>     -- personal tasks
```

New buildings placed mid-session arrive as inserts on the same
subscriptions — the list stays live with no re-querying.

### Table shapes (BSATN field order)

| Table | Row (field order = decode order) | Indexes |
| --- | --- | --- |
| `building_state` | `entity_id: u64, claim_entity_id: u64, direction_index: i32, building_description_id: i32, constructed_by_player_entity_id: u64` | entity_id, **claim_entity_id**, building_description_id |
| `building_desc` | `id: i32, functions: [ { function_type: i32, level: i32, crafting_slots: i32, storage_slots: i32, cargo_slots: i32, refining_slots: i32, refining_cargo_slots: i32, item_slot_size: i32, cargo_slot_size: i32, trade_orders: i32, allowed_item_id_per_slot: [i32], concurrent_crafts_per_player: i32, terraform: bool, housing_slots: i32, housing_income: u32 } ], name: string, description: string, …` | id |
| `building_type_desc` | `id: i32, name: string, category: Ref, actions: [string]` | id |
| `building_function_type_mapping_desc` | `type_id: i32, desc_ids: [i32]` | type_id |
| `building_nickname_state` | `entity_id: u64, nickname: string` | entity_id |
| `claim_state` | `entity_id: u64, owner_player_entity_id: u64, owner_building_entity_id: u64, name: string, neutral: bool` | entity_id, name, … |
| `claim_local_state` | `entity_id: u64, supplies: i32, building_maintenance: f32, num_tiles: i32, num_tile_neighbors: u32, location: Option<Ref>, treasury: u32, …` | entity_id |
| `claim_member_state` | (see §2) | player_entity_id, claim_entity_id, … |
| `passive_craft_state` | `entity_id: u64, owner_entity_id: u64, recipe_id: i32, building_entity_id: u64, timestamp: micros-since-epoch (i64), status: Queued\|Processing\|Complete, slot: Option<u32>` | building_entity_id, entity_id, owner_entity_id |
| `progressive_action_state` | `entity_id: u64, building_entity_id: u64, function_type: i32, progress: i32, recipe_id: i32, craft_count: i32, last_crit_outcome: i32, owner_entity_id: u64, lock_expiration: micros, preparation: bool` | building_entity_id, entity_id, owner_entity_id |
| `inventory_state` | `entity_id: u64, pockets: [ { volume: i32, contents: Option<{item_id, quantity, item_type, durability}>, locked: bool } ], inventory_index: i32, cargo_index: i32, owner_entity_id: u64, player_owner_entity_id: u64` | entity_id, **owner_entity_id**, player_owner_entity_id |

(`passive_craft_state`/`progressive_action_state` timestamps are
microseconds since the Unix epoch, matching the SDK's BSATN timestamp
encoding.)

### Building classification

`building_desc.functions` decides what a building is (relay's rule,
`relay-cache/src/decode.rs::functions_is_storage`):

- **crafting station** ⇔ any function entry has `crafting_slots > 0` or
  `refining_slots > 0`;
- **storage** ⇔ any entry has `storage_slots > 0` or `cargo_slots > 0`;
- buildings whose `name` contains "bank" are personal storage, excluded
  from claim rollups (BitJita policy — the relay does the same).

## 4. Protocol notes

- WHERE predicates in subscriptions are proven grammar on this server:
  the desktop client sent `WHERE identity = 0x…` / `WHERE entity_id = …`
  on the global leg (tap capture, 35 query sets), and the mirror runs
  `SELECT * FROM location_state WHERE dimension != 1` on the shards.
- SDK: `client.subscribe([sql…])` → `SubscriptionHandle`,
  `await handle.applied()`, then `client.rowEvents(table:)` streams
  `.inserted/.deleted/.updated` (PK-merged when the row type conforms to
  `BSATNTableWithPrimaryKey`).

## 5. Guardrails (measured row counts from the relay)

- **Never** subscribe `building_state` unfiltered on a phone — ~74K
  rows/region; the claim filter cuts it to tens.
- **Never** subscribe `location_state` whole — ~13M rows/region. Not
  needed for the workstation list; only for grouping storage by
  housing-interior dimension, and then only `WHERE dimension != 1`
  (absent row = overworld, dimension 1).
- `inventory_state` (storage contents, future feature) must be per-owner
  equality — `WHERE owner_entity_id = <building>` — indexed for exactly
  that.
- `mobile_entity_state` (~20–25K rows/region) and the full
  `progressive_action_state` table are borderline; prefer the
  per-building / per-owner filters above.

## 6. Open decision

Craft tasks: per-building subscriptions (precise, re-subscribe when the
building set changes) vs whole-table + client-side filter (the relay's
stance; both tables are small enough that `USED-TABLES.md` carries no
size warning, unlike the guardrailed ones). v1 ships per-building
equality plus the `owner_entity_id = <me>` personal set — one claim's
building set is small and changes rarely.
