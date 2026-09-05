# Bit-Me — Data Requirements & Relay Extension Spec

> **⚠️ SUPERSEDED (2026-09-05).** Phase 1 of this spec was implemented by the
> relay team with a different — and better-fitted — acquisition model:
> server-side claim-scoped tracking exposed as two JSON HTTP endpoints
> (`/bitme/resolve`, `/bitme/session`), with polling instead of client-held
> WebSocket subscriptions. See [`api.md`](api.md) for the live API,
> [`tutorial-onboarding-and-polling.md`](tutorial-onboarding-and-polling.md)
> and [`tutorial-harvest-session.md`](tutorial-harvest-session.md) for app-side
> usage, and `relay-bitcraftsync-app/BITME-DATA-ASSESSMENT.md` for why the
> design changed and what was verified live. This document is kept for design
> history; its §6 static-gamedata list still applies as written.

Handoff document for the `spacetimedb-relay` development agent.
Prepared from the BitCraft module schemas mirrored by the relay fleet
(`bitjita-schema-global.json` / `bitjita-schema-region.json` in `bitcraft-mats`).

## 1. What Bit-Me is

A cross-platform mobile companion app that gives a player large, glanceable,
time-critical feedback while harvesting a timed world resource. Reference
scenario (drives all requirements below):

> Player activates a **Giant Bountiful Strawberry Bush**. It stays harvestable
> for ~10 minutes. When it runs out, a **Citric Giant Strawberry Bush** spawns
> in its place for only ~30 seconds, yielding rare resources. During the
> session the player's **stamina** drains per harvest and their **food buff**
> (which regenerates stamina while inactive) may expire.

App screens driven by this data:

| Indicator | Source of truth |
|---|---|
| Big countdown: time left on the active bush | player's current action + target resource health |
| "Eat food now" alert (before citric phase) | stamina level + active food buff expiry |
| Side indicator: food buff active / missing | active buffs |
| "Stamina recovering — full in Xs, resume at T" | stamina + regen params |
| Character offline / connection lost | player signed-in state |

Session flow: user types character name → app resolves **name → entity_id →
region** via the global module → app opens **one filtered WebSocket
subscription per needed table** against that region's mirror → renders.

## 2. Design principle

All heavy filtering happens **server-side in the subscription SQL**. The
mobile app must never receive an unfiltered snapshot of any large table.
The worst offenders (region module): `location_state` (every entity
position), `resource_state` / `resource_health_state` (every resource node),
`player_lowercase_username_state` (every player ever). These are the GB-scale
tables; every other table we need is one-row-per-player and tiny once
filtered by `entity_id`.

The relay already speaks SpacetimeDB's `v1.json.spacetimedb` subscribe
protocol (`SubscribeSingle` with SQL — proven by `bitcraft-relay-snapshot`).
JSON-over-WebSocket is ideal for mobile: no BSATN decoder needed.

## 3. Onboarding: name → entity_id → region (global module, port 3000)

All tables below are **PUBLIC** in `relay-mirror-bc-global`. Resolution chain,
one filtered subscription each (or one joined query if the relay supports
multi-table subscription SQL):

| Step | Table | Filter | Used columns |
|---|---|---|---|
| 1 | `player_lowercase_username_state` | `WHERE username_lowercase = ?` | `entity_id` |
| 2 | `user_state` | `WHERE entity_id = ?` | `identity`, `entity_id` |
| 3 | `user_region_state` | `WHERE identity = ?` | `region_id` |
| 4 | `region_connection_info` | full table (tiny, few rows) | `id`, `host`, `module` |
| 5 | `world_region_name_state` | full table (tiny) | `id`, `player_facing_name` |
| 6 | `player_state` | `WHERE entity_id = ?` | `signed_in`, `sign_in_timestamp` |

Notes:
- `player_username_state` (non-lowercase) is also PUBLIC if exact-match
  display names are preferred; the lowercase table is better for user input.
- Steps 1–3 can be one subscription with joins if allowed:
  `SELECT u.entity_id, r.region_id FROM player_lowercase_username_state p JOIN user_state u ON p.entity_id = u.entity_id JOIN user_region_state r ON r.identity = u.identity WHERE p.username_lowercase = ?`
- **Relay gap:** there is no HTTP route that does this join today. Either the
  app performs the 3 filtered subscriptions itself (needs those global tables
  allowlisted), or the relay adds a convenience endpoint (Ask C below).

## 4. Live session: region module (e.g. `relay-mirror-bc14` on :3014)

All tables below are **PUBLIC** in the region module. Every subscription is
parameterized by `player_entity_id` (resolved at onboarding) and, once the
player starts an action, `target_entity_id`.

### 4.1 Player tables — subscribed for the whole session

