"""Run the detector (and optionally the tracker) over saved frames, without hardware.

    python count/tools/replay.py count/frames/table1            # detections per frame
    python count/tools/replay.py count/frames/table1 --track    # and the count they produce
    python count/tools/replay.py frame.jpg --out count/out      # annotated images to look at

This is the tuning loop. Change a threshold in detect.py, replay, look at the annotated
output, repeat. It is how "expect the detector to be the real work" is meant to be done —
on saved frames from the actual table, not live, so a change can be judged against the
same frames twice.
"""

import argparse
import glob
import os
import sys
import time

import cv2
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from detect import CardDetector           # noqa: E402
from track import CountOnceTracker        # noqa: E402
from worker import camera_motion          # noqa: E402


def annotate(frame, cards, debug):
    out = frame.copy()
    for q in debug.get('quads', []):
        cv2.polylines(out, [q.astype(np.int32)], True, (80, 80, 255), 1)
    for c in cards:
        colour = (0, 220, 0) if c.rank and c.margin >= 4 else (0, 200, 255) if c.rank else (0, 0, 255)
        cv2.polylines(out, [c.quad.astype(np.int32)], True, colour, 2)
        label = (c.rank or '?') + ((' ' + c.suit[0]) if c.suit else '') + ' %.0f/%.0f' % (c.score, c.margin)
        x, y = int(c.center[0]), int(c.center[1])
        cv2.putText(out, label, (x - 30, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 4)
        cv2.putText(out, label, (x - 30, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6, colour, 1)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('paths', nargs='+')
    ap.add_argument('--track', action='store_true')
    ap.add_argument('--decks', type=int, default=6)
    ap.add_argument('--out', default=None, help='write annotated frames here')
    ap.add_argument('--fps', type=float, default=3.5, help='assumed frame interval for --track')
    ap.add_argument('--quiet', '-q', action='store_true')
    args = ap.parse_args()

    files = []
    for p in args.paths:
        files += sorted(glob.glob(os.path.join(p, '*.jpg'))) if os.path.isdir(p) else [p]
    if not files:
        sys.exit('no frames')
    if args.out:
        os.makedirs(args.out, exist_ok=True)

    det = CardDetector()
    trk = CountOnceTracker(decks=args.decks)
    prev_small = None
    t_all = 0.0
    now = 0.0
    for f in files:
        frame = cv2.imread(f)
        if frame is None:
            continue
        dbg = {}
        t0 = time.time()
        if args.track:
            grey = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            scale = 160.0 / grey.shape[1]
            small = cv2.resize(grey, None, fx=scale, fy=scale).astype(np.float32)
            if prev_small is not None and prev_small.shape == small.shape:
                dx, dy = camera_motion(prev_small, small)
                trk.shift(dx / scale, dy / scale)
            prev_small = small
        cards = det.detect(frame, debug=dbg)
        counted = trk.update(cards, now) if args.track else []
        t_all += time.time() - t0
        now += 1.0 / args.fps
        if not args.quiet:
            desc = ' '.join((c.rank or '?') + ('' if c.margin >= 4 else '~') for c in cards)
            line = '%-28s %2d quads %2d cards  %s' % (os.path.basename(f), len(dbg.get('quads', [])), len(cards), desc)
            if counted:
                line += '   COUNTED ' + ' '.join(t.rank for t in counted) + '  → run %+d true %+.1f' % (trk.running, trk.true_count())
            print(line)
        if args.out:
            cv2.imwrite(os.path.join(args.out, os.path.basename(f)), annotate(frame, cards, dbg))
    print('%d frames, %.1f ms/frame' % (len(files), 1000.0 * t_all / max(1, len(files))))
    if args.track:
        s = trk.snapshot()
        print('running %+d  true %+.1f  seen %d  decks left %.1f' % (s['running'], s['trueCount'], s['seen'], s['decksLeft']))
        print('recent: ' + ' '.join(c['rank'] + (c['suit'][0] if c['suit'] else '') for c in s['recent']))


if __name__ == '__main__':
    main()
