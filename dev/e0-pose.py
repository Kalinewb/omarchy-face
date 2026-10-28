#!/usr/bin/env python3

"""E0: the enrolment sweep's pure half, tested without a camera (plan-face-enroll.md 7.1).

    dev/e0-pose.py

It pulls SWEEP_PY out of system/omarchy-face-admin -- the text root will run, not a
copy -- and drives its pure functions with landmarks drawn from a canonical 3D face
turned by known angles (orthographic, millimetres, (chosen) like every number the
module marks). Standard library only: no numpy, no dlib, no cv2, no camera.

What it asserts is the chain landmarks -> pose -> bin -> gates -> guard -> medoid ->
pick. What it does NOT assert is that five points measure a real head well: the
printed "findings" at the end are the synthetic model's own coupling and noise, and
Phase 0's recordings (dev/enrol-record.py) replace them with measurements.

Exit 0 when every check passes, 1 otherwise.
"""

import ast
import math
import os
import random
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADMIN = os.path.join(REPO, "system", "omarchy-face-admin")

PASS, FAIL = [], []


def check(name, condition, detail=""):
    (PASS if condition else FAIL).append(name)
    print("  %s  %s%s" % ("pass" if condition else "FAIL", name, ("  -- " + detail) if detail and not condition else ""))


def extract():
    with open(ADMIN, encoding="utf-8") as handle:
        text = handle.read()
    found = re.search(r"read -r -d '' SWEEP_PY <<'SWEEP_PY_END' \|\| true\n(.*?)\nSWEEP_PY_END\n", text, re.S)
    if not found:
        sys.exit("e0: SWEEP_PY is not in system/omarchy-face-admin")
    return found.group(1) + "\n"


SOURCE = extract()
MODULE = {"__name__": "sweep_py"}
exec(compile(SOURCE, "SWEEP_PY", "exec"), MODULE)


class S:
    """The module's names, as attributes."""

    def __getattr__(self, name):
        return MODULE[name]


sw = S()


# --- the canonical face ----------------------------------------------------------
# Millimetres, x to the image right, y down, z toward the camera. The two eyes are one
# plane (63 mm between the centres, corners 30 mm apart); the nose bottom is 42 mm
# below them and 28 mm in front. The order is the module's: two points per eye, nose last.
CANONICAL = [(46.5, 0.0, 0.0), (16.5, 0.0, 0.0), (-16.5, 0.0, 0.0), (-46.5, 0.0, 0.0), (0.0, 42.0, 28.0)]
EYE_MM = 63.0


def landmarks(yaw, pitch, roll=0.0, scale=1.2, centre=(200.0, 200.0)):
    """Five image points for a head turned `yaw` degrees (positive: the nose moves to the
    image right, so the subject turns to their LEFT), nodded `pitch` (positive: looking
    down), rolled `roll` in the image plane. Pitch first, then yaw: the head turns about
    its vertical axis, so the eye line stays level.
    """
    ty, tp, tr = math.radians(yaw), math.radians(pitch), math.radians(roll)
    points = []
    for x, y, z in CANONICAL:
        y1 = y * math.cos(tp) + z * math.sin(tp)
        z1 = -y * math.sin(tp) + z * math.cos(tp)
        x2 = x * math.cos(ty) + z1 * math.sin(ty)
        points.append((centre[0] + scale * (x2 * math.cos(tr) - y1 * math.sin(tr)),
                       centre[1] + scale * (x2 * math.sin(tr) + y1 * math.cos(tr))))
    return points


def neutral_for(pitch_offset=0.0):
    pose = sw.pose_indices(landmarks(0.0, pitch_offset))
    return sw.neutral_of([pose] * 5)


def uv_of(points, neutral):
    return sw.pose_uv(sw.pose_indices(points), neutral)


def pose_for(u, v, neutral, pitch_offset=0.0):
    """The yaw and pitch (degrees) whose landmarks read as exactly (u, v): Newton on the
    module's own pose chain, so the 12 directions are 12 real head poses. None when no
    head pose reads there (looking down saturates: past about 34 degrees the nose gets no lower).
    """
    yaw, pitch = -15.0 * u, 10.0 * v + pitch_offset
    for _ in range(60):
        cu, cv = uv_of(landmarks(yaw, pitch), neutral)
        eu, ev = u - cu, v - cv
        if abs(eu) < 1e-9 and abs(ev) < 1e-9:
            return yaw, pitch
        step = 0.01
        u1, v1 = uv_of(landmarks(yaw + step, pitch), neutral)
        u2, v2 = uv_of(landmarks(yaw, pitch + step), neutral)
        a, b, c, d = (u1 - cu) / step, (u2 - cu) / step, (v1 - cv) / step, (v2 - cv) / step
        det = a * d - b * c
        if abs(det) < 1e-12:
            return None
        yaw += max(-8.0, min(8.0, (d * eu - b * ev) / det))
        pitch += max(-8.0, min(8.0, (-c * eu + a * ev) / det))
    return None


