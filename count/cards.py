"""Card identity, Hi-Lo values, and the glyph templates the detector matches against.

Hi-Lo is **suit-blind and coarse**: 2-6 are +1, 7-9 are 0, ten-through-ace are -1. That
matters far more than it sounds, and it is the reason this pipeline is tractable at all on
a 3 fps head-mounted camera:

  - A suit never has to be read correctly. The count cannot be wrong because a heart was
    called a diamond. Suits are read anyway (they make a misread obvious to a human
    watching the display) but no arithmetic depends on them.
  - A rank only has to land in the right *bucket*. Confusing a jack for a queen costs
    nothing. Only bucket-crossing confusions matter, and there are few of them that are
    also visually plausible — 6/7 is the one to actually worry about, which is why
    `detect.py` reports a margin and `track.py` refuses to count a card on a thin one.

So the accuracy target is not "read 52 cards"; it is "put each card in one of three
buckets, and know when you are unsure". Everything downstream is built around that.
"""

import os

import cv2
import numpy as np

# "10" is deliberately two characters — its corner glyph is twice as wide as any other
# rank, which makes it the easiest card on the table to identify and, conveniently, one
# of the -1s we most want to get right.
RANKS = ['A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K']
SUITS = ['spades', 'hearts', 'diamonds', 'clubs']

# Hi-Lo. The values are the system; do not "improve" them.
HILO = {
    '2': +1, '3': +1, '4': +1, '5': +1, '6': +1,
    '7': 0, '8': 0, '9': 0,
    '10': -1, 'J': -1, 'Q': -1, 'K': -1, 'A': -1,
}

# Template canvases. Matching normalises every candidate glyph into these boxes, so the
# numbers only have to be consistent between build and match time — they are not physical.
RANK_W, RANK_H = 70, 125
SUIT_W, SUIT_H = 70, 100

TEMPLATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'templates')


def hilo_delta(rank):
    """The running-count contribution of a rank, or 0 for anything unrecognised."""
    return HILO.get(rank, 0)


def bucket(rank):
    """'low' | 'neutral' | 'high' | 'unknown' — what Hi-Lo actually cares about."""
    if rank not in HILO:
        return 'unknown'
    return {1: 'low', 0: 'neutral', -1: 'high'}[HILO[rank]]


# ---------------------------------------------------------------------------
# Synthetic templates
#
# The reference implementations of this trick all ship templates cropped from photographs
# of one specific deck under one specific lamp. That is a better matcher and a worse
# starting point: it cannot be regenerated, and it silently encodes someone else's
# lighting. These are drawn from scratch instead, so the pipeline runs the moment it is
# checked out, and `tools/mktemplates.py --from-frames` replaces them with glyphs cropped
# from real frames off the glasses once there are any. Treat these as the bootstrap, not
# the final answer: a stroke font is not a card font, and the suit shapes below are
# approximations of the pips, not the pips.
# ---------------------------------------------------------------------------

def _rank_template(rank):
    """Draw a rank glyph, then crop and stretch it exactly as the matcher will."""
    canvas = np.zeros((220, 200), dtype=np.uint8)
    # DUPLEX is the least stylised Hershey face available, which is the closest a stroke
    # font gets to the plain serif on a card corner.
    font = cv2.FONT_HERSHEY_DUPLEX
    scale = 3.4 if len(rank) == 1 else 2.6   # keep "10" inside the canvas
    (w, h), _ = cv2.getTextSize(rank, font, scale, 6)
    cv2.putText(canvas, rank, ((200 - w) // 2, (220 + h) // 2), font, scale, 255, 6, cv2.LINE_AA)
    return _fit(canvas, RANK_W, RANK_H)


def _suit_template(suit):
    """Draw a pip. Circles and polygons get close enough to a silhouette match."""
    c = np.zeros((220, 200), dtype=np.uint8)
    cx = 100
    if suit == 'diamonds':
        cv2.fillPoly(c, [np.array([[cx, 30], [175, 110], [cx, 190], [25, 110]])], 255)
    elif suit == 'hearts':
        cv2.circle(c, (cx - 38, 90), 45, 255, -1)
        cv2.circle(c, (cx + 38, 90), 45, 255, -1)
        cv2.fillPoly(c, [np.array([[25, 105], [175, 105], [cx, 195]])], 255)
    elif suit == 'spades':
        # A spade is a heart upside down with a stem.
        cv2.circle(c, (cx - 38, 130), 45, 255, -1)
        cv2.circle(c, (cx + 38, 130), 45, 255, -1)
        cv2.fillPoly(c, [np.array([[25, 115], [175, 115], [cx, 25]])], 255)
        cv2.fillPoly(c, [np.array([[cx - 28, 195], [cx + 28, 195], [cx + 10, 150], [cx - 10, 150]])], 255)
    elif suit == 'clubs':
        cv2.circle(c, (cx, 70), 42, 255, -1)
        cv2.circle(c, (cx - 48, 130), 42, 255, -1)
        cv2.circle(c, (cx + 48, 130), 42, 255, -1)
        cv2.fillPoly(c, [np.array([[cx - 28, 195], [cx + 28, 195], [cx + 10, 140], [cx - 10, 140]])], 255)
    return _fit(c, SUIT_W, SUIT_H)


def _fit(binary, w, h):
    """Crop to the ink and stretch to (w, h).

    Both the template and the candidate go through this, which is what makes the match
    scale- and position-invariant — the glyph off a warped card is never the same size as
    the drawn one. Aspect ratio is deliberately *not* preserved: stretching to a fixed box
    is what keeps "10" (wide) separable from "1"-like glyphs, and it is what the candidate
    side does too, so the two agree.
    """
    pts = cv2.findNonZero(binary)
    if pts is None:
        return np.zeros((h, w), dtype=np.uint8)
    x, y, bw, bh = cv2.boundingRect(pts)
    return cv2.resize(binary[y:y + bh, x:x + bw], (w, h), interpolation=cv2.INTER_AREA)


def build_templates(out_dir=TEMPLATE_DIR):
    """Draw and write every template. Idempotent; safe to re-run."""
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for r in RANKS:
        p = os.path.join(out_dir, 'rank_' + r + '.png')
        cv2.imwrite(p, _rank_template(r))
        written.append(p)
    for s in SUITS:
        p = os.path.join(out_dir, 'suit_' + s + '.png')
        cv2.imwrite(p, _suit_template(s))
        written.append(p)
    return written


def load_templates(out_dir=TEMPLATE_DIR):
    """Load templates, drawing them first if the directory is empty.

    Returns (ranks, suits) as {name: uint8 array}. Missing files are skipped rather than
    fatal, so a hand-curated directory holding only the ranks that matter still works.
    """
    if not os.path.isdir(out_dir) or not os.listdir(out_dir):
        build_templates(out_dir)
    ranks, suits = {}, {}
    for r in RANKS:
        img = cv2.imread(os.path.join(out_dir, 'rank_' + r + '.png'), cv2.IMREAD_GRAYSCALE)
        if img is not None:
            ranks[r] = cv2.resize(img, (RANK_W, RANK_H), interpolation=cv2.INTER_AREA)
    for s in SUITS:
        img = cv2.imread(os.path.join(out_dir, 'suit_' + s + '.png'), cv2.IMREAD_GRAYSCALE)
        if img is not None:
            suits[s] = cv2.resize(img, (SUIT_W, SUIT_H), interpolation=cv2.INTER_AREA)
    return ranks, suits


if __name__ == '__main__':
    files = build_templates()
    print('wrote ' + str(len(files)) + ' templates to ' + TEMPLATE_DIR)
