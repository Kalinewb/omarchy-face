#!/bin/bash

# E1's gate: the dot scan through the REAL parent (`enroll-session`), with a fake
# camera and a fake dlib (plan-face-enroll.md section 7, item 2). 3.3.0 removed the Advanced scan
# and with it this suite's sweep half; what is left is the dot scan, the legacy capture, and
# what a stored Advanced appearance still has to do.
#
#   ./dev/e1-enrol-sweep.sh
#
# In the same private user namespace the other suites use (tmpfs over /etc, /run,
# /var/lib and /usr/lib/security, a uid 0 that owns nothing), howdy's directory gets a
# stub recorders/video_capture.py that plays a SCRIPTED press (dev/e1-frames.py: 400x400
# numpy images, the landmarks, the face box and whose face it is) and a fake `dlib` is
# bind-mounted over site-packages, as f3 --real does for the real one. cv2 and numpy are
# the real ones, so the engine's own gates (darkness, saturation, sharpness, CLAHE) run on
# real pixels. The camera also keeps a VIRTUAL clock (it patches time.monotonic in the
# child, one 1/15 s step per frame), so a press takes a second or two and its ceiling is exact. Nothing but the sandbox is written: no person
# is recorded on this machine, the camera is never opened, nothing is installed.
#
# What this cannot say: that real dlib behaves like the fake. The protocol, the rules (F,
# table V), the allow-list and the bounds are the real code.

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

echo "E1 — the dot scan (plan-face-enroll.md section 7, item 2)"
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

CREATE='{"cmd":"create","label":"Emil"}'
DONE='{"cmd":"done"}'
no_child() { ! pgrep -f 'python3 -I -c' >/dev/null; }
CAMLOCK=/run/omarchy-face/camera.lock
dotcmd() { echo '{"cmd":"dot","appearance":"No glasses","pose":"'$1'"}'; }
DOTC=$(dotcmd centre); DOTL=$(dotcmd left); DOTT=$(dotcmd top); DOTR=$(dotcmd right); DOTB=$(dotcmd bottom)

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
reset_store() { rm -rf "$STORE"/people "$STORE"/people.json "$MODELS"/omarchy-face.*.dat; }

# E1_SHELL='command' runs one command in the sandbox with the helpers above, for debugging.
if [[ -n ${E1_SHELL:-} ]]; then eval "$E1_SHELL"; exit; fi

# =============================================================================

step "ready names the verbs and the limits"
reset_store
scenario dot-centre
out=$(session emil "await ready 30" "eof")
same "ready lists the verbs that exist: the single capture and the dot scan (3.3.0: no sweep, which is how a 3.2.x card knows to fall back)" '["capture","dot"]' "$(q "$out" 'first("ready")["verbs"]')"
same "ready carries the default limits" '{"lock":12,"sudo":4}' "$(q "$out" 'first("ready")["limits"]')"
same "ready says which stored templates Sudo may use (the policy, a plain word)" '"centre"' "$(q "$out" 'first("ready")["sudoPolicy"]')"

step "the dot scan (3.2.0): centre, left, top, right, bottom, one press each"
reset_store
scenario dot-centre dot-left dot-top dot-right dot-bottom
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "awaitwhere {\"event\":\"dotted\",\"pose\":\"centre\"} 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTT" "awaitwhere {\"event\":\"dotted\",\"pose\":\"top\"} 60" "send $DOTR" "awaitwhere {\"event\":\"dotted\",\"pose\":\"right\"} 60" "send $DOTB" "awaitwhere {\"event\":\"dotted\",\"pose\":\"bottom\"} 60" "send $DONE" "await saved 30")
echo "${DIM}$(grep -v '"event":"dot"' <<<"$out" | head -6 | cut -c1-200)${RESET}"
same "each press is announced (dotting, with the frames it needs), then closes with dotted: the poses come in the order they were pressed" '["centre","left","top","right","bottom"]' "$(q "$out" '[e["pose"] for e in evs if e.get("event") == "dotted"]')"
same "dotting carries the pose and the need (3), and nothing else" '[["event","need","pose"],[3]]' "$(q "$out" '[sorted({tuple(sorted(e)) for e in evs if e.get("event") == "dotting"})[0], sorted({e["need"] for e in evs if e.get("event") == "dotting"})]')"
same "the last dotted lists all five poses and five templates kept" '[["centre","left","top","right","bottom"],5]' "$(q "$out" '[evs[[i for i, e in enumerate(evs) if e.get("event") == "dotted"][-1]]["poses"], [e for e in evs if e.get("event") == "dotted"][-1]["kept"]]')"
same "the ring closes only when the frames are there: in every press the count the child reports rises to the need (3) and the closing dotted comes after it, never before" 'true' "$(q "$out" '(lambda groups: len(groups) == 5 and all(g and g[-1] == 3 and g == sorted(g) and max(g) <= 3 for g in groups))([[e["good"] for e in evs[a:b] if e.get("event") == "dot"] for a, b in zip([i for i, e in enumerate(evs) if e.get("event") == "dotting"], [i for i, e in enumerate(evs) if e.get("event") == "dotted"])])')"
same "the stored appearance is the centre plus a270 a000 a090 a180 (left, top, right, bottom), all near" '["a270","a000","a090","a180"]' "$(python3 -c '
import json,sys
print(json.dumps([e["pose"] for e in json.load(open(sys.argv[1]))["appearances"][0]["extra"]], separators=(",", ":")))' "$STORE/people/emil.json")"
same "...each with r 1.6 (nominal: no pose is measured, and past the Sudo band), support 3 or more, 128 numbers" 'true' "$(python3 -c '
import json,sys
a = json.load(open(sys.argv[1]))["appearances"][0]
print(json.dumps(all(e["band"] == "near" and e["r"] == 1.6 and e["support"] >= 3 and len(e["encoding"]) == 128 for e in a["extra"])))' "$STORE/people/emil.json")"
same "people.json counts five templates; Sudo uses one (the centre, SUDO_POLICY stays centre), Lock all five" '[5,1,5,"centre"]' "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
p = d["people"][0]
print(json.dumps([p["appearances"][0]["templates"], p["sudoTemplates"], p["lockTemplates"], d["sudoPolicy"]], separators=(",", ":")))' "$PEOPLE")"
check "people.json carries no encoding" bash -c "! grep -q encoding $PEOPLE"
same "...every stored descriptor is the owner's" 'true' "$(stored_all_owner 5)"
check "no engine child is left behind" no_child

