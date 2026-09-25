#!/usr/bin/env node
// bitcraft-tap — local listener/forwarder for the BitCraft client.
//
//   BitCraft client ──HTTP──▶ 127.0.0.1:8443 ──HTTPS──▶ api.bitcraftonline.com
//                              (logged, SpacetimeDB URI rewritten to localhost)
//
//   BitCraft client ──ws://──▶ 127.0.0.1:9443 ──wss://──▶ bitcraft-early-access.spacetimedb.com
//                              (every frame recorded, both directions, verbatim passthrough)
//
// Captures land in captures/<session>/:
//   api.jsonl                  one line per HTTP request/response pair
//   conn-<n>/handshake.json    WS path, subprotocol, (redacted) auth headers
//   conn-<n>/index.jsonl       one line per WS frame (dir, offset into frames.bin, len, preview)
//   conn-<n>/frames.bin        raw concatenated frame payloads
//   conn-<n>/close.json        how the connection ended
//   server.log                 tap's own diagnostics + rewrite log

import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';

const argv = new Set(process.argv.slice(2));
const CFG = {
  host: process.env.TAP_HOST || '127.0.0.1',
  apiPort: parseInt(process.env.TAP_API_PORT || '8443', 10),
  wsPort: parseInt(process.env.TAP_WS_PORT || '9443', 10),
  upstreamApi: process.env.TAP_UPSTREAM_API || 'https://api.bitcraftonline.com',
  upstreamWsHost: process.env.TAP_UPSTREAM_WS_HOST || 'bitcraft-early-access.spacetimedb.com',
  session: new Date().toISOString().replace(/[:.]/g, '-').replace('T', '_').slice(0, 19),
};

const here = path.dirname(fileURLToPath(import.meta.url));
const capDir = path.join(here, 'captures', CFG.session);
fs.mkdirSync(capDir, { recursive: true });
const serverLog = fs.createWriteStream(path.join(capDir, 'server.log'), { flags: 'a' });
const apiLog = fs.createWriteStream(path.join(capDir, 'api.jsonl'), { flags: 'a' });
const respBin = fs.openSync(path.join(capDir, 'resp.bin'), 'a');
let respBinOffset = 0;

const log = (...a) => {
  const line = `[${new Date().toISOString()}] ${a.join(' ')}`;
  console.log(line);
  serverLog.write(line + '\n');
};

// ---------- helpers ----------

const SENSITIVE_HEADERS = new Set(['authorization', 'cookie', 'set-cookie', 'x-token', 'x-identity']);
function redactHeader(v) {
  if (!v) return v;
  const h = crypto.createHash('sha256').update(String(v)).digest('hex').slice(0, 12);
  return `<redacted sha256:${h} tail:${String(v).slice(-4)}>`;
}
function redactHeaders(headers) {
  const out = {};
  for (const [k, v] of Object.entries(headers || {})) {
    out[k] = SENSITIVE_HEADERS.has(k.toLowerCase()) ? redactHeader(v) : v;
  }
  return out;
}

// JSON bodies: keep structure, mask values of token-ish keys in LOGS ONLY.
const TOKENISH = /token|jwt|secret|password|authorization/i;
function redactJsonForLog(obj) {
  if (Array.isArray(obj)) return obj.map(redactJsonForLog);
  if (obj && typeof obj === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(obj)) {
      out[k] = TOKENISH.test(k) && typeof v === 'string' && v.length > 8 ? redactHeader(v) : redactJsonForLog(v);
    }
    return out;
  }
  return obj;
}

function printable(buf, max = 220) {
  // BSATN frames embed reducer names / subscription SQL as plain bytes —
  // a printable preview makes the index greppable without a full decoder.
  if (typeof buf === 'string') buf = Buffer.from(buf, 'utf8');
  if (!buf || !buf.length) return '';
  let s = '';
  for (let i = 0; i < Math.min(buf.length, max); i++) {
    const c = buf[i];
    s += c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : '·';
  }
  return s;
}

