# Region sign-in: the queue gate

Why a region `sign_in` sometimes refuses with **"You must join the queue
first."** and what the client must do instead. Researched 2026-09-28 against
the game module source (BitCraftPublic `release sept-17`) and the first-ever
captured region leg (tap `captures/2026-09-28_00-24-16`, conn-02,
`bitcraft-live-14`; capture enabled by the tap's same-length in-frame URI
rewrite — see §4).

## 1. The server-side rule

`sign_in` (region module) requires `user_state.can_sign_in == true`. The flag
is **not permanent**: on disconnect the account keeps it only for a grace
period (`region_sign_in_parameters.grace_period_seconds`, admin-set, public
table); when the scheduled `end_grace_period` timer fires, the flag flips
false and the next sign-in must rejoin the queue. A long-offline account
always hits the refusal.

`player_queue_join()` — **no arguments** — is the gate the desktop client
calls first (`BitCraftServer/packages/game/src/game/handlers/queue/
player_queue.rs`):

- queue empty and population under `max_signed_in_players` → `allow_sign_in`
  **in the join's own transaction** (sets `can_sign_in = true`, starts a fresh
  grace timer) — the common case, ~40 ms;
- otherwise the identity is enqueued (`player_queue_state`), and admission
  arrives later via `process_queue` (run whenever any grace period ends) as a
  `user_state` row update;
- refusals: "The queue is full…" (`max_queue_length`), "Server is unavailable
  at this time…" (`is_signing_in_blocked` maintenance, GM-exempt).

Roles `SkipQueue`+ skip the queue entirely; `config.env == "dev"` bypasses
everything.

## 2. The wire sequence (captured, 2026-09-28)

```
subscribe   SELECT * FROM user_state WHERE identity=0x<own hex>
            SELECT * FROM player_queue_state          -- queue UI, whole table
→ SubscribeApplied  user_state row: identity(32) + entity_id(8) + can_sign_in(1) = 41 B
                    can_sign_in = 0x00                (grace had expired)
→ CallReducer player_queue_join  (0 B args)           first reducer on the leg
→ ReducerResult Ok (~40 ms), transaction updates the subscribed user_state
                    row to can_sign_in = 0x01         (no queue row ever created)
… ~20 s of world-load subscriptions (146 query sets) …
→ CallReducer sign_in (8 B args: owner_entity_id, little-endian —
                    identical to the global leg's argument)
```

The 20 s gap is client asset loading, **not** protocol: once the row reports
`can_sign_in == true`, `sign_in` is unblocked. `end_grace_period_timer` is a
module-private scheduled table — clients never observe it; `can_sign_in` is
the only visible signal.

## 3. What Bit-Me does (`GlobalSessionClient.joinQueue`)

Region leg, when the token's `hex_identity` is known (absent → legacy bare
`sign_in`):

1. `registerTableRowDecoder(UserStateRow.self)`, attach `tableEvents` for
   `user_state` **before** subscribing (SDK rule — else the snapshot is
   missed);
2. subscribe the own row (`WHERE identity=0x<canonical hex>`, no spaces —
   mirrors the capture), await `applied()`;
3. `player_queue_join` with empty `Data()` (20 s deadline);
4. wait for any row insert reporting `canSignIn == true` — event-driven;
   unbounded when genuinely queued (the loop's connecting state is the queue
   screen), leg death or cancellation ends the wait;
5. `sign_in` as before.

## 4. Tap note — capturing region legs

Region URIs reach the client as `region_connection_info` **table rows**
inside s2c websocket frames, so the API-side rewrite never sees them; every
capture before 2026-09-28 has global legs only. `tools/tap/server.js` now
also rewrites those in-frame: the 45-byte `https://bitcraft-early-access.
spacetimedb.com` string is replaced **same-length** with
`http://taprewrite.bitcraft-tap.localhost:9443` (host via `/etc/hosts`).
Length must be preserved — BSATN row blocks carry explicit per-row
lengths/offsets, and a shortened first attempt desynced the client's parser
(it closed the socket 4 ms after the frame). Frames are decompressed,
patched, recompressed with their original algorithm; the capture still
records the untouched server bytes.
