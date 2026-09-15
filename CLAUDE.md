# Vision — sensors for the glasses

Read `../CLAUDE.md` first for the hardware facts if this is checked out inside the
`glasses` parent repo; standalone, the one fact that matters is below. The one that matters most here:

> **The glasses browser has no camera and no mic.** Probed on real hardware.
> `enumerateDevices` returns `1x audiooutput`, `getUserMedia` throws `NotFoundError`.

That is the whole reason this project exists. A web app on the glasses cannot see or
hear. So a native client on the **phone** captures instead and dials *out* to a bridge —
outbound, because a browser on the glasses will not accept a TLS-less LAN address, and
mixed content is blocked.

| Piece | What it is |
|---|---|
| `PROTOCOL.md` | **The durable asset.** Wire contract between a native sensor client and a bridge. |
| `server.js` | **The host.** Token gate + lockout + static `public/` + mounts `sensors.js`. `./start.sh`, port 8791. |
| `sensors.js` | Bridge-side handler implementing `PROTOCOL.md`. Zero-dep; `server.js` mounts it. |
| `ios/` | Native sensor client (Swift). Speaks `PROTOCOL.md`. See `ios/README.md`. |
| `tools/swift-sensor/` | The real `BridgeClient` with capture faked — compiles and runs on macOS. |
| `tools/fake-sensor.sh` | Impersonates the native client so the pipeline can be tested with no app. |
| `public/look.html` | Standalone camera-stills web app. |
| `public/probe.html` | Capability probe for the glasses browser. How the camera verdict was reached. |
| `tools/capture/` | Mac/iPhone webcam stand-in. **Not the glasses.** See the warning below. |

## The goal is the GLASSES camera. Read this before building anything.

The point of this repo is that an agent sees **what the wearer sees through the glasses**. A
desk webcam is not that. `PROTOCOL.md` encodes the distinction deliberately: `camera` is
the function, `glasses-camera` is the origin, and a stand-in must be visibly marked
"so a desk test is never mistaken for the real thing."

**`tools/capture` is a stand-in.** It grabs a frame from the MacBook camera or the iPhone
via Continuity. It is genuinely useful for pointing an agent at a screen or a desk, and it
needs no Xcode — but it does **not** advance glasses vision. Do not present it as if it
does. (An earlier agent did exactly that, which is why this warning exists.)

## The real path: Meta Wearables Device Access Toolkit

Meta's DAT is in public developer preview and **Ray-Ban Display is supported for camera
and photo capture**. This supersedes the old "the glasses camera is impossible" verdict,
which was true only of the *browser*, and only before DAT shipped.

`ios/SensorAgent` now links `MWDATCore`, `MWDATCamera` and `MWDATMockDevice` (pinned to
0.9.0) and `Sources/GlassesCamera.swift` reads the glasses camera. The old AVFoundation
`StillCapture.swift` — the phone's camera, the wrong thing — is deleted.

Worth knowing before touching that file:

- **DAT has no one-shot photo call.** A photo can only be taken while a video stream is
  live, so every capture is `session → camera → stream → wait for .streaming →
  capturePhoto → wait for the photo publisher`. That is seconds of Bluetooth setup, which
  is why the session is held open between shots.
- **Ask for less bandwidth, get a better picture.** DAT degrades quality to fit Bluetooth
  Classic. Requesting `.medium`/15fps yields a cleaner still than requesting `.high` and
  being throttled into it.
- **Two links carry camera frames, and the Info.plist decides which exist.** Since 0.8.0
  DAT streams over either Bluetooth Classic (ExternalAccessory, ~8 fps) or the glasses'
  SoftAP Wi-Fi (~24 fps). Wi-Fi needs the `wifi-info` + `HotspotConfiguration` entitlements,
  which a **free Apple personal team cannot provision** — so on a free team Bluetooth is the
  only link. Bluetooth in turn needs `UISupportedExternalAccessoryProtocols:
  [com.meta.ar.wearable]` and `external-accessory` in `UIBackgroundModes`. With neither set
  present, MWDATCore logs "Neither .medium nor .low link levels are available", the stream
  sits in `waitingForDevice` and dies `deviceNotConnected` after exactly 30s. That is what
  happened on hardware on 2026-09-11; the EA keys were missing. Found by `strings` on the
  0.9.0 binaries (`"UISupportedExternalAccessoryProtocols must contain 'com.meta.ar.wearable'"`,
  `"requires medium (BTC) or high (WiFi) bandwidth link"`), confirmed by Meta's own
  integration config. Read `project.yml` before touching either block.
