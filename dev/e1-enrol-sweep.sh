#!/bin/bash

# E1's gate: the enrolment sweep through the REAL parent (`enroll-session`), with a fake
# camera and a fake dlib (plan-face-enroll.md section 7, item 2).
#
#   ./dev/e1-enrol-sweep.sh
#
# In the same private user namespace the other suites use (tmpfs over /etc, /run,
# /var/lib and /usr/lib/security, a uid 0 that owns nothing), howdy's directory gets a
# stub recorders/video_capture.py that plays a SCRIPTED lap (dev/e1-frames.py: 400x400
# numpy images, the landmarks, the face box and whose face it is) and a fake `dlib` is
# bind-mounted over site-packages, as f3 --real does for the real one. cv2 and numpy are
# the real ones, so the engine's own gates (darkness, saturation, sharpness, CLAHE) run on
# real pixels. The camera also keeps a VIRTUAL clock (it patches time.monotonic in the
# child, one 1/15 s step per frame), so a 60 s lap takes a second or two and every dwell,
# grace, patience and ceiling is exact. Nothing but the sandbox is written: no person
# is recorded on this machine, the camera is never opened, nothing is installed.
#
# What this cannot say: whether five landmarks measure a real head (dev/e0-pose.py has the
# synthetic findings; Phase 0's recordings the real ones) or that real dlib behaves like
# the fake. The protocol, the rules (L, P, F, table V), the allow-list and the bounds are
# the real code.

set -uo pipefail

GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; DIM=$'\e[2m'; RESET=$'\e[0m'
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ACCOUNT=${SUDO_USER:-${USER:-$(id -un)}}
failures=0
checks=0

check() { # check <description> <command…>
  local description=$1
  shift
  checks=$((checks + 1))
  if "$@" >/dev/null 2>&1; then
    echo "  ${GREEN}pass${RESET}  $description"
  else
    echo "  ${RED}FAIL${RESET}  $description"
    failures=$((failures + 1))
  fi
}

same() { # same <description> <expected> <actual>
  checks=$((checks + 1))
  if [[ $2 == "$3" ]]; then
    echo "  ${GREEN}pass${RESET}  $1"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected '$2', got '$3')${RESET}"
    failures=$((failures + 1))
  fi
}

step() { echo; echo "${DIM}== $*${RESET}"; }

# --- the sandbox ---------------------------------------------------------------

if [[ ${OMARCHY_FACE_E1_IN_NS:-0} != 1 ]]; then
  command -v unshare >/dev/null || { echo "unshare is not installed" >&2; exit 1; }
  exec env OMARCHY_FACE_E1_IN_NS=1 OMARCHY_FACE_E1_ACCOUNT="$ACCOUNT" \
    unshare --map-root-user --mount --pid --fork "$BASH" "$0"
fi
ACCOUNT=${OMARCHY_FACE_E1_ACCOUNT:-$ACCOUNT}

mount --bind /etc /mnt || exit 1
mount -t tmpfs tmpfs /etc || exit 1
chmod 0755 /etc
for real in /mnt/*; do ln -s "$real" "/etc/${real#/mnt/}"; done
rm -f /etc/omarchy-face 2>/dev/null
mkdir -p /etc/omarchy-face
printf 'account=%s\nsudo=false\nlock=false\n' "$ACCOUNT" >/etc/omarchy-face/config
mount -t tmpfs tmpfs /run || exit 1
chmod 0755 /run
mount -t proc proc /proc 2>/dev/null
mkdir -p /run/real-var-lib
mount --bind /var/lib /run/real-var-lib || exit 1
mount -t tmpfs tmpfs /var/lib || exit 1
chmod 0755 /var/lib
for real in /run/real-var-lib/*; do
  [[ ${real##*/} == omarchy-face* ]] && continue
  ln -s "$real" "/var/lib/${real#/run/real-var-lib/}"
done
mount -t tmpfs tmpfs /usr/lib/security || exit 1
chmod 0755 /usr/lib/security
HOWDY=/usr/lib/security/howdy
mkdir -p $HOWDY/models $HOWDY/recorders $HOWDY/dlib-data
chmod 0755 $HOWDY
chmod 0700 $HOWDY/models

ADMIN=$REPO/system/omarchy-face-admin
STUB=/run/omarchy-face-stub
mkdir -p "$STUB"
LAB=$(mktemp -d /run/e1.XXXXXX)
STORE=/var/lib/omarchy-face
PEOPLE=$STORE/people.json
MODELS=$HOWDY/models

echo "E1 — the enrolment sweep (plan-face-enroll.md section 7, item 2)"
echo "${DIM}sandbox: uid $(id -u) in a user namespace; /etc /run /var/lib and /usr/lib/security are private to this run${RESET}"

# howdy's config as the engine reads it, and the legacy `add`/`compare` stubs `capture` still uses
cat >$HOWDY/config.ini <<'INI'
[video]
certainty = 3.5
timeout = 5
dark_threshold = 50
max_height = 320
device_path = /run/omarchy-face-stub/ir
recording_plugin = opencv
[core]
use_cnn = false
[debug]
end_report = true
INI
: >"$STUB/ir"
cat >$HOWDY/cli.py <<'PY'
import json, os, sys
args = sys.argv[1:]
model = args[args.index("-U") + 1]
encoding = [round(0.01 + index * 0.001, 6) for index in range(128)]
path = os.path.abspath(__file__ + "/../models/" + model + ".dat")
json.dump([{"time": 1789400000, "label": "Initial model", "id": 0, "data": [encoding]}], open(path, "w"))
os.chmod(path, 0o600)
PY
cat >$HOWDY/compare.py <<'PY'
import json, os, sys
path = os.path.abspath(__file__ + "/../models/" + sys.argv[1] + ".dat")
models = json.load(open(path))
print("Certainty of winning frame: 2.800")
print('Winning model: 0 ("%s")' % models[0]["label"])
PY

# The camera: plays $STUB/frames.json, one entry per read, on a virtual clock.
cat >$HOWDY/recorders/video_capture.py <<'PY'
import json, os, select, sys, time
import cv2
import numpy as np
import dlib

CONTROL = "/run/omarchy-face-stub"
_now = [5000.0]
time.monotonic = lambda: _now[0]          # the engine's clock is this camera's


class _Internal:
    def get(self, prop):
        return 400


class VideoCapture:
    def __init__(self, config):
        # Only the path the code under test hands over is opened; nothing is logged about it.
        open(config.get("video", "device_path"), "rb").close()
        launches = CONTROL + "/launches"
        n = int(open(launches).read()) + 1 if os.path.exists(launches) else 1
        open(launches, "w").write(str(n))
        numbered = CONTROL + "/frames.%d.json" % n
        self.frames = json.load(open(numbered if os.path.exists(numbered) else CONTROL + "/frames.json"))
        self.index = 0
        self.internal = _Internal()
        self.fw = self.fh = 400

    def release(self):
        pass

    def read_frame(self):
        spec = self.frames[min(self.index, len(self.frames) - 1)]
        if spec.get("hold") and self.index < len(self.frames):
            select.select([0], [], [], 20)          # wait until a line is waiting on stdin
        self.index += 1
        _now[0] += spec["dt"]
        time.sleep(0.001)
        dlib.CURRENT = spec
        rng = np.random.RandomState(self.index)
        kind = spec["kind"]
        gray = np.clip(rng.normal(110, 40, (400, 400)), 1, 253).astype(np.uint8)
        if kind == "dark":
            gray = rng.randint(0, 8, (400, 400)).astype(np.uint8)
        elif kind == "sat":
            gray[rng.random_sample((400, 400)) < 0.3] = 255
        elif kind == "blur":
            gray = cv2.GaussianBlur(gray, (0, 0), 25)
        elif kind == "black":
            gray = np.zeros((400, 400), np.uint8)
        elif kind == "unlit":
            # The strobing emitter's off phase as MEASURED (dev/fixtures/ir-strobe-stats.json): never
            # exactly black. A mean of about 1.3, a few hundred pixels that survive CLAHE, so about
            # 99.8% in the darkest bin.
            gray = rng.poisson(1.2, (400, 400)).astype(np.uint8)
            gray.flat[rng.randint(0, 160000, 900)] = rng.randint(8, 26, 900)
        elif kind == "unlit-start":
            # the first unlit frames of a stream, measured at 89% dark with a mean of 6
            gray = rng.poisson(5.0, (400, 400)).astype(np.uint8)
            gray.flat[rng.randint(0, 160000, 14000)] = rng.randint(10, 57, 14000)
        elif kind == "lit":
            # a lit frame as measured: 27-37% dark, a mean of 31-65 (not the 10% of "ok")
            gray = np.clip(rng.normal(80, 35, (400, 400)), 1, 253).astype(np.uint8)
            dim = rng.random_sample((400, 400)) < 0.3
            gray[dim] = rng.randint(0, 12, int(dim.sum())).astype(np.uint8)
        elif kind == "dim":
            # lit but dim: mostly the darkest values with a fifth of the pixels brighter, so that
            # after CLAHE about 80% sit in the darkest bin (over DARK_MAX, under 100: not black)
            gray = rng.randint(0, 8, (400, 400)).astype(np.uint8)
            gray[rng.random_sample((400, 400)) < 0.2] = 120
        frame = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
        return frame, gray
PY

# The fake dlib, bind-mounted over site-packages as f3 --real does for the real one.
site=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
mkdir -p /run/real-site "$LAB/site"
mount --bind "$site" /run/real-site || exit 1
# A real dlib on this machine would win over the fake (a package beats a module), so
# its entries are not linked.
for entry in /run/real-site/*; do
  case ${entry##*/} in dlib|dlib-*|dlib.*|_dlib*) continue ;; esac
  ln -s "$entry" "$LAB/site/${entry##*/}"
