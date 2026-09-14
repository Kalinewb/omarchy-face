#!/usr/bin/env python3

"""Does a bigger sudo set cost search time? (plan-engine.md §7, measured in F3.)

    ./dev/f3-people-store.sh --measure        (this script, inside that sandbox)

The question this answers is the one the plan refuses to assume: with 3, 6 and 9
real encodings in one model set, how long does `compare.py` spend searching for a
known face? The source predicts almost nothing -- per frame it is one norm over
N x 128 floats on top of a detection and an encoding that happen whatever N is
(E8) -- but "almost nothing" is what a measurement is for.

    Pass:  median(9) - median(3) < 150 ms       no cap on Sudo faces
    Fail:  cap Sudo at 3 people (`sudo_limit`)

It needs the real engine and a real face: it records nine encodings of whoever is
in front of the infrared camera, then runs ten comparisons per set with that same
person present. Expect to sit still for a few minutes. Everything it writes is in
the sandbox's tmpfs copy of howdy's directory and disappears with the namespace.
"""

import json
import os
import re
import statistics
import subprocess
import sys
import time

HOWDY = "/usr/lib/security/howdy"
MODELS = HOWDY + "/models"
ENV = {"PATH": "/usr/local/bin:/usr/bin", "HOME": "/root", "LC_ALL": "C",
       "SUDO_USER": "root", "PYTHONDONTWRITEBYTECODE": "1"}

SETS = [3, 6, 9]
RUNS = int(os.environ.get("OMARCHY_FACE_MEASURE_RUNS", "10"))
LIMIT_MS = 150


def run(argv, seconds):
    done = subprocess.run(["timeout", "-k", "2", str(seconds)] + argv, env=ENV,
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    return done.returncode, done.stdout.decode("utf-8", "replace")


def capture(user, index):
    code, output = run(["python3", HOWDY + "/cli.py", "-U", user, "-y", "add"], 40)
    if code != 0:
        print("  capture %d failed: %s" % (index, output.strip().splitlines()[-1:]))
        return False
    return True


def main():
    biggest = max(SETS)
    source = "omarchy-face.measure"
    path = MODELS + "/" + source + ".dat"
    if os.path.exists(path):
        os.unlink(path)

    print("recording %d encodings — look at the camera" % biggest)
    for index in range(biggest):
        if not capture(source, index + 1):
            print("FAILED: could not record %d encodings" % biggest)
            return 1
        print("  %d/%d" % (index + 1, biggest))

    models = json.load(open(path))
    if len(models) < biggest:
        print("FAILED: only %d encodings were recorded" % len(models))
        return 1

    medians = {}
    for size in SETS:
        name = "omarchy-face.measure%d" % size
        subset = []
        for index in range(size):
            entry = dict(models[index])
            entry["id"] = index
            entry["label"] = "measure/%d" % index
            subset.append(entry)
        with open(MODELS + "/" + name + ".dat", "w") as handle:
            json.dump(subset, handle)
        os.chmod(MODELS + "/" + name + ".dat", 0o600)

        timings = []
        for attempt in range(RUNS):
            code, output = run(["python3", HOWDY + "/compare.py", name], 10)
            if code != 0:
                print("  set %d, run %d: compare exited %d" % (size, attempt + 1, code))
                continue
            found = re.search(r"Searching for known face:\s*(\d+)ms", output)
            if found:
                timings.append(int(found.group(1)))
            time.sleep(0.2)
        if not timings:
            print("FAILED: set %d never matched — is the person still there?" % size)
            return 1
        medians[size] = statistics.median(timings)
        print("  set %d: %d runs, median %d ms  %s" %
              (size, len(timings), medians[size], sorted(timings)))

    difference = medians[9] - medians[3]
    print("median(9) - median(3) = %d ms (limit %d)" % (difference, LIMIT_MS))
    if difference < LIMIT_MS:
        print("PASS: more faces do not cost search time; no cap on Sudo")
        return 0
    print("FAIL: plan-engine.md §7's fallback applies — cap Sudo at 3 people (sudo_limit)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
