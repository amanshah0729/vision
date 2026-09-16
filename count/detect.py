"""Find playing cards in a frame and read their rank (and, best-effort, suit).

Classical CV, no model. The reasoning: a card is the single most detector-friendly object
on a table — a bright, rigid, convex quadrilateral with a high-contrast glyph in a known
corner. A quad detector plus a corner-glyph matcher gets most of the way on that alone,
it runs in a few milliseconds per frame on the Air, and it can be tuned by looking at one
saved frame rather than by retraining. A YOLO-class detector may end up better on a real
casino table; if so it slots in behind the same `detect(frame) -> [Card]` interface and
nothing else changes. Start here, measure with `tools/replay.py`, then decide.

Pipeline per frame:
  1. grey → blur → adaptive threshold. Adaptive, not global: a table under a spotlight has
     a brightness gradient that one Otsu level cannot follow, and the glasses' auto-exposure
     drifts between frames.
  2. external contours → keep convex 4-gons in a plausible area/aspect band.
  3. perspective-warp each to a canonical portrait card.
  4. cut the top-left corner, split it into rank (top) and suit (bottom) blobs, and match
     each against the templates by absolute difference. Try the corner both ways up — a
     card dealt "upside down" has its readable corner at the bottom-right.
  5. report rank, suit, the *margin* between best and second-best rank, and geometry.

The margin is the important output. Downstream, a card is only counted once the margin is
comfortably positive, because in Hi-Lo the only misreads that cost anything are the ones
that cross a bucket boundary, and those are exactly the low-margin ones (6↔7, 9↔10).
"""

import cv2
import numpy as np

from cards import RANK_W, RANK_H, SUIT_W, SUIT_H, load_templates

# Canonical warped card. 2.5:3.5 is a real poker card; 200×300 is a convenient multiple.
CARD_W, CARD_H = 200, 300
# The corner index of a poker card sits inside roughly the top-left 24% × 30%. Wider than
# the index itself on purpose: a warp is never pixel-perfect and a clipped "K" reads as
# an "8". The centre pips start at ~30% so this still cannot catch one.
CORNER_W, CORNER_H = 48, 92
# Corner glyphs are read at 4× so the rank/suit split and the crop have pixels to work with.
CORNER_ZOOM = 4


class Card:
    __slots__ = ('rank', 'suit', 'score', 'second', 'margin', 'suit_score', 'center', 'quad',
                 'area', 'flipped')

    def __init__(self, rank, suit, score, second, suit_score, center, quad, area, flipped):
        self.rank = rank            # 'A'..'K' or None if nothing matched sanely
        self.suit = suit            # 'hearts'.. or None
        self.score = score          # best rank diff (lower is better)
        self.second = second        # runner-up rank diff
        self.margin = second - score if rank else 0.0
        self.suit_score = suit_score
        self.center = center        # (x, y) in frame pixels
        self.quad = quad            # 4×2 float32, frame pixels, ordered TL,TR,BR,BL
        self.area = area
        self.flipped = flipped      # True if read from the rotated corner

    def as_dict(self):
        return {
            'rank': self.rank, 'suit': self.suit,
            'score': round(float(self.score), 1), 'margin': round(float(self.margin), 1),
            'x': int(self.center[0]), 'y': int(self.center[1]), 'area': int(self.area),
        }