| Table | Filter | Columns used | Purpose |
|---|---|---|---|
| `player_action_state` | `WHERE entity_id = ?` | `auto_id`, `entity_id`, `start_time`, `duration`, `target`, `recipe_id`, `action_type`, `layer`, `last_action_result`, `client_cancel`, `was_consumed`, `chunk_index` | **The core table.** Tells us the player is harvesting, which entity is the target, when the action started and how long it runs. Insert = action started; delete = done/cancelled. |
| `stamina_state` | `WHERE entity_id = ?` | `stamina`, `last_stamina_decrease_timestamp` | Live stamina + last-drain time; client extrapolates regen ("full in Xs") using static `parameters_desc` tick data. |
| `active_buff_state` | `WHERE entity_id = ?` | `active_buffs` (list of buff id + expiry) | Food buff ("Well Fed") presence and expiry → "buff runs out in X" and "buff gone — eat" alerts. |
| `player_state` | `WHERE entity_id = ?` | `signed_in` | Offline detection. |
| `location_state` | `WHERE entity_id = ?` | `x`, `z`, `chunk_index`, `dimension` | Player position; anchors the citric-detection bounding box (§5) and later features. One row when filtered. |
| `inventory_state` *(optional, P2)* | `WHERE player_owner_entity_id = ?` | `pockets` (item ids + quantities) | Distinguish "no food buff" from "no food in bag" → different alert copy. |

Volume check: all of these are one row per player when filtered — bytes, not
MBs. `player_action_state` and `stamina_state` update at action/tick
frequency (worst case a few updates/second), fine for mobile.

### 4.2 Resource tables — subscribed dynamically while an action targets a resource

| Table | Filter | Columns used | Purpose |
|---|---|---|---|
| `resource_state` | `WHERE entity_id = ?` (target) | `resource_id`, `entity_id` | Confirms the target is a resource and gives its `resource_id` → static `resource_desc` join (name, max_health, despawn behavior). |
| `resource_health_state` | `WHERE entity_id = ?` (target) | `health` | Depletion progress → fraction of `max_health` → the big countdown when combined with observed drain rate. |
| `location_state` | `WHERE entity_id = ?` (target) | `x`, `z` | Target position → centers the citric detection box. |

Subscription lifecycle: when `player_action_state.target` changes to an
entity not yet tracked, the app (or relay) adds the two filtered
subscriptions; removes them when the target changes or the action ends.

### 4.3 Not needed (explicitly out of scope)

`storage_log_state`, `passive_craft_state`, `chat_*`, `claim_*`, `empire_*`,
`trade_*`, `enemy_*`, `combat_*`, housing/deployable/cargo tables, and all
`*_desc` tables over the relay (static gamedata is bundled in the app, §6).
Also **unreachable and not needed**: `resource_spawn_timer`,
`respawn_resource_in_chunk_timer`, `single_resource_clump_info`,
`passive_craft_timer` — all `private`.

## 5. The citric-spawn detection problem (key design point)

The Citric Giant Strawberry Bush is a **new entity with a new `entity_id`**.
Subscribing to the old target's `resource_state` row never sees it. Two
complementary mechanisms:

1. **Depletion prediction (works today):** when the tracked bush's
   `resource_health_state.health` → 0 (or its `resource_state` row deletes),
   the app starts a countdown from the static `resource_desc.despawn_time` of
   the citric variant (resolved via `on_destroy_yield_resource_id` on the
   bountiful `resource_desc` row — verify this link in gamedata).
2. **Positional confirmation (needs relay support):** a bounded spatial
   subscription that catches the new entity's insert near the player:
   ```sql
   SELECT r.entity_id, r.resource_id, l.x, l.z
   FROM resource_state r
   JOIN location_state l ON r.entity_id = l.entity_id
   WHERE l.x BETWEEN ? AND ? AND l.z BETWEEN ? AND ?
   ```
   The box is the target's ±few-tile radius, recentered when the player
   moves. If the relay's subscription engine supports joins + range
   predicates over the mirrors, this is small and safe. **If joins are not
   supported in subscriptions**, the fallback is two range-filtered
   subscriptions (`resource_state` has no location column, so this only works
   relay-side — see Ask B2).

The 30-second citric window itself comes from static data
(`resource_desc.despawn_time`); no private timer table is needed.

## 6. Static gamedata (bundled in the app — zero relay traffic)

