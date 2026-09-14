#!/bin/bash

# F3's gate: the people store, `enroll-session`, and the derived model sets
# (plan-merged.md §4 phase 4, plan-engine.md §3).
#
#   ./dev/f3-people-store.sh              in a private user namespace (default)
#   ./dev/f3-people-store.sh --real       the REAL howdy, the REAL infrared
#                                         camera, and a face in front of it
#   ./dev/f3-people-store.sh --measure    --real, plus the 3/6/9 measurement
#                                         of plan-engine.md §7
#
# The default run stubs the engine: `cli.py add` and `compare.py` are two small
# scripts that write and read howdy's own model format and can be told to fail in
# each of the ways add.py does. That is what lets every branch of the protocol be
# tested -- including the ones that need a camera that is busy, dark or looking at
# two people -- without a person sitting in front of the laptop.
#
# What the stub cannot say is whether the real engine is driven correctly. That
# is what --real is for: it unpacks the howdy and python-dlib packages the engine
# build produced into the sandbox and runs the same code against /dev/video2.
#
# The sandbox is the one f1-round-trip.sh uses -- `unshare --map-root-user
# --mount`, a uid 0 that owns nothing -- with tmpfs over /etc, /run, /var/lib and
# /usr/lib/security. Nothing outside it is written: no people are recorded on
# this machine, no models land in howdy's directory, and the store disappears
# with the namespace.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ACCOUNT=${SUDO_USER:-${USER:-$(id -un)}}
MODE=${1:-}

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

note() { echo "  ${YELLOW}note${RESET}  $*"; }
step() { echo; echo "${DIM}== $*${RESET}"; }

# --- the sandbox -------------------------------------------------------------

if [[ ${OMARCHY_FACE_F3_IN_NS:-0} != 1 ]]; then
  command -v unshare >/dev/null || { echo "unshare is not installed" >&2; exit 1; }
  exec env OMARCHY_FACE_F3_IN_NS=1 OMARCHY_FACE_F3_ACCOUNT="$ACCOUNT" \
    OMARCHY_FACE_F3_MODE="$MODE" \
    unshare --map-root-user --mount --pid --fork "$BASH" "$0" "$MODE"
fi

ACCOUNT=${OMARCHY_FACE_F3_ACCOUNT:-$ACCOUNT}
REAL=0
MEASURE=0
[[ $MODE == --real || $MODE == --measure ]] && REAL=1
[[ $MODE == --measure ]] && MEASURE=1

# /etc, with everything but Face's own directory pointing back at the real one.
mount --bind /etc /mnt || exit 1
mount -t tmpfs tmpfs /etc || exit 1
chmod 0755 /etc
for real in /mnt/*; do ln -s "$real" "/etc/${real#/mnt/}"; done
rm -f /etc/pam.d
cp -rp /mnt/pam.d /etc/pam.d 2>/dev/null
chown -R root:root /etc/pam.d
rm -f /etc/omarchy-face 2>/dev/null
mkdir -p /etc/omarchy-face
printf 'account=%s\nsudo=false\nlock=false\n' "$ACCOUNT" >/etc/omarchy-face/config

mount -t tmpfs tmpfs /run || exit 1
chmod 0755 /run

# A PID namespace with the host's /proc is a namespace where a process cannot
# read its own parent. The stub engine checks that it was started by timeout(1),
# which is exactly that read.
mount -t proc proc /proc 2>/dev/null

# /var/lib holds the store. Same trick as /etc: the machine's own entries stay
# reachable (pacman's database, among others), Face's own directory is new. The
# bind target is under /run, which is already a tmpfs of our own -- there is
# nowhere at / this uid may create a directory.
mkdir -p /run/real-var-lib
mount --bind /var/lib /run/real-var-lib || exit 1
mount -t tmpfs tmpfs /var/lib || exit 1
chmod 0755 /var/lib
for real in /run/real-var-lib/*; do ln -s "$real" "/var/lib/${real#/run/real-var-lib/}"; done

# howdy's directory. Real or stubbed, it is a tmpfs either way, so no model
# file ever lands in the installed engine's own folder.
mount -t tmpfs tmpfs /usr/lib/security || exit 1
chmod 0755 /usr/lib/security
mkdir -p /usr/lib/security/howdy/models
chmod 0755 /usr/lib/security/howdy
chmod 0700 /usr/lib/security/howdy/models

# The two PAM helpers, because the unwire step below inserts and removes the
# block phase 5 will use, and `pam_insert_block` refuses to point an auth stack
# at a helper that is not root's alone.
mount -t tmpfs tmpfs /usr/local || exit 1
chmod 0755 /usr/local
mkdir -p /usr/local/bin
chmod 0755 /usr/local/bin
install -o root -g root -m 0755 "$REPO/system/omarchy-face-gate" /usr/local/bin/
install -o root -g root -m 0755 "$REPO/system/omarchy-face-verify" /usr/local/bin/

ADMIN=$REPO/system/omarchy-face-admin
STUB=/run/omarchy-face-stub
mkdir -p "$STUB"
LAB=$(mktemp -d /run/f3.XXXXXX)

echo "F3 — the people store (plan-merged.md §4 phase 4)"
echo "${DIM}sandbox: uid $(id -u), /etc /run /var/lib and /usr/lib/security are private to this run${RESET}"

# --- the engine, real or stubbed ---------------------------------------------

if ((REAL)); then
  # The packages the phase-3 build produced, unpacked into the sandbox. Nothing
  # is installed on the machine: the tmpfs above is where howdy lands, and
  # dlib's site-packages entry is a bind mount that exists only in here.
  packages=$(ls -d /tmp/omarchy-face-f2.* 2>/dev/null | head -1)
  howdy_pkg=$(ls "$packages"/howdy/howdy-*.pkg.tar.* 2>/dev/null | grep -v debug | head -1)
  dlib_pkg=$(ls "$packages"/python-dlib/python-dlib-[0-9]*.pkg.tar.* 2>/dev/null | grep -v debug | head -1)
  if [[ -z ${howdy_pkg:-} || -z ${dlib_pkg:-} ]]; then
    echo "  ${RED}FAIL${RESET}  --real needs the built packages (run dev/f2-engine-job.sh --builder first)"
    exit 1
  fi
  bsdtar -xf "$howdy_pkg" -C "$LAB" usr/lib/security/howdy || exit 1
  cp -a "$LAB"/usr/lib/security/howdy/. /usr/lib/security/howdy/
  mkdir -p /usr/lib/security/howdy/models
  chmod 0700 /usr/lib/security/howdy/models

  site=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
  bsdtar -xf "$dlib_pkg" -C "$LAB" || exit 1
  # The real site-packages has to stay reachable AFTER it is shadowed, or every
  # link below points at the directory that replaced it -- which is how numpy
  # goes missing from a machine that has it.
  mkdir -p /run/real-site
  mount --bind "$site" /run/real-site || exit 1
  mkdir -p "$LAB/site"
  for entry in /run/real-site/*; do ln -s "$entry" "$LAB/site/${entry##*/}"; done
  for entry in "$LAB$site"/*; do ln -sfn "$entry" "$LAB/site/${entry##*/}"; done
  mount --bind "$LAB/site" "$site" || exit 1
  python3 -c 'import dlib' 2>/dev/null ||
    { echo "  ${RED}FAIL${RESET}  dlib does not import from the unpacked package"; exit 1; }

  ir=$("$REPO/system/omarchy-face-camera" --ir-node 2>/dev/null)
  [[ -n $ir ]] || { echo "  ${RED}FAIL${RESET}  no infrared camera"; exit 1; }
  sed -i "s#^device_path =.*#device_path = $ir#" /usr/lib/security/howdy/config.ini
  sed -i 's/^end_report =.*/end_report = true/' /usr/lib/security/howdy/config.ini
  sed -i 's/^timeout =.*/timeout = 5/' /usr/lib/security/howdy/config.ini
  sed -i 's/^recording_plugin =.*/recording_plugin = opencv/' /usr/lib/security/howdy/config.ini
  echo "${DIM}real engine: howdy $(basename "$howdy_pkg") on $ir${RESET}"