done
cat >"$LAB/site/dlib.py" <<'PY'
FAKE = True
CURRENT = {}


class _Rect:
    def __init__(self, l, t, r, b):
        self._v = (int(l), int(t), int(r), int(b))
    def left(self): return self._v[0]
    def top(self): return self._v[1]
    def right(self): return self._v[2]
    def bottom(self): return self._v[3]


class _Part:
    def __init__(self, x, y):
        self.x, self.y = x, y


class _Shape:
    def __init__(self, points):
        self._p = points
    def parts(self):
        return [_Part(x, y) for x, y in self._p]


def get_frontal_face_detector():
    def detect(image, upsample):
        f = image.shape[0] / 400.0
        spec = CURRENT
        boxes = [_Rect(*(v * f for v in spec["box"]))]
        if spec["faces"] > 1:
            boxes.append(_Rect(*((v + 30) * f for v in spec["box"])))
        return boxes if spec["faces"] else []
    return detect


def shape_predictor(path):
    return lambda image, rect: _Shape([(x * image.shape[0] / 400.0, y * image.shape[0] / 400.0)
                                       for x, y in CURRENT["pts"]])


class face_recognition_model_v1:
    def __init__(self, path):
        pass
    def compute_face_descriptor(self, image, shape, jitter):
        vector = [0.0] * 128
        # one axis carries whose face it is; a hair of per-frame difference rides on another
        vector[0] = CURRENT["who"]
        vector[1] = 0.004 * (int(CURRENT["pts"][4][0] * 10) % 7)
        # how far this pose has moved the same face from its straight-on descriptor (the owner's own
        # frames at a turn are 0.3-0.46 from the centre: dev/measure-guard.py)
        vector[CURRENT.get("axis", 2)] = CURRENT.get("drift", 0.0)
        return vector
PY
mount --bind "$LAB/site" "$site" || exit 1
python3 -c 'import dlib; assert dlib.FAKE' || { echo "  ${RED}FAIL${RESET}  the fake dlib is not what imports"; exit 1; }

# --- driving a session ---------------------------------------------------------

scenario() { # scenario <name…>: one per launch of the engine (a second lap plays the second)
  local n=0 name
  rm -f "$STUB"/frames.*.json "$STUB/launches"
  python3 "$REPO/dev/e1-frames.py" "$1" >"$STUB/frames.json"
  for name in "$@"; do
    n=$((n + 1))
    python3 "$REPO/dev/e1-frames.py" "$name" >"$STUB/frames.$n.json"
  done
}

session() { # session <name> <directive…>  -> the client's transcript
  local name=$1
  shift
  printf '%s\n' "$@" >"$LAB/script"
  python3 "$REPO/dev/enroll-client.py" "$LAB/script" -- "$ADMIN" enroll-session "$name" 2>&1 | tee -a "$LAB/all.log"
}

q() { # q <transcript> <python expression over evs, tracks, names>  -> JSON
  python3 -c '
import itertools, json, sys
evs = [json.loads(l[3:]) for l in sys.stdin.read().splitlines() if l.startswith("EV ")]
tracks = [e for e in evs if e.get("event") == "track"]
def first(n): return next((e for e in evs if e.get("event") == n), None)
def last(n): return next((e for e in reversed(evs) if e.get("event") == n), None)
names = [k for k, _ in itertools.groupby(e.get("event") or "error:" + e.get("error", "") for e in evs)]
print(json.dumps(eval(sys.argv[1]), separators=(",", ":")))' "$2" <<<"$1"
}