class CardDetector:
    # Area band is in fractions of the frame. A card at seat distance through the glasses is
    # 0.5–2% of a 504×896 frame. Monitors, laptops, phones and paper in a real room came in
    # at 8% and up and read as face cards with wide margins, so the cap is deliberately
    # tight. `tools/mktemplates.py learn` raises it, because there the card is held up.
    def __init__(self, min_area_frac=0.002, max_area_frac=0.04, template_dir=None):
        self.min_area_frac = min_area_frac
        self.max_area_frac = max_area_frac
        self.ranks, self.suits = load_templates(template_dir) if template_dir else load_templates()

    # ------------------------------------------------------------------ detect

    def detect(self, frame, debug=None):
        """Return a list of Card for a BGR frame. `debug`, if a dict, is filled with
        intermediates (thresh, quads) for tools/replay.py to draw."""
        h, w = frame.shape[:2]
        frame_area = float(h * w)
        grey = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        blur = cv2.GaussianBlur(grey, (5, 5), 0)
        # Block size ~ a card's short side at this resolution; the offset pulls the
        # threshold below local mean so felt texture does not fragment into blobs.
        block = max(31, (min(h, w) // 8) | 1)
        thresh = cv2.adaptiveThreshold(blur, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                       cv2.THRESH_BINARY, block, -12)
        # Cards touch each other in a dealt hand; a small open breaks the bridges.
        thresh = cv2.morphologyEx(thresh, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))

        contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cards, quads = [], []
        for cnt in contours:
            area = cv2.contourArea(cnt)
            if area < frame_area * self.min_area_frac or area > frame_area * self.max_area_frac:
                continue
            peri = cv2.arcLength(cnt, True)
            approx = cv2.approxPolyDP(cnt, 0.04 * peri, True)
            if len(approx) != 4 or not cv2.isContourConvex(approx):
                continue
            quad = _order(approx.reshape(4, 2).astype(np.float32))
            if not _card_shaped(quad):
                continue
            quads.append(quad)
            warped = _warp(grey, quad)
            if not _looks_like_card_face(warped):
                continue
            read = self._read_corner(warped)
            if read is None:
                continue
            rank, score, second, suit, suit_score, flipped = read
            cx, cy = quad.mean(axis=0)
            cards.append(Card(rank, suit, score, second, suit_score, (cx, cy), quad, area, flipped))

        if isinstance(debug, dict):
            debug['thresh'] = thresh
            debug['quads'] = quads
        return cards

    # ------------------------------------------------------------- corner read

    def _read_corner(self, warped):
        """Read the top-left corner and the bottom-right one rotated 180°.

        A real card prints the same index in both, so both reads must land on the same
        rank or it is not a card. This is the single strongest thing separating a card
        from every other white rectangle with a mark in the corner (a monitor showing a
        document passed every other filter and read as a K with a wide margin). A hand of
        overlapped cards hides the second corner, but then it is not a clean 4-gon either
        and never reaches this point, so nothing this detector could do is lost."""
        reads = []
        for flipped in (False, True):
            img = warped if not flipped else cv2.rotate(warped, cv2.ROTATE_180)
            corner = img[0:CORNER_H, 0:CORNER_W]
            corner = cv2.resize(corner, None, fx=CORNER_ZOOM, fy=CORNER_ZOOM, interpolation=cv2.INTER_CUBIC)
            # Card-local Otsu: the corner is white paper with black ink, so a global
            # split works here even though it did not on the whole frame.
            _, binary = cv2.threshold(corner, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
            rank_img, suit_img = _split_corner(binary)
            # No pip under the rank means this is not a card index. Every real corner has
            # one, and the false positives in a real room (monitors, labels, stickers)
            # consistently lacked it. The suit's *identity* is still best-effort.
            if rank_img is None or suit_img is None:
                continue
            rank, score, second = self._match(rank_img, self.ranks, RANK_W, RANK_H)
            suit, suit_score = (None, 1e9)
            if suit_img is not None and self.suits:
                suit, suit_score, _ = self._match(suit_img, self.suits, SUIT_W, SUIT_H)
            reads.append((rank, score, second, suit, suit_score, flipped))
        if len(reads) < 2:
            return None
        a, b = sorted(reads, key=lambda r: r[1])
        rank, score, second, suit, suit_score, flipped = a
        # Beyond this the "match" is noise on noise. Keep the geometry (the tracker still
        # wants to know a card is there) but do not claim a rank. Likewise when the two
        # corners disagree: report the quad, withhold the rank, let the tracker wait.
        if score > MAX_SANE_SCORE or b[1] > MAX_SANE_SCORE or a[0] != b[0]:
            rank = None
        # The margin the tracker sees is the weaker corner's, so one lucky corner cannot
        # carry a card over the counting bar on its own.
        second = min(second, score + (b[2] - b[1]))
        return rank, score, second, suit, suit_score, flipped

    @staticmethod
    def _match(glyph, templates, w, h):
        pts = cv2.findNonZero(glyph)
        if pts is None:
            return None, 1e9, 1e9
        x, y, bw, bh = cv2.boundingRect(pts)
        fitted = cv2.resize(glyph[y:y + bh, x:x + bw], (w, h), interpolation=cv2.INTER_AREA)
        scored = sorted(
            (float(cv2.absdiff(fitted, t).sum()) / 255.0 / (w * h) * 100.0, name)
            for name, t in templates.items()
        )
        best_score, best = scored[0]
        second = scored[1][0] if len(scored) > 1 else 1e9
        return best, best_score, second


# Percentage of mismatched pixels above which a read is declared meaningless.
MAX_SANE_SCORE = 45.0


# ------------------------------------------------------------------- geometry

def _order(pts):
    """TL, TR, BR, BL — by the usual sum/diff trick."""
    s = pts.sum(axis=1)
    d = np.diff(pts, axis=1).ravel()
    return np.array([pts[np.argmin(s)], pts[np.argmin(d)], pts[np.argmax(s)], pts[np.argmax(d)]],
                    dtype=np.float32)


def _card_shaped(quad):
    """Reject quads whose side ratio a card could not produce even under perspective.

    A poker card is 1:1.4. Seen from a seat it foreshortens, so anything from about 1:1.1
    to 1:2.6 is admitted; squarer than that is a chip stack or a phone, longer is a gap
    between two cards read as one."""
    tl, tr, br, bl = quad
    top, bottom = np.linalg.norm(tr - tl), np.linalg.norm(br - bl)
    left, right = np.linalg.norm(bl - tl), np.linalg.norm(br - tr)
    a = (top + bottom) / 2.0
    b = (left + right) / 2.0
    if min(a, b) < 12:
        return False
    ratio = max(a, b) / min(a, b)
    return 1.1 <= ratio <= 2.6


def _warp(grey, quad):
    """Warp to a portrait canonical card. If the quad is landscape, rotate the point order
    so the long side ends up vertical — the corner index is at the top of the *long* edge."""
    tl, tr, br, bl = quad
    wide = np.linalg.norm(tr - tl) > np.linalg.norm(bl - tl)
    if wide:
        src = np.array([bl, tl, tr, br], dtype=np.float32)
    else:
        src = quad
    dst = np.array([[0, 0], [CARD_W - 1, 0], [CARD_W - 1, CARD_H - 1], [0, CARD_H - 1]], dtype=np.float32)
    m = cv2.getPerspectiveTransform(src, dst)
    return cv2.warpPerspective(grey, m, (CARD_W, CARD_H))


def _looks_like_card_face(warped):
    """Cheap rejection of bright rectangles that are not cards: screens, paper, boxes.

    On every real card the band along the top edge to the right of the corner index is
    plain white — pips start lower and face-card frames start further in. A screen or a
    printed page has ink there. One threshold on that band's dark fraction is a strong
    filter and costs nothing."""
    band = warped[0:int(CARD_H * 0.08), int(CARD_W * 0.30):int(CARD_W * 0.72)]
    _, dark = cv2.threshold(band, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    # Otsu on a plain white band will happily split paper grain into two halves, so
    # only trust it when there is real contrast to split.
    if band.max() - band.min() < 60:
        return True
    return (dark > 0).mean() < 0.15


def _split_corner(binary):
    """Separate the rank (upper blob) from the suit (lower blob) in a zoomed corner.

    Uses the row profile: the gap between rank and pip is the widest run of empty rows.
    Returns (rank_img, suit_img); suit may be None when the pip is off the crop or merged."""
    # Drop the outer 6% — the warp edge often carries a sliver of table or of the
    # neighbouring card, and it reads as a false vertical stroke.
    h, w = binary.shape
    my, mx = int(h * 0.07), int(w * 0.08)
    binary = binary.copy()
    binary[:my, :] = 0
    binary[:, :mx] = 0
    binary[:, w - mx:] = 0
    rows = (binary > 0).sum(axis=1)
    ink = np.where(rows > 0)[0]
    if ink.size < 8:
        return None, None
    top, bottom = int(ink[0]), int(ink[-1])
    # A card corner is two stacked blobs: the rank and, below it, the pip. Anything with
    # more vertical ink runs than that is lines of text, not a card index.
    runs = int(((rows[top:bottom + 1] > 0).astype(np.int8)[1:] - (rows[top:bottom + 1] > 0).astype(np.int8)[:-1] == 1).sum()) + 1
    if runs > 3:
        return None, None
    # Longest empty gap strictly inside the ink extent — that's the rank/suit boundary.
    best_gap, gap_at = 0, None
    run_start = None
    for y in range(top, bottom + 1):
        if rows[y] == 0:
            if run_start is None:
                run_start = y
        elif run_start is not None:
            if y - run_start > best_gap:
                best_gap, gap_at = y - run_start, run_start + (y - run_start) // 2
            run_start = None
    if gap_at is None or best_gap < 2:
        # A single blob: the pip was cut off (or merged with the rank). Rank only.
        return binary[top:bottom + 1], None
    rank_img = binary[top:gap_at]
    suit_img = binary[gap_at:bottom + 1]
    # Sanity: the rank should hold more ink than a speck.
    if (rank_img > 0).sum() < 30:
        return None, None
    if (suit_img > 0).sum() < 30:
        suit_img = None
    return rank_img, suit_img
