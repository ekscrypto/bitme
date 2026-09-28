---
name: craft-visibility
description: BitCraft craft privacy and sharing rules for the Crafter crafts projection — passive vs progressive crafts, public_progressive_action_state membership, which craft rows may render (own pending + others' shared-in-progress), progress-as-effort math (server-side accrual, stamina, crits), the client-driven _start/complete action loop with server cadence validation (no repeat reducer, 95%/80% band, strikes), and skill_desc skill-id mapping. Use when changing craft tracking or rendering (CrafterRep, RegionBuildingRows, State, Crafter views), occupancy or progress bars, craft filters, skill grouping, or anything that paces or validates craft/extract actions.
---

# BitCraft craft visibility & sharing

Craft privacy is a game concept, not an app policy. The rules below decide
which craft rows may ever render in the Crafter.

## Privacy model

- **Passive** (time-based) crafts are **always private**.
- **Progressive** (effort-based) crafts are private or shared: shared ⇔
  listed in `public_progressive_action_state` (subscribed per building,
  like the craft tables).

## Which rows render

Rows = the player's own pending crafts + others' shared bench crafts while
`progress < craft_count × recipe.actions_required`.

Everyone else's work (private, abandoned, finished-uncollected) renders
nowhere — no occupancy chips. Abandoned private prep crafts linger in the
tables for months and **must never surface**.

## Progress math

`progress` is cumulative *effort*, not items — the progress-bar denominator
is `craft_count × recipe.actions_required`. Effort accrues server-side on
the completion call: `progress += min(remaining, damage)` with
`damage = (tool_power + skill_power) × crit_multiplier` (rounded), and
`stamina -= recipe.stamina_requirement` per completed iteration
(`craft.rs::reduce`, BitCraftPublic). `craft_completed_event` fires at the
denominator — that, not `progress` polling, is the completion signal.

## Action loop & server cadence validation (BitCraftPublic)

Active crafts run as client-re-called pairs — `craft_continue_start`
(arms, charges nothing) → `craft_continue` (completes, charges stamina,
adds effort). No "repeat" reducer exists; there is no server auto-repeat
(the `passive_craft_*` path is the server-driven exception). The server
never trusts client timing:

- cooldown is server-computed: `recipe.time_requirement ×
  1/(CraftingSpeed + skill_speed − 1)` (extraction uses GatheringSpeed —
  the buffed ~1.06 s forage swing);
- completion earlier than **95 %** of that delay: **80–95 %** = strike,
  **< 80 %** = `"Tried to … too quickly"` fail (action cleared, must
  re-arm via the `_start` call); `was_consumed` also blocks double
  completes ("Invalid repeat action");
- strikes (`move_validation_strike_counter_state`, admin-tuned window in
  `private_parameters_desc`) escalate to hard rejection — and position
  resets for `player_move`;
- request timestamps are sanity-clamped: ≤ 1 s ahead / ≤ 8 s behind
  server clock, monotonic. They are ms; row/server timestamps are µs.

Observation guardrail: `*_event` tables (`craft_continue_start_event`, …)
are v2-subscription-only, and a caller's own actions are never echoed to
them — craft tracking stays on `progressive_action_state` /
`public_progressive_action_state`, never events.

## Recipe skill ids

Come from `skill_desc` (2 Forestry … 13 Cooking, 14 Foraging; 0/1
sentinels), NOT the stat-list ordinals — an off-by-two there once rendered
Mining crafts under Scholar.

## Reference

Subscription set, table shapes (BSATN field order), and guardrails:
[docs/protocol/region-claim-buildings.md](../../../docs/protocol/region-claim-buildings.md).
Captured wire layouts, the no-repeat reducer idiom, and the full cadence-
validation chain:
[docs/protocol/region-move-and-craft-continue.md](../../../docs/protocol/region-move-and-craft-continue.md)
