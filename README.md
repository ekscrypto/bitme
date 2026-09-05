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

## iOS app

SwiftUI (iOS 17+, Swift 6, zero third-party dependencies). The project is
generated with XcodeGen:

```bash
xcodegen generate          # creates BitMe.xcodeproj from project.yml
open BitMe.xcodeproj       # Cmd+R in Xcode
```

- Bundle ID: `life.encoded.bitme.ios` (display name "Bit-Me")
- Layout: `BitMe/Models` (wire types), `BitMe/Networking` (`RelayClient`,
  `SessionMonitor` 1 Hz poller, `SpacetimeSubscribeClient` one-shot mirror
  WebSocket), `BitMe/Engine` (pure snapshot → screen-state logic +
  `GameConfig` + `GamedataService`), `BitMe/Views` (onboarding, activity
  screen), `BitMeTests/` (wire-format lock + engine + gamedata tests)
- Gamedata: `buff_desc`/`buff_type_desc` are fetched live from the relay's
  global mirror (`wss://relay.bitcraftsync.app:3000/v1/database/
  bitcraft-live-global/subscribe`, JSON subprotocol, subscribe-read-close)
  and cached 48 h; food-buff classification derives from `buff_type_desc`
  names ("Food Buffs", "Food Regen", "Teas"). No gamedata is bundled.
- Debug smoke test: run with environment `BITME_AUTO_RESOLVE=<name>` to skip
  typed onboarding; with simctl:
  `SIMCTL_CHILD_BITME_AUTO_RESOLVE=maplesugar xcrun simctl launch booted life.encoded.bitme.ios`

Known gaps (tunable placeholders live in `BitMe/Engine/GameConfig.swift`):
stamina regen constants need gamedata + playtest confirmation.

## Status

- Relay: **Phase 1 shipped to production** (2026-09-05) — resolve + session
  endpoints, server-side target-health tracking, watched-spawn (citric) log.
- iOS app: **v0.1 working against production** — onboarding → live session
  screen (big depletion countdown with learned pacing, stamina projection,
  food-buff card, citric detection); 17 unit tests green.
