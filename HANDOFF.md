# Handoff — written 2026-09-16 on the Air, after the card counter landed

Read `CLAUDE.md` and `README.md` first for the platform facts; `count/README.md` for the
counter. This file is only "where things stand and what to do next".

## Where things stand

- **The card counter exists end to end and runs as a service on the Air.** Glasses stream →
  `count/worker.py` (LaunchAgent `com.vision.count`) → `/api/count` on the bridge →
  `public/count.html` on the glasses. Verified with a synthetic dealt table (six cards, each
  counted exactly once, correct Hi-Lo), with those frames posted through the real bridge by a
  fake phone, and with the real glasses stream in an office (≈3 fps, zero false counts after
  two card-specific filters — see `count/README.md`).
- **The decoder-recovery fixes in `FrameStreamer` from the Pro are still unverified** — they
  did not get their 3-minute locked run. The stream was started and stopped ~8 times today
  in short bursts without a stall; that is not the same test.
- **`count.html` has not been opened on the glasses yet.** Served (200), inline script
  syntax-checked, layout follows `look.html`. Someone has to add
  `https://<bridge>/count.html?k=<token>` as a web app and tap Start.
- One stream start today silently did nothing (`frame.seq` did not move for 30 s after
  `camera.stream.start`); the next attempt 60 s later worked. Unexplained. If it recurs,
  check `count.out.log` for `frameSeq` and just re-send the command.

## What to do next, in order

1. **Real cards.** Everything about detector *accuracy* is unmeasured. Deal a deck in front
   of the glasses: `grab.py` → `replay.py --track --out` → look at the annotated frames.
   Expect under-counting (low-margin reads are refused by design), not wrong counting.
2. **Learn templates from the real deck** (`mktemplates.py learn`, 13 ranks + 4 suits). The
   shipped templates are drawn in a Hershey font; they are a bootstrap.
3. Then tune `detect.py` thresholds against the same saved frames, or, if classical matching
   tops out, put a trained detector behind the same `detect()` interface.

## Air vs Pro

The Air runs the bridge and the worker and cannot build iOS. No iOS change was needed for
the counter and none is planned. If `FrameStreamer` turns out not to hold on a long locked
run, that is the one remaining iOS task and it lives on the Pro.

After `git pull` on the Air: `launchctl kickstart -k gui/$(id -u)/com.vision.bridge` and
`launchctl kickstart -k gui/$(id -u)/com.vision.count`. Static files need no restart.

## Quirks carried forward

- Eight bad tokens from one IP = ten-minute lockout for that IP. Never loop with an empty token.
- `maxSeconds` on the stream defaults to 600; `count.html` asks for 1800. The glasses'
  battery lasts a few streaming runs.
- First minute after a Meta AI (re)approval: the glasses may end sessions on their own.
- Phone logs only from the Pro (`ios/SensorAgent/device.sh log`).