step "dot scan: a press that fails says why, the ball stays, and the same press can be made again"
retry() { # retry <description> <the failing scenario> <the code it must fail with> [the pose, default centre]
  local pose=${4:-centre} first=""
  reset_store
  if [[ $pose == centre ]]; then
    scenario "$2" dot-centre
    out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "awaitwhere {\"event\":\"capture_failed\"} 60" "send $DOTC" "await dotted 60" "eof")
  else
    scenario dot-centre "$2" dot-left
    out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"capture_failed\"} 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "eof")
  fi
  same "$1: the press fails with $3, nothing else fails, and the next press succeeds" "[[\"$3\"],true]" "$(q "$out" '[[e["code"] for e in evs if e.get("event") == "capture_failed"], any(e.get("event") == "dotted" and e["pose"] == "'$pose'" for e in evs)]')"
  same "...and a failed press closed no ring: no dotted came before the retry" '1' "$(q "$out" 'len([e for e in evs if e.get("event") == "dotted" and e["pose"] == "'$pose'"])')"
  check "...nothing was written (the session ended with the cancel)" bash -c "[[ ! -e $STORE/people/emil.json ]]"
}
retry "nobody in view" dot-none no_face
retry "a room too dark (every frame lit, but dim)" dot-dim too_dark
retry "a covered camera (nothing lit for over two seconds)" unlit-room black_frames
retry "two faces" dot-two-faces multiple_faces
retry "the centre with the face too small" dot-centre-far too_far
reset_store
scenario dot-centre-seat
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "eof")
same "the user's seat (eyes 37.8 px: too small for the old limit of 40, fine for 36): the centre is taken at the first press, nothing failed" '[1,0]' "$(q "$out" '[len([e for e in evs if e.get("event") == "dotted"]), len([e for e in evs if e.get("event") == "capture_failed"])]')"
reset_store
scenario dot-centre-far dot-centre-just-small
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "awaitwhere {\"event\":\"capture_failed\"} 60" "send $DOTC" "sleep 1.5" "eof")
same "a centre too small says how much bigger it must look: eyes 31.5 px need 14%, 34.7 px need 4% (the event carries 'short', an int, and only for too_far)" '[["too_far",14],["too_far",4]]' "$(q "$out" '[[e["code"], e.get("short")] for e in evs if e.get("event") == "capture_failed"]')"
retry "the centre with the face too big" dot-centre-close too_close
retry "the centre with the head tilted past ROLL_MAX (30 degrees; 3.2.0 as first built did not judge it)" dot-centre-roll face_tilted
retry "nobody in view at the left press" dot-none no_face left
retry "two faces at the left press" dot-two-faces multiple_faces left
retry "a dark room at the left press" dot-dim too_dark left
reset_store
scenario dot-two-good dot-late
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "awaitwhere {\"event\":\"capture_failed\"} 60" "send $DOTC" "await dotted 60" "eof")
same "two good frames and then nobody do not close the ring: no_face, and the count never passed 2" '["no_face",2]' "$(q "$out" '[[e["code"] for e in evs if e.get("event") == "capture_failed"][0], max(e["good"] for e in evs[:[i for i, e in enumerate(evs) if e.get("event") == "capture_failed"][0]] if e.get("event") == "dot")]')"
same "...while a face that arrives after a second of nobody is still taken (dot-late): the count reached 3 and then dotted" '[3,"dotted"]' "$(q "$out" '[max(e["good"] for e in evs if e.get("event") == "dot"), [e for e in evs if e.get("event") in ("dotted", "capture_failed")][-1]["event"]]')"
reset_store
scenario dot-centre dot-left-small
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "eof")
same "a turned head is a smaller face (eyes 35 px, under the centre's 40): the size gate is the centre's alone, so left is taken" '2' "$(q "$out" 'len([e for e in evs if e.get("event") == "dotted"])')"

step "dot scan: the strobing emitter. Unlit frames are 99.8% dark and are not evidence about anything"
reset_store
scenario dot-strobe-centre dot-strobe-left
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "eof")
same "centre and left on a strobing camera (half the frames unlit): both taken, and nothing failed, not even once with a dark word" '[2,0]' "$(q "$out" '[len([e for e in evs if e.get("event") == "dotted"]), len([e for e in evs if e.get("event") == "capture_failed"])]')"
reset_store
scenario dot-strobe-dim dot-centre
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "a strobe whose lit frames are too dark is too_dark (the lit ones decide), not black_frames" '"too_dark"' "$(q "$out" 'last("capture_failed")["code"]')"

step "dot scan: a wrong press must not add somebody else"
reset_store
scenario dot-centre dot-stranger-left dot-left dot-right
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"capture_failed\"} 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTR" "awaitwhere {\"event\":\"dotted\",\"pose\":\"right\"} 60" "send $DONE" "await saved 30")
same "somebody else at the left press (a descriptor 1.0 from the centre): not_you, the ball stays; the owner's next left press is kept" '["not_you",["centre","left","right"]]' "$(q "$out" '[[e["code"] for e in evs if e.get("event") == "capture_failed"][0], [e for e in evs if e.get("event") == "dotted"][-1]["poses"]]')"
same "...and every stored descriptor is the owner's (the stranger's frames never reached a template)" 'true' "$(stored_all_owner 3)"
for sc in dot-stranger-near-left dot-owner-far-left; do
  reset_store
  scenario dot-centre $sc dot-left
  out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
  same "$sc: a descriptor 0.46 from the centre (over CHAIN, under HARD) is not_you: the cost of the chain, as in 3.1.x, and the owner who turns that far is asked again" '"not_you"' "$(q "$out" 'last("capture_failed")["code"]')"
done
reset_store
scenario dot-centre dot-stranger-limit-left
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "eof")
same "the documented limit: somebody 0.30 from the owner (inside CHAIN of the centre) is taken at the left press, as 3.1.x took him in a lap" '"left"' "$(q "$out" 'last("dotted")["pose"]')"

step "dot scan: a lookalike who straddles CHAIN (SR1 F1). A press closes on three frames IN A ROW that passed the guard, and five in a row that failed it end it as not_you"
straddle_stored() { # straddle_stored <gap> <wobble> <presses>: how many of that many fresh left presses stored a template
  local n=0 seed
  for seed in $(seq 1 "$3"); do
    reset_store
    scenario dot-centre "dot-straddle:$1:$2:$seed"
    out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "sleep 1.0" "eof")
    grep -q '"event":"dotted","pose":"left"' <<<"$out" && n=$((n + 1))
  done
  echo "$n"
}
got=$(straddle_stored 0.46 0.08 40)
check "somebody 0.46 from the centre with per-frame wobble of 0.08 (one frame in eight inside CHAIN): $got of 40 left presses stored (3.2.0 as first built: most; 3.1.7's lap: about 0 in 10); at most 2 allowed" test "$got" -le 2
got=$(straddle_stored 0.50 0.04 40)
check "...and at 0.50 +-0.04: $got of 40 stored; at most 2 allowed" test "$got" -le 2
got=$(straddle_stored 0.30 0.04 40)
same "the owner's proxy at 0.30 +-0.04 from the centre: every one of 40 presses stores" '40' "$got"
got=$(straddle_stored 0.34 0.04 40)
same "...and at 0.34 +-0.04: every one of 40 stores" '40' "$got"

step "dot scan: the cap on presses that end not_you (a stranger trying presses, or an owner who cannot be matched)"
reset_store
scenario dot-centre dot-stranger-left dot-stranger-left dot-stranger-left dot-stranger-left dot-stranger-left dot-left
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"capture_failed\"} 60" "send $DOTL" "sleep 1.2" "send $DOTL" "sleep 1.2" "send $DOTL" "sleep 1.2" "send $DOTL" "sleep 1.5" "send $DOTL" "sleep 1.5" "eof")
same "five presses that end not_you: five capture_failed not_you, then the session closes (discarded) and the sixth press is never run" '[5,"discarded",0]' "$(q "$out" '[len([e for e in evs if e.get("event") == "capture_failed" and e.get("code") == "not_you"]), evs[-1]["event"], len([e for e in evs if e.get("event") == "dotted" and e["pose"] == "left"])]')"
check "...nothing was written" bash -c "[[ ! -e $STORE/people/emil.json ]]"
check "...and no child is left" no_child
reset_store
scenario dot-centre dot-stranger-left dot-stranger-left dot-stranger-left dot-stranger-left dot-left
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "sleep 1.2" "send $DOTL" "sleep 1.2" "send $DOTL" "sleep 1.2" "send $DOTL" "sleep 1.2" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "eof")
same "four that end not_you and then the owner: below the cap, the fifth press stores" '[4,true]' "$(q "$out" '[len([e for e in evs if e.get("event") == "capture_failed" and e.get("code") == "not_you"]), any(e.get("event") == "dotted" and e["pose"] == "left" for e in evs)]')"

