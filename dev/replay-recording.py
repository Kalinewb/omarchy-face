#!/usr/bin/env python3

"""Replay a recording through the REAL pure functions and the sweep loop's decisions.

    dev/replay-recording.py <recording dir> [...] [--json] [--step S] [--roll D] [--sharp X]

User-run, never part of CI: the recordings (`dev/enrol-record.py`, in ~/.cache/omarchy-face-enrol)
are a person's face and are never committed. For each recording it takes the IR frames and the
dlib landmarks that were recorded with them and runs, per frame, what `SWEEP_PY`'s capture loop
runs (`run()`): the strobe test, CLAHE darkness, saturation, the sharpness against the session
median, the pose from the five points, the three-frame smoothed steadiness, `frame_word`, the
neutral (the first five accepted frames), then the centre target's dwell. It reports, for the
LIT frames with one face:

  - every word `frame_word` gave, and how often each GATE failed on its own (a frame can fail
    several; the word is the first),
  - when a Simple lap's centre would have been held (dwell 0.8 s at r < R_MIN with two supported
    frames 0.2 s apart; the encodings are not in a recording, so the same-person guard and
    `supported`'s distances are assumed to pass), and how long the longest run of accepted frames is.

Not replayed: the encoder (so no `other`, no `changed`, no `supported` by distance), the child's
own face detection (the recording's detections are used) and the fake clock. The recorder's
detections ran on the same CLAHE image at the camera's size, as the helper's do at howdy's
`max_height` (the helper rescales by that factor, so its landmarks sit on a 1.25 px grid and the
recording's on a 1 px grid).
"""

import collections
import importlib.util
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("e0_pose", os.path.join(HERE, "e0-pose.py"))
e0 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(e0)
sw = e0.sw


def load(directory):
    rows = [json.loads(line) for line in open(os.path.join(directory, "frames.jsonl"))]
    return rows


def replay(directory, overrides=None):
    import cv2
    import numpy as np
    const = dict(STEADY_STEP=sw.STEADY_STEP, ROLL_MAX=sw.ROLL_MAX, SHARP_MIN=sw.SHARP_MIN,
                 EYE_MIN=sw.EYE_MIN, EYE_MAX=sw.EYE_MAX)
    const.update(overrides or {})
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    rows = load(directory)
    counts = collections.Counter()
    gates = collections.Counter()
    words = collections.Counter()
    poses, neutral_poses, neutral = [], [], None
    sharp_seen = []
    centre = {"dwell": None, "held_at": None, "cands": [], "longest": 0, "run": 0}
    centre_dw = sw.new_dwell()
    accepted_times = []
    first = None
    prompts = []
    ppath = os.path.join(directory, "prompts.jsonl")
    if os.path.exists(ppath):
        prompts = [json.loads(line) for line in open(ppath)]
    target_hits = collections.defaultdict(lambda: [0, 0])      # prompt target -> [accepted frames, in its wedge]
    for row in rows:
        path = os.path.join(directory, "ir", "%05d.png" % row["i"])
        gray_in = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
        t = row["t"]
        if first is None:
            first = t
        gray = clahe.apply(gray_in)
        hist = cv2.calcHist([gray], [0], None, [8], [0, 256])
        total = float(np.sum(hist))
        darkness = float(hist[0] / total * 100) if total else 100.0
        counts["frames"] += 1
        if sw.is_strobe(total, darkness, float(np.mean(gray_in))):
            counts["strobe_off"] += 1
            continue
        counts["lit"] += 1
        faces = row["faces"]
        if len(faces) == 0:
            counts["no_face"] += 1
            continue
        if len(faces) > 1:
            counts["multi"] += 1
            continue
        counts["one_face"] += 1
        face = faces[0]
        points = [tuple(p) for p in face["landmarks"]][:5]
        pose = sw.pose_indices(points)
        if pose is None:
            words["no_pose"] += 1
            continue
        box = tuple(face["box"])
        saturated = float(np.count_nonzero(gray_in >= 254)) * 100.0 / gray_in.size
        left, top = max(0, int(box[0])), max(0, int(box[1]))
        patch = gray[top:max(top + 1, int(box[3])), left:max(left + 1, int(box[2]))]
        variance = float(cv2.Laplacian(patch, cv2.CV_64F).var()) if patch.size else 0.0
        sharp_seen.append(variance)
        middle = sw.median(sharp_seen)
        sharp = variance / middle if middle else 1.0
        poses = (poses + [pose])[-8:]

        def uv_of(p):
            n = neutral or {"yaw": 0.0, "pitch": 0.0}
            return sw.pose_decouple(*sw.pose_uv(p, n))

        steady = sw.is_steady([uv_of(p) for p in poses[-(sw.SMOOTH_FRAMES + sw.STEADY_FRAMES):]], step=const["STEADY_STEP"])
        size = (row["w"], row["h"])
        # each gate on its own
        eye = pose["eye"]
        if eye < const["EYE_MIN"]: gates["closer"] += 1
        if eye > const["EYE_MAX"]: gates["farther"] += 1
        if not sw.box_inside(box, size): gates["edge"] += 1
        if darkness > sw.DARK_MAX or saturated > sw.SATURATED_MAX: gates["dark_or_saturated"] += 1
        if sharp < const["SHARP_MIN"]: gates["blurry"] += 1
        if abs(pose["roll"]) > const["ROLL_MAX"]: gates["roll"] += 1
        if not steady: gates["unsteady"] += 1
        # the word, with the constants as given (frame_word reads the module's own, so patch them)
        saved = {k: sw.__dict__.get(k) for k in const}
        word = frame_word_with(const, 1, eye, box, size, darkness, saturated, sharp, pose["roll"], steady)
        words[word or "ok"] += 1
        if word is not None:
            centre["run"] = 0
            continue
        counts["accepted"] += 1
        centre["run"] += 1
        centre["longest"] = max(centre["longest"], centre["run"])
        if neutral is None:
            neutral_poses.append(pose)
            if len(neutral_poses) >= sw.NEUTRAL_FRAMES:
                neutral = sw.neutral_of(neutral_poses)
                counts["neutral_at_s"] = round(t - first, 2)
            continue
        u, v = uv_of(pose)
        r = math.hypot(u, v)
        for pr in prompts:
            # the hold part of a prompt (after the first 1.8 s), the four Simple targets and the centre
            if pr.get("bin") in (0, 3, 6, 9) and pr["t"] + 1.8 <= t < pr["t"] + pr["len"]:
                target_hits[pr["target"]][0] += 1
                target_hits[pr["target"]][1] += bool(sw.in_target(u, v, pr["bin"], False, sw.SIMPLE_WEDGE_HALF))
        if r >= sw.R_MIN:
            counts["accepted_off_centre"] += 1
            continue
        counts["accepted_at_centre"] += 1
        accepted_times.append(t)
        centre_dw = sw.dwell_step(centre_dw, t, True, True)
        spaced = []
        for x in accepted_times:                    # `supported`: frames at least SUPPORT_GAP apart
            if not spaced or x - spaced[-1] >= sw.SUPPORT_GAP:
                spaced.append(x)
        if centre["held_at"] is None and centre_dw["dwell"] >= sw.TARGET_DWELL and len(spaced) >= sw.QUOTA:
            centre["held_at"] = round(t - first, 2)
    return {"directory": os.path.basename(directory.rstrip("/")), "counts": dict(counts), "gates": dict(gates),
            "words": dict(words), "targets": dict(target_hits), "centre_held_at_s": centre["held_at"], "longest_accepted_run": centre["longest"],
            "seconds": round(rows[-1]["t"] - rows[0]["t"], 1)}