def direction(k, radius):
    angle = math.radians(30 * k)
    return radius * math.sin(angle), -radius * math.cos(angle)


# --- encodings: 128 numbers, a distance is the offset along one axis ---------------
def enc(*offsets, size=128):
    vector = [0.0] * size
    for index, value in enumerate(offsets):
        vector[index] = value
    return vector


def frame(t, r, *offsets):
    return {"t": t, "r": r, "encoding": enc(*offsets)}


# --- 0. the module is pure --------------------------------------------------------
def test_pure():
    print("pure and importable")
    tree = ast.parse(SOURCE)
    imported = sorted({alias.name.split(".")[0] for node in ast.walk(tree) if isinstance(node, ast.Import)
                       for alias in node.names} |
                      {node.module.split(".")[0] for node in ast.walk(tree) if isinstance(node, ast.ImportFrom)})
    check("imports only math and sys", imported == ["math", "sys"], str(imported))
    io_calls = sorted({node.func.id for node in ast.walk(tree) if isinstance(node, ast.Call)
                       and isinstance(node.func, ast.Name)
                       and node.func.id in ("open", "print", "input", "exec", "eval", "__import__", "compile")})
    check("no I/O or dynamic-code calls", not io_calls, str(io_calls))
    check("no file or device path in the text", not re.search(r"/dev/|/var/|/usr/|/etc/|video\d", SOURCE))

    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "sweep_py.txt")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(SOURCE)
        loader = ("import sys\n"
                  "for name in ('dlib', 'cv2', 'numpy'):\n"
                  "    sys.modules[name] = None\n"
                  "ns = {'__name__': 'sweep_py'}\n"
                  "exec(compile(open(sys.argv[1]).read(), 'SWEEP_PY', 'exec'), ns)\n"
                  "assert sys.modules['dlib'] is None and sys.modules['cv2'] is None and sys.modules['numpy'] is None\n"
                  "print(ns['pose_name'](3), len(ns['BIN_ORDER']))\n")
        done = subprocess.run([sys.executable, "-I", "-c", loader, path], capture_output=True, text=True, cwd=scratch)
        check("python3 -I loads it with dlib, cv2 and numpy made unimportable",
              done.returncode == 0 and done.stdout.strip() == "a090 12", done.stderr.strip()[-200:])
        # As root will run it: `python3 -I -c "$SWEEP_PY"`. Nothing is wired in yet, so
        # it must refuse cleanly rather than touch anything.
        done = subprocess.run([sys.executable, "-I", "-c", SOURCE], capture_output=True, text=True,
                              cwd=scratch, stdin=subprocess.DEVNULL)
        check("run as a program it declines (exit 2, no traceback)",
              done.returncode == 2 and "Traceback" not in done.stderr, done.stderr.strip()[-200:])
        check("it left nothing behind in its directory", os.listdir(scratch) == ["sweep_py.txt"])