else
  # A stub of the two engine entry points, in howdy's own model format. The
  # control files below are how a test asks for each of add.py's failures.
  cat >/usr/lib/security/howdy/config.ini <<'INI'
[video]
certainty = 3.5
timeout = 5
dark_threshold = 60
[debug]
end_report = true
INI
  cat >/usr/lib/security/howdy/cli.py <<'STUBADD'
import json, os, sys, time
# The stand-in for `howdy add`. It mirrors cli.py's own refusals so the helper's
# invocation is tested, not just its parsing (cli.py:83-90).
if os.environ.get("SUDO_USER") is None:
    print("Please run this command as root:")
    sys.exit(1)
args = sys.argv[1:]
model = args[args.index("-U") + 1] if "-U" in args else "none"
if model == "root":
    print("Can't run howdy commands as root")
    sys.exit(1)
control = "/run/omarchy-face-stub"
with open(control + "/log", "a") as handle:
    parent = open("/proc/%d/comm" % os.getppid()).read().strip()
    handle.write("add %s parent=%s y=%s cmd=%s\n" %
                 (model, parent, "-y" in args, args[-1]))
word = open(control + "/add").read().strip() if os.path.exists(control + "/add") else "ok"
if word == "no_face":
    print("No face detected, aborting"); sys.exit(1)
if word == "multiple_faces":
    print("Multiple faces detected, aborting"); sys.exit(1)
if word == "too_dark":
    print("All frames were too dark, please check dark_threshold in config"); sys.exit(1)
if word == "black_frames":
    print("Camera saw only black frames - is IR emitter working?"); sys.exit(1)
if word == "hang":
    time.sleep(300)
face = 1
if os.path.exists(control + "/face"):
    face = int(open(control + "/face").read().strip() or 1)
encoding = [round(face * 0.01 + index * 0.001, 6) for index in range(128)]
path = os.path.abspath(__file__ + "/../models/" + model + ".dat")
json.dump([{"time": 1789400000, "label": "Initial model", "id": 0, "data": [encoding]}],
          open(path, "w"))
os.chmod(path, 0o600)
print("Scan complete")
STUBADD
  cat >/usr/lib/security/howdy/compare.py <<'STUBCOMPARE'
import json, os, sys, time
# The stand-in for compare.py, printing the two lines the engine reads
# (compare.py:277 and :279) on howdy's own x10 scale.
control = "/run/omarchy-face-stub"
user = sys.argv[1]
path = os.path.abspath(__file__ + "/../models/" + user + ".dat")
with open(control + "/log", "a") as handle:
    parent = open("/proc/%d/comm" % os.getppid()).read().strip()
    handle.write("compare %s parent=%s\n" % (user, parent))
