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

- iOS SDK via Swift Package Manager → **needs full Xcode**. The disk-space work is on the
  critical path for this, not for the old AVFoundation design.
- Needs a Meta developer account and Developer Mode enabled via the Meta AI app.
- Solo dev running a build on their own glasses is supported. Publishing is not, during
  preview — irrelevant for personal use.
- **`MockDeviceKit` tests without physical glasses**, so integration can start before
  hardware and permissions are sorted.

`ios/SensorAgent` was written against the wrong assumption: AVFoundation capturing the
*phone's* camera. The fix is to swap its capture layer for DAT reading the *glasses*
camera. `PROTOCOL.md` already anticipated this and needs no change — it has the
`glasses-camera` capability designed in.

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
