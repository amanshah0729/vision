# Glasses Sensor Protocol v1

A language-neutral wire contract between a **native sensor client** (iOS/Swift today,
Android/Kotlin later) and a **bridge** (`sensors.js`, mounted in Sightline's `server.js`),
so that a **web app** running on the glasses can use sensors its browser cannot reach.

This file is the durable asset. Swift and Kotlin share no code, so the reusable thing is
the protocol, not a library. Any client that speaks this and any backend that mounts
`sensors.js` interoperate for free.

## Why the phone pushes outbound

The glasses web app is served over HTTPS. If it fetched `http://<phone-lan-ip>` the browser
would block it as mixed content, and a phone on WiFi cannot get a valid TLS cert. So the
arrow is inverted: **the phone dials out to the bridge**, which already has a real cert and
a token. The glasses keep talking only to the bridge they already trust, and the whole thing
works over cellular rather than only on the home network.

```
 Glasses (HTTPS, polls)          Mac bridge                iPhone (outbound HTTPS)
 ┌──────────────┐   GET /api/  ┌────────────┐  POST /api/ ┌─────────────────┐
 │  Sightline   │◄────────────►│ server.js  │◄────────────│  SensorAgent    │
 │   web app    │  sensors/*   │ +sensors.js│  sensors/*  │  mic / camera   │
 └──────────────┘              └────────────┘  long-poll  └─────────────────┘
                                                 commands
```

## Auth

Every route lives under `/api/`, so it inherits the bridge's existing token gate. Supply the
token as `?k=<token>`, or `Authorization: Bearer <token>`. Clients should store it in the
platform keychain, never in plain preferences.

## Conventions

- All JSON bodies are `application/json; charset=utf-8`, except `POST /still` which is a raw
  `image/jpeg` byte body.
- Timestamps (`at`) are epoch milliseconds, integer.
- `deviceId` is a client-generated stable UUID string, one per install.
- Unknown JSON fields MUST be ignored, so v1 clients keep working against v2 bridges.

## Capabilities

A client advertises what it can actually do right now. The web app renders controls only for
capabilities that are present, so a phone-only build and a DAT build need no UI branching.

| Capability | Meaning |
|---|---|
| `mic` | can capture audio and produce transcripts |
| `camera` | can capture JPEG stills |
| `glasses-mic` | the audio source is the **glasses**, not the phone |
| `glasses-camera` | the image source is the **glasses**, not the phone |

`mic`/`camera` describe the *function*; the `glasses-` prefix describes the *origin*. A phone
development stand-in reports `["mic","camera"]`. A DAT build reports
`["mic","camera","glasses-mic","glasses-camera"]`. The web app should visibly mark a session
as a stand-in when the `glasses-` variants are missing, so a desk test is never mistaken for
the real thing.

## Phone → bridge

### `POST /api/sensors/register`
Announce presence and capabilities. Also serves as the heartbeat: re-post every 30s. A device
with no register for **90s** is dropped from `GET /api/sensors`.

```json
{ "deviceId": "8A1F…", "name": "My iPhone", "caps": ["mic", "camera"] }
```
→ `200 { "ok": true, "ttlMs": 90000 }`

### `POST /api/sensors/transcript`
Push dictation text. Send partials freely; send `final: true` when the recognizer settles.

```json
{ "deviceId": "8A1F…", "text": "open the ortho repo", "final": false }
```
→ `200 { "ok": true, "seq": 41 }`

`seq` is a monotonically increasing integer assigned by the bridge. Readers poll with
`?since=<seq>` and receive only newer segments, which makes the read side idempotent and
safe to retry.

### `POST /api/sensors/still?deviceId=…`
Raw JPEG bytes as the request body, `Content-Type: image/jpeg`. Max **3 MB**; larger is
rejected `413`. Only the most recent still is retained.

→ `200 { "ok": true, "bytes": 148213, "at": 1757389200000 }`

### `POST /api/sensors/frame?deviceId=<id>`
Body: `image/jpeg`, one live-stream frame, **≤ 1 MB** (the sender scales to `maxWidth` first).
The bridge keeps only the newest and answers `{ "ok": true, "bytes": n, "at": ms, "seq": n }`.
Send at most one at a time and skip frames while a post is in flight — a backlog of stale
frames is worse than a gap.

### `GET /api/sensors/commands?deviceId=…`
**Long poll**, held up to **25s**. Returns as soon as a command is queued for this device,
otherwise returns an empty list. Reconnect immediately on return. 25s sits under the common
30s proxy idle timeout, so the connection is closed by us rather than by infrastructure.

→ `200 { "commands": [ { "id": "c7", "action": "mic.start", "args": {} } ] }`

Commands are delivered **at most once** — they are removed from the queue when handed to a
poller. A dropped connection can therefore lose a command; actions are designed to be
idempotent and user-retriable rather than guaranteed.

| Action | Args | Effect |
|---|---|---|
| `mic.start` | `{}` | begin dictation, stream partials |
| `mic.stop` | `{}` | end dictation, emit a final |
| `camera.still` | `{}` | capture one JPEG and POST it |
| `camera.stream.start` | `{ fps?, maxWidth?, quality?, maxSeconds?, resolution? }` | post JPEG frames to `/api/sensors/frame` at ≤`fps` (default 3, max 10), scaled *down* to `maxWidth` px (default 480), JPEG `quality` (default 0.6), for at most `maxSeconds` (default 600). `resolution` picks the source off the glasses: `"low"`, `"medium"` (504×896, default) or `"high"` (720×1280). `maxWidth` above the source width does nothing — frames are never upscaled. Every start brings up a fresh camera stream (~3 s) so the decoder begins on a keyframe |
| `camera.stream.stop` | `{}` | stop posting frames |
| `display.show` | `{ title?, big?, lines? }` | draw on the glasses' display **from the phone**, in the camera's own session: `title` (small), `big` (headline), `lines` (array of strings). Replaces whatever was shown. This is the only way to show anything while the camera runs — a DAT camera session takes the display from the glasses browser, so a web page is black for the duration |
| `display.clear` | `{}` | blank the phone-drawn display |

## Glasses (web app) → bridge

### `GET /api/sensors`
Which clients are online and what they can do, plus a description of the latest still
(`null` if there is none).

```json
{ "devices": [ { "deviceId": "8A1F…", "name": "My iPhone",
                 "caps": ["mic","camera"], "at": 1757389200000, "ageMs": 1200 } ],
  "still": { "at": 1757389200000, "bytes": 148213, "deviceId": "8A1F…" },
  "frame": { "at": 1757389201500, "bytes": 38120, "deviceId": "8A1F…", "seq": 412 } }
```

`frame` describes the newest live-stream frame (`null` if none yet). `seq` increases by one
per frame received, so a consumer can tell how many it skipped; poll it and fetch
`frame.jpg` only when it changes.

The still's metadata rides along so a client can poll for *a new frame* by comparing `at`,
without pulling the image itself once a second. Requesting a capture and then waiting for
`still.at` to exceed the value seen beforehand is the intended way to await a shot — checking
merely that a still exists would match a frame from an hour ago.

### `GET /api/sensors/frame.jpg`
The newest live-stream frame as `image/jpeg`, with `X-Frame-Seq` and `X-Frame-At` headers.
404 until the first frame arrives. Only the latest is kept — there is no history and no
video; a CV loop polls this at its own pace.

### `GET /api/sensors/transcript?since=<seq>`
Newer transcript segments only.

```json
{ "seq": 42, "segments": [ { "seq": 42, "text": "open the ortho repo",
                             "final": true, "at": 1757389200000 } ] }
```

`seq` at the top level is the newest sequence the bridge holds; pass it back as `since` on
the next poll. The bridge retains the last 50 segments.

### `GET /api/sensors/still.jpg`
The most recent JPEG, or `404` if none. `Cache-Control: no-store`.

### `POST /api/sensors/command`
Queue a command for a device.

```json
{ "deviceId": "8A1F…", "action": "mic.start", "args": {} }
```
→ `200 { "ok": true, "id": "c7" }`

`deviceId` may be omitted when exactly one device is online, which is the common case.
The bridge will not guess between two, so a UI that may see a phone *and* a test client
should name the device it means rather than relying on the shortcut.

## Host-specific: consuming a still (Sightline)

Not part of this protocol — noted because it is the only reason the still exists. Sightline's
`POST /api/sessions/:id/send` accepts `withStill: true`, which attaches the current frame to
the outgoing turn as a base64 image block. The client never re-uploads the image: the bridge
already holds it, and pushing megabytes back out to the glasses only to receive them again
would be absurd. `409` if there is no still to attach.

## Errors

Uniform shape: `{ "error": "<human readable>" }` with a conventional status —
`400` malformed, `401` bad token, `404` unknown device or no still, `413` payload too large.

## Design notes

- **State is in memory only.** Sensor data is live, worthless a minute later, and often
  private. Restarting the bridge clears it; nothing lands on disk.
- **No websockets.** Long-polling costs one idle connection and traverses every proxy and
  cellular NAT without special handling. The glasses side already polls.
- **The bridge never talks to the phone first.** All phone-bound work is a queued command the
  phone collects, so the phone needs no reachable address, no port forwarding, and no cert.