word = open(control + "/compare").read().strip() if os.path.exists(control + "/compare") else "ok"
if word == "timeout":
    sys.exit(11)
if word == "hang":
    time.sleep(300)
if not os.path.exists(path):
    sys.exit(10)
models = json.load(open(path))
printed = open(control + "/certainty").read().strip() if os.path.exists(control + "/certainty") else "2.800"
if word != "silent":
    print("Certainty of winning frame: %s" % printed)
    print('Winning model: 0 ("%s")' % models[0]["label"])
sys.exit(0)
STUBCOMPARE
fi

reset_stub() { rm -f "$STUB"/add "$STUB"/compare "$STUB"/certainty "$STUB"/face; }
stub_add() { printf '%s\n' "$1" >"$STUB/add"; }
stub_compare() { printf '%s\n' "$1" >"$STUB/compare"; }
stub_face() { printf '%s\n' "$1" >"$STUB/face"; }

# --- driving a session -------------------------------------------------------

STORE=/var/lib/omarchy-face
PEOPLE=$STORE/people.json
MODELS=/usr/lib/security/howdy/models

session() { # session <name> <directive…>  -> the client's transcript
  local name=$1
  shift
  printf '%s\n' "$@" >"$LAB/script"
  python3 "$REPO/dev/enroll-client.py" "$LAB/script" -- "$ADMIN" enroll-session "$name" 2>&1
}

# A whole appearance in one go, for the sessions that are setting a scene rather
# than being the thing under test.
record() { # record <name> <label> <appearance> [new]
  local name=$1 label=$2 appearance=$3 new=${4:-}
  local directives=("await ready 30")
  [[ -n $new ]] && directives+=("send {\"cmd\":\"create\",\"label\":\"$label\"}")
  directives+=("send {\"cmd\":\"capture\",\"appearance\":\"$appearance\"}"
               "await captured 60"
               "send {\"cmd\":\"done\"}"
               "await saved 30")
  session "$name" "${directives[@]}"
}

fingerprint() { # every derived file and the summary, as content and mtime
  {
    for file in "$MODELS"/omarchy-face.*.dat "$PEOPLE"; do
      [[ -e $file ]] || continue
      printf '%s %s %s\n' "$(sha256sum <"$file" | cut -d' ' -f1)" \
        "$(stat -c '%y %a %U' "$file")" "$file"
    done
  } | sort
}

event_codes() { sed -n 's/^EV //p' | python3 -c '
import json, sys
for line in sys.stdin:
    doc = json.loads(line)
    event = doc.get("event")
    if event == "error" or (event is None and "error" in doc):
        print("error:" + doc.get("error", "?"), end=" ")
    else:
        print(event or "?", end=" ")
print()'; }

# One field of a JSON document, as JSON: `true`, not python`s True, and a string
# with its quotes, so an expectation reads like the contract does.
json_field() { python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    doc = doc[int(key)] if key.isdigit() else doc[key]
print(json.dumps(doc))' "$@"; }

json_from() { python3 -c '
import json, sys
doc = json.loads(sys.argv[1])
for key in sys.argv[2].split("."):
    doc = doc[int(key)] if key.isdigit() else doc[key]
print(json.dumps(doc))' "$@"; }

# =============================================================================

# The stub suite: every branch of the protocol, driven by an engine that can be
# told what to see. With the real engine in place these same steps would be
# asking a camera to produce "two faces in frame" on demand, so --real runs the
# section at the bottom instead.
if ((!REAL)); then

step "a session that commits (plan-merged.md §2.4)"
reset_stub
out=$(record "$ACCOUNT" "$ACCOUNT" "No glasses" new)
echo "${DIM}$(sed 's/^/  /' <<<"$out" | head -12)${RESET}"
same "ready, capturing, captured, saved" "ready capturing captured saved " "$(event_codes <<<"$out")"
same "the session exits 0" "EXIT 0" "$(grep '^EXIT' <<<"$out")"
check "the record is where §3.2 says" test -f "$STORE/people/$ACCOUNT.json"
same "the record is 0600 root:root" "600 root root" \
  "$(stat -c '%a %U %G' "$STORE/people/$ACCOUNT.json" 2>/dev/null)"
same "people/ is 0700" "700" "$(stat -c %a "$STORE/people" 2>/dev/null)"
same "the summary is 0644" "644" "$(stat -c %a "$PEOPLE" 2>/dev/null)"
same "the first person committed is the owner" "true" "$(json_field "$PEOPLE" people.0.owner)"
same "…with Sudo on" "true" "$(json_field "$PEOPLE" people.0.sudo)"
same "…and Lock off" "false" "$(json_field "$PEOPLE" people.0.lock)"
same "one sudo face" "1" "$(json_field "$PEOPLE" sudo_faces)"
same "no warning under four faces" "null" "$(json_field "$PEOPLE" warning)"
check "the summary carries no encodings" bash -c "! grep -q encoding $PEOPLE"
check "the sudo set exists" test -f "$MODELS/omarchy-face.sudo.$ACCOUNT.dat"
check "the lock set does not (empty sets are deleted, not written empty)" \
  test ! -e "$MODELS/omarchy-face.lock.$ACCOUNT.dat"
same "the derived set is 0600" "600" "$(stat -c %a "$MODELS/omarchy-face.sudo.$ACCOUNT.dat")"
same "…labelled <name>/<appearance> (E8 attribution)" "\"$ACCOUNT/No glasses\"" \
  "$(json_field "$MODELS/omarchy-face.sudo.$ACCOUNT.dat" 0.label)"
same "…holding exactly one encoding" "1" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))[0]["data"]))' "$MODELS/omarchy-face.sudo.$ACCOUNT.dat")"
same "…of 128 floats" "128" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))[0]["data"][0]))' "$MODELS/omarchy-face.sudo.$ACCOUNT.dat")"
check "the person set exists too" test -f "$MODELS/omarchy-face.person.$ACCOUNT.dat"
check "no enrolment debris is left" bash -c "! compgen -G '$MODELS/omarchy-face.enroll.*'"
if ((!REAL)); then
  same "capture ran howdy's add under timeout(1), with -y" "parent=timeout y=True" \
    "$(sed -n 's/^add .* \(parent=[a-z]*\) \(y=[A-Za-z]*\).*/\1 \2/p' "$STUB/log" | head -1)"
  same "…on a temp model of its own" "1" \
    "$(grep -c '^add omarchy-face\.enroll\.' "$STUB/log")"
  same "…and verified it with compare.py under timeout(1)" "parent=timeout" \
    "$(sed -n 's/^compare .* \(parent=[a-z]*\).*/\1/p' "$STUB/log" | head -1)"
