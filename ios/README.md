# SensorAgent — native sensor client

The glasses browser exposes **no camera and no microphone** (probed on hardware: only
`1x audiooutput`, and `getUserMedia` throws `NotFoundError`). This app supplies both,
speaking `../PROTOCOL.md` v1. The phone dials **out** to the bridge, so there is no
mixed-content problem and no LAN requirement.

Stills come from the **glasses** via Meta's Device Access Toolkit. Dictation still comes from
the phone — DAT does not expose the glasses microphone. Hence the advertised caps are
`["mic", "camera", "glasses-camera"]`: the mic is a stand-in, the camera is the real thing.

## Layout

| File | Verified? |
|---|---|
| `Sources/BridgeClient.swift` | **Yes** — Foundation-only, compiled and run against the live bridge via `tools/swift-sensor`. |
| `Sources/GlassesCamera.swift` | **Runs against the mock.** Full DAT path — session → stream → `capturePhoto` → JPEG — via `GlassesMockCaptureTests`. Never run against hardware. |
| `Sources/GlassesMock.swift` | **Runs.** Stands a fake Ray-Ban up in `MockDeviceKit`: pair → powerOn → unfold → don → generated video feed + stamped still. |
| `Sources/DAT.swift` | **Runs.** One-time `Wearables.configure()` at launch; without it `Wearables.shared` traps. |
| `Sources/AgentController.swift` | **Compiles.** Wires the above to the client; the `Mock glasses` toggle routes through `GlassesMock`. |
| `Sources/SensorAgentApp.swift` | **Compiles.** SwiftUI shell, `configure()` at launch, the `onOpenURL` registration hop, and the Debug toggle. |
| `Sources/Dictation.swift` | **Compiles.** `SFSpeechRecognizer` + `AVAudioEngine`. |

"Runs against the mock" is not "works on glasses". Nothing here has touched real hardware yet.

`BridgeClient.swift` is deliberately free of AVFoundation, Speech, SwiftUI and MWDAT so the
same file drives the iOS app and the macOS harness in `tools/swift-sensor`.

## Build

```sh
brew install xcodegen
cd ios/SensorAgent && ./gen.sh            # xcodegen + a gitignored Team.xcconfig
xcodebuild -project SensorAgent.xcodeproj -scheme SensorAgent \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

Needs Xcode 26 (MWDAT 0.9.0's interfaces are Swift 6.3), so macOS 15.6 or later.

`CODE_SIGNING_ALLOWED=NO` is fine for a **compile check**, but it cannot *run* capture: DAT's
`Wearables.configure()` needs the keychain, so the app must be signed with the
`keychain-access-groups` entitlement. Ad-hoc is enough on the simulator — run and test with:

```sh
CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES
```

Both `.xcodeproj`, `Info.plist` and `SensorAgent.entitlements` are generated and gitignored —
**`project.yml` is the source of truth**. Editing them directly gets silently overwritten.

Deployment target is iOS 17.2 because the MWDAT binaries are built against 17.2. Running on
a real phone needs your own signing team. A free Personal Team is enough (see below).

Device build from the CLI: copy `.device.env.example` to `.device.env` (gitignored), fill in
your device UDID, team id and bundle id, then:

```sh
./device.sh build     # xcodegen + signed device build
./device.sh install
./device.sh run       # launches with -autoStartCameraPoC
./device.sh log       # pulls Documents/poc.log
./device.sh photo     # pulls Documents/last-photo.jpg
```

Each step is one `xcodebuild` / `xcrun devicectl` call; read the script if you would rather
run them by hand.

## Free team vs paid team

Camera frames travel over one of two links. Bluetooth Classic (ExternalAccessory, ~8 fps)
needs only the `UISupportedExternalAccessoryProtocols` / `external-accessory` Info.plist
entries, which `project.yml` sets. The glasses' SoftAP Wi-Fi (~24 fps) additionally needs
the `wifi-info` + `HotspotConfiguration` entitlements, which a free personal team cannot
provision — they are commented out in `project.yml`. Enrol in the paid program only for
the faster link; it is not needed to stream at all.

## What the glasses camera needs from *you*

Compiling proves nothing about access. Before a capture can succeed:

1. A Meta developer account, with the Developer Terms + Acceptable Use Policy accepted.
2. **Developer Mode on**: Meta AI app → Settings → Your glasses → Developer Mode. This is
   what lets `MWDAT.MetaAppID = "0"` in `project.yml` work without a registered app record.
3. First launch calls `startRegistration()`, which opens Meta AI. **You tap approve**, and
   Meta AI returns through the `sensoragent://` scheme.
