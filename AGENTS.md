# AGENTS.md

Guidance for AI agents working in this repo. Project overview, architecture,
build/test commands, and documentation index: see [README.md](README.md).

## Local reference projects

Three sibling checkouts answer most questions about the game servers' data
models and the relay that serves this app. Consult them locally before making
external queries. Upstream is the BitCraft 1.0 release host
`bitcraft-release.spacetimedb.com` (databases `idc-global` + `idc-N`; 25
regions, of which only 9 — 7, 8, 9, 12, 13, 14, 17, 18, 19 — have player
settlements and are mirrored).

| Project | Path | Use it for |
|---|---|---|
| SpacetimeDB BitCraft mirror | `../spacetimedb-bitcraft-mirror` | Source of truth for the Bit-Me relay API and the full SpacetimeDB server/protocol source the game runs on. |
| BitCraft relay (ops) | `../bitcraft-relay` | Production topology of `relay.bitcraftsync.app`: systemd units, nginx, ports, fleet scripts, and the explorer/tutorial/dashboard web tools. |
| BitCraft calculator | `../bitcraft-calculator-httpd` | The BitCraft module table schemas (`docs/archive/bitjita-schema-*.json`) — the game servers' data model (pre-1.0 snapshot; re-verify against the live `idc-*` schema). |

The SDK this app is built on, `../spacetimedb-swift-sdk`, is a required
sibling checkout too (`Core/Package.swift` depends on it by path).

### `bitme-resources/` — extracted game art (nested, private)

`bitme-resources/` inside this checkout is its own **private** repo
(github.com/ekscrypto/bitme-resources; gitignored here, not a submodule)
holding 3,310 icons/tier-rarity PNGs extracted from the BitCraft client.
Source map, tier palette, refresh procedure:
[docs/client-assets.md](docs/client-assets.md); tooling:
[tools/asset-extraction](tools/asset-extraction/).

### `spacetimedb-bitcraft-mirror` — the relay itself

A purpose-built fork of SpacetimeDB (pinned to the v2.7.1 lineage the
BitCraft edge speaks) that mirrors the populated `idc-*` region databases
(plus `idc-global`) in one process, with the embedded `relay-cache` serving
the Bit-Me HTTP API.

- `crates/relay-cache/BITME-API.md` — **authoritative Bit-Me API reference**;
  handlers in `crates/relay-cache/src/bitme_serve.rs`, tracker in `bitme.rs`,
  table inventory in `USED-TABLES.md`. If it disagrees with our
  `docs/api.md`, the relay repo wins.
- `BITCRAFT-FORK.md`, `docs/postmortems/MULTI-MIRROR-UPSTREAM-RESETS.md`,
  `docs/postmortems/MULTI-MIRROR-STARVATION.md` — fork policy and observed upstream (game
  server) behavior: v2.bsatn ingestion, edge ping/pong deadlines, reset
  patterns. The protocol notes in `docs/protocol/` build on these.
- The wider tree is full SpacetimeDB server source (`crates/table`,
  `crates/client-api-messages`, …) — the reference implementation for the
  table/reducer/BSATN data model the game servers expose.

### `bitcraft-relay` — ops layer

No Rust: systemd units, nginx snippets, fleet scripts, and the
explorer/tutorial/dashboard sites. `BITCRAFT.md` (global → shard discovery,
the 25-region grid, auth, upstream protocol) and `PORTS.md` are the useful
references; its `AGENTS.md` documents the live topology.

### `bitcraft-calculator-httpd` — game schema reference

A separate project (crafting calculator / planner site), but it currently
carries an archived copy of the **BitCraft module schemas** (EA-era snapshot)
in `docs/archive/`: `bitjita-schema-global.json` and `bitjita-schema-region.json` (with
`bitjita-schema-analysis.md` and `*.digest.md` companions). These list the
game servers' tables and fields — `player_username_state`, `user_state`,
`region_connection_info`, … — and are what `docs/relay-data-requirements.md`
was prepared from. Check them first when a question is "does the game have a
table/field for X?".

## Working notes (hard-won, 2026-09 claim-buildings work)

- **Claim-buildings sync**: reference is
  [docs/protocol/region-claim-buildings.md](docs/protocol/region-claim-buildings.md);
  sync design, row pipeline, and guardrails live in the
  `claim-buildings-sync` skill. The one catastrophic rule: never subscribe
  `building_state` (~74K rows/region) or `location_state` (~13M)
  unfiltered; `inventory_state` per-owner only.
- **spacetimedb-swift-sdk (our own SDK repo, `../spacetimedb-swift-sdk`)**:
  `connect()` returns *before* the
  handshake — `.connected` means InitialConnection. Attach `tableEvents`
  streams *before* `subscribe`, or the initial snapshot is missed.
  Transport death fails pending calls and emits `.disconnected` (fixed
  2026-09-26; it used to hang callers silently). App tests do not cover
  this layer — adapters stub it; suspect the SDK first when only
  live behavior breaks.
- **Architecture discipline that bites**: mutators are pure — no logging,
  no clocks; diagnose at the activity/adapter level (e.g. the loop's
  "received N pooled event(s)" debug line). Activities read no state —
  use the carrier pattern (`ClaimCarrier`, `ResourceStreamCarrier`).
- **Testing**: the full suite runs in <1 s — run it after every edit.
  Test-writing patterns (event-driven `RepCollecting` waits, the
  scripted-adapter machine-flow harness) live in the `event-driven-tests`
  skill.
- **Craft privacy & pacing**: which craft rows may render, progress math,
  and the `_start`/complete loop's server cadence validation live in the
  `craft-visibility` skill — read it before touching craft tracking or
  rendering.
- **Protocol facts**: the server answers `sign_in` with a ReducerResult
  in ~200 ms — anything slower is a dead handshake, not server slowness.
  BSATN row decoders pin schema field order; after a game update, follow
  the `bsatn-schema-check` skill (schema re-verification + tap-capture
  decoding).

Project skills live in `.agents/skills/`: `bsatn-schema-check`,
`claim-buildings-sync`, `craft-visibility`, `event-driven-tests`.