step "dot scan: a pose needs a centre that a dot press took; a failed centre retake does not strand another label's save"
reset_store
scenario dot-left
out=$(session emil "await ready 30" "send $CREATE" 'send {"cmd":"capture","appearance":"No glasses"}' "await captured 60" "send $DOTL" "await capture_failed 30" "send $DONE" "await saved 30")
same "a pose pressed against a legacy capture's centre is bad_sweep with no child (it would never be saveable), and the capture still saves" '["bad_sweep",0,true]' "$(q "$out" '[first("capture_failed")["code"], len([e for e in evs if e.get("event") == "dotting"]), first("saved") is not None]')"
reset_store
scenario dot-centre dot-left dot-right dot-none
EVERY='{"cmd":"dot","appearance":"Everyday glasses","pose":"centre"}'
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTR" "awaitwhere {\"event\":\"dotted\",\"pose\":\"right\"} 60" "send $EVERY" "await capture_failed 60" "send $DONE" "await saved 30")
same "label A held the floor; a centre press for label B fails; done still saves A (it was refused in 3.2.0 as first built: the state went to ready)" '["no_face",true]' "$(q "$out" '[first("capture_failed")["code"], any(e.get("event") == "saved" for e in evs)]')"
same "...and A's three templates are what was stored" '3' "$(python3 -c '
import json, sys
a = json.load(open(sys.argv[1]))["appearances"]
print(sum(1 + len(x.get("extra") or []) for x in a))' "$STORE/people/emil.json")"

step "dot scan, the TOP pose only (3.2.2): the guard's two bounds are DOT_TOP_CHAIN 0.56 and DOT_TOP_HARD 0.60 for it, the 3.1.x 0.40 and 0.55 for every other pose"
top_stored() { # top_stored <gap> <wobble> <presses> [model] [pose]: how many fresh presses of POSE (default top) stored, with left held first
  local n=0 seed pose=${5:-top}
  for seed in $(seq 1 "$3"); do
    reset_store
    if [[ $pose == top ]]; then
      scenario dot-centre dot-left "dot-straddle:$1:$2:$seed:${4:-uni}:$pose"
      out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTT" "sleep 1.0" "eof")
    else
      scenario dot-centre "dot-straddle:$1:$2:$seed:${4:-uni}:$pose"
      out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $(dotcmd "$pose")" "sleep 1.0" "eof")
    fi
    grep -q "\"event\":\"dotted\",\"pose\":\"$pose\"" <<<"$out" && n=$((n + 1))
  done
  echo "$n"
}
got=$(top_stored 0.52 0.02 20)
same "the owner's up pose at 0.52 +-0.02 from the centre (the live presses read 0.46-0.60; 3.2.1 refused them): every one of 20 top presses stores" '20' "$got"
got=$(top_stored 0.54 0.02 20)
same "...at 0.54 +-0.02 (every frame 0.52-0.56, inside DOT_TOP_CHAIN): 20 of 20" '20' "$got"
got=$(top_stored 0.56 0.02 20)
check "...at 0.56 +-0.02 (frames 0.54-0.58, the upper ones over CHAIN 0.56, so some presses fail): $got of 20 stored (18 when measured; at least 14 required)" test "$got" -ge 14
got=$(top_stored 0.58 0.02 20)
check "...at 0.58 +-0.02 (every frame 0.56-0.60, at or over CHAIN): $got of 20 stored (0 when measured; at most 2 allowed): what the old trace's 0.60 press would still be refused by" test "$got" -le 2
got=$(top_stored 0.64 0.02 20)
same "somebody at 0.64 +-0.02 (every frame over DOT_TOP_HARD 0.60): 0 of 20 stored" '0' "$got"
got=$(top_stored 0.66 0.04 20 gauss)
check "...at 0.66, Gaussian wobble 0.04: $got of 20 stored (at most 2 allowed)" test "$got" -le 2
for pose in left right bottom; do
  got=$(top_stored 0.54 0.02 10 uni "$pose")
  same "the $pose pose keeps its 3.1.x limits: the same 0.54 +-0.02 that the top pose takes (20 of 20) is refused, 0 of 10" '0' "$got"
  got=$(top_stored 0.38 0.02 10 uni "$pose")
  same "...and 0.38 +-0.02 still stores at $pose (inside CHAIN 0.40): 10 of 10" '10' "$got"
done
step "dot scan: a stranger admitted at the TOP cannot chain on into right and bottom (3.2.2 re-read F1)"
reset_store
scenario dot-centre dot-left "dot-straddle:0.52:0.02:1:uni:top" dot-chain-right dot-chain-bottom
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTT" "awaitwhere {\"event\":\"dotted\",\"pose\":\"top\"} 60" "send $DOTR" "awaitwhere {\"event\":\"capture_failed\"} 60" "send $DOTB" "sleep 1.5" "send $DONE" "sleep 1" "eof")
same "centre and left held, a stranger takes the top at 0.52 (stored: that is the top pose's reach), then right and bottom with frames 0.1 from his top picture: both are not_you, nothing of his chains in, the scan is not saveable" '[["centre","left","top"],2,false]' "$(q "$out" '[[e["pose"] for e in evs if e.get("event") == "dotted"], len([e for e in evs if e.get("event") == "capture_failed" and e.get("code") == "not_you"]), any(e.get("event") == "saved" for e in evs)]')"
check "...and nothing was written" bash -c "[[ ! -e $STORE/people/emil.json ]]"
reset_store
scenario dot-centre dot-left "dot-straddle:0.52:0.02:1:uni:top" dot-right dot-bottom
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTT" "awaitwhere {\"event\":\"dotted\",\"pose\":\"top\"} 60" "send $DOTR" "awaitwhere {\"event\":\"dotted\",\"pose\":\"right\"} 60" "send $DOTB" "awaitwhere {\"event\":\"dotted\",\"pose\":\"bottom\"} 60" "send $DONE" "await saved 30")
same "the owner: centre, left, top at 0.52, right and bottom at their normal 0.30: all five are taken and saved" '[["centre","left","top","right","bottom"],true,0]' "$(q "$out" '[[e["pose"] for e in evs if e.get("event") == "dotted"], any(e.get("event") == "saved" for e in evs), len([e for e in evs if e.get("event") == "capture_failed"])]')"
same "...with five templates stored (the centre and the four poses)" '5' "$(python3 -c '
import json, sys
a = json.load(open(sys.argv[1]))["appearances"][0]
print(1 + len(a.get("extra") or []))' "$STORE/people/emil.json")"