4. A second prompt asks for the camera permission. "Allow once" or "Allow always".

None of this is scriptable. Steps 3 and 4 happen on the phone, in Meta's app.

## Test without glasses

`GlassesMock` drives `MockDeviceKit` — the only way to exercise `GlassesCamera` without
hardware or a Meta account. `GlassesMockCaptureTests` runs the whole DAT path against it and
asserts a JPEG comes back:

```sh
cd ios/SensorAgent && xcodegen generate
xcodebuild -project SensorAgent.xcodeproj -scheme SensorAgent \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES test
```

In the app itself, flip **Debug → Mock glasses** before Start. A mock session registers as a
stand-in (`["mic","camera"]`, no `glasses-` caps) and every frame is stamped "MOCK GLASSES",
so it is never mistaken for the real thing. The mock is `#if DEBUG`-free on purpose: it is
gated behind an explicit `enable()` call, inert otherwise, so it can ship in the same binary.

## Camera PoC — measuring the link

**Main screen → "Camera PoC — live feed + latency."** A standalone harness (`CameraPoC` +
`CameraPoCView`, no bridge) that opens the DAT video stream and shows fps, a photo-capture
round-trip time, and resolution / frame-rate knobs. The point is to *feel* the real link:
wave your hand and watch the lag, drop the resolution and watch fps climb.

**The numbers only mean something on real glasses.** Against the mock the pipeline reaches
`.streaming` but no synthetic video frames arrive (a MockDeviceKit 0.9.0 limitation), so the
live view stays blank on the simulator — `CameraPoCStreamTests` asserts only that it reaches
`.streaming`. On device: run signed (same ad-hoc invocation as above), open the PoC, tap
**Start stream**, approve the Meta AI prompts once, and the feed + fps/latency come alive.

## Unattended hardware run

Registration and camera permission need a human in Meta AI once per install. After that:

```sh
./device.sh run     # phone must be unlocked
./device.sh log
```

The PoC logs session/stream state, fps stats every 5s, and one timed capture at 10s; the
still is saved beside the log as `Documents/last-photo.jpg`. Frames off real glasses are
compressed HEVC (504×896 `hvc1`), so the live view renders them through an
`AVSampleBufferDisplayLayer` — `makeUIImage()` returns nil for them.

## Mic PoC

**Main screen → "Mic PoC — glasses mic (Bluetooth)".** The glasses expose their mic as an
ordinary Bluetooth HFP headset, so this needs no DAT at all: probe the inputs, toggle
"Use glasses mic", start dictation, and the "Active input" line shows which mic is feeding
the transcript. Unverified on hardware as of 2026-09-14.

## Test without a phone

`tools/swift-sensor` is `BridgeClient` with capture faked — the fastest way to confirm the
bridge half works before blaming the app:

```sh
swiftc -O ios/SensorAgent/Sources/BridgeClient.swift tools/swift-sensor/main.swift \
  -o tools/swift-sensor/bin/swift-sensor
./tools/swift-sensor/bin/swift-sensor http://localhost:8787 "$(cat .token)" 30
```

`tools/fake-sensor.sh` does the same in bash if you would rather not compile anything.

## Use

1. Run the bridge: `./start.sh` in this repo (port 8791) behind something that gives it
   HTTPS — the glasses browser refuses plain http.
2. In the app, paste the bridge URL (`https://…`, no `?k=`) and the token from `.token`
3. Start. The phone appears in `GET /api/sensors` within a second or two.
4. Queue a command:
   `curl -X POST -H "Authorization: Bearer $TOKEN" -d '{"action":"camera.still"}' $BASE/api/sensors/command`
