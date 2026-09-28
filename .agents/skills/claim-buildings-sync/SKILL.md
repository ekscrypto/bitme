---
name: claim-buildings-sync
description: Design and guardrails of the live claim-buildings sync on the game session's single region leg — subscription sets, EventBuffer 0.5 s event pooling, debounced additive craft subscriptions, the consume/recordDelta row pipeline, and phone-safe table filters. Use when changing RegionBuildingsClient, RegionBuildingRows, ClaimBuildingsEvent/RegionCraft types, the crafts projection (CrafterRep, WorkstationsRep), adding region tables or subscriptions, or debugging region-leg, EventBuffer, or subscribe behavior.
---

# Claim-buildings sync

Full reference: [docs/protocol/region-claim-buildings.md](../../../docs/protocol/region-claim-buildings.md).
Implementation: `Core/Sources/BitMeCore/RegionBuildingsClient.swift`.

## One region leg

All region-DB traffic rides the single region-leg websocket
(`GlobalSessionClient` yields it as `.regionLeg`) — the game allows one
live session per account per database; a second connection is closed
with code 4000. Never open a second region connection.

## Sync shape

1. Static catalogs load first, cache-first with a 48 h TTL — names and
   classification resolve from the very first row event on.
2. One base subscription set: the claim slice (`building_state WHERE
   claim_entity_id`, `claim_state`, whole-table `building_nickname_state`)
   plus the player's own crafts on both craft tables.
3. As building batches arrive, `BuildingSet` debounces (0.25 s) one
   additive subscribe covering the new buildings' craft rows (both craft
   tables + `public_progressive_action_state`). Additive-subscribe errors
   are logged, not fatal — the next building change re-attempts.

## Row pipeline

Attach `tableEvents` streams **before** `subscribe` — the initial
snapshot fans out when SubscribeApplied lands. Updates arrive as
delete+insert pairs in one event, applied delete-first so a pair lands as
an upsert. Each table drains through `consume()` (decode + snapshot
logging) and reports counts via `recordDelta` — a new table goes through
this same pair. Row events pool 0.5 s in `RegionBuildingsClient.
EventBuffer` (one flush = one ingest; status events and the 512-event cap
flush immediately). Each drain logs one pooled line:
`claim buildings: pool <table> +n −m, …` — that line is the diagnostic
cadence (mutators are pure; diagnose here, not in the machine).

## Phone guardrails (measured row counts)

- **Never** subscribe `building_state` (~74K rows/region) or
  `location_state` (~13M) unfiltered — claim-filter / dimension-filter
  only.
- `inventory_state` per-owner equality only.
- Craft tables per-building or per-owner, never whole-table
  (`mobile_entity_state` ~20–25K and whole `progressive_action_state`
  are borderline; keep them filtered).

## Projection facts

A progressive craft's progress denominator is
`craft_count × actions_required` — never `craft_count`. The projection
drops completed passive crafts and caps the row list at 200
(`craftsOverflow` carries what the cap dropped). Shared-craft rendering
rules (whose crafts may appear at all) live in the `craft-visibility`
skill.
