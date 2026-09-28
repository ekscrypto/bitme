---
name: craft-visibility
description: BitCraft craft privacy and sharing rules for the Crafter crafts projection — passive vs progressive crafts, public_progressive_action_state membership, which craft rows may render (own pending + others' shared-in-progress), progress-as-effort math, and skill_desc skill-id mapping. Use when changing craft tracking or rendering (CrafterRep, RegionBuildingRows, State, Crafter views), occupancy or progress bars, craft filters, or skill grouping.
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
is `craft_count × recipe.actions_required`.

## Recipe skill ids

Come from `skill_desc` (2 Forestry … 13 Cooking, 14 Foraging; 0/1
sentinels), NOT the stat-list ordinals — an off-by-two there once rendered
Mining crafts under Scholar.

## Reference

Subscription set, table shapes (BSATN field order), and guardrails:
[docs/protocol/region-claim-buildings.md](../../../docs/protocol/region-claim-buildings.md)
