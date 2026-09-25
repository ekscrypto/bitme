#!/usr/bin/env node
// decode.js — decode bitcraft-tap captures (SpacetimeDB v2.bsatn websocket protocol).
//
// Wire format (per SpacetimeDB crates/client-api-messages/src/websocket/):
//   frame = [u8 compression tag: 0=raw, 1=brotli, 2=gzip] + payload
//   payload = BSATN-encoded ClientMessage (c2s) or ServerMessage (s2c)
//   BSATN: little-endian; str/Bytes = u32 len + data; array = u32 count + elems;
//          Option/Result-style enums = u8 variant tag; Rust enums = u8 tag.
//
// Usage:
//   node decode.js <session-dir> [conn-number ...]   # decode + summary
//   node decode.js <session-dir> --scan <text>       # search rows/args for text

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const sessionDir = process.argv[2];
if (!sessionDir) {
  console.error('usage: node decode.js <session-dir> [conn-number ...] | --scan <text>');
  process.exit(1);
}
const args = process.argv.slice(3);
const scanMode = args[0] === '--scan';
const scanText = scanMode ? args[1] : '';
const connFilter = !scanMode && args.length
  ? args.map((n) => `conn-${String(n).padStart(2, '0')}`)
  : null;

// ---------- BSATN reader ----------

class Rdr {
  constructor(buf) { this.buf = buf; this.off = 0; }
  get remaining() { return this.buf.length - this.off; }
  u8() { return this.buf.readUInt8(this.off++); }
  u16() { const v = this.buf.readUInt16LE(this.off); this.off += 2; return v; }
  u32() { const v = this.buf.readUInt32LE(this.off); this.off += 4; return v; }
  u64() { const v = this.buf.readBigUInt64LE(this.off); this.off += 8; return v; }
  i64() { const v = this.buf.readBigInt64LE(this.off); this.off += 8; return v; }
  str() { const len = this.u32(); const s = this.buf.toString('utf8', this.off, this.off + len); this.off += len; return s; }
  bytes() { const len = this.u32(); const b = this.buf.subarray(this.off, this.off + len); this.off += len; return b; }
  take(n) { const b = this.buf.subarray(this.off, this.off + n); this.off += n; return b; }
  arr(fn) { const n = this.u32(); const out = []; for (let i = 0; i < n; i++) out.push(fn(this)); return out; }
  opt(fn) { const t = this.u8(); return t === 0 ? null : fn(this); }
}

const hex = (b, max = 64) =>
  b.length === 0 ? '' : Buffer.from(b).toString('hex').slice(0, max * 2) + (b.length > max ? `…(${b.length}B)` : '');

const printable = (b, max = 120) => {
  let s = '';
  for (let i = 0; i < Math.min(b.length, max); i++) {
    const c = b[i];
    s += c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : '·';
  }
  return s;
};

// ---------- protocol types ----------

function rowList(r) {
  const hintTag = r.u8();
  let rowCount, size = 0;
  if (hintTag === 0) {
    size = r.u16();
  } else if (hintTag === 1) {
    rowCount = r.arr((rr) => Number(rr.u64())).length;
  } else {
    throw new Error(`row size hint tag ${hintTag}`);
  }
  const data = r.bytes();
  if (hintTag === 0) rowCount = size === 0 ? 0 : Math.floor(data.length / size);
  return { rowCount, bytes: data.length, data };
}

function queryRows(r) {
  return r.arr((rr) => ({ table: rr.str(), rows: rowList(rr) }));
}

function tableUpdate(r) {
  const tableName = r.str();
  const kind = r.u8();
  let inserts = 0, deletes = 0, events = 0, bytes = 0, data;
  if (kind === 0) {
    const i = rowList(r); const d = rowList(r);
    inserts = i.rowCount; deletes = d.rowCount;
    bytes = i.bytes + d.bytes;
    data = Buffer.concat([i.data, d.data]);
  } else if (kind === 1) {
    const e = rowList(r);
    events = e.rowCount; bytes = e.bytes; data = e.data;
  } else throw new Error(`table update rows tag ${kind}`);
  return { table: tableName, kind, inserts, deletes, events, bytes, data };
}

function transactionUpdate(r) {
  return r.arr((rr) => ({ querySetId: rr.u32(), tables: rr.arr(tableUpdate) }));
}

const CLIENT = ['Subscribe', 'Unsubscribe', 'OneOffQuery', 'CallReducer', 'CallProcedure', 'SubscribeBatch'];
const SERVER = ['InitialConnection', 'SubscribeApplied', 'UnsubscribeApplied', 'SubscriptionError',
  'TransactionUpdate', 'OneOffQueryResult', 'ReducerResult', 'ProcedureResult', 'SubscribeBatchApplied'];

