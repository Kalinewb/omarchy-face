#!/usr/bin/env python3

"""The Phase 0 recorder, tested without a camera (plan-face-enroll.md section 8, Phase 0).

    dev/enrol-record-test.py

Two halves. The pure one imports dev/enrol-record.py and checks what each kind
schedules: the prompts, their order, bins and lengths. The other runs the script as a
process on synthetic picture sequences given to --ir and --rgb (never a /dev node: no
camera is opened by this file or by anything it starts) and checks each kind end to end:
the files, their fields, the labels, mode 0700, exit codes, and Ctrl-C during a
countdown and during a schedule. Recordings go to a temporary directory that is removed.

Needs python-opencv and python-numpy for the second half (it skips it without them).
Takes about a minute. Exit 0 when every check passes, 1 otherwise.
"""

import ast
import importlib.util
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "dev", "enrol-record.py")

PASS, FAIL = [], []


def check(name, condition, detail=""):
    (PASS if condition else FAIL).append(name)
    print("  %s  %s%s" % ("pass" if condition else "FAIL", name, ("  -- " + detail) if detail and not condition else ""))


spec = importlib.util.spec_from_file_location("enrol_record", SCRIPT)
R = importlib.util.module_from_spec(spec)
spec.loader.exec_module(R)


# --- the pure half --------------------------------------------------------------

def test_schedules():
    print("schedules")
    prompts, total = R.prompt_schedule("guided", 4.0, 3)
    first = prompts[:13]
    check("guided: 13 prompts a round, 3 rounds, 4 s each", len(prompts) == 39 and total == 156.0
          and all(p["len"] == 4.0 for p in prompts), "%d prompts, %s s" % (len(prompts), total))
    check("guided: centre, right, down, left, up first", [p["target"] for p in first[:5]]
          == ["centre", "right", "down", "left", "up"])
    check("guided: those are bins None, 3, 6, 9, 0", [p["bin"] for p in first[:5]] == [None, 3, 6, 9, 0])
    check("guided: then the eight other bins in clock order", [p["bin"] for p in first[5:]] == [1, 2, 4, 5, 7, 8, 10, 11])
    check("guided: every bin of the twelve is asked for once a round",
          sorted(p["bin"] for p in first[1:]) == list(range(12)))
    check("guided: starts are back to back and rise", all(abs(b["at"] - (a["at"] + a["len"])) < 1e-6
                                                         for a, b in zip(prompts, prompts[1:])))
    check("guided: rounds are numbered, steps run 1 to 13", [p["round"] for p in prompts[::13]] == [1, 2, 3]
          and [p["step"] for p in first] == list(range(1, 14)) and all(p["of"] == 13 for p in prompts))
    check("guided: every prompt has words that name the way", all(p["say"] for p in prompts)
          and "RIGHT" in first[1]["say"] and "DOWN" in first[2]["say"] and "LEFT" in first[3]["say"] and "UP" in first[4]["say"])
    check("guided: --pace changes the length", R.prompt_schedule("guided", 2.5, 1)[1] == 32.5)

    holds, total = R.prompt_schedule("holds", 4.0, 2)
    check("holds: a centre prompt then 5 steps for each of 4 directions, per round", len(holds) == 42, str(len(holds)))
    one = holds[:21]
    check("holds: right, down, left, up in that order", [p["target"] for p in one[1::5]] == ["right", "down", "left", "up"])
    check("holds: each direction is past, back, settle, hold, return",
          [p["phase"] for p in one[1:6]] == ["past", "back", "settle", "hold", "return"])
    check("holds: the still hold is 3 s", all(p["len"] == 3.0 for p in holds if p["phase"] == "hold") and
          sum(1 for p in holds if p["phase"] == "hold") == 8)
    check("holds: 67 s a round, 134 s for two", total == 134.0, str(total))
    check("holds: --pace scales the whole table", R.prompt_schedule("holds", 0.4, 1)[1] == 6.7)
    check("holds: bins are 3, 6, 9, 0", sorted({p["bin"] for p in holds if p["bin"] is not None}) == [0, 3, 6, 9])

    still, total = R.prompt_schedule("still", None, 1, 10)
    check("still: one prompt, ten seconds, in the plan's words", len(still) == 1 and total == 10
          and still[0]["say"] == "Hold still, look at the circle.")