fi

step "GATE: Esc before a capture writes nothing"
before=$(fingerprint)
before_records=$(ls "$STORE/people")
out=$(session anna "await ready 30" 'send {"cmd":"create","label":"Anna"}' "eof")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
same "closing stdin discards the session" "ready discarded " "$(event_codes <<<"$out")"
same "…and it still exits 0" "EXIT 0" "$(grep '^EXIT' <<<"$out")"
same "no record was written" "$before_records" "$(ls "$STORE/people")"
same "people.json and every derived file are untouched, bytes and mtime" \
  "$before" "$(fingerprint)"

step "GATE: the owner cannot be removed"
out=$("$ADMIN" remove-person "$ACCOUNT" 2>&1)
status=$?
same "remove-person on the owner is refused" '{"error":"is_owner"}' "$out"
same "…with exit 1" "1" "$status"
check "the owner's record is still there" test -f "$STORE/people/$ACCOUNT.json"
check "…and so is the sudo set" test -f "$MODELS/omarchy-face.sudo.$ACCOUNT.dat"

step "a second person, and the store's invariants"
reset_stub
stub_face 2
out=$(record anna Anna "Everyday glasses" new)
same "a second person commits" "ready capturing captured saved " "$(event_codes <<<"$out")"
same "…and is not the owner" "false" "$(json_field "$STORE/people/anna.json" owner)"
same "…with Sudo off" "false" "$(json_field "$STORE/people/anna.json" sudo)"
same "the owner is still listed first" "\"$ACCOUNT\"" "$(json_field "$PEOPLE" people.0.name)"

out=$(session anna "await ready 30" 'send {"cmd":"create","label":"Anna again"}' "await error 20")
same "create for a name already in the store → exists" "ready error:exists " "$(event_codes <<<"$out")"
same "…exit 1" "EXIT 1" "$(grep '^EXIT' <<<"$out")"

out=$(session "Anna" "await error 20")
same "a name that is not a slug → invalid_name, before ready" "error:invalid_name " "$(event_codes <<<"$out")"
out=$(session mia "await ready 30" 'send {"cmd":"capture","appearance":"No glasses"}' "await error 20")
same "a capture for a person nobody created → invalid_name" "ready error:invalid_name " "$(event_codes <<<"$out")"
out=$(session "long-label" "await ready 30" 'send {"cmd":"create","label":"'"$(printf 'x%.0s' {1..40})"'"}' "await error 20")
same "a label longer than labelRule → invalid_label" "ready error:invalid_label " "$(event_codes <<<"$out")"

step "three appearances is the most"
reset_stub
stub_face 2
record anna Anna "No glasses" >/dev/null
record anna Anna "Reading glasses" >/dev/null
same "three appearances" "3" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["appearances"]))' "$STORE/people/anna.json")"
out=$(session anna "await ready 30" 'send {"cmd":"capture","appearance":"Sunglasses"}' "await error 30")
same "a fourth label → appearance_limit" "ready error:appearance_limit " "$(event_codes <<<"$out")"
out=$(session anna "await ready 30" 'send {"cmd":"capture","appearance":"No glasses"}' "await captured 60" 'send {"cmd":"done"}' "await saved 30")
same "…but recording an existing label replaces it" "ready capturing captured saved " "$(event_codes <<<"$out")"
same "still three" "3" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["appearances"]))' "$STORE/people/anna.json")"

step "every way a capture can fail is retryable"
if ((REAL)); then
  note "skipped: the failure codes are driven by the stub engine"
else
  for word in no_face multiple_faces too_dark black_frames; do
    reset_stub
    stub_add "$word"
    out=$(session anna "await ready 30" 'send {"cmd":"capture","appearance":"No glasses"}' "await capture_failed 30" "eof")
    same "add's \"$word\" line → capture_failed $word" \
      "$word" "$(sed -n 's/^EV //p' <<<"$out" | python3 -c 'import json,sys