# --- 1. pose ----------------------------------------------------------------------
def test_pose():
    print("pose from five points")
    neutral = neutral_for()
    check("the neutral of a straight head is the median of five", neutral is not None)
    check("fewer than five frames give no neutral", sw.neutral_of([sw.pose_indices(landmarks(0, 0))] * 4) is None)

    pose = sw.pose_indices(landmarks(0, 0, scale=1.2))
    check("eye distance is the scale times 63 mm", abs(pose["eye"] - 1.2 * EYE_MM) < 1e-9, str(pose["eye"]))
    check("a straight head has no yaw and no roll", abs(pose["yaw"]) < 1e-12 and abs(pose["roll"]) < 1e-9)
    check("roll is read as the eye line's angle", abs(sw.pose_indices(landmarks(0, 0, roll=17))["roll"] - 17) < 1e-6)
    check("the eyes are told apart by x, not by index order",
          abs(sw.pose_indices(landmarks(10, 5)[2:4] + landmarks(10, 5)[0:2] + landmarks(10, 5)[4:])["yaw"]
              - sw.pose_indices(landmarks(10, 5))["yaw"]) < 1e-12)
    check("a degenerate pair of eyes is refused", sw.pose_indices([(1, 1)] * 5) is None)

    # mirroring: the preview is mirrored, so turning to YOUR right lights the right.
    right = uv_of(landmarks(-20, 0), neutral)
    left = uv_of(landmarks(20, 0), neutral)
    up = uv_of(landmarks(0, -20), neutral)
    down = uv_of(landmarks(0, 20), neutral)
    check("turning to your right gives u > 0 (ring right)", right[0] > 1.0, str(right))
    check("turning to your left gives u < 0", left[0] < -1.0, str(left))
    check("looking up gives v < 0 (ring top)", up[1] < -1.0, str(up))
    check("looking down gives v > 0 (ring bottom)", down[1] > 1.0, str(down))
    cardinals = []
    for k in (3, 9, 0, 6):
        yaw, pitch = pose_for(*direction(k, 1.6), neutral)
        cardinals.append(sw.locate(*uv_of(landmarks(yaw, pitch), neutral))[0])
    check("heads turned right, left, up, down read bins 3, 9, 0, 6 (clockwise from the top)",
          cardinals == [3, 9, 0, 6], str(cardinals))
    FINDINGS.append("a plain 20 degree turn to your right (no nod) reads bin %d, not 3: yaw leaks into v (see below)"
                    % sw.locate(*right)[0])

    yaws = [yaw for yaw in range(-30, 31, 2)]
    us = [uv_of(landmarks(yaw, 0), neutral)[0] for yaw in yaws]
    check("u falls strictly as the nose moves right (monotone in yaw)", all(a > b for a, b in zip(us, us[1:])))
    pitches = [uv_of(landmarks(0, pitch), neutral)[1] for pitch in range(-30, 31, 2)]
    check("v rises strictly as the head nods down (monotone in pitch)", all(a < b for a, b in zip(pitches, pitches[1:])))
    check("inside r = 1 is the centre: no bin", sw.locate(*uv_of(landmarks(-5, 4), neutral))[0] is None)
    check("past r = 2.2 is too far: no bin", sw.locate(0.0, -2.3)[0] is None and sw.locate(0.0, -2.2)[0] == 0)
    check("r = 1.0 is the first ring position", sw.locate(0.0, -1.0)[0] == 0 and sw.locate(0.0, -0.999)[0] is None)

    # wedges, exactly: bin k is 30 degrees centred on 30 x k.
    edges = [(14.9, 0), (15.1, 1), (44.9, 1), (45.1, 2), (345.1, 0), (344.9, 11), (194.9, 6), (195.1, 7)]
    check("wedge edges fall at 15 degrees past each centre",
          all(sw.locate(1.5 * math.sin(math.radians(a)), -1.5 * math.cos(math.radians(a)))[0] == k for a, k in edges),
          str([(a, sw.locate(1.5 * math.sin(math.radians(a)), -1.5 * math.cos(math.radians(a)))[0]) for a, k in edges]))
    check("pose names round-trip",
          all(sw.bin_of_pose(sw.pose_name(k)) == k and re.fullmatch(r"[a-z0-9-]{1,16}", sw.pose_name(k)) for k in range(12))
          and sw.bin_of_pose("usual") is None and sw.bin_of_pose("a015") is None and sw.bin_of_pose("a360") is None)

    # every one of the twelve directions, as a real turned head.
    wrong, unreachable = [], []
    for k in range(12):
        for radius in (1.2, 1.6, 2.1):
            posed = pose_for(*direction(k, radius), neutral)
            if posed is None:
                unreachable.append((k, radius))
                continue
            got, r, _ = sw.locate(*uv_of(landmarks(*posed), neutral))
            if got != k or abs(r - radius) > 1e-6:
                wrong.append((k, radius, got))
    check("all 12 directions at r 1.2 and 1.6 are reachable by a head and recovered",
          not wrong and not [x for x in unreachable if x[1] < 2.0], str((wrong, unreachable)))
    check("every reachable direction at r 2.1 is recovered too", not wrong)
    if unreachable:
        FINDINGS.append("no head pose reads at (bin, r) %s with AMP_PITCH %s: nose-down saturates"
                        % (unreachable, sw.AMP_PITCH))

    wrong = []
    for k in range(12):
        for roll in (-24, -10, 10, 24):
            yaw, pitch = pose_for(*direction(k, 1.6), neutral)
            if sw.locate(*uv_of(landmarks(yaw, pitch, roll=roll), neutral))[0] != k:
                wrong.append((k, roll))
    check("a rolled head (up to 24 degrees) reads the same bin", not wrong, str(wrong))

    wrong = []
    for k in (0, 3, 6, 9, 2, 7):
        yaw, pitch = pose_for(*direction(k, 1.6), neutral)
        for scale, centre in ((0.6, (150.0, 250.0)), (1.8, (220.0, 180.0))):
            if sw.locate(*uv_of(landmarks(yaw, pitch, scale=scale, centre=centre), neutral))[0] != k:
                wrong.append((k, scale))
    check("distance and position in the frame do not move the bin", not wrong, str(wrong))

    # the neutral absorbs a constant pitch offset (a laptop tilted back, or a tall user).
    offset = 12.0
    shifted = neutral_for(offset)
    results, missing = {}, []
    for k in range(12):
        posed = pose_for(*direction(k, 1.6), shifted, pitch_offset=offset)
        if posed is None:
            missing.append(k)
            continue
        results[k] = sw.locate(*uv_of(landmarks(*posed), shifted))[0] == k
    check("with a 12 degree pitch offset in the neutral every reachable bin still reads",
          results and all(results.values()), str(results))
    if missing:
        FINDINGS.append("with the neutral nodded 12 degrees down, bins %s at r 1.6 are out of reach of the nose" % missing)
    yaw, pitch = pose_for(*direction(3, 1.6), shifted, pitch_offset=offset)
    check("and the same head against a neutral that ignores the offset does not",
          sw.locate(*uv_of(landmarks(yaw, pitch), neutral))[0] != 3)


