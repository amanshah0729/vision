# Vision — sensors for the glasses

Read `../CLAUDE.md` first for the hardware facts. The one that matters most here:

> **The glasses browser has no camera and no mic.** Probed on real hardware.
> `enumerateDevices` returns `1x audiooutput`, `getUserMedia` throws `NotFoundError`.

That is the whole reason this project exists. A web app on the glasses cannot see or
hear. So a native client on the **phone** captures instead and dials *out* to a bridge —
outbound, because a browser on the glasses will not accept a TLS-less LAN address, and
mixed content is blocked.

| Piece | What it is |
|---|---|
| `PROTOCOL.md` | **The durable asset.** Wire contract between a native sensor client and a bridge. |
| `server.js` | **The host.** Token gate + static `public/` + mounts `sensors.js`. `./start.sh`, port 8791. |
| `sensors.js` | Bridge-side handler implementing `PROTOCOL.md`. Zero-dep; `server.js` mounts it. |
| `ios/` | Native sensor client (Swift). Speaks `PROTOCOL.md`. See `ios/README.md`. |
| `tools/swift-sensor/` | The real `BridgeClient` with capture faked — compiles and runs on macOS. |
| `tools/fake-sensor.sh` | Impersonates the native client so the pipeline can be tested with no app. |
| `public/look.html` | Standalone camera-stills web app. |
| `public/probe.html` | Capability probe for the glasses browser. How the camera verdict was reached. |
| `tools/capture/` | Mac/iPhone webcam stand-in. **Not the glasses.** See the warning below. |

## The goal is the GLASSES camera. Read this before building anything.

The point of this repo is that an agent sees **what Aman sees through the glasses**. A
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
- **Subscribe to session and stream state *before* calling `start()`.** DAT does not replay
  the current state to a late listener, so watching `stateStream()` after `start()` silently
  misses `.started`/`.streaming` and hangs. `GlassesCamera` and Meta's own sample both attach
  the listener first.
- **Warm the `AutoDeviceSelector` before `createSession`.** A freshly-made selector reports no
  active device for a beat; a session created in that beat throws `noEligibleDevice`.
- `Foundation.Stream` collides with `MWDATCamera.Stream`. Qualify it.
- `MWDAT.MetaAppID = "0"` is the documented Developer Mode value; it only needs a real
  application id for builds that leave this machine.

## Wi-Fi is the camera link, and that needs the PAID Apple Developer Program

Settled 2026-09-14 by reading `MWDATCore` and Meta's own sample. Do not re-litigate.

- **Bluetooth is only the base link.** DAT brings BLE up for discovery/control, then
  *upgrades to Wi-Fi* for the camera stream (`base connection ready, starting WiFi
  upgrade`). Two transports: SoftAP — the phone joins the glasses' access point via
  `NEHotspotConfiguration` — and Wi-Fi Aware on iOS 26. If the user denies Local Network,
  Meta's docs say the app "will continue over Bluetooth LE, but without streaming" — and
  photos need a live stream, so no Wi-Fi means no photos.
- **`NEHotspotConfiguration` needs `com.apple.developer.networking.HotspotConfiguration`.**
  Meta's `samples/CameraAccess/CameraAccess.entitlements` declares it plus
  `com.apple.developer.networking.wifi-info`. Both are capabilities a **free personal team
  cannot provision**. A free-team build compiles, installs, and never gets a frame. Hence:
  the $99/yr Apple Developer Program is a hard requirement for real hardware, not a nicety.
- `project.yml` now declares both entitlements plus every Info.plist key MWDATCore validates
  at runtime (`NSBonjourServices` must include `_meta-datax._tcp`; `UIBackgroundModes` gets
  `external-accessory`; `UISupportedExternalAccessoryProtocols: com.meta.ar.wearable`).
  Meta's sample has fewer of these; the extras come from the binary's own
  "missing requirements" strings and cost nothing.
- Team ID is plumbed through the gitignored `Team.xcconfig` (`ios/SensorAgent/gen.sh`).
  DAT reads the same value as `MWDAT.TeamID`, so it must be the real one.

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

- **Still no *real* glasses.** The DAT capture path is now exercised end to end — but against
  `MockDeviceKit`, not hardware. Registration, permission and pairing against a real pair, and
  a real Bluetooth capture, remain unexercised. The mock proves the code; it does not prove the
  device. Say which one you mean.
- **`MockDeviceKit` is wired and covered.** `GlassesMock` stands a fake Ray-Ban up (pair →
  powerOn → unfold → don → video feed + captured still), and `GlassesMockCaptureTests` drives
  the real `GlassesCamera` path against it — session → stream → `capturePhoto` — and asserts a
  JPEG comes back. It passes on the simulator. Toggle it in the app under **Debug → Mock
  glasses**; a mock session reports as a stand-in (plain `["mic","camera"]`) and every frame is
  stamped "MOCK GLASSES".
- **Access needs Aman, not an agent.** A Meta developer account, accepted Developer Terms,
  Developer Mode on in the Meta AI app, then two in-app approvals on his phone. No part of
  that is scriptable. Do not claim to have access. This is the only thing between the mock and
  a real capture.
- **The host exists now (`server.js`) but is not deployed.** Same token scheme as
  Sightline, port 8791, hostname `vision.orthosoftwaresucks.com` in
  `../tunnel/config.yml`, LaunchAgent in `../deploy/com.vision.bridge.plist`. Verified
  2026-09-14 locally with `tools/fake-sensor.sh` and `tools/swift-sensor` (register →
  `camera.still` → still lands → `mic.start` → transcripts land). Installing the LaunchAgent
  and restarting the tunnel on the host is the remaining step.

What *is* verified: the protocol layer end to end, via `tools/swift-sensor` and
`tools/fake-sensor.sh` against `server.js`; the whole iOS target builds; and the
glasses-camera DAT path produces a JPEG end to end against `MockDeviceKit`, via
`GlassesMockCaptureTests` on the simulator.

## Toolchain

**Xcode 26 is required, which means macOS 15.6+.** MWDAT 0.9.0's `.swiftinterface` files
were emitted by Swift 6.3.3 in `-swift-version 6` mode; Xcode 15 cannot parse them at all
and Xcode 16 is a gamble. Meta's docs still say "Xcode 14.0+" — that predates 0.9.0.

Two Macs, and it matters which one you are on:
- **Dev laptop — Aman's MacBook Pro** (`macbook-pro-42` on Tailscale). Xcode 26.6 / iOS 26.5
  SDK, installed 2026-09-10; where the mock tests ran and where phone builds happen. Note
  App Store Xcode ships the macOS platform only; the iOS platform is a separate ~8GB
  `xcodebuild -downloadPlatform iOS`, without which every build fails "Supported platforms
  for the buildables in the current scheme is empty."
- **Home server — the M1 MacBook Air** (`amans-macbook-air`, macOS 14.1.1). Runs the
  tunnel and both bridges 24/7. **No Xcode, only Command Line Tools**, and it does not need
  any: nothing here builds iOS. An agent session on this box can still edit `project.yml`
  and run `xcodegen`, but cannot compile the app. Do not try to install Xcode on it.

`xcodegen` via Homebrew generates the `.xcodeproj`, `Info.plist` and `.entitlements`
(`ios/SensorAgent/gen.sh`). All gitignored; `project.yml` is the source of truth.

## Rules

- `ios/SensorAgent/Sources/BridgeClient.swift` must stay **Foundation-only**. It is shared
  by the iOS app, the macOS harness, and any future build; importing AVFoundation or
  SwiftUI into it breaks all three.
- **Nothing here goes back into `sightline`.** That merge is what caused the split.
