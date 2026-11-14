#!/usr/bin/env python3

"""Scripted frames for dev/e1-enrol-sweep.sh: a person turning their head, as data.

    dev/e1-frames.py <scenario>      prints the frame script (JSON) on stdout

The fake camera in e1's sandbox plays this script, one entry per frame at 15 fps of
VIRTUAL time, and its fake dlib answers from the same entry: the five landmarks, the
face box, how many faces there are and whose face it is. The pixels are real numpy
images (noise, dark, saturated, blurred or black) so the engine's own cv2 gates run on
them. Heads are drawn with e0's canonical 3D face; the poses that land in a chosen
(u, v) are found with its pose_for, which is circular and is fine here: e1 tests the
engine, e0 tests the pose chain.

An entry is {"pts": 5 points, "box": [l, t, r, b], "faces": n, "who": F, "kind": K,
"dt": s, "hold": bool}. `hold` makes the camera wait, before it returns that frame,
until a line is waiting on the engine's stdin: how a test puts a `finish` in the same
frame as a fill.
"""

import importlib.util
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("e0_pose", os.path.join(HERE, "e0-pose.py"))
e0 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(e0)

DT = 1.0 / 15
NEUTRAL = e0.neutral_for()
_POSES = {}


def pose_of(where):
    """(yaw, pitch) degrees for "centre", a bin 0 to 11 at r 1.6, or ("uv", u, v)."""
    if where == "centre":
        return 0.0, 0.0
    key = where
    if key not in _POSES:
        u, v = (where[1], where[2]) if isinstance(where, tuple) else e0.direction(where, 1.6)
        # A real head couples: turned sideways it reads lower by COUPLING_C of the turn (3.1.5, measured on the
        # user's own trace). The engine takes that out (rule D), so the head that lands on a bin's centre
        # after rule D is the one that reads that much lower before it.
        _POSES[key] = e0.pose_for(u, v + e0.sw.COUPLING_C * abs(u), NEUTRAL)
    return _POSES[key]


def entry(yaw, pitch, scale=1.2, who=0.0, kind="ok", faces=1, hold=False, roll=0.0, drift=0.0, axis=2):
    points = e0.landmarks(yaw, pitch, roll=roll, scale=scale)
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    eye = 63.0 * scale
    box = [min(xs) - 0.6 * eye, min(ys) - 0.9 * eye, max(xs) + 0.6 * eye, max(ys) + 0.9 * eye]
    return {"pts": points, "box": box, "faces": faces, "who": who, "kind": kind, "dt": DT, "hold": hold, "drift": drift, "axis": axis}


def build(segments):
    """Segments: {"at": where, "n": frames, "from": where (the travel's start, default
    the previous segment), "travel": frames, plus any of entry()'s keywords and
    "swing": degrees of yaw alternating each frame}."""
    frames, previous, previous_drift = [], "centre", 0.0
    for segment in segments:
        segment = dict(segment)
        where = segment.pop("at", "centre")
        count = segment.pop("n", 30)
        travel = segment.pop("travel", 6)
        swing = segment.pop("swing", 0.0)
        hold_last = segment.pop("hold", False)
        # "drift": how far this pose moves the SAME face's descriptor from its straight-on one (the owner's
        # frames at a turn are 0.3-0.46 from the centre); it ramps over the travel like the pose does
        drift1 = segment.pop("drift", 0.0)
        yaw1, pitch1 = pose_of(where)
        yaw0, pitch0 = pose_of(segment.pop("from", previous))
        for i in range(travel):
            f = (i + 1) / float(travel + 1)
            frames.append(entry(yaw0 + (yaw1 - yaw0) * f, pitch0 + (pitch1 - pitch0) * f,
                                drift=previous_drift + (drift1 - previous_drift) * f, **segment))
        for i in range(count):
            wobble = swing * (1 if i % 2 else -1)
            frames.append(entry(yaw1 + wobble, pitch1, drift=drift1, **dict(segment, hold=hold_last and i == count - 1)))
        previous, previous_drift = where, drift1
    return frames


