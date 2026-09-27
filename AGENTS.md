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
