# Card counter — glasses stream → Hi-Lo true count → glasses display

Everything runs on the bridge Mac. The phone streams frames from the glasses' camera
(`camera.stream.start`, see `../PROTOCOL.md`); `worker.py` pulls each new frame off the
bridge, finds the cards, counts each one once, and pushes the running/true count back;
`../public/count.html` on the glasses polls that and shows it in big type. No iOS change
was needed and none is planned.

```
glasses camera ─BT─▶ phone ─POST frame─▶ bridge :8791 ◀─GET frame.jpg── worker.py
                                             ▲                              │
 glasses browser ◀──GET /api/count───────────┴──────POST /api/count/state───┘
                 ──POST /api/count/reset (pinch "Shuffle")──▶
```

| File | What |
|---|---|
| `cards.py` | Ranks, Hi-Lo values, and the glyph templates (drawn synthetically on first run). |
| `detect.py` | Classical detector: adaptive threshold → convex quads → warp → corner glyph match. |
| `track.py` | Count-once tracker: motion-compensated position tracks, vote on rank, count on stable read. |
| `worker.py` | The loop. Polls `frame.seq`, runs the two above, pushes `/api/count/state`. |
| `../count.js` | Bridge routes (`/api/count*`), mounted by `server.js`. In memory, like `sensors.js`. |
| `../public/count.html` | The glasses page. 600×600, D-pad, four chips: Start/Stop, Shuffle, Decks −/+. |
| `tools/synth.py` | Draws a fake dealt table so the whole chain runs with no hardware. |
| `tools/replay.py` | Run the detector/tracker over saved frames; annotated output for tuning. |
| `tools/grab.py` | Save frames off the live stream — how a real-table dataset is collected. |
| `tools/mktemplates.py` | Redraw the synthetic templates, or `learn` real ones from frames of a known card. |
| `start.sh`, `com.vision.count.plist` | Run it as a LaunchAgent beside the bridge. |

## Run

```
count/start.sh                     # builds count/.venv on first run (python3 + opencv + numpy)
open https://<bridge>/count.html?k=<token>     # on the glasses: Start, then Shuffle at each shuffle
```

As a service: `cp count/com.vision.count.plist ~/Library/LaunchAgents/ && launchctl bootstrap
gui/$(id -u) ~/Library/LaunchAgents/com.vision.count.plist`. After `git pull`:
`launchctl kickstart -k gui/$(id -u)/com.vision.count`. Logs: `count.out.log`.

## What is verified and what is not

**Verified (2026-09-16):**
- Synthetic table (`tools/synth.py`, six cards dealt over 14 frames with camera jitter and
  perspective) → all six detected, each counted exactly once, correct Hi-Lo running count.
  9 ms/frame on the M1 Air.
- Same frames posted to the real bridge by a fake phone, with the worker running as its
  LaunchAgent → `/api/count` shows the count, `POST /api/count/reset` clears it, the deck
  setting round-trips.
- The real glasses stream reaches the worker at ~3 fps (504×896). Two recordings of an
  office with no cards in it (`count/frames/room1`, `room2`, gitignored) produce zero
  counted cards. They did not at first: a monitor showing a white document read as a K
  with a wide margin every frame. Two card-specific rules fixed it and are why they exist —
  the area cap (cards at seat distance are 0.5–2% of the frame; screens were 8%+) and the
  rule that both opposite corners must read the same rank, which nothing but a card does.

**Not verified — needs a deck and a table:** detector accuracy on real cards. The templates
are drawn in a Hershey stroke font and the suit pips are approximations; they were enough
to read the synthetic deck (which is drawn the same way, so that proves nothing about
paper). Real card indices are a different font, and real tables have glare, overlap, hands,
and chips. The tracker deliberately refuses to count a low-margin read, so the failure mode
on real cards is expected to be *under*-counting, not wrong counting. Do this first:

1. `count/.venv/bin/python count/tools/grab.py --seconds 120 --out count/frames/home1` while
   dealing a deck in front of the glasses.
2. `count/.venv/bin/python count/tools/replay.py count/frames/home1 --track --out count/out`
   and look at `count/out/*.jpg`: green = confident read, orange = low margin (not counted),
   red = quad but no rank.
3. For each rank that reads badly, hold that card up alone, grab a frame, and
   `mktemplates.py learn <frame> <rank> [suit]`. Thirteen of those replaces the synthetic set.
4. Replay again. Iterate on `detect.py` thresholds against the *same* saved frames.

If classical matching tops out below what the table needs, the next step is a small trained
detector (a YOLO-class model on a public playing-card dataset, fine-tuned on `count/frames`)
behind the same `detect(frame) -> [Card]` interface. Nothing else changes.

## Design choices worth knowing

- **Hi-Lo is suit-blind and only has three buckets.** The detector is built around that:
  suits are best-effort and never affect the count; a rank only has to land in the right
  bucket; and the detector reports a *margin* so the tracker can refuse the reads that
  could cross a bucket boundary (6/7, 9/10).
- **Count once, on stable evidence.** A card is counted when a track has been seen in ≥3
  frames, ≥66% of its rank votes agree, and the mean margin clears the bar. It keeps
  suppressing for 6 s after it was last seen, so a hand over the table does not create a
  second count. A sweep-and-redeal in the same spot after that is counted again, correctly.
- **The camera moves; the table does not.** Phase correlation on a 160-px-wide grey copy
  gives the frame-to-frame translation of the whole picture for free, and tracks are shifted
  by it before matching. That is what keeps a track on its card while the wearer's head
  moves. When a hand sweeps through, the correlation response drops and the shift is skipped.
- **Decks left floors at 0.5** so the true count cannot blow up at the end of a shoe.
- **The glasses never see a frame.** They get numbers. `count.html` shows the true count at
  176 px because through the waveguide that is what has to be readable in a glance.

## Legal note

Aman already knows this and it is recorded here so nobody has to say it again: using a
device to count cards at a licensed table is a crime in Nevada (NRS 465.075) and in most
jurisdictions. This is a home/build project.