step "dot scan: what can be saved, and the refusals"
reset_store
scenario dot-centre dot-left dot-right
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DONE" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DONE" "send $DOTR" "awaitwhere {\"event\":\"dotted\",\"pose\":\"right\"} 60" "send $DONE" "await saved 30")
same "done is refused with only the centre and with the centre and left (bad_sweep both times, the session lives)" '2' "$(q "$out" 'len([e for e in evs if e.get("event") == "capture_failed" and e.get("code") == "bad_sweep"])')"
same "...and saved once left and right are in: the centre and two poses, three templates" '3' "$(python3 -c '
import json, sys
a = json.load(open(sys.argv[1]))["appearances"][0]
print(1 + len(a.get("extra") or []))' "$STORE/people/emil.json")"
reset_store
scenario dot-centre
bad=(
  '{"cmd":"dot","appearance":"No glasses","pose":"left"}'
  '{"cmd":"dot","appearance":"No glasses","pose":"up"}'
  '{"cmd":"dot","appearance":"No glasses","pose":""}'
  '{"cmd":"dot","appearance":"No glasses","pose":7}'
  '{"cmd":"dot","appearance":"No glasses","pose":["centre"]}'
  '{"cmd":"dot","appearance":"No glasses","pose":null}'
  '{"cmd":"dot","appearance":"No glasses"}'
  '{"cmd":"dot","pose":"centre"}'
  '{"cmd":"dot","appearance":"","pose":"centre"}'
  '{"cmd":"dot","appearance":7,"pose":"centre"}'
  '{"cmd":"dot","appearance":"No\u0001glasses","pose":"centre"}'
)
script=("await ready 30" "send $CREATE")
for line in "${bad[@]}"; do script+=("send $line"); done
script+=("send $DOTC" "await dotted 60" "send {\"cmd\":\"capture\",\"appearance\":\"No glasses\"}" "eof")
out=$(session emil "${script[@]}")
same "${#bad[@]} malformed presses (a pose before the centre, a pose that does not exist, junk types, no appearance) and a capture after a dot: all bad_sweep" "$(( ${#bad[@]} + 1 ))" "$(q "$out" 'len([e for e in evs if e.get("event") == "capture_failed" and e.get("code") == "bad_sweep"])')"
same "...none of them started a child: exactly one dotting, and the valid centre after them all runs" '[1,1]' "$(q "$out" '[len([e for e in evs if e.get("event") == "dotting"]), len([e for e in evs if e.get("event") == "dotted"])]')"
check "...and nothing is left running" no_child

step "dot scan: cancel, and a press while one runs"
reset_store
scenario dot-hold-first
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotting 30" "send $DOTC" "send $DOTL" "send $DONE" "sleep 1" "eof")
same "while a press runs, a second press, a left press and a done are all refused, and the cancel ends it: discarded" '[3,"discarded"]' "$(q "$out" '[len([e for e in evs if e.get("event") == "capture_failed" and e.get("code") == "bad_sweep"]), evs[-1]["event"]]')"
sleep 2
check "...no engine child outlives the cancel" no_child
check "...and the camera lock is free again" flock -n "$CAMLOCK" true
check "...nothing is stored" bash -c "[[ ! -e $STORE/people/emil.json ]]"
reset_store
scenario dot-centre dot-left
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "eof")
same "cancel with the centre and left held: discarded, not saved" '["discarded",false]' "$(q "$out" '[evs[-1]["event"], any(e.get("event") == "saved" for e in evs)]')"
check "...and no record was written" bash -c "[[ ! -e $STORE/people/emil.json ]]"
reset_store
scenario dot-centre dot-left dot-top dot-centre
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTT" "awaitwhere {\"event\":\"dotted\",\"pose\":\"top\"} 60" "send $DOTC" "sleep 2" "eof")
same "a new centre (Scan again) replaces everything pending: the poses list restarts at the centre" '[["centre"]]' "$(q "$out" '[[e["poses"] for e in evs if e.get("event") == "dotted"][-1]]')"


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


step "the Advanced scan is gone (3.3.0): its verbs are refused, one by one, and nothing starts"
reset_store
scenario dot-centre
bad=(
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1,"targets":[0,1,2,3,4,5,6,7,8,9,10,11]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":2,"targets":[0,1,2,3,4,5,6,7,8,9,10,11]}'
  '{"cmd":"sweep","appearance":"No glasses","mode":"simple","lap":1,"targets":[9,3,0,6]}'
  '{"cmd":"sweep","appearance":"No glasses"}'
  '{"cmd":"sweep"}'
  '{"cmd":"trial","appearance":"No glasses"}'
  '{"cmd":"usual","appearance":"No glasses"}'
)
script=("await ready 30" "send $CREATE" "send $(python3 -c 'print("[" * 60000)')")
for line in "${bad[@]}"; do script+=("send $line"); done
script+=('send {"cmd":"finish"}' 'send {"cmd":"abort"}' "send $DOTC" "await dotted 60" "send $DONE" "eof")
out=$(session emil "${script[@]}")
same "${#bad[@]} Advanced verbs (a sweep of either mode and lap, a trial, a usual) are each answered bad_sweep, and so is the done after the centre alone (the floor): ${#bad[@]} + 1" "$(( ${#bad[@]} + 1 ))" "$(q "$out" 'len([e for e in evs if e.get("event") == "capture_failed" and e.get("code") == "bad_sweep"])')"
same "...none of them started a child (exactly one dotting: the valid centre after them), and there is no sweeping, track or swept event in the transcript" '[1,0]' "$(q "$out" '[len([e for e in evs if e.get("event") == "dotting"]), len([e for e in evs if e.get("event") in ("sweeping", "track", "swept", "aborted")])]')"
same "...finish and abort are not commands any more: ignored, no event, and the session carries on to the dot scan's centre" 'true' "$(q "$out" 'first("dotted") is not None')"
sleep 1
check "...nothing was stored (the done was refused)" bash -c "[[ ! -e $STORE/people/emil.json ]]"
check "...and nothing is left running" no_child
same "a 60,000-bracket line is ignored: no Traceback, the session lived to answer the valid press" 'false' "$(grep -q Traceback <<<"$out" && echo true || echo false)"
unset bad script

step "a stored Advanced appearance (3.1.x: the centre, 12 near, 12 far and 2 usual templates) still loads, matches, regenerates and goes"
# The helper can no longer MAKE one, so the record is written the way 3.1.x wrote it: a person scanned with the dot scan,
# then given the Advanced shape. plant_advanced <name> <label> rewrites that person's record in place.
plant_advanced() {
  python3 - "$STORE/people/$1.json" "$2" <<'PY'
import json, sys
path, label = sys.argv[1:]
doc = json.load(open(path))
appearance = next(a for a in doc["appearances"] if a["label"] == label)
def vec(centre, k, band):
    v = [0.0] * 128
    v[0] = centre                       # the owner's own axis
    v[2 + k % 6] = 0.12 + 0.02 * (band == "far")
    return v
extra = []
for band, r in (("near", 1.3), ("far", 1.1)):
    for k in range(12):
        extra.append({"pose": "a%03d" % (30 * k), "band": band, "time": 1789400000 + k, "r": r, "support": 4 + k % 3,
                      "encoding": vec(0.0, k, band)})
for k in range(2):
    extra.append({"pose": "usual", "band": "usual", "time": 1789400100 + k, "r": 1.0, "support": 3, "encoding": vec(0.0, 7 + k, "near")})
appearance["extra"] = extra
json.dump(doc, open(path, "w"))
PY
  chmod 0600 "$STORE/people/$1.json"
}
reset_store
scenario dot-centre dot-left dot-right
session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTR" "awaitwhere {\"event\":\"dotted\",\"pose\":\"right\"} 60" "send $DONE" "await saved 30" >/dev/null
plant_advanced emil "No glasses"
out=$("$ADMIN" regenerate 2>&1)
same "regenerate reads the Advanced record (27 templates) without complaint" 'ok' "$(python3 -c 'import json,sys; print("ok" if "error" not in json.loads(sys.argv[1]) else sys.argv[1])' "$out")"
same "the Lock set holds 12 of the 27 (the cap), every entry labelled emil/No glasses and one encoding of 128 numbers" '[12,["emil/No glasses"],true]' "$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(json.dumps([len(m), sorted({e["label"] for e in m}), all(len(e["data"]) == 1 and len(e["data"][0]) == 128 for e in m)], separators=(",", ":")))' "$MODELS/omarchy-face.person.emil.dat")"
same "...the Sudo set the centre alone (SUDO_POLICY is centre: an Advanced set gives Sudo nothing a dot scan's would not)" '1' "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$MODELS/omarchy-face.sudo.$ACCOUNT.dat")"
same "people.json (what the People and Person views read) counts 27 templates, Lock 12, Sudo 1, and carries no encoding" '[27,12,1,false]' "$(python3 -c '
import json, sys
text = open(sys.argv[1]).read()
p = json.loads(text)["people"][0]
print(json.dumps([p["appearances"][0]["templates"], p["lockTemplates"], p["sudoTemplates"], "encoding" in text], separators=(",", ":")))' "$PEOPLE")"
fp1=$(sha256sum "$MODELS"/omarchy-face.*.dat "$PEOPLE" | sort)
"$ADMIN" regenerate >/dev/null 2>&1
same "regenerate is byte-identical on it (the derived sets and people.json)" "$fp1" "$(sha256sum "$MODELS"/omarchy-face.*.dat "$PEOPLE" | sort)"
out=$("$ADMIN" set-limits emil 3 3 2>&1)
same "set-limits changes what is used without re-enrolment (3 and 3 on the Advanced record)" '[3,1]' "$(python3 -c '
import json, sys
p = json.loads(sys.argv[1])["person"]
print(json.dumps([p["lockTemplates"], p["sudoTemplates"]], separators=(",", ":")))' "$out")"
same "...and the person's Lock set holds three templates, from the same record" '3' "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$MODELS/omarchy-face.person.emil.dat")"
"$ADMIN" set-limits emil 12 4 >/dev/null 2>&1
same "back to 12 and 4: twelve in the Lock set" '12' "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$MODELS/omarchy-face.person.emil.dat")"
for bad in "2 4" "12 13" "37 4" "a 4" "12" ""; do
  out=$("$ADMIN" set-limits emil $bad 2>&1)
  same "set-limits emil $bad is refused" '{"error":"bad_arguments"}' "$out"
