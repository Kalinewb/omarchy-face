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
import json
import math
import os
import random
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# E0_ADMIN: another copy of the helper (dev/replay-recording.py compares two versions)
ADMIN = os.environ.get("E0_ADMIN") or os.path.join(REPO, "system", "omarchy-face-admin")

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
# The text splits where the capture half starts: the head is pure (the parent loads only
# that), the tail may import what a camera needs, lazily.
MARKER = "# ==== THE CAPTURE HALF"
HEAD = SOURCE.split(MARKER)[0] if SOURCE.count(MARKER) == 1 else SOURCE
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
    check("the text has exactly one marker between its pure and capture halves", SOURCE.count(MARKER) == 1)
    tree = ast.parse(HEAD)
    imported = sorted({alias.name.split(".")[0] for node in ast.walk(tree) if isinstance(node, ast.Import)
                       for alias in node.names} |
                      {node.module.split(".")[0] for node in ast.walk(tree) if isinstance(node, ast.ImportFrom)})
    check("imports only math and sys", imported == ["math", "sys"], str(imported))
    io_calls = sorted({node.func.id for node in ast.walk(tree) if isinstance(node, ast.Call)
                       and isinstance(node.func, ast.Name)
                       and node.func.id in ("open", "print", "input", "exec", "eval", "__import__", "compile")})
    check("no I/O or dynamic-code calls", not io_calls, str(io_calls))
    check("no file or device path in the pure half", not re.search(r"/dev/|/var/|/usr/|/etc/|video\d", HEAD))
    tail = SOURCE.split(MARKER)[1] if SOURCE.count(MARKER) == 1 else ""
    check("the capture half has no device argument and names no device node",
          not re.search(r"/dev/|video\d|--device|rgb", tail), "")
    check("dlib, cv2 and numpy are imported only inside functions (indented), never at the top level",
          not re.search(r"^(import|from) (dlib|cv2|numpy)", SOURCE, re.M))

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
        # As root will run it: `python3 -I -c "$SWEEP_PY"`. Without the parent's arguments it
        # must refuse cleanly rather than touch a camera.
        done = subprocess.run([sys.executable, "-I", "-c", SOURCE], capture_output=True, text=True,
                              cwd=scratch, stdin=subprocess.DEVNULL)
        check("run as a program with no arguments it declines (exit 2, no traceback)",
              done.returncode == 2 and "Traceback" not in done.stderr, done.stderr.strip()[-200:])
        # SR1 m6: the ninth argument (the debug flag) is 0 or 1 and nothing else, like every other argument
        good = ["simple", "1", "9,3,0,6", "60.0", "13.0", "3.0", "20.0", "5"]

        def run_child(arguments):
            return subprocess.run([sys.executable, "-I", "-c", SOURCE] + arguments, capture_output=True, text=True,
                                  cwd=scratch, stdin=subprocess.DEVNULL, pass_fds=())

        refused = [run_child(good + [value]) for value in ("2", "yes", "", "01", "true", "-1")]
        check("a ninth argument that is not 0 or 1 is refused before anything starts (exit 2, 'not started by omarchy-face-admin')",
              all(d.returncode == 2 and "not started by omarchy-face-admin" in d.stderr for d in refused),
              str([d.stderr.strip()[-60:] for d in refused]))
        check("so is a missing one (the old eight-argument form)",
              run_child(good).returncode == 2 and "not started by omarchy-face-admin" in run_child(good).stderr)
        accepted = [run_child(good + [value]) for value in ("0", "1")]
        check("0 and 1 are accepted (they get past argument parsing, to the reference descriptor the test does not provide)",
              all("not started by omarchy-face-admin" not in d.stderr for d in accepted),
              str([d.stderr.strip()[-60:] for d in accepted]))
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

    need = sw.SMOOTH_FRAMES + sw.STEADY_FRAMES
    still = [(0.0, 0.0)] * need
    check("%d still lit frames are steady (SMOOTH_FRAMES %d + STEADY_FRAMES %d)" % (need, sw.SMOOTH_FRAMES, sw.STEADY_FRAMES),
          sw.is_steady(still))
    check("one frame fewer is not enough history", not sw.is_steady(still[:-1]))
    for factor, expect in ((0.98, True), (1.02, False)):
        step = sw.STEADY_STEP * factor
        check("smoothed steps of %.3f (STEADY_STEP x %.2f) are %s" % (step, factor, "steady" if expect else "not steady"),
              sw.is_steady([(i * step, 0.0) for i in range(need)]) == expect)
    check("one jump in the last frames is not steady",
          not sw.is_steady([(0, 0)] * (need - 3) + [(1.0, 0)] * 3))
    check("an old jump that has left the window does not count",
          sw.is_steady([(0, 0), (0.5, 0)] + [(0.5, 0)] * need))
    jitter = [(0.12 * (-1) ** i, 0.0) for i in range(need)]
    check("rule J: jitter whose raw steps are 0.24 is steady once the mean of %d is taken, and is not at a step of 0.02" % sw.SMOOTH_FRAMES,
          sw.is_steady(jitter) and not sw.is_steady(jitter, step=0.02))

    # 3.1.3: the held-head jitter MEASURED (dev/fixtures/ir-held-head-stats.json, the `still` recording):
    # a head held still wanders by 0.4 u (about 6 degrees), slowly, which 3.1.2's mean of 3 and
    # step of 0.05 read as a moving head 96% of the time, so no Simple lap could leave the centre.
    held = json.load(open(os.path.join(HERE, "fixtures", "ir-held-head-stats.json")))
    rng = random.Random(11)

    def ar1(rho, sd, n):
        x, out, k = 0.0, [], sd * math.sqrt(1 - rho * rho)
        for _ in range(n):
            x = rho * x + rng.gauss(0, k)
            out.append(x)
        return out

    # the measured spread and the measured lag-1 autocorrelation (a held head drifts, it is not white noise)
    noise = list(zip(ar1(held["lag1_autocorrelation"]["u"], held["u_sd"], 6000),
                     ar1(held["lag1_autocorrelation"]["v"], held["v_sd"], 6000)))

    def share(width, step):
        steady = 0
        for i in range(10, len(noise)):
            window = noise[i - (width + sw.STEADY_FRAMES) + 1:i + 1]
            means = [(sum(p[0] for p in window[j:j + width]) / width, sum(p[1] for p in window[j:j + width]) / width)
                     for j in range(len(window) - width + 1)]
            steady += all(math.hypot(b[0] - a[0], b[1] - a[1]) < step for a, b in zip(means, means[1:]))
        return steady / float(len(noise) - 10)

    check("regression: a held head with the measured spread and drift is steady under 20%% of the time at 3.1.2's constants (mean of 3, 0.05): %.2f" % share(3, 0.05),
          share(3, 0.05) < 0.20)
    check("the helper's constants (mean of %d, step %.2f) read the same modelled head as steady at least 70%% of the time (the recording itself: 98%%): %.2f" % (sw.SMOOTH_FRAMES, sw.STEADY_STEP, share(sw.SMOOTH_FRAMES, sw.STEADY_STEP)),
          share(sw.SMOOTH_FRAMES, sw.STEADY_STEP) >= 0.70)
    # ...without calling a real turn steady: a head sweeping 0.3 u a frame (about 4.5 degrees, 34 degrees a second at 7.5 Hz)
    sweep = [(0.3 * i, 0.0) for i in range(need)]
    check("a head turning at 0.3 u per lit frame is not steady", not sw.is_steady(sweep))
    failing = sw.gate_failures(30, (0, 0, 10, 10), (400, 400), 60.0, 7.0, 0.4, 30.0, False)
    check("the debug trace's gate_failures names every gate a frame fails, in frame_word's order",
          failing == ["closer", "edge", "exposure", "blurry", "roll", "unsteady"], str(failing))
    check("...none for a frame that passes all of them", sw.gate_failures(80, (60, 60, 340, 340), (400, 400), 10, 1, 1.0, 0, True) == [])
    check("...and the word frame_word gives is the first of them",
          sw.frame_word(1, 30, (0, 0, 10, 10), (400, 400), 60.0, 7.0, 0.4, 30.0, False) == "closer")

    check("lap 2 wants farther from a 100 px lap 1 (80 px)", sw.lap2_want(100) == "far")
    check("lap 2 wants closer when farther would fall under the gate", sw.lap2_want(45) == "near")
    check("farther fits from 50 px up (50 x 0.8 = 40); below that lap 2 asks for closer",
          (sw.lap2_want(50), sw.lap2_want(49)) == ("far", "near"))
    check("lap 2 'farther' until eye <= 0.8 x lap 1", (sw.lap2_word(81, 100, "far"), sw.lap2_word(80, 100, "far")) == ("farther", None))
    check("lap 2 'closer' until eye >= 1.25 x lap 1", (sw.lap2_word(124, 100, "near"), sw.lap2_word(125, 100, "near")) == ("closer", None))