def test_noise():
    print("noise injection")
    neutral = neutral_for()
    rng = random.Random(20261028)
    for sigma, floor in ((0.5, 0.95), (1.0, 0.80)):
        hits = near = total = 0
        pitch_error = []
        for k in (3, 9):  # pure yaw: the well-conditioned axis
            yaw, pitch = pose_for(*direction(k, 1.6), neutral)
            base = landmarks(yaw, pitch)
            for _ in range(2000):
                noisy = [(x + rng.gauss(0, sigma), y + rng.gauss(0, sigma)) for x, y in base]
                got, _, _ = sw.locate(*uv_of(noisy, neutral))
                hits += got == k
                near += got is not None and min((got - k) % 12, (k - got) % 12) <= 1
                total += 1
        rate = hits / total
        check("yaw bins 3 and 9 keep their bin at %.1f px jitter (>= %d%%): %.1f%%" % (sigma, floor * 100, rate * 100),
              rate >= floor, "%.3f" % rate)
        check("and a wrong bin is the neighbour in at least 99%% of frames at %.1f px (%.1f%%)" % (sigma, near / total * 100),
              near / total >= 0.99, "%.3f" % (near / total))
        for _ in range(4000):
            noisy = [(x + rng.gauss(0, sigma), y + rng.gauss(0, sigma)) for x, y in landmarks(0, 0)]
            pitch_error.append(uv_of(noisy, neutral)[1])
        rms = math.sqrt(sum(e * e for e in pitch_error) / len(pitch_error))
        FINDINGS.append("pitch noise at %.1f px: rms v error %.2f units (1.0 ~ 15 degrees of nod): %.1f degrees"
                        % (sigma, rms, rms * 15))
        FINDINGS.append("yaw bins 3/9 keep their bin %.1f%% of 4000 jittered frames at %.1f px" % (rate * 100, sigma))
    # pitch: the weak axis, so its bins are reported, not promised.
    for k in (0, 6):
        yaw, pitch = pose_for(*direction(k, 1.6), neutral)
        base = landmarks(yaw, pitch)
        hits = sum(sw.locate(*uv_of([(x + rng.gauss(0, 1.0), y + rng.gauss(0, 1.0)) for x, y in base], neutral))[0] == k
                   for _ in range(2000))
        FINDINGS.append("pitch bin %d keeps its bin %.1f%% of 2000 frames at 1.0 px (the weak axis, not a promise)"
                        % (k, hits / 20.0))


def coupling_findings():
    neutral = neutral_for()
    FINDINGS.append("canonical model, 22.5 degrees of yaw alone puts v at %.2f (eye foreshortening feeds pitch)"
                    % uv_of(landmarks(-22.5, 0), neutral)[1])
    up, down = uv_of(landmarks(0, -15), neutral)[1], uv_of(landmarks(0, 15), neutral)[1]
    FINDINGS.append("canonical model, 15 degrees of nod gives v %.2f up and %.2f down (asymmetric); AMP_PITCH is %s"
                    % (up, down, sw.AMP_PITCH))
    top = max(uv_of(landmarks(0, pitch / 2.0), neutral)[1] for pitch in range(0, 140))
    FINDINGS.append("canonical model, nodding down tops out at v %.2f (r 2.2 is the ring's edge)" % top)
    FINDINGS.append("canonical model, 15 degrees of yaw gives u %.2f; AMP_YAW is %s"
                    % (uv_of(landmarks(-15, 0), neutral)[0], sw.AMP_YAW))


