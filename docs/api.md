# Bit-Me — Relay API Reference

The two HTTP endpoints Bit-Me consumes, served by the relay-cache embedded in
the mirror fleet at **`https://relay.bitcraftsync.app`**. Plain JSON over
HTTPS — no authentication, no WebSocket, no SpacetimeDB protocol. The app
only polls.

> **Source of truth:** the relay repo's
> `spacetimedb-bitcraft-mirror/crates/relay-cache/BITME-API.md`
> (handlers: `src/bitme_serve.rs`, tracker: `src/bitme.rs`). This document
> mirrors it for Bit-Me development; if the two ever disagree, the relay
> repo wins. Design history: `relay-bitcraftsync-app/BITME-DATA-ASSESSMENT.md`.
> Last synced: 2026-09-05.

---

## 1. Conventions

| Convention | Detail |
|---|---|
| Transport | HTTPS GET, JSON responses. `Cache-Control: no-store` on every response. CORS: `*`. |
| Entity ids | **JSON strings** — upstream ids are u64 and exceed JS `Number.MAX_SAFE_INTEGER`. Never parse them as numbers. |
| Positions | `world_x`/`world_z` are float world units (upstream milli-units ÷ 1000; one tile = 1.0). `tile_x`/`tile_z` are integer odd-r tiles (`floor(world)`), same coordinate space as the relay's `/roads` endpoints. |
| Clocks | `*_ms` fields are unix **milliseconds**. Buff `start_timestamp`/`duration` are unix **seconds**. `stamina.last_decrease_at` is RFC 3339. `server_time_ms` lets you correct for device clock skew. |
| Nulls | Present-but-`null` means *unknown or not applicable* — never an error. Every documented field is always present on the wire. |
| Errors | `400` with `{"error": "…"}` for bad input; `404` with `{"found": false, …}` for misses. |
| Rate limits | None enforced today (nginx 60 s timeouts only). Design for **1 Hz polling** per active session; a snapshot is ~2–6 KB. |
| Sessions | A `GET /bitme/session/:id` **is** the registration. Stop polling for >15 min and the server drops its tracking (next poll transparently re-registers). |

---

## 2. `GET /bitme/resolve?name=<username>`

Resolve a character name to the ids/region Bit-Me needs to open a session.
**Exact match on the lowercase name** — this is not a search. (Substring
player search exists separately at `GET /player?name=` — do not use it for
onboarding.)

Works for players of **all 25 regions** (global-module data), independent of
which regions the mirror currently covers.

| Param | Required | Meaning |
|---|---|---|
| `name` | yes | Player name, any case (lowercased server-side, exact match) |

### Response `200`

```json
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
```

| Field | Type | Meaning |
|---|---|---|
| `found` | bool | Always `true` on 200. |
| `entity_id` | string | Player entity id — the key for `/bitme/session/:id`. |
| `username` | string | Display-cased name (region shard; falls back to lowercase form). |
| `username_lowercase` | string | The exact key that matched. |
| `identity` | string \| null | SpacetimeDB identity, canonical big-endian hex, no `0x` prefix. |
| `region_id` | int \| null | Home region (1–25). |
| `region_name` | string \| null | Player-facing region name (e.g. `Virexal`). |
| `host` | string \| null | Region sign-in host. |
| `module` | string \| null | Database/module name (e.g. `bitcraft-live-7`). |
| `signed_in` | bool \| null | Live sign-in state. `null` only when neither the global presence set nor a mirrored home region knows. |

### Errors

```json
HTTP 404  {"found": false, "name_lowercase": "nosuchuser123"}
HTTP 400  {"error": "missing or empty `name` query parameter"}
```

---

## 3. `GET /bitme/session/:entity_id`

One snapshot with everything the activity screens render. `entity_id` is the
decimal-string player entity id from **resolve**.

Poll cadence: ~1 Hz while the player is active in the app. The poll keeps the
server-side tracker alive; target health and spawn tracking only accumulate
while sessions are being polled.

### Response `200` (top level)

