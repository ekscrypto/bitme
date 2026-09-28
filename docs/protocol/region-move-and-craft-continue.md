# Region leg: player movement & shared-craft resume

Reducer ground truth for the two gameplay actions captured in tap
`captures/2026-09-28_00-24-16`, conn-02 (`bitcraft-live-14`, 186,753 frames,
0 framing errors): moving the player, and resuming a shared craft at a claim
workstation. Verified 2026-09-28 by decoding the capture
(`tools/tap/decode.js`) against the canonical module schema
(`bitcraft-mats/bitjita-schema-region.json`); every byte layout below parses
its captured payloads exactly, with no trailing bytes.

Companion docs: the leg's sign-in gate
([region-sign-in-queue.md](region-sign-in-queue.md)), the claim/craft table
catalog ([region-claim-buildings.md](region-claim-buildings.md)).

## 1. Reducer inventory of the session (319 calls, in order)

| reducers | count | when |
| --- | --- | --- |
| `player_queue_join`, `sign_in`, `set_quest_tracked` | 1 each | sign-in (see the queue doc) |
| `player_move` | 11 | two bursts: approach 01:12:22–24, exit 01:16:54–55 |
| `target_update` | 1 | 01:12:23.9, locking the workstation before crafting |
| `player_action_cancel` | 1 | 01:12:24.4, together with the final stop move |
| `craft_continue_start` / `craft_continue` | 151 / 150 | the craft loop, 01:12:26.6–01:16:00.8 |
| `pause_play_timer` | 2 | 01:12:34 (paused), 01:16:53 (resumed) |

Only 5 of the 319 calls received a `ReducerResult` (all calls carry
`flags: 0`): `player_queue_join`, `set_quest_tracked`, `target_update`,
`player_action_cancel`, and the final `craft_continue_start`, which failed
(§3). Why exactly those five is not resolved from the capture — routine
craft iterations are simply open-loop, with no receipts.

## 2. Moving the player

```rust
player_move(timestamp: u64,                 // client wall clock, MILLISECONDS
            destination: Option<Pos>,       // Pos = (x: i32, z: i32, dimension: u32)
            origin:      Option<Pos>,
            duration:    f32,               // seconds the segment should take
            move_type:   i32,               // 2 = walk segment, 1 = stop
            is_rp_walk:  bool)              // false throughout the capture
```

43 bytes when both positions are `Some`; a `None` position is a 1-byte tag
and shrinks the payload accordingly.

**Decoder trap — this "Option" is a declared `Sum` with variants
`[some, none]`, so `some = 0x00` and `none = 0x01`** (declaration-order u8
tags; the module declares `some` first — the reverse of std `Option`
habit). A decoder assuming none=0 misaligns every field after the first
position and produces garbage coordinates. The type is schema ref 613.

Observed shape of a burst (all 11 calls decoded):

- Walk segments (`move_type = 2`): destination ≈ a few hundred units from
  origin, `duration` 0.02–0.2 s, sent every ~150–500 ms while walking. Each
  call's `origin` equals the previous call's `destination`.
- Stop (`move_type = 1`): `destination == origin` byte-for-byte,
  `duration = 0.0`. Sent once on arrival.