// Query strings carry live credentials (authToken, accessCode, authTicket) —
// redact them in LOGS ONLY; the forwarded request stays byte-exact.
function redactUrl(u) {
  return String(u).replace(/([?&])(authToken|accessCode|authTicket)=[^&]*/gi, (m, p, k) =>
    `${p}${k}=<redacted>`);
}

// ---------- response rewriting ----------

// Rule 1: full wss:// URIs anywhere in API response bodies.
const WSS_URI_RE = new RegExp(`wss://${CFG.upstreamWsHost.replace(/\./g, '\\.')}(?::443)?`, 'g');
// Rule 2: the game-server address as delivered by /global-module/get-connection-info:
// {"uri":"https://bitcraft-early-access.spacetimedb.com","name":"..."} — the client's
// SpacetimeDB SDK converts the scheme (https->wss, http->ws), so handing it a local
// http URI sends the WebSocket leg to our plaintext forwarder.
const CONN_URI_RE = new RegExp(
  `("uri"\\s*:\\s*")https?://${CFG.upstreamWsHost.replace(/\./g, '\\.')}(?::\\d+)?(")`, 'g');
const BARE_HOST_RE = new RegExp(CFG.upstreamWsHost.replace(/\./g, '\\.'), 'g');

function rewriteBody(body, contentType) {
  const isText = /json|text|javascript/i.test(contentType || '');
  if (!isText || !body || !body.length) return { body, changed: false };
  let text = body.toString('utf8');
  const notes = [];
  const localWs = `ws://${CFG.host}:${CFG.wsPort}`;
  const n1 = (text.match(WSS_URI_RE) || []).length;
  if (n1) {
    text = text.replace(WSS_URI_RE, localWs);
    notes.push(`rewrote ${n1} wss:// URI(s) -> ${localWs}`);
  }
  const localHttp = `http://${CFG.host}:${CFG.wsPort}`;
  const n2 = (text.match(CONN_URI_RE) || []).length;
  if (n2) {
    text = text.replace(CONN_URI_RE, `$1${localHttp}$2`);
    notes.push(`rewrote ${n2} "uri" field(s) -> ${localHttp}`);
  }
  const bare = (text.match(BARE_HOST_RE) || []).length;
  if (bare) notes.push(`note: ${bare} bare occurrence(s) of ${CFG.upstreamWsHost} left untouched`);
  if (!notes.length) return { body, changed: false };
  log(`REWRITE ${notes.join('; ')}`);
  return { body: Buffer.from(text, 'utf8'), changed: true };
}

// ---------- API reverse proxy ----------

const upstreamApiUrl = new URL(CFG.upstreamApi);
let apiReqId = 0;