# --- 2b. the strobing emitter: a black frame is not a dark one ---------------------
def test_strobe():
    print("a strobing IR emitter: unlit frames are skipped, `dark` is a property of lit frames (3.1.2)")
    stats = json.load(open(os.path.join(HERE, "fixtures", "ir-strobe-stats.json")))
    lit, unlit, start = stats["lit"], stats["unlit"], stats["first_unlit_frames_of_the_stream"]
    check("the measured data leave a wide gap between the two classes (the rule's margin)",
          lit["darkness"]["max"] < sw.DARK_MAX < sw.STROBE_DARKNESS < start["darkness"]["min"]
          and lit["mean"]["min"] > sw.STROBE_MEAN > start["mean"]["max"],
          "%s %s" % (lit, start))
    check("the rule's constants are 85 percent and a raw mean of 12", (sw.STROBE_DARKNESS, sw.STROBE_MEAN) == (85.0, 12.0))

    def strobe_of(d, m, total=160000.0):
        return sw.is_strobe(total, d, m)

    check("every measured UNLIT frame is the off phase (min, median, max darkness; max mean)",
          all(strobe_of(d, unlit["mean"]["max"]) for d in (unlit["darkness"]["min"], unlit["darkness"]["median"], unlit["darkness"]["max"])))
    check("...the first unlit frames of a stream (89.3% dark, mean 6.3) too", strobe_of(start["darkness"]["min"], start["mean"]["max"]))
    check("...and an exactly black frame, and one with no pixels", strobe_of(100.0, 0.0) and sw.is_strobe(0, 100.0, 0.0))
    check("no measured LIT frame is (worst case: 37.3% dark, mean 31.4)",
          not strobe_of(lit["darkness"]["max"], lit["mean"]["min"]) and not strobe_of(lit["darkness"]["max"], lit["mean"]["max"]))
    check("regression (3.1.1 tested only exactly black frames): a real unlit frame, 99.8% dark with a mean of 1.5, is the off phase",
          strobe_of(99.8, 1.5))
    check("the rule is not an equality test: the pure text has no `darkness >= 100` or `== 100`",
          not re.search(r"darkness\s*(>=|==)\s*100", SOURCE))
    check("a dim LIT frame (80% dark, mean 25) is a dark frame, not a strobe frame", not strobe_of(80.0, 25.0))
    check("so is one that is dark but has some light (95% dark, mean 20) and one bright but flat (60% dark, mean 8)",
          not strobe_of(95.0, 20.0) and not strobe_of(60.0, 8.0))
    check("both halves of the rule are strict at their edges: darkness 85 passes, 84.99 does not; mean 12 does not, 11.99 does",
          (strobe_of(85.0, 5.0), strobe_of(84.99, 5.0), strobe_of(99.0, 12.0), strobe_of(99.0, 11.99)) == (True, False, False, True))

    # SR1 minor M3: the 2 s rule, as a pure function with its boundary
    check("the silence after which an all-blank stream stops being a strobe is 2 s", sw.STROBE_SILENCE == 2.0)
    check("a blank frame within 2 s of a lit one is the off phase; at exactly 2 s it is not (it is dark)",
          (sw.strobe_phase(True, 11.99, 10.0), sw.strobe_phase(True, 12.0, 10.0), sw.strobe_phase(True, 15.0, 10.0)) == (True, False, False))
    check("a lit frame is never skipped, and a blank one with nothing lit seen yet is not skipped either",
          (sw.strobe_phase(False, 10.5, 10.0), sw.strobe_phase(True, 10.5, None)) == (False, False))

    def refine(frames, strobe=0, black=0, dark=0, none=0, multi=0):
        return sw.refine_for({"frames": frames, "strobe": strobe, "black": black, "dark": dark, "none": none, "multi": multi})

    check("only black frames: black_frames", refine(40, strobe=40) == "black_frames")
    check("black frames called dark after the silence, and nothing lit: still black_frames", refine(40, strobe=30, black=10) == "black_frames")
    check("half the frames strobe-off, every lit one too dark: too_dark (not black_frames)",
          refine(40, strobe=20, dark=20) == "too_dark")
    check("the strobe frames do not count for or against `no_face`: 20 lit, 9 empty is not a verdict, 10 is",
          (refine(40, strobe=20, none=9), refine(40, strobe=20, none=10)) == (None, "no_face"))
    check("...nor for `multiple_faces`", refine(40, strobe=20, multi=10) == "multiple_faces")
    check("a lit frame with a face among the strobe frames means no refinement", refine(40, strobe=20, none=5, dark=3) is None)
    check("before the fix a stream of half black frames could never be too_dark: lit frames alone decide",
          refine(10, strobe=5, black=0, dark=5) == "too_dark" and refine(10, strobe=5, black=0, dark=4, none=1) is None)


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

    # 3.1.4: the guard is 3.1.3's. A sliding chain of the latest accepted frames was tried and withdrawn:
    # SR1 showed an accepted stranger frame becomes the chain (dev/SR1-notes.md)
    check("an owner frame 0.46 from the centre and over CHAIN of every template is still not ok (3.1.5: it is a band frame, which does not end the lap)",
          not sw.guard_ok(enc(0.46), [centre], centre))
    try:
        sw.guard_ok(enc(0.46), [centre], centre, recent=[enc(0.26)])
        has_recent = True
    except TypeError:
        has_recent = False
    check("regression: guard_ok takes no `recent` frames (a chain of accepted frames must not come back; e1 pins it end to end)",
          not has_recent and "recent" not in SOURCE.lower().replace("recently", ""))
    check("a stranger who gets ONE frame in (0.38 from the centre) does not make 0.46 a chain step",
          sw.guard_ok(enc(0.38), [centre], centre) and not sw.guard_ok(enc(0.46), [centre], centre))
    check("HARD is unchanged: 0.55 passes the centre test, 0.56 does not (chain wide open)",
          sw.guard_ok(enc(0.55), [enc(0.50)], centre) and not sw.guard_ok(enc(0.56), [enc(0.50)], centre))
    check("guard_distances returns what the guard compares: the centre and the nearest template (and nothing before a centre)",
          [round(x, 3) for x in sw.guard_distances(enc(0.46), [centre, enc(0.30)], centre)] == [0.46, 0.16]
          and sw.guard_distances(enc(0.1), [], None) == (None, None))
    # 3.1.5: three verdicts. Only a frame over HARD of the centre (the stranger bound) counts towards `changed`.
    verdict = sw.guard_verdict
    check("guard_verdict: ok within CHAIN of a template, band between CHAIN and HARD, beyond past HARD, ok before a centre",
          (verdict(enc(0.40), [centre], centre), verdict(enc(0.4001), [centre], centre),
           verdict(enc(0.55), [centre], centre), verdict(enc(0.5501), [centre], centre),
           verdict(enc(9.0), [], None)) == ("ok", "band", "band", "beyond", "ok"))
    check("a frame near a filled template is ok however far from the centre, until HARD",
          verdict(enc(0.52), [centre, enc(0.45)], centre) == "ok" and verdict(enc(0.60), [centre, enc(0.58)], centre) == "beyond")
    grid = [enc(x / 100.0) for x in range(0, 80)]
    check("guard_ok is exactly 'the verdict is ok' (3.1.3's refusal set is unchanged; only what the loop does with a refusal is new)",
          all(sw.guard_ok(e, [centre, enc(0.30)], centre) == (verdict(e, [centre, enc(0.30)], centre) == "ok") for e in grid))
    check("beyond is the stranger bound alone: it is HARD from the centre and nothing else, whatever the templates",
          all((verdict(e, t, centre) == "beyond") == (sw.distance(e, centre) > sw.HARD)
              for e in grid for t in ([centre], [centre, enc(0.30)], [centre, enc(0.30), enc(0.55)])))
    check("the loop gives a banded frame no part in the `changed` run (it never calls changed_step for one)",
          'if verdict == "band":' in SOURCE and 'changed_step(run_failed, verdict == "beyond")' in SOURCE
          and "changed_step(run_failed, bad)" not in SOURCE)
    check("the pose history cap is derived from SMOOTH_FRAMES + STEADY_FRAMES, not a literal 8 (SR1 m4)",
          "[-(SMOOTH_FRAMES + STEADY_FRAMES):]" in SOURCE and "[-8:]" not in SOURCE)
    check("the debug trace is written by one function that is also called when the lap ends (SR1 S3: guard_run reaches its real value)",
          "def trace_line(lap_end):" in SOURCE and SOURCE.count("trace_line(") >= 3)

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
    # The rules below are the plan's pick for Sudo, which SUDO_POLICY "full" selects; the
    # shipped "centre" policy is asserted at the end of this function.
    MODULE["SUDO_POLICY"] = "full"
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

    # SUDO_POLICY "centre", the shipped value: Sudo takes the centres and nothing else.
    MODULE["SUDO_POLICY"] = "centre"
    check("SUDO_POLICY ships as centre", MODULE["SUDO_POLICY"] == "centre" and sw.SUDO_POLICY == "centre")
    for cap in (1, 2, 3, 4, 12, 100):
        got = sw.pick(person, "sudo", cap)
        check("centre policy, Sudo cap %d: centres only, as many as fit" % cap,
              all(ref[1] is None for ref in got) and len(got) == min(cap, len(person["appearances"])), str(got))
    check("centre policy: all three appearances' centres are kept at the cap of 3 (a look is never dropped)",
          {key_of(person, ref) for ref in sw.pick(person, "sudo", 3)} == centres)
    lock_centre = [key_of(person, ref) for ref in sw.pick(person, "lock", 12)]
    MODULE["SUDO_POLICY"] = "full"
    lock_full = [key_of(person, ref) for ref in sw.pick(person, "lock", 12)]
    check("centre policy: Lock is not affected (the same picks under both words)", lock_centre == lock_full)
    for word in ("bogus", "", None):
        MODULE["SUDO_POLICY"] = word
        check("an unknown policy %r fails closed to centres" % (word,),
              all(ref[1] is None for ref in sw.pick(person, "sudo", 12)))
    MODULE["SUDO_POLICY"] = "centre"