done
same "limits are in the record" '{"lock": 12, "sudo": 4}' "$(json_field "$STORE/people/emil.json" limits)"
# a dot scan of the same appearance replaces it whole: there is no larger-set rule any more
scenario dot-centre dot-left dot-right
out=$(session emil "await ready 30" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTR" "awaitwhere {\"event\":\"dotted\",\"pose\":\"right\"} 60" "send $DONE" "await saved 30")
same "a dot re-scan of the Advanced appearance is accepted (3.2.x refused it, rule R) and replaces it whole: three templates, no far or usual left" '[3,true]' "$(python3 -c '
import json, sys
a = json.load(open(sys.argv[1]))["appearances"]
print(json.dumps([sum(1 + len(x.get("extra") or []) for x in a), all(e["band"] == "near" for x in a for e in x.get("extra") or [])], separators=(",", ":")))' "$STORE/people/emil.json")"
reset_store
scenario dot-centre dot-left dot-right dot-centre
session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTR" "awaitwhere {\"event\":\"dotted\",\"pose\":\"right\"} 60" "send $DONE" "await saved 30" >/dev/null
plant_advanced emil "No glasses"
"$ADMIN" regenerate >/dev/null 2>&1
out=$(printf '{"appearance":"No glasses"}' | "$ADMIN" remove-appearance emil 2>&1)
same "remove-appearance takes the Advanced appearance away: the person has none left" 'true' "$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
p = d.get("person") or {}
print(json.dumps("error" not in d and not p.get("appearances")))' "$out" 2>/dev/null || echo false)"
reset_store
scenario dot-centre dot-left dot-right
session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTR" "awaitwhere {\"event\":\"dotted\",\"pose\":\"right\"} 60" "send $DONE" "await saved 30" >/dev/null
scenario dot-centre dot-left dot-right
session anna "await ready 30" 'send {"cmd":"create","label":"Anna"}' "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTR" "awaitwhere {\"event\":\"dotted\",\"pose\":\"right\"} 60" "send $DONE" "await saved 30" >/dev/null
plant_advanced anna "No glasses"
"$ADMIN" regenerate >/dev/null 2>&1
"$ADMIN" remove-person anna >/dev/null 2>&1
check "remove-person takes a second person with an Advanced appearance away: the record and her derived set go, the owner's stay" bash -c "[[ ! -e $STORE/people/anna.json && ! -e $MODELS/omarchy-face.person.anna.dat && -e $STORE/people/emil.json && -e $MODELS/omarchy-face.person.emil.dat ]]"
reset_store

step "a legacy capture works until the first dot press"
out=$(session emil "await ready 30" "send $CREATE" 'send {"cmd":"capture","appearance":"No glasses"}' "await captured 60" "send $DONE" "await saved 30")
same "capture is still the old single frame: ready capturing captured saved" '["ready","capturing","captured","saved"]' "$(q "$out" 'names')"
same "...and the stored appearance has no extra" '1' "$(python3 -c '
import json, sys
a = json.load(open(sys.argv[1]))["appearances"][0]
print(1 + len(a.get("extra") or []))' "$STORE/people/emil.json")"
reset_store
scenario dot-centre
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" 'send {"cmd":"capture","appearance":"No glasses"}' "await capture_failed 30" "eof")
same "...and after a dot press it is refused (bad_sweep, nothing taken)" '"bad_sweep"' "$(q "$out" 'last("capture_failed")["code"]')"

step "the debug trace: off by default; with debug=true in root's config, one line per press, no frame data"
# A stand-in for `logger`: only the dot child's own (tag omarchy-face-sweep, no message, lines on stdin) is kept;
# every other call has its message in argv and must not read the caller's stdin.
cat >"$LAB/logger-stub" <<'LOGGER'
#!/bin/bash
if [[ $# -eq 4 && $2 == omarchy-face-sweep ]]; then cat >>/run/omarchy-face-stub/logger.out; else echo "$*" >>/run/omarchy-face-stub/logger.other; fi
LOGGER
chmod +x "$LAB/logger-stub"
mount --bind "$LAB/logger-stub" /usr/bin/logger || exit 1
: >/run/omarchy-face-stub/logger.out
reset_store
scenario dot-strobe-centre
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "eof")
check "off by default: the child logs no debug line" bash -c "! grep -q '^debug ' /run/omarchy-face-stub/logger.out"
printf 'debug=true\n' >>/etc/omarchy-face/config
reset_store
scenario dot-strobe-centre dot-strobe-left dot-stranger-left
: >/run/omarchy-face-stub/logger.out
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTL" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "dot scan with debug=true: one trace line per press (three presses, three lines), and the journal line is the child's own" '3' "$(grep -c '^debug dot ' /run/omarchy-face-stub/logger.out)"
check "...each line is the pose, the result, the counts and the reason, in words and numbers only" bash -c "grep '^debug dot ' /run/omarchy-face-stub/logger.out | grep -qvE '^debug dot pose=(centre|left|top|right|bottom) ok=[01] agree=[0-9]+ frames=[0-9]+ strobe_off=[0-9]+ black=[0-9]+ dark=[0-9]+ none=[0-9]+ multi=[0-9]+ closer=[0-9]+ farther=[0-9]+ edge=[0-9]+ roll=[0-9]+ stranger=[0-9]+ refused_hard=[0-9]+ refused_chain=[0-9]+ maxrun=[0-9]+ end=[a-z]+ centre_max=[0-9.a-z/]+ eye_lo=[0-9a-z/]+ eye_hi=[0-9a-z/]+ t=[0-9.]+ why=[a-z_-]+\$' && exit 1 || exit 0"
same "...the stranger's press (a descriptor 1.0 from the centre) says WHICH bound refused it: over HARD of the centre (refused_hard 3 or more, refused_chain 0), ended by the run (end=run), and the owner's presses took theirs (maxrun 3 or more, end=ok)" 'true' "$(python3 -c "
import re
rows = [dict(re.findall(r'(\w+)=(\S+)', l)) for l in open('/run/omarchy-face-stub/logger.out') if l.startswith('debug dot ')]
print(str(len(rows) == 3 and int(rows[2]['refused_hard']) >= 3 and rows[2]['refused_chain'] == '0' and rows[2]['end'] == 'run' and int(rows[0]['maxrun']) >= 3 and rows[0]['end'] == 'ok').lower())
")"
same "...the strobe's off frames were counted and skipped (about as many as the lit ones), and the stranger's press names its reason" 'true' "$(python3 -c "
import re
rows = [dict(re.findall(r'(\w+)=(\S+)', l)) for l in open('/run/omarchy-face-stub/logger.out') if l.startswith('debug dot ')]
print(str(len(rows) == 3 and int(rows[0]['strobe_off']) > 0 and rows[0]['ok'] == '1' and rows[2]['ok'] == '0' and rows[2]['why'] == 'not_you' and int(rows[2]['stranger']) >= 3 and rows[0]['centre_max'] == 'n/a').lower())
")"
reset_store
scenario dot-centre "dot-straddle:0.46:0.0:1:uni:left"
: >/run/omarchy-face-stub/logger.out
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "...and a frame 0.46 from the centre (inside HARD 0.55, over CHAIN 0.40) is refused by CHAIN: refused_chain 3 or more, refused_hard 0" 'true' "$(python3 -c "
import re
rows = [dict(re.findall(r'(\w+)=(\S+)', l)) for l in open('/run/omarchy-face-stub/logger.out') if l.startswith('debug dot ')]
print(str(len(rows) == 2 and int(rows[1]['refused_chain']) >= 3 and rows[1]['refused_hard'] == '0' and rows[1]['end'] == 'run').lower())
")"
printf 'debug=false\n' >>/etc/omarchy-face/config
: >/run/omarchy-face-stub/logger.out
reset_store
scenario dot-strobe-centre
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "eof")
check "the last debug line in the config wins, as in the shell side (debug=true then debug=false: no trace)" bash -c "! grep -q '^debug ' /run/omarchy-face-stub/logger.out"
sed -i '/^debug=/d' /etc/omarchy-face/config
umount /usr/bin/logger

step "rule F: root re-checks the guard itself, whatever the child says"
# A copy of the helper whose child has a broken guard (guard_verdict always passes). The parent must still refuse.
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
patch_admin "$LAB/admin-noguard" '    if distance(encoding, centre) > hard:
        return "beyond"' '    return "ok"
    if distance(encoding, centre) > hard:
        return "beyond"'
REAL_ADMIN=$ADMIN
ADMIN=$LAB/admin-noguard
reset_store
scenario dot-centre dot-left "dot-straddle:0.66:0.0:1:uni:top"
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTT" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "a child whose guard passes everything, a top press 0.66 from the centre (over DOT_TOP_HARD 0.60): the parent drops it with the TOP limits (not_you), and the same child at the left press 0.58 is dropped with the 3.1.x ones" '["not_you",false]' "$(q "$out" '[last("capture_failed")["code"], any(e.get("event") == "dotted" and e["pose"] == "top" for e in evs)]')"
reset_store
scenario dot-centre "dot-straddle:0.58:0.0:1:uni:left"
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"capture_failed\"} 60" "eof")
same "...(the left press at 0.58, same broken child)" '"not_you"' "$(q "$out" 'last("capture_failed")["code"]')"
ADMIN=$REAL_ADMIN
# the control: the 3.2.2 helper as first built (every held picture a reference) stores the same flow
patch_admin "$LAB/admin-allref" '                reference = sw["dot_references"](pose, captured[label]["encoding"], [
                    (e["pose"], e["encoding"]) for e in (captured[label].get("extra") or []) if e["pose"] != stored_pose])' '                reference = [captured[label]["encoding"]] + [
                    e["encoding"] for e in (captured[label].get("extra") or []) if e["pose"] != stored_pose]'
