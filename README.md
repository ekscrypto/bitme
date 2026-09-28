# BitMe

Two mobile companion apps for BitCraft, one shared core:

- **BitMe X-Ray** (bundle `life.encoded.bitme.ios`, the successor of the
  original "Bit-Me" app) — map-first: resolve a character by name and live
  on the hex resource map, with the glanceable activity dashboard (bush
  countdown, citric, stamina, food, nearby resources) a cover away.
- **BitMe Pocket Crafter** (bundle `life.encoded.bitme.crafter`) — the
  claim's workstations and craft tasks on the go. Signs in with the BitCraft
  account (email → emailed access code) and tracks the account's own player,
  located over the game's global database — no character-name entry. The
  game session's region-shard leg carries a live claim-buildings sync (the
  pinned claim's buildings, catalogs, nicknames, and crafts — see
  [docs/protocol/region-claim-buildings.md](docs/protocol/region-claim-buildings.md)).
  The map stack is disabled at construction (see `StateMachine.Configuration`).

Both are thin clients over the `relay.bitcraftsync.app` **Bit-Me API**
(JSON HTTPS endpoints + binary resource-map endpoints, ~1 Hz polling). All
countdowns and alert logic run client-side from snapshots + bundled
gamedata — the Giant Bountiful Strawberry Bush → Citric window remains the
reference scenario for X-Ray's dashboard.

## Documentation

| Doc | Contents |
|---|---|
| [docs/api.md](docs/api.md) | **API reference** — `/bitme/resolve`, `/bitme/session/:entity_id`, the resource-map endpoints (BMR1 windows, region dictionary, BME1 terrain), and the resource change stream (BMD1 + control protocol), field-by-field, error and deploy semantics. |
| [docs/tutorial-onboarding-and-polling.md](docs/tutorial-onboarding-and-polling.md) | **Tutorial 1** — name → character resolution, readiness probe, a production-shaped 1 Hz polling client with clock-skew correction and backoff. |
| [docs/tutorial-harvest-session.md](docs/tutorial-harvest-session.md) | **Tutorial 2** — snapshot → screen state: bush countdown, citric detection, food-buff and stamina alerts; lifecycle (backgrounding, deploys) and a playtest checklist. |
| [docs/relay-data-requirements.md](docs/relay-data-requirements.md) | Design history — the original data-requirements spec sent to the relay team (superseded; static-gamedata list §6 still applies). |
| [docs/protocol/session-2026-09-25-tap-analysis.md](docs/protocol/session-2026-09-25-tap-analysis.md) | **Protocol: global-DB tap** — auth flow, connection topology, v2.bsatn wire facts, the desktop client's subscription/reducer catalog. |
| [docs/protocol/region-claim-buildings.md](docs/protocol/region-claim-buildings.md) | **Protocol: claim-buildings sync** — the region tables behind a claim's workstations (shapes, indexes, guardrails) and the subscription set Pocket Crafter rides on the game session's region leg. |
| [docs/protocol/region-move-and-craft-continue.md](docs/protocol/region-move-and-craft-continue.md) | **Protocol: movement & shared-craft resume** — captured `player_move` / `craft_continue` reducer wire layouts (incl. the `[some, none]` tag trap and ms-vs-µs timestamps), the no-repeat `_start`/complete idiom with server-side cadence validation (95%/80% band, strikes), the v2-only `*_event` tables, and client-side speed/buff computation (materialized `character_stats_state`, buff stacking rules, movement-speed chain). |

## External sources of truth

- **Relay API:** `relay-bitcraftsync-app/spacetimedb-bitcraft-mirror/crates/relay-cache/BITME-API.md`
  (handlers `bitme_serve.rs`, tracker `bitme.rs`). If it ever disagrees with
  our `docs/api.md`, the relay repo wins.
- **Design rationale:** `relay-bitcraftsync-app/BITME-DATA-ASSESSMENT.md` —
  why the relay team chose a server-side tracker + HTTP polling over raw
  SpacetimeDB WebSocket subscriptions, with live measurements.
- **Game-data timings** (`resource_desc` despawn/respawn, regen constants):
  resolved live by the relay; client-side constants (stamina regen curve,
  harvest pacing) are bundled gamedata and must be confirmed in playtests —
  see tutorial 2, §5.

## Architecture

All behavior lives in the **`Core/` local Swift package** (fenex-light-style
one-way state machine), shared by both iOS apps and a headless CLI:

- `StateMachine` — `final actor`, owns `PersistentState` (resolved identity)
  and `EphemeralState`; all mutation flows through serially-processed
  `Intent.*` values; async work happens in `Activity.*` structs that feed
  results back as intents. Internal state is not queryable — observers read
  the published rep channels only.
- Screen projections — screen-shaped, Equatable/Codable enums with
  relay-clock anchor timestamps; UIs interpolate countdowns locally. One per
  sign-in flow, published on its own channel chosen by configuration:
  `ViewRep` (name-driven — X-Ray and the CLI: onboarding, the harvest
  dashboard, the resource map) and `CrafterRep` (account-driven — Pocket
  Crafter: emailed-code sign-in, the pre-sign-in gate, the session with the
  live game session). Payloads both apps render (`BitCraftSignIn`,
  `RunningAction`, `SessionConnection`, the session shell projection) are
  shared; each app's rep carries only the screens and fields it can show.