- **Registration can silently drop.** On 2026-09-14 the app came up `.available` (not
  registered) after being rebuilt with a changed Info.plist, though it had been `.registered`
  on 09-11. Cause unconfirmed — reinstall, plist change, or Meta-side expiry. When it happens
  `ensureAccess()` re-opens Meta AI and a human must tap approve again; a later reinstall the
  same day did *not* drop it. Log `registrationState` before assuming anything.
- **Subscribe to session and stream state *before* calling `start()`.** DAT does not replay
  the current state to a late listener, so watching `stateStream()` after `start()` silently
  misses `.started`/`.streaming` and hangs. `GlassesCamera` and Meta's own sample both attach
  the listener first.
- **Warm the `AutoDeviceSelector` before `createSession`.** A freshly-made selector reports no
  active device for a beat; a session created in that beat throws `noEligibleDevice`.
- `Foundation.Stream` collides with `MWDATCamera.Stream`. Qualify it.
- `MWDAT.MetaAppID = "0"` is the documented Developer Mode value; it only needs a real
  application id for builds that leave this machine.

## `configure()` at launch, and the keychain — both non-obvious, both found by running

- **`Wearables.configure()` must run once at app launch** (`SensorAgentApp.init`, via
  `DAT.configureOnce`). `Wearables.shared` traps until it has. Calling it later — lazily on
  first capture, or from a test method — throws `internalError` and leaves `shared` trapping.
  Meta's sample configures in its `@main` init for exactly this reason.
- **DAT's `configure()` touches the keychain**, so the app must be **signed** with a
  `keychain-access-groups` entitlement (`SensorAgent.entitlements`, generated from
  `project.yml`). Ad-hoc (`-`) signing is enough on the simulator. Building with
  `CODE_SIGNING_ALLOWED=NO` compiles fine but the unsigned app has no keychain access, so
  `configure()` fails `internalError` at runtime and no capture works. **Build ≠ run here.**

`PROTOCOL.md` needed no change — it had `glasses-camera` designed in from the start.

## State of this repo — read before promising anything

Split out of `sightline` on 2026-09-09. Honestly incomplete, in priority order:

- **Real glasses have streamed — 2026-09-14, Ray-Ban Display, DAT 0.9.0, free Apple team,
  Bluetooth Classic link.** Driven unattended from the Mac (`-autoStartCameraPoC`, log pulled
  with `devicectl`). Numbers from `poc.log`: link `connected` 1s after unfolding; session
  `.started` <1s; stream `.streaming` 2s later; first frame 2s after that; `.medium`/30fps
  requested → 30 fps bursts, dipping to 6–19 fps (Bluetooth), ~880 frames in 35s; one
  `capturePhoto` → 190–265 KB 1080×1440 JPEG in 0.7–1.8s. Later runs the same night held
  29–32 fps for 30s straight. `VideoFrame.makeUIImage()` returns nil for `.hvc1` frames on
  hardware (compressed HEVC), so the live view feeds the sample buffers to an
  `AVSampleBufferDisplayLayer` — **and must flush it after every photo**, or the picture
  freezes on the frame before the capture while frames keep arriving (run 7 vs run 8, both
  confirmed by eye on the phone). Live view verified working, including across a capture.
  The bridge path (`GlassesCamera.capture` → `camera.still`) shares the same session/stream
  code but has not itself been run against hardware yet.
- **`MockDeviceKit` is wired and covered.** `GlassesMock` stands a fake Ray-Ban up (pair →
  powerOn → unfold → don → video feed + captured still), and `GlassesMockCaptureTests` drives
  the real `GlassesCamera` path against it — session → stream → `capturePhoto` — and asserts a
  JPEG comes back. It passes on the simulator. Toggle it in the app under **Debug → Mock
  glasses**; a mock session reports as a stand-in (plain `["mic","camera"]`) and every frame is
  stamped "MOCK GLASSES".
- **Access needs a human, not an agent.** A Meta developer account, accepted Developer Terms,
  Developer Mode on in the Meta AI app, then two in-app approvals on their phone. No part of
  that is scriptable. Do not claim to have access. This is the only thing between the mock and
  a real capture.
- **The host exists (`server.js`) and is verified with the fakes, not yet with the phone.**
  Same token scheme as Sightline (bearer / `?k=` / cookie, eight failures = ten-minute
  lockout), port 8791. Verified 2026-09-14 locally with `tools/fake-sensor.sh` and
  `tools/swift-sensor` (register → `camera.still` → still lands → `mic.start` →
  transcripts land). **And with the real phone on 2026-09-15:** `device.sh bridge <url>
  <token>` → phone registers with `glasses-camera` → `POST camera.still` → still on the
  bridge in 3.7 s warm (capture 1.3 s + upload 1.6 s over cellular), ~34 s cold. The
  glasses browser side (`look.html`) was stood in for by curl; still to be tapped for real.
  **Backgrounding solved 2026-09-15** with `Keepalive` (silent looping `.playback` session):
  8 min behind Settings still polling, capture in 5 s; pinches from the glasses with the
  phone locked and away worked. `look.html` verified on the glasses browser. **Remaining
  gap:** iOS can still terminate the app (it did, after ~4 h and several audio
  interruptions), and a locked phone cannot be relaunched from the Mac. The app now
  auto-connects on any launch when a bridge is saved, so recovery is one tap on the icon.

