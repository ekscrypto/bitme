# Tutorial 2 — The harvest session: from snapshots to on-screen guidance

This tutorial turns the raw `/bitme/session` snapshot into the four things
Bit-Me actually shows, using the Giant Bountiful Strawberry Bush scenario as
the worked example:

1. **Big countdown** — time left on the resource being harvested
2. **"Eat food" side indicator** — food buff missing or about to expire
3. **"Stamina recovering / full at T"** — when to stop and wait
4. **Citric alert** — the 30-second rare-resource window

Prerequisites: [tutorial 1](tutorial-onboarding-and-polling.md) (a running
`SessionPoller` and relay-corrected clock) and bundled static gamedata
(§6 of [api.md](api.md): `resource_desc`, `buff_desc`, `food_desc`,
`parameters_desc`).

---

## 1. Read the player's current activity from `actions`

`actions` rows persist after completion — they are the *last* action on each
layer, not necessarily a running one. Derive liveness, never assume it:

```ts
export interface LiveAction {
  actionType: string;            // "Extract" | "Craft" | …
  layer: "Base" | "UpperBody";
  targetEntityId: string | null;
  recipeId: number | null;
  progress01: number;            // 0..1, clamped
  endsInMs: number;              // negative = already finished
}

export function liveActions(s: SessionSnapshot, nowRelay: number): LiveAction[] {
  return s.actions
    .filter(a =>
      a.last_action_result === "Success" &&
      !a.client_cancel &&
      nowRelay < a.ends_at_ms)
    .map(a => ({
      actionType: a.action_type,
      layer: a.layer as "Base" | "UpperBody",
      targetEntityId: a.target_entity_id,
      recipeId: a.recipe_id,
      progress01: clamp01((nowRelay - a.start_time_ms) / a.duration_ms),
      endsInMs: a.ends_at_ms - nowRelay,
    }));
}

export const isHarvesting = (acts: LiveAction[]) =>
  acts.some(a => a.actionType === "Extract");
```

A harvest tick cycle in BitCraft is a rapid series of short `Extract`
actions, all targeting the same entity. **The stable identity of "the bush"
is `target_entity_id`, not the action row** — actions blink on and off
between ticks, the target doesn't.

## 2. The big countdown — time left on the resource

Two independent signals, combine both:

**a) Depletion (health-based).** While a session polls, the relay tracks the
target's `health` per extract tick:

```ts
function depletionCountdown(s: SessionSnapshot, harvest: {msPerPoint: number}): number | null {
  const t = s.target;
  if (!t || t.health === null || t.max_health === null) return null;
  const remainingPoints = t.health;                       // points of health left
  return remainingPoints * harvest.msPerPoint;            // calibrate: see below
}
```

`msPerPoint` (ms of harvesting per health point) is **learned, not
configured**: keep a rolling average of `(Δnow) / (Δhealth)` across observed
extract ticks — a few ticks in, the estimate is stable; until then, show
health as a percentage instead of a time. Reset the estimate when
`target.entity_id` changes.

**b) Despawn window (clock-based).** When the resource itself arrived as a
watched spawn — the Bountiful bush spawns when the Withering bush is
destroyed — `activity_spawns` carries its whole window:

```ts
function spawnWindowLeft(s: SessionSnapshot, nowRelay: number, resourceId: number): number | null {
  const spawn = s.activity_spawns.find(a => a.resource_id === resourceId);
  if (!spawn) return null;
  if (spawn.expires_at_ms !== null) return spawn.expires_at_ms - nowRelay;
  return null; // no server-side despawn timer → rely on (a) or bundled gamedata
}
```

**Recommended display rule for the big timer:** show
`min(health-based estimate, spawn-window remaining)` when both exist; fall
back to whichever single signal is available; show a percentage ring when
neither is (first poll after targeting, `health: null`).

Also read `target.despawn_time_secs` / `respawn_time_secs` — passthrough
gamedata the relay includes precisely so the client can reason about windows
without shipping its own copy of `resource_desc` lookups for this screen.

## 3. Citric detection — the 30-second window

This is what `activity_spawns` exists for. The Citric bush is a **new
entity**; it will never appear as your `target` until the player switches to
it. Watch for its *insert* into the spawn list:

```ts
const CITRIC_IDS = new Set([1688062540, 65901922, 1875092977]);

function detectCitric(
  prev: SessionSnapshot | null,
  next: SessionSnapshot,
  nowRelay: number,
): CitricAlert | null {
  for (const spawn of next.activity_spawns) {
    if (!CITRIC_IDS.has(spawn.resource_id)) continue;
    const isNew = !prev?.activity_spawns.some(a => a.entity_id === spawn.entity_id);
    const expiresAt = spawn.expires_at_ms ?? (spawn.spawned_at_ms + 30_000); // 30 s fallback
    const remainingMs = expiresAt - nowRelay;
    if (remainingMs <= 0) continue;
    return {
      entityId: spawn.entity_id,
      resource: spawn.name ?? "Citric Giant Berry Bush",
      location: spawn.location,
      remainingMs,
      isNewlySpawned: isNew,       // isNew + <30s → full-screen alert + vibration
    };
  }
  return null;
}
```

Alert thresholds worth tuning in playtests: full alert while
`remainingMs > 0`, escalate (sound/vibration) for the first 10 s. If
`health !== null` on the spawn, someone else is already harvesting it —
different copy ("citric bush up — being harvested").

The relay scopes spawns to the player's claim (or surrounding wilderness),
so a spawn entry means "in the player's area", not merely "in the region" —
no distance filtering needed on the phone beyond `location` for a direction
arrow if you want one.

## 4. "Eat food" indicator — food buff watch

`buffs` lists live buffs with second-resolution expiry. Which buff ids count
as "food" is resolved at runtime by `GamedataService`: it fetches
`buff_desc` + `buff_type_desc` from the relay's global mirror over a one-shot
JSON WebSocket (connect → `SubscribeSingle` → `SubscribeApplied` → close),
classifies food types by name ("Food Buffs", "Food Regen", "Teas"), and
caches the derived id set for 48 h — stale cache is used on fetch failure.
The iOS implementation lives in `BitMe/Networking/SpacetimeSubscribeClient.swift`
and `BitMe/Engine/GamedataService.swift`.

```ts
const foodBuffIDs = await gamedataService.foodBuffIDs(); // Set<number>, 48 h cache
```

```ts
const FOOD_BUFF_IDS: Set<number> = loadFromGamedata(); // buff_desc ⋈ buff_type_desc

export interface FoodBuffState {
  active: boolean;
  expiresAtSec: number | null;   // unix seconds
  remainingMs: number | null;
}

export function foodBuffState(s: SessionSnapshot, nowRelay: number): FoodBuffState {
  const nowSec = nowRelay / 1000;
  const rows = s.buffs.filter(b => FOOD_BUFF_IDS.has(b.buff_id));
  // Multiple food buffs can stack; the latest expiry is the one that matters.
  const expiries = rows
    .map(b => b.start_timestamp + b.duration)
    .filter(exp => exp > nowSec);            // expired rows can linger — check the math
  if (expiries.length === 0) return { active: false, expiresAtSec: null, remainingMs: null };
  const expiresAtSec = Math.max(...expiries);
  return { active: true, expiresAtSec, remainingMs: expiresAtSec * 1000 - nowRelay };
}
```

**Indicator logic** (thresholds to tune in playtests):

| Condition | Display |
|---|---|
| `active === false` while harvesting | Persistent "EAT FOOD" side indicator |
| `0 < remainingMs < 120_000` while harvesting | Amber buff timer, gently pulsing |
| citric detected (§3) **and** food missing/expiring within the citric window | Escalate: "EAT NOW — citric in Xs" |

The last row is the scenario's whole point: the player should top up their
stamina *before* the Bountiful bush dies, because the regen-from-food
window they'll want to exploit is the 30-second Citric phase.

## 5. Stamina — "recovering, full at T"

The relay reports the raw state, not a projection:

```json
{ "current": 370.5, "max": 471.0, "max_health": 210.0,
  "last_decrease_at": "2026-09-05T17:14:52.000Z" }
```

Project client-side with the bundled gamedata rules
(`parameters_desc`: passive-regen delay + tick rate; food-buff modifiers
from `buff_desc.values` when present):

```ts
export function staminaProjection(s: SessionSnapshot, nowRelay: number, regen: RegenRules) {
  const st = s.stamina;
  if (!st) return null;
  const lastDecreaseMs = Date.parse(st.last_decrease_at + "Z"); // RFC 3339, UTC
  const regenStartMs = lastDecreaseMs + regen.delayAfterDecreaseMs;
  const elapsed = Math.max(0, nowRelay - regenStartMs);
  const projected = Math.min(st.max, st.current + Math.floor(elapsed / regen.tickMs) * regen.perTick);
  const missing = st.max - projected;
  const fullAtMs = missing <= 0 ? nowRelay : nowRelay + Math.ceil(missing / regen.perTick) * regen.tickMs;
  return { current: st.current, projected, max: st.max, fullAtMs, pct: projected / st.max };
}
```