for line in sys.stdin:
    doc = json.loads(line)
    if doc.get("event") == "capture_failed": print(doc["code"])')"
  done
  reset_stub
  stub_compare timeout
  out=$(session anna "await ready 30" 'send {"cmd":"capture","appearance":"No glasses"}' "await capture_failed 30" "eof")
  same "a verification that never matched → capture_failed timeout" "ready capturing capture_failed discarded " \
    "$(event_codes <<<"$out")"
  reset_stub
  # The camera lock, held by somebody else for longer than the wait.
  flock -x /run/omarchy-face/camera.lock -c 'sleep 12' &
  holder=$!
  sleep 0.5
  out=$(session anna "await ready 30" 'send {"cmd":"capture","appearance":"No glasses"}' "await capture_failed 30" 'send {"cmd":"capture","appearance":"No glasses"}' "eof")
  kill $holder 2>/dev/null
  wait $holder 2>/dev/null
  same "a busy camera is a retryable capture_failed, never session-fatal" \
    "camera_busy" "$(sed -n 's/^EV //p' <<<"$out" | python3 -c 'import json,sys
for line in sys.stdin:
    doc = json.loads(line)
    if doc.get("event") == "capture_failed": print(doc["code"]); break')"
fi

step "a capture that failed, then one that worked, in one session"
reset_stub
stub_add no_face
out=$(session mia "await ready 30" 'send {"cmd":"create","label":"Mia"}' \
  'send {"cmd":"capture","appearance":"No glasses"}' "await capture_failed 30" "eof")
same "the first capture failed" "ready capturing capture_failed discarded " "$(event_codes <<<"$out")"
stub_add ok
stub_face 3
out=$(session mia "await ready 30" 'send {"cmd":"create","label":"Mia"}' \
  'send {"cmd":"capture","appearance":"No glasses"}' "await captured 60" \
  'send {"cmd":"done"}' "await saved 30")
same "the session carries on to a saved person" "ready capturing captured saved " "$(event_codes <<<"$out")"
same "three people now" "3" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["people"]))' "$PEOPLE")"

step "permissions, and the unwire rule (plan-engine.md §3.4)"
out=$("$ADMIN" set-permission mia sudo on 2>&1)
same "Sudo on for Mia" "true" "$(json_field "$STORE/people/mia.json" sudo)"
same "…and the sudo set grew to the owner's face plus hers" "2" "$(json_field "$PEOPLE" sudo_faces)"
same "…with no warning at two faces" "null" "$(json_field "$PEOPLE" warning)"
out=$("$ADMIN" set-permission anna sudo on 2>&1)
same "Anna's three appearances take it to five" "5" "$(json_field "$PEOPLE" sudo_faces)"
same "…so the summary carries a warning (§7: more faces, more false accepts)" "True" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["warning"] is not None)' "$PEOPLE")"
check "…naming the count, so the GUI invents nothing" \
  grep -q 'matches against 5 faces' "$PEOPLE"
out=$("$ADMIN" set-permission anna sudo off 2>&1)
out=$("$ADMIN" set-permission anna lock on 2>&1)
check "a lock set appears when somebody has Lock" test -f "$MODELS/omarchy-face.lock.$ACCOUNT.dat"
same "…with Anna's three appearances in it" "3" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$MODELS/omarchy-face.lock.$ACCOUNT.dat")"
out=$(printf '{"label":"Anna Marie"}' | "$ADMIN" set-label anna 2>&1)
same "set-label renames the display name" "\"Anna Marie\"" "$(json_field "$STORE/people/anna.json" label)"
same "…and never the name" "\"anna\"" "$(json_field "$STORE/people/anna.json" name)"
out=$(printf '{"label":"'"$(printf 'y%.0s' {1..40})"'"}' | "$ADMIN" set-label anna 2>&1)
same "a label over 32 characters is refused" '{"error":"invalid_label"}' "$out"

out=$(printf '{"appearance":"Reading glasses"}' | "$ADMIN" remove-appearance anna 2>&1)
same "remove-appearance takes one" "2" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["appearances"]))' "$STORE/people/anna.json")"
same "…and the lock set follows" "2" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$MODELS/omarchy-face.lock.$ACCOUNT.dat")"

out=$("$ADMIN" set-permission mia sudo off 2>&1)
out=$("$ADMIN" remove-person mia 2>&1)
same "a person who is not the owner can be removed" '{"ok":true,"removed":"mia","sudo_faces":1}' "$out"
check "…and their derived file goes with them" test ! -e "$MODELS/omarchy-face.person.mia.dat"
check "…while the others stay" test -f "$MODELS/omarchy-face.person.anna.dat"

step "unwiring sudo when the last face goes (config sudo=true)"
printf 'account=%s\nsudo=true\nlock=false\n' "$ACCOUNT" >/etc/omarchy-face/config
# The block phase 5 will insert, put there by the same function phase 5 calls --
# sourced out of this very helper, the way f1-round-trip.sh does it, so the
# unwire is tested against the real edit and not against a copy of it.
FACE_FN=pam_insert_block FACE_ARG=/etc/pam.d/sudo FACE_ADMIN=$ADMIN bash -c '
  set -- purge
  source <(sed -n "1,/^# --- the people store/p" "$FACE_ADMIN") >/dev/null
  "$FACE_FN" "$FACE_ARG"'