ADMIN=$LAB/admin-allref
reset_store
scenario dot-centre dot-left "dot-straddle:0.52:0.02:1:uni:top" dot-chain-right dot-chain-bottom
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"dotted\",\"pose\":\"left\"} 60" "send $DOTT" "awaitwhere {\"event\":\"dotted\",\"pose\":\"top\"} 60" "send $DOTR" "awaitwhere {\"event\":\"dotted\",\"pose\":\"right\"} 60" "send $DOTB" "awaitwhere {\"event\":\"dotted\",\"pose\":\"bottom\"} 60" "send $DONE" "await saved 30")
same "control: with every held picture a reference (as first built) the same stranger chains into right and bottom and is saved" '[["centre","left","top","right","bottom"],true]' "$(q "$out" '[[e["pose"] for e in evs if e.get("event") == "dotted"], any(e.get("event") == "saved" for e in evs)]')"
ADMIN=$REAL_ADMIN
reset_store
scenario dot-centre dot-stranger-left
ADMIN=$LAB/admin-noguard
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 60" "send $DOTL" "awaitwhere {\"event\":\"capture_failed\"} 60" "send $DONE" "eof")
same "dot scan, a child whose guard passes everything: the stranger at the left press is dropped by the parent (not_you), and the saved-nothing done is refused" '["not_you","bad_sweep"]' "$(q "$out" '[c["code"] for c in evs if c.get("event") == "capture_failed"]')"
same "...and the child's debug-free transcript has no dotted for left" '["centre"]' "$(q "$out" '[e["pose"] for e in evs if e.get("event") == "dotted"]')"
ADMIN=$REAL_ADMIN


