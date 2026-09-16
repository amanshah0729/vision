"""The counting loop. Polls the bridge for new frames, detects, tracks, pushes the count.

    count/.venv/bin/python count/worker.py            # token from ../.token, bridge on :8791
    BRIDGE=https://host TOKEN=… python worker.py      # against a remote bridge
    python worker.py --save count/frames              # also keep every frame (dataset)

Runs next to the bridge, so it talks to it on localhost and never needs the tunnel. It is
the only process that ever sees the frames; the glasses only get numbers back.

Why poll and not stream: the bridge keeps exactly one frame (newest wins, see PROTOCOL.md)
and the phone posts ~3.5 of them a second. Polling `frame.seq` ten times a second costs a
few hundred bytes a call and never processes a stale frame, which a queue would. When the
detector is slower than the frame rate the loop simply skips frames — the count does not
need every frame, it needs each card in a few of them.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from detect import CardDetector          # noqa: E402
from track import CountOnceTracker       # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def read_token():
    t = os.environ.get('TOKEN')
    if t:
        return t.strip()
    p = os.path.join(HERE, '..', '.token')
    try:
        with open(p) as f:
            return f.read().strip()
    except OSError:
        sys.exit('no TOKEN in env and no ' + p)


class Bridge:
    def __init__(self, base, token):
        self.base = base.rstrip('/')
        self.token = token

    def _req(self, path, body=None, timeout=5):
        url = self.base + path + ('&' if '?' in path else '?') + 'k=' + self.token
        data = None
        headers = {}
        if body is not None:
            data = json.dumps(body).encode()
            headers['Content-Type'] = 'application/json'
        r = urllib.request.Request(url, data=data, headers=headers)
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            ct = resp.headers.get('Content-Type', '')
            raw = resp.read()
            return json.loads(raw) if ct.startswith('application/json') else raw

    def sensors(self):
        return self._req('/api/sensors')

    def frame(self):
        return self._req('/api/sensors/frame.jpg')

    def push_state(self, state):
        return self._req('/api/count/state', body=state)


def camera_motion(prev_small, cur_small):
    """Frame-to-frame translation of the whole picture, in *small* pixels.

    Phase correlation is the cheapest global-motion estimate there is and it is exactly
    right for a head-mounted camera looking at a mostly static table: the table moves as
    one, the response is high; when a hand sweeps through, the response drops and we
    ignore it rather than drag every track sideways."""
    (dx, dy), response = cv2.phaseCorrelate(prev_small, cur_small)
    if response < 0.08:
        return 0.0, 0.0
    return dx, dy


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bridge', default=os.environ.get('BRIDGE', 'http://127.0.0.1:8791'))
    ap.add_argument('--decks', type=int, default=int(os.environ.get('DECKS', '6')))
    ap.add_argument('--save', default=None, help='directory to keep every processed frame in')
    ap.add_argument('--keep-counted', default=os.path.join(HERE, 'out', 'counted'),
                    help='directory for the frame each card was counted on (annotated); "" to disable')
    ap.add_argument('--verbose', '-v', action='store_true')
    args = ap.parse_args()

    bridge = Bridge(args.bridge, read_token())
    detector = CardDetector()
    tracker = CountOnceTracker(decks=args.decks)
    if args.save:
        os.makedirs(args.save, exist_ok=True)
    if args.keep_counted:
        os.makedirs(args.keep_counted, exist_ok=True)

    last_seq = 0
    last_reset_epoch = None
    prev_small = None
    processed = 0
    t_window = time.time()
    fps = 0.0
    last_push = 0.0
    last_err = None
    print('count worker → ' + args.bridge, flush=True)

    while True:
        try:
            s = bridge.sensors()
        except Exception as e:  # bridge down or restarting: wait, don't spin
            msg = str(e)
            if msg != last_err:
                print('bridge unreachable: ' + msg, flush=True)
                last_err = msg
            time.sleep(1.0)
            continue
        last_err = None
        fr = s.get('frame')
        seq = fr['seq'] if fr else 0
        now = time.time()

        if seq > last_seq:
            try:
                raw = bridge.frame()
            except Exception:
                time.sleep(0.1)
                continue
            last_seq = seq
            frame = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
            if frame is None:
                continue
            if args.save:
                cv2.imwrite(os.path.join(args.save, 'f%06d.jpg' % seq), frame)

            grey = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            scale = 160.0 / grey.shape[1]
            small = cv2.resize(grey, None, fx=scale, fy=scale).astype(np.float32)
            if prev_small is not None and prev_small.shape == small.shape:
                dx, dy = camera_motion(prev_small, small)
                tracker.shift(dx / scale, dy / scale)
            prev_small = small

            cards = detector.detect(frame)
            counted = tracker.update(cards, now)
            processed += 1
            if args.verbose and (cards or counted):
                print('#%d  %d quads  %s  %s' % (
                    seq, len(cards),
                    ' '.join((c.rank or '?') + ('' if c.margin > 4 else '~') for c in cards),
                    ('COUNTED ' + ' '.join(t.rank for t in counted)) if counted else ''), flush=True)
            for t in counted:
                print('counted %s%s → running %+d, true %+.1f (%d seen, %.1f decks left)' % (
                    t.rank, (' of ' + t.suit) if t.suit else '', tracker.running,
                    tracker.true_count(), tracker.seen, tracker.decks_left()), flush=True)
            # Keep the frame each count happened on, with the quads drawn. Every false count
            # so far was diagnosed from exactly this, and every real-table tuning session
            # will want it. Bounded: a shoe is a few hundred cards, ~50 KB each.
            if counted and args.keep_counted:
                out = frame.copy()
                for c in cards:
                    cv2.polylines(out, [c.quad.astype(np.int32)], True, (0, 220, 0) if c.rank else (0, 0, 255), 2)
                    cv2.putText(out, (c.rank or '?') + ' %.0f/%.0f' % (c.score, c.margin),
                                (int(c.center[0]) - 20, int(c.center[1])), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
                cv2.imwrite(os.path.join(args.keep_counted, 'seq%06d_%s.jpg' % (seq, '-'.join(t.rank for t in counted))), out)

        if now - t_window >= 2.0:
            fps = processed / (now - t_window)
            processed = 0
            t_window = now

        # Push state ~4×/s whether or not a frame arrived, so the glasses can tell a
        # stalled stream from a dead worker: the worker heartbeat stays fresh while
        # frameSeq stops moving.
        if now - last_push >= 0.25:
            state = tracker.snapshot()
            state.update({'fps': round(fps, 1), 'frameSeq': last_seq,
                          'frameAgeMs': int(now * 1000 - fr['at']) if fr else None})
            try:
                reply = bridge.push_state(state)
                ctl = reply.get('control', {}) if isinstance(reply, dict) else {}
                epoch = ctl.get('resetEpoch')
                if last_reset_epoch is None:
                    last_reset_epoch = epoch
                elif epoch is not None and epoch != last_reset_epoch:
                    last_reset_epoch = epoch
                    tracker.reset()
                    print('reset (shuffle)', flush=True)
                decks = ctl.get('decks')
                if isinstance(decks, (int, float)) and decks != tracker.decks:
                    tracker.decks = decks
                    print('decks → %s' % decks, flush=True)
            except Exception as e:
                if args.verbose:
                    print('push failed: ' + str(e), flush=True)
            last_push = now

        time.sleep(0.05 if seq > last_seq else 0.1)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
