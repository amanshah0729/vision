# capture

A single-file Swift CLI that grabs one JPEG still from any camera macOS can see.

```bash
swiftc -O -o bin/capture main.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist

./bin/capture --list                          # devices + permission state
./bin/capture --out /tmp/shot.jpg             # default (built-in) camera
./bin/capture --device "Aman" --out /tmp/p.jpg # iPhone via Continuity Camera
./bin/capture > shot.jpg                      # JPEG on stdout if --out omitted
```

## Why this is the shortcut

The glasses browser has no camera. The iOS `SensorAgent` that was meant to supply one
needs full Xcode (~50GB), a developer account, and provisioning — none of which exist yet.

But **AVFoundation compiles against Command Line Tools**, and Continuity Camera exposes
the iPhone as an ordinary Mac capture device. So an agent can see today, with none of
that. This sidesteps the blocked iOS thread rather than solving it.

What it is not: it is **not the glasses' camera**, and it needs the Mac awake with the
phone nearby and unlocked.

## Two things that were paid for the hard way

- **`AVCaptureVideoDataOutput`, not `AVCapturePhotoOutput`.** The photo path needs a KVO
  subclass the ObjC runtime cannot synthesise in a bare CLI. It fails with
  `NSKVONotifying_AVCapturePhotoOutput not linked into application` and then silently
  never fires the delegate — it looks like a hang, not an error.
- **Early frames are discarded.** A just-woken sensor is still auto-exposing; the first
  frames come back black or blown out. `--warmup` (default 700ms worth) sets how many to
  throw away. Continuity Camera is slower to wake than the built-in one.

## Permission

macOS TCC attributes the prompt to whatever launched the binary. Run it once from a normal
terminal window and click Allow. A capture launched from a headless or background process
before that grant can fail with no visible prompt — hence exit code 3 and an explicit
message rather than a broken image.

Grant lives in System Settings → Privacy & Security → Camera, against the *launching* app
(Terminal, iTerm, etc.), not against `capture` itself.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | image written |
| 2 | bad usage |
| 3 | permission denied / not granted |
| 4 | no matching camera |
| 5 | capture failed or timed out |

## Sanity check

A valid JPEG of the right dimensions proves nothing — a black frame is also a valid JPEG.
Always open the file, or have a vision model describe it, before believing the capture
worked. A flat featureless image usually means the phone is face-down, not that the code
is broken.