# --- 6. plain turns, as a person turns (rules D, O, J) -------------------------------
def test_plain_turns():
    print("plain turns, decoupling, overshoot, held-head jitter")
    neutral = neutral_for()
    # Heads posed by PHYSICAL yaw or pitch through landmarks(), never by inverting the chain.
    right = uv_of(landmarks(-20, 0), neutral)
    left = uv_of(landmarks(20, 0), neutral)
    check("pose_decouple is the identity at c = 0, leaves u alone, and is symmetric in u",
          sw.pose_decouple(1.3, 0.7, 0.0) == (1.3, 0.7) and sw.pose_decouple(1.3, 0.7, 0.75)[0] == 1.3
          and sw.pose_decouple(-1.3, 0.7, 0.75)[1] == sw.pose_decouple(1.3, 0.7, 0.75)[1])
    check("a yaw-only 20 degree turn to your right reads bin 4 without it (the finding, asserted on the synthetic head)",
          sw.locate(*right)[0] == 4 and sw.locate(*left)[0] == 8, str((sw.locate(*right)[0], sw.locate(*left)[0])))

    # 3.1.5: COUPLING_C from the user's own live trace (dev/fixtures/live-coupling-3.1.4.json) and the
    # `guided` recording's big turns -- the synthetic head above leans quadratically, the real one
    # is a straight line (the fit below), so these are the measured tests, not the synthetic one.
    live = json.load(open(os.path.join(HERE, "fixtures", "live-coupling-3.1.4.json")))
    pts = [(y / 15.0, p / 15.0) for y, p in live["right_hold"] + live["left_hold"] + live["left_over"]]
    k_line = sum(abs(u) * v for u, v in pts) / sum(u * u for u, v in pts)
    c_quad = sum(u * u * v for u, v in pts) / sum(u ** 4 for u, v in pts)
    spread = lambda residuals: math.sqrt(sum(x * x for x in residuals) / len(residuals))
    check("COUPLING_C is the measured 0.75: the least-squares line through the live samples (%.2f) and the recording's medians (0.66-0.77)"
          % k_line, sw.COUPLING_C == 0.75 and abs(k_line - 0.75) < 0.1)
    check("the straight line leaves less scatter than the quadratic form on the same samples (why the form changed)",
          spread([v - k_line * abs(u) for u, v in pts]) < spread([v - c_quad * u * u for u, v in pts]) - 0.05,
          "%.3f vs %.3f" % (spread([v - k_line * abs(u) for u, v in pts]), spread([v - c_quad * u * u for u, v in pts])))
    held_right = [(y / 15.0, p / 15.0) for y, p in live["right_hold"]]
    held_left = [(y / 15.0, p / 15.0) for y, p in live["left_hold"]]
    inside = lambda samples, k, c: sum(sw.in_target(*sw.pose_decouple(u, v, c), k, False, sw.SIMPLE_WEDGE_HALF) for u, v in samples)
    check("the user's right turn: 0 of 12 seconds inside Simple's right wedge before, all 12 after",
          inside(held_right, 3, 0.0) == 0 and inside(held_right, 3, sw.COUPLING_C) == 12,
          str((inside(held_right, 3, 0.0), inside(held_right, 3, sw.COUPLING_C))))
    check("their left turn (the seconds inside R_MAX): 0 of 4 before, all 4 after",
          inside(held_left, 9, 0.0) == 0 and inside(held_left, 9, sw.COUPLING_C) == 4,
          str((inside(held_left, 9, 0.0), inside(held_left, 9, sw.COUPLING_C))))
    over = [sw.pose_decouple(y / 15.0, p / 15.0, sw.COUPLING_C) for y, p in live["left_over"]]
    check("and a left turn past 34 degrees stays `over` (r past R_MAX) however it is decoupled: rule O is not touched",
          all(math.hypot(*uv) > sw.R_MAX for uv in over), str([round(math.hypot(*uv), 2) for uv in over]))
    check("a nod alone is not moved by it: at 0 of yaw the pitch is exactly what was measured",
          sw.pose_decouple(0.0, -1.2) == (0.0, -1.2) and sw.pose_decouple(0.0, 1.5) == (0.0, 1.5))
    check("up and down at a few degrees of yaw keep their bins (a 5 degree yaw moves pitch by under 4 degrees)",
          sw.locate(*sw.pose_decouple(0.33, -1.2))[0] == 0 and sw.locate(*sw.pose_decouple(0.33, 1.5))[0] == 6,
          str((sw.locate(*sw.pose_decouple(0.33, -1.2)), sw.locate(*sw.pose_decouple(0.33, 1.5)))))
    up, down = uv_of(landmarks(0, -12), neutral), uv_of(landmarks(0, 12), neutral)
    check("a pure 12 degree nod up and down read bins 0 and 6", (sw.locate(*up)[0], sw.locate(*down)[0]) == (0, 6),
          str((sw.locate(*up), sw.locate(*down))))
    far = uv_of(landmarks(0, -20), neutral)
    check("above R_MAX a frame that passed every gate is `over` (rule O)",
          sw.over_word(None, math.hypot(*far)) == "over" and sw.over_word(None, 2.2) is None
          and sw.over_word("blurry", 9.0) == "blurry")

    # held-head jitter: smoothed is_steady, at the smallest STEADY_STEP that passes on the synthetic model.
    rng = random.Random(5)
    for sigma in (0.25, 0.5):
        base = landmarks(0, 0, scale=75.6 / EYE_MM)
        history, flags = [], {}
        for _ in range(4000):
            noisy = [(x + rng.gauss(0, sigma), y + rng.gauss(0, sigma)) for x, y in base]
            history.append(uv_of(noisy, neutral))
        found = None
        for step in (0.05, 0.075, 0.10, 0.125, 0.15, 0.20, 0.25, 0.30):
            share = sum(sw.is_steady(history[max(0, i - 7):i + 1], step=step) for i in range(7, 4000)) / 3993.0
            if share >= 0.8:
                found = (step, share)
                break
        check("a still head with %.2f px of jitter is steady in 80%% of frames at some STEADY_STEP" % sigma,
              found is not None, "")
        FINDINGS.append("held-head jitter %.2f px: smallest STEADY_STEP giving 80%% steady frames is %s (share %.2f); "
                        "the module's placeholder is %s" % (sigma, found[0] if found else None, found[1] if found else 0, sw.STEADY_STEP))