```json
{
  "found": true,
  "player_entity_id": "504403158290646123",
  "username": "Whisper",
  "signed_in": true,
  "region": 7,
  "position": { … },
  "claim": { … },
  "stamina": { … },
  "buffs": [ … ],
  "actions": [ … ],
  "target": { … },
  "activity_spawns": [ … ],
  "server_time_ms": 1788628492673
}
```

| Field | Meaning |
|---|---|
| `signed_in` | `null` when unknown. Judge liveness together with `position.age_ms`. |
| `server_time_ms` | Relay clock at snapshot build; use for skew correction (§5.1). |

### 3.1 `position` — last known world position

```json
{
  "world_x": 11173.0,      "world_z": 13848.002,
  "tile_x": 11173,         "tile_z": 13848,
  "destination_world_x": 11173.0, "destination_world_z": 13848.002,
  "dimension": 1,
  "is_walking": false,
  "timestamp_ms": 1788628340546,
  "age_ms": 152127
}
```

- `dimension: 1` is the overworld; `> 1` is a building/dungeon interior
  (then `world_*` are interior coords and **`claim` is not resolved**).
- The row **persists after logout** — it is the *last known* position. Judge
  freshness by `age_ms`, and `signed_in` for liveness.
- `null` when the entity has no mobile row (never observed in a mirrored
  region).

### 3.2 `claim` — claim under the player's tile (`null` when none)

```json
{
  "entity_id": "504403158281321768",
  "name": "Hex and Highwater Port",
  "owner_player_entity_id": "1008806316547466858",
  "neutral": false
}
```

`null` in unclaimed wilderness, in interiors, or if the roads cache is
disabled (it is enabled in production).

### 3.3 `stamina`

```json
{
  "current": 370.5,
  "max": 471.0,
  "max_health": 210.0,
  "last_decrease_at": "2026-09-05T17:14:52.000Z"
}
```

- `current`/`max` are floats (upstream F32).
- Regeneration is **not** simulated server-side. Project forward client-side
  using the passive regen rules from bundled gamedata, anchored at
  `last_decrease_at`/`current` (see the harvest tutorial, §4.3).
- `null` when the player has no stamina row.

### 3.4 `buffs` — live buffs only

```json
{ "buff_id": 5887916, "start_timestamp": 1788627036, "duration": 3600,
  "values": [0.092, 0.092] }
```

- Zeroed placeholder entries (upstream lists every buff type the entity ever
  saw) are filtered server-side; what remains is live.
- Countdown = `start_timestamp + duration − now` (unix **seconds**). Expired
  entries may linger until the next upstream flush of the row — **check the
  countdown, not just presence**.
- `values` are raw modifier numbers; map `buff_id` → name/icon/effects via
  bundled gamedata (`buff_desc`).

### 3.5 `actions` — action lifecycle (usually ≤ 2, one per layer)

```json
{
  "auto_id": "122145",
  "action_type": "Craft",
  "layer": "Base",
  "start_time_ms": 1788628492480,
  "duration_ms": 1088,
  "ends_at_ms": 1788628493568,
  "target_entity_id": "504403158308175117",
  "recipe_id": 109007,
  "last_action_result": "Success",
  "client_cancel": false
}
```

- `action_type`: `None`, `Attack`, `Extract`, `Craft`, `Build`, `Terraform`,
  `Sleep`, `Death`, `Prospect`, … (upstream sum variants, PascalCase).
- `layer`: `Base` or `UpperBody` (a player can run one of each).
- **Rows persist after completion** — they are the *last* action on that
  layer, not necessarily a running one. An action is in progress iff
  `server_time_ms < ends_at_ms` (and `last_action_result == "Success"`).
- Progress bar: `(now − start_time_ms) / duration_ms`.
- `recipe_id` → recipe gamedata for extract/craft progress naming.

### 3.6 `target` — the acted-on entity, enriched (`null` when no target)

```json
{
  "entity_id": "504403158302441789",
  "resource_id": 38,
  "name": "Flint Pile",
  "health": 2398,
  "max_health": 10000,
  "despawn_time_secs": 0.0,
  "respawn_time_secs": 600.0,
  "location": { "tile_x": 10213, "tile_z": 12367 }
}
```

- Primary target = the **`Extract` action's target**, else the `Base`-layer
  target (e.g. a crafting station, which has `resource_id: null` because it
  is a building, not a resource).
