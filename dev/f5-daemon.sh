#!/bin/bash

# F5: omarchy-faced and omarchy-face-identity (plan-merged.md §4 phase 6,
# plan-engine.md §6).
#
#   ./dev/f5-daemon.sh
#
# This phase adds the one thing Face did not have before: a **listening socket
# any local process can connect to**, answered by a root daemon that opens the
# infrared camera. So the suite is written around the three properties that make
# that safe rather than around the happy path:
#
#   peer credentials   a connection whose uid is not the config account's is
#                      refused before the request is even read, and costs no
#                      camera, no rate-limit slot and no fork
#   draining           every exit path accepts what is pending first, because a
#                      connection left in the backlog re-activates the unit,
#                      and a loop of those puts the SOCKET into `failed` --
#                      which any local user could do and only root could undo
#   hangup             a client that goes away takes compare.py with it within
#                      300 ms, camera lock included (plan-merged.md §2.5)
#
# systemd is not reachable from the sandbox (/run is a tmpfs of our own), so
# `Accept=no` activation is played by dev/socket-activate.py, which does exactly
# what systemd does: it holds the listening socket, starts the daemon with it on
# fd 3 when a connection arrives, and starts it again for the next one. That is
# what lets idle-exit and re-activation be tested here at all -- and what it
# cannot say is whether the shipped unit files are right, which is the live
# check at the foot of this file.
#
# The engine is stubbed, as in f3-people-store.sh: a compare.py stand-in in
# howdy's own output shape that can be told to match, miss, time out, go dark or
# hang for ever. On this machine the IR emitter is not driven, so a real check
# ends in `black_frames` whatever the face in front of it -- the stub is what
# lets the branches be tested at all, and a real match still needs the live run.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

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

under() { # under <description> <limit ms> <actual ms>
  checks=$((checks + 1))
  if (($3 <= $2)); then
    echo "  ${GREEN}pass${RESET}  $1 ${DIM}(${3} ms)${RESET}"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}(${3} ms, limit ${2} ms)${RESET}"
    failures=$((failures + 1))
  fi
}

note() { echo "  ${YELLOW}note${RESET}  $*"; }
step() { echo; echo "${DIM}== $*${RESET}"; }

# --- the sandbox -------------------------------------------------------------

if [[ ${OMARCHY_FACE_F5_IN_NS:-0} != 1 ]]; then
  command -v unshare >/dev/null || { echo "unshare is not installed" >&2; exit 1; }
  exec env OMARCHY_FACE_F5_IN_NS=1 OMARCHY_FACE_F5_ACCOUNT="$ACCOUNT" \
    unshare --map-root-user --mount --pid --fork "$BASH" "$0" "$@"
fi

ACCOUNT=${OMARCHY_FACE_F5_ACCOUNT:-$ACCOUNT}