def _adv_base():
    """The owner's centre and four Advanced bins (frames 0 to about 185), then the rest of the ring held for a long time."""
    return build([dict(n=40)] + visit(CLOCK[:4]) + visit(CLOCK[4:], n=60))


def _late2_base():
    """The owner's centre, left and right (0.30 each, own axes), then up and down held for a long time."""
    return build([dict(n=40), dict(at=9, n=40, drift=0.30, travel=14, axis=2), dict(at=3, n=40, drift=0.30, travel=14, axis=3)]
                 + visit((0, 6), n=240))


def _lap():
    return build([dict(n=40)] + visit(SIMPLE))


def _identity(frames, start, gap, wobble, pattern=None, seed=7):
    """From frame `start`, the frames `pattern` picks (all of them by default) are somebody else: their
    descriptor is `gap` from the owner's plus a per-frame wobble of up to +-`wobble`, as a real stranger's
    would vary (a constant gap makes a test that cannot see a stranger who is only sometimes close)."""
    import random
    rng = random.Random(seed)
    out = []
    for i, frame in enumerate(frames):
        frame = dict(frame)
        if i >= start and (pattern is None or pattern(i - start)):
            frame["who"] = gap + rng.uniform(-wobble, wobble)
        out.append(frame)
    return out


def _identity_mixed(frames, start, gaps, wobble=0.01):
    """From frame `start` every frame is somebody else, the gaps cycling through `gaps`."""
    import random
    rng = random.Random(11)
    out = []
    for i, frame in enumerate(frames):
        frame = dict(frame)
        if i >= start:
            frame["who"] = gaps[(i - start) % len(gaps)] + rng.uniform(-wobble, wobble)
        out.append(frame)
    return out


def _foothold():
    import random
    rng = random.Random(3)
    out = []
    for i, frame in enumerate(_lap()):
        frame = dict(frame)
        if i == 45:
            frame["who"] = 0.38
        elif i > 45:
            frame["who"] = 0.46 + rng.uniform(-0.02, 0.02)
        out.append(frame)
    return out


def strobe(frames):
    """A strobing emitter as measured on this laptop (dev/fixtures/ir-strobe-stats.json): every
    other frame is unlit (about 99.8% dark, mean 1.3; the first one 89% dark, mean 6) and the lit
    ones come at half the rate and are 27-37% dark. `unlit` frames are never exactly black."""
    out = []
    for i, frame in enumerate(frames):
        lit = frame["kind"] == "ok"
        out.append(dict(frame, kind="lit") if lit else frame)
        out.append(dict(frame, kind="unlit-start" if i == 0 else "unlit", hold=False))
    return out


CLOCK = (0, 6, 3, 9, 1, 7, 4, 10, 2, 8, 5, 11)
SIMPLE = (9, 3, 0, 6)
# The dot scan (3.2.0): ONE press is one launch of the camera, so each scenario below is one press. The pose is
# not measured by the engine; what differs between the poses is how far they move the descriptor from the centre's
# (each along its own axis, as in the 3.1.x scenarios) and, for a turned head, a smaller face.
DOT_AT = {"left": (9, 2), "top": (0, 3), "right": (3, 4), "bottom": (6, 5)}


def dot_press(pose, **kw):
    where, axis = DOT_AT[pose]
    return build([dict(at=where, n=40, travel=kw.pop("travel", 4), drift=kw.pop("drift", 0.30), axis=axis,
                       scale=kw.pop("scale", 1.0), **kw)])


def visit(bins, n=30, **kw):
    return [dict(at=k, n=n, **kw) for k in bins]


