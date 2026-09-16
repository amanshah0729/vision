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

## Next project: card counting (all bridge-side)

Architecture agreed with Aman, no iOS changes:

1. `camera.stream.start {fps: 4, maxWidth: 640}` from a small glasses page.
2. A worker on the Air polls `frame.seq` and runs a playing-card detector (YOLO-class, public
   card datasets exist) on each new frame. Not OCR.
3. Count each card **once**: track by position across frames, count on first stable
   appearance, ignore while it persists. Keep running count, cards seen, decks remaining;
   true count = running / decks left. Expose `GET /count` JSON.
4. Glasses page polls `/count` twice a second and shows running + true count in big type;
   pinch = reset at shuffle. 600×600, D-pad only, black is transparent — see `../CLAUDE.md`.

Expect the detector to be the real work; collect frames from the glasses at an actual table
to tune. Aman knows the legal caveat (device-assisted counting in a casino is a crime in
Nevada and most jurisdictions); this is a home/build project.

## Quirks worth knowing before you burn an hour

- `device.sh bridge <url> <token>` launch args did not override the saved bridge in one
  test; the saved bridge is the public one, so it does not matter for the Air.
- The stream's `maxSeconds` defaults to 600; the glasses' battery lasts a few streaming runs.
- First minute after a Meta AI (re)approval: the glasses may end sessions on their own.
