#!/usr/bin/env python3

"""Record laps for the enrolment plan's Phase 0. User-run; never part of CI.

    dev/enrol-record.py --list                 what to record, in order, and the commands
    dev/enrol-record.py desk                   a slow lap at the desk
    dev/enrol-record.py inlap | tilt | far     the same, with the laptop elsewhere / farther
    dev/enrol-record.py concurrent             a lap with the RGB camera running too
    dev/enrol-record.py --stranger             another person's frames, with their consent

plan-face-enroll.md section 8, Phase 0, replaces every (chosen) number from what this
writes: the HOG drop-off angle, the pose amplitudes, the eye range per distance, the dark
share, per-frame times, the same-person distance by pose (HARD, CHAIN), the 400 versus
320 px A/B, the landmark order, the IR-in-RGB crop, pitch quality, the false-accept check
and the N = 3, 12, 36 benchmark. Someone reads the recordings; nobody reads the camera.

What is written, to ~/.cache/omarchy-face-enrol/<time>-<kind>/ (mode 0700, never in the
repository, never read by anything but the person running this):

    ir/NNNNN.png    each infrared frame exactly as the camera gave it, lossless
    frames.jsonl    per IR frame: index, seconds since the first frame, how long the read
                    took, mean brightness, and dlib's HOG faces with the five landmarks
                    (in dlib's own point order) and how long detection took
    rgb.jsonl       --concurrent only, per RGB frame: seconds, frame size, and the face
                    box as fractions of the frame. NO RGB PICTURE is kept.
    meta.json       the kind, the date, the library versions and what each camera said

It opens the infrared node and, for `concurrent` only, the RGB node, both for reading,
and releases them when it ends -- on a finished lap, Ctrl-C, SIGTERM or an error. It
does not use the network (nothing here imports a socket), writes only under the output
directory, and never touches the face daemon, PAM, polkit or anything under /etc. Run it
as yourself, not as root, and not while a sudo or the lock screen is checking your face.
"""

import argparse
import bz2
import datetime
import json
import os
import signal
import subprocess
import sys
import threading
import time

CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "omarchy-face-enrol")
HERE = os.path.dirname(os.path.abspath(__file__))
CAMERA_HELPER = os.path.join(os.path.dirname(HERE), "system", "omarchy-face-camera")
ENGINE_JSON = "/var/lib/omarchy-face/engine.json"
YAY_HOWDY = os.path.expanduser("~/.cache/yay/howdy")
PREDICTOR = "shape_predictor_5_face_landmarks.dat"

MAX_SECONDS = 90          # frames are held in memory until the lap ends: 90 s of 400x400 at 15 fps is ~220 MB
MAX_IDLE_READS = 30       # consecutive failed reads before a camera is called dead

# kind -> (title, seconds, what to do). One sentence each, said before the countdown.
KINDS = {
    "desk": ("A slow lap at the desk", 45,
             "Sit as you normally do, laptop on the desk. Look at the camera, then turn your head slowly "
             "to your right, look up, turn left, look down and come back round: a full circle in about "
             "15 seconds. Go round three times."),
    "inlap": ("A slow lap with the laptop in your lap", 45,
              "Laptop on your lap, the way you use it on the sofa. Same slow circle, three times round."),
    "tilt": ("A slow lap with the laptop tilted", 45,
             "Tilt the screen back or forward from where you normally have it, so the camera looks up or "
             "down at you. Same slow circle, three times round."),
    "far": ("A slow lap farther away", 45,
            "Lean back, or push the laptop to arm's length, so your face is about a quarter smaller in the "
            "frame. Same slow circle, three times round."),
    "concurrent": ("A lap with the RGB camera on as well", 45,
                   "As at the desk, but the colour camera runs too, as the enrolment preview does. For the "
                   "first 15 seconds hold your head still for 3 seconds at a time in the left, right, top "
                   "and bottom of the picture (move yourself, not the laptop); then the slow circle."),
    "stranger": ("Another person's face, with their consent", 20,
                 "Look at the camera, then turn your head a little each way and up and down, slowly, for the "
                 "whole time."),
}
ORDER = ("desk", "inlap", "tilt", "far", "concurrent")


