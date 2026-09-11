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
| `Sources/GlassesCamera.swift` | **Compiles.** DAT glasses camera. Never run against hardware. |
| `Sources/AgentController.swift` | **Compiles.** Wires the above to the client. |
| `Sources/SensorAgentApp.swift` | **Compiles.** SwiftUI shell + the `onOpenURL` registration hop. |
| `Sources/Dictation.swift` | **Compiles.** `SFSpeechRecognizer` + `AVAudioEngine`. |

"Compiles" is not "works". Nothing here has touched real glasses yet.

`BridgeClient.swift` is deliberately free of AVFoundation, Speech, SwiftUI and MWDAT so the
same file drives the iOS app and the macOS harness in `tools/swift-sensor`.

## Build

```sh
brew install xcodegen
cd ios/SensorAgent && xcodegen generate
xcodebuild -project SensorAgent.xcodeproj -scheme SensorAgent \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

Both `.xcodeproj` and `Info.plist` are generated and gitignored — **`project.yml` is the
source of truth**. Editing the plist directly gets your change silently overwritten.

Deployment target is iOS 17.2 because the MWDAT binaries are built against 17.2. Running on
a real phone needs your own signing team; the bundle prefix is `com.amanshah.glasses`.

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

`MWDATMockDevice` is already linked. It is inert until something calls
`MockDeviceKit.shared.enable()` and `pairGlasses(model:)`, which nothing does yet — that is
the next piece of work and the only way to exercise `GlassesCamera` without hardware.

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

1. Run the bridge: `./start.sh --tunnel` (in the `sightline` repo)
2. In the app, paste the bridge URL (`https://…`, no `?k=`) and the token from `.token`
3. Start. The phone appears in `GET /api/sensors` within a second or two.
4. Queue a command:
   `curl -X POST -H "Authorization: Bearer $TOKEN" -d '{"action":"camera.still"}' $BASE/api/sensors/command`
