# bitcraft-tap

Local listener/forwarder that sits between the BitCraft client and its servers
so we can record the exact SpacetimeDB traffic the official client sends and
receives — reducer call order, subscription SQL, table update stream.

```
BitCraft client ──HTTP──▶ 127.0.0.1:8443 ──HTTPS──▶ api.bitcraftonline.com
                          (logged; SpacetimeDB URIs in responses rewritten
                           to ws://127.0.0.1:9443)

BitCraft client ──ws://──▶ 127.0.0.1:9443 ──wss://──▶ bitcraft-early-access.spacetimedb.com
                          (frames recorded both directions, forwarded verbatim)
```

## Run

```sh
cd tools/tap
npm install        # first time only (installs ws)
npm start          # or: node server.js
```

Defaults: API proxy on `127.0.0.1:8443`, WS forwarder on `127.0.0.1:9443`.
Override with env vars `TAP_HOST`, `TAP_API_PORT`, `TAP_WS_PORT`,
`TAP_UPSTREAM_API`, `TAP_UPSTREAM_WS_HOST`. Health check: `curl
http://127.0.0.1:8443/__tap/status`.

## Pointing the client at it

Preference override (no app-bundle changes):

```sh
defaults write com.ClockworkLabs.BitCraft 'ApiServerUrlOverride' 'http://127.0.0.1:8443'
defaults write com.ClockworkLabs.BitCraft 'EarlyAccess:ApiServerUrlOverride' 'http://127.0.0.1:8443'
```

Revert with `defaults delete` for both keys. If the client ignores the
override, fall back to editing `BitCraft.app/Contents/Resources/Data/
StreamingAssets/Config/production.json` (`apiServerUrl`) — keep a backup and
ad-hoc re-sign the bundle afterwards (`codesign --force --deep -s - BitCraft.app`)
since modifying bundle contents invalidates the signature.

The WebSocket rewrite happens automatically: any `wss://bitcraft-early-access.
spacetimedb.com` URI the API returns is rewritten to the local forwarder before
the client sees it. Everything else passes through byte-exact. If the server
URI never transits the API, `server.log` will note bare occurrences of the
hostname so a new rewrite rule can be added.

## Decode captures

```sh
node decode.js captures/<session>            # all connections: summary + timeline
node decode.js captures/<session> 3          # just conn-03
node decode.js captures/<session> --scan bitcraft-live   # find frames containing text
```

Writes `conn-NN/decoded.jsonl` (every message structured: subscriptions with
exact SQL, reducer calls with args, table update counts) and prints the reducer
call order, subscription catalog, and per-table traffic stats.

Protocol reference: SpacetimeDB `crates/client-api-messages/src/websocket/`
(v2.rs + common.rs). Envelope: server→client frames are
`[u8 0=raw|1=brotli|2=gzip] + BSATN message`; client→server frames are raw
BSATN.

## Capture layout

`captures/<session>/` (gitignored):

- `api.jsonl` — every HTTP request/response pair (auth material redacted;
  forwarded payloads on the wire are untouched)
- `conn-NN/handshake.json` — WS path, subprotocol, redacted headers
- `conn-NN/index.jsonl` — one line per frame: direction (`c2s`/`s2c`), binary
  or text, offset+length into `frames.bin`, printable preview (BSATN embeds
  reducer names / SQL as plain bytes, so the index is greppable)
- `conn-NN/frames.bin` — raw concatenated frame payloads
- `conn-NN/close.json` — close code/reason for both legs
- `server.log` — tap diagnostics + rewrite log
