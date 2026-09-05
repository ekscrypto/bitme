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
| [docs/api.md](docs/api.md) | **API reference** — `/bitme/resolve`, `/bitme/session/:entity_id`, field-by-field, error and deploy semantics. |
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
- `Adapters` — closure-based system boundaries (relay HTTP, mirror WebSocket
  gamedata, identity persistence, sleep) so tests substitute simulated
  doubles and flows run deterministically.
- API layer (relay HTTP client, mirror WebSocket gamedata client) and the
  pure harvest engine are internal to the package.

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
- Core + CLI: state machine, API, ViewRep extracted; 26 unit tests; CLI
  verified against production (resolve + live watch).
- iOS app: **v0.2** — thin ViewRep renderer over the core (onboarding, big
  countdown with learned pacing, citric banner, stamina projection,
  food-buff classification), verified live against production.