step "the session bound: a press does not lengthen the session (scaled by OMARCHY_FACE_SESSION_SECONDS)"
reset_store
scenario dot-hold-first
out=$(OMARCHY_FACE_SESSION_SECONDS=4 session emil "await ready 30" "send $CREATE" "send $DOTC" "sleep 5.5" "eof")
same "a session of 4 s is over at 4 s with a press running: the transcript ends discarded" '"discarded"' "$(q "$out" 'evs[-1]["event"]')"
out=$(OMARCHY_FACE_SESSION_SECONDS=4 session emil "await ready 30" "sleep 3" "send $CREATE" "send $DOTC" "sleep 2.5" "eof")
same "...also when the press is sent late (at 3 s): it buys no extra time (discarded)" '"discarded"' "$(q "$out" 'evs[-1]["event"]')"
sleep 1
check "...with the child gone" no_child
# A refused line is not activity: it must not restart the idle clock (the dot branch's refusals do not either).
# With both bounds at 4 s the session ends at 4 s whatever happens, so the reason is what tells the two apart:
# "idle" when nothing but refusals came after the create, "the session limit" when a refusal had moved the idle clock.
reset_store
out=$(OMARCHY_FACE_SESSION_SECONDS=4 session emil "await ready 30" "send $CREATE" "sleep 1.5" 'send {"cmd":"sweep","appearance":"No glasses"}' "sleep 1.5" 'send {"cmd":"trial"}' "sleep 3" "eof")
same "refused lines (a sweep, a trial) at 1.5 s and 3 s do not extend the idle clock: the session expires as idle at 4 s" '1' "$(grep -c 'the session expired (idle)' <<<"$out")"
patch_admin "$LAB/admin-idle" 'refuse("%s is not in this release" % command)
            continue' 'refuse("%s is not in this release" % command)'
ADMIN=$LAB/admin-idle
reset_store
out=$(OMARCHY_FACE_SESSION_SECONDS=4 session emil "await ready 30" "send $CREATE" "sleep 1.5" 'send {"cmd":"sweep","appearance":"No glasses"}' "sleep 1.5" 'send {"cmd":"trial"}' "sleep 3" "eof")
ADMIN=$REAL_ADMIN
same "...and the same session on a copy without the continue is what the test would catch: it ends at the session limit, not as idle" '0' "$(grep -c 'the session expired (idle)' <<<"$out")"

step "what the child says on stderr never reaches the client; the child holds the camera lock; a deep line is ignored"
patch_admin "$LAB/admin-noisy" 'def say(obj):
    import json
' 'def say(obj):
    import json
    sys.stderr.write("LEAK /dev/video9 Traceback (most recent call last)\n")
