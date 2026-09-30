# Prospecting — the compass data model

Where the prospecting target lives on the wire, what the client actually
receives, and how Bit-Me X-Ray derives the target area. Everything here was
verified live 2026-09-29/30 against `bitcraft-live-14` on the relay mirror
(anonymous `v2.bsatn` subscriptions; `bitcraft-mats/Sources/bitcraft-streamd/
src/bin/prospect_watch.rs` was the ground-truth harness).

## Tables

| Table | Access | Purpose |
|---|---|---|
| `prospecting_desc` | public | Config per activity (63 rows): crumb count/radius/distance `[min,max]` ranges, deadzone, durations, join radius, messages. |
| `crumb_trail_state` | **private** | The truth: `original_location`, `crumb_locations[] {x,z,dimension}`, `crumb_radiuses[]`, `prize_location`, `prize_entity_ids[]`, `active_step`, `join_radius`. Never transmitted to any client; never replicated. |
| `prospecting_state` | public, PK `entity_id` | One row per active prospector: the compass projection (below). Deleted when the trail completes or is abandoned. |
| `crumb_trail_exposed_state` | public, PK `crumb_trail_entity_id` | `exposed_locations[] {x,z,dimension}` — exact crumb/prize positions, published as players enter them (cumulative row replacements). Also `exposed_herd_entity_id`. |
| `prospect_start_event` | public event | `{actor_id, prospecting_id, timestamp_ms}` when a nearby player starts. |
| `herd_state`, `crumb_trail_contribution_lock/spent_state`, `prospecting_participants` | public | Multiplayer join / contribution bookkeeping; herd linkage. |

The game client's own subscription set (captured, `tools/tap/
2026-09-28_00-24-16`): `SELECT * FROM prospecting_desc`,
`SELECT * FROM prospecting_participants`, `SELECT * FROM
prospect_start_event`, and `prospecting_state` joined to
`mobile_entity_state` per chunk. Bit-Me needs only the own-row equality
slice (`WHERE entity_id = <player>`).

## The compass projection (`prospecting_state`)

Field order (BSATN, schema-pinned 2026-09-29):

```
entity_id u64, prospecting_id i32, crumb_trail_entity_id u64,
completed_steps i32, ongoing_step i32, total_steps i32,
next_crumb_angle [f32], last_prospection_timestamp (i64 micros),
contribution i32, to_next_node f32
```

- `next_crumb_angle` — radians, world-relative, `atan2(Δz, Δx)` (0 = +x,
  sweeping toward +z; +z is map-north). Two entries during crumb steps:
  `[lo, hi]` of a cone whose **midpoint is the true bearing** (±8–25° of
  slop observed — the "loosely pointing compass"). One entry on the final
  step: a precise bearing to the prize.
- `to_next_node` — distance from the player's current position to the next
  target (crumb, or prize on the final step), **world units** (1 = 1 tile).
- `total_steps` — rolled `bread_crumb_count` **+ 1** final step (desc
  `[3,4]` → observed totals 4 and 5).
- `contribution` — +`contribution_per_visited_bread_crumb` per crumb
  entered.

Numeric verification (trail `…298591`/`…367684`, player
`1297036692699996362`): bearing computed from the player's interpolated
position to the later-exposed crumb matched the displayed cone midpoint to
<0.002 rad; the final-step single needle matched to ~0.02 rad (position
interpolation error).

## Units

- `crumb_trail_state` / `crumb_trail_exposed_state` coordinates: **integer
  world units** (tile scale).
- `mobile_entity_state` positions: **milli-units** (÷ 1000 → world).
- `to_next_node`, `bread_crumb_radius`, `distance_between_bread_crumbs`:
  world units.
- `last_prospection_timestamp`: microseconds since the Unix epoch.
- `prospect_start_event.timestamp`: milliseconds.

## Flow

`ProspectStart` creates the private trail + the public `prospecting_state`
row and broadcasts `prospect_start_event`. `Prospect` re-checks: inside
`bread_crumb_radius` → step advances, contribution accrues, a fresh cone is
published, and the crumb's exact position is appended to
`crumb_trail_exposed_state` (shared — everyone sees it). The final step
reveals the prize (chest / resource clump / herd) at `prize_location`; the
row is deleted on completion or abandonment.

## X-Ray usage

`RegionProspectClient` subscribes the own-row slice anonymously on the
mirror (`relay.bitcraftsync.app:300<region>`, db `bitcraft-live-<region>`)
— the mirror accepts anonymous reads even though the game's own servers do
not. `MapRep.prospect` carries the cone + range and `MapScreen` renders the
wedge, the range arc, and the crumb-radius circle at the cone midpoint.

The fix origin matters: the server measured the bearing from where the
player stood at `last_prospection_timestamp`, so the mutator captures the
position once per fix (keyed on that timestamp — contribution-only row
rewrites and reconnect re-deliveries reuse the stored origin) and the
overlay is anchored there, static until the next prospection. It never
follows the moving player marker.