# --- 7. the sequencer: validation, wedge, dwell, order, patience, Done, verbs -----------
ALL12 = list(range(12))


def prior(**changes):
    base = {"state": "ready", "kept_mode": None, "kept_laps": [], "centre": False, "stored": 0}
    base.update(changes)
    return base


def test_sequencer():
    print("sequencer")
    vs = sw.valid_sweep
    check("simple / lap 1 / [9,3,0,6] is accepted and echoed", vs("simple", 1, [9, 3, 0, 6], prior()) == ([9, 3, 0, 6], None))
    check("advanced with all 12 in any order is accepted, returned ascending",
          vs("advanced", 1, list(reversed(ALL12)), prior()) == (ALL12, None))
    bad = {
        "simple [3,9,0,6]": ("simple", 1, [3, 9, 0, 6], prior()), "simple [9,3,0]": ("simple", 1, [9, 3, 0], prior()),
        "simple five entries": ("simple", 1, [9, 3, 0, 6, 1], prior()), "simple lap 2": ("simple", 2, [9, 3, 0, 6], prior(state="swept")),
        "simple over 6 stored": ("simple", 1, [9, 3, 0, 6], prior(stored=6)),
        "advanced one bin": ("advanced", 1, [3], prior()), "advanced []": ("advanced", 1, [], prior()),
        "advanced 11": ("advanced", 1, ALL12[:11], prior()), "advanced 13": ("advanced", 1, ALL12 + [0], prior()),
        "advanced repeat": ("advanced", 1, [0] * 12, prior()), "advanced -1": ("advanced", 1, ALL12[:11] + [-1], prior()),
        "advanced 12": ("advanced", 1, ALL12[:11] + [12], prior()), "advanced True": ("advanced", 1, ALL12[:11] + [True], prior()),
        "advanced 3.0": ("advanced", 1, [3.0] + ALL12[1:], prior()), "advanced '3'": ("advanced", 1, ["3"] + ALL12[1:], prior()),
        "advanced None": ("advanced", 1, [None] + ALL12[1:], prior()), "advanced not a list": ("advanced", 1, "0123", prior()),
        "lap 0": ("advanced", 0, ALL12, prior()), "lap 3": ("advanced", 3, ALL12, prior()), "lap True": ("advanced", True, ALL12, prior()),
        "lap 1.0": ("advanced", 1.0, ALL12, prior()),
        "mode lap": ("lap", 1, ALL12, prior()), "mode ''": ("", 1, ALL12, prior()), "mode None": (None, 1, ALL12, prior()),
        "usual [3]": ("usual", 1, [3], prior(state="swept", kept_mode="advanced", centre=True)),
        "usual lap 2": ("usual", 2, [], prior(state="swept", kept_mode="advanced", centre=True)),
        "advanced lap 2 no prior lap 1": ("advanced", 2, ALL12, prior(state="swept")),
        "advanced lap 2 after a simple lap": ("advanced", 2, ALL12, prior(state="swept", kept_mode="simple", kept_laps=[1])),
        "usual no centre": ("usual", 1, [], prior(state="swept", kept_mode="advanced", centre=False)),
        "usual after simple": ("usual", 1, [], prior(state="swept", kept_mode="simple", centre=True)),
        "a sweep while one runs": ("simple", 1, [9, 3, 0, 6], prior(state="running")),
    }
    refused = {name: vs(*args)[1] is not None and vs(*args)[0] is None for name, args in bad.items()}
    check("validation refuses all %d bad sweeps" % len(bad), all(refused.values()), str([n for n, v in refused.items() if not v]))
    check("5 stored templates are accepted for Simple (rule R), 6 are not",
          vs("simple", 1, [9, 3, 0, 6], prior(stored=5))[1] is None and vs("simple", 1, [9, 3, 0, 6], prior(stored=6))[1] is not None)
    check("advanced lap 2 after a kept Advanced lap 1, and usual after one with a centre, are accepted",
          vs("advanced", 2, ALL12, prior(state="swept", kept_mode="advanced", kept_laps=[1]))[1] is None
          and vs("usual", 1, None, prior(state="swept", kept_mode="advanced", centre=True)) == ([], None))

    def uv(angle, r):
        return r * math.sin(math.radians(angle)), -r * math.cos(math.radians(angle))
    inn = sw.in_target
    check("bin 3 holds at 90 degrees and at 105.0 but not 105.1 (Advanced)",
          inn(*uv(90, 1.5), 3, False, 15) and inn(*uv(105.0, 1.5), 3, False, 15) and not inn(*uv(105.1, 1.5), 3, False, 15))
    check("while holding it widens to 110.0 and not 110.1", inn(*uv(110.0, 1.5), 3, True, 15) and not inn(*uv(110.1, 1.5), 3, True, 15))
    check("Simple's 30 degree half-width holds at 120", inn(*uv(120, 1.5), 3, False, 30))
    check("r 0.99 out, 1.0 and 2.2 in, 2.21 out",
          (inn(*uv(90, 0.99), 3, False, 15), inn(*uv(90, 1.0), 3, False, 15), inn(*uv(90, 2.2), 3, False, 15),
           inn(*uv(90, 2.21), 3, False, 15)) == (False, True, True, False))
    check("bin 0 wraps: 350 degrees is in, 20 is out", inn(*uv(350, 1.5), 0, False, 15) and not inn(*uv(20, 1.5), 0, False, 15))

    d = sw.new_dwell()
    seventh = None
    for i in range(10):
        d = sw.dwell_step(d, i * 0.14, True, True)
        if seventh is None and d["dwell"] >= sw.TARGET_DWELL:
            seventh = i + 1
    check("frames 0.14 s apart reach TARGET_DWELL at the seventh (the first credits nothing)", seventh == 7, str(seventh))
    d = sw.dwell_step(sw.dwell_step(sw.new_dwell(), 0.0, True, True), 1.0, True, True)
    check("a 1 s hole credits only DWELL_GAP_MAX", abs(d["dwell"] - 0.3) < 1e-9, str(d))
    d = sw.dwell_step(sw.dwell_step(sw.new_dwell(), 0.0, True, True), 0.1, True, True)
    kept = sw.dwell_step(d, 0.3, False, False)
    check("a frame that fails a gate adds nothing and does not reset", kept == d)
    d = sw.dwell_step(sw.dwell_step(sw.new_dwell(), 0.0, True, True), 0.2, True, True)
    out = sw.dwell_step(d, 1.0, True, False)
    check("0.49 s out of the wedge keeps the dwell", sw.dwell_step(out, 1.49, True, True)["dwell"] >= d["dwell"] and d["dwell"] > 0)
    check("0.50 s resets it", sw.dwell_step(out, 1.5, True, True)["dwell"] == 0.0)
    full = {"dwell": 9.0, "last": 0.0, "out": None}
    check("the fraction caps at 1", sw.dwell_fraction(full) == 1.0 and sw.dwell_fraction(sw.new_dwell()) == 0.0)
    check("a steady head with unsupported pictures stays under 1 (no template)",
          sw.target_progress(1.0, 1) == 0.5 and sw.target_progress(1.0, 2) == 1.0 and sw.target_progress(0.4, 5) == 0.4)

    ct = sw.current_target
    s4 = [9, 3, 0, 6]
    check("Simple: the centre first, then 9, 3, 0, 6",
          [ct("simple", s4, set(), set(), False, None), ct("simple", s4, set(), set(), True, None),
           ct("simple", s4, {9}, set(), True, None), ct("simple", s4, {9, 3}, set(), True, None),
           ct("simple", s4, {9, 3, 0}, set(), True, None)] == ["centre", 9, 3, 0, 6])
    check("a head in 3's wedge while 9 is current changes nothing", ct("simple", s4, set(), set(), True, 3) == 9)
    check("a skipped target moves on; none when all are resolved",
          ct("simple", s4, set(), {9}, True, None) == 3 and ct("simple", s4, {9, 3}, {0, 6}, True, None) is None)
    check("Advanced: the centre, then the head's unfilled bin, else none",
          ct("advanced", ALL12, set(), set(), False, 4) == "centre" and ct("advanced", ALL12, set(), set(), True, 4) == 4
          and ct("advanced", ALL12, {4}, set(), True, 4) is None and ct("advanced", ALL12, set(), set(), True, None) is None)

    mark = (0.0, 0.0)
    became = 100.0
    since = sw.patience_since(mark, became)
    check("PROMPT_LEAD pushes `since` to became + 3", since == 103.0)
    check("patience: 9.99 s no, 10.0 s yes", (sw.patience_expired("simple", 103.0, 112.99), sw.patience_expired("simple", 103.0, 113.0)) == (False, True))
    mark = sw.progress_mark(mark, 0.25, 106.0)
    check("a rise of the mark restarts the clock", sw.patience_since(mark, became) == 106.0)
    mark2 = sw.progress_mark(mark, 0.1, 108.0)
    check("the mark is a high-water mark: a dwell that resets and rises again does not restart it",
          mark2 == mark and sw.progress_mark(mark2, 0.2, 109.0) == mark and sw.progress_mark(mark2, 0.26, 109.0) == (0.26, 109.0))
    check("never in Advanced", not sw.patience_expired("advanced", 0.0, 1e9))
    # a steady head whose pictures are 0.4 apart: supported stuck at 1 keeps dwell full but the mark stops at 0.5
    mark, t = (0.0, 0.0), 0.0
    for i in range(1, 400):
        t = i * 0.1
        dwell_part = min(1.0, t / sw.TARGET_DWELL)
        mark = sw.progress_mark(mark, sw.target_progress(dwell_part, 1), t)
    check("a steady head whose pictures disagree (supported stuck at 1) is skipped at PROMPT_LEAD + TARGET_PATIENCE",
          mark[0] == 0.5 and sw.patience_expired("simple", sw.patience_since(mark, 0.0), 13.0)
          and not sw.patience_expired("simple", sw.patience_since(mark, 0.0), 12.9), str(mark))

    cf = sw.can_finish
    check("Done, Simple: centre + 4 yes; centre + 2 filled (2 skipped or unresolved) yes; centre + 1 no; no centre no",
          cf("simple", True, {9, 3, 0, 6}) and cf("simple", True, {9, 3}) and cf("simple", True, {0, 6})
          and not cf("simple", True, {9}) and not cf("simple", False, {9, 3, 0, 6}))
    check("Done, Advanced equals done_ready: centre + 4 yes, 3 no",
          cf("advanced", True, {0, 1, 2, 3}) is sw.done_ready(True, 4) and not cf("advanced", True, {0, 1, 2}) and not cf("advanced", False, set(ALL12)))
    le = sw.lap_ended
    check("lap end, Simple: all four resolved yes, three no, not at the second fill",
          le("simple", s4, {9, 3}, {0, 6}, 0.0, 5.0) == "resolved" and le("simple", s4, {9, 3}, {0}, 0.0, 5.0) is None
          and le("simple", s4, {9, 3}, set(), 0.0, 5.0) is None)
    check("the Simple ceiling: 59.9 s no, 60.0 s yes", (le("simple", s4, set(), set(), 0.0, 59.9), le("simple", s4, set(), set(), 0.0, 60.0)) == (None, "ceiling"))
    check("Advanced ends at 90 s and when all 12 are filled",
          le("advanced", ALL12, set(), set(), 0.0, 90.0) == "ceiling" and le("advanced", ALL12, set(ALL12), set(), 0.0, 5.0) == "resolved"
          and le("advanced", ALL12, set(ALL12[:11]), set(), 0.0, 5.0) is None)
    check("a lowered ceiling (the test override) ends a lap sooner", le("simple", s4, set(), set(), 0.0, 5.0, {"simple": 5.0}) == "ceiling")
    lr = sw.lap_result
    check("lap result: 3 filled and 1 unresolved at the ceiling is swept; 1 filled is too_few; no centre is lap_timeout",
          (lr("simple", True, {9, 3, 0}), lr("simple", True, {9}), lr("simple", False, set())) == ("swept", "too_few", "lap_timeout"))
    check("lap result: all resolved with 2 filled swept, with 1 filled too_few",
          (lr("simple", True, {9, 3}), lr("simple", True, {6})) == ("swept", "too_few"))
    check("lap result, Advanced at 90 s: centre + 3 too_few, centre + 4 swept, no centre lap_timeout",
          (lr("advanced", True, {0, 1, 2}), lr("advanced", True, {0, 1, 2, 3}), lr("advanced", False, {0, 1, 2, 3})) == ("too_few", "swept", "lap_timeout"))

    va = sw.verb_allowed
    cells = [
        ("ready", "sweep", 1, None, False, "allow"), ("ready", "sweep", 2, None, False, "refuse"),
        ("ready", "capture", None, None, False, "allow"), ("ready", "capture", None, None, True, "refuse"),
        ("ready", "done", None, None, False, "allow"), ("ready", "done", None, None, True, "refuse"),
        ("ready", "finish", None, None, False, "ignore"), ("ready", "abort", None, None, False, "ignore"),
        ("ready", "trial", None, None, False, "refuse"), ("ready", "usual", 1, None, False, "refuse"),
        ("running", "finish", None, None, True, "allow"), ("running", "abort", None, None, True, "allow"),
        ("running", "sweep", 1, None, True, "refuse"), ("running", "trial", None, None, True, "refuse"),
        ("running", "done", None, None, True, "refuse"), ("running", "capture", None, None, True, "refuse"),
        ("swept", "done", None, "simple", True, "allow"), ("swept", "sweep", 1, "simple", True, "allow"),
        ("swept", "sweep", 2, "advanced", True, "allow"), ("swept", "sweep", 2, "simple", True, "refuse"),
        ("swept", "trial", None, "advanced", True, "allow"), ("swept", "trial", None, "simple", True, "refuse"),
        ("swept", "usual", 1, "advanced", True, "allow"), ("swept", "usual", 1, "simple", True, "refuse"),
        ("swept", "finish", None, "advanced", True, "ignore"), ("swept", "abort", None, "advanced", True, "ignore"),
        ("swept", "capture", None, "advanced", True, "refuse"),
        ("trialing", "abort", None, "advanced", True, "allow"), ("trialing", "sweep", 1, "advanced", True, "refuse"),
        ("trialing", "finish", None, "advanced", True, "ignore"), ("closed", "done", None, None, True, "refuse"),
    ]
    wrong = [c for c in cells if va(c[0], c[1], c[2], c[3], c[4]) != c[5]]
    check("table V: all %d cells" % len(cells), not wrong, str(wrong))

    tb = sw.track_bins
    bins = tb([9, 3, 0, 6], {9: 1.0, 3: 0.456, 5: 0.9})
    check("track_bins: 12 numbers, non-targets exactly 0.0, rounded to 2 decimals, Simple non-zero only at 9, 3, 0, 6",
          len(bins) == 12 and [k for k, x in enumerate(bins) if x] == [3, 9] and bins[3] == 0.46 and bins[5] == 0.0)
    person = {"appearances": [{"label": "A", "time": 1, "encoding": enc(0.0), "extra": [
        make_extra(sw.pose_name(k), "near", 1.3, 2, 0.1, 10 + k) for k in (9, 3, 0, 6)]}]}
    MODULE["SUDO_POLICY"] = "full"
    sudo = [key_of(person, r)[1] for r in sw.pick(person, "sudo", 4)]
    lock = [key_of(person, r)[1] for r in sw.pick(person, "lock", 12)]
    flipped = {"appearances": [dict(person["appearances"][0], extra=list(reversed(person["appearances"][0]["extra"])))]}
    check("pick: centre + Simple's four: Sudo cap 4 gives the centre and bins 0, 3, 6; Lock all five; either input order",
          sudo == ["centre", "a000", "a090", "a180"] and lock == ["centre", "a000", "a090", "a180", "a270"]
          and [key_of(flipped, r)[1] for r in sw.pick(flipped, "sudo", 4)] == sudo
          and [key_of(flipped, r)[1] for r in sw.pick(flipped, "lock", 12)] == lock, str((sudo, lock)))
    MODULE["SUDO_POLICY"] = "centre"
    check("pick under the shipped centre policy: Sudo gets the centre alone, Lock all five",
          [key_of(person, r)[1] for r in sw.pick(person, "sudo", 4)] == ["centre"]
          and [key_of(person, r)[1] for r in sw.pick(person, "lock", 12)] == lock)
    check("the code and word enums are the plan's twelve and ten",
          len(sw.CODES) == 12 and len(set(sw.CODES)) == 12 and len(sw.GATE_WORDS) == 10)
    check("finite() rejects bools, NaN, Infinity and 1e400 and accepts ints and floats",
          not any(sw.finite(x) for x in (True, float("nan"), float("inf"), 10 ** 400, "1", None))
          and sw.finite(0) and sw.finite(-1.5))


# --- run ----------------------------------------------------------------------------
FINDINGS = []


def main():
    test_pure()
    test_pose()
    test_noise()
    coupling_findings()
    test_gates()
    test_strobe()
    test_guard()
    test_support()
    test_pick()
    test_plain_turns()
    test_sequencer()
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
