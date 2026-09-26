# BitCraft protocol session analysis — 2025-09-25 tap capture

Reference for implementing the BitMe iOS client against BitCraft's servers.
Captured with [tools/tap](../../tools/tap/README.md) (API proxy + WebSocket
forwarder), decoded with `tools/tap/decode.js` against the SpacetimeDB v2
websocket protocol spec (source: clockworklabs/SpacetimeDB,
`crates/client-api-messages/src/websocket/`).

Raw capture: `tools/tap/captures/2026-09-25_20-47-37/` (gitignored) —
`conn-03/decoded.jsonl` has every message of the global-DB session structured.

## 1. Auth flow (REST, api.bitcraftonline.com)

```
POST /authentication/request-access-code?email=<email>            -> 200 (emails a code)
POST /authentication/authenticate?email=<email>&accessCode=<code> -> 200 (returns SpacetimeDB JWT)
GET  /status/can-sign-in?authToken=<JWT>&platform=OSXPlayer&buildNumber=473 -> 200
POST /authentication/authenticate-steam?email=<email>&authTicket=<steam session ticket> -> 200 (links Steam)
GET  /global-module/get-connection-info -> {"uri":"https://bitcraft-early-access.spacetimedb.com","name":"bitcraft-live-global"}
POST /client-disconnect/report   (on disconnects)
```

- The JWT is a **SpacetimeDB token**: `aud: ["spacetimedb"]`, `iss: "localhost"`,
  `sub: <uuid>`, custom `hex_identity` claim, **no expiry**. It is the Bearer
  token for every game WebSocket.
- The client stores it in PlayerPrefs keyed by api URL + email
  (`EarlyAccess:<apiServerUrl>:<email munged>:AuthToken`), i.e. tokens are
  per-environment; switching apiServerUrl forces re-auth.
- `get-connection-info` is unauthenticated — the global DB address is public.

## 2. Connection topology

```
                    ┌─ REST: https://api.bitcraftonline.com  (auth/bootstrap)
BitCraft client ────┤
                    ├─ WSS:  bitcraft-early-access.spacetimedb.com / bitcraft-live-global
                    │        (identity, social, chat, empire data, world directory)
                    └─ WSS:  bitcraft-early-access.spacetimedb.com / bitcraft-live-<N>
                             (the player's region/world shard; N chosen via tables)
```

World selection data (subscribed on the global DB):

- `user_region_state WHERE identity = 0x<your hex identity>` — the player's region
- `region_connection_info` — rows `{ uri: "https://bitcraft-early-access.spacetimedb.com", name: "bitcraft-live-1" … "bitcraft-live-14"+ }`

### 2.1 Identity → player over the JSON protocol (verified live, 2026-09-25)

The game host accepts `v1.json.spacetimedb` (not just the v2.bsatn the
client uses) with the account JWT as `Authorization: Bearer` — same
`/v1/database/<db>/subscribe` URL the relay mirror serves anonymously. That
gives an account-driven client (BitMe Pocket Crafter) everything it needs
to go from a login token to the player, with no character-name entry:

| Query (on `bitcraft-live-global`) | Row |
| --- | --- |
| `user_state WHERE identity = 0x<hex>` | `{"identity":{"__identity__":"0x…"},"entity_id":<u64>,"can_sign_in":<bool>}` |
| `user_region_state WHERE identity = 0x<hex>` | `{"identity":{…},"region_id":<int>}` |
| `player_username_state WHERE entity_id = <u64>` | `{"entity_id":<u64>,"username":"Maplesugar"}` |

`entity_id` here is the same decimal-string key the relay's
`/bitme/session/:entity_id` takes. Core implementation:
`GlobalPlayerResolver` + a Bearer-capable `SpacetimeSubscribeClient`.
An account with no row in `user_state` has no character yet.

## 3. Wire protocol (v2.bsatn.spacetimedb)

- WS URL: `wss://<host>/v1/database/<db>/subscribe?connection_id=<32-hex>&compression=Brotli&confirmed=false`
- Headers: `Authorization: Bearer <JWT>`; subprotocol `v2.bsatn.spacetimedb`
- `connection_id` must be a hex string (server deserializes it as a byte array)
- **Envelope: server→client only** — `[u8: 0=raw | 1=brotli | 2=gzip] + BSATN message`.
  Client→server messages are raw BSATN, uncompressed.
- BSATN: little-endian; `str`/`Bytes` = u32 len + data; arrays = u32 count + elems;
  enums/Option = u8 tag. Message schemas: `ClientMessage`/`ServerMessage` in v2.rs.
- `SESSION_BUSY_CLOSE_CODE = 4000`: a second live connection with the same
  `session_id` is refused — relevant when BitMe runs beside the desktop client.
- Server pushes `InitialConnection { identity, connection_id, token }` first
  (token refresh mechanism — the frame carries a fresh JWT).

### 3.1 Client transport requirements (verified live, 2026-09-26)

The websocket edge (nginx 1.18 in front of SpacetimeDB) is picky in ways
that break both Apple platform websocket APIs:

- **`Upgrade: websocket` is matched case-sensitively.** `Upgrade: WebSocket`
  (which `NWProtocolWebSocket` always sends) gets HTTP 426. The exact
  lowercase token is required.