- `MapRep` — the tile-data channel for the hex-grid map renderer: raw BMR1
  window words, the BME1 terrain plane, and the dictionary, published only
  when map state changes (never on every poll).
- `WorkstationsRep` — the claim-buildings channel (Pocket Crafter): the
  claim's buildings joined with catalogs, nicknames, and crafts, published
  only when the buildings state moves (the `MapRep` precedent).
- `StateMachine.Configuration` — optional subsystems an app host toggles at
  construction. Pocket Crafter disables the resource-map stack (no tile
  windows, no terrain, no change-stream websocket); X-Ray and the CLI use
  the standard configuration.
- `Adapters` — closure-based system boundaries (relay HTTP, resource change
  stream, mirror WebSocket gamedata, identity persistence, sleep) so tests
  substitute simulated doubles and flows run deterministically.
- API layer (relay HTTP client incl. the BMR1/BMD1/BME1 binary codecs,
  change-stream WebSocket client, mirror WebSocket gamedata client, and the
  BitCraft account auth client — emailed access code → SpacetimeDB JWT,
  Keychain-stored) and the pure harvest/resource-map engines are internal
  to the package.

### CLI (`bitme-cli`) — headless testing surface

```bash
cd Core
swift run bitme-cli resolve maplesugar      # resolve, print outcome, exit
swift run bitme-cli watch maplesugar        # stream live session ViewReps
swift run bitme-cli watch maplesugar --json # one JSON ViewRep per line
swift test                                  # core unit tests (no simulator)
```

### iOS apps

SwiftUI (iOS 17+, Swift 6, zero third-party dependencies). The Xcode project
is generated with XcodeGen:

```bash
xcodegen generate          # creates BitMe.xcodeproj from project.yml
open BitMe.xcodeproj       # pick the BitMeXRay or BitMeCrafter scheme, Cmd+R
```

- **BitMe X-Ray** — bundle ID `life.encoded.bitme.ios` (display name
  "BitMe X-Ray"; inherits the original app's identity, so it upgrades in
  place). `XRay/` is presentation only: `XRayApp` owns the `StateMachine`
  and mirrors the published `ViewRep` (the name-driven projection);
  `OnboardingView` (name-only entry) and `MapScreen` (the root screen,
  presenting `ActivityScreen` — the dashboard — as a full-screen cover)
  are the two screens.
- **BitMe Pocket Crafter** — bundle ID `life.encoded.bitme.crafter`
  (display name "BitMe Pocket Crafter"). `Crafter/` renders the
  account-driven `CrafterRep`: the emailed-code `SignInView` (the app's
  root), then the pre-sign-in gate (`GameSessionPromptView`: character
  name, in-game N/E coordinates, current claim, and the relay's live answer
  to whether the account is signed in elsewhere), then `CrafterHomeView`
  (the claim header, the running-craft card, and the Crafting/Storage tabs
  rendering the `WorkstationsRep` channel). The
  gate's action performs the game's `sign_in` (`CallReducer` on the global
  database, held open by `Activity.GameSessionLoop`) — "Take over session"
  when another device holds it, "Sign in" when not — which is what kicks
  the desktop client (and vice versa). A kicked or dropped session returns
  to the gate and is never re-taken automatically. All game-database
  traffic rides our [spacetimedb-swift-sdk](../spacetimedb-swift-sdk)
  (v2.bsatn; its transport speaks the byte-exact HTTP/1.1 websocket this
  server requires — see docs/protocol §3.1).
- `Shared/` — presentation code compiled into both targets (`Format`).
- Each app has its own sandbox: identity persists at
  `<Application Support>/BitMe/identity.json` per app, and the BitCraft
  account lives in each app's own Keychain item — sign in separately in
  each.

Known gaps (tunable placeholders live in `Core/Sources/BitMeCore/GameConfig.swift`):
stamina regen constants need gamedata + playtest confirmation.

## Status

- Relay: **Phase 1 shipped to production** (2026-09-05) — resolve + session
  endpoints, server-side target-health tracking, watched-spawn (citric) log.
  **Resource-map APIs live** (2026-09-24, first shipped on the X-Ray web
  client): BMR1 session/world windows, region dictionaries, BME1 terrain,
  and the BMD1 change-stream WebSocket.
- Core + CLI: state machine, API, screen projections extracted (per-flow
  `ViewRep`/`CrafterRep` since the two-app split); 109 unit tests; CLI
  verified against production (resolve, live watch, live resource map —
  window + dictionary + stream). The session/map loops also survive the
  CLI's start → SignOut → resolve race (late bootstraps can no longer
  resurrect the previous character).
- iOS apps: **v0.3 — split into two apps.** **X-Ray** (map-first; same
  bundle id as the original Bit-Me app) carries everything the combined
  app had — the odd-r hex-grid map (terrain from BME1 planes, per-id
  resource colors, live deltas, pan/pinch/follow, tile inspect, filter
  panel with persisted tracked set, gathering HUD) with the activity
  dashboard (big countdown with learned pacing, citric banner, stamina
  projection, food-buff classification, nearby-resources feed) now a
  cover over the map. **Pocket Crafter** pairs the claim header +
  running-craft card + sign-in with the live workstation list (the
  claim-buildings sync over the game session's region leg — crafting
  stations, storage, and craft tasks, joined with the game's own
  catalogs).