function decodeClient(r) {
  const tag = r.u8();
  const out = { type: CLIENT[tag] ?? `Client(${tag})` };
  if (tag === 0) {
    out.requestId = r.u32(); out.querySetId = r.u32();
    out.queries = r.arr((rr) => rr.str());
  } else if (tag === 1) {
    out.requestId = r.u32(); out.querySetId = r.u32(); out.flags = r.u8();
  } else if (tag === 2) {
    out.requestId = r.u32(); out.query = r.str();
  } else if (tag === 3 || tag === 4) {
    out.requestId = r.u32(); out.flags = r.u8();
    out.name = r.str(); out.args = r.bytes();
  } else if (tag === 5) {
    out.requestId = r.u32();
    out.sets = r.arr((rr) => ({ querySetId: rr.u32(), queries: rr.arr((x) => x.str()) }));
  } else throw new Error(`client tag ${tag}`);
  return out;
}

function decodeServer(r) {
  const tag = r.u8();
  const out = { type: SERVER[tag] ?? `Server(${tag})` };
  if (tag === 0) {
    out.identity = hex(r.take(32)); out.connectionId = hex(r.take(16)); out.token = r.str();
  } else if (tag === 1) {
    out.requestId = r.u32(); out.querySetId = r.u32(); out.tables = queryRows(r);
  } else if (tag === 2) {
    out.requestId = r.u32(); out.querySetId = r.u32(); out.tables = r.opt(queryRows);
  } else if (tag === 3) {
    out.requestId = r.opt((rr) => rr.u32()); out.querySetId = r.u32(); out.error = r.str();
  } else if (tag === 4) {
    out.querySets = transactionUpdate(r);
  } else if (tag === 5) {
    out.requestId = r.u32();
    const ok = r.u8();
    out.tables = ok === 0 ? queryRows(r) : undefined;
    if (ok !== 0) out.error = r.str();
  } else if (tag === 6) {
    out.requestId = r.u32(); out.timestamp = Number(r.i64());
    const outcome = r.u8();
    if (outcome === 0) { out.outcome = 'Ok'; out.retValue = r.bytes(); out.querySets = transactionUpdate(r); }
    else if (outcome === 1) out.outcome = 'OkEmpty';
    else if (outcome === 2) { out.outcome = 'Err'; out.errValue = r.bytes(); }
    else if (outcome === 3) { out.outcome = 'InternalError'; out.error = r.str(); }
    else throw new Error(`reducer outcome ${outcome}`);
  } else if (tag === 7) {
    const st = r.u8();
    out.status = st === 0 ? 'Returned' : 'InternalError';
    if (st === 0) out.retValue = r.bytes(); else out.error = r.str();
    out.timestamp = Number(r.i64()); out.duration = Number(r.i64()); out.requestId = r.u32();
  } else if (tag === 8) {
    out.requestId = r.u32();
    out.results = r.arr((rr) => {
      const qsid = rr.u32();
      const ok = rr.u8();
      return ok === 0 ? { querySetId: qsid, tables: queryRows(rr) } : { querySetId: qsid, error: rr.str() };
    });
  } else throw new Error(`server tag ${tag}`);
  return out;
}

// The compression envelope is SERVER->CLIENT only (SERVER_MSG_COMPRESSION_TAG_*
// in common.rs). Client messages are sent as raw BSATN with no envelope byte.
function unwrap(frame, dir) {
  if (dir === 'c2s') return { compression: 'raw', payload: frame };
  const tag = frame[0];
  const payload = frame.subarray(1);
  if (tag === 0) return { compression: 'raw', payload };
  if (tag === 1) return { compression: 'brotli', payload: zlib.brotliDecompressSync(payload) };
  if (tag === 2) return { compression: 'gzip', payload: zlib.gunzipSync(payload) };
  throw new Error(`server compression tag ${tag}`);
}

// ---------- driver ----------

const conns = fs.readdirSync(sessionDir)
  .filter((d) => /^conn-\d+$/.test(d) && (!connFilter || connFilter.includes(d)))
  .filter((d) => fs.existsSync(path.join(sessionDir, d, 'index.jsonl')))
  .sort();