- **Live frame stream (2026-09-15).** `camera.stream.start {fps,maxWidth,quality,maxSeconds}`
  → `FrameStreamer` decodes the glasses' HEVC in hardware (VideoToolbox), scales, JPEGs and
  posts one frame at a time to `POST /api/sensors/frame`; the bridge keeps only the newest
  (`GET /api/sensors/frame.jpg`, `frame.seq` in `GET /api/sensors`). Designed for a CV loop
  on the bridge, not for video: a few fps, newest-wins, no history. `GlassesCamera` now
  streams `.hvc1` so stills and frames share one session. Auto-stops after `maxSeconds`
  (default 600) — streaming keeps the glasses' camera on and their battery dies in a few
  runs. The mock tests pass with `.hvc1`; see README "Status" for what was measured live.
- **There is a mic PoC** (`MicPoC` + `MicPoCView`). The glasses' mic is plain Bluetooth
  HFP, not DAT, so `Dictation.preferBluetoothHFP` routes speech capture to it via
  `AVAudioSession`. Needs no entitlements and no paid account. Unverified on hardware.
- **Hardware runs can be driven from the Mac.** Launch with
  `ios/SensorAgent/device.sh run` (wraps `xcrun devicectl device process launch … --
  -autoStartCameraPoC`; the `--` matters; the phone must be unlocked) and pull
  `Documents/poc.log` with `device.sh log` (wraps `devicectl device copy from`). `print`/`NSLog` never reach the CLI; the file log is
  the only way to read what DAT reported. `PoCLog` writes it; `CameraPoC` adds fps stats
  every 5s and fires one capture at 10s so an unattended run leaves numbers behind.
- **There is a live-camera PoC** (`CameraPoC` + `CameraPoCView`, reachable from the main
  screen). It opens the DAT video stream and shows fps, a photo capture round-trip time, and
  resolution/frame-rate knobs — a standalone harness for measuring how bad the real link is,
  no bridge. **The numbers only exist on hardware.** Against the mock the pipeline reaches
  `.streaming` but `MockDeviceKit` 0.9.0 emits no synthetic video frames off `setCameraFeed`
  (confirmed: valid feed, `.streaming`, zero frames), so `videoFramePublisher` — hence the live
  view, fps and latency — is exercised only on real glasses. `.hvc1` is the streaming codec
  (`.raw` serves photos but no video frames).

What *is* verified: the protocol layer end to end, via `tools/swift-sensor` against the
running bridge; the whole iOS target builds; the glasses-camera DAT path produces a JPEG
end to end against `MockDeviceKit` (`GlassesMockCaptureTests`); and the live-stream pipeline
comes up to `.streaming` against the mock (`CameraPoCStreamTests`) — both on the simulator.

## Toolchain

**Xcode 26 is required, which means macOS 15.6+.** MWDAT 0.9.0's `.swiftinterface` files
were emitted by Swift 6.3 in `-swift-version 6` mode; Xcode 15 cannot parse them and
Xcode 16 is a gamble. Meta's docs still say "Xcode 14.0+" — that predates 0.9.0.

Xcode 26.6 with the iOS 26.5 SDK is what this was built with. App Store Xcode ships the
**macOS platform only** — the iOS platform is a separate ~8GB download. Without it every
build fails with "Supported platforms for the buildables in the current scheme is empty."
Fix is `xcodebuild -downloadPlatform iOS`, not a reinstall.

The bridge (`server.js`) needs only Node ≥ 18 and can run on a machine with no Xcode; an
agent session there can edit `project.yml` and run `xcodegen` but cannot compile the app.

`xcodegen` via Homebrew generates the `.xcodeproj`, `Info.plist` and `.entitlements`
(`ios/SensorAgent/gen.sh`). All gitignored; `project.yml` is the source of truth.

## Rules

- `ios/SensorAgent/Sources/BridgeClient.swift` must stay **Foundation-only**. It is shared
  by the iOS app, the macOS harness, and any future build; importing AVFoundation or
  SwiftUI into it breaks all three.
- **Nothing here goes back into `sightline`.** That merge is what caused the split.