# --- 2. gates ---------------------------------------------------------------------
def test_gates():
    print("gates flip at their boundary")
    size = (400, 400)
    inside = (60, 60, 340, 340)

    def word(**changes):
        arguments = dict(faces=1, eye=80, box=inside, size=size, dark=10, saturated=1, sharp=1.0, roll=0, steady=True)
        arguments.update(changes)
        return sw.frame_word(**arguments)

    check("a good frame passes", word() is None)
    check("no face is 'searching'", word(faces=0) == "searching")
    check("two faces is 'multiple'", word(faces=2) == "multiple")
    check("eye 39 closer, 40 passes", (word(eye=39), word(eye=40)) == ("closer", None), str((word(eye=39), word(eye=40))))
    check("eye 150 passes, 151 farther", (word(eye=150), word(eye=151)) == (None, "farther"))
    margin = 0.04 * 400
    check("a box exactly 4% from each border passes",
          word(box=(margin, margin, 400 - margin, 400 - margin)) is None)
    check("a box a hair inside 4% on each border is 'edge'",
          all(word(box=box) == "edge" for box in ((margin - 0.1, 60, 340, 340), (60, margin - 0.1, 340, 340),
                                                  (60, 60, 400 - margin + 0.1, 340), (60, 60, 340, 400 - margin + 0.1))))
    check("dark share 50 passes, 51 is 'dark'", (word(dark=50), word(dark=51)) == (None, "dark"))
    check("saturation 6 passes, 6.1 is 'dark'", (word(saturated=6.0), word(saturated=6.1)) == (None, "dark"))
    check("sharpness 0.5 passes, 0.49 is 'blurry'", (word(sharp=0.5), word(sharp=0.49)) == (None, "blurry"))
    check("roll 25 passes, 26 is 'hold' (either way)",
          (word(roll=25), word(roll=26), word(roll=-25), word(roll=-26)) == (None, "hold", None, "hold"))
    check("not steady is 'hold'", word(steady=False) == "hold")
    check("a face too small to see wins over an edge it also touches", word(eye=30, box=(0, 0, 40, 40)) == "closer")

    still = [(0.0, 0.0)] * 4
    check("four still lit frames are steady", sw.is_steady(still))
    check("three frames are not enough history", not sw.is_steady(still[:3]))
    for step, expect in ((0.049, True), (0.05, False)):
        check("steps of %.3f are %s" % (step, "steady" if expect else "not steady"),
              sw.is_steady([(0.0, 0.0), (step, 0.0), (2 * step, 0.0), (3 * step, 0.0)]) == expect)
    check("one jump among the last three steps is not steady",
          not sw.is_steady([(0, 0), (0.01, 0), (0.2, 0), (0.21, 0)]))
    check("an old jump that has left the window does not count",
          sw.is_steady([(0, 0), (0.5, 0), (0.5, 0), (0.5, 0), (0.5, 0)]))

    check("lap 2 wants farther from a 100 px lap 1 (80 px)", sw.lap2_want(100) == "far")
    check("lap 2 wants closer when farther would fall under the gate", sw.lap2_want(45) == "near")
    check("farther fits from 50 px up (50 x 0.8 = 40); below that lap 2 asks for closer",
          (sw.lap2_want(50), sw.lap2_want(49)) == ("far", "near"))
    check("lap 2 'farther' until eye <= 0.8 x lap 1", (sw.lap2_word(81, 100, "far"), sw.lap2_word(80, 100, "far")) == ("farther", None))
    check("lap 2 'closer' until eye >= 1.25 x lap 1", (sw.lap2_word(124, 100, "near"), sw.lap2_word(125, 100, "near")) == ("closer", None))