def test_kinds():
    print("kinds and options")
    check("the five old kinds are all still there, in the plan's order",
          R.ORDER == ("still", "desk", "inlap", "tilt", "far", "concurrent", "guided", "holds")
          and all(R.KINDS[k][1] == 45 for k in ("desk", "inlap", "tilt", "far", "concurrent")) and R.KINDS["stranger"][1] == 20)
    check("--stranger is not a choosable kind", "stranger" not in R.ORDER)
    out = subprocess.run([sys.executable, SCRIPT, "--list"], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30)
    listing = out.stdout
    check("--list exits 0 and opens no camera (stdout only)", out.returncode == 0 and not out.stderr)
    commands = [line.split("dev/enrol-record.py ", 1)[1].split("  ")[0].strip() for line in listing.splitlines()
                if line.startswith("  dev/enrol-record.py ")]
    kinds = [c.split()[0] for c in commands]
    check("--list names still, desk, inlap, tilt, far, concurrent, guided, holds in the plan's order",
          [k for k in kinds if k in R.ORDER][:8] == ["still", "desk", "inlap", "tilt", "far", "concurrent", "guided", "holds"], str(kinds))
    check("--list ends with a dim-room round of desk, still and guided",
          [c for c in commands if "--dark" in c] == ["still --where desk --dark", "desk --where desk --dark",
                                                      "guided --where desk --dark --rounds 2"], str(commands))
    check("--list has guided for the lap and for a nodded neutral", any("guided --where lap" in c for c in commands)
          and any("nodded" in c for c in commands))
    check("--list says the total time", "minutes in all" in listing)
    tree = ast.parse(open(SCRIPT, encoding="utf-8").read())
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(a.name.split(".")[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            imported.add((node.module or "").split(".")[0])
    check("no network module is imported", not imported & {"socket", "ssl", "urllib", "http", "requests", "ftplib", "smtplib",
                                                           "asyncio", "xmlrpc", "websocket", "websockets", "aiohttp"}, str(sorted(imported)))


# --- the process half -------------------------------------------------------------

def make_sequence(directory, count, rgb=False):
    import cv2
    import numpy as np
    os.makedirs(directory, exist_ok=True)
    rng = np.random.default_rng(7)
    for i in range(count):
        picture = (rng.random((400, 400)) * 60 + 100 * (i % 2)).astype("uint8")
        cv2.circle(picture, (200, 200), 60, 200, -1)
        if rgb:
            picture = cv2.cvtColor(picture, cv2.COLOR_GRAY2BGR)
        cv2.imwrite(os.path.join(directory, "%04d.png" % i), picture)
    return os.path.join(directory, "%04d.png")


def run(work, *args, ir="ir", rgb=None, stdin=subprocess.DEVNULL, timeout=120):
    cmd = [sys.executable, SCRIPT] + list(args) + ["--countdown", "0", "--ir", ir, "--out", os.path.join(work, "out")]
    if rgb:
        cmd += ["--rgb", rgb]
    assert not [a for a in cmd[2:] if a.startswith("/dev/")], "a test must never name a device"
    return subprocess.run(cmd, capture_output=True, text=True, stdin=stdin, timeout=timeout)


def recordings(work, kind):
    base = os.path.join(work, "out")
    return sorted(os.path.join(base, d) for d in os.listdir(base) if d.endswith("-" + kind)) if os.path.isdir(base) else []


def rows(path):
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle]


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def common(name, done, folder, extra_ok=True):
    """Checks every kind must pass: the files, the fields, the permissions."""
    check("%s: exits 0" % name, done.returncode == 0, "rc %s, stderr %s" % (done.returncode, done.stderr[-300:]))
    check("%s: one recording folder, mode 0700" % name, folder is not None and mode(folder) == 0o700)
    if folder is None:
        return None, None
    frames = rows(os.path.join(folder, "frames.jsonl"))
    meta = json.load(open(os.path.join(folder, "meta.json"), encoding="utf-8"))
    check("%s: frames.jsonl has i, t, readMs, mean per frame, the times rising" % name,
          len(frames) > 10 and all({"i", "t", "readMs", "mean", "w", "h"} <= set(f) for f in frames)
          and all(b["t"] >= a["t"] for a, b in zip(frames, frames[1:])))
    check("%s: every frame has its PNG, and only ir/ holds pictures" % name,
          len(os.listdir(os.path.join(folder, "ir"))) == len(frames)
          and not [f for f in os.listdir(folder) if f.endswith((".png", ".jpg"))])
    check("%s: files are 0600" % name, all(mode(os.path.join(folder, f)) == 0o600 for f in os.listdir(folder)
                                           if os.path.isfile(os.path.join(folder, f))))
    if R.load_dlib(os.path.join(os.path.dirname(folder), "models"))[0] is not None:
        check("%s: each frame carries its HOG faces and the detection time" % name,
              all("faces" in f and "detectMs" in f for f in frames))
    check("%s: meta.json has the kind, counts and the labels" % name,
          meta["kind"] == name.split()[0] and meta["completed"] is True and meta["irFrames"] == len(frames)
          and {"where", "dark", "darkNote", "note", "otherPerson", "firstFrameMono", "cameras"} <= set(meta))
    return frames, meta


def test_processes(work):
    print("end to end, on synthetic pictures (no camera)")
    ir = make_sequence(os.path.join(work, "ir_seq"), 600)
    rgb = make_sequence(os.path.join(work, "rgb_seq"), 300, rgb=True)

    done = run(work, "still", "--seconds", "2", "--where", "lap", "--dark", ir=ir)
    folder = (recordings(work, "still") or [None])[0]
    frames, meta = common("still", done, folder)
    if meta:
        check("still: where and dark land in meta.json; no prompts.jsonl", meta["where"] == "lap" and meta["dark"] is True
              and meta["darkNote"] == "recorded in a dark room" and not os.path.exists(os.path.join(folder, "prompts.jsonl")))
        check("still: the prompt is said", "Hold still, look at the circle." in done.stdout)

    done = run(work, "guided", "--pace", "0.3", "--rounds", "2", "--where", "desk", "--note", "nodded", ir=ir)
    folder = (recordings(work, "guided") or [None])[0]
    frames, meta = common("guided", done, folder)
    if meta:
        prompts = rows(os.path.join(folder, "prompts.jsonl"))
        check("guided: 26 prompts written, in the schedule's order", len(prompts) == 26
              and [p["bin"] for p in prompts[:13]] == [None, 3, 6, 9, 0, 1, 2, 4, 5, 7, 8, 10, 11])
        check("guided: prompts.jsonl has mono, t, target, bin, round, step",
              all({"mono", "t", "target", "bin", "round", "step", "say", "phase"} <= set(p) for p in prompts))
        check("guided: prompt times rise and sit on the frames' clock", all(b["mono"] > a["mono"] for a, b in zip(prompts, prompts[1:]))
              and all(abs(p["t"] - (p["mono"] - meta["firstFrameMono"])) < 1e-3 for p in prompts)
              and prompts[-1]["t"] < frames[-1]["t"] + 1.0)
        check("guided: spacing is the pace", all(abs((b["mono"] - a["mono"]) - 0.3) < 0.1 for a, b in zip(prompts, prompts[1:])))
        check("guided: meta holds pace, rounds, prompts, labels", meta["pace"] == 0.3 and meta["rounds"] == 2 and meta["prompts"] == 26
              and meta["where"] == "desk" and meta["note"] == "nodded" and meta["cameraStoppedEarly"] is False)
        check("guided: the terminal got a tick count and plain words", "Turn your head to your RIGHT" in done.stdout
              and "round 2 of 2" in done.stdout)

    done = run(work, "holds", "--pace", "0.2", "--rounds", "1", ir=ir)
    folder = (recordings(work, "holds") or [None])[0]
    frames, meta = common("holds", done, folder)
    if meta:
        prompts = rows(os.path.join(folder, "prompts.jsonl"))
        check("holds: 21 prompts, phases past/back/settle/hold/return per direction", len(prompts) == 21
              and [p["phase"] for p in prompts[1:6]] == ["past", "back", "settle", "hold", "return"]
              and [p["target"] for p in prompts[1::5]] == ["right", "down", "left", "up"])
        check("holds: prompts carry t and bin", all("t" in p and "bin" in p for p in prompts)
              and [p["bin"] for p in prompts[1::5]] == [3, 6, 9, 0])

    done = run(work, "desk", "--seconds", "2", ir=ir)
    folder = (recordings(work, "desk") or [None])[0]
    frames, meta = common("desk", done, folder)
    if meta:
        check("desk: unchanged: no prompts.jsonl, no pace", not os.path.exists(os.path.join(folder, "prompts.jsonl"))
              and "pace" not in meta and done.stdout.count("starting in") == 0)

    done = run(work, "concurrent", "--seconds", "2", ir=ir, rgb=rgb)
    folder = (recordings(work, "concurrent") or [None])[0]
    frames, meta = common("concurrent", done, folder)
    if meta:
        boxes = rows(os.path.join(folder, "rgb.jsonl"))
        check("concurrent: unchanged: rgb.jsonl has boxes only, never a picture", len(boxes) > 5
              and all({"t", "w", "h", "faces", "box"} <= set(b) for b in boxes) and not os.path.exists(os.path.join(folder, "rgb")))

    short = make_sequence(os.path.join(work, "short_seq"), 20)
    done = run(work, "guided", "--pace", "1", "--rounds", "1", ir=short)
    check("a camera that stops ends the schedule and still saves", done.returncode == 0 and "stopped giving pictures" in done.stdout)


def test_refusals(work):
    print("refusals")
    ir = os.path.join(work, "ir_seq", "%04d.png")
    out = os.path.join(work, "refuse")
    for args, why in ((["--stranger"], "--stranger"), (["guided", "--other-person"], "--other-person")):
        done = subprocess.run([sys.executable, SCRIPT] + args + ["--countdown", "0", "--ir", ir, "--out", out],
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
        check("%s without a terminal and a typed yes records nothing" % why, done.returncode == 1 and "no consent" in done.stderr
              and not os.path.exists(out))
    here = os.path.join(REPO, "dev", "refuse-out")
    done = subprocess.run([sys.executable, SCRIPT, "still", "--countdown", "0", "--ir", ir, "--out", here],
                          capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    check("an --out inside the repository is refused", done.returncode == 1 and "repository" in done.stderr
          and not os.path.exists(here))
    for args in (["still", "--pace", "1"], ["guided", "--seconds", "5"], ["guided", "--pace", "0.01"], ["holds", "--rounds", "99"]):
        done = subprocess.run([sys.executable, SCRIPT] + args + ["--ir", ir, "--out", out], capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=60)
        check("bad options are refused: %s" % " ".join(args), done.returncode == 2 and not os.path.exists(out))


def lines_until(proc, needle, seconds=60):
    seen, end = [], time.monotonic() + seconds
    while time.monotonic() < end:
        line = proc.stdout.readline()
        if not line:
            break
        seen.append(line)
        if needle in line:
            return seen
    return None


def test_interrupts(work):
    print("Ctrl-C")
    ir = os.path.join(work, "ir_seq", "%04d.png")
    out = os.path.join(work, "int-out")
    for kind in ("still", "guided", "holds"):
        proc = subprocess.Popen([sys.executable, SCRIPT, kind, "--countdown", "30", "--ir", ir, "--out", out],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True)
        seen = lines_until(proc, "starting in")
        proc.send_signal(signal.SIGINT)
        try:
            err = proc.communicate(timeout=30)[1]
        except subprocess.TimeoutExpired:
            proc.kill()
            err = ""
        check("%s: Ctrl-C in the countdown exits 130 before the camera is opened" % kind,
              seen is not None and proc.returncode == 130 and "cancelled before the camera was opened" in err
              and not (os.path.isdir(out) and [f for f in os.listdir(out) if f != "models"]),
              "rc %s, %s" % (proc.returncode, err[-200:]))

    proc = subprocess.Popen([sys.executable, SCRIPT, "guided", "--countdown", "0", "--pace", "1", "--rounds", "1", "--ir", ir,
                             "--out", out], stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True)
    seen = lines_until(proc, "step 3 of 13")
    proc.send_signal(signal.SIGINT)
    try:
        proc.communicate(timeout=60)
    except subprocess.TimeoutExpired:
        proc.kill()
    folders = [os.path.join(out, f) for f in sorted(os.listdir(out)) if f.endswith("-guided")] if os.path.isdir(out) else []
    check("guided: Ctrl-C during a prompt exits 130 and keeps what it has", seen is not None and proc.returncode == 130
          and len(folders) == 1)
    if folders:
        meta = json.load(open(os.path.join(folders[0], "meta.json"), encoding="utf-8"))
        prompts = rows(os.path.join(folders[0], "prompts.jsonl"))
        check("guided: the cut-short recording says so and has the prompts shown so far",
              meta["interrupted"] is True and 3 <= len(prompts) <= 5, "%d prompts" % len(prompts))


def main():
    test_schedules()
    test_kinds()
    try:
        import cv2  # noqa: F401
        import numpy  # noqa: F401
    except ImportError:
        print("skipped the process half: python-opencv and python-numpy are needed")
    else:
        work = tempfile.mkdtemp(prefix="enrol-record-test.")
        try:
            test_processes(work)
            test_refusals(work)
            test_interrupts(work)
        finally:
            shutil.rmtree(work, ignore_errors=True)
            shutil.rmtree(os.path.join(REPO, "dev", "refuse-out"), ignore_errors=True)
    print()
    print("enrol-record-test: %d passed, %d failed" % (len(PASS), len(FAIL)))
    for name in FAIL:
        print("  FAILED: " + name)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