def frame_word_with(const, faces, eye, box, size, dark, saturated, sharp, roll, steady):
    """frame_word with the thresholds of `const`, in the same order of tests."""
    if faces == 0:
        return "searching"
    if faces > 1:
        return "multiple"
    if eye < const["EYE_MIN"]:
        return "closer"
    if eye > const["EYE_MAX"]:
        return "farther"
    if not sw.box_inside(box, size):
        return "edge"
    if dark > sw.DARK_MAX or saturated > sw.SATURATED_MAX:
        return "dark"
    if sharp < const["SHARP_MIN"]:
        return "blurry"
    if abs(roll) > const["ROLL_MAX"] or not steady:
        return "hold"
    return None


def main(argv):
    # --step S / --roll D / --sharp X try another STEADY_STEP, ROLL_MAX, SHARP_MIN than the helper's.
    # To compare helper versions (SMOOTH_FRAMES is bound into `smooth` at definition) run it with
    # E0_ADMIN=<another copy of omarchy-face-admin>.
    for flag, name, cast in (("--step", "STEADY_STEP", float),
                             ("--roll", "ROLL_MAX", float), ("--sharp", "SHARP_MIN", float)):
        if flag in argv:
            at = argv.index(flag)
            e0.MODULE[name] = cast(argv[at + 1])
            del argv[at:at + 2]
    as_json = "--json" in argv
    directories = [a for a in argv if not a.startswith("--")]
    if not directories:
        sys.stderr.write(__doc__)
        return 2
    results = [replay(d) for d in directories]
    if as_json:
        print(json.dumps(results, indent=1))
        return 0
    for r in results:
        print("%s (%ss)" % (r["directory"], r["seconds"]))
        print("  frames", r["counts"])
        print("  words ", r["words"])
        print("  gates ", r["gates"])
        if r["targets"]:
            print("  targets (accepted frames in the hold part of each prompt / of them in the Simple wedge)",
                  {k: "%d/%d" % (v[1], v[0]) for k, v in sorted(r["targets"].items())})
        print("  centre held at", r["centre_held_at_s"], "s; longest run of accepted frames", r["longest_accepted_run"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
