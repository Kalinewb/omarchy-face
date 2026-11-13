#!/usr/bin/env python3

"""How face size (eye distance in pixels) moves dlib's descriptor distance, on a person's own recordings.

    dev/measure-scale.py --model <dlib_face_recognition_resnet_model_v1.dat[.bz2]> --cache <dir> \\
                         [--reference <recording dir>] [--detect <recording dir> ...] <recording dir> [...]

User-run, never part of CI: the recordings (dev/enrol-record.py, in ~/.cache/omarchy-face-enrol) are a
person's face and are never committed, and neither is anything this computes from them. Like
dev/measure-guard.py it takes the same upstream model from a file you can read (nothing here uses sudo;
the helper's own copy is root-only) and keeps the descriptors in `--cache`, a private (0700) directory;
a recording whose descriptors are not cached yet is encoded first, by measure-guard's own functions.

It prints four things, each from the recordings' lit one-face frames:

  1. eye px per recording (the scan's gates are EYE_MIN 40 and EYE_MAX 150) and how many frames each gate
     would have refused;
  2. the distance to the lap's CENTRE template by the frame's eye px divided by the centre's (the scale
     drift a head makes by leaning), and the share of frames over CHAIN and HARD at each ratio;
  3. `--reference R`: the distance of every recording's frames to the centre of recording R (a normal
     desk distance, say), by the frame's own eye px: what an unlock at another distance would see against
     templates enrolled at R's, with howdy's stock threshold 0.35 and CHAIN 0.40;
  4. `--detect D`: for the recording D, how often the HOG detector finds a face and how often a detected
     face is within 0.35 of R's centre, at 400 px / 320 px (howdy's `max_height`) and upsample 0, 1, 2,
     and what each costs per frame.
"""

import json
import math
import os
import shutil
import statistics
import sys
import tempfile
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("mg", os.path.join(HERE, "measure-guard.py"))
mg = importlib.util.module_from_spec(_spec)
sys.modules["mg"] = mg                  # the encoder pool pickles measure-guard's functions by module name
_spec.loader.exec_module(mg)
sw = mg.sw
dist = sw.distance
R = os.path.expanduser("~/.cache/omarchy-face-enrol")


def name_of(path):
    return os.path.basename(path.rstrip("/"))


def load(path, cache_dir):
    """Per lit one-face frame after the neutral: eye px, pose, steadiness, descriptor."""
    frames = mg.frames_of(path)
    cache = os.path.join(cache_dir, name_of(path) + ".json")
    encodings = json.load(open(cache))
    by_time = {round(r["t"], 4): r for r in mg.rp.load(path)}
    out = []
    for f, e in zip(frames, encodings):
        row = by_time.get(round(f["t"], 4))
        pose = sw.pose_indices([tuple(p) for p in row["faces"][0]["landmarks"]][:5]) if row and len(row["faces"]) == 1 else None
        out.append({"t": f["t"], "eye": pose["eye"] if pose else None, "u": f["u"], "v": f["v"], "steady": f["steady"],
                    "gated": f["gated"], "enc": e, "r": math.hypot(f["u"], f["v"])})
    return out


def centre_of(frames):
    """The centre as the sweep forms it, approximately: the medoid of the first eight steady, ungated frames in R_MIN."""
    first = [i for i, f in enumerate(frames) if f["steady"] and not f["gated"] and f["r"] < sw.R_MIN and f["eye"]][:8]
    if len(first) < 3:
        return None, None, None
    cand = [{"t": frames[i]["t"], "r": 0.0, "encoding": frames[i]["enc"]} for i in first]
    return sw.medoid(cand)["encoding"], statistics.median(frames[i]["eye"] for i in first), first[0]


def pct(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(p * (len(ordered) - 1) + 0.5))]


def table_eye(names, loaded):
    print("\n1. eye px per recording (the scan's gates: closer < %d, farther > %d)" % (sw.EYE_MIN, sw.EYE_MAX))
    for name in names:
        eyes = [f["eye"] for f in loaded[name] if f["eye"]]
        if eyes:
            print("   %-28s n=%4d  eye p10/p50/p90 = %.0f/%.0f/%.0f   closer %3d  farther %3d" % (
                name, len(eyes), pct(eyes, .1), statistics.median(eyes), pct(eyes, .9),
                sum(e < sw.EYE_MIN for e in eyes), sum(e > sw.EYE_MAX for e in eyes)))


