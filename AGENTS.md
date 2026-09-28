# AGENTS.md

Guidance for AI agents working in this repo. Project overview, architecture,
build/test commands, and documentation index: see [README.md](README.md).

## Local reference projects

Three sibling checkouts answer most questions about the game servers' data
models and the relay that serves this app. Consult them locally before making
external queries.

| Project | Path | Use it for |
|---|---|---|
| Relay workspace | `../relay-bitcraftsync-app` | Production topology of `relay.bitcraftsync.app` and the design rationale behind the Bit-Me API. |
| SpacetimeDB BitCraft mirror | `../relay-bitcraftsync-app/spacetimedb-bitcraft-mirror` | Source of truth for the Bit-Me relay API and the full SpacetimeDB server/protocol source the game runs on. |
| BitCraft Materials Coordination | `../bitcraft-mats` | The BitCraft module table schemas — the game servers' actual data model. |

### `bitme-resources/` — extracted game art (nested, private)

`bitme-resources/` inside this checkout is its own **private** repo
(github.com/ekscrypto/bitme-resources; gitignored here, not a submodule)
holding 3,310 icons/tier-rarity PNGs extracted from the BitCraft client.
Source map, tier palette, refresh procedure:
[docs/client-assets.md](docs/client-assets.md); tooling:
[tools/asset-extraction](tools/asset-extraction/).

### `relay-bitcraftsync-app` — relay workspace

Mirrors `/srv/relay/` on the production host; its own `AGENTS.md` documents
the live topology. Two repos live inside: `spacetimedb-bitcraft-mirror`
(production mirror + cache + health) and `bitcraft-relay/` (ops layer —
systemd units, nginx, and the explorer/tutorial/dashboard web tools).
Key documents in the workspace root:

- `DEPLOY.md` / `DEPLOY-ARCHIVE.md` — how (and when) production was deployed;
  relevant when API behavior changed at a deploy boundary.
- Note: `BITME-DATA-ASSESSMENT.md` is cited as the design-history source by
  our `docs/api.md` and by the relay's `BITME-API.md`, but is **not present**
  in the local checkout — don't go hunting for it; the rationale it carried
  is summarized in `docs/api.md` and the tutorials.

### `relay-bitcraftsync-app/spacetimedb-bitcraft-mirror` — the relay itself

A purpose-built fork of SpacetimeDB (pinned to the v2.7.1 lineage the
BitCraft edge speaks) that mirrors all `bitcraft-live-*` region databases in
one process, with the embedded `relay-cache` serving the Bit-Me HTTP API.

- `crates/relay-cache/BITME-API.md` — **authoritative Bit-Me API reference**;
  handlers in `crates/relay-cache/src/bitme_serve.rs`, tracker in `bitme.rs`,
  table inventory in `USED-TABLES.md`. If it disagrees with our
  `docs/api.md`, the relay repo wins.
- `BITCRAFT-FORK.md`, `MULTI-MIRROR-UPSTREAM-RESETS.md`,
  `MULTI-MIRROR-STARVATION.md` — fork policy and observed upstream (game
  server) behavior: v2.bsatn ingestion, edge ping/pong deadlines, reset
  patterns. The protocol notes in `docs/protocol/` build on these.
- The wider tree is full SpacetimeDB server source (`crates/table`,
  `crates/client-api-messages`, …) — the reference implementation for the
  table/reducer/BSATN data model the game servers expose.

### `bitcraft-mats` — game schema reference

A separate project (the BitCraft Materials Coordination site: inventory,
crafting calculator, settlement planner), but it carries the canonical local
copy of the **BitCraft module schemas**: `bitjita-schema-global.json` and
`bitjita-schema-region.json` (with `bitjita-schema-analysis.md` and
`*.digest.md` companions). These list the game servers' tables and fields —
`player_username_state`, `user_state`, `region_connection_info`, … — and are
what `docs/relay-data-requirements.md` was prepared from. Check them first
when a question is "does the game have a table/field for X?".

## Working notes (hard-won, 2026-09 claim-buildings work)

- **Claim-buildings sync**: reference is
  [docs/protocol/region-claim-buildings.md](docs/protocol/region-claim-buildings.md);
  sync design, row pipeline, and guardrails live in the
  `claim-buildings-sync` skill. The one catastrophic rule: never subscribe
  `building_state` (~74K rows/region) or `location_state` (~13M)
  unfiltered; `inventory_state` per-owner only.
- **spacetimedb-swift-sdk (our fork)**: `connect()` returns *before* the
  handshake — `.connected` means InitialConnection. Attach `tableEvents`
  streams *before* `subscribe`, or the initial snapshot is missed.
  Transport death fails pending calls and emits `.disconnected` (fixed
  2026-09-26; it used to hang callers silently). App tests do not cover
  this layer — adapters stub it; suspect the SDK fork first when only
  live behavior breaks.
- **Architecture discipline that bites**: mutators are pure — no logging,
  no clocks; diagnose at the activity/adapter level (e.g. the loop's
  "received N pooled event(s)" debug line). Activities read no state —
  use the carrier pattern (`ClaimCarrier`, `ResourceStreamCarrier`).
- **Testing**: the full suite runs in <1 s — run it after every edit.
  Test-writing patterns (event-driven `RepCollecting` waits, the
  scripted-adapter machine-flow harness) live in the `event-driven-tests`
  skill.
- **Protocol facts**: the server answers `sign_in` with a ReducerResult
  in ~200 ms — anything slower is a dead handshake, not server slowness.
  BSATN row decoders pin schema field order; after a game update, follow
  the `bsatn-schema-check` skill (schema re-verification + tap-capture
  decoding).
