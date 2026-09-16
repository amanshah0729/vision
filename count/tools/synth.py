"""Draw a fake table with known cards, so the whole pipeline can be exercised with no glasses.

    python count/tools/synth.py --out /tmp/synth --frames 12

Writes a short sequence: cards dealt one at a time onto a green felt, with a little camera
jitter and perspective, plus the ground-truth ranks in labels.txt. `replay.py --track` on
the output should count exactly those cards, once each. This proves the plumbing — quad
finding, warp, corner read, tracking, Hi-Lo — not the detector's accuracy on real cards,
which only real frames can (see grab.py).
"""

import argparse
import os
import random
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import cards   # noqa: E402


def draw_card(rank, suit, w=120, h=168):
    img = np.full((h, w, 3), 245, np.uint8)
    cv2.rectangle(img, (0, 0), (w - 1, h - 1), (200, 200, 200), 1)
    red = suit in ('hearts', 'diamonds')
    colour = (30, 30, 200) if red else (20, 20, 20)
    font = cv2.FONT_HERSHEY_DUPLEX
    scale = 0.95 if len(rank) == 1 else 0.6
    cv2.putText(img, rank, (7, 30), font, scale, colour, 2, cv2.LINE_AA)
    # A pip below the rank in the corner, drawn from the same shapes as the templates so
    # the synthetic test is self-consistent. Real pips differ; that is what learn is for.
    pip = cards._suit_template(suit)
    pip = cv2.resize(pip, (14, 18))
    y0, x0 = 36, 9
    roi = img[y0:y0 + 18, x0:x0 + 14]
    roi[pip > 127] = colour
    # Real cards carry the index in both opposite corners, rotated; the detector requires it.
    rot = cv2.rotate(img.copy(), cv2.ROTATE_180)
    img[h // 2:, :] = rot[h // 2:, :]
    # A big centre pip so the card face is not blank.
    big = cv2.resize(cards._suit_template(suit), (40, 52))
    roi = img[h // 2 - 26:h // 2 + 26, w // 2 - 20:w // 2 + 20]
    roi[big > 127] = colour
    return img


def place(table, card, cx, cy, angle, tilt):
    h, w = card.shape[:2]
    src = np.array([[0, 0], [w, 0], [w, h], [0, h]], np.float32)
    # Rotate in-plane, then squash vertically for a seat-height perspective.
    ca, sa = np.cos(angle), np.sin(angle)
    pts = []
    for x, y in src:
        x -= w / 2
        y -= h / 2
        xr, yr = x * ca - y * sa, x * sa + y * ca
        pts.append([cx + xr, cy + yr * tilt])
    dst = np.array(pts, np.float32)
    m = cv2.getPerspectiveTransform(src, dst)
    warped = cv2.warpPerspective(card, m, (table.shape[1], table.shape[0]), borderValue=(0, 0, 0))
    mask = cv2.warpPerspective(np.full((h, w), 255, np.uint8), m, (table.shape[1], table.shape[0]))
    table[mask > 0] = warped[mask > 0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='/tmp/synth')
    ap.add_argument('--frames', type=int, default=12)
    ap.add_argument('--seed', type=int, default=7)
    args = ap.parse_args()
    random.seed(args.seed)
    os.makedirs(args.out, exist_ok=True)
    deal = [('6', 'hearts'), ('K', 'spades'), ('10', 'diamonds'), ('3', 'clubs'), ('A', 'hearts'), ('8', 'spades')]
    slots = [(100, 280), (250, 300), (400, 280), (100, 620), (250, 650), (400, 620)]
    W, H = 504, 896
    with open(os.path.join(args.out, 'labels.txt'), 'w') as lab:
        for r, s in deal:
            lab.write(r + ' ' + s + '\n')
    for i in range(args.frames):
        table = np.zeros((H, W, 3), np.uint8)
        table[:] = (40, 110, 40)
        noise = np.random.randint(0, 18, (H, W, 1), np.uint8)
        table = cv2.add(table, np.repeat(noise, 3, axis=2))
        # camera jitter: the whole scene shifts a few px per frame
        jx, jy = random.randint(-6, 6), random.randint(-6, 6)
        # one new card every two frames
        for k, ((r, s), (cx, cy)) in enumerate(zip(deal, slots)):
            if i >= k * 2:
                ang = random.uniform(-0.15, 0.15) + 0.05 * k
                place(table, draw_card(r, s), cx + jx, cy + jy, ang, 0.82)
        cv2.imwrite(os.path.join(args.out, 'f%06d.jpg' % i), table, [cv2.IMWRITE_JPEG_QUALITY, 60])
    print('wrote %d frames to %s; expected count: %s' % (
        args.frames, args.out, ' '.join(r for r, _ in deal)))
    run = sum(cards.hilo_delta(r) for r, _ in deal)
    print('expected running count %+d' % run)


if __name__ == '__main__':
    main()
