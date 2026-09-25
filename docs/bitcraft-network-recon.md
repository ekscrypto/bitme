# BitCraft client network recon

Goal: enumerate every endpoint the BitCraft client talks to (IP/port/protocol),
so we can (phase 2) stand up a localhost listener/forwarder, observe the
client↔server protocol, and eventually drive characters from the BitMe iOS app.

Everything below was derived from the installed client on this machine
(Steam install, updated 2025-09-24) unless marked otherwise.

## Client install

- Path: `~/Library/Application Support/Steam/steamapps/common/BitCraft Online/BitCraft.app`
- Unity **IL2CPP** build (arm64 + x86_64):
  - `Contents/MacOS/BitCraft` (launcher stub)
  - `Contents/Frameworks/GameAssembly.dylib` (~169 MB, all game code)
  - `Contents/Resources/Data/il2cpp_data/Metadata/global-metadata.dat` (~33 MB, all C# string literals)
- Settings/credentials: `~/Library/Preferences/com.ClockworkLabs.BitCraft.plist` (Unity PlayerPrefs)
  - `EarlyAccess:Email`
  - `EarlyAccess:https://api.bitcraftonline.com:<email with _ for @ and .>:AuthToken` → JWT (one per account)
- Bootstrap config: `Contents/Resources/Data/StreamingAssets/Config/production.json`

## Static endpoint inventory

From `production.json`:

| Purpose | URL |
| --- | --- |
| API / auth | `https://api.bitcraftonline.com` |
| Addressables CDN | `https://bitcraft-production.sfo3.cdn.digitaloceanspaces.com/addressable-content` |
| Title announcements | `https://bitcraft-production.sfo3.cdn.digitaloceanspaces.com/title-screen-announcements.json` |
| World map files | `https://maps.game.bitcraftonline.com/world-maps` (CNAME → same DO Spaces CDN, Cloudflare-fronted) |
| Bug reports | `https://spiqlnq0yf.execute-api.us-east-1.amazonaws.com/api/report_bug` |

From strings in `global-metadata.dat`:

- REST paths: `/authentication/request-access-code`, `/authentication/authenticate`,
  `/authentication/authenticate-steam`, `/authentication/authenticate-without-email`,
  `/token`, `/v1/database/…` (SpacetimeDB HTTP API paths)
- Login UI is email → emailed access code → JWT; Steam auth is an alternative.
- Debug/QA strings: "SpacetimeDB window", "SpacetimeDBStatsTool", `EnableDebugKeys` pref,
  staging env (`https://api.staging.bitcraftonline.com` referenced in community notes).

DNS (2025-09-25):

| Host | IPs |
| --- | --- |
| api.bitcraftonline.com | 165.227.240.184 (DigitalOcean droplet, no CDN) |
| bitcraft-early-access.spacetimedb.com | 125.253.89.29, 131.153.154.11, 125.253.87.85, 125.253.87.87 |
| bitcraft-production.sfo3.cdn.digitaloceanspaces.com | 104.18.42.227, 172.64.145.29 (Cloudflare) |
| spiqlnq0yf.execute-api.us-east-1.amazonaws.com | 184.192.46.196, 18.204.192.107 |

## Game protocol = SpacetimeDB client protocol

Hard evidence from the binary:

- Embedded SpacetimeDB C# SDK types: `SpacetimeDB.ClientApi|CallReducer`,
  `OneOffQuery`, `TableUpdate`, `Unsubscribe`, `BsatnRowList`, `EnergyQuanta`,
  `SubscriptionHandle`, `NetworkRequestTracker`, "SpacetimeDB Network Thread".
- Client string: "No auth token. Log in via the SpacetimeDB window first."
- Client string: "Subscribing to heavy tables (building_state, location_state) on-demand…"
- Wire is WebSocket (wss) carrying BSATN (binary) or JSON protocol messages;
  "commands" = reducer calls + SQL-ish subscription requests;
  "responses" = table updates (insert/update/delete rows) + reducer callbacks.

The relay project already mirrors the production database:
`wss://bitcraft-early-access.spacetimedb.com/bitcraft-live-14`
(tables mirrored: `player_username_state`, `player_notification_event`,
`market_trade_event`, `craft_event`). The game client is expected to hit the
same cluster (possibly a different gateway/host — live capture will confirm).

Reducer catalog: 601 BitCraft reducers extracted to
[reducers.txt](protocol/reducers.txt). Player-facing examples: `SignIn`,
`SignOut`, `PlayerCreate`, `Attack`, `Emote`, `Sleep`, `Extract`, `ItemUse`,
`ItemDrop`, `Prospect`, `Terraform`, `PlaceablePlaceStart`, `EmpireSubmit`,
`ClaimTechUnlockTech`, `PassiveCraftCollect`, `TradeDeclineSession`, …
(plus Admin*/Cheat*/Import*/Stage* which are internal/QA).

## Live capture (in progress)

- Monitor: `tools/netrecon/connmon.sh` (lsof poll @ 250 ms, logs NEW/GONE per
  pid+endpoint+state).
- Log: `/tmp/bitcraft-recon/connections.log`
- Procedure: launch game → title screen → log in → character select → enter
  world → move/chat/gather for ~1 min → quit. Monitor records the full
  connection timeline.

### Runtime results (captured 2025-09-25 16:23–16:25, session to world entry)

Everything is **TCP over :443** — zero UDP at any point. The entire game,
including realtime movement/combat, is WebSocket(s) on 443.

| When | Remote | Identity | Bytes in/out | Lifecycle |
| --- | --- | --- | --- | --- |
| boot 16:23:42 | `127.0.0.1:57343` | Steam client IPC (`steam_osx` local API socket) | 7.4 KB / 2.1 KB | open whole session |
| boot 16:23:42 | `104.18.41.99:443` | Cloudflare edge, unidentified small config fetch | 4.5 KB / 0.7 KB | stays open |
| boot 16:23:42 | `34.111.113.40:443` | `config.uca.cloud.unity3d.com` (Unity Remote Config) | small | closed entering world |
| boot 16:23:42 | `34.107.172.168:443` | `cdp.cloud.unity3d.com` (Unity telemetry ingest) | small | closed entering world |
| boot 16:23:42 | `172.64.145.29:443` | DO Spaces CDN (title-screen announcements) | small | closed 16:24:20 |
| login 16:24:02 | `165.227.240.184:443` | **api.bitcraftonline.com** (auth + bootstrap REST) | 5.3 KB / 6.9 KB | stays open |
| world 16:24:06 | `125.253.89.29:443` ×2 | **SpacetimeDB cluster** (game world WebSockets) | 6.7 MB/142 KB and 1.5 MB/47 KB | stays open |
| world 16:24:06 | `131.153.154.11:443` | SpacetimeDB cluster, 2nd node (likely 2nd database/global) | 24 KB / 3.3 KB | stays open |
| world 16:24:16 | `104.18.42.227:443` ×3 | DO Spaces CDN (world-map files, addressables) | 7 MB + 0.9 MB + 5 KB | open while downloading |

Observations:

- The two heavy sockets to `125.253.89.29` are the actual game channel
  (megabytes bidirectional — subscription stream + reducer calls). The client
  opens two WebSockets plus one to a second cluster node; the client binary has
  no hardcoded DB hostname (only `wss://` scheme fragments), so the
  URI/database name is delivered by the API at login — one more reason the API
  hop is the intercept point.
- Login sequence timing: process start → CDN/telemetry (40 s at title screen) →
  api.bitcraftonline.com at login click → 4 s later the three SpacetimeDB
  sockets open → 10 s later map/addressable downloads begin.
- Nothing connects anywhere but 443/TCP + the Steam loopback socket.

Shutdown sequence (sign-out at 16:25:20, client quit at 16:28:11):

- Sign-out closes the api.bitcraftonline.com REST socket and the second
  SpacetimeDB node (131.153.154.11) — but **the two game-world WebSockets to
  125.253.89.29 stay open all the way back at the title screen** until process
  exit. Sign-out is itself a reducer (`SignOut`) sent over the still-open
  WebSocket, not a new API call; no new connections are made between sign-out
  and quit.

Raw capture: [captures/connections-2025-09-25.log](protocol/captures/connections-2025-09-25.log)
(full system-wide NEW/GONE events; filter on `BitCraft`).

## Phase 2 — DONE (2025-09-25): client interposed, protocol decoded

The tap ([tools/tap](../tools/tap/README.md)) captured a full login→world
session through the global database. Wire protocol, auth flow, world topology,
subscription catalog, and reducer sequence are documented in
[protocol/session-2026-09-25-tap-analysis.md](protocol/session-2026-09-25-tap-analysis.md).
Key facts: game protocol is SpacetimeDB `v2.bsatn` over WSS (server→client
frames carry a 1-byte compression envelope, Brotli); world shards
`bitcraft-live-1..14+` are listed in the `region_connection_info` table on
`bitcraft-live-global`; the auth JWT is a non-expiring SpacetimeDB token.
