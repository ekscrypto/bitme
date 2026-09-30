import WebSocket from 'ws';

const url = 'wss://relay.bitcraftsync.app:3000/v1/database/bitcraft-live-14/subscribe';
const ws = new WebSocket(url, ['v1.json.spacetimedb']);
const queries = [
  'SELECT * FROM prospecting_state',
  'SELECT * FROM prospecting_desc',
  'SELECT * FROM prospect_start_event',
  'SELECT * FROM crumb_trail_exposed_state',
  'SELECT * FROM prospecting_participants',
];
const collected = {};   // queryId -> rows
const deltas = [];
let open = false;

const timer = setTimeout(() => { console.log('=== WINDOW END ==='); dump(); ws.close(); process.exit(0); }, 90000);

function dump() {
  for (const [qid, rows] of Object.entries(collected)) {
    console.log(`\n=== snapshot query ${qid}: ${rows.length} rows ===`);
    for (const r of rows.slice(0, 80)) console.log(typeof r === 'string' ? r : JSON.stringify(r));
  }
  console.log(`\n=== deltas: ${deltas.length} ===`);
  for (const d of deltas.slice(0, 40)) console.log(JSON.stringify(d).slice(0, 1200));
}

ws.on('open', () => { open = true; console.log('OPEN', new Date().toISOString()); });
ws.on('error', (e) => { console.log('ERROR', e.message); });
ws.on('close', (c, r) => { console.log('CLOSE', c, r.toString()); clearTimeout(timer); });
ws.on('message', (raw, isBin) => {
  const text = isBin.toString('utf8');
  let msg;
  try { msg = JSON.parse(text); } catch { console.log('NON-JSON', text.slice(0, 200)); return; }
  if (!globalThis.msgCount) globalThis.msgCount = 0;
  if (globalThis.msgCount < 5) { console.log('RAW MSG', Object.keys(msg).join(','), text.slice(0, 300)); }
  globalThis.msgCount++;
  if (msg.IdentityToken) { 
    console.log('IDENTITY ok; subscribing…');
    queries.forEach((q, i) => {
      ws.send(JSON.stringify({ SubscribeSingle: { query: q, request_id: i + 1, query_id: { id: i + 1 } } }));
    });
    return;
  }
  if (msg.SubscriptionError) { console.log('SUB ERR', JSON.stringify(msg).slice(0, 400)); return; }
  if (msg.SubscribeApplied) {
    const a = msg.SubscribeApplied;
    const qid = a.query_id?.id ?? 0;
    const updates = a.rows?.table_rows?.updates ?? [];
    const rows = [];
    for (const u of updates) {
      const un = u.Uncompressed ?? u;
      for (const ins of un.inserts ?? []) rows.push(ins);
    }
    collected[qid] = rows;
    console.log(`APPLIED q${qid} table=${a.table_name ?? '?'} rows=${rows.length} @${new Date().toISOString()}`);
    return;
  }
  if (msg.TransactionUpdate || msg.TransactionUpdateLight) {
    const s = JSON.stringify(msg);
    if (/prospect|crumb/i.test(s)) deltas.push({ ts: new Date().toISOString(), msg });
  }
});
