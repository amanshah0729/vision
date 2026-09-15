# Handoff — continue on the MacBook Pro (written 2026-09-14 from the Air)

Read `CLAUDE.md` first; it now holds every verified fact. This file is only the
"where we are and what to do next" for the thread that picks this up on the Pro.

## Where things stand

- Branch **`glasses-camera-real-hardware`** (this repo, PR amanshah0729/vision#1) — pushed.
  Parent repo branch `t3code/f22bfb99` (PR amanshah0729/glasses#3) — pushed.
- **Settled:** the DAT camera stream rides Wi-Fi (`NEHotspotConfiguration`), whose entitlements
  are paid-Apple-Developer-Program only. `ios/SensorAgent/project.yml` now declares everything
  Meta's CameraAccess sample does, plus the Info.plist keys MWDATCore validates at runtime.
- **Bridge is live on the Air** (`server.js`, port 8791, LaunchAgent `com.vision.bridge`).
  Token: `cat ~/Documents/glasses/vision/.token` on the Air. Verified end to end with
  `tools/fake-sensor.sh` and `tools/swift-sensor`.
- **Public URL `https://vision.orthosoftwaresucks.com`** — DNS + TLS verified, but it 404s until
  glasses PR #3 is merged and pulled on the Air and the tunnel is kickstarted (see below).
- **Never touched real hardware.** Mock path passes on the simulator. Nothing else is proven.

## Machines

| | Air (`amans-macbook-air`) | Pro (`macbook-pro-42`) |
|---|---|---|
| Role | always-on host: tunnel + bridges | dev laptop: Xcode 26.6, phone builds |
| Xcode | none, and must not be installed | yes |
| ssh over Tailscale | — | **off** (turn on Remote Login to let an Air session drive xcodebuild here) |

## Do on the Pro, in order

1. `git fetch && git checkout glasses-camera-real-hardware` in this repo.
2. `cd ios/SensorAgent && ./gen.sh` — simulator-only sanity. Then the mock test:
   ```sh
   xcodebuild -project SensorAgent.xcodeproj -scheme SensorAgent \
     -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' \
     CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES test
   ```
   This confirms the new entitlements/plist keys did not break the mock path (the 0.9.0
   changelog says the mock now runs the same Info.plist link check as real devices).
3. **Apple Developer Program** enrolled → Xcode → Settings → Accounts → note Team ID.
4. `DEVELOPMENT_TEAM=<team id> ./gen.sh`, open `SensorAgent.xcodeproj`, phone plugged in, Run.
   Automatic signing should mint a profile with HotspotConfiguration + wifi-info. If Xcode
   refuses those two capabilities, the team is not on the paid program — that is the only
   known cause.
5. Phone: trust the developer cert (Settings → General → VPN & Device Management).
6. **Meta:** Developer Terms accepted at wearables.developer.meta.com; Meta AI app →
   Settings → App Info → tap version ×5 → Developer Mode on. Glasses firmware ≥ v125, Meta AI
   ≥ v272.
7. In Sensor Agent: leave Mock OFF, tap **Capture now**. Expect: Meta AI opens → approve
   registration → bounce back via `sensoragent://` → camera permission prompt → Local
   Network prompt (say yes; no Wi-Fi = no photos) → a JPEG from the glasses appears.
   Watch `status` in the app; every failure surfaces a reason string from `GlassesCamera`.
8. Then bridge mode: paste `https://vision.orthosoftwaresucks.com` + the Air's token, Start,
   and on the glasses open `https://vision.orthosoftwaresucks.com/?k=<token>`. Pinch = capture.

## Do on the Air (any session there)

```sh
cd ~/Documents/glasses && git pull   # after merging glasses PR #3
launchctl kickstart -k gui/$(id -u)/com.glasses.tunnel
curl -s https://vision.orthosoftwaresucks.com/healthz   # expect {"ok":true,...}
```

## Open questions nobody has answered yet

- Can a still squeeze through DAT's `.low` (Bluetooth-only) link if Local Network is denied?
  MWDATCore has a `.medium → .low` fallback; Meta's docs say "no streaming" without Wi-Fi.
  Assume no.
- Does `external-accessory` in `UIBackgroundModes` + `UISupportedExternalAccessoryProtocols`
  cause any App Store/TestFlight complaint? Irrelevant for a dev build; revisit if distributing.
- `_meta-datax._tcp` came from binary strings, not docs. Harmless if wrong.

## First prompt to paste into the new thread on the Pro

> Read HANDOFF.md and CLAUDE.md in this repo. We're on the MacBook Pro now (Xcode 26.6).
> Run step 2 (gen.sh + mock test) and report. Then wait for my Team ID for step 4.
