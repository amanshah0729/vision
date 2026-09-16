"""Count each card exactly once, from a camera that never holds still.

The detector says "there is a 6 at (312, 540)" three times a second. The problems are
that the same 6 will be reported thirty times before it is swept, that the glasses are on
a head so (312, 540) drifts every frame, that a hand will hide it for a second and then it
is back, and that a bad frame will call it a 5 once. `CountOnceTracker` turns that stream
into "a 6 was dealt", once.

How:
  - Every detection is matched to the nearest existing track within a radius scaled to
    the card's own size. Track positions are first shifted by the frame-to-frame camera
    motion (phase correlation on the whole frame, see `worker.py`), which is what keeps a
    track glued to its card while the wearer's head moves.
  - A track accumulates rank votes. It is counted when it has been seen in enough frames,
    its majority rank has enough of the votes, and the mean detector margin is over the
    bar. Thin-margin reads wait; they usually firm up within a frame or two, and if they
    never do the card is simply not counted, which is the honest outcome.
  - A counted track keeps existing, and keeps suppressing, until it has been unseen for
    long enough to be gone. That window is generous (seconds), because a hand pausing over
    the table is the common case and a genuine sweep-and-redeal at the same spot is rare
    and slow.

Errors this does not solve: a card that is never read at all (occluded, glare, off-frame)
is not counted. That is a detector gap, and `tools/replay.py` exists to measure it. There
is no attempt to guess unseen cards.
"""

import time
from collections import Counter

from cards import hilo_delta, HILO


class Track:
    __slots__ = ('id', 'x', 'y', 'size', 'votes', 'margins', 'seen', 'first', 'last', 'counted',
                 'rank', 'suit', 'suit_votes')

    def __init__(self, tid, card, now):
        self.id = tid
        self.x, self.y = card.center
        self.size = card.area ** 0.5
        self.votes = Counter()
        self.suit_votes = Counter()
        self.margins = []
        self.seen = 0
        self.first = now
        self.last = now
        self.counted = False
        self.rank = None
        self.suit = None
        self.absorb(card, now)

    def absorb(self, card, now):
        # Exponential smoothing on position: one jittery detection should not yank a track
        # out from under its next frame.
        self.x = 0.6 * self.x + 0.4 * card.center[0]
        self.y = 0.6 * self.y + 0.4 * card.center[1]
        self.size = 0.7 * self.size + 0.3 * card.area ** 0.5
        self.seen += 1
        self.last = now
        if card.rank:
            self.votes[card.rank] += 1
            self.margins.append(card.margin)
        if card.suit:
            self.suit_votes[card.suit] += 1

    def majority(self):
        if not self.votes:
            return None, 0.0
        rank, n = self.votes.most_common(1)[0]
        return rank, n / float(sum(self.votes.values()))


class CountOnceTracker:
    def __init__(self, decks=6, min_frames=3, min_agreement=0.66, min_margin=4.0,
                 forget_s=6.0, match_radius=1.1):
        self.decks = decks
        self.min_frames = min_frames
        self.min_agreement = min_agreement
        self.min_margin = min_margin
        self.forget_s = forget_s
        self.match_radius = match_radius
        self.reset()

    # -------------------------------------------------------------- state

    def reset(self, decks=None):
        if decks is not None:
            self.decks = decks
        self.tracks = []
        self.next_id = 1
        self.running = 0
        self.seen = 0
        self.recent = []          # last few counted cards, newest last, for the display
        self.reset_at = time.time()

    def decks_left(self):
        # Floor at half a deck: the true count is a ratio and the last few cards of a shoe
        # would otherwise send it to infinity. Any real shoe has a cut card well before this.
        return max(0.5, self.decks - self.seen / 52.0)

    def true_count(self):
        return self.running / self.decks_left()

    def snapshot(self):
        return {
            'running': self.running,
            'trueCount': round(self.true_count(), 1),
            'seen': self.seen,
            'decks': self.decks,
            'decksLeft': round(self.decks_left(), 1),
            'recent': self.recent[-8:],
            'live': [t.rank for t in self.tracks if t.counted],
            'pending': sum(1 for t in self.tracks if not t.counted),
        }

    # -------------------------------------------------------------- update

    def shift(self, dx, dy):
        """Apply the camera's frame-to-frame motion to every track before matching."""
        for t in self.tracks:
            t.x += dx
            t.y += dy

    def update(self, cards, now=None):
        """Feed one frame's detections. Returns the list of cards counted this frame."""
        now = time.time() if now is None else now
        unmatched = list(cards)
        matched_tracks = set()

        # Greedy nearest-neighbour. Cards are big and sparse relative to head jitter, so
        # this is enough; Hungarian would be overkill for a dozen objects.
        pairs = []
        for ci, c in enumerate(cards):
            for t in self.tracks:
                d = ((t.x - c.center[0]) ** 2 + (t.y - c.center[1]) ** 2) ** 0.5
                if d <= t.size * self.match_radius:
                    pairs.append((d, ci, t))
        pairs.sort(key=lambda p: p[0])
        used_cards = set()
        for d, ci, t in pairs:
            if ci in used_cards or t.id in matched_tracks:
                continue
            t.absorb(cards[ci], now)
            used_cards.add(ci)
            matched_tracks.add(t.id)
        unmatched = [c for i, c in enumerate(cards) if i not in used_cards]

        for c in unmatched:
            self.tracks.append(Track(self.next_id, c, now))
            self.next_id += 1

        counted_now = []
        for t in self.tracks:
            if t.counted or t.seen < self.min_frames:
                continue
            rank, agreement = t.majority()
            if rank is None or agreement < self.min_agreement:
                continue
            mean_margin = sum(t.margins) / float(len(t.margins)) if t.margins else 0.0
            if mean_margin < self.min_margin:
                continue
            t.counted = True
            t.rank = rank
            t.suit = t.suit_votes.most_common(1)[0][0] if t.suit_votes else None
            self.running += hilo_delta(rank)
            self.seen += 1
            self.recent.append({'rank': rank, 'suit': t.suit, 'delta': hilo_delta(rank)})
            if len(self.recent) > 32:
                self.recent = self.recent[-32:]
            counted_now.append(t)

        # Forget what has been gone long enough. Uncounted tracks die faster: they were
        # probably a false quad (a chip tray, a phone) and should not linger and absorb a
        # real card's detections later.
        keep = []
        for t in self.tracks:
            gone = now - t.last
            limit = self.forget_s if t.counted else min(self.forget_s, 1.5)
            if gone <= limit:
                keep.append(t)
        self.tracks = keep
        return counted_now
