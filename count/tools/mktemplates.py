"""Build rank/suit templates — synthetic by default, from real glasses frames when you have them.

    python count/tools/mktemplates.py                         # (re)draw the synthetic set
    python count/tools/mktemplates.py learn f000123.jpg 7 hearts
    python count/tools/mktemplates.py learn f000140.jpg 10
    python count/tools/mktemplates.py learn f000151.jpg Q spades

`learn` takes a frame holding ONE clearly visible card (hold it up to the glasses, or lay
it alone on the table), finds it, cuts the corner glyphs exactly as the detector would at
match time, and writes them as the template for that rank (and suit, if given). Do it for
thirteen ranks and four suits with the deck the table actually uses and the synthetic
bootstrap is gone. Ten minutes at home; that is the whole "training".

Templates live in count/templates/ (gitignored: they belong to a deck, not the repo).
"""

import os
import sys

import cv2

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import cards                                                      # noqa: E402
from detect import CardDetector, CORNER_W, CORNER_H, CORNER_ZOOM, _warp, _split_corner, _order   # noqa: E402


def learn(path, rank, suit=None):
    if rank not in cards.RANKS:
        sys.exit('rank must be one of ' + ' '.join(cards.RANKS))
    if suit and suit not in cards.SUITS:
        sys.exit('suit must be one of ' + ' '.join(cards.SUITS))
    frame = cv2.imread(path)
    if frame is None:
        sys.exit('cannot read ' + path)
    det = CardDetector(max_area_frac=0.6)   # the card is held up close here
    dbg = {}
    det.detect(frame, debug=dbg)
    quads = dbg.get('quads', [])
    if not quads:
        sys.exit('no card-shaped quad found in ' + path + ' — is the card alone and well lit?')
    # Largest quad: the card being held up is the closest thing to the camera.
    quad = max(quads, key=lambda q: cv2.contourArea(q))
    grey = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    warped = _warp(grey, _order(quad))
    best = None
    for flipped in (False, True):
        img = warped if not flipped else cv2.rotate(warped, cv2.ROTATE_180)
        corner = cv2.resize(img[0:CORNER_H, 0:CORNER_W], None, fx=CORNER_ZOOM, fy=CORNER_ZOOM, interpolation=cv2.INTER_CUBIC)
        _, binary = cv2.threshold(corner, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        r, s = _split_corner(binary)
        ink = int((r > 0).sum()) if r is not None else 0
        if r is not None and (best is None or ink > best[0]):
            best = (ink, r, s)
    if best is None:
        sys.exit('found the card but could not isolate a corner glyph')
    _, r, s = best
    os.makedirs(cards.TEMPLATE_DIR, exist_ok=True)
    p = os.path.join(cards.TEMPLATE_DIR, 'rank_' + rank + '.png')
    cv2.imwrite(p, cards._fit(r, cards.RANK_W, cards.RANK_H))
    print('wrote ' + p)
    if suit:
        if s is None:
            print('no suit pip isolated in this frame; rank written, suit skipped')
        else:
            p = os.path.join(cards.TEMPLATE_DIR, 'suit_' + suit + '.png')
            cv2.imwrite(p, cards._fit(s, cards.SUIT_W, cards.SUIT_H))
            print('wrote ' + p)


if __name__ == '__main__':
    a = sys.argv[1:]
    if a and a[0] == 'learn':
        if len(a) < 3:
            sys.exit(__doc__)
        learn(a[1], a[2], a[3] if len(a) > 3 else None)
    else:
        files = cards.build_templates()
        print('drew %d synthetic templates in %s' % (len(files), cards.TEMPLATE_DIR))
