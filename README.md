# vision — the Meta Ray-Ban Display camera, from your phone, on a free Apple account

The browser on Meta Ray-Ban Display glasses has **no camera and no microphone**
(`getUserMedia` throws `NotFoundError`; probed on hardware). This repo is the workaround:
a small iOS app that reads the glasses' camera through Meta's Wearables Device Access
Toolkit (DAT) and a wire protocol so a web app on the glasses can ask for a still or a
transcript through a bridge server the phone dials out to.

Verified on a Ray-Ban Display with DAT 0.9.0, an iPhone 16 Pro, and a **free** Apple
Personal Team, 2026-09-14:

| | |
|---|---|
| Link | Bluetooth Classic (no Wi-Fi entitlements) |
| Stream up | ~2 s after the glasses connect |
| Video | 504×896 HEVC, 29–32 fps sustained |
| Photo | 1080×1440 JPEG in 0.7–1.8 s |
| End to end via the bridge | command → still visible: 3.7 s warm, ~34 s cold (first session) |

## The one finding worth the repo

DAT ≥ 0.8.0 can carry camera frames over **two** links: the glasses' SoftAP Wi-Fi, which
needs the `wifi-info` + `HotspotConfiguration` entitlements a free Apple team cannot
provision, **or Bluetooth Classic via ExternalAccessory**, which needs only two Info.plist
entries:

```yaml
UISupportedExternalAccessoryProtocols: [com.meta.ar.wearable]
UIBackgroundModes: [bluetooth-central, external-accessory]
```

Without those two keys DAT has no usable link at all: the stream sits in
`waitingForDevice` and dies `deviceNotConnected` after exactly 30 s, even though the
device reports `.connected`. That is the failure several threads on Meta's DAT repo
describe, and it is not fixed by a paid account. The paid Apple Developer Program only
buys the faster Wi-Fi link (~24 fps steady vs Bluetooth's bursty 6–30).

Full notes, including what was learned from `strings` on the DAT binaries, are in
[`ios/README.md`](ios/README.md) and [`CLAUDE.md`](CLAUDE.md).

## What is here

| Path | What |
|---|---|
| `ios/SensorAgent/` | The iOS app. Glasses camera via DAT, phone-mic dictation, a bridge client, a live-camera PoC with fps/latency HUD, a Bluetooth-HFP mic PoC, and a `MockDeviceKit` mock so it runs on the simulator. |
| `PROTOCOL.md` | Wire contract between a native sensor client and a bridge: registration, capabilities, command queue, results. Language-neutral. |
| `server.js` | The bridge host: token gate with lockout, static `public/`, mounts `sensors.js`. Zero dependencies, Node ≥ 18. `./start.sh`. |
| `sensors.js` | Bridge-side handler implementing the protocol. |
| `public/` | `probe.html` (the capability probe that produced the "no camera" verdict) and `look.html` (a stills viewer). |
| `tools/` | A macOS harness for the bridge client, a bash impersonator, and a Mac webcam CLI that is explicitly *not* the glasses. |

## Run it

Requirements: Xcode 26 with the iOS platform, `brew install xcodegen`, an iPhone, Ray-Ban
Display glasses paired in the Meta AI app with Developer Mode on, and a Meta developer
account with the terms accepted.

```sh
cd ios/SensorAgent
./gen.sh                              # xcodegen + a gitignored Team.xcconfig

# Simulator: runs the whole DAT path against MockDeviceKit and asserts a JPEG comes back
xcodebuild -project SensorAgent.xcodeproj -scheme SensorAgent -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES test

# Real phone + real glasses, driven entirely from the Mac
cp .device.env.example .device.env   # fill in UDID, team id, bundle id
./device.sh all                       # build, install, launch the camera PoC
./device.sh log                       # pull the run log: link state, fps, capture time
./device.sh photo                     # pull the still it took at the 10 s mark
```

First launch opens Meta AI for you to approve the app, then asks for camera permission.
Both are one tap and happen on the phone. After that the run is hands-free: unfold the
glasses, keep the phone unlocked, and `device.sh run`.

For the real thing: `./device.sh bridge https://your-bridge <token>` connects the agent to
a bridge, and it stays connected with the phone locked. On a free Personal Team every
device build that needs a new profile mints a new certificate (`PROVISION=1`), and a key
minted by one build will prompt for the Mac login password on the next — if you don't have
that password, just build with `PROVISION=1` each time and prune old certificates.

Things that bit us, so you can skip them:

- **Build ≠ run.** `CODE_SIGNING_ALLOWED=NO` compiles but DAT's `configure()` needs the
  keychain, so the unsigned app fails at runtime. Ad-hoc signing is enough on the simulator.
- **`Wearables.configure()` must run at app launch**, not lazily. Later calls throw and
  leave `Wearables.shared` trapping.
- **Subscribe to state before `start()`.** DAT does not replay state to late listeners.
- **The permission check needs a connected pair.** With the glasses known but folded it
  throws instantly; the app now waits up to 30 s for `linkState == .connected`.
- **Frames off real glasses are compressed HEVC.** `VideoFrame.makeUIImage()` returns nil;
  render them with `AVSampleBufferDisplayLayer`, and **flush it after every photo** or the
  picture freezes while frames keep arriving.
- **Streaming drains the glasses fast.** Expect a low-battery shutdown within a few runs.

## Status

Honest and incomplete:

- Camera capture, live view, and photo are verified on hardware. Dictation from the
  phone mic works; the Bluetooth-HFP glasses-mic PoC is untested on hardware.
- The full loop is verified on hardware (2026-09-15): a `camera.still` posted to a public
  `server.js` behind a Cloudflare tunnel → the phone app (over cellular) → the glasses →
  JPEG posted back → fetched from `/api/sensors/still.jpg`. 3.7 s warm, ~34 s the first
  time while the DAT session comes up. Put the bridge behind HTTPS — the glasses browser
  refuses plain http.
- The agent survives backgrounding and a locked screen: it holds a silent audio session
  under the `audio` background mode. Verified 2026-09-15: eight minutes behind another app,
  still polling, capture in 5 s; and pinches from the glasses with the phone locked and
  away. It does *not* survive iOS terminating the app (memory pressure, reboot, swipe-up),
  and a locked phone cannot be relaunched remotely — so the app reconnects by itself on
  any launch once a bridge is saved, and recovery is one tap on the icon.
- `look.html` verified on the glasses browser: pinch → still on the display in ~5 s.
- **Live frame stream** (`camera.stream.start`, 2026-09-15/16): the phone decodes the glasses'
  HEVC in hardware and posts ~44 KB 480×854 JPEGs; the bridge keeps the newest at
  `/api/sensors/frame.jpg`. Measured: 3.6 fps for 60 s with the app in the foreground, 3.2 fps
  for 75 s with the phone **locked**, ~115–150 ms per upload, zero upload failures. Frames
  are sharp enough to read a laptop screen layout. Two rough edges, both with fixes built
  but **not yet verified on hardware**: the decoder dies when the app changes foreground
  state (now rebuilt on `kVTInvalidSessionErr`), and one locked run decoded nothing at all
  (now detected after 5 s and the camera stream restarted to force a keyframe).
- Right after a fresh Meta AI registration the glasses ended three sessions within a minute
  ("Session ended by device"); nothing since. Treat the first minute after approving as
  unreliable. Registration itself dropped after some reinstalls and survived others —
  budget one Meta AI tap per install.
- Android is a protocol away. Nothing here is shared with iOS except `PROTOCOL.md`, on
  purpose.

## License

MIT.