'
reset_store
scenario dot-centre
ADMIN=$LAB/admin-noisy
out=$(session emil "await ready 30" "send $CREATE" "send $DOTC" "await dotted 90" "eof")
ADMIN=$REAL_ADMIN
same "a child that writes a path and a traceback to stderr: the press still completes" 'true' "$(q "$out" 'first("dotted") is not None')"
same "...and none of it reaches the client (no ERR line mentions it)" 'false' "$(grep -qE 'LEAK|/dev/video9|Traceback' <<<"$out" && echo true || echo false)"
reset_store
scenario dot-hold-first
CAMLOCK=/run/omarchy-face/camera.lock
( session emil "await ready 30" "send $CREATE" "send $DOTC" "sleep 3" "send $(python3 -c 'print("[" * 60000)')" "sleep 1" "eof" >"$LAB/hold.out" 2>&1 ) &
holder=$!
sleep 2
held=0
for pid in $(pgrep -f 'def run_dot'); do
  for fd in /proc/$pid/fd/*; do [[ $(readlink "$fd" 2>/dev/null) == "$CAMLOCK" ]] && held=$((held + 1)) && break; done
done
same "the dot child (and its timeout) holds the camera lock's file, as the daemon's compare.py does" 'true' "$([[ $held -ge 2 ]] && echo true || echo false)"
wait "$holder"
same "a 60,000-bracket line during a running press is ignored: the press ran (dotting), and the cancel after it ended the session (discarded)" '["dotting","discarded"]' "$(q "$(cat "$LAB/hold.out")" '[e for e in names if e in ("dotting", "discarded")]')"
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
check("the Advanced scan's events are not on the allow-list (3.3.0): sweeping, swept and track are all dropped",
      all(t(d) is None for d in (
          {"event": "sweeping", "mode": "advanced", "lap": 1, "targets": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], "quota": 2},
          {"event": "swept", "mode": "advanced", "lap": 2, "filled": [0, 1], "centreHeld": True, "kept": 3},
          {"event": "track", "state": "hold", "u": 0.1, "v": -1.2, "target": 9, "centre": 1.0, "bins": [0.0] * 12, "canFinish": False},
          {"event": "aborted"})))
check("capture_failed with each of the twelve codes passes",
      all(t({"event": "capture_failed", "code": c}) for c in ns["pure"]()["CODES"]))
check("capture_failed with short passes (an int from 1 to 99), and without it", t({"event": "capture_failed", "code": "too_far", "short": 14}) is not None and t({"event": "capture_failed", "code": "too_far"}) is not None)
for name, doc in [("short 0", {"event": "capture_failed", "code": "too_far", "short": 0}), ("short 100", {"event": "capture_failed", "code": "too_far", "short": 100}),
                  ("a bool short", {"event": "capture_failed", "code": "too_far", "short": True}), ("a float short", {"event": "capture_failed", "code": "too_far", "short": 5.0}),
                  ("a string short", {"event": "capture_failed", "code": "too_far", "short": "5"})]:
    check(name + " is dropped", t(doc) is None)
check("dotting, dot and dotted pass", all(t(d) is not None for d in (
    {"event": "dotting", "pose": "left", "need": 3}, {"event": "dot", "pose": "centre", "good": 2, "need": 3},
    {"event": "dotted", "pose": "bottom", "poses": ["centre", "left", "bottom"], "kept": 3})))
for name, doc in [
    ("a pose that is not on the card", {"event": "dotting", "pose": "up", "need": 3}),
    ("a pose that is a number", {"event": "dotting", "pose": 3, "need": 3}),
    ("a need of 0", {"event": "dotting", "pose": "left", "need": 0}),
    ("a need of 10", {"event": "dotting", "pose": "left", "need": 10}),
    ("a count that is a bool", {"event": "dot", "pose": "left", "good": True, "need": 3}),
    ("a count of 10", {"event": "dot", "pose": "left", "good": 10, "need": 3}),
    ("a float count", {"event": "dot", "pose": "left", "good": 1.0, "need": 3}),
    ("poses with a repeat", {"event": "dotted", "pose": "left", "poses": ["left", "left"], "kept": 2}),
    ("poses with a word that is not a pose", {"event": "dotted", "pose": "left", "poses": ["centre", "ceiling"], "kept": 2}),
    ("six poses", {"event": "dotted", "pose": "left", "poses": ["centre", "left", "top", "right", "bottom", "left"], "kept": 5}),
    ("a dotted carrying an encoding", {"event": "dotted", "pose": "left", "poses": ["centre"], "kept": 1, "encoding": [0.0] * 128}),
]:
    check(name + " is dropped", t(doc) is None)
good_dotted = {"event": "dotted", "pose": "left", "poses": ["centre", "left"], "kept": 2}
for name, doc in [
    ("a planted key", dict(good_dotted, encoding=[0.0] * 128)),
    ("a path", dict(good_dotted, path="/dev/video2")),
    ("a bool where a number belongs", dict(good_dotted, kept=True)),
    ("NaN", dict(good_dotted, kept=float("nan"))),
    ("Infinity", dict(good_dotted, kept=float("inf"))),
    ("1e400", dict(good_dotted, kept=json.loads("1e400"))),
    ("a huge int", dict(good_dotted, kept=10 ** 400)),
    ("a code that is not one of the twelve", {"event": "capture_failed", "code": "ok"}),
    ("an event name that is not a scan event", {"event": "saved"}),
    ("no event", {"state": "hold"}),
]:
    check(name + " is dropped", t(doc) is None)
check("dumping NaN is refused outright (allow_nan=False)", not any(
    "NaN" in json.dumps(g, allow_nan=False) for g in [good_dotted]))
# the override: only lowers, ignores junk, and is never read by root of the machine
base = ns["sweep_bounds"]()
check("no override: the dot scan's bound alone", base == {"dot": 4.0})
for asked in ("1e9", "NaN", "inf", "-1", "-inf", "0", "abc", ""):
    os.environ["OMARCHY_FACE_SWEEP_SECONDS"] = asked
    check("OMARCHY_FACE_SWEEP_SECONDS=%r lengthens nothing" % asked, ns["sweep_bounds"]() == base)
os.environ["OMARCHY_FACE_SWEEP_SECONDS"] = "2"
check("2 lowers the bound to at most 2", all(v <= 2 for v in ns["sweep_bounds"]().values()))
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
# judge_dot(): the parent's own reading of one press, whatever the child says
jd = ns["judge_dot"]
ZERO0 = [0.0] * 128
def at(d):
    return [d] + [0.0] * 127
def ok_press(encoding=None, support=3):
    return {"ok": True, "encoding": encoding if encoding is not None else at(0.2), "support": support}
check("judge_dot keeps a centre with no reference", jd("centre", ok_press(at(5.0)), [])["code"] is None)
check("judge_dot keeps a pose 0.3 from the centre", jd("left", ok_press(at(0.3)), [ZERO0])["code"] is None)
check("judge_dot keeps a pose exactly CHAIN (0.40) from the centre", jd("left", ok_press(at(0.40)), [ZERO0])["code"] is None)
check("judge_dot refuses a pose just past CHAIN of the only template (0.4001)", jd("left", ok_press(at(0.4001)), [ZERO0])["code"] == "not_you")
check("judge_dot refuses somebody else (1.0)", jd("left", ok_press(at(1.0)), [ZERO0])["code"] == "not_you")
check("judge_dot refuses a pose 0.6 from the centre (over HARD) although a held pose is 0.3 from it: HARD is the centre's",
      jd("right", ok_press([0.0, 0.0, 0.6] + [0.0] * 125), [ZERO0, [0.0, 0.0, 0.3] + [0.0] * 125])["code"] == "not_you")
check("judge_dot keeps a pose 0.5 from the centre when a held pose is 0.3 from it (chain, inside HARD)",
      jd("right", ok_press([0.0, 0.0, 0.5] + [0.0] * 125), [ZERO0, [0.0, 0.0, 0.3] + [0.0] * 125])["code"] is None)
check("judge_dot carries 'short' for too_far only, and only an int from 1 to 99", jd("centre", {"ok": False, "code": "too_far", "short": 14}, []) == {"code": "too_far", "short": 14}
      and jd("centre", {"ok": False, "code": "no_face", "short": 14}, []) == {"code": "no_face"} and jd("centre", {"ok": False, "code": "too_far", "short": 100}, []) == {"code": "too_far"}
      and jd("centre", {"ok": False, "code": "too_far", "short": True}, []) == {"code": "too_far"} and jd("centre", {"ok": False, "code": "too_far"}, []) == {"code": "too_far"})
def at2(a, b):
    return [a, b] + [0.0] * 126
check("judge_dot, TOP: 0.56 from the centre and from the nearest template is kept, 0.5601 is not (CHAIN); LEFT, RIGHT and BOTTOM keep 0.55 and 0.40",
      jd("top", ok_press(at(0.56)), [ZERO0])["code"] is None and jd("top", ok_press(at(0.5601)), [ZERO0])["code"] == "not_you"
      and jd("top", ok_press(at(0.54)), [ZERO0])["code"] is None
      and all(jd(p, ok_press(at(0.58)), [ZERO0])["code"] == "not_you" and jd(p, ok_press(at(0.40)), [ZERO0])["code"] is None
              and jd(p, ok_press(at(0.4001)), [ZERO0])["code"] == "not_you" for p in ("left", "right", "bottom")))
check("judge_dot, TOP: chained through a held pose it may be 0.59 from the centre (0.5 from the held one) but never over DOT_TOP_HARD 0.60 from the centre (HARD stays the centre's)",
      jd("top", ok_press(at2(0.59, 0.0)), [ZERO0, at2(0.59, 0.5)])["code"] is None and jd("top", ok_press(at2(0.6001, 0.0)), [ZERO0, at2(0.6001, 0.5)])["code"] == "not_you")
check("judge_dot refuses a pose press with an empty reference (nothing to compare with), but takes the centre's", jd("left", ok_press(at(0.1)), [])["code"] == "timeout"
      and jd("centre", ok_press(at(0.1)), [])["code"] is None)
check("judge_dot refuses a NaN encoding", jd("centre", ok_press([float("nan")] + [0.0] * 127), [])["code"] == "timeout")
check("judge_dot refuses 127 numbers", jd("centre", ok_press([0.0] * 127), [])["code"] == "timeout")
check("judge_dot refuses a support of 2 (under DOT_NEED) and of 100", jd("centre", ok_press(support=2), [])["code"] == "timeout" and jd("centre", ok_press(support=100), [])["code"] == "timeout")
check("judge_dot refuses a bool support", jd("centre", ok_press(support=True), [])["code"] == "timeout")
check("judge_dot passes a known failure code through and turns an unknown one into timeout",
      jd("centre", {"ok": False, "code": "no_face"}, [])["code"] == "no_face" and jd("centre", {"ok": False, "code": "changed"}, [])["code"] == "timeout"
      and jd("centre", {"ok": False, "code": 7}, [])["code"] == "timeout" and jd("centre", {"ok": False}, [])["code"] == "timeout")
check("judge_dot refuses a result that is not a dict, and an ok that is only truthy", jd("centre", None, [])["code"] == "timeout" and jd("centre", {"ok": 1, "encoding": at(0.1), "support": 3}, [])["code"] == "timeout")
check("judge, the Advanced lap's check, is gone (3.3.0): no `judge`, no lap results, in STORE_PY", "judge" not in ns or ns.get("judge") is None)
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
check "every event line of every transcript is one of the event names the 3.3.0 helper has" python3 - "$LAB/all.log" <<'PY'
import json, sys
allowed = {"ready", "capturing", "captured", "capture_failed", "dotting", "dot", "dotted", "saved", "discarded", "error"}
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