SCENARIOS = {
    # the dot scan: the centre, and each of the other four, held for a press (3 lit frames close the ring)
    "dot-centre": lambda: build([dict(n=40)]),
    "dot-left": lambda: dot_press("left"),
    "dot-top": lambda: dot_press("top"),
    "dot-right": lambda: dot_press("right"),
    "dot-bottom": lambda: dot_press("bottom"),
    # a turned head is a smaller face (eyes under EYE_MIN): the centre's size gate does not apply to it
    "dot-left-small": lambda: dot_press("left", scale=0.55),
    # the same behind a strobing emitter: every other frame unlit
    "dot-strobe-centre": lambda: strobe(build([dict(n=40)])),
    "dot-strobe-left": lambda: strobe(dot_press("left")),
    "dot-strobe-dim": lambda: strobe(build([dict(n=200, kind="dim")])),
    # no face, a dark room, a covered camera, two faces, a face too small or too big (the centre's gates)
    "dot-none": lambda: build([dict(n=120, faces=0)]),
    # the centre with the eye line tilted past ROLL_MAX (25 degrees)
    "dot-centre-roll": lambda: build([dict(n=120, roll=30.0)]),
    "dot-dim": lambda: build([dict(n=120, kind="dim")]),
    "dot-two-faces": lambda: build([dict(n=120, faces=2)]),
    "dot-centre-far": lambda: build([dict(n=120, scale=0.5)]),
    "dot-centre-close": lambda: build([dict(n=120, scale=2.6)]),
    # two good frames and then nobody: not enough, so the ring must not close
    "dot-two-good": lambda: build([dict(n=2, travel=0), dict(n=118, faces=0, travel=0)]),
    # nobody for a second, then the face: the press still succeeds inside its seconds
    "dot-late": lambda: build([dict(n=15, faces=0, travel=0), dict(n=40, travel=0)]),
    # somebody else at the left press (a descriptor 1.0 away), and the owner whose left turn moved the descriptor 0.46
    # (over CHAIN, under HARD: the cost of the chain, as in 3.1.x)
    "dot-stranger-left": lambda: dot_press("left", who=1.0),
    "dot-stranger-near-left": lambda: dot_press("left", who=0.46),
    "dot-owner-far-left": lambda: dot_press("left", drift=0.46, travel=0),
    # a stranger just inside CHAIN of the centre: the documented limit, nothing in the guard refuses it
    "dot-stranger-limit-left": lambda: dot_press("left", who=0.30, drift=0.0),
    # the camera waits for a line on stdin before its first frame (the cancel test)
    "dot-hold-first": lambda: build([dict(n=1, hold=True, travel=0), dict(n=900)]),
    # a whole lap of either mode, every target held in turn
    "four-bins": lambda: build([dict(n=40)] + visit(SIMPLE)),
    "advanced": lambda: build([dict(n=40)] + visit(CLOCK)),
    # Advanced with the centre and four bins, then the camera waits for a `finish`
    "advanced4-hold": lambda: build([dict(n=40)] + visit(CLOCK[:3], n=30) + visit(CLOCK[3:4], n=30, hold=True) + visit(CLOCK[4:5], n=400)),
    # four bins in hand, a fifth being held when the `finish` arrives, filled one frame later
    "advanced3-then-4": lambda: build([dict(n=40)] + visit(CLOCK[:3], n=30) + visit(CLOCK[3:4], n=18, hold=True) + visit(CLOCK[3:4], n=60)),
    # the head sits in the wrong wedge (6) while 9 is current, for ever
    # sweeping through each wedge without holding: 4 frames in each
    # a hold, a 0.5 s absence (the dwell resets), then the hold again, long enough to fill
    # 9 and 3 held, then nothing is ever reached: 0 and 6 are skipped
    # never at the centre: the head never settles, so there is no neutral and no centre
    "no-centre": lambda: build([dict(n=900, swing=12.0)]),
    "black": lambda: build([dict(n=900, kind="black")]),
    # a strobing emitter (3.1.1): black frames between the lit ones are not "dark"
    "advanced-strobe": lambda: strobe(build([dict(n=40)] + visit(CLOCK))),
    # every frame lit but too dark (80% in the darkest bin: kind "dark" is 100%, which is black); and the same behind a strobe
    "dim": lambda: build([dict(n=900, kind="dim")]),
    "strobe-dim": lambda: strobe(build([dict(n=450, kind="dim")])),
    # a room too dark for the emitter's own light: every frame unlit (no strobe at all)
    "unlit-room": lambda: build([dict(n=900, kind="unlit")]),
    # one frame of each real-like kind, 30 of each, for e1's check of the fake camera's distribution
    "calibrate": lambda: [dict(entry(0.0, 0.0), kind=kind) for kind in ("unlit", "unlit-start", "lit") for _ in range(30)],
    # the unlit frames of a strobe whose lit frames are exactly black too
    "strobe-black": lambda: strobe(build([dict(n=450, kind="black")])),
    # the OWNER at each Simple target with a descriptor 0.46 from the straight-on one (over CHAIN, under HARD) by small
    # steps: the FIRST target is already that far, so nothing is filled and the run of refusals ends the lap `changed`,
    # as in 3.1.3 (the cost of the strictness below the floor; the live trace's failure was after two fills).
    # (each turn moves the descriptor along its own axis, as turning to different sides does: the left turn is not near the up one)
    "owner-turn": lambda: build([dict(n=40)] + [dict(at=k, n=240, drift=0.46, travel=14, axis=2 + i) for i, k in enumerate(SIMPLE)]),
    # left fills (0.30), then right, up and down are 0.46 from the centre: ONE fill is below the floor of two, so the
    # right target's frames are stranger frames (`changed`) -- the cost of keying the band on the floor
    "owner-band-after-fill": lambda: build([dict(n=40), dict(at=9, n=40, drift=0.30, travel=14, axis=2)]
                                                  + [dict(at=k, n=240, drift=0.46, travel=14, axis=3 + i) for i, k in enumerate((3, 0, 6))]),
    # a stranger straddling CHAIN who takes over after the owner's left target has filled (one fill: below the floor of two,
    # so the band is still strict) and after left AND right have (the floor is met: the band is neutral and five band
    # frames in a row end the lap with what is filled)
    "stranger-late-after-fill": lambda: _identity(build([dict(n=40), dict(at=9, n=40, drift=0.30, travel=14, axis=2)] + visit((3, 0, 6))), 100, 0.46, 0.08),
    "stranger-late-after-fill-2": lambda: _identity(build([dict(n=40), dict(at=9, n=40, drift=0.30, travel=14, axis=2), dict(at=3, n=40, drift=0.30, travel=14, axis=3)]
                                                      + visit((0, 6), n=240)), 135, 0.46, 0.08),
    # lap 2 (Advanced), the owner at the centre, then somebody else: `accepted` holds lap 1's templates from the first frame,
    # so only THIS LAP's fills count towards the floor
    # ADVANCED, the floor met (four bins of this lap): the owner far off-centre on the fifth bin (0.46 on its own axis), and
    # somebody else who takes over after the owner's fourth bin (gaps 0.46 and 0.50 in the band, 0.44 +-0.08 straddling).
    # Five band frames in a row end the lap with `finish`, keeping the owner's four bins.
    "adv-owner-band": lambda: build([dict(n=40)] + visit(CLOCK[:4], drift=0.30) + [dict(at=CLOCK[4], n=240, drift=0.46, travel=14, axis=6)]),
    "adv-late-stranger-046": lambda: _identity(_adv_base(), 190, 0.46, 0.04),
    "adv-late-stranger-050": lambda: _identity(_adv_base(), 190, 0.50, 0.04),
    "adv-late-straddle-044": lambda: _identity(_adv_base(), 190, 0.44, 0.08),
    # 3.1.6: past the floor a frame OVER HARD is neutral too (five in a row end the lap with `finish`, what is filled is kept):
    # the owner whose up is 0.60 from the centre, a stranger 0.60 away after left and right, and after the owner's four Advanced
    # bins; below the floor (after only left) it still ends `changed`
    "stranger-late-beyond-1": lambda: _identity(build([dict(n=40), dict(at=9, n=40, drift=0.30, travel=14, axis=2)] + visit((3, 0, 6))), 100, 0.60, 0.02),
    "adv-late-stranger-060": lambda: _identity(_adv_base(), 190, 0.60, 0.02),
    # 3.1.7: the scale band. The owner leans back on the first bin (smaller face, 0.67 of the centre's eye distance) and the
    # descriptor goes 0.60 from the centre (over HARD): without the band that is five stranger frames and the lap is `changed`;
    # with it those frames are asked to come `closer`, never encoded, and the owner who leans forward again fills four bins.
    "adv-scale-drift": lambda: build([dict(n=40), dict(at=0, n=60, scale=0.8, drift=0.60, travel=6, axis=6)] + visit(CLOCK[:4], travel=10)),
    # ...and somebody else who takes over at ANOTHER size (0.6 from the centre, 0.67 of its eye distance) and stays there gains
    # nothing: none of his frames is encoded, so none can be stored, and nothing ends the lap but the ceiling
    "stranger-small": lambda: _identity(build([dict(n=40, scale=1.2)] + visit(SIMPLE, scale=0.8)), 45, 0.60, 0.02),
    "lap2-stranger-044": lambda: _identity(build([dict(n=40, scale=0.9)] + visit(CLOCK, scale=0.9)), 45, 0.44, 0.04),
    "lap2-straddle": lambda: _identity(build([dict(n=40, scale=0.9)] + visit(CLOCK, scale=0.9)), 45, 0.44, 0.08),
    # STRANGERS WITH PER-FRAME SPREAD (identity gap from the owner + wobble, after the centre). With only the centre
    # filled, every frame over CHAIN counts towards `changed` (3.1.3's rule): the band (0.40-0.55), straddling CHAIN and
    # past HARD all end the lap `changed` and store nothing.
    "stranger-gap-046": lambda: _identity(_lap(), 45, 0.46, 0.04),
    "stranger-gap-050": lambda: _identity(_lap(), 45, 0.50, 0.04),
    "stranger-gap-054": lambda: _identity(_lap(), 45, 0.54, 0.01),
    "stranger-midswap": lambda: _identity(_lap(), 70, 0.50, 0.04),
    "stranger-gap-058": lambda: _identity(_lap(), 45, 0.58, 0.02),
    "stranger-gap-062": lambda: _identity(_lap(), 45, 0.62, 0.03),
    # band and beyond frames alternating
    "stranger-band-beyond-mix": lambda: _identity_mixed(_lap(), 45, (0.48, 0.60)),
    "stranger-two-of-three": lambda: _identity(_lap(), 45, 0.46, 0.04, pattern=lambda i: i % 3 != 0),
    "stranger-alternation": lambda: _identity(_lap(), 45, 0.46, 0.04, pattern=lambda i: i % 2 == 0),
    # ONE stranger frame inside CHAIN of the centre (a foothold), then frames 0.46 from the centre but near that
    # one: no template is near them (a chain of templates), and a chain of accepted frames would have admitted them
    "stranger-foothold": lambda: _foothold(),
    # a stranger wholly inside CHAIN of the centre (0.38): the documented limit, nothing in the guard refuses it
    "stranger-limit-038": lambda: _identity(_lap(), 45, 0.38, 0.02),
    # a stranger who STRADDLES CHAIN (0.46 +-0.08, so about one frame in eight is 0.40 or less from the owner's)
    "stranger-straddle": lambda: _identity(_lap(), 45, 0.46, 0.08),
    "advanced-idle": lambda: build([dict(n=40), dict(n=900)]),
    "wrong-long": lambda: build([dict(n=40), dict(at=6, n=900)]),
    # the camera waits on its first frame for a line on stdin (for the session-bound test)
    "hold-first": lambda: build([dict(n=1, hold=True, travel=0), dict(n=900)]),
    # the 4th Advanced bin with a `finish` landing before its fill (12th frame) and after it (14th)
    "fin-before": lambda: build([dict(n=40)] + visit(CLOCK[:3]) + visit(CLOCK[3:4], n=12, hold=True) + visit(CLOCK[3:4], n=60, travel=0)),
    "fin-after": lambda: build([dict(n=40)] + visit(CLOCK[:3]) + visit(CLOCK[3:4], n=24, hold=True) + visit(CLOCK[3:4], n=60, travel=0)),
    # a second person walks in after the centre; and one stray frame of them
    "lap-changed": lambda: build([dict(n=40), dict(at=9, n=20), dict(at=9, n=40, who=1.0)]),
    "lap-stray": lambda: build([dict(n=40), dict(at=9, n=12), dict(at=9, n=1, who=1.0, travel=0), dict(at=9, n=18, travel=0)]
                                  + visit((3, 0, 6))),
    # the centre is the owner's, then a stranger holds all four Simple targets: with the
    # child's guard working this is `changed`; with it disabled (SR1 S1's test) the parent
    # has to refuse the lap itself
    "stranger-lap": lambda: build([dict(n=40)] + visit(SIMPLE, who=1.0)),
    # Advanced: each bin held under a different fault, the rest held cleanly
    "advanced-faults": lambda: build(
        [dict(n=40)]
        + [dict(at=1, kind="dark"), dict(at=2, kind="sat"), dict(at=4, kind="blur"), dict(at=5, scale=0.5),
           dict(at=7, scale=2.6), dict(at=8, faces=2), dict(at=10, swing=12.0), dict(at=11, n=1, travel=0)]
        + visit((0, 6, 3, 9)) + [dict(at="centre", n=900)]),
    # lap 2, further away (eye ratio under 0.8), the same person
    "lap2": lambda: build([dict(n=40, scale=0.9)] + visit(CLOCK, scale=0.9)),
    "lap2-other": lambda: build([dict(n=40, scale=0.9, who=1.0)] + visit(CLOCK, scale=0.9, who=1.0)),
}