- `health` is tracked server-side **only while a session is polling** and
  only from the first extract tick onward: expect `null` on the first poll
  after targeting, then per-tick updates.
- `resource_id`/`name`/`max_health` resolve via the roads harvestable index,
  the spawn log, and `resource_desc` gamedata; unknown resource types keep
  `null` identity but still report `health`.
- `despawn_time_secs` / `respawn_time_secs` are passthrough gamedata for
  client-side countdowns.

### 3.7 `activity_spawns` — watched spawns in the player's area

```json
{
  "entity_id": "504403163787158939",
  "resource_id": 2089325907,
  "name": "Baited School Of Muddy Auratus",
  "health": null,
  "max_health": 3000,
  "location": { "tile_x": 11448, "tile_z": 11357 },
  "spawned_at_ms": 1788622724778,
  "expires_at_ms": null
}
```

- **What is watched:** every resource the game can spawn as the destroy-yield
  of another resource (growth/respawn chains — Withering → Bountiful berry
  bushes, depleted ore → fresh ore, baited fishing schools, …) plus the three
  **Citric Giant berry bushes**. This is the citric-detection signal.
- **Scope:** only spawns located in the player's current claim — or in
  unclaimed wilderness when the player is outside any claim — and in the
  player's region. Interior/dungeon spawn churn is dropped.
- Entries disappear when the resource is harvested/despawned (upstream
  delete) or after 30 minutes.
- `expires_at_ms` = `spawned_at_ms + despawn_time` when the resource gamedata
  has a despawn timer; otherwise `null` (compute client-side from gamedata).
- `health` non-null means someone is already harvesting it.

#### Citric / Bountiful Berry Bush gamedata ids

| resource_id | Name | Notes |
|---|---|---|
| `1688062540` | Citric Giant Strawberry Bush | **Citric event** — watch `activity_spawns` for these |
| `65901922` | Citric Giant Savory Berry Bush | Citric event |
| `1875092977` | Citric Giant Zesty Berry Bush | Citric event |
| `1822942131` | Giant Bountiful Strawberry Bush | Harvestable bush (max_health 500) |
| `353689546` | Giant Bountiful Savory Berry Bush | Harvestable bush |
| `1713099134` | Giant Bountiful Zesty Berry Bush | Harvestable bush |
| `2022069397` | Withering Giant Strawberry Bush | Destroying yields the Bountiful bush |
| `379556870` | Withering Giant Savory Berry Bush | idem |
| `206224604` | Withering Giant Zesty Berry Bush | idem |

All nine share a 7-hex footprint and the `Bountiful Berry Bush` tag.

### Errors

```json
HTTP 404  {"found": false, "player_entity_id": "…",
           "error": "player not present in any mirrored region"}
HTTP 400  {"error": "entity_id must be a u64"}
```

A player **resolves globally** even when their region is not mirrored, but a
**session requires them to be present** in one of the mirrored regions
(currently 3, 7, 8, 9, 11, 12, 13, 14, 15, 17, 18, 19, 23 — read dynamically
from `GET /roads/regions` rather than hardcoding).

---

## 4. Readiness, deploys, failure modes

- **Readiness probe:** `GET /cache-health` → `{"ready": true, …}`. If
  `ready` is `false`, treat all relay data as stale.
- **Deploys restart the mirror** (~15–20 min reseed). During that window both
  endpoints return `404 {"found": false, …}` and `/cache-health` flips to
  `ready: false`. Retry with backoff (≥ 30 s). Countdowns already on screen
  can keep running from the last snapshot — show a "reconnecting" state.
- Upstream game-server resets can also momentarily empty stores; same backoff.
- Never hold state across deploys — on persistent `404`/`ready: false`,
  re-resolve.

---

## 5. Clock skew correction

Snapshot fields are computed against the relay clock and returned with
`server_time_ms`. To render countdowns that survive device clock drift:

```
offset_ms = server_time_ms - Date.now()          // on each snapshot
now(relay) = Date.now() + offset_ms              // when interpolating
```

Recompute `offset_ms` on every poll (1 Hz) — it absorbs both drift and
network jitter accumulation between snapshots.