- All positions in this capture: `dimension = 1` — the overworld (same
  convention as the mirror's `location_state WHERE dimension != 1` filter),
  x/z around 23.99M/19.26M.

Companion reducers around movement:

```rust
target_update(owner_entity_id: u64, target_entity_id: u64, generate_aggro: bool)  // 17 B
player_action_cancel(client_cancel: bool)                                          // 1 B, sent true
pause_play_timer(player_entity_id: u64, paused: bool)                              // 9 B
```

`target_update` was aimed at the workstation entity (…4033962, no aggro) on
approach; `player_action_cancel(true)` rode with the stop move — movement
interrupts an in-progress action. `pause_play_timer(paused = true)` was sent
8 s into the craft loop and `paused = false` one second before the exit
walk.

## 3. Resuming a shared craft

Both reducers of the loop share one signature (schema ref 165):

```rust
craft_continue_start(progressive_action_entity_id: u64, timestamp: u64)  // 16 B
craft_continue(        progressive_action_entity_id: u64, timestamp: u64)  // 16 B
```

The captured resume of one shared craft (entity
`1008806320824526897` = `0x0E000000FFEA2831`, constant across all 301
calls — the same id space `public_progressive_action_state` keys on):

```
craft_continue_start ── ~1.36–1.43 s ──> craft_continue ── ~50–90 ms ──> craft_continue_start ── …
```

- The client drives the cadence itself: `timestamp` is its local clock in
  **milliseconds** (frame wall-time ±1 ms), not a server round-trip.
- 151 starts + 150 continues over 3 m 34 s ≈ one iteration per ~1.4 s.
- The loop ended at the final `craft_continue_start` (requestId 312):
  `ReducerResult Err "Not enough stamina."` 36 ms later. That receipt is
  the only per-iteration feedback observed on the wire.

### There is no "repeat" reducer — the pair re-called per iteration IS the repeat

The module (750 reducers, `bitjita-schema-region.json`; the client C#
catalog `docs/protocol/reducers.txt` agrees) declares no repeat-named
reducer. Every active-action loop uses the same idiom — a `_start`/main
pair the client re-calls each iteration, paced by its own cooldown timer:

```rust
extract_start / extract(          // foraging (signature: schema)
    recipe_id: i32, target_entity_id: u64, timestamp: u64 /*ms*/, clear_from_claim: bool)
craft_initiate_start / craft_initiate(    // new craft
    recipe_id: i32, building_entity_id: u64, count: i32, timestamp: u64 /*ms*/, is_public: bool)
craft_continue_start / craft_continue(   // resume shared craft — §3 above
    progressive_action_entity_id: u64, timestamp: u64 /*ms*/)
```

Other players' foraging in this capture confirms it end-to-end: 15
players, 1,523 `extract_start_event` rows, and **1,483 of 1,501
consecutive swings re-hit the same resource node** — each swing is a fresh
client call, not a server auto-repeat. Per player, starts and completions
are ~1:1 (`extract_start_event` : `extract_event`, e.g. 217/215).
Inter-swing gaps: p10 **1.03 s** / median 1.30 s / p90 1.58 s — the
fastest cluster matches the food-buffed foraging cooldown (~1.06 s
in-game), the tail is unbuffed players and jitter.

The one exception is the **passive** craft path (`passive_craft_queue`,
`passive_craft_process`, …): those run server-side on the
`passive_craft_state` status lifecycle (Queued → Processing → Complete)
with no per-iteration client calls.

### Server-side validation of the client cadence (BitCraftPublic source)

Verified against `github.com/clockworklabs/BitCraftPublic` `master`
(sparse clone, 2026-09-28). Every action reducer funnels through the same
chain — `handlers/player_craft/craft.rs`, `handlers/player/extract.rs`
→ `entities/player_action_state.rs` → `reducer_helpers/move_validation_helpers.rs`:

1. **Timestamp sanity** (`validate_move_timestamp`): the client's ms
   timestamp must be ≤ 1 000 ms ahead of the server clock, ≤ 8 000 ms
   behind, and monotonic vs the previous action. A client cannot forge
   time; it can only absorb jitter.
2. **The cooldown is server-computed, never client-claimed**:
   `event_delay() = recipe.time_requirement × 1/(CraftingSpeed|GatheringSpeed
   + skill_speed − 1)` — from the recipe table and the actor's
   `character_stats_state` (food buffs raise the speed stats; that's the
   buffed 1.06 s forage cooldown). It is stored in
   `player_action_state.duration` by `start_action`.
3. **Cadence gate** (`validate_action_timing`), on the completion call
   (`craft_continue` / `extract`): `elapsed = (client_ts − start_time) /
   duration` → **≥ 95 %** passes; **80–95 %** passes but records a
   *strike*; **< 80 %** fails with "Tried to … too quickly"
   (`TimingFail` clears the action — the loop must restart via the
   `_start` call). Last action failed/cancelled → gate skipped (retry-
   friendly).
4. **Strike escalation** (`validation_strike` +
   `move_validation_strike_counter_state`): strikes inside a rolling
   window (`private_parameters_desc.move_validation.*`, admin-tuned,
   private table); past `strike_count_before_move_validation_failure`
   the request is rejected — and for `player_move`, the position is
   reset server-side. Occasional early fires are tolerated; sustained
   over-speed is not.
5. **Repeat protection** (`validate`): completion sets `was_consumed`, so
   a second `craft_continue` without an intervening `craft_continue_start`
   errors "Invalid repeat action"; target and action type must also
   match.

Movement has its own tier (`validate_move_basic` / `validate_move` /
`validate_move_origin`): max speed 100, max hop 7 tiles, duration ≤ 100 s,
dimension/interior-bounds checks, ≤ 3 chunks per hop — with the stricter
terrain/elevation/raycast code present but disabled ("triggered by HTM +
glancing").

Implication for BitMe: an account-driven client could legally drive the
same `_start`/complete pairs, but must honor the server-side cadence —
fire-to-completion no earlier than ~95 % of the recipe delay (or accept
strikes), and never reuse a consumed action.

## 4. Event tables (v2-only — a constraint that shapes who can see them)

The region streams ephemeral `*_event` tables alongside persistent ones.
They are **not** in the module's 475-table schema dump
(`bitjita-schema-region.json` carries no `craft_continue_start_event`) —
event tables ride the v2 wire as inserts-only table updates
(`TableUpdateRows::EventTable` in the fork's
`client-api-messages/src/websocket/v2.rs`; schema flag `is_event`, which
the v1 subscribe-all path explicitly filters out,
`core/src/subscription/subscription.rs`).

**Events are not forwarded over v1 connections — only v2 subscriptions
receive them.** (Protocol rule confirmed against the fork source; the
v1.json leg has no event representation on the wire at all.) Consequences
for this stack:

- the relay mirror's upstream legs (anonymous, v2.bsatn) can receive them —
  the fork re-broadcasts mirrored event tables natively
  (`core/src/host/public_mirror.rs`, "wire-only semantics") — but
  `USED-TABLES.md`'s inventory doesn't list any `*_event` table today;
- BitMe's JSON-protocol clients (`SpacetimeSubscribeClient`,
  `v1.json.spacetimedb`) can never see events — and an anonymous v1.json
  connect to a region edge is closed before the first frame anyway (live
  check 2026-09-28: close 1006, zero frames; the game edge wants v2 or an
  account token);
- the Swift SDK leg (`spacetimedb-swift-sdk`, `v2.bsatn`) **can** subscribe
  to event tables if a feature ever needs them.

Event tables seen in this capture (frames over 5 min; counts ≈ region-wide
activity, not just ours):

| table | frames | during our craft loop |
| --- | --- | --- |
| `enemy_move_event` | 37,287 | 27,314 |
| `deployable_move_event` | 11,235 | 8,078 |
| `craft_continue_start_event` | 8,381 | 5,991 |
| `player_move_event` | 3,429 | 2,477 |
| `extract_start_event` / `extract_event` | 1,523 / 1,472 | 1,101 / 1,058 |
| ~10 more (`*_start_event`, `attack_*`, `emote_*`, …) | ≤ 200 each | — |

`craft_continue_start_event` rows are 24 bytes; across 8,381 rows the
columns are consistently `(u64, u64, u64)` = 54 distinct player ids, 66
distinct progressive-action ids, and a millisecond timestamp — inferred as
`(player_entity_id, progressive_action_entity_id, timestamp_ms)`; a busy
region's shared-craft starts, ~28/s.

**Your own actions are not echoed to you.** Despite whole-table
subscriptions, our own player/craft entity ids never appear in our own
event streams (0 hits in 11,810 `player_move_event` +
`craft_continue_start_event` frames, while our 11 moves and 151 craft
starts were happening). The same holds for the craft's own **state** row:
the server runs `progressive_action_state().update(...)` every completed
iteration (`craft.rs::reduce`), the desktop client held a chunk-scoped
subscription covering the station (see region-claim-buildings §1), yet
**zero `progressive_action_state` update frames arrived in the entire
capture** — the acting client tracks its own progress locally.
Implication for BitMe is asymmetric by design: the app never shares the
session with the desktop game (one session per account), so it only ever
observes crafts **other** players drive — those row updates broadcast
normally. Don't build own-action tracking on either events or own-row
updates; subscribe `progressive_action_state` /
`public_progressive_action_state` (region-claim-buildings §3) for state.

## 5. Timestamp units — requests are ms, everything else is µs

`player_move`, `craft_continue(_start)`, and the event rows carry
**milliseconds**; server-side timestamps (`ReducerResult.timestamp`, table
rows like `passive_craft_state.timestamp`) are **microseconds**, as
everywhere else in the protocol. When replaying captured args, don't mix
the two — a ms value reinterpreted as µs lands ~1970-01-21.
