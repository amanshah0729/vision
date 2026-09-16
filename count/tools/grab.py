"""Save frames off the bridge to disk — how a real-table dataset gets collected.

    count/.venv/bin/python count/tools/grab.py --seconds 120 --out count/frames/table1

Start the stream first (from count.html or look.html, or with tools/stream.sh). Every new
frame is written as f<seq>.jpg. The frames are what tools/replay.py and
tools/mktemplates.py consume, and they are the only way to tune the detector for a room
the agent has never been in. Frames are private: count/frames/ is gitignored.
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from worker import Bridge, read_token   # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bridge', default=os.environ.get('BRIDGE', 'http://127.0.0.1:8791'))
    ap.add_argument('--out', default='count/frames/' + time.strftime('%Y%m%d-%H%M%S'))
    ap.add_argument('--seconds', type=float, default=60)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    b = Bridge(args.bridge, read_token())
    last, n, t0 = 0, 0, time.time()
    print('grabbing to ' + args.out + ' for %.0fs' % args.seconds)
    while time.time() - t0 < args.seconds:
        s = b.sensors()
        fr = s.get('frame')
        if fr and fr['seq'] > last:
            last = fr['seq']
            raw = b.frame()
            with open(os.path.join(args.out, 'f%06d.jpg' % last), 'wb') as f:
                f.write(raw)
            n += 1
            if n % 20 == 0:
                print('  %d frames (%.1f fps)' % (n, n / (time.time() - t0)), flush=True)
        time.sleep(0.08)
    print('saved %d frames' % n)


if __name__ == '__main__':
    main()