check "the sudo stack has Face's block" grep -q '^# omarchy-face begin$' /etc/pam.d/sudo
out=$("$ADMIN" set-permission "$ACCOUNT" sudo off 2>&1)
same "turning off the last Sudo face reports the unwire" "True" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("unwired") == "sudo")' "$out")"
check "…the block is gone from /etc/pam.d/sudo" bash -c "! grep -q omarchy-face /etc/pam.d/sudo"
same "…and the config says so" "sudo=false" "$(grep '^sudo=' /etc/omarchy-face/config)"
check "…and the sudo set was deleted" test ! -e "$MODELS/omarchy-face.sudo.$ACCOUNT.dat"

# And the same rule when the edit cannot be made. A block holding a line Face
# did not write is refused by pam_remove_block, which leaves the file exactly as
# it was -- so the caller must say so rather than claim an unwire and write
# sudo=false over a stack that still runs the verifier.
printf 'account=%s\nsudo=true\nlock=false\n' "$ACCOUNT" >/etc/omarchy-face/config
"$ADMIN" set-permission "$ACCOUNT" sudo on >/dev/null 2>&1
FACE_FN=pam_insert_block FACE_ARG=/etc/pam.d/sudo FACE_ADMIN=$ADMIN bash -c '
  set -- purge
  source <(sed -n "1,/^# --- the people store/p" "$FACE_ADMIN") >/dev/null
  "$FACE_FN" "$FACE_ARG"'
sed -i "/^# omarchy-face begin\$/a auth  required  pam_permit.so" /etc/pam.d/sudo
out=$("$ADMIN" set-permission "$ACCOUNT" sudo off 2>&1)
same "a refused PAM edit is reported, not swallowed" "pam_edit_failed" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("error"))' "$out")"
same "…and the unwire is never claimed" "failed" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("unwired"))' "$out")"
same "…so the config still says sudo is on" "sudo=true" "$(grep '^sudo=' /etc/omarchy-face/config)"
check "…and the stack is untouched" grep -q '^auth  required  pam_permit.so$' /etc/pam.d/sudo
# Back to the stack and the config the rest of the run expects.
sed -i '/^auth  required  pam_permit.so$/d' /etc/pam.d/sudo
FACE_FN=pam_remove_block FACE_ARG=/etc/pam.d/sudo FACE_ADMIN=$ADMIN bash -c '
  set -- purge
  source <(sed -n "1,/^# --- the people store/p" "$FACE_ADMIN") >/dev/null
  "$FACE_FN" "$FACE_ARG"'
printf 'account=%s\nsudo=false\nlock=false\n' "$ACCOUNT" >/etc/omarchy-face/config
"$ADMIN" set-permission "$ACCOUNT" sudo on >/dev/null 2>&1

step "GATE: names in argv are validated (plan-merged.md §2 rule 4)"
for bad in "Anna" "2-kids" "anna_marie" "" "$(printf 'a%.0s' {1..30})" "../etc"; do
  out=$("$ADMIN" set-permission "$bad" sudo on 2>&1)
  same "set-permission refuses '${bad:0:12}'" '{"error":"invalid_name"}' "$out"
done
out=$("$ADMIN" remove-person "anna;rm" 2>&1)
same "remove-person refuses a name with a semicolon" '{"error":"invalid_name"}' "$out"

step "regenerate is a function of people/*.json alone"
"$ADMIN" regenerate >/dev/null 2>&1
first=$(fingerprint | cut -d' ' -f1 | tr '\n' ' ')
sleep 1.1
out=$("$ADMIN" regenerate 2>&1)
same "regenerate answers ok" "True" "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["ok"])' "$out")"
same "…twice over, byte-identical" "$first" "$(fingerprint | cut -d' ' -f1 | tr '\n' ' ')"

step "GATE: a corrupt record returns store_corrupt and touches nothing"
before=$(fingerprint)
cp "$STORE/people/anna.json" "$LAB/anna.json"
head -c 60 "$LAB/anna.json" >"$STORE/people/anna.json"
out=$("$ADMIN" regenerate 2>&1)
status=$?
same "regenerate → store_corrupt" "store_corrupt" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["error"])' "$out")"
same "…naming the file" "$STORE/people/anna.json" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["file"])' "$out")"
same "…exit 1" "1" "$status"
same "every derived set is untouched, bytes and mtime" "$before" "$(fingerprint)"
out=$("$ADMIN" set-permission "$ACCOUNT" lock on 2>&1)
same "…and no other verb will write over it either" "store_corrupt" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["error"])' "$out")"
out=$(session anna "await error 20")
same "…including a session, which says so before ready" "error:store_corrupt " "$(event_codes <<<"$out")"
same "still untouched" "$before" "$(fingerprint)"
cp "$LAB/anna.json" "$STORE/people/anna.json"
"$ADMIN" regenerate >/dev/null 2>&1
check "…and a repaired store regenerates again" test -f "$MODELS/omarchy-face.person.anna.dat"

step "a record that lies about its own name, and other corruptions"
python3 - "$STORE/people/anna.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["name"] = "someone-else"
json.dump(doc, open(sys.argv[1], "w"))
PY
out=$("$ADMIN" regenerate 2>&1)
same "a record stored under another name is corrupt" "store_corrupt" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["error"])' "$out")"
python3 - "$STORE/people/anna.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["name"] = "anna"
doc["appearances"][0]["encoding"] = doc["appearances"][0]["encoding"][:64]
json.dump(doc, open(sys.argv[1], "w"))
PY
out=$("$ADMIN" regenerate 2>&1)
same "an encoding that is not 128 floats is corrupt" "store_corrupt" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["error"])' "$out")"
cp "$LAB/anna.json" "$STORE/people/anna.json"
python3 - "$STORE/people/second-owner.json" <<'PY'
import json, sys, time
json.dump({"name": "second-owner", "label": "Second", "owner": True, "sudo": False,
           "lock": False, "created": int(time.time()), "appearances": []},
          open(sys.argv[1], "w"))