- **h2 breaks the upgrade.** `URLSessionWebSocketTask` negotiates ALPN and,
  when the server selects h2, attempts RFC 8441 extended CONNECT (no public
  opt-out); this nginx does not advertise `SETTINGS_ENABLE_CONNECT_PROTOCOL`
  and the task dies with POSIX 57 "Socket is not connected".
- **Anonymous or invalid-token connections to the global DB are closed
  ~100 ms after the 101.** A valid account token gets `InitialConnection`
  immediately; anything less gets silence then a reset.
- The edge **pings and expects pongs within ~30 s** (see the mirror's
  `MULTI-MIRROR-UPSTREAM-RESETS.md`); clients ping at ~10 s cadence.

The working shape (what tokio-tungstenite sends, and what
`spacetimedb-swift-sdk`'s `NWWebSocketConnection` now sends): plain TLS
**without ALPN** over `NWConnection`, a hand-built HTTP/1.1 upgrade with
the exact lowercase header values, and in-package RFC 6455 framing (masked
client frames, auto-pong). Verified end-to-end against the live host:
101 → `InitialConnection` → authenticated `OneOffQuery` rows → `CallReducer`
result.

## 4. Global-DB session sequence (conn-03, 1,783 frames, 0 decode errors)

1. `InitialConnection`
2. `Subscribe` qsid=1: `user_region_state WHERE identity = 0x…` + `region_connection_info`
3. 33 more `Subscribe` sets (full SQL in decoded.jsonl; catalog below)
4. `CallReducer sign_in` — args decode to `{ owner_entity_id: u64 }` where the
   id is the account's user entity (`user_state.entity_id`, the same id
   §2.1's identity→player lookup returns). Captured bytes
   `CA E0 07 01 00 00 00 12` = 1297036692699996362, the id the client also
   keys its self-subscriptions by (`player_username_state WHERE entity_id = …`,
   `friends_state WHERE owner_entity_id = …`, …). Signature confirmed via the
   module's public schema: `GET /v1/database/<db>/schema?version=9|10`
   (unauthenticated, ~600 KB JSON; reducers carry full param types).
   This is the session-takeover wire action — the game allows one live
   session per account, and a fresh `sign_in` is what takes (and thereby
   kicks) it. BitMe Pocket Crafter performs it over the JSON protocol
   (`v1.json.spacetimedb`, Bearer token) with
   `"args":"[{\"owner_entity_id\":<id>]"`, `flags: 0` (FullUpdate) so a
   subscriptionless caller still receives its own `TransactionUpdate`
   (core: `GlobalSessionClient` + `Activity.GameSessionLoop`).
5. During play: ~830 `OneOffQuery`/result pairs (polling-style queries), 40
   `TransactionUpdate`s (live row changes), chat via `chat_post_targeted_message`

Reducer calls observed, in order:

| time | reducer | args |
| --- | --- | --- |
| 20:49:37 | `sign_in` | `{ owner_entity_id: 1297036692699996362 }` (see §4) |
| 20:50:50 | `chat_post_targeted_message` | channel id + UTF-8 text ("o/…") |
| 20:51:16 | `chat_post_targeted_message` | "all good for clay?" |
| 20:55:44 | `chat_post_targeted_message` | "perfect" |

Reducer names are snake_case on the wire (client C# names map 1:1, e.g.
`BitCraft.Spacetime.Reducer|SignIn` → `sign_in`).

## 5. Global-DB subscription catalog (35 query sets, exact SQL)

Social/identity: `player_username_state`, `friends_state` (both directions),
`blocked_player_state` (both directions), `visibility_state`, `claim_member_state`,
`player_shard_state`, `player_developer_notification_state`, `empire_player_log_state`,
`chat_channel_permission_state`, `chat_channel_state` (JOIN on permissions),
`signed_in_player_state`.

Empire: `empire_state`, `empire_emblem_state`, `empire_directive_state`,
`empire_node_state`, `empire_settlement_state`, `empire_chunk_state`,
`empire_player_data_state`, `empire_rank_state`, `empire_node_siege_state`,
`empire_notification_state`, `empire_foundry_state`, `empire_siege_engine_state`.

World directory: `region_connection_info`, `region_population_info`,
`region_control_info`, `world_region_name_state`, `user_region_state`.

Chat/misc: `chat_message_state`, `direct_message_state`, `admin_broadcast`,
`official_translators`, `translation_corrections`, `player_vote_state`.

(All as `SELECT * FROM …` except the per-entity WHEREs above; full list with
request/query-set ids in `conn-03/decoded.jsonl`.)

## 6. What's still uncaptured

The **world-shard leg** (`bitcraft-live-<N>`) went direct: the client reads the
shard URI from `region_connection_info` *rows* (SpacetimeDB data, not API
responses), so the tap's API-side rewrite can't redirect it. Options for a
world-leg capture:

1. Extend the tap to rewrite the URI inside `region_connection_info` table rows
   in-flight (BSATN-aware body edit — doable now that the protocol is decoded).
2. `/etc/hosts` override + local TLS MITM (heavier: needs a trusted cert and
   pinning the tap's upstream dial to real IPs to avoid a loop).

The iOS client doesn't strictly need this — it can connect to the shard
directly (it's the same protocol) — but capturing one world session would give
us the shard's subscription/reducer catalog (movement, gathering, crafting) the
same way this one gave us the global catalog.