def table_ratio(names, loaded):
    rows = []
    for name in names:
        frames = loaded[name]
        centre, centre_eye, start = centre_of(frames)
        if centre is None:
            continue
        for f in frames[start:]:
            if f["eye"] and f["r"] <= sw.R_MAX:
                rows.append({"ratio": f["eye"] / centre_eye, "d": dist(f["enc"], centre), "r": f["r"], "steady": f["steady"], "gated": f["gated"]})
    print("\n2. distance to the lap's centre by the frame's eye px over the centre's (%d frames, all poses r <= %.1f)" % (len(rows), sw.R_MAX))
    print("   ratio        n   p50   p90   over CHAIN  over HARD")
    for lo, hi in ((0, .6), (.6, .7), (.7, .8), (.8, .9), (.9, 1.1), (1.1, 1.25), (1.25, 1.5), (1.5, 9)):
        x = [r["d"] for r in rows if lo <= r["ratio"] < hi]
        if len(x) >= 5:
            print("   %.2f-%.2f %4d  %.2f  %.2f   %3d%%        %3d%%" % (lo, hi, len(x), pct(x, .5), pct(x, .9),
                                                                        100 * sum(v > sw.CHAIN for v in x) // len(x), 100 * sum(v > sw.HARD for v in x) // len(x)))
    for lo, hi in ((0.85, 1.0 / 0.85), (0.80, 1.25), (0.75, 1.0 / 0.75)):
        reach = [r for r in rows if r["steady"] and not r["gated"]]
        inside = [r for r in reach if lo <= r["ratio"] <= hi]
        print("   a band of %.2f-%.2f keeps %d of the %d frames that reach the guard; frames over CHAIN: %d of %d inside it, %d of %d outside it" % (
            lo, hi, len(inside), len(reach), sum(r["d"] > sw.CHAIN for r in inside), len(inside),
            sum(r["d"] > sw.CHAIN for r in reach if r not in inside), len(reach) - len(inside)))


def table_reference(names, loaded, reference):
    centre, centre_eye, _ = centre_of(loaded[name_of(reference)])
    print("\n3. distance to the centre of %s (eye %.0f px) by the frame's own eye px; howdy's unlock is per frame under 0.35" % (name_of(reference), centre_eye))
    print("   eye px       n   p50   p90   <0.35  <0.40")
    rows = [f for name in names if name != name_of(reference) for f in loaded[name] if f["eye"] and f["r"] < 2.2]
    for lo, hi in ((0, 25), (25, 32), (32, 38), (38, 44), (44, 52), (52, 60), (60, 80), (80, 200)):
        x = [dist(f["enc"], centre) for f in rows if lo <= f["eye"] < hi]
        if len(x) >= 5:
            print("   %3d-%3d %5d  %.2f  %.2f   %3d%%   %3d%%" % (lo, hi, len(x), pct(x, .5), pct(x, .9),
                                                                100 * sum(v < .35 for v in x) // len(x), 100 * sum(v < .40 for v in x) // len(x)))
    return centre


def table_detect(path, centre, model, landmarks):
    import time
    import cv2
    import numpy as np
    import dlib
    encoder = dlib.face_recognition_model_v1(model)
    predictor = dlib.shape_predictor(landmarks)
    detector = dlib.get_frontal_face_detector()
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    settings = (("400 px, upsample 1 (as recorded)", 400, 1), ("320 px, upsample 1 (howdy as installed)", 320, 1),
                ("400 px, upsample 2", 400, 2), ("320 px, upsample 2", 320, 2), ("400 px, upsample 0", 400, 0))
    result = {s[0]: {"lit": 0, "det": 0, "multi": 0, "hit": 0, "ms": 0.0} for s in settings}
    for row in mg.rp.load(path):
        gray = cv2.imread(os.path.join(path, "ir", "%05d.png" % row["i"]), cv2.IMREAD_GRAYSCALE)
        gc = clahe.apply(gray)
        hist = cv2.calcHist([gc], [0], None, [8], [0, 256])
        total = float(np.sum(hist))
        if sw.is_strobe(total, float(hist[0] / total * 100), float(np.mean(gray))):
            continue
        frame = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
        for name, height, up in settings:
            k = height / 400.0
            small = cv2.resize(frame, None, fx=k, fy=k, interpolation=cv2.INTER_AREA) if k != 1 else frame
            small_gray = cv2.resize(gc, None, fx=k, fy=k, interpolation=cv2.INTER_AREA) if k != 1 else gc
            t0 = time.time()
            faces = detector(small_gray, up)
            r = result[name]
            r["ms"] += (time.time() - t0) * 1000
            r["lit"] += 1
            r["det"] += bool(faces)
            r["multi"] += len(faces) > 1
            best = min((dist([float(x) for x in encoder.compute_face_descriptor(small, predictor(small, rect), 1)], centre)
                        for rect in faces), default=9.0)
            r["hit"] += best < 0.35
    print("\n4. detection and matching on %s (centre templates from the reference)" % name_of(path))
    for name, r in result.items():
        print("   %-42s lit %3d  detected %3d%%  two or more faces %3d  a face within 0.35: %3d%%  detect %.0f ms/frame" % (
            name, r["lit"], 100 * r["det"] // max(1, r["lit"]), r["multi"], 100 * r["hit"] // max(1, r["lit"]), r["ms"] / max(1, r["lit"])))


def main(argv):
    model = reference = cache_dir = None
    detect, directories = [], []
    i = 0
    while i < len(argv):
        if argv[i] == "--model":
            model = argv[i + 1]; i += 2
        elif argv[i] == "--cache":
            cache_dir = argv[i + 1]; os.makedirs(cache_dir, mode=0o700, exist_ok=True); os.chmod(cache_dir, 0o700); i += 2
        elif argv[i] == "--reference":
            reference = argv[i + 1]; i += 2
        elif argv[i] == "--detect":
            detect.append(argv[i + 1]); i += 2
        else:
            directories.append(argv[i]); i += 1
    if not model or not cache_dir or not directories:
        sys.stderr.write(__doc__)
        return 2
    landmarks = os.path.join(R, "models", "shape_predictor_5_face_landmarks.dat")
    scratch = tempfile.mkdtemp(prefix="omarchy-face-scale.")
    try:
        model = mg.prepare(model, scratch)
        missing = [d for d in directories + detect + ([reference] if reference else [])
                   if not os.path.exists(os.path.join(cache_dir, name_of(d) + ".json"))]
        if missing:       # measure-guard's own main encodes and caches them (and prints its report, which is fine)
            mg.main(["--model", model, "--cache", cache_dir] + sorted(set(missing)))
        names = [name_of(d) for d in directories]
        loaded = {name_of(d): load(d, cache_dir) for d in set(directories + detect + ([reference] if reference else []))}
        table_eye(names, loaded)
        table_ratio(names, loaded)
        if reference:
            centre = table_reference(names, loaded, reference)
            for d in detect:
                table_detect(d, centre, model, landmarks)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