# /etc, with everything but Face's own directory pointing back at the real one.
mount --bind /etc /mnt || exit 1
mount -t tmpfs tmpfs /etc || exit 1
chmod 0755 /etc
for real in /mnt/*; do ln -s "$real" "/etc/${real#/mnt/}"; done
rm -f /etc/omarchy-face 2>/dev/null
mkdir -p /etc/omarchy-face

mount -t tmpfs tmpfs /run || exit 1
chmod 0755 /run
# The pid namespace needs its own /proc, or a process cannot read its own
# children -- and the lid check below is a read of /proc that has to be fakeable.
mount -t proc proc /proc 2>/dev/null

mkdir -p /run/real-var-lib
mount --bind /var/lib /run/real-var-lib || exit 1
mount -t tmpfs tmpfs /var/lib || exit 1
chmod 0755 /var/lib
for real in /run/real-var-lib/*; do ln -s "$real" "/var/lib/${real#/run/real-var-lib/}"; done

mount -t tmpfs tmpfs /usr/lib/security || exit 1
chmod 0755 /usr/lib/security
mkdir -p /usr/lib/security/howdy/models
chmod 0755 /usr/lib/security/howdy
chmod 0700 /usr/lib/security/howdy/models

mount -t tmpfs tmpfs /usr/local || exit 1
chmod 0755 /usr/local
mkdir -p /usr/local/bin
chmod 0755 /usr/local/bin

RUN=/run/omarchy-face
SOCK=$RUN/verify.sock
STUB=/run/omarchy-face-stub
MODELS=/usr/lib/security/howdy/models
STORE=/var/lib/omarchy-face
LAB=$(mktemp -d /run/f5.XXXXXX)
mkdir -p "$RUN" "$STUB" "$STORE"
chmod 0755 "$RUN"

echo "F5 — the daemon and the Profiles client (plan-merged.md §4 phase 6)"
echo "${DIM}sandbox: uid $(id -u), /etc /run /var/lib /usr/lib/security /usr/local are private${RESET}"

# The shipped helpers, installed the way the installer installs them.
install -o root -g root -m 0755 "$REPO/system/omarchy-faced" /usr/local/bin/
install -o root -g root -m 0755 "$REPO/system/omarchy-face-identity" /usr/local/bin/
install -o root -g root -m 0755 "$REPO/system/omarchy-face-lock-verify" /usr/local/bin/

# The config. `account=root` looks odd and is deliberate: inside this namespace
# the process running the tests IS uid 0, and the daemon's rule is "the caller's
# uid must be the config account's uid". Naming the account whose uid is ours is
# how the ALLOWED case is expressed here; the refusal case below names an
# account whose uid is not, which is the same check answering the other way.
# On a real machine the installer refuses root (plan-engine.md §5.1).
write_config() { # write_config <account> <lock>
  printf 'account=%s\nsudo=false\nlock=%s\n' "$1" "$2" >/etc/omarchy-face/config
}
write_config root false

# --- the stub engine ---------------------------------------------------------

cat >/usr/local/bin/omarchy-face-camera <<'CAMERA'
#!/bin/bash
# Stand-in for the camera helper: the real one reads /sys, which the sandbox
# cannot fake, and the daemon only wants to know whether there is an infrared
# node at all. /dev/null is a character device, which is what its check asks.
[[ -e /run/omarchy-face-stub/no-camera ]] && exit 1
case ${1:-} in
  --ir-node) echo /dev/null ;;
  *) echo '{"ir":"/dev/null","rgb":null}' ;;
esac
exit 0
CAMERA
chmod 0755 /usr/local/bin/omarchy-face-camera

cat >/usr/lib/security/howdy/compare.py <<'COMPARE'
import json, os, sys, time
# The stand-in for compare.py, printing the two lines the engine reads
# (compare.py:277 and :279) on howdy's own x10 scale.
control = "/run/omarchy-face-stub"
model = sys.argv[1]
path = os.path.abspath(__file__ + "/../models/" + model + ".dat")
with open(control + "/log", "a") as handle:
    handle.write("compare %s pid=%d ppid=%d\n" % (model, os.getpid(), os.getppid()))
word = open(control + "/compare").read().strip() if os.path.exists(control + "/compare") else "ok"
if word == "hang":
    # The case the client-hangup poll exists for: an engine that will never
    # answer on its own, so the only thing that can end it is the daemon.
    time.sleep(300)
if word == "timeout":
    sys.exit(11)
if word == "dark":
    sys.exit(12)
if word == "no_match":
    sys.exit(1)
if word == "slow":
    time.sleep(3)
if not os.path.exists(path):
    sys.exit(10)
models = json.load(open(path))
print("Certainty of winning frame: 2.800")
print('Winning model: 0 ("%s")' % models[0]["label"])
sys.exit(0)
COMPARE

stub() { printf '%s\n' "$1" >"$STUB/compare"; }
stub ok

# --- the store ---------------------------------------------------------------
#
# people.json is the world-readable summary the client reads; the .dat files are
# the derived sets the daemon reads. `cal` is in the summary with no model, which
# is what a person with no appearances looks like.

cat >"$STORE/people.json" <<'PEOPLE'
{"people":[
  {"name":"anna","label":"Anna","owner":true,"sudo":true,"lock":true,
   "appearances":[{"label":"Everyday glasses","time":1789400000}]},
  {"name":"bo","label":"Bo","owner":false,"sudo":false,"lock":false,
   "appearances":[{"label":"No glasses","time":1789400001}]},
  {"name":"cal","label":"Cal","owner":false,"sudo":false,"lock":false,
   "appearances":[]}],
 "sudo_faces":1,"lock_faces":1,"maxAppearances":3,
 "nameRule":"^[a-z][a-z0-9-]{0,23}$","labelRule":"^[^\\u0000-\\u001f\\u007f]{1,32}$",
 "warning":null,"updated":1789400001}
PEOPLE
chmod 0644 "$STORE/people.json"

model_file() { # model_file <model name> <label>
  printf '[{"time":1789400000,"label":"%s","id":0,"data":[[0.1]]}]\n' "$2" >"$MODELS/$1.dat"
  chmod 0600 "$MODELS/$1.dat"
}
model_file omarchy-face.person.anna "anna/Everyday glasses"
model_file omarchy-face.person.bo "bo/No glasses"

# --- driving it --------------------------------------------------------------

ACTIVATOR_LOG=$LAB/activator.log

start_daemon() {
  python3 "$REPO/dev/socket-activate.py" "$SOCK" /usr/local/bin/omarchy-faced \
    >"$LAB/activator.out" 2>"$ACTIVATOR_LOG" &
  ACTIVATOR=$!
  for _ in $(seq 1 50); do
    [[ -S $SOCK ]] && return 0
    sleep 0.1
  done
  return 1
}

stop_daemon() {
  [[ -n ${ACTIVATOR:-} ]] || return 0
  kill "$ACTIVATOR" 2>/dev/null
  wait "$ACTIVATOR" 2>/dev/null
  ACTIVATOR=""
  rm -f "$SOCK"
}

# Every check starts with a clean budget unless the test IS the budget: the
# daemon enforces two seconds between checks, and a suite that did not reset it
# would be testing the rate limit in every case by accident.
reset_rate() { rm -f "$RUN"/identity-attempts.*; }

identity() { # identity <args…> -> exit code
  /usr/local/bin/omarchy-face-identity "$@" >"$LAB/out" 2>"$LAB/err"
  echo $?
}

say() { # say <request> [extra args…]
  python3 "$REPO/dev/socket-say.py" "$SOCK" "$@" 2>&1
}

ms_now() { date +%s%3N; }

compare_runs() {
  local count
  count=$(grep -c '^compare ' "$STUB/log" 2>/dev/null)
  [[ $count =~ ^[0-9]+$ ]] || count=0
  printf '%s' "$count"
}
reset_log() { : >"$STUB/log"; }

# The daemon's own pid, from the activator's log. `pgrep -f omarchy-faced` would
# find the activator too -- its argv ends in the same path -- and TERMing the
# wrong one is a test that proves nothing while looking like it passed.
daemon_pid() { sed -n 's/^ACTIVATOR pid //p' "$ACTIVATOR_LOG" | tail -1; }

camera_free() { flock -n "$RUN/camera.lock" true; }

compare_alive() { pgrep -f 'compare\.py' >/dev/null 2>&1; }

trap 'stop_daemon; rm -rf "$LAB"' EXIT

start_daemon || { echo "  ${RED}FAIL${RESET}  the activator never created the socket"; exit 1; }

# =============================================================================
step "the contract's own shape (plan-engine.md §6.4 tests 1 and 2)"
# =============================================================================

reset_rate; reset_log
same "list is people.json's names, in order" "anna bo cal" "$(/usr/local/bin/omarchy-face-identity list | tr '\n' ' ' | sed 's/ $//')"
same "…and exit 0" "0" "$(identity list)"

same "verify of a person in front of the camera is 0" "0" "$(identity verify anna)"
same "…and it really asked the engine" "1" "$(compare_runs)"

reset_rate; reset_log; stub no_match
same "an empty chair is 1, not 'unavailable'" "1" "$(identity verify anna)"
reset_rate; stub timeout
same "an engine that timed out is also 1" "1" "$(identity verify anna)"
reset_rate; stub dark
same "…and a frame too dark to read" "1" "$(identity verify anna)"
stub ok

reset_rate; reset_log
same "a name that is not a name at all is 2" "2" "$(identity verify 'Anna!')"
same "…and costs no camera" "0" "$(compare_runs)"
same "a name nobody has is 2" "2" "$(identity verify nobody)"
same "a person with no appearances is 2 — there is nothing to compare against" \
  "2" "$(identity verify cal)"
same "…still with no camera" "0" "$(compare_runs)"
same "a verb this file does not have is 2" "2" "$(identity frobnicate anna)"

# =============================================================================
step "GATE: peer credentials, before anything real (plan-engine.md §6.2)"
# =============================================================================

# The daemon's rule is about the CALLER's uid. Naming an account whose uid is
# not this process's is the refusal case: on a real machine that is any other
# local account connecting to a 0666 socket.
reset_rate; reset_log
write_config "$ACCOUNT" false
same "a connection from another uid is refused by the protocol" "NO not_allowed" \
  "$(say 'VERIFY-PERSON anna')"
same "…before the request is even relevant: an unparseable one is refused too" \
  "NO not_allowed" "$(say 'GIVE-ME-ROOT')"
same "…and the client reports it as 'cannot check', never as 'not that person'" \
  "3" "$(identity verify anna)"
same "…with no camera work at all" "0" "$(compare_runs)"
check "…and no rate-limit slot spent" test ! -e "$RUN/identity-attempts.0"
check "…and the camera lock untouched" camera_free

write_config root false
reset_rate; reset_log
same "the account's own uid is served" "OK anna" "$(say 'VERIFY-PERSON anna')"

# =============================================================================
step "GATE: a closed lid (plan-engine.md §6.2, §6.4 test 7)"
# =============================================================================

if [[ -e /proc/acpi/button/lid/LID0/state ]]; then
  printf 'state:      closed\n' >"$LAB/lid-closed"
  if mount --bind "$LAB/lid-closed" /proc/acpi/button/lid/LID0/state 2>/dev/null; then
    reset_rate; reset_log
    started=$(ms_now)
    code=$(identity verify anna)
    elapsed=$(( $(ms_now) - started ))
    same "a closed lid is 'cannot check right now', not 'not present'" "3" "$code"
    under "…answered without waiting for a camera" 900 "$elapsed"
    same "…with no engine run" "0" "$(compare_runs)"
    check "…no rate-limit slot spent" test ! -e "$RUN/identity-attempts.0"
    check "…and the camera lock never taken" camera_free
    same "…and the raw answer is the plan's reason" "NO lid_closed" "$(say 'VERIFY-PERSON anna')"
    umount /proc/acpi/button/lid/LID0/state
  else
    note "could not bind over /proc/acpi/button/lid — lid check not exercised"
  fi
else
  note "no /proc/acpi/button/lid on this machine — lid check not exercised"
fi

reset_rate; reset_log
same "an open lid is not in the way" "0" "$(identity verify anna)"

# =============================================================================
step "GATE: the rate limit, and exit 4 (plan-engine.md §6.2, §6.4 test 4)"
# =============================================================================

reset_rate; reset_log
same "the first check goes through" "0" "$(identity verify anna)"
same "a second one straight away is 4 — try again in a moment" "4" "$(identity verify anna)"
same "…and it cost no second engine run" "1" "$(compare_runs)"
same "…the raw reason being the plan's" "NO rate_limited" "$(say 'VERIFY-PERSON anna')"
sleep 2.1
same "two seconds later it is allowed again" "0" "$(identity verify anna)"

step "two at once (§6.4 test 4: one exits 4, never two compares)"
reset_rate; reset_log; stub slow
identity verify anna >"$LAB/a" 2>&1 &
first=$!
sleep 0.2
second=$(identity verify anna)
wait "$first"
same "the second of two parallel checks is 4" "4" "$second"
same "…and only one of them reached the engine" "1" "$(compare_runs)"
stub ok

step "the ten-minute ceiling"
reset_rate; reset_log
# Twenty starts in the window, written the way the daemon writes them, with the
# last one far enough back that the two-second rule is not what refuses.
: >"$RUN/identity-attempts.0"
boot=$(awk '{print $1}' /proc/uptime)
for index in $(seq 1 20); do
  stamp=$(awk -v b="$boot" -v i="$index" 'BEGIN{printf "%.3f", b - 100 - i}')
  printf '%s %s\n' "$stamp" "$stamp" >>"$RUN/identity-attempts.0"
done
same "the twenty-first check in ten minutes is refused" "4" "$(identity verify anna)"
same "…without asking the camera" "0" "$(compare_runs)"
reset_rate

# =============================================================================
step "GATE: the camera is one thing at a time (§6.2)"
# =============================================================================

reset_rate; reset_log
# Somebody else holding the lock is the sudo verifier or an enrol capture. The
# daemon waits two seconds for it and then says so.
flock "$RUN/camera.lock" -c 'sleep 4' &
holder=$!
sleep 0.3
same "a busy camera is 4, not a failed check" "4" "$(identity verify anna)"
same "…and the engine was never started" "0" "$(compare_runs)"
wait "$holder" 2>/dev/null
check "…and the lock is free again afterwards" camera_free

reset_rate; reset_log
same "no infrared camera at all is 'cannot check'" "3" \
  "$(touch "$STUB/no-camera"; identity verify anna)"
rm -f "$STUB/no-camera"

step "the engine holds the camera lock itself (review F9)"
# The lock fd is handed to compare.py the way the sudo verifier hands down its
# fd 9. It matters for the one state no signal ends: a V4L ioctl stuck in the
# kernel. If the lock lived only in the daemon, killing the daemon would report
# the camera FREE while the sensor was still open -- and the next caller, or
# sudo, would be told to go ahead into nothing. Killing the daemon outright is
# how that is asked here, because a D state cannot be arranged on demand.
reset_rate; reset_log; stub hang
say 'VERIFY-PERSON anna' >"$LAB/orphan" 2>&1 &
orphan=$!
for _ in $(seq 1 60); do camera_free || break; sleep 0.05; done
victim=$(daemon_pid)
kill -KILL "$victim" 2>/dev/null
sleep 0.3
check "the daemon is gone" bash -c "! kill -0 $victim 2>/dev/null"
check "…the engine it started is not" compare_alive
check "…and the camera still reads as taken, because it still is" \
  bash -c '! flock -n /run/omarchy-face/camera.lock true'
pkill -KILL -f 'compare\.py' 2>/dev/null
kill "$orphan" 2>/dev/null
wait "$orphan" 2>/dev/null
sleep 0.2
check "…and free once the engine really has gone" camera_free
stub ok

step "an engine the backstop had to stop is a timeout, not a stranger (review F4)"
# `timeout -k 2 8` exits 124 when it had to signal the engine. Reporting that as
# `no_match` would put "Did not recognise Anna" on a card about a camera that
# hung, and tell Profiles the person was absent when nothing ever looked.
reset_rate; reset_log; stub hang
same "the backstop's answer is timeout" "NO timeout" "$(say 'VERIFY-PERSON anna')"
same "…which the client reports as 'the check said no'" "failed" \
  "$(python3 -c 'import json; print(json.load(open("/run/omarchy-face/state.json"))["state"])' 2>/dev/null)"
stub ok

# =============================================================================
step "GATE: a client that goes away (§6.4 test 3, plan-merged.md §2.5)"
# =============================================================================

reset_rate; reset_log; stub hang
say 'VERIFY-PERSON anna' --hangup-after 1 >"$LAB/hangup" 2>&1 &
hangup=$!
sleep 0.6
check "the engine is running while the client is there" compare_alive
check "…holding the camera while it does" bash -c '! flock -n /run/omarchy-face/camera.lock true'
# The client closes its socket at one second and exits immediately after, so
# waiting for it IS waiting for the hangup. From there the daemon's poll has
# 300 ms to notice, kill the process group and let go of the camera.
wait "$hangup" 2>/dev/null
gone=999
freed=999
started=$(ms_now)
for _ in $(seq 1 60); do
  if ! compare_alive; then gone=$(( $(ms_now) - started )); break; fi
  sleep 0.01
done
for _ in $(seq 1 60); do
  if camera_free; then freed=$(( $(ms_now) - started )); break; fi
  sleep 0.01
done
check "a client that went away takes compare.py with it" test "$gone" -ge 0
under "…within the 300 ms the Profiles contract promises" 300 "$gone"
under "…and the camera lock with it" 300 "$freed"
check "…leaving nothing of the engine behind" bash -c '! pgrep -f "compare\.py" >/dev/null'
same "…and the indicator is told to say nothing, not 'not recognised'" "skipped" \
  "$(python3 -c 'import json,sys; print(json.load(open("/run/omarchy-face/state.json"))["state"])' 2>/dev/null)"
stub ok

# =============================================================================
step "the state document the indicator draws (plan-merged.md §2.6)"
# =============================================================================

reset_rate; reset_log
identity verify anna >/dev/null 2>&1
state=$(cat "$RUN/state.json")
echo "${DIM}  $state${RESET}"
same "a match is recorded as the identity service" "matched identity anna" \
  "$(python3 -c 'import json,sys; d=json.load(open("/run/omarchy-face/state.json")); print(d["state"], d["service"], d["person"])')"
check "…world readable, because the GUI runs as the owner" \
  bash -c '[[ $(stat -c %a /run/omarchy-face/state.json) == 644 ]]'
reset_rate; stub no_match
identity verify anna >/dev/null 2>&1
same "a miss is recorded as failed" "failed identity" \
  "$(python3 -c 'import json,sys; d=json.load(open("/run/omarchy-face/state.json")); print(d["state"], d["service"])')"
stub ok

# =============================================================================
step "VERIFY-LOCK, which the phase-7 wrapper will use (§6.1)"
# =============================================================================

reset_rate; reset_log
same "with the lock feature off, it is disabled — and no camera" "NO disabled" \
  "$(say 'VERIFY-LOCK')"
write_config root true
same "with it on but nobody permitted, still disabled (fail safe)" "NO disabled" \
  "$(say 'VERIFY-LOCK')"
model_file omarchy-face.lock.root "anna/Everyday glasses"
reset_rate
same "with a lock set, it answers with who was recognised" "OK anna" "$(say 'VERIFY-LOCK')"
same "…and the journal records it as a lock verify, not as an unlock" "1" \
  "$(grep -c 'lock verify matched: anna' "$ACTIVATOR_LOG")"
check "…said at notice level, so it is in the journal by default" \
  grep -q '<5>lock verify matched' "$ACTIVATOR_LOG"
reset_rate
same "VERIFY-LOCK takes no arguments" "NO error" "$(say 'VERIFY-LOCK anna')"

# The client the lock wrapper actually runs (§6.3, F6). Two exit codes and
# nothing else: every reason for a no is the same no, because a lock screen is
# the one place where telling them apart is telling whoever is standing there.
lock_verify() { /usr/local/bin/omarchy-face-lock-verify >"$LAB/lock-out" 2>"$LAB/lock-err"; echo $?; }

reset_rate
same "omarchy-face-lock-verify exits 0 on a match" "0" "$(lock_verify)"
same "…and prints the name, for the wrapper's journal line" "anna" "$(cat "$LAB/lock-out")"
same "…and says nothing on stderr" "" "$(cat "$LAB/lock-err")"
reset_rate; stub no_match
same "a face that does not match is exit 1" "1" "$(lock_verify)"
same "…with no name to attribute anything to" "" "$(cat "$LAB/lock-out")"
reset_rate; stub ok
write_config root false
same "the feature being off is the same no (the daemon answers disabled)" "1" "$(lock_verify)"
write_config root true
reset_rate
same "and so is a rate limit — nothing on the lock screen tells them apart" "0" "$(lock_verify)"
same "…the second inside two seconds is refused, silently" "1" "$(lock_verify)"

rm -f "$MODELS/omarchy-face.lock.root.dat"
write_config root false

# =============================================================================
step "GATE: every exit path drains the socket (the phase-2 review's second half)"
# =============================================================================

reset_rate; reset_log; stub hang
say 'VERIFY-PERSON anna' >"$LAB/inflight" 2>&1 &
inflight=$!
sleep 0.6
# A second connection, which the single-threaded daemon has not accepted yet: it
# is sitting in the listening socket's backlog, which is exactly the state that
# re-activates the unit if the daemon exits without accepting it.
say 'VERIFY-PERSON anna' >"$LAB/pending" 2>&1 &
pending=$!
sleep 0.4
victim=$(daemon_pid)
check "the daemon is up and serving" test -n "$victim"
kill -TERM "$victim" 2>/dev/null
wait "$pending" 2>/dev/null
wait "$inflight" 2>/dev/null
same "a connection pending at exit is answered rather than left in the backlog" \
  "NO error" "$(cat "$LAB/pending")"
check "…and the engine did not outlive the daemon that started it" \
  bash -c '! pgrep -f "compare\.py" >/dev/null'
check "…nor the camera lock" camera_free
# review F5: a check that ended because systemd stopped the daemon must not
# leave the indicator spinning on the `start` nobody replaced.
same "…and the indicator is told the check is over, not left waiting" "skipped" \
  "$(python3 -c 'import json; print(json.load(open("/run/omarchy-face/state.json"))["state"])' 2>/dev/null)"
stub ok

reset_rate; reset_log
sleep 0.3
same "the next connection starts it again, the way systemd would" "0" "$(identity verify anna)"
starts=$(grep -c 'ACTIVATOR start' "$ACTIVATOR_LOG")
check "…as a second activation, not a second copy of the first" test "$starts" -ge 2

step "one activation serves many requests (it is not inetd)"
reset_rate; reset_log
before=$(grep -c 'ACTIVATOR start' "$ACTIVATOR_LOG")
identity verify anna >/dev/null 2>&1
sleep 2.1
identity verify bo >/dev/null 2>&1
after=$(grep -c 'ACTIVATOR start' "$ACTIVATOR_LOG")
same "two checks, one daemon" "$before" "$after"
same "…and both really ran" "2" "$(compare_runs)"

step "idle exit (§6: it does not sit around as root)"
same "the shipped daemon idles out after two minutes" "IDLE_TIMEOUT = 120.0" \
  "$(grep -m1 '^IDLE_TIMEOUT' "$REPO/system/omarchy-faced")"
# The same code with the timeout turned down, because a suite cannot wait two
# minutes to watch a timer it can read.
sed 's/^IDLE_TIMEOUT = 120.0/IDLE_TIMEOUT = 1.5/' "$REPO/system/omarchy-faced" \
  >/usr/local/bin/omarchy-faced-quick
chmod 0755 /usr/local/bin/omarchy-faced-quick
python3 "$REPO/dev/socket-activate.py" /run/quick.sock /usr/local/bin/omarchy-faced-quick \
  >"$LAB/quick.out" 2>"$LAB/quick.log" &
quick=$!
for _ in $(seq 1 50); do [[ -S /run/quick.sock ]] && break; sleep 0.1; done
reset_rate
same "it answers while it is up" "OK anna" \
  "$(python3 "$REPO/dev/socket-say.py" /run/quick.sock 'VERIFY-PERSON anna')"
sleep 2.5
check "…and has gone away on its own by the time nobody is asking" \
  grep -q 'ACTIVATOR exit 1' "$LAB/quick.log"
sleep 2.1
same "…and comes back for the next caller" "OK anna" \
  "$(python3 "$REPO/dev/socket-say.py" /run/quick.sock 'VERIFY-PERSON anna')"
check "…as a fresh activation" grep -q 'ACTIVATOR start 2' "$LAB/quick.log"

# A stranger connecting in a loop must not be able to keep a root process
# resident just by resetting the idle timer. Refused connections do not count as
# the daemon having done anything for anybody.
write_config "$ACCOUNT" false
before=$(grep -c 'ACTIVATOR exit' "$LAB/quick.log")
for _ in $(seq 1 6); do
  python3 "$REPO/dev/socket-say.py" /run/quick.sock 'VERIFY-PERSON anna' >/dev/null 2>&1
  sleep 0.5
done
after=$(grep -c 'ACTIVATOR exit' "$LAB/quick.log")
check "a refused caller cannot keep the daemon resident by knocking" \
  test "$after" -gt "$before"
sleep 2
starts=$(grep -c 'ACTIVATOR start' "$LAB/quick.log")
exits=$(grep -c 'ACTIVATOR exit' "$LAB/quick.log")
same "…and nothing of it is left running afterwards" "$starts" "$exits"
write_config root false
kill "$quick" 2>/dev/null
wait "$quick" 2>/dev/null

# =============================================================================
step "what the client does when there is no daemon at all"
# =============================================================================

stop_daemon
reset_rate
started=$(ms_now)
code=$(identity verify anna)
elapsed=$(( $(ms_now) - started ))
same "a missing socket is 'unavailable', never 'not present'" "3" "$code"
under "…and it says so at once rather than making Profiles wait" 1000 "$elapsed"
same "list still works without the daemon: it is a file read" "0" "$(identity list)"

rm -f "$STORE/people.json"
same "with Face not set up at all, list is 3 and prints nothing" "3" "$(identity list)"
same "…and so is verify" "3" "$(identity verify anna)"

# =============================================================================
step "the unit files say what this daemon needs (read, not run)"
# =============================================================================

UNIT=$REPO/system/omarchy-faced.service
SOCKET_UNIT=$REPO/system/omarchy-faced.socket
check "the socket is world-connectable, because peer credentials decide" \
  grep -q '^SocketMode=0666' "$SOCKET_UNIT"
check "…and hands over the listening socket, not an accepted one" \
  grep -q '^Accept=no' "$SOCKET_UNIT"
check "…keeping /run/omarchy-face when the daemon stops" \
  grep -q '^RuntimeDirectoryPreserve=yes' "$SOCKET_UNIT"
check "the service is never enabled on its own" bash -c "! grep -q '^\[Install\]' '$UNIT'"
check "…holds one capability" grep -q '^AmbientCapabilities=CAP_DAC_READ_SEARCH$' "$UNIT"
check "…is allowed video4linux and nothing else" grep -q '^DeviceAllow=char-video4linux rw' "$UNIT"
check "…and now carries the filter phase 6 promised" grep -q '^SystemCallFilter=@system-service' "$UNIT"
check "…which fails the call rather than killing an undrained daemon" \
  grep -q '^SystemCallErrorNumber=EPERM' "$UNIT"
check "…and says so in the journal, since EPERM is otherwise silent" \
  grep -q '^SystemCallLog=~@system-service' "$UNIT"

step "one name rule, written out in four places (review F6)"
# The rule cannot be shared: three of the four are self-contained root helpers
# in three languages, and giving them a common file to import would be giving
# them a file to be broken by. So the rule is repeated and this is what notices
# when one copy drifts -- a looser one in the daemon would be a name the store
# never allowed being accepted at the socket.
rules=$(grep -ohE '\[a-z\]\[a-z0-9-\]\{[0-9]+,[0-9]+\}' \
  "$REPO/system/omarchy-face-admin" "$REPO/system/omarchy-face-identity" \
  "$REPO/system/omarchy-faced" "$REPO/common/names.js" | sort -u)
same "every copy of the name rule is the same rule" "[a-z][a-z0-9-]{0,23}" "$rules"
for file in system/omarchy-face-admin system/omarchy-face-identity system/omarchy-faced common/names.js; do
  check "…and $file has one" \
    grep -qE '\[a-z\]\[a-z0-9-\]\{[0-9]+,[0-9]+\}' "$REPO/$file"
done

echo
if ((failures == 0)); then
  echo "${GREEN}F5 daemon checks pass.${RESET} ${DIM}$checks checks.${RESET}"
  echo "${DIM}Still needs a live machine: the shipped units under real systemd, and a"
  echo "real match through the real engine (the IR emitter is not driven here).${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
