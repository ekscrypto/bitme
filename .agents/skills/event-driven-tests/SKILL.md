---
name: event-driven-tests
description: Test-writing patterns for the BitMeCore suites — event-driven waits via RepCollecting.collect and machine-flow tests that drive the real state machine over scripted adapters. Use when writing or reviewing tests under Core/Tests, adding machine-flow coverage, or when a test flakes or times out under full-suite load.
---

# Event-driven tests

The full suite runs in <1 s (`cd Core && swift test`, no simulator) —
run it after every edit.

## Waits are event-driven

Use `RepCollecting.collect` (`Core/Tests/BitMeCoreTests/RepCollecting.swift`):
subscribe the rep channel, dispatch, and resume the moment `until`
matches. `timeout` is a backstop paid only when the flow under test is
broken — never on the happy path.

**Never** write wall-clock "nothing happened within X ms" assertions.
Under full-suite load (many machines running their loops at once) timer
pollers starve past their deadlines and stretch every staged wait to its
backstop even when the awaited rep has long since arrived — that was the
old scheme, and it is why tests go flaky under load.

`collect` contract details that bite:

- **One sink per wait.** The broadcaster replays only the latest value;
  a second subscriber misses intermediate reps.
- The match is evaluated inside the sink callback, off every actor the
  test or machine occupies — the wait costs nothing beyond the flow's
  own latency.
- The broadcaster's replay means a `collect` issued *after* an `ingest`
  still sees that ingest's final rep.

## Machine-flow harness

Machine-flow tests drive the **real** machine over scripted adapters —
see `AccountDrivenSignInTests` for the shape:

- `@MainActor @Suite(.serialized)` — staged collects share the main
  actor; serialization avoids self-contention.
- Adapter doubles are lock-protected `@unchecked Sendable` boxes that
  record what they were asked (`SimulatedLink` records identities,
  `AccountStore` records saves, `SnapshotBox` swaps snapshots mid-test).
  Record-then-answer, never sleep-then-answer.
- Adapters stub the SDK/transport layer — app tests do not cover the
  live spacetimedb-swift-sdk fork (that layer is debugged live; suspect
  the fork first when only live behavior breaks).

Existing suites: `StateMachineTests`, `SignInFlowTests`,
`ClaimBuildingsTests`, `AccountDrivenSignInTests`.