for (const conn of conns) {
  const dir = path.join(sessionDir, conn);
  const index = fs.readFileSync(path.join(dir, 'index.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  const bin = fs.readFileSync(path.join(dir, 'frames.bin'));
  const db = (fs.existsSync(path.join(dir, 'handshake.json'))
    ? JSON.parse(fs.readFileSync(path.join(dir, 'handshake.json'), 'utf8')).requestPath : '').match(/database\/([^/?]+)/)?.[1];

  const decodedOut = fs.createWriteStream(path.join(dir, 'decoded.jsonl'));
  const stats = { raw: 0, brotli: 0, gzip: 0, errors: 0 };
  const events = [];
  const tableTotals = {};
  const subscriptions = [];
  const reducerCalls = [];
  const searchHits = [];

  for (const f of index) {
    const frame = bin.subarray(f.off, f.off + f.len);
    let comp, payload, msg, err = null;
    try {
      ({ compression: comp, payload } = unwrap(frame, f.dir));
      stats[comp]++;
      const r = new Rdr(payload);
      msg = f.dir === 'c2s' ? decodeClient(r) : decodeServer(r);
      if (r.remaining > 0) err = `trailing ${r.remaining}B`;
    } catch (e) {
      stats.errors++; err = e.message;
    }
    const rec = { ts: f.ts, dir: f.dir, frameLen: f.len, ...(msg || { type: 'DECODE-ERROR' }), decodeError: err };
    if (comp) rec.compression = comp;
    // strip bulky row data from the jsonl record (kept in frames.bin); keep counts
    const stripRows = (o) => {
      for (const k of Object.keys(o)) {
        if (Array.isArray(o[k])) o[k].forEach(stripRows);
        else if (o[k] && typeof o[k] === 'object') {
          if ('rowCount' in o[k]) { o[k] = { rowCount: o[k].rowCount, bytes: o[k].bytes, data: undefined }; }
          else stripRows(o[k]);
        } else if (k === 'data' && Buffer.isBuffer(o[k])) { o[k] = undefined; }
      }
    };
    stripRows(rec);
    decodedOut.write(JSON.stringify(rec) + '\n');

    if (!msg) continue;
    events.push({ ts: f.ts, dir: f.dir, msg });
    if (scanText) {
      const blob = JSON.stringify(msg, (k, v) => (v && v.type === 'Buffer' ? Buffer.from(v.data).toString('latin1') : v));
      if (blob.includes(scanText)) searchHits.push({ ts: f.ts, dir: f.dir, type: msg.type });
    }
    if (msg.type === 'Subscribe') subscriptions.push({ ts: f.ts, requestId: msg.requestId, querySetId: msg.querySetId, queries: msg.queries });
    if (msg.type === 'SubscribeBatch') msg.sets.forEach((s) => subscriptions.push({ ts: f.ts, requestId: msg.requestId, querySetId: s.querySetId, queries: s.queries }));
    if (msg.type === 'CallReducer' || msg.type === 'CallProcedure')
      reducerCalls.push({ ts: f.ts, requestId: msg.requestId, name: msg.name, argsHex: hex(msg.args, 96), argsPreview: printable(msg.args), argsLen: msg.args.length });
    const tally = (tables) => {
      for (const t of tables || []) {
        const e = tableTotals[t.table] ?? (tableTotals[t.table] = { rows: 0, bytes: 0 });
        // snapshot-style rows (SubscribeApplied/OneOffQueryResult) vs update-style
        const n = t.inserts ?? t.deletes ?? t.events ?? t.rows?.rowCount ?? t.rowCount ?? 0;
        e.rows += Number.isFinite(n) ? n : 0;
        e.bytes += Number.isFinite(t.bytes) ? t.bytes : 0;
      }
    };
    if (msg.type === 'SubscribeApplied' || msg.type === 'OneOffQueryResult') tally(msg.tables);
    if (msg.type === 'SubscribeBatchApplied') msg.results.forEach((s) => tally(s.tables));
    for (const qs of msg.querySets || []) tally(qs.tables);
    if (msg.querySets2) tally(msg.querySets2);
  }
  decodedOut.end();

  const byType = {};
  for (const e of events) byType[`${e.dir}:${e.msg.type}`] = (byType[`${e.dir}:${e.msg.type}`] || 0) + 1;

  console.log(`\n================ ${conn} (db: ${db ?? '?'}) ================`);
  console.log(`frames: ${index.length}  compression: raw=${stats.raw} brotli=${stats.brotli} gzip=${stats.gzip}  decode-errors: ${stats.errors}`);
  console.log('message types:', JSON.stringify(byType));

  if (subscriptions.length) {
    console.log(`\n-- subscriptions (${subscriptions.length} sets) --`);
    for (const s of subscriptions) {
      console.log(`${s.ts.slice(11,23)} req=${s.requestId} qsid=${s.querySetId}:`);
      s.queries.forEach((q) => console.log(`    ${q}`));
    }
  }
  if (reducerCalls.length) {
    console.log(`\n-- ${reducerCalls.length} reducer/procedure calls in order --`);
    for (const c of reducerCalls)
      console.log(`${c.ts.slice(11,23)} req=${c.requestId} ${c.name}(${c.argsLen}B args) ${c.argsPreview.slice(0, 60)}`);
  }
  const tables = Object.entries(tableTotals).sort((a, b) => b[1].bytes - a[1].bytes);
  if (tables.length) {
    console.log(`\n-- tables touched (${tables.length}) --`);
    for (const [name, t] of tables)
      console.log(`${name}: rows=${t.rows} bytes=${t.bytes}`);
  }
  if (scanText) {
    console.log(`\n-- scan for '${scanText}': ${searchHits.length} hits --`);
    for (const h of searchHits.slice(0, 20)) console.log(`${h.ts.slice(11,23)} ${h.dir} ${h.type}`);
  }
}
