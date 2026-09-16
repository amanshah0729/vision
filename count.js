/* Card-count relay — the meeting point between the counting worker and the glasses.
 *
 * The worker (count/worker.py, on the same Mac) does the vision and the arithmetic. The
 * glasses page (public/count.html) only ever talks to this bridge, because the glasses
 * browser will not fetch anything that is not the HTTPS host it already trusts. So the
 * worker pushes its state here a few times a second and the glasses poll it back, and
 * control goes the other way through the same two calls: the glasses set "reset" or a
 * deck count, the worker reads it on its next push. No sockets, in memory only, same
 * shape as sensors.js — a restart forgets the count, which is correct: a count from
 * before a restart belongs to a shoe nobody was watching.
 *
 *   worker → bridge   POST /api/count/state      {running, trueCount, seen, …}
 *   worker ← bridge   GET  /api/count/control    {decks, resetEpoch}
 *   glasses ← bridge  GET  /api/count            {state, worker:{alive,ageMs}, control}
 *   glasses → bridge  POST /api/count/reset      bumps resetEpoch (shuffle)
 *   glasses → bridge  POST /api/count/decks      {decks}
 */

const WORKER_TTL_MS = 5_000;   // no state push for this long and the glasses say "worker down"

let state = null;              // last snapshot from the worker
let stateAt = 0;
let control = { decks: 6, resetEpoch: 0 };

function json(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
}

function readJson(req, limit = 64 * 1024) {
  return new Promise((resolve) => {
    let d = '', over = false;
    req.on('data', (c) => {
      if (over) return;
      d += c;
      if (d.length > limit) { over = true; d = ''; }
    });
    req.on('end', () => { try { resolve(JSON.parse(d || '{}')); } catch { resolve({}); } });
  });
}

/** Returns true if the request was handled. Mount alongside handleSensors. */
export async function handleCount(req, res, url) {
  const p = url.pathname;
  if (!p.startsWith('/api/count')) return false;
  const m = req.method;

  if (p === '/api/count' && m === 'GET') {
    const ageMs = stateAt ? Date.now() - stateAt : null;
    json(res, 200, {
      state,
      worker: { alive: ageMs !== null && ageMs < WORKER_TTL_MS, ageMs },
      control,
    });
    return true;
  }

  if (p === '/api/count/state' && m === 'POST') {
    const b = await readJson(req);
    if (typeof b.running !== 'number') { json(res, 400, { error: 'running required' }); return true; }
    state = b;
    stateAt = Date.now();
    json(res, 200, { ok: true, control });
    return true;
  }

  if (p === '/api/count/control' && m === 'GET') {
    json(res, 200, control);
    return true;
  }

  if (p === '/api/count/reset' && m === 'POST') {
    control = { ...control, resetEpoch: control.resetEpoch + 1 };
    json(res, 200, { ok: true, control });
    return true;
  }

  if (p === '/api/count/decks' && m === 'POST') {
    const b = await readJson(req);
    const d = Number(b.decks);
    if (!Number.isFinite(d) || d < 1 || d > 8) { json(res, 400, { error: 'decks must be 1..8' }); return true; }
    control = { ...control, decks: d };
    json(res, 200, { ok: true, control });
    return true;
  }

  json(res, 404, { error: 'unknown count route' });
  return true;
}