def say(text=""):
    print(text, flush=True)


def fail(text, code=1):
    print("enrol-record: " + text, file=sys.stderr)
    return code


# --- locating things ----------------------------------------------------------

def helper(*args):
    """omarchy-face-camera only reads sysfs and prints names; it never opens a stream."""
    try:
        done = subprocess.run([CAMERA_HELPER] + list(args), capture_output=True, text=True, timeout=10,
                              stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.strip() if done.returncode == 0 and done.stdout.strip() else None


def ir_device(given):
    if given:
        return given
    try:
        with open(ENGINE_JSON, encoding="utf-8") as handle:
            path = json.load(handle).get("device_path")
        if path:
            return path
    except (OSError, ValueError):
        pass
    return helper("--ir-node")


def rgb_device(given):
    return given or helper("--rgb-node")


def find_models(models_dir):
    """The 5-point landmark model, decompressed once into `models_dir`.

    The installed copy under /usr/lib/security/howdy is root-only, so this reads the
    package build's bz2 from the AUR cache, if it is there. HOG detection needs no model.
    """
    ready = os.path.join(models_dir, PREDICTOR)
    if os.path.exists(ready):
        return ready
    for root, _dirs, names in os.walk(YAY_HOWDY):
        if PREDICTOR + ".bz2" in names:
            os.makedirs(models_dir, mode=0o700, exist_ok=True)
            with bz2.open(os.path.join(root, PREDICTOR + ".bz2")) as source, open(ready + ".part", "wb") as target:
                target.write(source.read())
            os.replace(ready + ".part", ready)
            return ready
    return None


def open_camera(cv2, path, kind):
    """(capture, how it went). Devices go through V4L2, anything else (a file, for a dry run) as given."""
    note = {"device": path, "kind": kind, "opened": False, "error": None}
    try:
        capture = cv2.VideoCapture(path, cv2.CAP_V4L2) if str(path).startswith("/dev/") else cv2.VideoCapture(path)
    except Exception as error:  # cv2 raises on some bad arguments
        note["error"] = repr(error)
        return None, note
    if not capture.isOpened():
        capture.release()
        note["error"] = "could not be opened (in use by another program, or no permission)"
        return None, note
    note["opened"] = True
    note["properties"] = {
        "width": capture.get(cv2.CAP_PROP_FRAME_WIDTH), "height": capture.get(cv2.CAP_PROP_FRAME_HEIGHT),
        "fps": capture.get(cv2.CAP_PROP_FPS), "fourcc": int(capture.get(cv2.CAP_PROP_FOURCC)),
        "convert_rgb": capture.get(cv2.CAP_PROP_CONVERT_RGB),
    }
    return capture, note


# --- capture threads ----------------------------------------------------------

class Lap:
    """One camera's frames, held in memory so writing to disk never slows the reads."""

    def __init__(self):
        self.frames = []        # (seconds on the monotonic clock, read seconds, ndarray)
        self.reads_failed = 0
        self.first_frame_at = None
        self.last_error = None


def grab(cv2, capture, lap, deadline, stop, keep):
    """Read until the deadline; hand each frame to `keep`. Always releases the camera."""
    idle = 0
    try:
        while not stop.is_set() and time.monotonic() < deadline:
            before = time.monotonic()
            ok, frame = capture.read()
            after = time.monotonic()
            if not ok or frame is None:
                lap.reads_failed += 1
                idle += 1
                if idle >= MAX_IDLE_READS:
                    lap.last_error = "%d reads in a row returned nothing" % MAX_IDLE_READS
                    break
                time.sleep(0.02)
                continue
            idle = 0
            if lap.first_frame_at is None:
                lap.first_frame_at = after
            keep(after, after - before, frame)
    except Exception as error:  # a driver can raise mid-stream; keep what was read
        lap.last_error = repr(error)
    finally:
        capture.release()


def to_gray(cv2, frame):
    return cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame


def to_u8(np, frame):
    return (frame >> 8).astype(np.uint8) if frame.dtype == np.uint16 else frame


# --- detection, after the lap -------------------------------------------------

def load_dlib(models_dir):
    try:
        import dlib
    except ImportError:
        return None, None, None
    path = find_models(models_dir)
    predictor = dlib.shape_predictor(path) if path else None
    return dlib, dlib.get_frontal_face_detector(), predictor


def describe_faces(dlib, cv2, detector, predictor, gray8):
    """howdy's treatment: CLAHE, then HOG with one upsample; the five landmarks of every face."""
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    equalised = clahe.apply(gray8)
    started = time.monotonic()
    rectangles = detector(equalised, 1)
    faces = []
    for rectangle in rectangles:
        face = {"box": [rectangle.left(), rectangle.top(), rectangle.right(), rectangle.bottom()]}
        if predictor is not None:
            shape = predictor(equalised, rectangle)
            face["landmarks"] = [[shape.part(i).x, shape.part(i).y] for i in range(shape.num_parts)]
        faces.append(face)
    return faces, (time.monotonic() - started) * 1000.0


# --- the run -------------------------------------------------------------------

def countdown(seconds, stop):
    for left in range(seconds, 0, -1):
        if stop.is_set():
            return
        say("  starting in %d..." % left)
        stop.wait(1.0)


def consent():
    if not sys.stdin.isatty():
        return False
    say("This records infrared pictures of another person's face, to a folder on this computer only")
    say("(%s). Nothing is sent anywhere or committed. They can ask you to delete it." % CACHE)
    return input("Has this person agreed to be recorded for this? Type yes: ").strip().lower() == "yes"


def record(args):
    kind = "stranger" if args.stranger else args.kind
    title, default_seconds, instructions = KINDS[kind]
    seconds = min(args.seconds or default_seconds, MAX_SECONDS)
    if os.geteuid() == 0:
        return fail("run this as yourself, not as root: the recordings belong to you")
    os.umask(0o077)  # pictures of a face: nobody else reads them
    if kind == "stranger" and not consent():
        return fail("no consent, nothing recorded")

    try:
        import cv2
        import numpy as np
    except ImportError as error:
        return fail("needs python-opencv and python-numpy (%s)" % error)

    out = os.path.join(args.out or CACHE, "%s-%s" % (datetime.datetime.now().strftime("%Y%m%d-%H%M%S"), kind))
    models = os.path.join(args.out or CACHE, "models")
    concurrent = kind == "concurrent"

    dlib, detector, predictor = load_dlib(models)
    if concurrent and detector is None:
        return fail("the concurrent lap needs dlib to find your face in the RGB picture (no RGB picture is kept)")
    ir_path = ir_device(args.ir)
    if not ir_path:
        return fail("could not find the infrared camera; pass --ir /dev/videoN")
    rgb_path = rgb_device(args.rgb) if concurrent else None
    if concurrent and not rgb_path:
        return fail("could not find the RGB camera; pass --rgb /dev/videoN")

    stop = threading.Event()
    for name in (signal.SIGINT, signal.SIGTERM):
        signal.signal(name, lambda *_: stop.set())

    say()
    say(title)
    say()
    say("  " + instructions)
    say()
    say("  Infrared: %s" % ir_path)
    if concurrent:
        say("  RGB:      %s  (only where your face is, as numbers; no colour picture is kept)" % rgb_path)
    say("  Recording %d seconds. Ctrl-C ends it early and keeps what it has." % seconds)
    say()
    countdown(args.countdown, stop)
    if stop.is_set():
        return fail("cancelled before the camera was opened", 130)

    notes = []
    rgb_lap, ir_lap = Lap(), Lap()
    rgb_rows = []
    threads = []
    interrupted = False
    rgb_capture = ir_capture = None
    try:
        # The product turns the preview on first and opens the infrared camera under it.
        if concurrent:
            rgb_capture, note = open_camera(cv2, rgb_path, "rgb")
            notes.append(note)
            if rgb_capture is None:
                return fail("the RGB camera: " + note["error"])
        ir_capture, note = open_camera(cv2, ir_path, "ir")
        notes.append(note)
        if ir_capture is None:
            if rgb_capture is not None:
                rgb_capture.release()
            say("  The infrared camera did not open%s." % (" while the RGB camera was running: that is the finding" if concurrent else ""))
            _write_meta(out, kind, notes, ir_lap, rgb_lap, args, seconds, False, note["error"])
            return fail("the infrared camera: " + note["error"])

        started = time.monotonic()
        deadline = started + seconds
        if rgb_capture is not None:

            def keep_rgb(at, took, frame):
                height, width = frame.shape[:2]
                scale = 320.0 / width if width > 320 else 1.0
                reduced = cv2.resize(to_gray(cv2, frame), None, fx=scale, fy=scale) if scale != 1.0 else to_gray(cv2, frame)
                found = detector(to_u8(np, reduced), 0)
                biggest = max(found, key=lambda r: r.width() * r.height()) if found else None
                box = None
                if biggest is not None:
                    box = [biggest.left() / reduced.shape[1], biggest.top() / reduced.shape[0],
                           biggest.right() / reduced.shape[1], biggest.bottom() / reduced.shape[0]]
                rgb_rows.append({"t": round(at - started, 4), "w": width, "h": height, "faces": len(found), "box": box})

            threads.append(threading.Thread(target=grab, args=(cv2, rgb_capture, rgb_lap, deadline, stop, keep_rgb)))

        def keep_ir(at, took, frame):
            ir_lap.frames.append((at, took, to_u8(np, to_gray(cv2, frame)).copy()))

        threads.append(threading.Thread(target=grab, args=(cv2, ir_capture, ir_lap, deadline, stop, keep_ir)))
        say("  RECORDING")
        for thread in threads:
            thread.start()
        while any(thread.is_alive() for thread in threads):
            for thread in threads:
                thread.join(0.25)
        interrupted = stop.is_set()
    finally:
        # grab() releases its camera in a finally; this is the same promise for a failure
        # between opening a camera and starting its thread.
        stop.set()
        for thread in threads:
            thread.join(5.0)
        for capture in (rgb_capture, ir_capture):
            if capture is not None:
                capture.release()

    say("  done: %d infrared frames%s%s" % (
        len(ir_lap.frames), (", %d RGB frames" % len(rgb_rows)) if concurrent else "",
        " (ended early)" if interrupted else ""))
    if len(ir_lap.frames) < 20:
        say("  Too few frames to be useful (%s)." % (ir_lap.last_error or "the camera gave almost nothing"))

    os.makedirs(os.path.join(out, "ir"), mode=0o700, exist_ok=True)
    os.chmod(out, 0o700)
    say("  looking for your face in each frame (nothing leaves this computer)...")
    write_ir(cv2, out, ir_lap, dlib, detector, predictor)
    if concurrent:
        with open(os.path.join(out, "rgb.jsonl"), "w", encoding="utf-8") as handle:
            for row in rgb_rows:
                handle.write(json.dumps(row) + "\n")
    _write_meta(out, kind, notes, ir_lap, rgb_lap, args, seconds, True, None, interrupted, len(rgb_rows),
                dlib is not None, predictor is not None)
    say("  saved to %s" % out)
    return 130 if interrupted else 0


def write_ir(cv2, out, lap, dlib, detector, predictor):
    origin = lap.first_frame_at
    with open(os.path.join(out, "frames.jsonl"), "w", encoding="utf-8") as handle:
        for index, (at, took, gray) in enumerate(lap.frames):
            cv2.imwrite(os.path.join(out, "ir", "%05d.png" % index), gray, [cv2.IMWRITE_PNG_COMPRESSION, 1])
            row = {"i": index, "t": round(at - origin, 4), "readMs": round(took * 1000.0, 2),
                   "mean": round(float(gray.mean()), 2), "w": int(gray.shape[1]), "h": int(gray.shape[0])}
            if detector is not None:
                faces, ms = describe_faces(dlib, cv2, detector, predictor, gray)
                row["faces"], row["detectMs"] = faces, round(ms, 2)
            handle.write(json.dumps(row) + "\n")


def _write_meta(out, kind, notes, ir_lap, rgb_lap, args, seconds, completed, error, interrupted=False,
                rgb_frames=0, have_dlib=False, have_predictor=False):
    import cv2
    os.makedirs(out, mode=0o700, exist_ok=True)
    meta = {
        "kind": kind, "at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "requestedSeconds": seconds, "completed": completed, "interrupted": interrupted, "error": error,
        "irFrames": len(ir_lap.frames), "irReadsFailed": ir_lap.reads_failed, "irError": ir_lap.last_error,
        "rgbFrames": rgb_frames, "rgbReadsFailed": rgb_lap.reads_failed, "rgbError": rgb_lap.last_error,
        "cameras": notes, "opencv": cv2.__version__, "dlib": have_dlib, "landmarkModel": have_predictor,
        "landmarkOrder": "dlib shape_predictor_5_face_landmarks point order, as recorded",
        "notes": "RGB pictures are never kept; IR frames are the camera's own, lossless.",
    }
    with open(os.path.join(out, "meta.json"), "w", encoding="utf-8") as handle:
        json.dump(meta, handle, indent=2)
        handle.write("\n")


def show_list():
    say("Phase 0 recordings (plan-face-enroll.md section 8). Do them in this order, one command each,")
    say("from the repository, with nothing else using the camera. Each is 45 seconds plus a 5 second countdown.")
    say()
    for kind in ORDER:
        title, seconds, instructions = KINDS[kind]
        say("  dev/enrol-record.py %-11s %s" % (kind, title))
        say("      " + instructions)
        say()
    say("Optional, with the other person next to you and their yes:")
    say("  dev/enrol-record.py --stranger         %s (%d s)" % (KINDS["stranger"][0], KINDS["stranger"][1]))
    say()
    say("Recordings land in %s" % CACHE)
    say("They never go in git and nothing here sends them anywhere. Say when you are done.")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description="Record laps for the enrolment plan's Phase 0.",
                                     epilog="Run with --list for the whole recording plan.")
    parser.add_argument("kind", nargs="?", choices=ORDER, help="which lap")
    parser.add_argument("--stranger", action="store_true", help="another person's frames (asks for their consent)")
    parser.add_argument("--list", action="store_true", help="print what to record and exit; opens no camera")
    parser.add_argument("--seconds", type=int, help="length of the lap (default 45, 20 for --stranger; at most %d)" % MAX_SECONDS)
    parser.add_argument("--countdown", type=int, default=5, help="seconds before the camera opens (default 5)")
    parser.add_argument("--ir", help="infrared device or file; default: engine.json's device_path")
    parser.add_argument("--rgb", help="RGB device or file; default: the helper's --rgb-node")
    parser.add_argument("--out", help="parent directory for recordings (default ~/.cache/omarchy-face-enrol)")
    args = parser.parse_args(argv)
    if args.list:
        return show_list()
    if args.stranger == bool(args.kind):
        parser.error("give a lap kind, or --stranger, but not both" if args.kind else "give a lap kind (see --list) or --stranger")
    if args.seconds is not None and args.seconds < 1:
        parser.error("--seconds must be at least 1")
    if args.countdown < 0:
        parser.error("--countdown cannot be negative")
    return record(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
