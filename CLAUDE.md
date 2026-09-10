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
| `sensors.js` | Bridge-side handler implementing `PROTOCOL.md`. Was mounted into Sightline. |
| `ios/` | Native sensor client (Swift). Speaks `PROTOCOL.md`. See `ios/README.md`. |
| `tools/swift-sensor/` | The real `BridgeClient` with capture faked — compiles and runs on macOS. |
| `tools/fake-sensor.sh` | Impersonates the native client so the pipeline can be tested with no app. |
| `public/look.html` | Standalone camera-stills web app. |
| `public/probe.html` | Capability probe for the glasses browser. How the camera verdict was reached. |
| `tools/capture/` | **Works today.** Swift CLI, one JPEG from any Mac-visible camera. No Xcode. |

## If an agent needs to see something, use `tools/capture`

This is the working path, and it sidesteps the entire blocked iOS thread:

```bash
tools/capture/bin/capture --out /tmp/shot.jpg      # built-in camera
tools/capture/bin/capture --device "Aman" --out /tmp/p.jpg   # iPhone, Continuity
```

AVFoundation compiles against Command Line Tools, and Continuity Camera exposes the phone
as an ordinary Mac capture device — so no Xcode, no developer account, no provisioning.
Verified 2026-09-09: real 1920x1080 frames from both the built-in camera and the iPhone.

It is **not the glasses' camera** and needs the Mac awake with the phone nearby. See
`tools/capture/README.md` for the KVO and warmup traps, both already paid for.

A valid JPEG proves nothing — a black frame is valid too. Look at the image before
believing a capture worked.

## State of this repo — read before promising anything

Split out of `sightline` on 2026-09-09. Two things are honestly incomplete:

- **There is no host process here.** `sensors.js` used to be mounted into Sightline's
  `server.js`, which supplied the HTTP server, the token gate, and the lockout. Pulling it
  out left the handler without a host. Nothing in this repo currently runs. Standing one up
  means reimplementing auth — do not just expose `handleSensors` unauthenticated.
- **The iOS capture layer has never compiled.** This machine has Command Line Tools, not
  full Xcode, so `xcodebuild` does not exist. `Dictation.swift`, `StillCapture.swift`,
  `AgentController.swift`, and `SensorAgentApp.swift` are unverified code. Say so plainly
  rather than implying they work. Xcode also needs ~50GB free that the disk does not have,
  plus a developer account and provisioning to reach a device — this is not nearly done.

What *is* verified: the protocol layer, end to end, via `tools/swift-sensor` against the
running bridge.

## Rules

- `ios/SensorAgent/Sources/BridgeClient.swift` must stay **Foundation-only**. It is shared
  by the iOS app, the macOS harness, and any future build; importing AVFoundation or
  SwiftUI into it breaks all three.
- **Nothing here goes back into `sightline`.** That merge is what caused the split.