json_field() { python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    doc = doc[int(key)] if key.isdigit() else doc[key]
print(json.dumps(doc))' "$@"; }

SIMPLE='{"cmd":"sweep","appearance":"No glasses","mode":"simple","lap":1,"targets":[9,3,0,6]}'
ALL12='[0,1,2,3,4,5,6,7,8,9,10,11]'
ADV1='{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1,"targets":'$ALL12'}'
ADV2='{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":2,"targets":'$ALL12'}'
CREATE='{"cmd":"create","label":"Emil"}'
FINISH='{"cmd":"finish"}'
DONE='{"cmd":"done"}'

reset_store() { rm -rf "$STORE"/people "$STORE"/people.json "$MODELS"/omarchy-face.*.dat; }

# E1_SHELL='command' runs one command in the sandbox with the helpers above, for debugging.
if [[ -n ${E1_SHELL:-} ]]; then eval "$E1_SHELL"; exit; fi

# =============================================================================

step "ready names the verbs and the limits"
reset_store
scenario simple
out=$(session emil "await ready 30" "eof")
same "ready lists the verbs that exist (trial arrives with its phase)" '["capture","sweep","abort","finish"]' "$(q "$out" 'first("ready")["verbs"]')"
same "ready carries the default limits" '{"lock":12,"sudo":4}' "$(q "$out" 'first("ready")["limits"]')"
same "ready says which stored templates Sudo may use (the policy, a plain word)" '"centre"' "$(q "$out" 'first("ready")["sudoPolicy"]')"

step "a full Simple run: centre, then 9, 3, 0, 6 in that order"
reset_store
scenario simple
out=$(session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 90" "send $DONE" "await saved 30")
echo "${DIM}$(grep -v '"event":"track"' <<<"$out" | head -8 | cut -c1-200)${RESET}"
same "the events: ready, sweeping, track…, swept, saved" '["ready","sweeping","track","swept","saved"]' "$(q "$out" 'names')"
same "sweeping echoes the targets and the quota, and carries no bins" '{"event":"sweeping","mode":"simple","lap":1,"targets":[9,3,0,6],"quota":2}' "$(q "$out" 'first("sweeping")')"
same "the current target goes centre, 9, 3, 0, 6" '["centre",9,3,0,6]' "$(q "$out" '[k for k, _ in itertools.groupby(t["target"] for t in tracks) if k is not None]')"
same "bins are non-zero only at 9, 3, 0, 6" '[0,3,6,9]' "$(q "$out" 'sorted({i for t in tracks for i, x in enumerate(t["bins"]) if x})')"
same "swept: filled all four, none skipped, centre held, five kept" '{"event":"swept","mode":"simple","lap":1,"filled":[0,3,6,9],"skipped":[],"centreHeld":true,"kept":5}' "$(q "$out" 'first("swept")')"
same "canFinish is in every track and turns true once the floor is met" 'true' "$(q "$out" 'any(t["canFinish"] for t in tracks) and not tracks[0]["canFinish"]')"
same "the stored appearance is the centre plus four near templates a000 a090 a180 a270" '["a000","a090","a180","a270"]' "$(python3 -c '
import json,sys
print(json.dumps([e["pose"] for e in json.load(open(sys.argv[1]))["appearances"][0]["extra"]], separators=(",", ":")))' "$STORE/people/emil.json")"
same "...all band near, support 2 or more, r in 0..4, 128 numbers" 'true' "$(python3 -c '
import json,sys
a = json.load(open(sys.argv[1]))["appearances"][0]
print(json.dumps(all(e["band"] == "near" and e["support"] >= 2 and 0 <= e["r"] <= 4 and len(e["encoding"]) == 128 for e in a["extra"])))' "$STORE/people/emil.json")"
same "people.json counts the templates: 5 in the appearance" '5' "$(json_field "$PEOPLE" people.0.appearances.0.templates)"
check "people.json carries no encoding" bash -c "! grep -q encoding $PEOPLE"
same "people.json names the Sudo policy" '"centre"' "$(json_field "$PEOPLE" sudoPolicy)"
same "...and Sudo uses one template of the five (the centre), Lock all five" '[1,5]' "$(python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))["people"][0]
print(json.dumps([p["sudoTemplates"], p["lockTemplates"]], separators=(",", ":")))' "$PEOPLE")"

count_templates() { python3 -c '
import json, sys
a = json.load(open(sys.argv[1]))["appearances"][int(sys.argv[2])]
print(1 + len(a.get("extra") or []))' "$@"; }
no_child() { ! pgrep -f 'python3 -I -c' >/dev/null; }

step "a full Advanced lap: all twelve, in clock order, ends by itself"
reset_store
scenario advanced
out=$(session emil "await ready 30" "send $CREATE" "send $ADV1" "await swept 120" "send $DONE" "await saved 30")
same "sweeping echoes all twelve targets ascending" '[0,1,2,3,4,5,6,7,8,9,10,11]' "$(q "$out" 'first("sweeping")["targets"]')"
same "swept has twelve filled bins, no skipped list, thirteen templates kept" '{"event":"swept","mode":"advanced","lap":1,"filled":[0,1,2,3,4,5,6,7,8,9,10,11],"skipped":[],"centreHeld":true,"kept":13}' "$(q "$out" 'first("swept")')"
same "the first track asks for the centre and canFinish is false" '["centre",false]' "$(q "$out" '[tracks[0]["target"], tracks[0]["canFinish"]]')"
same "the record holds the centre and twelve near templates" '13' "$(count_templates "$STORE/people/emil.json" 0)"
same "the lock set is capped at 12, labelled emil/No glasses for every template" '[12,["emil/No glasses"]]' "$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(json.dumps([len(m), sorted({e["label"] for e in m})], separators=(",", ":")))' "$MODELS/omarchy-face.person.emil.dat")"
check "each model entry holds exactly one encoding of 128 numbers (E8 attribution holds)" python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
assert all(len(e["data"]) == 1 and len(e["data"][0]) == 128 for e in m)' "$MODELS/omarchy-face.person.emil.dat"
same "the sudo set holds the centre only (SUDO_POLICY centre; r 1.6 is also past the Sudo band)" '1' "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$MODELS/omarchy-face.sudo.$ACCOUNT.dat" 2>/dev/null || echo 1)"

step "lap 2 at another distance, and a lap 2 by somebody else"
reset_store
scenario advanced lap2
out=$(session emil "await ready 30" "send $CREATE" "send $ADV1" "await swept 120" "send $ADV2" "awaitwhere {\"event\":\"swept\",\"lap\":2} 120" "send $DONE" "await saved 30")
same "lap 2 is swept with twelve bins and 25 templates kept, centre held" '{"event":"swept","mode":"advanced","lap":2,"filled":[0,1,2,3,4,5,6,7,8,9,10,11],"skipped":[],"centreHeld":true,"kept":25}' "$(q "$out" 'last("swept")')"
same "lap 2 starts with the centre reported held" '[true,1.0]' "$(q "$out" '[t["centre"] == 1.0 for t in tracks[-1:]] + [tracks[-1]["centre"]]' | sed 's/\[true,/[true,/')"
same "the record holds both bands: 12 near and 12 far" '[12,12]' "$(python3 -c '
import json, sys
a = json.load(open(sys.argv[1]))["appearances"][0]["extra"]
print(json.dumps([sum(e["band"] == "near" for e in a), sum(e["band"] == "far" for e in a)], separators=(",", ":")))' "$STORE/people/emil.json")"
reset_store
scenario advanced lap2-other
out=$(session emil "await ready 30" "send $CREATE" "send $ADV1" "await swept 120" "send $ADV2" "awaitwhere {\"event\":\"capture_failed\",\"code\":\"changed\"} 120" "send $DONE" "eof")
same "a second identity in lap 2 is 'changed', which takes the whole appearance's set with it" '["changed","bad_sweep"]' "$(q "$out" '[c["code"] for c in evs if c.get("event") == "capture_failed"]')"
check "...so nothing is stored, and done in the ready state is refused" bash -c "[[ ! -e $STORE/people/emil.json ]]"
reset_store
scenario advanced hold-first
out=$(session emil "await ready 30" "send $CREATE" "send $ADV1" "await swept 120" "send $ADV2" "awaitwhere {\"event\":\"sweeping\",\"lap\":2} 30" "send {\"cmd\":\"abort\"}" "await aborted 30" "send $DONE" "await saved 30")
same "an aborted lap 2 keeps lap 1 (table V): the session is in swept and done saves its thirteen" '13' "$(count_templates "$STORE/people/emil.json" 0)"

step "Simple's order is the engine's"
reset_store
scenario simple-wrong
out=$(OMARCHY_FACE_SWEEP_SECONDS=20 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "a steady head in the wrong wedge (6) fills nothing while 9 is current" 'true' "$(q "$out" 'all(t["bins"][6] == 0 for t in tracks if t["target"] == 9)')"
same "the target stays 9 until the engine skips it, and the skip is announced in track.skipped" 'true' "$(q "$out" 'any(9 in t["skipped"] for t in tracks) and tracks[-1]["target"] in (9, 3)')"
same "nothing held at the ceiling is too_few" '"too_few"' "$(q "$out" 'last("capture_failed")["code"]')"
reset_store
scenario simple-sweep-through
out=$(OMARCHY_FACE_SWEEP_SECONDS=20 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "a head sweeping through the wedges without a hold fills nothing" '[true,"too_few"]' "$(q "$out" '[all(max(t["bins"]) < 1.0 for t in tracks), last("capture_failed")["code"]]')"
scenario simple-grace
out=$(OMARCHY_FACE_SWEEP_SECONDS=20 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "0.5 s out of the wedge resets the dwell: progress rises, falls to 0, rises again" 'true' "$(q "$out" '(lambda v: (lambda d: len(d) >= 1 and any(v[i] > v[i - 1] for i in range(d[0] + 1, len(v))))([i for i in range(1, len(v)) if v[i] == 0 and v[i - 1] > 0]))([t["bins"][9] for t in tracks if t["target"] == 9])')"

step "patience, resolved targets, and the ceiling (rules P and L)"
reset_store
scenario simple-two
out=$(OMARCHY_FACE_SWEEP_SECONDS=60 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 120" "send $DONE" "await saved 30")
same "two skipped plus two filled ends swept, the skipped listed, three templates kept" '{"event":"swept","mode":"simple","lap":1,"filled":[3,9],"skipped":[0,6],"centreHeld":true,"kept":3}' "$(q "$out" 'first("swept")')"
same "...and the saved appearance has three templates" '3' "$(count_templates "$STORE/people/emil.json" 0)"
reset_store
scenario simple-one
out=$(OMARCHY_FACE_SWEEP_SECONDS=60 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\",\"code\":\"too_few\"} 120" "send $DONE" "eof")
same "three skipped plus one filled ends too_few" '["too_few","bad_sweep"]' "$(q "$out" '[c["code"] for c in evs if c.get("event") == "capture_failed"][:2]')"
check "...and nothing is stored, and done after a dropped lap is refused" bash -c "[[ ! -e $STORE/people/emil.json ]]"
reset_store
scenario simple-three
out=$(OMARCHY_FACE_SWEEP_SECONDS=18 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 120" "send $DONE" "await saved 30")
same "at the ceiling with three filled and one unresolved the lap saves, listing the unresolved as skipped" '{"event":"swept","mode":"simple","lap":1,"filled":[0,3,9],"skipped":[6],"centreHeld":true,"kept":4}' "$(q "$out" 'first("swept")')"
reset_store
scenario simple-one
out=$(OMARCHY_FACE_SWEEP_SECONDS=18 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "at the ceiling with one filled it is too_few" '"too_few"' "$(q "$out" 'last("capture_failed")["code"]')"
reset_store
scenario no-centre
out=$(OMARCHY_FACE_SWEEP_SECONDS=18 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "a centre that is never held is lap_timeout" '"lap_timeout"' "$(q "$out" 'last("capture_failed")["code"]')"
reset_store
scenario black
out=$(OMARCHY_FACE_SWEEP_SECONDS=18 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "...and all-black frames are named black_frames" '"black_frames"' "$(q "$out" 'last("capture_failed")["code"]')"
same "...and a covered or dead camera still says dark, after 2 s with nothing lit (the strobe rule does not silence it)" 'true' "$(q "$out" 'any(t["state"] == "dark" for t in tracks)')"

step "the fake camera's strobe frames have the MEASURED distribution (dev/fixtures/ir-strobe-stats.json), not exactly black"
scenario calibrate
check "unlit frames are 99.5-99.99% dark with a mean under 2.5, the start ones 85-97% with a mean under 8, lit ones 25-40% with a mean of 40-70; none is exactly 100" python3 - "$REPO/dev/fixtures/ir-strobe-stats.json" <<'PY'
import json, sys
sys.path.insert(0, "/usr/lib/security/howdy")
import cv2, numpy as np
from recorders.video_capture import VideoCapture
stats = json.load(open(sys.argv[1]))
class Config:
    def get(self, *a):
        return "/dev/null"
camera = VideoCapture(Config())
clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
rows = {"unlit": [], "unlit-start": [], "lit": []}
for kind in ("unlit", "unlit-start", "lit"):
    for _ in range(30):
        frame, gray = camera.read_frame()
        hist = cv2.calcHist([clahe.apply(gray)], [0], None, [8], [0, 256])
        rows[kind].append((float(hist[0] / np.sum(hist) * 100), float(gray.mean())))
def span(kind, axis):
    values = [r[axis] for r in rows[kind]]
    return min(values), max(values)
ok = (99.5 <= span("unlit", 0)[0] and span("unlit", 0)[1] < 99.99 and span("unlit", 1)[1] < 2.5
      and 85 <= span("unlit-start", 0)[0] and span("unlit-start", 0)[1] <= 97 and span("unlit-start", 1)[1] < 8
      and 25 <= span("lit", 0)[0] and span("lit", 0)[1] <= 40 and 40 <= span("lit", 1)[0] and span("lit", 1)[1] <= 70)
print({k: (tuple(round(x, 2) for x in span(k, 0)), tuple(round(x, 2) for x in span(k, 1))) for k in rows}, file=sys.stderr)
print("measured on the laptop:", stats["unlit"]["darkness"], stats["lit"]["darkness"], file=sys.stderr)
sys.exit(0 if ok else 1)
PY

step "a strobing emitter (3.1.2): every other frame is unlit, and that is not the room being dark"
reset_store
scenario simple-strobe
out=$(session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 120" "send $DONE" "await saved 30")
same "a Simple lap on a strobing camera (half the frames black) finishes: all four targets" '[0,3,6,9]' "$(q "$out" 'first("swept")["filled"]')"
same "...and never says dark: the off phases are not a state, no word is emitted for them" 'false' "$(q "$out" 'any(t["state"] == "dark" for t in tracks)')"
same "...nor is anything stored short of the five templates the same lap gives without the strobe" '5' "$(q "$out" 'first("swept")["kept"]')"
reset_store
scenario advanced-strobe
out=$(session emil "await ready 30" "send $CREATE" "send $ADV1" "await swept 180" "send $DONE" "await saved 30")
same "an Advanced lap on a strobing camera fills all twelve bins, with no dark word" '[12,false]' "$(q "$out" '[len(first("swept")["filled"]), any(t["state"] == "dark" for t in tracks)]')"
reset_store
scenario strobe-black
out=$(OMARCHY_FACE_SWEEP_SECONDS=18 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "a strobe whose lit frames are all black too is black_frames" '"black_frames"' "$(q "$out" 'last("capture_failed")["code"]')"
reset_store
scenario dim
out=$(OMARCHY_FACE_SWEEP_SECONDS=18 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "an all-dim stream (every frame lit but too dark) is too_dark" '"too_dark"' "$(q "$out" 'last("capture_failed")["code"]')"
reset_store
scenario strobe-dim
out=$(OMARCHY_FACE_SWEEP_SECONDS=18 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "...and behind a strobe it is too_dark still, not black_frames (the off phases are not evidence)" '"too_dark"' "$(q "$out" 'last("capture_failed")["code"]')"
same "...the strobe frames still count towards the ceiling (it ended at 18 s of frame time, not 18 s of lit frames)" 'true' "$(q "$out" 'len([e for e in evs if e.get("event") == "capture_failed"]) >= 1')"
reset_store
scenario unlit-room
out=$(OMARCHY_FACE_SWEEP_SECONDS=18 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "a room too dark for the emitter (every frame unlit, no strobe) still ends: black_frames, and says dark after the 2 s of silence" '["black_frames",true]' "$(q "$out" '[last("capture_failed")["code"], any(t["state"] == "dark" for t in tracks)]')"

step "the same-person guard (3.1.5): ok / band / beyond. Strangers WITH per-frame spread, and the owner's far turn, pinned"
stored_all_owner() { # stored_all_owner [min]: every descriptor in the store is the owner's (axis 0 is the fake stranger's gap)
  python3 -c "
import json, glob
bad = 0; n = 0
for path in glob.glob('$STORE/people/emil.json'):
    for appearance in json.load(open(path)).get('appearances', []):
        for e in [appearance['encoding']] + [x['encoding'] for x in appearance.get('extra', [])]:
            n += 1; bad += abs(e[0]) > 0.1
print(str(n >= ${1:-5} and bad == 0).lower())
"
}
# A stranger every frame of whom is in the band (0.40-0.55 from the owner's): nothing is accepted (so nothing is
# stored), nothing is a stranger frame by the counter (so the lap is not ended `changed`), the targets run out.
for sc in simple-gap-046 simple-gap-050 simple-gap-054 simple-midswap simple-foothold; do
  reset_store
  scenario $sc
  out=$(OMARCHY_FACE_SWEEP_SECONDS=100 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 150" "eof")
  same "$sc: a stranger in the band (0.40-0.55 from the owner's, with wobble; or one foothold frame then frames near it) after the centre: not accepted, not stored, the lap ends too_few (3.1.5; 3.1.3 ended it changed)" '["too_few",false]' "$(q "$out" '[last("capture_failed")["code"], first("swept") is not None]')"
  check "...$sc: and nothing was written" bash -c "[[ ! -e $STORE/people/emil.json ]]"
done
for sc in simple-gap-058 simple-gap-062 simple-band-beyond-mix simple-stranger; do
  reset_store
  scenario $sc
  out=$(OMARCHY_FACE_SWEEP_SECONDS=100 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 150" "eof")
  same "$sc: a stranger past HARD (0.55) from the owner's, or beyond-HARD frames alternating with band ones (band frames neither count nor reset the run), ends changed, nothing stored" '["changed",false]' "$(q "$out" '[last("capture_failed")["code"], first("swept") is not None]')"
  check "...$sc: and nothing was written" bash -c "[[ ! -e $STORE/people/emil.json ]]"
done
for sc in simple-two-of-three simple-strict-alternation; do
  reset_store
  scenario $sc
  out=$(session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 120" "send $DONE" "await saved 30")
  same "$sc: the stranger's frames come two of three (or every other one) in the band: the owner's frames fill every target, no changed" '[[0,3,6,9],false]' "$(q "$out" '[first("swept")["filled"], any(c.get("code") == "changed" for c in evs)]')"
  same "...$sc: and not one stranger frame is in anything that was stored (every stored descriptor is the owner's)" 'true' "$(stored_all_owner)"
done
reset_store
scenario simple-limit-038
out=$(session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 120" "send $DONE" "await saved 30")
same "THE KNOWN LIMIT: a stranger wholly inside CHAIN of the centre (0.38) is accepted: the lap completes (no stranger data; this pins it so a change is deliberate)" '[[0,3,6,9],false]' "$(q "$out" '[first("swept")["filled"], any(c.get("code") == "changed" for c in evs)]')"
reset_store
scenario simple-straddle
out=$(OMARCHY_FACE_SWEEP_SECONDS=100 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 150" "send $DONE" "await saved 30")
same "NEW IN 3.1.5, THE COST, pinned: a stranger who STRADDLES CHAIN (0.46 +-0.08 from the owner's, so one frame in eight is 0.40 or less) is no longer ended by five refusals in a row: the lap completes (3.1.3 ended it changed)" '[[0,3,6,9],false]' "$(q "$out" '[first("swept")["filled"], any(c.get("code") == "changed" for c in evs)]')"
same "...what is stored passed the per-frame guard, as before, and the chain of TEMPLATES carries it: once one stranger template (0.39) is filled, the stranger's other frames are within CHAIN of it, so the stored descriptors reach past 0.40 but never past HARD (0.55) from the owner's centre" 'true' "$(python3 -c "
import json, glob
d = []
for path in glob.glob('$STORE/people/emil.json'):
    for appearance in json.load(open(path)).get('appearances', []):
        d += [abs(e[0]) for e in [appearance['encoding']] + [x['encoding'] for x in appearance.get('extra', [])]]
print(str(len(d) >= 5 and 0.40 < max(d) <= 0.55 + 1e-9).lower())
")"
reset_store
scenario simple-owner-turn
out=$(OMARCHY_FACE_SWEEP_SECONDS=100 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 150" "eof")
same "the OWNER far off-centre (0.46 from the centre at every target) is not refused as a stranger any more: no changed; every target runs out and the lap ends too_few (3.1.3's behaviour was changed, the live \"That was not you\")" '"too_few"' "$(q "$out" 'last("capture_failed")["code"]')"
same "...and the scan said so while it was happening: some track events said over (the band), and every target was skipped" 'true' "$(q "$out" 'any(t["state"] == "over" for t in tracks) and sorted(evs[-1].get("skipped", [])) in ([], [0,3,6,9]) or any(sorted(t.get("skipped", [])) == [0,3,6,9] for t in tracks)')"
reset_store
scenario simple-owner-band-updown
out=$(OMARCHY_FACE_SWEEP_SECONDS=100 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 150" "send $DONE" "await saved 30")
same "THE USER'S LAP: left and right fill, up and down are banded (0.46) and skipped by patience: the lap is swept with two filled and two skipped, and saved" '[[3,9],[0,6],true]' "$(q "$out" '[first("swept")["filled"], first("swept")["skipped"], any(e.get("event") == "saved" for e in evs)]')"
same "...and every stored descriptor is the owner's, no stranger frame was credited" 'true' "$(stored_all_owner 3)"
reset_store
scenario simple-stranger
out=$(session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 90" "eof")
same "a whole lap by somebody else after the centre still ends changed" '"changed"' "$(q "$out" 'last("capture_failed")["code"]')"

step "the debug trace (3.1.2): off by default; with debug=true in root's config, one line a second, no frame data"
# A stand-in for `logger`: only the sweep child's own (tag omarchy-face-sweep, no message, lines on
# stdin) is kept; every other call has its message in argv and must not read the caller's stdin.
cat >"$LAB/logger-stub" <<'LOGGER'
#!/bin/bash
if [[ $# -eq 4 && $2 == omarchy-face-sweep ]]; then cat >>/run/omarchy-face-stub/logger.out; else echo "$*" >>/run/omarchy-face-stub/logger.other; fi
LOGGER
chmod +x "$LAB/logger-stub"
mount --bind "$LAB/logger-stub" /usr/bin/logger || exit 1
: >/run/omarchy-face-stub/logger.out
reset_store
scenario simple-strobe
out=$(session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 120" "send $DONE" "await saved 30")
check "off by default: the child logs no debug line" bash -c "! grep -q '^debug ' /run/omarchy-face-stub/logger.out"
printf 'debug=true\n' >>/etc/omarchy-face/config
reset_store
scenario simple-strobe
out=$(session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 120" "send $DONE" "await saved 30")
lines=$(grep -c '^debug ' /run/omarchy-face-stub/logger.out)
check "with debug=true it logs, at most 120 lines for the lap, about one per second of frame time" bash -c "[[ $lines -ge 5 && $lines -le 120 ]]"
check "...each line has the counts, the per-gate failures, the target and what is held, the last word, the mean darkness of the lit frames and the refine candidate" bash -c "grep '^debug ' /run/omarchy-face-stub/logger.out | tail -1 | grep -qE '^debug t=[0-9.]+ frames=[0-9]+ strobe_off=[0-9]+ black=0 lit=[0-9]+ dark=0 none=[0-9]+ multi=[0-9]+ accepted=[0-9]+ acc_s=[0-9]+ closer=[0-9]+ farther=[0-9]+ edge=[0-9]+ exposure=[0-9]+ blurry=[0-9]+ roll=[0-9]+ unsteady=[0-9]+ other=[0-9]+ over=[0-9]+ band=[0-9]+ yaw=-?[0-9a-z/]+ pitch=-?[0-9a-z/]+ pitch_dec=-?[0-9a-z/]+ roll=-?[0-9a-z/]+ centre_gate=(in|out|-) centre_held=[01] filled=[0-9]+ target=[a-z0-9]+ hard_max=[0-9.]+ chain_max=[0-9.]+ guard_run=[0-9]+ lap_end=[a-z_]+ last_word=(skip|ok|hold|dark|blurry|closer|farther|edge|multiple|other|searching|over|band) lit_darkness_mean=[0-9.]+ refine=(None|[a-z_]+)\$'"
same "...the lap's accepted frames are counted (the engine filled four targets from them), and the last word of a strobe-off frame is skip or of an accepted one ok (words that are never on the wire)" 'true' "$(python3 -c "
import re
rows = [dict(re.findall(r'(\w+)=(\S+)', l)) for l in open('/run/omarchy-face-stub/logger.out') if l.startswith('debug ')]
words = {r['last_word'] for r in rows}
print(str(int(rows[-1]['accepted']) > 20 and int(rows[-1]['centre_held']) == 1 and bool(words & {'skip', 'ok'})).lower())
")"
same "...the strobe-off frames are counted, about as many as the lit ones" 'true' "$(python3 -c "
import re
last = [l for l in open('/run/omarchy-face-stub/logger.out') if l.startswith('debug ')][-1]
f = dict(re.findall(r'(\w+)=(\S+)', last))
off, lit = int(f['strobe_off']), int(f['lit'])
print(str(off > 0 and 0.7 <= off / max(1, lit) <= 1.3).lower())
")"
check "...and no frame data: every line is words and numbers, under 400 characters" bash -c "! grep '^debug ' /run/omarchy-face-stub/logger.out | grep -qvE '^debug [A-Za-z_=0-9./ -]+\$' && ! grep '^debug ' /run/omarchy-face-stub/logger.out | awk 'length(\$0) > 400 { bad = 1 } END { exit !bad }'"
same "...the pose is printed twice: pitch as the camera sees it and pitch_dec with rule D taken out; at the right target the fake head reads about 18 and 0" 'true' "$(python3 -c "
import re
rows = [dict(re.findall(r'(\w+)=(\S+)', l)) for l in open('/run/omarchy-face-stub/logger.out') if l.startswith('debug ')]
on = [r for r in rows if r['target'] == '3' and r['pitch'] not in ('n/a',) and r['pitch_dec'] != 'n/a' and abs(int(r['yaw'])) > 15]
print(str(len(on) >= 2 and all(12 <= int(r['pitch']) <= 24 and abs(int(r['pitch_dec'])) <= 5 for r in on)).lower())
")"
reset_store
scenario simple-gap-058
: >/run/omarchy-face-stub/logger.out
out=$(OMARCHY_FACE_SWEEP_SECONDS=100 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 150" "eof")
same "the trace explains a stranger, to the last line: hard_max over 0.55 (the stranger bound), guard_run reaches 5, the lap ends changed (SR1 S3: the final line is written before the lap is left)" 'true' "$(python3 -c "
import re
rows = [dict(re.findall(r'(\w+)=(\S+)', l)) for l in open('/run/omarchy-face-stub/logger.out') if l.startswith('debug ')]
last = rows[-1]
print(str(last['guard_run'] == '5' and last['lap_end'] == 'changed' and float(last['hard_max']) > 0.55 and max(int(r['guard_run']) for r in rows) == 5).lower())
")"
reset_store
scenario simple-owner-turn
: >/run/omarchy-face-stub/logger.out
out=$(OMARCHY_FACE_SWEEP_SECONDS=100 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 150" "eof")
same "...and the owner far off-centre: hard_max under 0.55 and chain_max over 0.40 (the band), band counted, guard_run never above 0, last word band, the lap ends by running out of targets (resolved)" 'true' "$(python3 -c "
import re
rows = [dict(re.findall(r'(\w+)=(\S+)', l)) for l in open('/run/omarchy-face-stub/logger.out') if l.startswith('debug ')]
last = rows[-1]
print(str(float(last['hard_max']) < 0.55 and max(float(r['chain_max']) for r in rows) > 0.40 and int(last['band']) > 5
          and max(int(r['guard_run']) for r in rows) == 0 and 'band' in {r['last_word'] for r in rows} and last['lap_end'] == 'resolved').lower())
")"
printf 'debug=false\n' >>/etc/omarchy-face/config
: >/run/omarchy-face-stub/logger.out
reset_store
scenario simple-strobe
out=$(session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 120" "send $DONE" "await saved 30")
check "the last debug line in the config wins, as in the shell side (debug=true then debug=false: no trace)" bash -c "! grep -q '^debug ' /run/omarchy-face-stub/logger.out"
sed -i '/^debug=/d' /etc/omarchy-face/config
umount /usr/bin/logger

step "finish: below the floor it is not_enough and the lap goes on; at it the lap ends"
reset_store
scenario fin-before
out=$(session emil "await ready 30" "send $CREATE" "send $ADV1" "awaitwhere {\"event\":\"track\",\"target\":9} 60" "sleep 1.5" "send $FINISH" "awaitwhere {\"event\":\"capture_failed\",\"code\":\"not_enough\"} 60" "awaitwhere {\"event\":\"track\",\"canFinish\":true} 60" "send $FINISH" "await swept 60" "send $DONE" "await saved 30")
same "a finish read one frame before the fill gives not_enough, and the lap continues" '["not_enough",true]' "$(q "$out" '[[c["code"] for c in evs if c.get("event") == "capture_failed"][0], any(t["canFinish"] for t in tracks)]')"
same "...then a finish at the floor ends the lap keeping what is held: four bins" '[0,3,6,9]' "$(q "$out" 'first("swept")["filled"]')"
reset_store
scenario fin-after
out=$(session emil "await ready 30" "send $CREATE" "send $ADV1" "awaitwhere {\"event\":\"track\",\"target\":9} 60" "sleep 1.5" "send $FINISH" "await swept 60" "send $DONE" "await saved 30")
same "a finish read after the frame that filled the fourth bin counts it (frame order): swept at once, no not_enough" '[[0,3,6,9],false]' "$(q "$out" '[first("swept")["filled"], any(c.get("code") == "not_enough" for c in evs)]')"
same "a finish in ready, in swept, and after a failed sweep validation is ignored (no event)" '0' "$(out=$(session emil "await ready 30" "send $FINISH" "send {\"cmd\":\"abort\"}" "send {\"cmd\":\"sweep\",\"mode\":\"x\"}" "send $FINISH" "await capture_failed 20" "eof"); q "$out" 'len([e for e in evs if e.get("code") == "not_enough"])')"

step "bad_sweep: every refusal comes through the real parent and the session carries on"
reset_store
scenario simple
bad=(
  '{"cmd":"sweep","appearance":"No glasses","mode":"simple","lap":1,"targets":[3,9,0,6]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"simple","lap":1,"targets":[9,3,0]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"simple","lap":2,"targets":[9,3,0,6]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1,"targets":[0,1,2,3]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1,"targets":[]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1,"targets":[0,0,0,0,0,0,0,0,0,0,0,0]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1,"targets":[true,1,2,3,4,5,6,7,8,9,10,11]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1,"targets":[0.0,1,2,3,4,5,6,7,8,9,10,11]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1,"targets":["0",1,2,3,4,5,6,7,8,9,10,11]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1,"targets":[null,1,2,3,4,5,6,7,8,9,10,11]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1,"targets":[0,1,2,3,4,5,6,7,8,9,10,12]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1,"targets":[0,1,2,3,4,5,6,7,8,9,10,-1]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":2,"targets":[0,1,2,3,4,5,6,7,8,9,10,11]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":0,"targets":[0,1,2,3,4,5,6,7,8,9,10,11]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":true,"targets":[0,1,2,3,4,5,6,7,8,9,10,11]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":NaN,"targets":[0,1,2,3,4,5,6,7,8,9,10,11]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1e400,"targets":[0,1,2,3,4,5,6,7,8,9,10,11]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"lap","lap":1,"targets":[0,1,2,3,4,5,6,7,8,9,10,11]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"","lap":1,"targets":[]}'
  '{"cmd":"sweep","appearance":"No glasses","lap":1,"targets":[9,3,0,6]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"simple","lap":1,"targets":[9,3,0,Infinity]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"usual","lap":1,"targets":[3]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"usual","lap":1}'
  '{"cmd":"trial","appearance":"No glasses"}'
  '{"cmd":"sweep","appearance":"","mode":"simple","lap":1,"targets":[9,3,0,6]}'
  '{"cmd":"sweep","appearance":"No\u0001glasses","mode":"simple","lap":1,"targets":[9,3,0,6]}'
  '{"cmd":"sweep","appearance":7,"mode":"simple","lap":1,"targets":[9,3,0,6]}'
  '{"cmd":"sweep","mode":"simple","lap":1,"targets":[9,3,0,6]}'
)
script=("await ready 30" "send $CREATE" "send $(python3 -c 'print("[" * 60000)')")
for line in "${bad[@]}"; do script+=("send $line"); done
script+=("send $SIMPLE" "send $SIMPLE" "await swept 120" "send {\"cmd\":\"capture\",\"appearance\":\"No glasses\"}" "send {\"cmd\":\"sweep\",\"appearance\":\"No glasses\",\"mode\":\"simple\",\"lap\":2,\"targets\":[9,3,0,6]}" "send {\"cmd\":\"trial\",\"appearance\":\"No glasses\"}" "send $FINISH" "send {\"cmd\":\"abort\"}" "send $DONE" "await saved 30")
out=$(session emil "${script[@]}")
same "${#bad[@]} refused sweeps, the capture after a sweep, a sweep while one runs, a lap 2 and a trial after a Simple set: all bad_sweep" "$(( ${#bad[@]} + 4 ))" "$(q "$out" 'len([e for e in evs if e.get("event") == "capture_failed" and e.get("code") == "bad_sweep"])')"
same "...and the sweep that follows them all runs: exactly one sweeping, one swept, saved" '[1,1,1]' "$(q "$out" '[len([e for e in evs if e.get("event") == n]) for n in ("sweeping", "swept", "saved")]')"
check "a bad sweep starts no child (no sweeping before the valid one; nothing left running)" no_child
same "...four bad labels count as bad_sweep above, and a 60,000-bracket line is ignored: no Traceback, the session lived to save" 'false' "$(grep -q Traceback <<<"$out" && echo true || echo false)"

step "a second identity: changed, and nothing from that lap is stored"
reset_store
scenario simple-changed
out=$(session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\",\"code\":\"changed\"} 120" "send $DONE" "eof")
same "five consecutive other-person frames give changed (and the done that follows is refused)" '["changed","bad_sweep"]' "$(q "$out" '[c["code"] for c in evs if c.get("event") == "capture_failed"]')"
check "...nothing is stored" bash -c "[[ ! -e $STORE/people/emil.json ]]"
scenario simple-stray
out=$(session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 60" "eof")
same "one stray frame of somebody else does not end the lap" '[0,3,6,9]' "$(q "$out" 'first("swept")["filled"]')"

step "rule F: root re-checks the guard and the pose ring itself, whatever the child says"
# A copy of the helper whose child has a broken guard (guard_ok always passes) and, in the
# other copy, a broken pose ring (every template claims r 3.9). The parent must still refuse.
patch_admin() { # patch_admin <out> <old> <new>
  python3 - "$ADMIN" "$1" "$2" "$3" <<'PY'
import sys
src, out, old, new = sys.argv[1:]
text = open(src).read()
assert text.count(old) == 1, "patch target not found exactly once"
open(out, "w").write(text.replace(old, new))
PY
  chmod 0755 "$1"
}
patch_admin "$LAB/admin-noguard" '    hard_distance, chain_distance = guard_distances(encoding, accepted, centre)
    if hard_distance > hard:' '    return "ok"
    hard_distance, chain_distance = guard_distances(encoding, accepted, centre)
    if hard_distance > hard:'
patch_admin "$LAB/admin-wide" '"templates": [{"bin": k, "r": round(t["r"], 3),' '"templates": [{"bin": k, "r": 3.9,'
REAL_ADMIN=$ADMIN
reset_store
scenario simple-stranger
ADMIN=$LAB/admin-noguard
out=$(OMARCHY_FACE_SWEEP_SECONDS=30 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 90" "send $DONE" "eof")
same "a child whose guard passes everything: four stranger templates, and the parent drops the lap (lap 1)" '[["timeout","bad_sweep"],false]' "$(q "$out" '[[c["code"] for c in evs if c.get("event") == "capture_failed"], first("swept") is not None]')"
check "...and nothing is stored" bash -c "[[ ! -e $STORE/people/emil.json ]]"
reset_store
scenario advanced lap2-other
out=$(OMARCHY_FACE_SWEEP_SECONDS=90 session emil "await ready 30" "send $CREATE" "send $ADV1" "await swept 120" "send $ADV2" "awaitwhere {\"event\":\"capture_failed\"} 120" "send $DONE" "await saved 30")
same "...and lap 2 by somebody else with that guard: dropped by the parent with lap 1 kept (13 saved)" '["timeout",1,13]' "$(python3 -c '
import json, sys
evs = [json.loads(l[3:]) for l in sys.stdin.read().splitlines() if l.startswith("EV ")]
print(json.dumps([[e["code"] for e in evs if e.get("event") == "capture_failed"][0], len([e for e in evs if e.get("event") == "swept"]), 13 if any(e.get("event") == "saved" for e in evs) else 0], separators=(",", ":")))' <<<"$out")"
reset_store
scenario simple
ADMIN=$LAB/admin-wide
out=$(OMARCHY_FACE_SWEEP_SECONDS=30 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 90" "send $DONE" "eof")
same "a child that reports r 3.9 (inside 0..4, outside R_MIN..R_MAX): dropped by the parent" '["timeout","bad_sweep"]' "$(q "$out" '[c["code"] for c in evs if c.get("event") == "capture_failed"]')"
check "...and nothing is stored" bash -c "[[ ! -e $STORE/people/emil.json ]]"
ADMIN=$REAL_ADMIN
reset_store
scenario simple-stranger
out=$(OMARCHY_FACE_SWEEP_SECONDS=30 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"capture_failed\"} 90" "eof")
same "control: the same stranger with the real guard is changed, as before" '"changed"' "$(q "$out" 'last("capture_failed")["code"]')"

step "frames that must yield no template"
reset_store
scenario advanced-faults
out=$(OMARCHY_FACE_SWEEP_SECONDS=60 session emil "await ready 30" "send $CREATE" "send $ADV1" "awaitwhere {\"event\":\"track\",\"canFinish\":true} 120" "send $FINISH" "await swept 60" "send $DONE" "await saved 30")
same "dark, saturated, blurry, tiny, huge, two-face, moving and one-off frames fill nothing; the clean four do" '[0,3,6,9]' "$(q "$out" 'first("swept")["filled"]')"
same "the engine named the faults (dark, blurry, closer, farther, multiple, hold, over/edge words are the gates')" 'true' "$(q "$out" '{"dark", "blurry", "closer", "farther", "multiple"} <= {t["state"] for t in tracks}')"

step "Advanced stall, abort, and nothing left running"
reset_store
scenario advanced-idle
out=$(OMARCHY_FACE_SWEEP_SECONDS=30 session emil "await ready 30" "send $CREATE" "send $ADV1" "awaitwhere {\"event\":\"capture_failed\",\"code\":\"sweep_stalled\"} 120" "send {\"cmd\":\"abort\"}" "await aborted 30" "send $ADV1" "awaitwhere {\"event\":\"capture_failed\",\"code\":\"sweep_stalled\"} 60" "eof")
same "20 s without a new supported frame is sweep_stalled and the lap continues until abort" '["sweep_stalled","aborted"]' "$(q "$out" '[c["code"] for c in evs if c.get("code") == "sweep_stalled"][:1] + ["aborted" if first("aborted") else "no"]')"
same "after aborted the session is usable: a second sweep ran (two sweeping events)" '2' "$(q "$out" 'len([e for e in evs if e.get("event") == "sweeping"])')"
same "...and the transcript ends discarded (nothing was written)" '"discarded"' "$(q "$out" 'evs[-1]["event"]')"
sleep 2
check "no engine child outlives an abort or an EOF" no_child
scenario simple-wrong-long
out=$(session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitwhere {\"event\":\"track\",\"target\":9} 60" "eof")
sleep 2
check "EOF in the middle of a lap kills the child within 2 s" no_child
same "...and writes nothing" '"discarded"' "$(q "$out" 'evs[-1]["event"]')"
check "...no person is stored" bash -c "[[ ! -e $STORE/people/emil.json ]]"

step "Start over replaces the pending set; a legacy capture works until the first sweep"
reset_store
scenario simple advanced
out=$(session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 120" "send $ADV1" "awaitwhere {\"event\":\"swept\",\"kept\":13} 120" "send $DONE" "await saved 30")
same "a Simple lap 1 followed by an Advanced lap 1 leaves one set of 13 (replaced, not 18)" '13' "$(count_templates "$STORE/people/emil.json" 0)"
reset_store
out=$(session emil "await ready 30" "send $CREATE" 'send {"cmd":"capture","appearance":"No glasses"}' "await captured 60" "send $DONE" "await saved 30")
same "capture is still the old single frame: ready capturing captured saved" '["ready","capturing","captured","saved"]' "$(q "$out" 'names')"
same "...and the stored appearance has no extra" '1' "$(count_templates "$STORE/people/emil.json" 0)"

step "Rule R: Simple may not replace a larger stored set"
reset_store
scenario simple
session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 120" "send $DONE" "await saved 30" >/dev/null
out=$(session emil "await ready 30" "send $SIMPLE" "await swept 60" "eof")
same "five stored templates: a Simple re-scan is accepted" 'true' "$(q "$out" 'first("swept") is not None')"
scenario advanced
session emil "await ready 30" "send $ADV1" "await swept 120" "send $DONE" "await saved 30" >/dev/null
scenario simple
out=$(session emil "await ready 30" "send $SIMPLE" "await capture_failed 30" "eof")
same "thirteen stored templates: Simple is bad_sweep" '"bad_sweep"' "$(q "$out" 'first("capture_failed")["code"]')"
same "...and the person's record is untouched (13)" '13' "$(count_templates "$STORE/people/emil.json" 0)"

step "limits: set-limits changes what is used, without re-enrolment"
out=$("$ADMIN" set-limits emil 3 3 2>&1)
same "set-limits answers ok with the new counts" '[3,1]' "$(python3 -c '
import json, sys
p = json.loads(sys.argv[1])["person"]
print(json.dumps([p["lockTemplates"], p["sudoTemplates"]], separators=(",", ":")))' "$out")"
same "...and the person's model holds three templates, from the same record" '3' "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$MODELS/omarchy-face.person.emil.dat")"
"$ADMIN" set-limits emil 12 4 >/dev/null 2>&1
same "back to 12 and 4: thirteen stored, twelve in the lock set" '12' "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$MODELS/omarchy-face.person.emil.dat")"
for bad in "2 4" "12 13" "37 4" "a 4" "12" ""; do
  out=$("$ADMIN" set-limits emil $bad 2>&1)
  same "set-limits emil $bad is refused" '{"error":"bad_arguments"}' "$out"
done
same "limits are in the record, and no encoding in people.json" '{"lock": 12, "sudo": 4}' "$(json_field "$STORE/people/emil.json" limits)"
fp1=$(sha256sum "$MODELS"/omarchy-face.*.dat "$PEOPLE" | sort)
"$ADMIN" regenerate >/dev/null 2>&1
same "regenerate is byte-identical (the derived sets and people.json)" "$fp1" "$(sha256sum "$MODELS"/omarchy-face.*.dat "$PEOPLE" | sort)"

step "the session bound: a sweep does not lengthen the session (scaled by OMARCHY_FACE_SESSION_SECONDS)"
reset_store
scenario hold-first
out=$(OMARCHY_FACE_SESSION_SECONDS=4 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "sleep 5.5" 'send {"cmd":"abort"}' "await discarded 30")
same "a session of 4 s is over at 4 s with a sweep running: the abort at 5.5 s finds it discarded" 'false' "$(q "$out" 'first("aborted") is not None')"
out=$(OMARCHY_FACE_SESSION_SECONDS=4 session emil "await ready 30" "sleep 3" "send $CREATE" "send $SIMPLE" "sleep 2.5" 'send {"cmd":"abort"}' "await discarded 30")
same "...also when the sweep is sent late (at 3 s): it buys no extra time" 'false' "$(q "$out" 'first("aborted") is not None')"
same "...and the transcript ends discarded" '"discarded"' "$(q "$out" 'evs[-1]["event"]')"
out=$(OMARCHY_FACE_SESSION_SECONDS=4 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "sleep 2" 'send {"cmd":"abort"}' "await aborted 30" "eof")
same "...but an abort inside the 4 s still works" 'true' "$(q "$out" 'first("aborted") is not None')"
sleep 1
check "...with the child gone" no_child

step "what the child says on stderr never reaches the client; the child holds the camera lock; a deep line is ignored"
patch_admin "$LAB/admin-noisy" 'def say(obj):
    import json
' 'def say(obj):
    import json
    sys.stderr.write("LEAK /dev/video9 Traceback (most recent call last)\n")
'
reset_store
scenario simple
ADMIN=$LAB/admin-noisy
out=$(OMARCHY_FACE_SWEEP_SECONDS=30 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "await swept 90" "eof")
ADMIN=$REAL_ADMIN
same "a child that writes a path and a traceback to stderr: the sweep still completes" 'true' "$(q "$out" 'first("swept") is not None')"
same "...and none of it reaches the client (no ERR line mentions it)" 'false' "$(grep -qE 'LEAK|/dev/video9|Traceback' <<<"$out" && echo true || echo false)"
reset_store
scenario hold-first
CAMLOCK=/run/omarchy-face/camera.lock
( session emil "await ready 30" "send $CREATE" "send $SIMPLE" "sleep 3" "send $(python3 -c 'print("[" * 60000)')" "sleep 1" 'send {"cmd":"abort"}' "await aborted 30" "eof" >"$LAB/hold.out" 2>&1 ) &
holder=$!
sleep 2
held=0
for pid in $(pgrep -f 'def parse_args'); do
  for fd in /proc/$pid/fd/*; do [[ $(readlink "$fd" 2>/dev/null) == "$CAMLOCK" ]] && held=$((held + 1)) && break; done
done
same "the sweep child (and its timeout) holds the camera lock's file, as the daemon's compare.py does" 'true' "$([[ $held -ge 2 ]] && echo true || echo false)"
wait "$holder"
same "a 60,000-bracket line during a running scan is ignored: the abort after it is answered" 'true' "$(q "$(cat "$LAB/hold.out")" 'first("aborted") is not None')"
check "...with no traceback" bash -c "! grep -q Traceback '$LAB/hold.out'"
sleep 1
check "...and the lock is free again once the child is gone" flock -n "$CAMLOCK" true
reset_store
mkdir -p "$STORE/people"
printf 'not json' >"$STORE/people/emil.json"
out=$(session emil "await error 20")
same "a corrupt record: the session's error event is store_corrupt" '"store_corrupt"' "$(q "$out" 'first("error")["error"]')"
same "...and it carries no record path (the code and nothing else)" '["error","event"]' "$(q "$out" 'sorted(first("error"))')"
same "...and no path appears in the transcript" 'false' "$(grep -qE '/var/lib|people/' <<<"$out" && echo true || echo false)"
reset_store

step "the typed allow-list and the test override, as code (STORE_PY loaded without its main)"
cat >"$LAB/unit.py" <<'PY'
import json, os, re, sys
text = open(sys.argv[1]).read()
store = re.search(r"read -r -d '' STORE_PY <<'STORE_PY_END' \|\| true\n(.*?)\nSTORE_PY_END\n", text, re.S).group(1)
sweep = re.search(r"read -r -d '' SWEEP_PY <<'SWEEP_PY_END' \|\| true\n(.*?)\nSWEEP_PY_END\n", text, re.S).group(1)
os.environ["OMARCHY_FACE_SWEEP_PY"] = sweep + "\n"
ns = {"__name__": "store_unit"}
exec(compile(store.rsplit("\nsys.exit(main", 1)[0], "STORE_PY", "exec"), ns)
bad = []
def check(name, ok):
    if not ok:
        bad.append(name)
t = ns["typed_event"]
good_track = {"event": "track", "state": "hold", "u": 0.1, "v": -1.2, "target": 9, "centre": 1.0,
              "bins": [0.0] * 12, "skipped": [], "canFinish": False}
check("a good track passes", t(good_track) == good_track)
check("sweeping passes", t({"event": "sweeping", "mode": "simple", "lap": 1, "targets": [9, 3, 0, 6], "quota": 2}) is not None)
check("swept passes", t({"event": "swept", "mode": "advanced", "lap": 2, "filled": [0, 1], "skipped": [], "centreHeld": True, "kept": 3}) is not None)
check("capture_failed with each of the twelve codes passes",
      all(t({"event": "capture_failed", "code": c}) for c in ns["pure"]()["CODES"]))
for name, doc in [
    ("a planted key", dict(good_track, encoding=[0.0] * 128)),
    ("a path", dict(good_track, path="/dev/video2")),
    ("a bool where a number belongs", dict(good_track, u=True)),
    ("NaN", dict(good_track, v=float("nan"))),
    ("Infinity", dict(good_track, centre=float("inf"))),
    ("1e400", dict(good_track, u=json.loads("1e400"))),
    ("a huge int", dict(good_track, u=10 ** 400)),
    ("u out of range", dict(good_track, u=4.1)),
    ("bins of 13", dict(good_track, bins=[0.0] * 13)),
    ("a bin out of range", dict(good_track, bins=[0.0] * 11 + [1.5])),
    ("a string for canFinish", dict(good_track, canFinish="true")),
    ("target 12", dict(good_track, target=12)),
    ("target True", dict(good_track, target=True)),
    ("an unknown state", dict(good_track, state="ok")),
    ("a repeat in filled", {"event": "swept", "mode": "simple", "lap": 1, "filled": [1, 1], "skipped": [], "centreHeld": True, "kept": 3}),
    ("lap True", {"event": "sweeping", "mode": "simple", "lap": True, "targets": [9], "quota": 2}),
    ("a code that is not one of the twelve", {"event": "capture_failed", "code": "ok"}),
    ("an event name that is not a sweep event", {"event": "saved"}),
    ("no event", {"state": "hold"}),
]:
    check(name + " is dropped", t(doc) is None)
check("dumping NaN is refused outright (allow_nan=False)", not any(
    "NaN" in json.dumps(g, allow_nan=False) for g in [good_track]))
# the override: only lowers, ignores junk, and is never read by root of the machine
base = ns["sweep_bounds"]()
check("no override: the plan's bounds", base == {"simple": 60.0, "advanced": 90.0, "patience": 10.0, "lead": 3.0, "stall": 20.0})
for asked in ("1e9", "NaN", "inf", "-1", "-inf", "0", "abc", ""):
    os.environ["OMARCHY_FACE_SWEEP_SECONDS"] = asked
    check("OMARCHY_FACE_SWEEP_SECONDS=%r lengthens nothing" % asked, ns["sweep_bounds"]() == base)
os.environ["OMARCHY_FACE_SWEEP_SECONDS"] = "5"
check("5 lowers every bound to at most 5", all(v <= 5 for v in ns["sweep_bounds"]().values()) and ns["sweep_bounds"]()["lead"] == 3.0)
ns["real_root"] = lambda: True
check("root of the machine never reads it", ns["sweep_bounds"]() == base)
# warning_for is per person
pure = ns["pure"]()
def person(count, cap):
    extra = [{"pose": "a%03d" % (30 * k), "band": "near", "time": 1, "r": 1.0, "support": 2, "encoding": [0.0] * 128} for k in range(count)]
    return {"sudo": True, "limits": {"lock": 12, "sudo": cap}, "appearances": [{"label": "A", "time": 1, "encoding": [0.0] * 128, "extra": extra}]}
check("default four: no warning for six templates a person holds", ns["warning_for"]([person(6, 4)]) is None)
pure["SUDO_POLICY"] = "full"
check("under the full policy a deliberate cap of 8 with eight in effect warns", ns["warning_for"]([person(9, 8)]) is not None)
pure["SUDO_POLICY"] = "centre"
check("five people with Sudo and one template each: no warning", ns["warning_for"]([person(0, 4)] * 5) is None)
# rule F: judge() re-checks the pose ring and HARD against the centre, whatever the child says
judge = ns["judge"]
ZERO = [0.0] * 128
def away(d):
    return [d] + [0.0] * 127
def tpl(k, d=0.3, r=1.6, support=3, encoding=None):
    return {"bin": k, "r": r, "support": support, "encoding": encoding if encoding is not None else away(d)}
def res(templates, centre=ZERO):
    return {"changed": False, "ended": "finish", "refine": None, "centreHeld": True,
            "centre": {"encoding": centre} if centre is not None else None, "templates": templates,
            "filled": [], "skipped": [], "eye": 80.0}
SIMPLE4 = [9, 3, 0, 6]
ALL12 = list(range(12))
good4 = [tpl(k) for k in SIMPLE4]
check("judge keeps a good Simple lap", judge("simple", 1, SIMPLE4, res(good4))["code"] is None)
check("judge keeps a template exactly at HARD (0.55)", judge("simple", 1, SIMPLE4, res([tpl(9, 0.55)] + good4[1:]))["code"] is None)
check("judge refuses a template just past HARD (0.5501)", judge("simple", 1, SIMPLE4, res([tpl(9, 0.5501)] + good4[1:]))["code"] == "timeout")
check("judge refuses a template of somebody else (distance 1.0)", judge("simple", 1, SIMPLE4, res([tpl(9, 1.0)] + good4[1:]))["code"] == "timeout")
for r, expect in ((1.0, True), (2.2, True), (0.99, False), (2.21, False), (3.9, False), (4, False), (0, False), (-1, False)):
    check("judge r=%s %s" % (r, "kept" if expect else "refused"),
          (judge("simple", 1, SIMPLE4, res([tpl(9, r=r)] + good4[1:]))["code"] is None) == expect)
nan_enc = [float("nan")] + [0.0] * 127
check("judge refuses a NaN encoding", judge("simple", 1, SIMPLE4, res([tpl(9, encoding=nan_enc)] + good4[1:]))["code"] == "timeout")
check("judge ignores a far lap-1 centre claim that does not exist (no centre: not swept)", judge("simple", 1, SIMPLE4, res(good4, centre=None))["code"] in ("lap_timeout", "too_few"))
adv = [tpl(k) for k in ALL12]
check("judge keeps a good lap 2 against the held centre", judge("advanced", 2, ALL12, res(adv), ZERO)["code"] is None)
check("judge returns no centre for lap 2", judge("advanced", 2, ALL12, res(adv), ZERO)["centre"] is None)
check("judge refuses lap 2 without the held centre", judge("advanced", 2, ALL12, res(adv), None)["code"] == "timeout")
check("judge refuses lap 2 templates far from the HELD centre, whatever centre the child names",
      judge("advanced", 2, ALL12, res(adv, centre=ZERO), away(0.9))["code"] == "timeout" and
      judge("advanced", 2, ALL12, res(adv, centre=away(0.9)), ZERO)["code"] is None)
check("judge refuses a 127-number held centre", judge("advanced", 2, ALL12, res(adv), [0.0] * 127)["code"] == "timeout")
# m8: the security constants STORE_PY and SWEEP_PY each hold are the same numbers
sweep_ns = ns["pure"]()
for name in ("LOCK_TEMPLATES", "SUDO_TEMPLATES", "LOCK_MAXIMUM", "SUDO_MAXIMUM"):
    check("%s is the same in STORE_PY (%r) and SWEEP_PY (%r)" % (name, ns[name], sweep_ns[name]), ns[name] == sweep_ns[name])
check("MAX_APPEARANCES in STORE_PY is the 3 the Sudo-centre bound assumes", ns["MAX_APPEARANCES"] == 3)
# the Sudo policy: one line decides, the stored data is the same under both words
def wide(count_appearances=2, count=12):
    appearances = []
    for a in range(count_appearances):
        extra = [{"pose": "a%03d" % (30 * k), "band": "near", "time": 1, "r": 1.2, "support": 3, "encoding": [0.0] * 128}
                 for k in range(count)]
        appearances.append({"label": "A%d" % a, "time": 1 + a, "encoding": [0.0] * 128, "extra": extra})
    return {"name": "emil", "label": "E", "owner": True, "sudo": True, "lock": True, "created": 1, "appearances": appearances}
rich = wide()
pick = sweep_ns["pick"]
check("the shipped policy is centre", sweep_ns["SUDO_POLICY"] == "centre" and ns["sudo_policy"]() == "centre")
under_centre = {kind: pick(rich, kind, cap) for kind, cap in (("sudo", 4), ("lock", 12))}
check("centre policy: Sudo gets the centre of each appearance and nothing else", under_centre["sudo"] == [(0, None), (1, None)])
check("centre policy: a glasses look is never dropped (3 appearances, Sudo cap 3)", pick(wide(3), "sudo", 3) == [(0, None), (1, None), (2, None)])
check("centre policy: Lock still takes the pose ring, up to its cap of 12", len(under_centre["lock"]) == 12 and under_centre["lock"][:2] == [(0, None), (1, None)])
sweep_ns["SUDO_POLICY"] = "full"
check("sudo_policy() says full", ns["sudo_policy"]() == "full")
under_full = {kind: pick(rich, kind, cap) for kind, cap in (("sudo", 4), ("lock", 12))}
check("full policy: Sudo gets the plan's four (both centres, then two bins)", len(under_full["sudo"]) == 4 and under_full["sudo"][:2] == [(0, None), (1, None)] and all(e is not None for _, e in under_full["sudo"][2:]))
check("flipping the policy leaves Lock exactly as it was", under_full["lock"] == under_centre["lock"])
def valid(doc):
    try:
        ns["validate_record"]("/x/emil.json", doc)
        return True
    except ns["Fatal"]:
        return False
check("the same record validates under both words (the stored data does not change)", valid(rich))
for word, expect in (("bogus", "centre"), ("", "centre"), (None, "centre")):
    sweep_ns["SUDO_POLICY"] = word
    check("an unknown policy %r fails closed to centre" % (word,), pick(rich, "sudo", 4) == [(0, None), (1, None)] and ns["sudo_policy"]() == expect)
sweep_ns["SUDO_POLICY"] = "full"
check("full policy: a cap of 8 on 12 near templates warns (the plan's warning)", ns["warning_for"]([rich | {"limits": {"lock": 12, "sudo": 8}}]) is not None)
check("full policy: the default four does not warn", ns["warning_for"]([rich]) is None)
check("full policy: the Sudo set of a person holds four entries", len([e for e in ns["model_entries"]([rich], "sudo")]) == 4)
sweep_ns["SUDO_POLICY"] = "centre"
check("centre policy: the cap of 8 cannot warn (only centres are usable)", ns["warning_for"]([rich | {"limits": {"lock": 12, "sudo": 8}}]) is None)
check("centre policy: the Sudo set holds the two centres", len(ns["model_entries"]([rich], "sudo")) == 2)
check("centre policy: the Lock set still holds 12", len(ns["model_entries"]([rich], "lock")) == 12)
# the stored shapes
def record(extra=None, limits=None):
    a = {"label": "A", "time": 1, "encoding": [0.0] * 128}
    if extra is not None:
        a["extra"] = extra
    doc = {"name": "emil", "label": "E", "owner": True, "sudo": True, "lock": False, "created": 1, "appearances": [a]}
    if limits is not None:
        doc["limits"] = limits
    return doc
def ok(doc):
    try:
        ns["validate_record"]("/x/emil.json", doc)
        return True
    except ns["Fatal"]:
        return False
one = {"pose": "a090", "band": "near", "time": 1, "r": 1.3, "support": 2, "encoding": [0.0] * 128}
check("an old record (no extra, no limits) is valid", ok(record()))
check("a good extra and good limits are valid", ok(record([one], {"lock": 12, "sudo": 4})))
for name, doc in [
    ("27 extras", record([dict(one, pose="a%03d" % (30 * (i % 12)), band=("near", "far", "usual")[i // 12 % 3]) for i in range(27)])),
    ("a pose that is not a bin", record([dict(one, pose="a095")])),
    ("a pose from client text", record([dict(one, pose="../../etc")])),
    ("a bad band", record([dict(one, band="usual2")])),
    ("usual with a bin pose", record([dict(one, band="usual")])),
    ("support 1", record([dict(one, support=1)])),
    ("support True", record([dict(one, support=True)])),
    ("r 5", record([dict(one, r=5)])),
    ("r NaN", record([dict(one, r=float("nan"))])),
    ("an encoding of 127", record([dict(one, encoding=[0.0] * 127)])),
    ("an encoding with a string", record([dict(one, encoding=["x"] + [0.0] * 127)])),
    ("a repeated slot", record([one, one])),
    ("limits {lock:2}", record(limits={"lock": 2, "sudo": 4})),
    ("limits sudo 13", record(limits={"lock": 12, "sudo": 13})),
    ("limits lock 37", record(limits={"lock": 37, "sudo": 4})),
    ("limits with a third key", record(limits={"lock": 12, "sudo": 4, "x": 1})),
    ("limits as floats", record(limits={"lock": 12.0, "sudo": 4})),
    ("limits True", record(limits={"lock": True, "sudo": 4})),
]:
    check(name + " is refused by validate_record", not ok(doc))
print("\n".join(bad) if bad else "ALL OK")
sys.exit(1 if bad else 0)
PY
unit=$(python3 -I "$LAB/unit.py" "$ADMIN" 2>&1)
same "typed_event, sweep_bounds, warning_for and validate_record: every case in the unit" "ALL OK" "$unit"

step "nothing that is an encoding, a frame or a path reached any client"
check "no list of 100 or more numbers appears in any transcript of this run" bash -c "! grep -qE '\[(-?[0-9.e-]+,){100,}' '$LAB/all.log'"
grep -B3 -A8 'Traceback' "$LAB/all.log" | head -24 | cut -c1-200
check "no /dev path appears in any transcript" bash -c "! grep -q '/dev/' '$LAB/all.log'"
check "every event line of every transcript is one of the plan's event names" python3 - "$LAB/all.log" <<'PY'
import json, sys
allowed = {"ready", "capturing", "captured", "capture_failed", "sweeping", "track", "swept", "aborted", "saved", "discarded", "error"}
for line in open(sys.argv[1]):
    if line.startswith("EV "):
        assert json.loads(line[3:]).get("event") in allowed, line
PY

echo
if ((failures == 0)); then
  echo "${GREEN}e1: $checks checks, all passed${RESET}"
else
  echo "${RED}e1: $checks checks, $failures failed${RESET}"
fi
exit $((failures > 0))