const apiServer = http.createServer((req, res) => {
  if (req.url.startsWith('/__tap')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, session: CFG.session, startedAt: capDir }));
    return;
  }
  const id = ++apiReqId;
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const reqBody = Buffer.concat(chunks);
    const fwdHeaders = { ...req.headers };
    delete fwdHeaders.host;
    delete fwdHeaders['accept-encoding']; // keep upstream bodies uncompressed for clean logging
    delete fwdHeaders.connection;
    const opts = {
      hostname: upstreamApiUrl.hostname,
      port: 443,
      path: req.url,
      method: req.method,
      headers: fwdHeaders,
    };
    const t0 = Date.now();
    const up = https.request(opts, (upRes) => {
      const rchunks = [];
      upRes.on('data', (c) => rchunks.push(c));
      upRes.on('end', () => {
        let resBody = Buffer.concat(rchunks);
        const rawResBody = resBody; // pre-rewrite bytes for resp.bin
        let logBody = resBody;
        let rewritten = [];
        try {
          const r = rewriteBody(resBody, upRes.headers['content-type']);
          if (r.changed) { resBody = r.body; rewritten.push('body'); }
        } catch (e) {
          log(`rewrite error on ${req.url}: ${e.message}`);
        }
        const resHeaders = { ...upRes.headers };
        if (rewritten.includes('body')) resHeaders['content-length'] = String(resBody.length);
        delete resHeaders['transfer-encoding'];
        // log a redacted copy; the wire copy stays byte-exact. Raw response
        // bytes go to resp.bin with offset/len recorded alongside.
        const ctJson = /json/i.test(upRes.headers['content-type'] || '');
        if (ctJson) {
          try { logBody = JSON.stringify(redactJsonForLog(JSON.parse(resBody.toString('utf8')))); } catch {}
        }
        const respOff = respBinOffset;
        fs.writeSync(respBin, rawResBody);
        respBinOffset += rawResBody.length;
        const rec = {
          ts: new Date().toISOString(), id, durMs: Date.now() - t0,
          request: { method: req.method, url: redactUrl(req.url), headers: redactHeaders(req.headers) },
          requestBody: reqBody.length ? printable(reqBody, 4000) : '',
          response: { status: upRes.statusCode, headers: redactHeaders(upRes.headers), bodyOff: respOff, bodyLen: resBody.length },
          responseBody: logBody && logBody.length ? printable(logBody, 8000) : '',
        };
        apiLog.write(JSON.stringify(rec) + '\n');
        res.writeHead(upRes.statusCode, resHeaders);
        res.end(resBody);
      });
    });
    up.on('error', (e) => {
      log(`upstream api error id=${id} ${req.method} ${req.url}: ${e.message}`);
      if (!res.headersSent) res.writeHead(502, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'tap upstream failure', detail: e.message }));
    });
    up.end(reqBody);
  });
});

// ---------- WebSocket forwarder ----------

const wss = new WebSocketServer({
  noServer: true,
  perMessageDeflate: false,
  maxPayload: 256 * 1024 * 1024,
  // The upstream (real server) decides the subprotocol; we already know it
  // by the time handleUpgrade runs (upstream is open), so mirror its choice.
  handleProtocols: () => (upstreamMirror && upstreamMirror.protocol) || false,
});
let upstreamMirror = null;

let connSeq = 0;