# --- 3. the same-person guard and the changed counter -----------------------------
def test_guard():
    print("same-person guard")
    centre = enc(0.0)
    check("CHAIN 0.40, HARD 0.55, SUPPORT 0.30, 5 frames are the constants",
          (sw.CHAIN, sw.HARD, sw.SUPPORT, sw.CHANGED_FRAMES) == (0.40, 0.55, 0.30, 5))
    check("the first frame (no centre yet) is the centre", sw.guard_ok(enc(9.0), [], None))
    check("a frame at CHAIN from the nearest template passes, past it fails",
          sw.guard_ok(enc(0.40), [centre], centre) and not sw.guard_ok(enc(0.4001), [centre], centre))
    check("a frame at HARD from the centre passes, past it fails (chain wide open)",
          sw.guard_ok(enc(0.55), [enc(0.30)], centre, chain=1.0) and not sw.guard_ok(enc(0.5501), [enc(0.30)], centre, chain=1.0))
    check("a chain follows a slow drift (0.35 steps) up to HARD",
          sw.guard_ok(enc(0.35), [centre], centre) and sw.guard_ok(enc(0.50), [centre, enc(0.35)], centre))
    check("but a jump straight to 0.50 is not a chain step", not sw.guard_ok(enc(0.50), [centre], centre))
    check("the chain is the NEAREST template, not every one",
          sw.guard_ok(enc(0.50), [centre, enc(0.20), enc(0.35)], centre))

    run, ended, history = 0, False, []
    for failed in (True, True, True, True, False, True, True, True, True):
        run, ended = sw.changed_step(run, failed)
        history.append((run, ended))
    check("a pass in the middle resets the count: four, one pass, four never ends the lap",
          not any(done for _, done in history), str(history))
    run = 0
    outcome = []
    for _ in range(5):
        run, ended = sw.changed_step(run, True)
        outcome.append(ended)
    check("five consecutive failures end the lap, not four", outcome == [False, False, False, False, True], str(outcome))


# --- 4. supported frames, the medoid, coverage ------------------------------------
def test_support():
    print("supported frames, medoid, coverage")
    spaced = [frame(0.0, 1.5, 0.0), frame(0.3, 1.5, 0.1)]
    check("two frames 0.3 s apart and 0.1 close are supported", len(sw.supported(spaced)) == 2)
    check("0.2 s apart counts, 0.19 s does not",
          len(sw.supported([frame(0.0, 1.5, 0.0), frame(0.2, 1.5, 0.0)])) == 2
          and len(sw.supported([frame(0.0, 1.5, 0.0), frame(0.19, 1.5, 0.0)])) == 1)
    check("SUPPORT 0.30 counts, 0.3001 does not",
          len(sw.supported([frame(0.0, 1.5, 0.0), frame(1.0, 1.5, 0.30)])) == 2
          and len(sw.supported([frame(0.0, 1.5, 0.0), frame(1.0, 1.5, 0.3001)])) == 1)
    odd = [frame(0.0, 1.5, 2.0), frame(0.5, 1.5, 0.0), frame(1.0, 1.5, 0.1), frame(1.5, 1.5, 0.05)]
    kept = sw.supported(odd)
    check("an early outlier does not anchor the set: the three that agree win",
          len(kept) == 3 and all(f["encoding"][0] < 0.2 for f in kept), str([f["encoding"][0] for f in kept]))

    three = [frame(0.0, 1.5, 0.0), frame(0.5, 1.5, 0.1), frame(1.0, 1.5, 0.28)]
    check("the medoid of three is the middle one, not an extremum", sw.medoid(three)["encoding"][0] == 0.1)
    two = [frame(0.0, 1.9, 0.0), frame(0.5, 1.2, 0.1)]
    check("with two frames the tie goes to the lower r", sw.medoid(two)["r"] == 1.2)
    two = [frame(0.0, 1.4, 0.0), frame(0.5, 1.4, 0.1)]
    check("and then to the earlier frame", sw.medoid(two)["t"] == 0.0)
    check("an empty set has no medoid", sw.medoid([]) is None)

    check("one frame is half a bin, two fill it, more stay at 1",
          (sw.bin_fraction(0), sw.bin_fraction(1), sw.bin_fraction(2), sw.bin_fraction(5)) == (0.0, 0.5, 1.0, 1.0))
    check("a bin yields no template under the quota", sw.bin_template(3, [frame(0.0, 1.5, 0.0)]) is None)
    template = sw.bin_template(3, three)
    check("a held bin's template is the medoid with its support, r and pose name",
          template["pose"] == "a090" and template["support"] == 3 and template["r"] == 1.5
          and template["encoding"][0] == 0.1, str(template))

    grown = []
    for index in range(30):
        grown = sw.add_candidate(grown, frame(index * 0.3, 1.5, 0.0))
    check("a long hold keeps only the newest MAX_CANDIDATES", len(grown) == sw.MAX_CANDIDATES and grown[0]["t"] == 18 * 0.3)

    by_bin = {0: three, 3: [frame(0.0, 1.5, 0.0)]}
    fractions, held = sw.coverage(by_bin)
    check("coverage: 12 fractions, bin 0 full, bin 3 half, one bin held",
          len(fractions) == 12 and fractions[0] == 1.0 and fractions[3] == 0.5 and sum(fractions) == 1.5 and held == 1,
          str((fractions, held)))
    check("Done needs the centre and 4 held bins", (sw.done_ready(True, 4), sw.done_ready(True, 3), sw.done_ready(False, 12)) == (True, False, False))
    check("a stricter or looser bar is a parameter, not a hidden default", sw.done_ready(True, 2, minimum=2))


