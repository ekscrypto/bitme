# Bit-Me

Cross-platform mobile companion app for BitCraft: large, glanceable,
time-critical guidance while harvesting timed world resources — the Giant
Bountiful Strawberry Bush → Citric window being the reference scenario.

The app is a thin client over the `relay.bitcraftsync.app` **Bit-Me API**
(two JSON HTTPS endpoints, ~1 Hz polling). All countdowns and alert logic
run client-side from snapshots + bundled gamedata.

## Documentation

| Doc | Contents |
|---|---|
| [docs/api.md](docs/api.md) | **API reference** — `/bitme/resolve`, `/bitme/session/:entity_id`, the resource-map endpoints (BMR1 windows, region dictionary, BME1 terrain), and the resource change stream (BMD1 + control protocol), field-by-field, error and deploy semantics. |
| [docs/tutorial-onboarding-and-polling.md](docs/tutorial-onboarding-and-polling.md) | **Tutorial 1** — name → character resolution, readiness probe, a production-shaped 1 Hz polling client with clock-skew correction and backoff. |
| [docs/tutorial-harvest-session.md](docs/tutorial-harvest-session.md) | **Tutorial 2** — snapshot → screen state: bush countdown, citric detection, food-buff and stamina alerts; lifecycle (backgrounding, deploys) and a playtest checklist. |
| [docs/relay-data-requirements.md](docs/relay-data-requirements.md) | Design history — the original data-requirements spec sent to the relay team (superseded; static-gamedata list §6 still applies). |

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
one-way state machine), shared by the iOS app and a headless CLI:

- `StateMachine` — `final actor`, owns `PersistentState` (resolved identity)
  and `EphemeralState`; all mutation flows through serially-processed
  `Intent.*` values; async work happens in `Activity.*` structs that feed
  results back as intents. Internal state is not queryable — observers read
  the published `ViewRep` only.
- `ViewRep` — screen-shaped, Equatable/Codable projection with relay-clock
  anchor timestamps; UIs interpolate countdowns locally.
- `MapRep` — the tile-data channel for the hex-grid map renderer: raw BMR1
  window words, the BME1 terrain plane, and the dictionary, published only
  when map state changes (never on every poll).
- `Adapters` — closure-based system boundaries (relay HTTP, resource change
  stream, mirror WebSocket gamedata, identity persistence, sleep) so tests
  substitute simulated doubles and flows run deterministically.
- API layer (relay HTTP client incl. the BMR1/BMD1/BME1 binary codecs,
  change-stream WebSocket client, mirror WebSocket gamedata client) and the
  pure harvest/resource-map engines are internal to the package.

### CLI (`bitme-cli`) — headless testing surface

```bash
cd Core
swift run bitme-cli resolve maplesugar      # resolve, print outcome, exit
swift run bitme-cli watch maplesugar        # stream live session ViewReps
swift run bitme-cli watch maplesugar --json # one JSON ViewRep per line
swift test                                  # core unit tests (no simulator)
```

### iOS app

SwiftUI (iOS 17+, Swift 6, zero third-party dependencies). The Xcode project
is generated with XcodeGen:

```bash
xcodegen generate          # creates BitMe.xcodeproj from project.yml
open BitMe.xcodeproj       # Cmd+R in Xcode
```

- Bundle ID: `life.encoded.bitme.ios` (display name "Bit-Me")
- `BitMe/` is presentation only: `BitMeApp` owns the `StateMachine` and
  mirrors the published `ViewRep`; `OnboardingView` / `ActivityScreen` render
  reps and dispatch intents.
- Identity persists at `<Application Support>/BitMe/identity.json` (written
  by the core after a successful resolve) — on relaunch the app goes
  straight to the activity screen.

Known gaps (tunable placeholders live in `Core/Sources/BitMeCore/GameConfig.swift`):
stamina regen constants need gamedata + playtest confirmation.

## Status

- Relay: **Phase 1 shipped to production** (2026-09-05) — resolve + session
  endpoints, server-side target-health tracking, watched-spawn (citric) log.
  **Resource-map APIs live** (2026-09-24, first shipped on the X-Ray web
  client): BMR1 session/world windows, region dictionaries, BME1 terrain,
  and the BMD1 change-stream WebSocket.
- Core + CLI: state machine, API, ViewRep extracted; 56 unit tests; CLI
  verified against production (resolve, live watch, live resource map —
  window + dictionary + stream). The session/map loops also survive the
  CLI's start → SignOut → resolve race (late bootstraps can no longer
  resurrect the previous character).
- iOS app: **v0.3** — thin ViewRep renderer over the core (onboarding, big
  countdown with learned pacing, citric banner, stamina projection,
  food-buff classification, live nearby-resources card with the
  spawn/despawn feed) plus the **odd-r hex-grid map**: terrain from BME1
  planes, resources colored per id, live deltas, pan/pinch/follow,
  tap-to-inspect tiles, and a **resource filter panel** (nearby counts,
  search, tracked set persisted in UserDefaults, untracked resources
  faded to 10%), plus a **gathering HUD** — a ¼-width × ⅒-height banner
  pinned to the left edge below the half point while the character is
  Extract-ing, showing the resource name, time until depleted, and the
  stamina meter — verified rendered in the simulator against production.