Sourced once at build/app-start time via the existing `bitcraft-gamedata`
pipeline (already downloads from the relay's anonymous static export):

| Table | Used for |
|---|---|
| `resource_desc` | resource names, `max_health`, `despawn_time`, `on_destroy_yield_resource_id` (bountiful → citric link), icons |
| `food_desc` | item_id → stamina restore, buffs granted |
| `item_desc` | food item names/icons |
| `buff_desc` + `buff_type_desc` | buff durations, `warn_time`, stats, icons |
| `parameters_desc` | `player_regen_tick_millis`, `min_seconds_to_passive_regen_stamina` (regen extrapolation), other tuning constants |
| `player_action_desc` | `action_type` id → label (harvest vs. other) |
| `tool_desc` / `tool_type_desc` *(P2)* | tool→skill, harvest pacing hints |

Open gamedata question (not relay): exact per-harvest stamina cost and the
precise passive-regen rule; both are static and only needed client-side.

## 7. Relay extension spec (the asks)

**Ask A — Allowlist additions (verify / one-line each).**
Ensure these PUBLIC tables are in the subscription allowlists:

- Region mirrors (`DEFAULT_REGION_TABLES`): `stamina_state`,
  `player_action_state`, `active_buff_state`, `player_state`,
  `resource_state`, `resource_health_state` (the last two may already be in
  from the hexite work), `inventory_state`.
  (`location_state` is already allowlisted.)
- Global mirror: `player_lowercase_username_state`, `user_state`,
  `user_region_state`, `region_connection_info`, `world_region_name_state`,
  `player_state`, `signed_in_player_state`.

**Ask B — Capability confirmation (critical path).**

1. **Filtered subscriptions:** confirm the relay evaluates `WHERE entity_id =
   ?` predicates in `SubscribeSingle` queries so the client receives only
   matching rows in `SubscribeApplied` and subsequent deltas. This is the
   single most important item — everything in §4 depends on it. If the relay
   currently re-broadcasts whole tables to subscribers regardless of WHERE,
   that must change (row-filtered forwarding).
2. **Join subscriptions:** confirm whether subscription SQL may join two
   tables (needed for the §5 positional query). If not supported, state so
   explicitly and consider the relay-side helper in Ask C/D instead.
3. **Dynamic subscribe/unsubscribe:** the app will add and remove
   subscriptions over one connection as the action target changes. Confirm
   this is supported per-connection (SpacetimeDB's usual model) and whether
   there is a per-connection subscription-count limit worth knowing.

**Ask C — Small HTTP convenience endpoint (recommended).**
`GET /v1/resolve-player?name={lowercase_name}` on the global mirror:
`player_lowercase_username_state ⋈ user_state ⋈ user_region_state ⋈
region_connection_info` → `{ entity_id, identity, region_id, host, module,
signed_in }`. Saves the app 3 WS round-trips and keeps the global username
table behind a server-side filter. Cacheable (names are stable;
`signed_in` should be short-TTL or omitted).

**Ask D — Volume guardrails.**
Reject (or hard-cap) subscriptions without an `entity_id`/range predicate on:
`location_state`, `resource_state`, `resource_health_state`,
`player_lowercase_username_state`, `inventory_state` for anonymous/mobile
clients. This protects the mirrors from a future client mistake and lets
Bit-Me ship knowing the failure mode is an error, not a 2 GB snapshot.

**Ask E — Optional phase-2: purpose-built session channel.**
If Bit-Me grows past one resource type, consider a streamd-style endpoint
(`/ws/session/{player_entity_id}`, JSON) that performs the §4/§5 joins
server-side and emits semantic events only:
`session_started`, `action_started {target, resource_id, duration}`,
`resource_health {value, max}`, `citric_spawned {entity_id, expires_at}`,
`stamina {value, last_decrease_ts}`, `buff_update [{buff_id, expires_at}]`,
`session_ended`. A few KB/min per client. Phase 1 does not require this —
raw filtered subscriptions are sufficient — but it moves all filtering logic
off the phone and makes future "Bit-Me" scenarios (crafting timers, combat)
cheap to add.

## 8. Open questions for the relay agent

1. Do `SubscribeSingle` WHERE clauses filter server-side today (Ask B1)? If
   yes, is there a max query complexity / rows-per-subscription limit?
2. Are join queries permitted in subscriptions (Ask B2)?
3. What is currently in each module's allowlist (exact contents of
   `DEFAULT_REGION_TABLES` and the global equivalent)?
4. Timestamps: confirm SpacetimeDB `Timestamp` arrives as microseconds since
   epoch in the JSON subprotocol, and that `stamina_state.stamina` is an
   integer with a known max (or whether max stamina must come from
   `character_stats_state`).
5. Recommended client identity/token strategy for anonymous mobile
   connections (relay assigns an `IdentityToken` on connect — any per-identity
   subscription limits we should design for?).
6. Reconnect semantics: after a phone backgrounding/network switch, can the
   client re-subscribe and receive a fresh consistent `SubscribeApplied`
   snapshot for its filtered queries (idempotent re-sync)?

## 9. Mobile app notes (Bit-Me side, for completeness)

- Transport: standard WebSocket, subprotocol `v1.json.spacetimedb`, JSON
  messages — no BSATN dependency on mobile.
- All countdowns (10-min bush window, 30-s citric window, stamina-full ETA,
  buff expiry) are **computed client-side** from row timestamps + static
  gamedata; the wire carries state, not rendered timers.
- Expected steady-state bandwidth: tens of KB per session. Well within
  mobile constraints.
