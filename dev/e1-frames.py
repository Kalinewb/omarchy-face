#!/usr/bin/env python3

"""Scripted frames for dev/e1-enrol-sweep.sh: a person's presses of the dot scan, as data.

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

import json
import math
import sys

# Millimetres, x to the image right, y down, z toward the camera: two points per eye, the nose bottom last.
CANONICAL = [(46.5, 0.0, 0.0), (16.5, 0.0, 0.0), (-16.5, 0.0, 0.0), (-46.5, 0.0, 0.0), (0.0, 42.0, 28.0)]


def landmarks(yaw, pitch, roll=0.0, scale=1.2, centre=(200.0, 200.0)):
    """Five image points for a head turned `yaw` degrees, nodded `pitch`, rolled `roll` in the image plane."""
    ty, tp, tr = math.radians(yaw), math.radians(pitch), math.radians(roll)
    points = []
    for x, y, z in CANONICAL:
        y1 = y * math.cos(tp) + z * math.sin(tp)
        z1 = -y * math.sin(tp) + z * math.cos(tp)
        x2 = x * math.cos(ty) + z1 * math.sin(ty)
        points.append((centre[0] + scale * (x2 * math.cos(tr) - y1 * math.sin(tr)),
                       centre[1] + scale * (x2 * math.sin(tr) + y1 * math.cos(tr))))
    return points


DT = 1.0 / 15
# the stored pose bin of each dot (left 9, top 0, right 3, bottom 6) -> the head's yaw and pitch, degrees
_POSES = {"centre": (0.0, 0.0), 9: (24.0, 0.0), 0: (0.0, -16.0), 3: (-24.0, 0.0), 6: (0.0, 16.0)}


def pose_of(where):
    return _POSES[where]


def entry(yaw, pitch, scale=1.2, who=0.0, kind="ok", faces=1, hold=False, roll=0.0, drift=0.0, axis=2):
    points = landmarks(yaw, pitch, roll=roll, scale=scale)
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


# The dot scan (3.2.0): ONE press is one launch of the camera, so each scenario below is one press. The pose is
# not measured by the engine; what differs between the poses is how far they move the descriptor from the centre's
# (each along its own axis) and, for a turned head, a smaller face.
DOT_AT = {"left": (9, 2), "top": (0, 3), "right": (3, 4), "bottom": (6, 5)}


def dot_press(pose, **kw):
    where, axis = DOT_AT[pose]
    return build([dict(at=where, n=40, travel=kw.pop("travel", 4), drift=kw.pop("drift", 0.30), axis=axis,
                       scale=kw.pop("scale", 1.0), **kw)])


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
    # somebody who took the TOP at 0.52 from the centre, then presses right and bottom: his frames sit 0.1 from that top picture
    # (so inside CHAIN of it) and 0.53 from the centre (inside HARD), but over CHAIN of the centre and of the owner's left
    "dot-chain-right": lambda: dot_press("right", who=0.53, drift=0.10, travel=0),
    "dot-chain-bottom": lambda: dot_press("bottom", who=0.53, drift=0.10, travel=0),
    # the centre with the eye line tilted past ROLL_MAX (25 degrees)
    "dot-centre-roll": lambda: build([dict(n=120, roll=30.0)]),
    "dot-dim": lambda: build([dict(n=120, kind="dim")]),
    "dot-two-faces": lambda: build([dict(n=120, faces=2)]),
    "dot-centre-far": lambda: build([dict(n=120, scale=0.5)]),
    # the user's own seat (3.2.1): eyes 37.8 px (scale 0.6), under the old EYE_MIN 40 and over the new 36; and one just under it (34.7 px)
    "dot-centre-seat": lambda: build([dict(n=40, scale=0.6)]),
    "dot-centre-just-small": lambda: build([dict(n=120, scale=0.55)]),
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
    # a room too dark for the emitter's own light: every frame unlit (no strobe at all)
    "unlit-room": lambda: build([dict(n=900, kind="unlit")]),
    # one frame of each real-like kind, 30 of each, for e1's check of the fake camera's distribution
    "calibrate": lambda: [dict(entry(0.0, 0.0), kind=kind) for kind in ("unlit", "unlit-start", "lit") for _ in range(30)],
}


def _identity_gauss(frames, start, gap, sigma, seed=7):
    """Like _identity, but each frame's gap is Gaussian (mean `gap`, standard deviation `sigma`), the other wobble model."""
    import random
    rng = random.Random(seed)
    out = []
    for i, frame in enumerate(frames):
        frame = dict(frame)
        if i >= start:
            frame["who"] = max(0.0, rng.gauss(gap, sigma))
        out.append(frame)
    return out


def straddle(name):
    """dot-straddle:GAP:WOBBLE:SEED[:MODEL[:POSE]] -- a press of POSE (default left) by somebody whose descriptor is GAP from the
    centre's, plus a per-frame wobble from the first frame: MODEL `uni` (default; up to +-WOBBLE, uniform) or `gauss` (standard
    deviation WOBBLE). At GAP 0.46 and WOBBLE 0.08 about one frame in eight is within 0.40: the lookalike that 3.2.0 as first
    built stored in most presses. At 0.30 or 0.34 it is the owner's proxy. For POSE top the limits are DOT_TOP_CHAIN and DOT_TOP_HARD."""
    parts = name.split(":")
    _, gap, wobble, seed = parts[:4]
    model = parts[4] if len(parts) > 4 else "uni"
    pose = parts[5] if len(parts) > 5 else "left"
    frames = dot_press(pose, drift=0.0)
    if model == "gauss":
        return _identity_gauss(frames, 0, float(gap), float(wobble), seed=int(seed))
    return _identity(frames, 0, float(gap), float(wobble), seed=int(seed))


def main(argv):
    if len(argv) == 1 and argv[0].startswith("dot-straddle:"):
        json.dump(straddle(argv[0]), sys.stdout)
        return 0
    if len(argv) != 1 or argv[0] not in SCENARIOS:
        sys.stderr.write(__doc__ + "\nscenarios: " + ", ".join(sorted(SCENARIOS)) + "\n")
        return 2
    json.dump(SCENARIOS[argv[0]](), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
