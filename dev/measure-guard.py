#!/usr/bin/env python3

"""Measure the same-person guard on a person's own recordings, with real dlib.

    dev/measure-guard.py --model <dlib_face_recognition_resnet_model_v1.dat[.bz2]> \\
                         [--landmarks <shape_predictor_5_face_landmarks.dat>] [--jobs N] [--cache <scratch dir for the descriptors>] \\
                         <recording dir> [<recording dir> ...]

User-run, never part of CI: the recordings (dev/enrol-record.py, in ~/.cache/omarchy-face-enrol)
are a person's face and are never committed, and neither is anything this computes from them.

The helper's own model lives in /usr/lib/security/howdy/dlib-data/, which is root-only (0700), so
this cannot read it; it takes the same upstream file from anywhere the user can read (howdy's
build cache keeps it: ~/.cache/yay/howdy/dlib_face_recognition_resnet_model_v1.dat.bz2; a .bz2 is
unpacked to a scratch file). Nothing here uses sudo or pkexec.

For every lit frame with one face it does what SWEEP_PY's capture loop does: CLAHE on the gray
frame, the frame and the detection scaled to howdy's max_height (320 of 400), the five landmarks
(the recording's own detection scaled the same way), `compute_face_descriptor(small, shape, 1)`.
Poses come from the recorded landmarks through the helper's pure functions and the neutral is the
first five steady frames, as in dev/replay-recording.py. It then reports, for the owner's own
frames, the distance to the CENTRE template (the guard's HARD test) and to the NEAREST earlier
frame in the same pose neighbourhood (what a chain of templates would measure), by how far the
head is off-centre (u, v and r = hypot(u, v), u about 15 degrees), as percentiles, and how
often CHAIN and HARD would have refused the owner.
"""

import bz2
import json
import math
import multiprocessing
import os
import shutil
import sys
import tempfile
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("rp", os.path.join(HERE, "replay-recording.py"))
rp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rp)
sw = rp.sw

MAX_HEIGHT = 320.0          # howdy's config.ini max_height, as the helper uses it


def prepare(path, scratch):
    if path.endswith(".bz2"):
        out = os.path.join(scratch, os.path.basename(path)[:-4])
        with bz2.open(path, "rb") as source, open(out, "wb") as target:
            shutil.copyfileobj(source, target)
        return out
    return path


_state = {}


def init(model, landmarks):
    import dlib
    _state["dlib"] = dlib
    _state["encoder"] = dlib.face_recognition_model_v1(model)
    _state["predictor"] = dlib.shape_predictor(landmarks)


def encode(job):
    import cv2
    import numpy as np
    dlib = _state["dlib"]
    path, box = job
    gray = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    frame = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
    factor = MAX_HEIGHT / frame.shape[0]
    small = cv2.resize(frame, None, fx=factor, fy=factor, interpolation=cv2.INTER_AREA)
    rect = dlib.rectangle(*[int(round(x * factor)) for x in box])
    shape = _state["predictor"](small, rect)
    return [float(x) for x in _state["encoder"].compute_face_descriptor(small, shape, 1)]


def frames_of(directory):
    """Lit one-face frames with their pose relative to the neutral (None before it exists)."""
    import cv2
    import numpy as np
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    poses, neutral_poses, neutral = [], [], None
    out = []
    for row in rp.load(directory):
        path = os.path.join(directory, "ir", "%05d.png" % row["i"])
        gray_in = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
        gray = clahe.apply(gray_in)
        hist = cv2.calcHist([gray], [0], None, [8], [0, 256])
        total = float(np.sum(hist))
        darkness = float(hist[0] / total * 100) if total else 100.0
        if sw.is_strobe(total, darkness, float(np.mean(gray_in))) or len(row["faces"]) != 1:
            continue
        face = row["faces"][0]
        pose = sw.pose_indices([tuple(p) for p in face["landmarks"]][:5])
        if pose is None:
            continue
        poses = (poses + [pose])[-(sw.SMOOTH_FRAMES + sw.STEADY_FRAMES):]
        n = neutral or {"yaw": 0.0, "pitch": 0.0}
        steady = sw.is_steady([sw.pose_decouple(*sw.pose_uv(p, n)) for p in poses])
        if steady and neutral is None:
            neutral_poses.append(pose)
            if len(neutral_poses) >= sw.NEUTRAL_FRAMES:
                neutral = sw.neutral_of(neutral_poses)
        if neutral is None:
            continue
        u, v = sw.pose_decouple(*sw.pose_uv(pose, neutral))
        # the gates that come before the guard (frame_word without the sharpness and darkness ones, which
        # need the median over the session): a frame they turn away never reaches it
        gated = (pose["eye"] < sw.EYE_MIN or pose["eye"] > sw.EYE_MAX or not sw.box_inside(tuple(face["box"]), (row["w"], row["h"]))
                 or abs(pose["roll"]) > sw.ROLL_MAX)
        out.append({"t": row["t"], "path": path, "box": face["box"], "u": u, "v": v, "steady": steady, "gated": gated})
    return out