# --- 5. pick ----------------------------------------------------------------------
def make_extra(pose, band, r, support, offset, time):
    return {"pose": pose, "band": band, "time": time, "r": r, "support": support, "encoding": enc(offset)}


def make_person():
    """Three appearances; many templates across bins and bands, some out of bounds."""
    rng = random.Random(7)
    appearances = []
    for ai, label in enumerate(("No glasses", "Everyday glasses", "Reading glasses")):
        extras = []
        for k in range(12):
            for band in ("near", "far"):
                extras.append(make_extra(sw.pose_name(k), band, round(1.0 + rng.random() * 1.2, 3),
                                         2 + rng.randrange(5), round(0.05 + rng.random() * 0.45, 3),
                                         1000 + ai * 100 + k * 2 + (band == "far")))
        extras.append(make_extra("usual", "usual", 0, 3, 0.6, 2000 + ai))  # beyond HARD, chained at capture
        appearances.append({"label": label, "time": 900 + ai, "encoding": enc(0.0), "extra": extras})
    return {"appearances": appearances}


def key_of(person, ref):
    appearance = person["appearances"][ref[0]]
    if ref[1] is None:
        return (appearance["label"], "centre", None, appearance["time"])
    extra = appearance["extra"][ref[1]]
    return (appearance["label"], extra["pose"], extra["band"], extra["time"])


def shuffled(person, seed):
    rng = random.Random(seed)
    copy = {"appearances": [dict(a, extra=list(a["extra"])) for a in person["appearances"]]}
    rng.shuffle(copy["appearances"])
    for appearance in copy["appearances"]:
        rng.shuffle(appearance["extra"])
    return copy


