/* Sensor relay — see PROTOCOL.md
 *
 * The glasses browser exposes no camera and no microphone (proven on hardware:
 * enumerateDevices returns a lone audiooutput, getUserMedia throws NotFoundError).
 * Native code can reach those sensors, so a native app acts as the peripheral and
 * this module is the meeting point between it and the web app.
 *
 * Deliberately zero-dependency and free of any Sightline import, so it can be
 * dropped into another Node backend as-is. Everything is in memory: sensor data is
 * live, worthless a minute later, and often private — none of it should touch disk.
 */

const DEVICE_TTL_MS = 90_000;   // no heartbeat for this long and you are gone
const LONGPOLL_MS = 25_000;     // under the usual 30s proxy idle timeout
const MAX_STILL_BYTES = 3 * 1024 * 1024;
const MAX_FRAME_BYTES = 1024 * 1024;   // live frames are small on purpose (see PROTOCOL.md)
const KEEP_SEGMENTS = 50;

const devices = new Map();      // deviceId -> { deviceId, name, caps, at }
const queues = new Map();       // deviceId -> [command]
const waiters = new Map();      // deviceId -> [resolve]

let segments = [];              // transcript ring buffer
let seq = 0;
let still = null;               // { buf, at, deviceId }
let frame = null;               // { buf, at, deviceId, seq } — latest live-stream frame
let frameSeq = 0;
let cmdSeq = 0;

/* ---------- helpers ---------- */

function json(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
}

function readJson(req, limit = 256 * 1024) {
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

function readRaw(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let n = 0, over = false;
    req.on('data', (c) => {
      if (over) return;
      n += c.length;
      // Stop accumulating the moment the cap is passed rather than buffering the
      // whole body and checking afterwards — otherwise the limit protects nothing.
      // Reject instead of destroying: the caller still has to send a real 413, and
      // tearing the socket down here would hand the client a connection reset.
      if (n > limit) { over = true; chunks.length = 0; return reject(new Error('too large')); }
      chunks.push(c);
    });
    req.on('end', () => { if (!over) resolve(Buffer.concat(chunks)); });
    req.on('error', reject);
  });
}

function liveDevices() {
  const now = Date.now();
  for (const [id, d] of devices) if (now - d.at > DEVICE_TTL_MS) devices.delete(id);
  return [...devices.values()].map((d) => ({ ...d, ageMs: now - d.at }));
}

/* Resolve a target device. With one client online — the common case — the caller
   should not have to know its id, but guessing when several are connected would
   send dictation to whichever happened to register first. So: guess only when the
   choice is unambiguous. */
function resolveDevice(explicit) {
  const live = liveDevices();
  if (explicit) return live.some((d) => d.deviceId === explicit) ? explicit : null;
  return live.length === 1 ? live[0].deviceId : null;
}

function enqueue(deviceId, action, args) {
  const cmd = { id: 'c' + ++cmdSeq, action, args: args || {} };
  const w = waiters.get(deviceId);
  // A poller parked on the long-poll gets it directly; the queue is only for
  // commands that arrive while nobody is listening.
  if (w && w.length) {
    w.shift()([cmd]);
    return cmd;
  }
  if (!queues.has(deviceId)) queues.set(deviceId, []);
  queues.get(deviceId).push(cmd);
  return cmd;
}

function waitForCommands(deviceId, req) {
  const pending = queues.get(deviceId);
  if (pending && pending.length) {
    queues.set(deviceId, []);
    return Promise.resolve(pending);
  }
  return new Promise((resolve) => {
    if (!waiters.has(deviceId)) waiters.set(deviceId, []);
    const list = waiters.get(deviceId);
    // One device, one poller. A waiter already parked here belongs to a previous instance of
    // the client (app relaunched, connection not yet noticed dead) — and `enqueue` would hand
    // the next command to it, where it vanishes. Seen on hardware: a command sent 6 s after a
    // relaunch was never received. Release the stale waiter(s) empty before parking this one.
    for (const stale of [...list]) stale([]);
    let done = false;
    const finish = (v) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      const i = list.indexOf(finish);
      if (i >= 0) list.splice(i, 1);
      resolve(v);
    };
    const timer = setTimeout(() => finish([]), LONGPOLL_MS);
    // A phone that walks out of coverage leaves a resolver and a timer behind.
    // Without this the maps grow for the life of the process.
    req.on('close', () => finish([]));
    list.push(finish);
  });
}