def percentiles(values):
    if not values:
        return None
    ordered = sorted(values)
    pick = lambda p: ordered[min(len(ordered) - 1, int(p / 100.0 * (len(ordered) - 1) + 0.5))]
    return {"n": len(ordered), "p50": round(pick(50), 3), "p90": round(pick(90), 3), "p99": round(pick(99), 3),
            "max": round(ordered[-1], 3)}


BANDS = ((0.0, 0.5), (0.5, 1.0), (1.0, 1.5), (1.5, 2.2), (2.2, 99.0))


def band_of(r):
    for lo, hi in BANDS:
        if lo <= r < hi:
            return "%.1f-%s" % (lo, "" if hi > 50 else "%.1f" % hi)
    return None


def analyse(frames, encodings, chain=sw.CHAIN, hard=sw.HARD):
    """frames: dicts with t, u, v; encodings: the 128 numbers of each. The centre template is the
    medoid of the first QUOTA+3 steady frames inside R_MIN after the neutral (the lap's centre)."""
    dist = sw.distance
    first = [i for i, f in enumerate(frames) if f["steady"] and math.hypot(f["u"], f["v"]) < sw.R_MIN][:8]
    if len(first) < 3:
        return None
    candidates = [{"t": frames[i]["t"], "r": math.hypot(frames[i]["u"], frames[i]["v"]), "encoding": encodings[i]}
                  for i in first]
    centre = sw.medoid(candidates)["encoding"]
    rows = []
    for i, f in enumerate(frames):
        r = math.hypot(f["u"], f["v"])
        d_centre = dist(encodings[i], centre)
        # the nearest EARLIER frame whose pose is within 0.6 u of this one and at least 0.4 s old: what a
        # chain of templates dense enough to follow the head would measure
        near = [dist(encodings[i], encodings[j]) for j in range(i)
                if frames[i]["t"] - frames[j]["t"] >= 0.4 and
                math.hypot(frames[i]["u"] - frames[j]["u"], frames[i]["v"] - frames[j]["v"]) <= 0.6]
        rows.append({"r": r, "u": f["u"], "v": f["v"], "angle": sw.ring_angle(f["u"], f["v"]),
                     "d_centre": d_centre, "d_near": min(near) if near else None, "steady": f["steady"],
                     "reach": f["steady"] and not f["gated"] and r <= sw.R_MAX})
    return rows


def report(name, rows, only_reaching=False):
    if only_reaching:
        rows = [x for x in rows if x["reach"]]
        print("\n%s: the %d frames that would REACH the guard (steady, through the eye/edge/roll gates, r <= R_MAX 2.2)" % (name, len(rows)))
    else:
        print("\n%s: all %d lit one-face frames after the neutral (including those the gates and `over` stop before the guard)" % (name, len(rows)))
    print("  distance to the CENTRE template (the guard's HARD test, 0.55) by how far off-centre (r, about 15 degrees per unit):")
    for lo, hi in BANDS:
        label = "%.1f-%s" % (lo, "" if hi > 50 else "%.1f" % hi)
        sel = [x for x in rows if lo <= x["r"] < hi]
        if not sel:
            continue
        p = percentiles([x["d_centre"] for x in sel])
        over_c = 100.0 * sum(x["d_centre"] > sw.CHAIN for x in sel) / len(sel)
        over_h = 100.0 * sum(x["d_centre"] > sw.HARD for x in sel) / len(sel)
        print("    r %-8s n=%4d  p50 %.3f  p90 %.3f  p99 %.3f  max %.3f   over CHAIN(0.40) %3.0f%%  over HARD(0.55) %3.0f%%"
              % (label, p["n"], p["p50"], p["p90"], p["p99"], p["max"], over_c, over_h))
    print("  distance to the nearest EARLIER frame in the same pose neighbourhood (>= 0.4 s old, within 0.6 u):")
    for lo, hi in BANDS:
        label = "%.1f-%s" % (lo, "" if hi > 50 else "%.1f" % hi)
        sel = [x["d_near"] for x in rows if lo <= x["r"] < hi and x["d_near"] is not None]
        if not sel:
            continue
        p = percentiles(sel)
        print("    r %-8s n=%4d  p50 %.3f  p90 %.3f  p99 %.3f  max %.3f   over CHAIN(0.40) %3.0f%%"
              % (label, p["n"], p["p50"], p["p90"], p["p99"], p["max"], 100.0 * sum(d > sw.CHAIN for d in sel) / len(sel)))


