# Tutorial 1 — Onboarding & the polling client

End-to-end walkthrough of a Bit-Me first run: the player types their
character name, the app resolves it against the relay, and a 1 Hz polling
loop starts feeding the activity screens. TypeScript examples; the API is
plain JSON + HTTPS so the same flow ports directly to Dart/Swift/Kotlin.

Read [api.md](api.md) first for the endpoint reference.

---

## Step 1 — Resolve the character name

`GET /bitme/resolve?name=` is an **exact, lowercase match** — not a search.
Debounce user input (300–500 ms) and only fire when the input looks
complete; do not fan out a call per keystroke.

```ts
const RELAY = "https://relay.bitcraftsync.app";

export interface ResolvedPlayer {
  found: true;
  entity_id: string;        // decimal string — never a number
  username: string;
  username_lowercase: string;
  identity: string | null;
  region_id: number | null;
  region_name: string | null;
  host: string | null;
  module: string | null;
  signed_in: boolean | null;
}

export async function resolvePlayer(name: string): Promise<ResolvedPlayer> {
  const res = await fetch(`${RELAY}/bitme/resolve?name=${encodeURIComponent(name.trim())}`);
  if (res.status === 404) throw new NotFound(`No character named "${name}"`);
  if (!res.ok) throw new Error(`resolve failed: ${res.status}`);
  return res.json();
}
```

Onboarding UI rules:

- **404** → "No character found with that exact name." Show the typed name
  back to the user; the most common cause is a typo, not the API.
- **`signed_in: false`** → the name is real, but the character is offline.
  Let the user proceed anyway — Bit-Me is useful pre-join, and the session
  endpoint will simply report `signed_in: false` and a stale position.
- Persist `{entity_id, username, region_id}` (secure storage / encrypted
  prefs). Next app launch skips onboarding and offers "Continue as
  Whisper".

What you do **not** need from resolve: `host`/`module` are informational
(they identify the region's upstream SpacetimeDB). Bit-Me talks only to the
relay, so the only field the polling loop needs is **`entity_id`**.

## Step 2 — Check relay readiness

Before the first session poll (and after any suspend/resume), probe:

```ts
export async function relayReady(): Promise<boolean> {
  const res = await fetch(`${RELAY}/cache-health`);
  const body = await res.json();
  return body.ready === true;
}
```

`ready: false` (or the request failing) means the mirror is reseeding — a
deploy takes ~15–20 minutes. Show a reconnecting state, back off ≥ 30 s,
keep rendering any countdowns you already have on screen.

## Step 3 — Poll the session

The session GET is self-registering: polling at ~1 Hz keeps the server-side
tracker warm. Stop polling >15 minutes and the tracker drops; the next poll
transparently re-registers (target health tracking restarts from zero —
see tutorial 2 for what that means on screen).

```ts
export interface SessionSnapshot {
  found: true;
  player_entity_id: string;
  username: string | null;
  signed_in: boolean | null;
  region: number;
  position: Position | null;
  claim: Claim | null;
  stamina: Stamina | null;
  buffs: Buff[];
  actions: PlayerAction[];
  target: Target | null;
  activity_spawns: ActivitySpawn[];
  server_time_ms: number;
}

export type SessionPoll =
  | { kind: "snapshot"; data: SessionSnapshot }
  | { kind: "not-found" }        // 404 — player left mirrored regions, or reseed window
  | { kind: "error"; retryable: boolean };

export class SessionPoller {
  private offsetMs = 0;          // relay clock − device clock
  private timer?: ReturnType<typeof setTimeout>;
  private stopped = false;

  constructor(
    private readonly entityId: string,
    private readonly onSnapshot: (s: SessionSnapshot, nowRelay: number) => void,
    private readonly onState: (s: "ok" | "degraded" | "down") => void,
    private readonly intervalMs = 1000,
  ) {}

  /** Relay-clock "now", safe to compare against snapshot timestamps. */
  get nowRelay(): number {
    return Date.now() + this.offsetMs;
  }

  start() {
    this.stopped = false;
    void this.tick();
  }

  stop() {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
  }

  private backoffMs = 0;

  private async tick() {
    if (this.stopped) return;
    let nextDelay = this.intervalMs;

    try {
      const res = await fetch(`${RELAY}/bitme/session/${this.entityId}`);
      if (res.status === 404) {
        // Unknown player-in-region right now: deploy reseed or player hop.
        this.onState("down");
        this.backoffMs = Math.min(Math.max(this.backoffMs, 30_000) * 2, 300_000);
        nextDelay = this.backoffMs;
      } else if (!res.ok) {
        throw new Error(`session poll failed: ${res.status}`);
      } else {
        const data: SessionSnapshot = await res.json();
        this.offsetMs = data.server_time_ms - Date.now();
        this.backoffMs = 0;
        this.onState("ok");
        this.onSnapshot(data, this.nowRelay);
      }
    } catch (e) {
      // Network error, 5xx, JSON garbage: degraded, not down — keep the UI alive.
      this.onState("degraded");
      this.backoffMs = Math.min(this.backoffMs ? this.backoffMs * 2 : 5_000, 60_000);
      nextDelay = this.backoffMs;
    }

    if (!this.stopped) this.timer = setTimeout(() => void this.tick(), nextDelay);
  }
}
```

Behavior notes baked into that loop:

- **Every snapshot carries `server_time_ms`;** store
  `offset = server_time_ms − Date.now()` and do all countdown math against
  `Date.now() + offset`. Never trust the device clock for the wire data.
- **404 and network errors get separate backoff ladders.** A 404 during a
  deploy reseed can last minutes — start at 30 s. A dropped Wi-Fi packet is
  transient — start at 5 s. Both cap out so a phone in a pocket doesn't burn
  battery.
- **One poll in flight at a time** (the `setTimeout` chain guarantees it).
  If you add foreground/background lifecycle hooks, `stop()` on background
  and `start()` on foreground; iOS/Android will kill long-running sockets
  and timers anyway — design for it (tutorial 2, §5).

## Step 4 — Persist and resume

Minimal durable state for a smooth relaunch:

```ts
interface StoredIdentity {
  entity_id: string;
  username: string;
  region_id: number | null;
  last_used_at: number;
}
```

On resume, don't replay onboarding — go straight to `relayReady()` →
`SessionPoller.start()`. If the session 404s persistently after a ready
probe passes, the character's region may no longer be mirrored (coverage can
change) — offer re-resolve.

## What's next

The snapshot fields only become "time left on the bush", "eat now", and
"stamina full at 17:32" once you run them through the activity state
machine — that's [tutorial 2](tutorial-harvest-session.md).