function handleUpgrade(req, socket, head) {
  const connId = ++connSeq;
  const connDir = path.join(capDir, `conn-${String(connId).padStart(2, '0')}`);
  fs.mkdirSync(connDir, { recursive: true });
  const framesBin = fs.openSync(path.join(connDir, 'frames.bin'), 'a');
  const indexStream = fs.createWriteStream(path.join(connDir, 'index.jsonl'), { flags: 'a' });
  let frameOffset = 0;
  const recordFrame = (dir, data, isBinary) => {
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
    const entry = {
      ts: new Date().toISOString(), dir,
      kind: isBinary ? 'binary' : 'text',
      off: frameOffset, len: buf.length,
      preview: printable(buf),
    };
    fs.writeSync(framesBin, buf);
    frameOffset += buf.length;
    indexStream.write(JSON.stringify(entry) + '\n');
  };
  const finish = (why, code, reason) => {
    try { fs.writeFileSync(path.join(connDir, 'close.json'), JSON.stringify({ ts: new Date().toISOString(), why, code, reason: String(reason || '') }, null, 2)); } catch {}
    try { fs.closeSync(framesBin); } catch {}
    indexStream.end();
  };

  const target = `wss://${CFG.upstreamWsHost}${req.url}`;
  const protocols = String(req.headers['sec-websocket-protocol'] || '')
    .split(',').map((s) => s.trim()).filter(Boolean);
  const fwdHeaders = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (/^(host|connection|upgrade|sec-websocket-.*)$/i.test(k)) continue;
    fwdHeaders[k] = v; // includes authorization, x-headers, user-agent
  }

  log(`conn-${connId} WS upgrade -> ${target} protocols=[${protocols.join(', ')}]`);

  let upstream;
  try {
    // NOTE: protocols must be the 2nd ARGUMENT to the ws constructor — the
    // server rejects the handshake with "no valid protocol selected" otherwise.
    upstream = new WebSocket(target, protocols, {
      headers: fwdHeaders,
      perMessageDeflate: false,
      maxPayload: 256 * 1024 * 1024,
      handshakeTimeout: 15000,
    });
    upstreamMirror = upstream;
  } catch (e) {
    log(`conn-${connId} dial failed: ${e.message}`);
    socket.destroy();
    finish('dial-error', 1011, e.message);
    return;
  }

  const die = (why, code = 1011, reason = '') => {
    try { upstream.close(code, reason); } catch {}
    try { socket.destroy(); } catch {}
    finish(why, code, reason);
  };

  upstream.on('error', (e) => {
    log(`conn-${connId} upstream error: ${e.message}`);
    die('upstream-error', 1011, e.message);
  });

  upstream.on('unexpected-response', (_req, res) => {
    let body = '';
    res.on('data', (c) => (body += c));
    res.on('end', () => {
      log(`conn-${connId} upstream rejected: HTTP ${res.statusCode} ${body.slice(0, 300)}`);
      // Relay the rejection so the client sees the same failure it would have.
      socket.write(
        `HTTP/1.1 ${res.statusCode} ${res.statusMessage}\r\n` +
        'content-type: text/plain\r\n' +
        `content-length: ${Buffer.byteLength(body)}\r\n` +
        'connection: close\r\n\r\n' + body,
      );
      socket.destroy();
      finish('upstream-rejected', res.statusCode, body.slice(0, 500));
    });
  });

  upstream.on('open', () => {
    fs.writeFileSync(path.join(connDir, 'handshake.json'), JSON.stringify({
      ts: new Date().toISOString(),
      target,
      requestPath: req.url,
      requestedProtocols: protocols,
      negotiatedProtocol: upstream.protocol || null,
      requestHeaders: redactHeaders(req.headers),
    }, null, 2));
    log(`conn-${connId} upstream open (protocol=${upstream.protocol || 'none'})`);

    // Complete the client handshake only now, mirroring the upstream's
    // negotiated subprotocol so protocol selection is decided by the real server.
    wss.handleUpgrade(req, socket, head, (client) => {
      log(`conn-${connId} client connected`);
      client.on('message', (data, isBinary) => {
        recordFrame('c2s', data, isBinary);
        if (upstream.readyState === WebSocket.OPEN) upstream.send(data, { binary: isBinary });
      });
      upstream.on('message', (data, isBinary) => {
        recordFrame('s2c', data, isBinary);
        if (client.readyState === WebSocket.OPEN) client.send(data, { binary: isBinary });
      });
      const linkClose = (who) => (code, reason) => {
        const other = who === 'client' ? upstream : client;
        log(`conn-${connId} ${who} closed code=${code}`);
        try { other.close(code, reason); } catch {}
        finish(`${who}-closed`, code, reason ? Buffer.from(reason).toString('utf8') : '');
      };
      client.on('close', linkClose('client'));
      client.on('error', (e) => { log(`conn-${connId} client error: ${e.message}`); die('client-error'); });
      upstream.on('close', linkClose('upstream'));
    });
  });
}

apiServer.on('upgrade', handleUpgrade);

const wsServer = http.createServer((req, res) => {
  if (req.url.startsWith('/__tap')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true }));
    return;
  }
  res.writeHead(426, { 'content-type': 'text/plain' });
  res.end('bitcraft-tap: websocket endpoint — connect with ws://');
});
wsServer.on('upgrade', handleUpgrade);

apiServer.listen(CFG.apiPort, CFG.host, () =>
  log(`tap API proxy  http://${CFG.host}:${CFG.apiPort} -> ${CFG.upstreamApi}`));
wsServer.listen(CFG.wsPort, CFG.host, () =>
  log(`tap WS forward ws://${CFG.host}:${CFG.wsPort} -> wss://${CFG.upstreamWsHost}`));
log(`capture dir: ${capDir}`);

if (!argv.has('--keep')) {
  // Long-lived server; nothing to do on exit for now.
}