def simulate(frames, encodings, variant):
    """Replay the guard over the lit steady frames in time order, as the capture loop would meet
    them after the centre is held. `variant`:
      current   the helper's guard: within HARD (0.55) of the centre and within CHAIN (0.40) of the nearest
                template, and the only template until a target fills is the centre
      slide     CHAIN is measured against the centre and the last 6 ACCEPTED frames of the last 1.5 s
                (a chain that follows the head), HARD unchanged
      slide+r   the same, and HARD grows with how far off-centre the head is: 0.55 + 0.05 x (r - 1), never
                above 0.60
    Returns (frames refused, frames tried, the longest run of refusals in a row, laps that would have ended
    `changed` (5 in a row))."""
    dist = sw.distance
    first = [i for i, f in enumerate(frames) if f["steady"] and math.hypot(f["u"], f["v"]) < sw.R_MIN][:8]
    if len(first) < 3:
        return None
    centre = sw.medoid([{"t": frames[i]["t"], "r": 0.0, "encoding": encodings[i]} for i in first])["encoding"]
    recent, refused, tried, run, longest, ended = [], 0, 0, 0, 0, 0
    start = first[0]
    for i in range(start, len(frames)):
        f = frames[i]
        r = math.hypot(f["u"], f["v"])
        if not f["steady"] or f["gated"] or r > sw.R_MAX:    # past R_MAX a frame is `over`; the gates come first
            continue
        hard = sw.HARD
        if variant == "slide+r":
            hard = min(0.60, sw.HARD + 0.05 * max(0.0, r - 1.0))
        near = [dist(encodings[i], centre)]
        if variant != "current":
            near += [dist(encodings[i], e) for t, e in recent if f["t"] - t <= 1.5][-6:]
        ok = dist(encodings[i], centre) <= hard and min(near) <= sw.CHAIN
        tried += 1
        if ok:
            run = 0
            recent.append((f["t"], encodings[i]))
            recent = recent[-6:]
        else:
            refused += 1
            run += 1
            longest = max(longest, run)
            if run == sw.CHANGED_FRAMES:
                ended += 1
    return refused, tried, longest, ended


def main(argv):
    model = landmarks = None
    jobs = max(1, (os.cpu_count() or 2) - 1)
    directories = []
    cache_dir = None
    i = 0
    while i < len(argv):
        if argv[i] == "--model":
            model = argv[i + 1]; i += 2
        elif argv[i] == "--landmarks":
            landmarks = argv[i + 1]; i += 2
        elif argv[i] == "--cache":
            # descriptors are a person's face: a private directory and private files
            cache_dir = argv[i + 1]; os.makedirs(cache_dir, mode=0o700, exist_ok=True); os.chmod(cache_dir, 0o700); i += 2
        elif argv[i] == "--jobs":
            jobs = int(argv[i + 1]); i += 2
        elif argv[i] == "--json":
            i += 1
        else:
            directories.append(argv[i]); i += 1
    if not model or not directories:
        sys.stderr.write(__doc__)
        return 2
    landmarks = landmarks or os.path.expanduser("~/.cache/omarchy-face-enrol/models/shape_predictor_5_face_landmarks.dat")
    scratch = tempfile.mkdtemp(prefix="omarchy-face-guard.")
    try:
        model = prepare(model, scratch)
        for directory in directories:
            frames = frames_of(directory)
            cache = os.path.join(cache_dir, os.path.basename(directory.rstrip("/")) + ".json") if cache_dir else None
            if cache and os.path.exists(cache):
                encodings = json.load(open(cache))
            else:
                with multiprocessing.Pool(jobs, init, (model, landmarks)) as pool:
                    encodings = pool.map(encode, [(f["path"], f["box"]) for f in frames], chunksize=8)
                if cache:
                    fd = os.open(cache, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                    with os.fdopen(fd, "w") as handle:
                        json.dump(encodings, handle)
                    os.chmod(cache, 0o600)
            rows = analyse(frames, encodings)
            sims = {v: simulate(frames, encodings, v) for v in ("current", "slide", "slide+r")}
            if rows is None:
                print("\n%s: no centre (fewer than 3 steady frames inside R_MIN)" % os.path.basename(directory.rstrip("/")))
                continue
            report(os.path.basename(directory.rstrip("/")), rows, only_reaching=True)
            print("  the guard replayed over the owner's own steady frames (refused / tried, longest run of refusals, times 5-in-a-row would have ended the lap `changed`):")
            for variant, result in sims.items():
                if result:
                    print("    %-9s %4d / %4d  longest run %3d  changed x%d" % ((variant,) + result))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
