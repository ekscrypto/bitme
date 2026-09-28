---
name: bsatn-schema-check
description: Re-verify pinned BSATN row-decoder field order against the BitCraft module schema, and decode bitcraft-tap captures (SpacetimeDB v2.bsatn websocket traffic) for ground truth. Use after a BitCraft game update or patch, when row decodes fail or fields look shifted/garbled, when adding or editing row decoders (RegionBuildingRows.swift, RegionGamedataDecoder, global-leg rows), or when inspecting tap captures, subscription SQL, or reducer call order.
---

# BSATN schema check & tap decoding

BSATN rows are positional — no field names on the wire. Decoders read
fields in schema declaration order and may stop after the last field they
need, but must read every field before it. Enums are u8 declaration-order
tags; timestamps are microseconds since the Unix epoch.

## Where things live

- **App decoders**: `Core/Sources/BitMeCore/RegionBuildingRows.swift` —
  region subscription rows (`*Row: BSATNTableWithPrimaryKey`) plus
  `RegionGamedataDecoder` for the one-off catalog rows. Global-leg rows:
  `GlobalSessionClient.swift`, `GlobalPlayerResolver.swift`.
- **Canonical schema**: `../bitcraft-mats/bitjita-schema-region.json` /
  `bitjita-schema-global.json`. Fastest field-order check: the
  `*.digest.md` companions list every table's columns in declaration
  order (grep the table name). `bitjita-schema-analysis.md` is the
  narrative companion.
- **Our condensed shapes**: the table-shapes section of
  [docs/protocol/region-claim-buildings.md](../../../docs/protocol/region-claim-buildings.md).

## Re-verification procedure (after a game update)

1. Refresh the `../bitcraft-mats` checkout — it carries the canonical
   module schema; the digest header names the module build (e.g.
   `bitcraft-live-14`, table/type counts).
2. For each subscribed table, grep the region digest and compare column
   order against the decoder's read sequence.
3. Columns inserted or reordered **before** the decoder's last consumed
   field shift everything downstream — re-pin the reads. Columns appended
   after it are safe (decoders stop early by design).
4. Re-check enum variant order (u8 tags — e.g. `PassiveCraftStatus`
   Queued/Processing/Complete = 0/1/2) and `Option` wrappers. Beware
   declared Sums that merely look like `Option`: `player_move`'s
   `destination`/`origin` declare variants **`[some, none]` → some = 0x00,
   none = 0x01** — the reverse of std `Option` habit; assuming none=0
   misaligns every later field. And reducer-request `timestamp` fields
   (`player_move`, `craft_continue*`, `extract*`) are **milliseconds**
   while row/server timestamps stay microseconds.
5. Run `cd Core && swift test` (full suite, <1 s).
6. Confirm end-to-end against a fresh tap capture (below): snapshot rows
   must decode with no trailing bytes.

The 48 h gamedata cache self-heals — a cache written before a field was
added fails to decode and self-refetches (one cold load per schema
change), so a stale cache never masks a decoder break for long.

## Tap-capture decoding

Captures are gitignored under `tools/tap/captures/<session>/` (per
connection: `handshake.json`, `index.jsonl`, `frames.bin`). Captures
before 2026-09-27 have global legs only — the region-leg rewrite landed
then. From `tools/tap/`:

```sh
node decode.js captures/<session>            # summary + timeline, all conns
node decode.js captures/<session> 3          # just conn-03
node decode.js captures/<session> --scan bitcraft-live   # find frames containing text
```

Writes `conn-NN/decoded.jsonl` and prints the subscription SQL catalog,
reducer call order, and per-table row/byte stats. To record a new
capture, run the tap per [tools/tap/README.md](../../../tools/tap/README.md)
(`npm start`, then the `defaults write` client override).