def grid(name):
    """grid-late2:GAP:WOBBLE:SEED -- the owner's left and right, then somebody else at that identity gap (+- wobble), seeded.
    The tool for measuring how often a late stranger is stored (dev/README.md)."""
    _, gap, wobble, seed = name.split(":")
    return _identity(_late2_base(), 135, float(gap), float(wobble), seed=int(seed))


def straddle(name):
    """dot-straddle:GAP:WOBBLE:SEED -- a LEFT press by somebody whose descriptor is GAP from the centre's, plus a per-frame
    wobble of up to +-WOBBLE (seeded), from the first frame. At GAP 0.46 and WOBBLE 0.08 about one frame in eight is within
    CHAIN: the lookalike that 3.2.0 as first built stored in most presses. At 0.30 or 0.34 it is the owner's proxy."""
    _, gap, wobble, seed = name.split(":")
    return _identity(dot_press("left", drift=0.0), 0, float(gap), float(wobble), seed=int(seed))


def main(argv):
    if len(argv) == 1 and argv[0].startswith("dot-straddle:"):
        json.dump(straddle(argv[0]), sys.stdout)
        return 0
    if len(argv) == 1 and argv[0].startswith("grid-late2:"):
        json.dump(grid(argv[0][len("grid-"):]), sys.stdout)
        return 0
    if len(argv) != 1 or argv[0] not in SCENARIOS:
        sys.stderr.write(__doc__ + "\nscenarios: " + ", ".join(sorted(SCENARIOS)) + "\n")
        return 2
    json.dump(SCENARIOS[argv[0]](), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