def test_pick():
    print("pick")
    person = make_person()
    centres = {(a["label"], "centre", None, a["time"]) for a in person["appearances"]}

    for kind, cap in (("lock", 12), ("sudo", 4)):
        chosen = [key_of(person, ref) for ref in sw.pick(person, kind, cap)]
        check("%s cap %d: no more than the cap, no repeats" % (kind, cap), len(chosen) == cap == len(set(chosen)), str(len(chosen)))
        check("%s: every appearance's centre is kept" % kind, centres <= set(chosen))
        check("%s: the centres come first" % kind, set(chosen[:3]) == centres)

    for cap in (0, 1, 2, 3, 5, 8, 12, 20, 36, 100):
        for kind in ("lock", "sudo"):
            maximum = 36 if kind == "lock" else 12
            got = sw.pick(person, kind, cap)
            if len(got) > min(cap, maximum):
                check("never exceeds the cap (%s %d)" % (kind, cap), False, str(len(got)))
                break
    else:
        check("never exceeds any cap tried, and clamps to 36 (lock) and 12 (sudo)",
              len(sw.pick(person, "lock", 100)) <= 36 and len(sw.pick(person, "sudo", 100)) <= 12
              and len(sw.pick(person, "sudo", 100)) == 12)
    check("a cap of 2 keeps two centres rather than none (chosen by time then label)",
          len(sw.pick(person, "sudo", 2)) == 2 and all(ref[1] is None for ref in sw.pick(person, "sudo", 2)))
    check("a cap of 0 or less picks nothing", sw.pick(person, "lock", 0) == [] and sw.pick(person, "sudo", -3) == [])

    cases = (("lock", 12), ("sudo", 4), ("lock", 36), ("sudo", 12), ("lock", 7))
    baseline = {case: [key_of(person, ref) for ref in sw.pick(person, *case)] for case in cases}
    same = True
    for seed in range(25):
        other = shuffled(person, seed)
        for case in cases:
            same = same and [key_of(other, ref) for ref in sw.pick(other, *case)] == baseline[case]
    check("the same set in the same order however the records are stored (25 shuffles, 5 caps)", same)

    for cap in (4, 12):
        for ref in sw.pick(person, "sudo", cap):
            if ref[1] is None:
                continue
            extra = person["appearances"][ref[0]]["extra"][ref[1]]
            if extra["band"] == "usual" or extra["r"] > 1.5 or sw.distance(extra["encoding"], person["appearances"][ref[0]]["encoding"]) > 0.40:
                check("sudo takes no usual, r > 1.5, or far-from-centre template", False, str(extra))
                break
    else:
        check("sudo takes no usual, r > 1.5, or far-from-centre template (caps 4 and 12)", True)

    lock = [(ref, person["appearances"][ref[0]]["extra"][ref[1]]) for ref in sw.pick(person, "lock", 36) if ref[1] is not None]
    check("lock keeps a chained 'usual' even 0.6 from the centre (beyond HARD)",
          any(extra["band"] == "usual" for _, extra in lock))
    check("lock keeps no ordinary template beyond HARD or r 2.2",
          all(extra["band"] == "usual" or (extra["r"] <= 2.2 and sw.distance(extra["encoding"], enc(0.0)) <= 0.55) for _, extra in lock))
    tiny = {"appearances": [{"label": "A", "time": 1, "encoding": enc(0.0),
                             "extra": [make_extra("a000", "near", 1.4, 3, 0.6, 5), make_extra("a030", "near", 2.3, 3, 0.1, 6),
                                       make_extra("a060", "far", 1.4, 3, 0.55, 7), make_extra("a090", "near", 1.5, 3, 0.40, 8),
                                       make_extra("a120", "near", 1.51, 3, 0.1, 9)]}]}
    check("lock drops HARD+ (a000) and r > 2.2 (a030), keeps exactly HARD (a060)",
          {key_of(tiny, ref)[1] for ref in sw.pick(tiny, "lock", 12)} == {"centre", "a060", "a090", "a120"},
          str({key_of(tiny, ref)[1] for ref in sw.pick(tiny, "lock", 12)}))
    check("sudo keeps r 1.5 at 0.40 (a090), drops r 1.51 (a120) and 0.55 away (a060)",
          {key_of(tiny, ref)[1] for ref in sw.pick(tiny, "sudo", 12)} == {"centre", "a090"},
          str({key_of(tiny, ref)[1] for ref in sw.pick(tiny, "sudo", 12)}))

    order = [key_of(person, ref) for ref in sw.pick(person, "lock", 36)][3:]
    poses = [pose for _, pose, _, _ in order if pose != "usual"]
    first_bins = []
    for pose in poses:
        if pose not in first_bins:
            first_bins.append(pose)
    check("the pose bins arrive in bit-reversal order: 0, 180, 90, 270 first",
          first_bins[:4] == ["a000", "a180", "a090", "a270"], str(first_bins[:4]))
    near_far = [band for _, pose, band, _ in order if pose in ("a000", "a180")][:2]
    check("and alternate the band: bin 0 near, bin 180 far", near_far == ["near", "far"], str(near_far))

    # the best-supported candidate wins its slot: highest support, then lowest r.
    contest = {"appearances": [{"label": "A", "time": 1, "encoding": enc(0.0), "extra": [
        make_extra("a000", "near", 1.8, 3, 0.1, 5), make_extra("a000", "near", 1.2, 3, 0.1, 6), make_extra("a000", "near", 2.0, 9, 0.1, 7)]}]}
    won = [key_of(contest, ref) for ref in sw.pick(contest, "lock", 2)][1]
    check("the best-supported candidate wins a slot (support 9 over lower r)", won[3] == 7, str(won))
    contest["appearances"][0]["extra"][2]["support"] = 3
    won = [key_of(contest, ref) for ref in sw.pick(contest, "lock", 2)][1]
    check("equal support: the lower r wins", won[3] == 6, str(won))

    check("a person with no extras yields just their centres", len(sw.pick({"appearances": [
        {"label": "A", "time": 1, "encoding": enc(0.0)}]}, "lock", 12)) == 1)
    check("no appearances yield nothing", sw.pick({}, "lock", 12) == [])


# --- run ----------------------------------------------------------------------------
FINDINGS = []


def main():
    test_pure()
    test_pose()
    test_noise()
    coupling_findings()
    test_gates()
    test_guard()
    test_support()
    test_pick()
    print()
    print("findings (the synthetic model, not a measurement; Phase 0 replaces them):")
    for line in FINDINGS:
        print("  " + line)
    print()
    print("e0: %d passed, %d failed" % (len(PASS), len(FAIL)))
    for name in FAIL:
        print("  FAILED: " + name)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
