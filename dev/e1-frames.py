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
        _POSES[key] = e0.pose_for(u, v, NEUTRAL)
    return _POSES[key]


def entry(yaw, pitch, scale=1.2, who=0.0, kind="ok", faces=1, hold=False, roll=0.0, drift=0.0):
    points = e0.landmarks(yaw, pitch, roll=roll, scale=scale)
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    eye = 63.0 * scale
    box = [min(xs) - 0.6 * eye, min(ys) - 0.9 * eye, max(xs) + 0.6 * eye, max(ys) + 0.9 * eye]
    return {"pts": points, "box": box, "faces": faces, "who": who, "kind": kind, "dt": DT, "hold": hold, "drift": drift}


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


def _alternating():
    """The owner's lap with a stranger's frame after every owner frame of the holds (never five in a row)."""
    frames = []
    for frame in build([dict(n=40)] + visit(SIMPLE)):
        frames.append(frame)
        if frame["who"] == 0.0 and len(frames) > 60:
            frames.append(dict(frame, who=0.9))
    return frames


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


def visit(bins, n=30, **kw):
    return [dict(at=k, n=n, **kw) for k in bins]


SCENARIOS = {
    # a whole lap of either mode, every target held in turn
    "simple": lambda: build([dict(n=40)] + visit(SIMPLE)),
    "advanced": lambda: build([dict(n=40)] + visit(CLOCK)),
    # Advanced with the centre and four bins, then the camera waits for a `finish`
    "advanced4-hold": lambda: build([dict(n=40)] + visit(CLOCK[:3], n=30) + visit(CLOCK[3:4], n=30, hold=True) + visit(CLOCK[4:5], n=400)),
    # four bins in hand, a fifth being held when the `finish` arrives, filled one frame later
    "advanced3-then-4": lambda: build([dict(n=40)] + visit(CLOCK[:3], n=30) + visit(CLOCK[3:4], n=18, hold=True) + visit(CLOCK[3:4], n=60)),
    # the head sits in the wrong wedge (6) while 9 is current, for ever
    "simple-wrong": lambda: build([dict(n=40), dict(at=6, n=900)]),
    # sweeping through each wedge without holding: 4 frames in each
    "simple-sweep-through": lambda: build([dict(n=40)] + visit(SIMPLE, n=3, travel=3) + [dict(at="centre", n=900)]),
    # a hold, a 0.5 s absence (the dwell resets), then the hold again, long enough to fill
    "simple-grace": lambda: build([dict(n=40), dict(at=9, n=8), dict(at="centre", n=8), dict(at=9, n=8), dict(at=3, n=900)]),
    # 9 and 3 held, then nothing is ever reached: 0 and 6 are skipped
    "simple-two": lambda: build([dict(n=40)] + visit((9, 3)) + [dict(at="centre", n=900)]),
    "simple-one": lambda: build([dict(n=40)] + visit((9,)) + [dict(at="centre", n=900)]),
    "simple-three": lambda: build([dict(n=40)] + visit((9, 3, 0)) + [dict(at="centre", n=900)]),
    # never at the centre: the head never settles, so there is no neutral and no centre
    "no-centre": lambda: build([dict(n=900, swing=12.0)]),
    "black": lambda: build([dict(n=900, kind="black")]),
    # a strobing emitter (3.1.1): black frames between the lit ones are not "dark"
    "simple-strobe": lambda: strobe(build([dict(n=40)] + visit(SIMPLE))),
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
    # the OWNER turning to each Simple target, whose descriptor drifts 0.46 from the straight-on one at the
    # target (over CHAIN, under HARD) but by small steps from frame to frame: it must complete (3.1.4)
    "simple-owner-turn": lambda: build([dict(n=40)] + [dict(at=k, n=30, drift=0.46, travel=14) for k in SIMPLE]),
    # a stranger 0.50 from the owner (inside HARD, outside CHAIN of everything accepted) after the centre
    "simple-lookalike": lambda: build([dict(n=40)] + visit(SIMPLE, who=0.5)),
    # the owner's frames alternating with a stranger's, from the first target on
    "simple-alternating": lambda: _alternating(),
    "advanced-idle": lambda: build([dict(n=40), dict(n=900)]),
    "simple-wrong-long": lambda: build([dict(n=40), dict(at=6, n=900)]),
    # the camera waits on its first frame for a line on stdin (for the session-bound test)
    "hold-first": lambda: build([dict(n=1, hold=True, travel=0), dict(n=900)]),
    # the 4th Advanced bin with a `finish` landing before its fill (12th frame) and after it (14th)
    "fin-before": lambda: build([dict(n=40)] + visit(CLOCK[:3]) + visit(CLOCK[3:4], n=12, hold=True) + visit(CLOCK[3:4], n=60, travel=0)),
    "fin-after": lambda: build([dict(n=40)] + visit(CLOCK[:3]) + visit(CLOCK[3:4], n=24, hold=True) + visit(CLOCK[3:4], n=60, travel=0)),
    # a second person walks in after the centre; and one stray frame of them
    "simple-changed": lambda: build([dict(n=40), dict(at=9, n=20), dict(at=9, n=40, who=1.0)]),
    "simple-stray": lambda: build([dict(n=40), dict(at=9, n=12), dict(at=9, n=1, who=1.0, travel=0), dict(at=9, n=18, travel=0)]
                                  + visit((3, 0, 6))),
    # the centre is the owner's, then a stranger holds all four Simple targets: with the
    # child's guard working this is `changed`; with it disabled (SR1 S1's test) the parent
    # has to refuse the lap itself
    "simple-stranger": lambda: build([dict(n=40)] + visit(SIMPLE, who=1.0)),
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


def main(argv):
    if len(argv) != 1 or argv[0] not in SCENARIOS:
        sys.stderr.write(__doc__ + "\nscenarios: " + ", ".join(sorted(SCENARIOS)) + "\n")
        return 2
    json.dump(SCENARIOS[argv[0]](), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