PY
out=$("$ADMIN" regenerate 2>&1)
same "two owners is corrupt" "store_corrupt" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["error"])' "$out")"
rm -f "$STORE/people/second-owner.json"
"$ADMIN" regenerate >/dev/null 2>&1

step "debris and orphans"
touch "$MODELS/omarchy-face.person.ghost.dat"
: >"$MODELS/omarchy-face.enroll.deadbeef.dat"
touch -d '30 minutes ago' "$MODELS/omarchy-face.enroll.deadbeef.dat"
: >"$MODELS/omarchy-face.enroll.fresh.dat"
"$ADMIN" regenerate >/dev/null 2>&1
check "a derived file with no record behind it is deleted" test ! -e "$MODELS/omarchy-face.person.ghost.dat"
check "enrolment debris older than ten minutes is swept" test ! -e "$MODELS/omarchy-face.enroll.deadbeef.dat"
check "…and a session's own temp model is left alone" test -e "$MODELS/omarchy-face.enroll.fresh.dat"
rm -f "$MODELS/omarchy-face.enroll.fresh.dat"

step "the person limit"
reset_stub
existing=$(ls "$STORE/people" | wc -l)
for index in $(seq 1 $((16 - existing))); do
  python3 - "$STORE/people/filler$index.json" "filler$index" <<'PY'
import json, sys, time
json.dump({"name": sys.argv[2], "label": "Filler " + sys.argv[2][-2:], "owner": False,
           "sudo": False, "lock": False, "created": int(time.time()), "appearances": []},
          open(sys.argv[1], "w"))
PY
done
out=$(session "one-too-many" "await error 20")
same "a seventeenth person → person_limit" "error:person_limit " "$(event_codes <<<"$out")"
rm -f "$STORE"/people/filler*.json
"$ADMIN" regenerate >/dev/null 2>&1

step "the caller check still applies to every new verb"
other=$(awk -F: '$3 > 1000 && $3 != '"$(id -u "$ACCOUNT" 2>/dev/null || echo 1000)"' {print $3; exit}' /etc/passwd)
: "${other:=65534}"
for verb in enroll-session set-label remove-person regenerate; do
  out=$(PKEXEC_UID=$other "$ADMIN" "$verb" anna 2>&1 </dev/null)
  same "$verb from another uid → not_owner" '{"error":"not_owner"}' "$(head -1 <<<"$out")"
done

# The three below are about what a session does when nobody is driving it and
# what it does when the store moved underneath it (plan-engine.md §12 risk 9,
# §3.2). They are last because the third one empties the store.

step "GATE: a session does not stay authorised for ever (risk 9)"
reset_stub
stub_face 2
before=$(fingerprint)
# The real deadline is two minutes; the helper takes an override that can only
# make it shorter, so the gate watches the same code path in three seconds.
export OMARCHY_FACE_SESSION_SECONDS=3
started=$(date +%s)
out=$(session anna "await ready 30" 'send {"cmd":"capture","appearance":"No glasses"}' \
  "await captured 60" "await discarded 40")
elapsed=$(( $(date +%s) - started ))
unset OMARCHY_FACE_SESSION_SECONDS
echo "${DIM}$(sed 's/^/  /' <<<"$out" | head -8)${RESET}"
same "a session nobody drives expires and discards" "ready capturing captured discarded " \
  "$(event_codes <<<"$out")"
same "…exiting 0, like the EOF cancel it is" "EXIT 0" "$(grep '^EXIT' <<<"$out")"
check "…within its deadline" test "$elapsed" -lt 30
same "…and the capture it was holding is NOT committed" "$before" "$(fingerprint)"

step "GATE: a person removed mid-session is not brought back by the commit"
reset_stub
stub_face 5
record bob Bob "No glasses" new >/dev/null
check "Bob is in the store" test -f "$STORE/people/bob.json"
( sleep 2; "$ADMIN" remove-person bob >/dev/null 2>&1 ) &
remover=$!
out=$(session bob "await ready 30" 'send {"cmd":"capture","appearance":"Everyday glasses"}' \
  "await captured 60" "sleep 3" 'send {"cmd":"done"}' "await error 30")
wait $remover 2>/dev/null
same "the commit refuses rather than re-appending what ready read" "ready capturing captured error:no_person " \
  "$(event_codes <<<"$out")"
check "…and Bob stays removed" test ! -e "$STORE/people/bob.json"
check "…derived set and all" test ! -e "$MODELS/omarchy-face.person.bob.dat"

