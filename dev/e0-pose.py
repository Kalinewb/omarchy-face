#!/usr/bin/env python3

"""E0: the enrolment helper's pure half (the dot scan's), tested without a camera (plan-face-enroll.md 7.1).

    dev/e0-pose.py

It pulls SWEEP_PY out of system/omarchy-face-admin -- the text root will run, not a
copy -- and drives its pure functions with landmarks drawn from a canonical 3D face
turned by known angles (orthographic, millimetres, (chosen) like every number the
module marks). Standard library only: no numpy, no dlib, no cv2, no camera.

What it asserts is the chain landmarks -> gates -> guard -> medoid -> pick, and the
dot scan's own pure functions. The 3.1.x Advanced scan (pose bins, laps, steadiness) is
gone from the helper as of 3.3.0, and so are its tests; what stored Advanced
appearances still need (`pick`, the bands) is tested here on records shaped like theirs.

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
# E0_ADMIN: another copy of the helper, to run the same checks against (an older release, say)
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
        # SR1 m6: the last argument (the debug flag) is 0 or 1 and nothing else, like every other argument
        good = ["dot", "centre", "20.0", "3", "9"]

        def run_child(arguments):
            return subprocess.run([sys.executable, "-I", "-c", SOURCE] + arguments, capture_output=True, text=True,
                                  cwd=scratch, stdin=subprocess.DEVNULL, pass_fds=())

        refused = [run_child(good + [value]) for value in ("2", "yes", "", "01", "true", "-1")]
        check("a last argument that is not 0 or 1 is refused before anything starts (exit 2, 'not started by omarchy-face-admin')",
              all(d.returncode == 2 and "not started by omarchy-face-admin" in d.stderr for d in refused),
              str([d.stderr.strip()[-60:] for d in refused]))
        check("so is a missing one (the old six-argument form)",
              run_child(good).returncode == 2 and "not started by omarchy-face-admin" in run_child(good).stderr)
        accepted = [run_child(good + [value]) for value in ("0", "1")]
        check("0 and 1 are accepted (they get past argument parsing, to the reference descriptor the test does not provide)",
              all("not started by omarchy-face-admin" not in d.stderr for d in accepted),
              str([d.stderr.strip()[-60:] for d in accepted]))
        check("it left nothing behind in its directory", os.listdir(scratch) == ["sweep_py.txt"])


# --- 2. gates ---------------------------------------------------------------------
def test_gates():
    print("gates flip at their boundary")
    size = (400, 400)
    inside = (60, 60, 340, 340)

    def word(**changes):
        arguments = dict(faces=1, eye=80, box=inside, size=size, dark=10, saturated=1, roll=0)
        arguments.update(changes)
        return sw.frame_word(**arguments)

    check("a good frame passes", word() is None)
    check("no face is 'searching'", word(faces=0) == "searching")
    check("two faces is 'multiple'", word(faces=2) == "multiple")
    check("EYE_MIN is 36 (3.2.1; it was 40, and the user's own seat is 39-45): eye 35 closer, 36 passes, 40 passes",
          sw.EYE_MIN == 36 and (word(eye=35), word(eye=36), word(eye=40)) == ("closer", None, None), str((word(eye=35), word(eye=36))))
    check("eye 150 passes, 151 farther", (word(eye=150), word(eye=151)) == (None, "farther"))
    margin = 0.04 * 400
    check("a box exactly 4% from each border passes",
          word(box=(margin, margin, 400 - margin, 400 - margin)) is None)
    check("a box a hair inside 4% on each border is 'edge'",
          all(word(box=box) == "edge" for box in ((margin - 0.1, 60, 340, 340), (60, margin - 0.1, 340, 340),
                                                  (60, 60, 400 - margin + 0.1, 340), (60, 60, 340, 400 - margin + 0.1))))
    check("dark share 50 passes, 51 is 'dark'", (word(dark=50), word(dark=51)) == (None, "dark"))
    check("saturation 6 passes, 6.1 is 'dark'", (word(saturated=6.0), word(saturated=6.1)) == (None, "dark"))
    check("roll 25 passes, 26 is 'hold' (either way)",
          (word(roll=25), word(roll=26), word(roll=-25), word(roll=-26)) == (None, "hold", None, "hold"))
    check("a face too small to see wins over an edge it also touches", word(eye=30, box=(0, 0, 40, 40)) == "closer")
    check("the sweep's sharpness and steadiness gates are gone: frame_word takes seven arguments and `blurry`/`unsteady` are not words of it",
          sw.frame_word.__code__.co_argcount == 7 and "blurry" not in HEAD and "unsteady" not in HEAD)


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


# --- 3. the same-person guard -----------------------------------------------------
def test_guard():
    print("same-person guard")
    centre = enc(0.0)
    check("CHAIN 0.40, HARD 0.55, SUPPORT 0.30, 5 frames are the constants",
          (sw.CHAIN, sw.HARD, sw.SUPPORT, sw.CHANGED_FRAMES) == (0.40, 0.55, 0.30, 5))
    verdict = sw.guard_verdict
    templates = [centre, enc(-0.20)]
    check("guard_verdict: ok within CHAIN of a template, band between CHAIN and HARD, beyond past HARD, ok before a centre",
          (verdict(enc(0.40), [centre], centre), verdict(enc(0.4001), [centre], centre), verdict(enc(0.55), [centre], centre),
           verdict(enc(0.5501), [centre], centre), verdict(enc(9.0), [], None)) == ("ok", "band", "band", "beyond", "ok"))
    check("a frame near a template is ok however far from the centre, until HARD",
          verdict(enc(0.52), [centre, enc(0.45)], centre) == "ok" and verdict(enc(0.60), [centre, enc(0.58)], centre) == "beyond")
    check("a chain follows a slow drift (0.35 steps) up to HARD, but a jump straight to 0.50 is not a chain step",
          verdict(enc(0.35), [centre], centre) == "ok" and verdict(enc(0.50), [centre, enc(0.35)], centre) == "ok"
          and verdict(enc(0.50), [centre], centre) == "band")
    check("the chain is the NEAREST template, not every one", verdict(enc(0.50), [centre, enc(0.20), enc(0.35)], centre) == "ok")
    check("a stranger who gets ONE frame in (0.38 from the centre) does not make 0.46 a chain step",
          verdict(enc(0.38), [centre], centre) == "ok" and verdict(enc(0.46), [centre], centre) == "band")
    grid = [enc(x / 100.0) for x in range(0, 80)]
    check("beyond is exactly over HARD of the centre, whatever the templates",
          all((verdict(e, t, centre) == "beyond") == (sw.distance(e, centre) > sw.HARD)
              for e in grid for t in ([centre], templates, [centre, enc(0.30), enc(0.55)])))
    check("over HARD returns before any template is looked at (3.1.3's order): a malformed template cannot raise for it",
          verdict(enc(0.70), [None], centre) == "beyond")
    check("the per-pose bounds are arguments: the top pose's 0.56/0.60 pass a frame 0.58 from the centre that 0.40/0.55 call beyond",
          verdict(enc(0.58), [centre, enc(0.50)], centre, 0.56, 0.60) == "ok" and verdict(enc(0.58), [centre, enc(0.50)], centre) == "beyond")
    check("the guard is 3.1.3's: no `recent` frames, no sliding chain (an accepted stranger frame must not become the chain)",
          "recent" not in HEAD.lower().replace("recently", "") and "guard_ok" not in HEAD and "changed_step" not in HEAD)


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
                             "extra": [make_extra("a000", "near", 1.4, 3, 0.63, 5), make_extra("a030", "near", 2.3, 3, 0.1, 6),
                                       make_extra("a060", "far", 1.4, 3, 0.55, 7), make_extra("a090", "near", 1.5, 3, 0.40, 8),
                                       make_extra("a120", "near", 1.51, 3, 0.1, 9)]}]}
    check("lock drops past DOT_TOP_HARD 0.60 (a000 at 0.63) and r > 2.2 (a030), keeps exactly HARD (a060)",
          {key_of(tiny, ref)[1] for ref in sw.pick(tiny, "lock", 12)} == {"centre", "a060", "a090", "a120"},
          str({key_of(tiny, ref)[1] for ref in sw.pick(tiny, "lock", 12)}))
    topish = {"appearances": [{"label": "A", "time": 1, "encoding": enc(0.0),
                               "extra": [make_extra("a000", "near", 1.6, 3, 0.60, 5), make_extra("a150", "near", 1.6, 3, 0.56, 6),
                                         make_extra("a090", "near", 1.6, 3, 0.56, 7), make_extra("a180", "near", 1.6, 3, 0.5501, 8)]}]}
    check("lock takes the TOP pose (a000) up to DOT_TOP_HARD (0.60) from its centre and every other pose only up to HARD (0.55): a150, a090 at 0.56 and a180 at 0.5501 are dropped",
          {key_of(topish, ref)[1] for ref in sw.pick(topish, "lock", 12)} == {"centre", "a000"},
          str({key_of(topish, ref)[1] for ref in sw.pick(topish, "lock", 12)}))
    topish["appearances"][0]["extra"][0] = make_extra("a000", "near", 1.6, 3, 0.6001, 5)
    check("...and a000 at 0.6001 is dropped; sudo (policy centre) never takes it", "a000" not in {key_of(topish, ref)[1] for ref in sw.pick(topish, "lock", 12)}
          and {key_of(topish, ref)[1] for ref in sw.pick(topish, "sudo", 12)} == {"centre"})
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


# --- 7. the sequencer: verbs, the code list ----------------------------------------
def test_sequencer():
    print("sequencer")
    va = sw.verb_allowed
    cells = [
        ("ready", "capture", False, "allow"), ("ready", "capture", True, "refuse"),
        ("ready", "done", False, "allow"), ("ready", "done", True, "refuse"),
        ("ready", "dot", False, "allow"), ("ready", "dot", True, "allow"),
        ("running", "dot", True, "refuse"), ("running", "done", True, "refuse"), ("running", "capture", True, "refuse"),
        ("swept", "done", True, "allow"), ("swept", "dot", True, "allow"), ("swept", "capture", True, "refuse"),
        ("closed", "done", True, "refuse"), ("closed", "dot", False, "refuse"),
        # 3.3.0: the Advanced scan's verbs are not in the table at all
        ("ready", "sweep", False, "refuse"), ("swept", "sweep", True, "refuse"), ("swept", "trial", True, "refuse"),
        ("swept", "usual", True, "refuse"), ("ready", "finish", False, "refuse"), ("running", "abort", True, "refuse"),
    ]
    wrong = [c for c in cells if va(c[0], c[1], c[2]) != c[3]]
    check("table V: all %d cells (the sweep verbs are refused, not ignored)" % len(cells), not wrong, str(wrong))
    check("the sweep's names are gone from the pure half: no sweep child, laps, bins track, dwell or lap clock",
          not re.search(r"def (valid_sweep|in_target|dwell_step|lap_ended|lap_result|track_bins|current_target|settle_verdict"
                        r"|refine_for|neutral_of|pose_uv|lap2_word|lap2_want|scale_word|is_steady|coupling)", SOURCE))
    check("the code list is the dot scan's twelve (the plan's ten and `face_cut_off`, `face_tilted`)",
          len(sw.CODES) == 12 and len(set(sw.CODES)) == 12 and set(sw.DOT_FAIL_CODES) <= set(sw.CODES))
    check("finite() rejects bools, NaN, Infinity and 1e400 and accepts ints and floats",
          not any(sw.finite(x) for x in (True, float("nan"), float("inf"), 10 ** 400, "1", None))
          and sw.finite(0) and sw.finite(-1.5))


# --- 9. the dot scan's pure half (3.2.0) -----------------------------------------------
def test_dot():
    print("the dot scan")
    check("the card's poses are the centre, then left, top, right, bottom",
          sw.DOT_POSES == ("centre", "left", "top", "right", "bottom"))
    check("each pose but the centre is stored as the pose bin 3.1.x's Simple lap held (left 9, top 0, right 3, bottom 6), a legal stored pose",
          sw.DOT_BINS == {"left": 9, "top": 0, "right": 3, "bottom": 6}
          and sorted(sw.DOT_BINS.values()) == [0, 3, 6, 9]
          and [sw.pose_name(k) for k in sw.DOT_BINS.values()] == ["a270", "a000", "a090", "a180"])
    check("the nominal r is inside what the store accepts (0..4) and R_MAX, and past SUDO_R_MAX (no policy could give these to Sudo by r)",
          1.0 <= sw.DOT_R <= sw.R_MAX and sw.DOT_R <= 4 and sw.DOT_R > sw.SUDO_R_MAX)
    check("every code the child may send, and every reason's code, is in the allow-list's CODES; each reason is distinct",
          set(sw.DOT_FAIL_CODES) <= set(sw.CODES) and {c for _, c in sw.DOT_REASONS} <= set(sw.DOT_FAIL_CODES)
          and len({k for k, _ in sw.DOT_REASONS}) == len(sw.DOT_REASONS))
    check("the need fits the child's argument bound (1..9), and a press fits inside the store's support bound (2..99)",
          1 <= sw.DOT_NEED <= 9 and 2 <= sw.DOT_NEED <= 99)
    check("per-pose guard limits: the top pose has DOT_TOP_CHAIN 0.56 and DOT_TOP_HARD 0.60 (HARD never under CHAIN), every other pose the 3.1.x CHAIN 0.40 and HARD 0.55",
          sw.dot_limits("top") == (sw.DOT_TOP_CHAIN, sw.DOT_TOP_HARD) == (0.56, 0.60) and sw.DOT_TOP_CHAIN <= sw.DOT_TOP_HARD
          and all(sw.dot_limits(p) == (sw.CHAIN, sw.HARD) == (0.40, 0.55) for p in ("centre", "left", "right", "bottom")))
    # --- dot_references: a held TOP picture is a chain link for the other poses only under the 3.1.x bounds (F1 of the 3.2.2 re-read)
    dr = sw.dot_references
    c0 = enc(0.0)
    left = ("a270", enc(0.0, 0.0, 0.30))
    def top_at(d):
        return ("a000", enc(d))
    names = lambda refs: sorted(round(r[0], 2) for r in refs)
    check("the centre first, always; a press of any pose gets every held non-top picture",
          dr("right", c0, [left])[0] == c0 and len(dr("right", c0, [left])) == 2 and len(dr("top", c0, [left])) == 2)
    check("a TOP press is judged against everything held, a held top picture included, wherever it sits",
          len(dr("top", c0, [left, top_at(0.58)])) == 3)
    check("another pose is NOT judged against a held top picture 0.52 from the centre (over CHAIN of every other reference): somebody admitted at the top cannot chain on",
          len(dr("right", c0, [left, top_at(0.52)])) == 2 and len(dr("bottom", c0, [left, top_at(0.58)])) == 2)
    check("...nor one over HARD (0.56-0.60 is the top's own reach), nor one within CHAIN of a reference but over HARD of the centre",
          len(dr("right", c0, [left, top_at(0.56)])) == 2
          and len(dr("right", c0, [("a270", enc(0.0, 0.0, 0.50)), top_at(0.56)])) == 2)
    check("a held top picture the 3.1.x rule WOULD have admitted (within CHAIN of the centre, or of another reference with the centre within HARD) is still a reference",
          len(dr("right", c0, [left, top_at(0.30)])) == 3 and len(dr("right", c0, [left, top_at(0.40)])) == 3
          and len(dr("right", c0, [("a270", enc(0.50)), top_at(0.54)])) == 3
          and len(dr("right", c0, [left, top_at(0.4001)])) == 2)
    check("an Advanced-style held set (other bins) is untouched, in order", [r[0] for r in dr("top", c0, [("a090", enc(0.1)), ("a180", enc(0.2))])] == [0.0, 0.1, 0.2])
    check("a press cannot out-wait its own ceiling: DOT_SECONDS is short (under 10 s) and positive", 0 < sw.DOT_SECONDS < 10)

    # --- dot_short: how much bigger a too-small face has to look (3.2.1)
    ds = sw.dot_short
    check("dot_short: 1 to 99 percent bigger to reach EYE_MIN: 33 px needs about 9%, 30 px 20%, 35 px 3%, 18 px 100 -> 99; junk is 1",
          (ds(33), ds(30), ds(35), ds(18), ds(sw.EYE_MIN - 0.01)) == (9, 20, 3, 99, 1) and ds(0) == 1 and ds(float("nan")) == 1 and ds(-5) == 1)

    # --- dot_word: the gates
    dw = sw.dot_word
    size = (400, 400)
    inside = (100, 100, 300, 300)
    check("the centre: no face is 'searching', two are 'multiple'",
          dw("centre", 0, 0, inside, size, 20, 0) == "searching" and dw("centre", 2, 80, inside, size, 20, 0) == "multiple")
    check("the centre keeps 3.1.x's size gates: eyes under EYE_MIN are 'closer', over EYE_MAX 'farther', a face at the border 'edge'",
          dw("centre", 1, sw.EYE_MIN - 1, inside, size, 20, 0) == "closer" and dw("centre", 1, sw.EYE_MAX + 1, inside, size, 20, 0) == "farther"
          and dw("centre", 1, 80, (2, 100, 300, 300), size, 20, 0) == "edge")
    check("the centre keeps the brightness gates: over DARK_MAX or over SATURATED_MAX is 'dark'",
          dw("centre", 1, 80, inside, size, sw.DARK_MAX + 1, 0) == "dark" and dw("centre", 1, 80, inside, size, 20, sw.SATURATED_MAX + 1) == "dark")
    check("a good centre frame passes, and so does one exactly at each limit",
          dw("centre", 1, 80, inside, size, 20, 0) is None and dw("centre", 1, sw.EYE_MIN, inside, size, sw.DARK_MAX, sw.SATURATED_MAX) is None
          and dw("centre", 1, sw.EYE_MAX, inside, size, 20, 0) is None)
    check("the centre judges the roll of the eye line as 3.1.x did: ROLL_MAX passes, past it is 'hold'; a turned pose does not",
          dw("centre", 1, 80, inside, size, 20, 0, sw.ROLL_MAX) is None and dw("centre", 1, 80, inside, size, 20, 0, -sw.ROLL_MAX - 1) == "hold"
          and dw("left", 1, 80, inside, size, 20, 0, 40.0) is None)
    check("a turned head (any other pose) is judged on faces and light only: small eyes, a face at the border and a roll are all fine",
          all(dw(p, 1, 20, (0, 0, 40, 40), size, 20, 0) is None for p in ("left", "top", "right", "bottom")))
    check("...but one face and light still apply: none, two, dark and saturated",
          dw("left", 0, 0, inside, size, 20, 0) == "searching" and dw("left", 2, 80, inside, size, 20, 0) == "multiple"
          and dw("left", 1, 80, inside, size, sw.DARK_MAX + 1, 0) == "dark" and dw("left", 1, 80, inside, size, 20, sw.SATURATED_MAX + 1) == "dark")

    # --- dot_agree: a press closes on frames of ONE face
    ag = sw.dot_agree
    check("no frames: no medoid and none agree", ag([]) == (None, 0))
    tight = [frame(i * 0.1, 0.0, 0.01 * i) for i in range(3)]
    check("three frames within SUPPORT of each other all agree (the count the card's progress is drawn from)", ag(tight)[1] == 3)
    check("one odd frame (1.0 away) among three does not count and does not become the medoid: two agree",
          ag(tight[:2] + [frame(0.5, 0.0, 1.0)])[1] == 2)
    spread = [frame(i * 0.1, 0.0, 0.2 * i) for i in range(4)]       # 0, 0.2, 0.4, 0.6 on one axis
    best, count = ag(spread)
    check("a spread of 0.2 steps: the medoid is a middle one and only those within SUPPORT (0.30) of it count",
          best["encoding"][0] in (0.2, 0.4) and count == 3, str((best["encoding"][0], count)))
    check("two people alternating (0 and 0.6 apart) never reach three together until one of them has three frames of his own",
          ag([frame(i * 0.1, 0.0, 0.6 * (i % 2)) for i in range(4)])[1] == 2 and ag([frame(i * 0.1, 0.0, 0.6 * (i % 2)) for i in range(5)])[1] == 3)

    # --- dot_why: what a failed press says
    def seen(**counts):
        base = {"frames": 60, "strobe": 0, "black": 0, "dark": 0, "none": 0, "multi": 0, "closer": 0, "farther": 0,
                "edge": 0, "roll": 0, "stranger": 0}
        base.update(counts)
        return base
    why = sw.dot_why
    check("no lit frame at all (a strobe with nothing lit, or black ones) is black_frames", why(seen(strobe=60)) == "black_frames"
          and why(seen(strobe=30, black=30)) == "black_frames" and why(seen(frames=0)) == "black_frames")
    check("the commonest reason of the lit frames: no face, a dark room, two faces, somebody else, too far, too close, cut off",
          [why(seen(**{k: 40})) for k in ("none", "dark", "multi", "stranger", "closer", "farther", "edge", "roll")]
          == ["no_face", "too_dark", "multiple_faces", "not_you", "too_far", "too_close", "face_cut_off", "face_tilted"])
    check("a tie goes to the first reason (two faces before no face before dark before somebody else)",
          why(seen(none=10, multi=10)) == "multiple_faces" and why(seen(dark=10, none=10)) == "no_face" and why(seen(stranger=10, dark=10)) == "too_dark")
    check("the unlit half of a strobe is never a reason: lit frames that are all fine but too few are 'timeout'",
          why(seen(strobe=30)) == "timeout")
    check("...and strobe frames do not outvote the lit ones (30 unlit, 4 lit with no face: no_face)", why(seen(strobe=30, none=4)) == "no_face")

    # --- floor, validity, verbs
    fl = sw.dot_floor_ok
    check("a scan can be saved with the centre, left and right (any others too), and with no fewer",
          fl({"centre", "left", "right"}) and fl({"centre", "left", "top", "right", "bottom"}) and fl({"centre", "left", "top", "right"})
          and not fl({"centre", "left"}) and not fl({"centre", "right", "top", "bottom"}) and not fl({"left", "right", "top"}) and not fl(set()))
    vd = sw.valid_dot
    cells = [
        (("centre", dict(state="ready", centre=False, stored=0)), None), (("centre", dict(state="swept", centre=True, stored=0)), None),
        (("left", dict(state="swept", centre=True, stored=0)), None), (("bottom", dict(state="ready", centre=True, stored=0)), None),
        (("left", dict(state="ready", centre=False, stored=0)), "the centre comes first"),
        (("centre", dict(state="running", centre=True, stored=0)), "a scan is running or the session is closed"),
        (("left", dict(state="closed", centre=True, stored=0)), "a scan is running or the session is closed"),
        (("up", dict(state="ready", centre=True, stored=0)), "pose"), ((None, dict(state="ready", centre=True, stored=0)), "pose"),
        ((7, dict(state="ready", centre=True, stored=0)), "pose"), ((["centre"], dict(state="ready", centre=True, stored=0)), "pose"),
        (("centre", dict(state="ready", centre=False, stored=5)), None),
        # 3.3.0: an Advanced set (up to 13 stored templates) is replaced like any other; there is no larger-set rule
        (("centre", dict(state="ready", centre=False, stored=13)), None),
        (("left", dict(state="swept", centre=True, stored=13)), None),
    ]
    wrong = [(c, vd(*c[0])) for c in cells if vd(*c[0]) != c[1]]
    check("valid_dot: all %d cells" % len(cells), not wrong, str(wrong))
    check("verb_allowed: a press is allowed in ready and swept, refused while running or closed",
          [sw.verb_allowed(st, "dot") for st in ("ready", "swept", "running", "trialing", "closed")] == ["allow", "allow", "refuse", "refuse", "refuse"])
    check("...and a done after a press with nothing taken stays refused (ready after a swept_before)", sw.verb_allowed("ready", "done", swept_before=True) == "refuse")

    # --- the child's arguments, as root's python would see them
    with tempfile.TemporaryDirectory() as scratch:
        def child(arguments):
            return subprocess.run([sys.executable, "-I", "-c", SOURCE, "dot"] + arguments, capture_output=True, text=True,
                                  cwd=scratch, stdin=subprocess.DEVNULL)
        good = ["left", "4.0", "3", "5", "0"]
        refused = [good[:i] + [bad] + good[i + 1:] for i, bad in ((0, "up"), (0, ""), (0, "Centre"), (1, "0"), (1, "-1"), (1, "nan"), (1, "inf"),
                                                                 (1, "61"), (1, "abc"), (2, "0"), (2, "10"), (2, "x"), (3, "2"), (3, "65"),
                                                                 (4, "2"), (4, "yes"), (4, ""))]
        refused += [good[:-1], good + ["0"], []]
        runs = [child(a) for a in refused]
        check("%d malformed argument lists are refused before anything starts (exit 2, 'not started by omarchy-face-admin')" % len(refused),
              all(d.returncode == 2 and "not started by omarchy-face-admin" in d.stderr and "Traceback" not in d.stderr for d in runs),
              str([(a, d.stderr.strip()[-50:]) for a, d in zip(refused, runs) if d.returncode != 2][:3]))
        done = child(good)
        check("a good list gets past parsing (it dies at the reference descriptor the test does not provide, which is not open)",
              "not started by omarchy-face-admin" not in done.stderr and "read_reference" in done.stderr, done.stderr.strip()[-120:])
        # a pose with an EMPTY reference (a centre that does not exist) is refused before the camera, with a descriptor that is open
        def child_with(reference_json, arguments):
            rfd, wfd = os.pipe()
            os.write(wfd, reference_json.encode())
            os.close(wfd)
            try:
                return subprocess.run([sys.executable, "-I", "-c", SOURCE, "dot"] + [a.replace("RFD", str(rfd)) for a in arguments],
                                      capture_output=True, text=True, cwd=scratch, stdin=subprocess.DEVNULL, pass_fds=(rfd,))
            finally:
                os.close(rfd)
        empty = '{"reference":[],"eye":null}'
        runs = [child_with(empty, [pose, "4.0", "3", "RFD", "0"]) for pose in ("left", "top", "right", "bottom")]
        check("a pose press with an empty reference exits 2 with 'no reference', before any camera",
              all(d.returncode == 2 and "dot: no reference" in d.stderr and "Traceback" not in d.stderr for d in runs),
              str([(d.returncode, d.stderr.strip()[-60:]) for d in runs]))
        check("it left nothing behind in its directory", os.listdir(scratch) == [])


# --- run ----------------------------------------------------------------------------
def main():
    test_pure()
    test_gates()
    test_strobe()
    test_guard()
    test_pick()
    test_sequencer()
    test_dot()
    print()
    print("e0: %d passed, %d failed" % (len(PASS), len(FAIL)))
    for name in FAIL:
        print("  FAILED: " + name)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