/* ---------- router ---------- */

/** Returns true if the request was handled. Mount before static file serving. */
export async function handleSensors(req, res, url) {
  const p = url.pathname;
  if (!p.startsWith('/api/sensors')) return false;
  const m = req.method;

  if (p === '/api/sensors' && m === 'GET') {
    // The still's timestamp rides along so a poller can tell a newly captured
    // frame from the one already on screen. Fetching still.jpg to find that out
    // would mean pulling megabytes once a second.
    json(res, 200, {
      devices: liveDevices(),
      still: still ? { at: still.at, bytes: still.buf.length, deviceId: still.deviceId } : null,
      frame: frame ? { at: frame.at, bytes: frame.buf.length, deviceId: frame.deviceId, seq: frame.seq } : null,
    });
    return true;
  }

  if (p === '/api/sensors/register' && m === 'POST') {
    const b = await readJson(req);
    if (!b.deviceId || typeof b.deviceId !== 'string') {
      json(res, 400, { error: 'deviceId required' });
      return true;
    }
    devices.set(b.deviceId, {
      deviceId: b.deviceId,
      name: typeof b.name === 'string' ? b.name.slice(0, 60) : 'device',
      caps: Array.isArray(b.caps) ? b.caps.filter((c) => typeof c === 'string').slice(0, 8) : [],
      at: Date.now(),
    });
    json(res, 200, { ok: true, ttlMs: DEVICE_TTL_MS });
    return true;
  }

  if (p === '/api/sensors/transcript' && m === 'POST') {
    const b = await readJson(req);
    if (typeof b.text !== 'string') {
      json(res, 400, { error: 'text required' });
      return true;
    }
    const seg = { seq: ++seq, text: b.text.slice(0, 4000), final: !!b.final, at: Date.now() };
    segments.push(seg);
    if (segments.length > KEEP_SEGMENTS) segments = segments.slice(-KEEP_SEGMENTS);
    if (b.deviceId && devices.has(b.deviceId)) devices.get(b.deviceId).at = Date.now();
    json(res, 200, { ok: true, seq: seg.seq });
    return true;
  }

  if (p === '/api/sensors/transcript' && m === 'GET') {
    const since = Number(url.searchParams.get('since')) || 0;
    json(res, 200, { seq, segments: segments.filter((s) => s.seq > since) });
    return true;
  }

  if (p === '/api/sensors/still' && m === 'POST') {
    // Refuse on the declared length before a single byte of body arrives. Large
    // uploads from curl and URLSession both wait on a 100-continue, so answering
    // here avoids pushing megabytes over cellular only to reject them.
    if (Number(req.headers['content-length'] || 0) > MAX_STILL_BYTES) {
      json(res, 413, { error: 'still too large' });
      req.destroy();
      return true;
    }
    let buf;
    try {
      buf = await readRaw(req, MAX_STILL_BYTES);
    } catch {
      // Chunked upload with no declared length: the cap tripped mid-stream. Answer
      // first, then drop the socket, so the client gets a 413 it can act on rather
      // than a bare reset it can only guess at.
      if (!res.writableEnded) json(res, 413, { error: 'still too large' });
      req.destroy();
      return true;
    }
    if (!buf.length) {
      json(res, 400, { error: 'empty body' });
      return true;
    }
    const deviceId = url.searchParams.get('deviceId') || null;
    still = { buf, at: Date.now(), deviceId };
    if (deviceId && devices.has(deviceId)) devices.get(deviceId).at = Date.now();
    json(res, 200, { ok: true, bytes: buf.length, at: still.at });
    return true;
  }

  if (p === '/api/sensors/still.jpg' && m === 'GET') {
    if (!still) {
      json(res, 404, { error: 'no still yet' });
      return true;
    }
    res.writeHead(200, {
      'Content-Type': 'image/jpeg',
      'Content-Length': still.buf.length,
      'Cache-Control': 'no-store',
    });
    res.end(still.buf);
    return true;
  }

  // Live stream: the phone POSTs small JPEGs at a few fps while `camera.stream.start` is
  // active; only the newest is kept. Consumers (a CV loop, the glasses page) poll `frame.seq`
  // in GET /api/sensors and fetch frame.jpg when it changes. No history, by design.
  if (p === '/api/sensors/frame' && m === 'POST') {
    if (Number(req.headers['content-length'] || 0) > MAX_FRAME_BYTES) {
      json(res, 413, { error: 'frame too large' });
      req.destroy();
      return true;
    }
    let buf;
    try { buf = await readRaw(req, MAX_FRAME_BYTES); } catch {
      if (!res.writableEnded) json(res, 413, { error: 'frame too large' });
      req.destroy();
      return true;
    }
    if (!buf.length) { json(res, 400, { error: 'empty body' }); return true; }
    const deviceId = url.searchParams.get('deviceId') || null;
    frame = { buf, at: Date.now(), deviceId, seq: ++frameSeq };
    if (deviceId && devices.has(deviceId)) devices.get(deviceId).at = Date.now();
    json(res, 200, { ok: true, bytes: buf.length, at: frame.at, seq: frame.seq });
    return true;
  }

  if (p === '/api/sensors/frame.jpg' && m === 'GET') {
    if (!frame) { json(res, 404, { error: 'no frame yet' }); return true; }
    res.writeHead(200, {
      'Content-Type': 'image/jpeg',
      'Content-Length': frame.buf.length,
      'Cache-Control': 'no-store',
      'X-Frame-Seq': String(frame.seq),
      'X-Frame-At': String(frame.at),
    });
    res.end(frame.buf);
    return true;
  }

  if (p === '/api/sensors/commands' && m === 'GET') {
    const deviceId = url.searchParams.get('deviceId');
    if (!deviceId) {
      json(res, 400, { error: 'deviceId required' });
      return true;
    }
    // Polling is itself proof of life, so a dictating phone need not also heartbeat.
    if (devices.has(deviceId)) devices.get(deviceId).at = Date.now();
    const commands = await waitForCommands(deviceId, req);
    if (!res.writableEnded) json(res, 200, { commands });
    return true;
  }

  if (p === '/api/sensors/command' && m === 'POST') {
    const b = await readJson(req);
    const ACTIONS = ['mic.start', 'mic.stop', 'camera.still', 'camera.stream.start', 'camera.stream.stop'];
    if (!ACTIONS.includes(b.action)) {
      json(res, 400, { error: 'unknown action' });
      return true;
    }
    const deviceId = resolveDevice(b.deviceId);
    if (!deviceId) {
      json(res, 404, { error: 'no matching device online' });
      return true;
    }
    const cmd = enqueue(deviceId, b.action, b.args);
    json(res, 200, { ok: true, id: cmd.id, deviceId });
    return true;
  }

  json(res, 404, { error: 'unknown sensor route' });
  return true;
}

/** The latest frame, for a host that wants to attach it to something. Returns the
 *  live buffer rather than a copy — callers must not mutate it. */
export function latestStill() {
  return still;
}

/** The latest live-stream frame (see POST /api/sensors/frame), or null. */
export function latestFrame() {
  return frame;
}

/** Test seam: drop all state. */
export function resetSensors() {
  devices.clear(); queues.clear(); waiters.clear();
  segments = []; seq = 0; still = null; cmdSeq = 0;
}