Two honest caveats:

- `last_decrease_at` is only as fresh as the last poll (1 Hz) — project
  forward between polls, don't step backward when a new snapshot arrives
  with the same anchor (monotonic clamp: `projected = max(prev, next)`).
- The exact regen curve (delay, tick, per-tick amount, whether the food-buff
  `values` are multipliers or additive) must be confirmed against gamedata
  and playtesting — the structure above is stable, the constants are not.
  Treat `RegenRules` as a tunable config, not gospel.

**UI mapping:** when `isHarvesting` and stamina pct < ~15% → red "stamina
low" state; when the player pauses and the projection is climbing → "full at
17:32 (2m 10s)"; when `current ≥ max` and no extract action → "ready —
resume harvesting".

## 6. Assembling the screen state

One pure function per render tick (60 fps locally, re-anchored at 1 Hz by
polls) keeps the phone-side logic testable:

```ts
export interface HarvestScreenState {
  connection: "ok" | "degraded" | "down";
  signedIn: boolean;
  activity: "idle" | "harvesting" | "crafting" | "other";
  bush: { name: string; progressPct: number | null; timeLeftMs: number | null } | null;
  citric: CitricAlert | null;
  food: FoodBuffState;
  stamina: ReturnType<typeof staminaProjection>;
}

export function render(s: SessionSnapshot, prev: SessionSnapshot | null,
                       nowRelay: number, cfg: GameConfig): HarvestScreenState {
  const acts = liveActions(s, nowRelay);
  const harvesting = acts.some(a => a.actionType === "Extract");
  return {
    connection: "ok",
    signedIn: s.signed_in !== false,
    activity: harvesting ? "harvesting"
            : acts.some(a => a.actionType === "Craft") ? "crafting"
            : acts.length > 0 ? "other" : "idle",
    bush: s.target && s.target.resource_id !== null ? {
      name: s.target.name ?? "Unknown resource",
      progressPct: s.target.health !== null && s.target.max_health
        ? 1 - s.target.health / s.target.max_health : null,
      timeLeftMs: depletionCountdown(s, cfg.harvest) ?? spawnWindowLeft(
        s, nowRelay, s.target.resource_id),
    } : null,
    citric: detectCitric(prev, s, nowRelay),
    food: foodBuffState(s, nowRelay),
    stamina: staminaProjection(s, nowRelay, cfg.regen),
  };
}
```

Note `bush` requires `resource_id !== null` — a Base-layer crafting-station
target has `health` but no resource identity, and shouldn't drive the bush
timer.

## 7. Lifecycle: backgrounding, deploys, and mid-session breaks

- **Background the app** → stop the poller (mobile OS rules), keep the last
  snapshot + the relay-clock offset. On foreground: `relayReady()` →
  restart poller → first fresh snapshot re-anchors everything. Countdowns
  that ran purely on `nowRelay` interpolation will have kept ticking in the
  UI; snap them to the fresh snapshot immediately (don't animate the
  correction).
- **Deploy reseed (404 / `ready: false`)** → reconnecting banner, keep the
  last screen state frozen. Server-side tracking (target `health`, spawn
  log) restarts empty after the reseed, so expect one or two snapshots with
  `health: null` and an empty `activity_spawns` — the state machine above
  already treats those as "unknown", not "gone". Show the big timer as a
  percentage ring until health re-anchors.
- **Session TTL (15 min of no polling)** → tracker dropped; same visual
  result as a reseed. The poll re-registers transparently.
- **`signed_in: false` + `position.age_ms` large** → "Character offline"
  state; stop alerts, keep the resolve shortcut on screen.

## 8. Testing checklist before playtest

- [ ] Resolve: exact-match happy path, 404 typo path, offline character
- [ ] Poller: backoff ladders (kill Wi-Fi vs. deploy 404), clock-offset
      correction (set device clock +5 min, verify countdowns)
- [ ] Actions: completed `Extract` rows don't render as live; blink between
      ticks doesn't flap `bush`
- [ ] Citric: insert detection fires exactly once per `entity_id`; expired
      entries are ignored; `expires_at_ms: null` fallback path
- [ ] Buffs: expired-but-lingering rows don't count as active; stacked food
      buffs take the max expiry
- [ ] Stamina: monotonic between polls; `stamina: null` (fresh character)
      renders a graceful empty state
- [ ] Deploy window: 404 loop shows reconnecting, UI stays on last data,
      recovers to live within one poll after ready
