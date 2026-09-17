# Handoff — take over from the always-on Mac (written 2026-09-16 from the MacBook Pro)

Read `CLAUDE.md` and `README.md` first; they hold every verified fact and number. This file is
only "where things stand and what to do next" for the agent that continues on the Air.

## Where things stand

Everything below is on `main`, pushed, and the matching build is installed on the phone.

- **Camera → web app loop works on hardware**, locked phone included: pinch on `look.html`
  → still on the glasses in ~5 s. Verified repeatedly.
- **Live frame stream works**: `camera.stream.start` → `/api/sensors/frame.jpg` at ~3.5 fps,
  480×854, ~44 KB. Verified foreground (60 s) and locked (75 s).
- **Not yet verified**: the two decoder-recovery fixes in `FrameStreamer` (rebuild on
  `kVTInvalidSessionErr`; restart the camera on a 5 s decode stall). They are in the build on
  the phone. First thing to do: a 3-minute locked stream with one unlock/lock in the middle,
  and read `STREAM:` lines in `poc.log`.
- **iOS side is done for now.** No further Swift work is needed to build things on top; if
  the decoder fixes turn out not to hold, that is the one remaining iOS task.

## The Air cannot build iOS. It can do everything else

- Bridge: `server.js` runs here as LaunchAgent `com.vision.bridge`, port 8791, public via the
  shared tunnel. After `git pull`: `launchctl kickstart -k gui/$(id -u)/com.vision.bridge`.
  Static files (`public/`) are served fresh without a restart.
- Token: `cat .token` in this repo on the Air. Never commit it. Eight bad tokens from one IP
  = ten-minute lockout for that IP (the whole house if the phone is on home Wi-Fi) — never
  loop a request with an empty token.
- Drive the phone: it auto-connects to the saved bridge on launch. If it drops off
  `GET /api/sensors`, the app was killed; someone taps the icon. Commands: see `PROTOCOL.md`.
- Phone logs: only from the Pro (`ios/SensorAgent/device.sh log`). From the Air, rely on the
  bridge's view (`/api/sensors`, `frame.seq`, `still.at`).

## Card counting lives in its own repo — do not build it here

The counter exists: **amanshah0729/cardcount**, cloned beside this repo as
`../cardcount`, running on the Air as LaunchAgent `com.cardcount` (port 8792,
`count.orthosoftwaresucks.com`). It is a *client* of this bridge — it uses only
`PROTOCOL.md` (`GET /api/sensors`, `frame.jpg`, `POST /api/sensors/command`) and
nothing in vision was changed for it. Keep it that way: vision is the open-source
sensor bridge and stays generic. If the counter needs something the bridge does not
expose, add it here as a generic feature, not as a counting feature.

## Streaming: what to ask for (verified 2026-09-17)

`camera.stream.start` with `{"fps": 8, "resolution": "high", "maxWidth": 720}` gives 720×1280
frames at ~5.5 fps on the bridge, ~89 KB each. `maxWidth` above the source width does
nothing (medium is 504 wide — 640/960 were upscales of nothing). Each start takes ~3 s to
bring up a fresh camera stream. The source sends a keyframe every 3 s, so after a damaged
frame expect a gap of up to 3 s in `frame.seq`, not a dead stream; a gap over ~15 s means the
glasses ended the session and the phone is restarting it. The stalls seen on 2026-09-16
(2 runs of 5) were the old build. **Pull and restart the bridge** to pick up the stale-poller
fix in `sensors.js`, or a command sent right after the app relaunches can be lost.

## Quirks worth knowing before you burn an hour

- **Free-team provisioning profiles expire after 7 days.** The app then refuses to launch
  ("crashes" on open). Fix is on the Pro: `PROVISION=1 ./device.sh build && ./device.sh install`,
  then one Meta AI approval with the glasses on. Same symptom if a certificate gets re-minted
  without reinstalling.

- `device.sh bridge <url> <token>` launch args did not override the saved bridge in one
  test; the saved bridge is the public one, so it does not matter for the Air.
- The stream's `maxSeconds` defaults to 600; the glasses' battery lasts a few streaming runs.
- First minute after a Meta AI (re)approval: the glasses may end sessions on their own.
