# SensorAgent — native sensor client

The glasses browser exposes **no camera and no microphone** (probed on hardware: only
`1x audiooutput`, and `getUserMedia` throws `NotFoundError`). This app supplies both from
the phone, speaking `../PROTOCOL.md` v1. The phone dials **out** to the bridge, so there is
no mixed-content problem and no LAN requirement.

## Layout

| File | Verified? |
|---|---|
| `Sources/BridgeClient.swift` | **Yes** — Foundation-only, compiled and run against the live bridge via `tools/swift-sensor`. |
| `Sources/Dictation.swift` | No — `SFSpeechRecognizer` + `AVAudioEngine`, iOS-only. |
| `Sources/StillCapture.swift` | No — `AVCapturePhotoOutput`, iOS-only. |
| `Sources/AgentController.swift` | No — wires the above to the client. |
| `Sources/SensorAgentApp.swift` | No — SwiftUI shell. |

`BridgeClient.swift` is deliberately free of AVFoundation, Speech and SwiftUI so the same
file drives the iOS app, the macOS harness, and a future DAT build.

## Build

This machine has Command Line Tools only, so the app has **never been compiled**. You need
full Xcode:

```sh
brew install xcodegen
cd ios/SensorAgent && xcodegen generate
open SensorAgent.xcodeproj
```

The `.xcodeproj` is gitignored — `project.yml` is the source of truth. Signing needs your
own team; the bundle prefix is `com.amanshah.glasses`.

## Use

1. Run the bridge: `./start.sh --tunnel`
2. In the app, paste the bridge URL (`https://…`, no `?k=`) and the token from `.token`
3. Start. The phone appears in `GET /api/sensors` within a second or two.
4. From the glasses (or curl) queue a command:
   `curl -X POST -H "Authorization: Bearer $TOKEN" -d '{"action":"mic.start"}' $BASE/api/sensors/command`

## Test without a phone

`tools/swift-sensor` is the same client with capture faked — the fastest way to confirm the
bridge half works before blaming the app:

```sh
swiftc -O ios/SensorAgent/Sources/BridgeClient.swift tools/swift-sensor/main.swift \
  -o tools/swift-sensor/bin/swift-sensor
./tools/swift-sensor/bin/swift-sensor http://localhost:8787 "$(cat .token)" 30
```

`tools/fake-sensor.sh` does the same in bash if you would rather not compile anything.