step "GATE: two first-time sessions cannot both become the owner"
rm -f "$STORE"/people/*.json
"$ADMIN" regenerate >/dev/null 2>&1
reset_stub
stub_face 6
# One session opens against an empty store and holds. A whole second session
# commits inside that window, so the first one's pre-lock read ("nobody is
# here, I am the owner") is stale by the time it takes the lock.
( sleep 2; stub_face 7; record two Two "No glasses" new >/dev/null 2>&1 ) &
racer=$!
out=$(session one "await ready 30" 'send {"cmd":"create","label":"One"}' "sleep 5" \
  'send {"cmd":"capture","appearance":"No glasses"}' "await captured 60" \
  'send {"cmd":"done"}' "await saved 30")
wait $racer 2>/dev/null
same "the session that lost the race still commits" "ready capturing captured saved " \
  "$(event_codes <<<"$out")"
same "…as an ordinary person" "false" "$(json_field "$STORE/people/one.json" owner)"
same "…without Sudo" "false" "$(json_field "$STORE/people/one.json" sudo)"
same "the store has exactly one owner" "1" \
  "$(python3 -c 'import json,sys; print(sum(1 for p in json.load(open(sys.argv[1]))["people"] if p["owner"]))' "$PEOPLE")"
same "…and it is the one that committed first" "\"two\"" "$(json_field "$PEOPLE" people.0.name)"
out=$("$ADMIN" regenerate 2>&1)
same "…so the store is not corrupt" "True" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["ok"])' "$out")"

fi   # end of the stub suite

# --- the real engine ----------------------------------------------------------

if ((REAL)); then
  step "the real engine, the real infrared camera"
  note "look at the camera: this records a face into the sandbox's tmpfs"
  rm -rf "$STORE/people"/*.json
  "$ADMIN" regenerate >/dev/null 2>&1

  # Is the sensor giving anything at all? A Windows Hello camera whose infrared
  # emitter is never triggered streams perfectly valid all-black frames, and the
  # only symptom further down is `black_frames` on every capture.
  frames=$(python3 - "$ir" <<'PYCAM'
import sys
import cv2, numpy
capture = cv2.VideoCapture(sys.argv[1], cv2.CAP_V4L2)
brightest = 0.0
for _ in range(30):
    ok, frame = capture.read()
    if ok:
        brightest = max(brightest, float(numpy.mean(frame)))
capture.release()
print("%.2f" % brightest)
PYCAM
)
  if [[ ${frames%%.*} -lt 1 ]]; then
    note "the infrared sensor is streaming BLACK frames (brightest mean $frames)"
    note "the emitter is not being driven on this machine -- no face can be recorded"
    note "until it is (linux-enable-ir-emitter or similar)"
  fi

  out=$(session "$ACCOUNT" "await ready 30" \
    "send {\"cmd\":\"create\",\"label\":\"$ACCOUNT\"}" \
    'send {"cmd":"capture","appearance":"No glasses"}' \
    "awaitany captured,capture_failed 60" \
    'send {"cmd":"done"}' \
    "awaitany saved,discarded 30")
  echo "${DIM}$(sed 's/^/  /' <<<"$out" | head -20)${RESET}"
  captured=$(sed -n 's/^EV //p' <<<"$out" | python3 -c '
import json, sys
for line in sys.stdin:
    doc = json.loads(line)
    if doc.get("event") == "captured":
        print("%.4f %.4f %s" % (doc["certainty"], doc["threshold"], doc["weak"]))
    if doc.get("event") == "capture_failed":
        print("failed " + doc["code"])')
  if [[ $captured == failed* ]]; then
    # Still evidence: the code in the event is add.py's own answer, mapped by
    # the engine rather than invented by it (add.py:166-179).
    same "a capture that found nothing is a retryable capture_failed" "true" \
      "$(python3 -c 'import sys; print(str(sys.argv[1].split()[1] in ("no_face", "multiple_faces", "too_dark", "black_frames")).lower())' "$captured")"
    same "…and the session ended on its own terms, not by being killed" "discarded" \
      "$(sed -n 's/^EV //p' <<<"$out" | python3 -c '
import json, sys
last = [json.loads(line) for line in sys.stdin][-1]
print(last.get("event"))')"
    note "the camera did not get a face: $captured — rerun with a face in view"
  else
    same "a real capture reports certainty on the 0-1 scale" "ok" \
      "$(python3 -c 'import sys; c=float(sys.argv[1].split()[0]); print("ok" if 0 < c < 1 else c)' "$captured")"
    same "…against howdy's threshold from config.ini" "0.35" \
      "$(python3 -c 'import sys; print("%.2f" % float(sys.argv[1].split()[1]))' "$captured")"
    check "E8: compare.py named the winning model" grep -q 'Winning model' <<<"$out"
    same "…and it is <name>/<appearance>" "\"$ACCOUNT/No glasses\"" \
      "$(sed -n 's/.*Winning model: [0-9]* (\(.*\))/\1/p' <<<"$out" | head -1)"
    printed=$(sed -n 's/.*Certainty of winning frame: \([0-9.]*\).*/\1/p' <<<"$out" | head -1)
    if [[ -n $printed ]]; then
      same "…and the printed certainty is ten times the JSON one (rule 8)" "ok" \
        "$(python3 -c 'import sys
printed, json_value = float(sys.argv[1]), float(sys.argv[2].split()[0])
print("ok" if abs(printed / 10 - json_value) < 0.0005 else "%s vs %s" % (printed, json_value))' \
          "$printed" "$captured")"
    fi
  fi
fi

if ((MEASURE)); then
  step "3/6/9 encodings: does a bigger sudo set cost search time? (§7)"
  python3 "$REPO/dev/f3-measure.py" || failures=$((failures + 1))
fi

# =============================================================================

echo
if ((failures == 0)); then
  echo "${GREEN}$checks checks, all passed${RESET}"
else
  echo "${RED}$checks checks, $failures failed${RESET}"
fi
exit $((failures > 0))
