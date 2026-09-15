/* Vision bridge — the host process for sensors.js.
 *
 * sensors.js used to be mounted inside Sightline's server.js and borrowed its HTTP
 * server, token gate and lockout. Splitting the repos left the handler with no host,
 * so nothing here ran. This is that host: static files from public/, everything under
 * /api/ behind the same bearer/?k= token scheme the glasses already use, and the
 * sensor routes mounted on top. Zero dependencies, like sensors.js itself.
 *
 *   GLASSES_TOKEN=… PORT=8791 node server.js
 *
 * Deliberately NOT a fork of Sightline: no Claude, no sessions, no repos. The only
 * thing the two share is the shape of the auth, so a token saved on the glasses
 * behaves identically on both hostnames.
 */
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { handleSensors } from './sensors.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT) || 8791;
const TOKEN = process.env.GLASSES_TOKEN || crypto.randomBytes(9).toString('base64url');
const PUBLIC = path.join(__dirname, 'public');

/* ---------- auth (same rules as sightline/server.js) ---------- */
function sameSecret(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}
function cookieToken(req) {
  const m = /(?:^|;\s*)vs=([^;]+)/.exec(req.headers.cookie || '');
  return m ? m[1] : '';
}
// Eight bad tokens from one address and it is locked out for ten minutes. The
// hostname sits on the open internet behind the tunnel, so a guessing loop must
// get expensive fast; a phone with a mistyped token trips this too, which is the
// intended reminder to fix the token rather than retry.
const failures = new Map();
const LOCK_AFTER = 8, LOCK_MS = 10 * 60 * 1000;
function noteFailure(ip) {
  const f = failures.get(ip) || { n: 0, at: 0 };
  f.n++; f.at = Date.now();
  failures.set(ip, f);
  return f.n;
}
function isLockedOut(ip) {
  const f = failures.get(ip);
  if (!f) return false;
  if (Date.now() - f.at > LOCK_MS) { failures.delete(ip); return false; }
  return f.n >= LOCK_AFTER;
}

/* ---------- http ---------- */
const MIME = { '.html': 'text/html', '.css': 'text/css', '.js': 'application/javascript', '.png': 'image/png', '.json': 'application/json' };
function json(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
}
function clientIp(req) {
  // cloudflared forwards the real address; locally there is no header.
  return (req.headers['cf-connecting-ip'] || req.socket.remoteAddress || '?').toString();
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://' + (req.headers.host || 'localhost'));
  const p = url.pathname;
  const ip = clientIp(req);

  if (p === '/healthz') return json(res, 200, { ok: true, up: process.uptime() | 0 });

  if (p.startsWith('/api/')) {
    if (isLockedOut(ip)) return json(res, 429, { error: 'locked out' });
    const key = url.searchParams.get('k') ||
      (req.headers.authorization || '').replace('Bearer ', '') ||
      cookieToken(req);
    if (!sameSecret(key, TOKEN)) {
      const n = noteFailure(ip);
      console.warn('[auth] rejected from ' + ip + ' (' + n + ' failed)');
      return json(res, 401, { error: 'bad token' });
    }
    failures.delete(ip);
    try {
      if (await handleSensors(req, res, url)) return;
    } catch (e) {
      console.error('[sensors] ' + (e && e.stack || e));
      if (!res.writableEnded) return json(res, 500, { error: 'sensor route failed' });
      return;
    }
    return json(res, 404, { error: 'unknown route' });
  }

  // First load with ?k= sets an HttpOnly cookie so the token stops living in the
  // URL bar of the glasses browser. Every later /api call can ride the cookie.
  const headers = {};
  if (sameSecret(url.searchParams.get('k'), TOKEN)) {
    headers['Set-Cookie'] = 'vs=' + TOKEN + '; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=31536000';
  }

  // Static. `/` is look.html: on the glasses the app is "the camera view", full stop.
  let file = p === '/' ? '/look.html' : p;
  file = path.normalize(file).replace(/^(\.\.[/\\])+/, '');
  const abs = path.join(PUBLIC, file);
  if (!abs.startsWith(PUBLIC) || !fs.existsSync(abs) || !fs.statSync(abs).isFile()) {
    return json(res, 404, { error: 'not found' });
  }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(abs)] || 'application/octet-stream', 'Cache-Control': 'no-store', ...headers });
  fs.createReadStream(abs).pipe(res);
});

server.listen(PORT, () => {
  console.log('vision bridge');
  console.log('  local:  http://localhost:' + PORT + '/?k=' + TOKEN);
  console.log('  token:  ' + TOKEN + '\n');
});
