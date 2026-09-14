#!/bin/bash

# THE PHASE-6 GATE: "Profiles' bound-face `set` works, including its TERM-cancel
# test" (plan-merged.md §4 phase 6, plan-engine.md §6.4 test 6, §11.3).
#
#   ./dev/f5-profiles-contract.sh
#
# This is the one suite in the project that runs somebody else's code. The
# Profiles contract is two lines of a table (`list` and `verify <name>`, exit
# codes 0-4), and a table is not a test: what has to work is the actual sequence
# graveklar.profiles performs when a profile with a bound face is opened --
#
#   omarchy-profile set <profile>  with empty stdin
#     -> auth_entry: has_password, no secret, a bound identity
#     -> timeout 12 /usr/local/bin/omarchy-face-identity verify <name> &  ; wait
#     -> exit 0 from that = "entered <profile> by bound face"
#
# and its cancellation, which is the half that has bitten this project before:
#
#   the panel shows the password field IMMEDIATELY and runs the face `set`
#   beside it, then SIGTERMs that `set` the moment somebody types. Profiles'
#   own gate is "TERM during a face `set`'s face wait exits 143 within ~100 ms"
#   (its plan-merged.md §4 phase 4). The TERM reaches `timeout`, which forwards
#   it to our client, whose death closes the socket -- and the daemon's poll is
#   what turns that into a released camera within 300 ms.
#
# So the suite drives the REAL `bin/omarchy-profile` from the installed plugin,
# against a Profiles store built for the occasion, with Face's real daemon and
# real client behind it. Nothing is stubbed on the Profiles side at all.
#
# It runs in the same private namespace as the other F suites, with a temporary
# HOME on top: a profile switch rewrites ~/.config, so a run that used the real
# one would be a test that redecorated somebody's desktop. `omarchy`,
# `omarchy-shell` and `hyprctl` are stood in for, because stage 2 restarts the
# shell and talks to the compositor, and the machine running the test is using
# both.
#
# The engine is stubbed (compare.py's stand-in), for the reason f5-daemon.sh
# gives: this machine's IR emitter is not driven, so a real check ends in
# `black_frames` whoever is sitting there. What that costs is stated at the end.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ACCOUNT=${SUDO_USER:-${USER:-$(id -un)}}
PROFILES=${OMARCHY_PROFILES_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/graveklar.profiles}

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

[[ -x $PROFILES/bin/omarchy-profile ]] || {
  echo "f5-profiles: graveklar.profiles is not installed at $PROFILES" >&2
  echo "  (set OMARCHY_PROFILES_DIR to point at it)" >&2
  exit 1
}

# --- the sandbox -------------------------------------------------------------

if [[ ${OMARCHY_FACE_F5P_IN_NS:-0} != 1 ]]; then
  command -v unshare >/dev/null || { echo "unshare is not installed" >&2; exit 1; }
  exec env OMARCHY_FACE_F5P_IN_NS=1 OMARCHY_FACE_F5P_ACCOUNT="$ACCOUNT" \
    OMARCHY_PROFILES_DIR="$PROFILES" \
    unshare --map-root-user --mount --pid --fork "$BASH" "$0" "$@"
fi

ACCOUNT=${OMARCHY_FACE_F5P_ACCOUNT:-$ACCOUNT}

mount --bind /etc /mnt || exit 1
mount -t tmpfs tmpfs /etc || exit 1
chmod 0755 /etc
for real in /mnt/*; do ln -s "$real" "/etc/${real#/mnt/}"; done
rm -f /etc/omarchy-face 2>/dev/null
mkdir -p /etc/omarchy-face

mount -t tmpfs tmpfs /run || exit 1
chmod 0755 /run
mount -t proc proc /proc 2>/dev/null

mkdir -p /run/real-var-lib
mount --bind /var/lib /run/real-var-lib || exit 1
mount -t tmpfs tmpfs /var/lib || exit 1
chmod 0755 /var/lib
for real in /run/real-var-lib/*; do ln -s "$real" "/var/lib/${real#/run/real-var-lib/}"; done
# Profiles' root store is root:root 0700 on the real machine, which this
# namespace's uid 0 cannot read (it is not the same root). A fresh one, here.
rm -f /var/lib/omarchy-profiles
mkdir -p /var/lib/omarchy-profiles/passwords /var/lib/omarchy-profiles/identity
chmod 0700 /var/lib/omarchy-profiles

mount -t tmpfs tmpfs /usr/lib/security || exit 1
chmod 0755 /usr/lib/security
mkdir -p /usr/lib/security/howdy/models
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
LAB=$(mktemp -d /run/f5p.XXXXXX)
mkdir -p "$RUN" "$STUB" "$STORE"
chmod 0755 "$RUN"

echo "F5 gate — Profiles' bound-face set (plan-merged.md §4 phase 6)"
echo "${DIM}sandbox: uid $(id -u); profiles from $PROFILES${RESET}"

# --- Face's half -------------------------------------------------------------

install -o root -g root -m 0755 "$REPO/system/omarchy-faced" /usr/local/bin/
install -o root -g root -m 0755 "$REPO/system/omarchy-face-identity" /usr/local/bin/
# `account=root` for the reason f5-daemon.sh gives: inside this namespace the
# tests run as uid 0, and the daemon's rule is that the caller's uid must be the
# config account's. On a real machine that is the owner's own account.
printf 'account=root\nsudo=false\nlock=false\n' >/etc/omarchy-face/config

cat >/usr/local/bin/omarchy-face-camera <<'CAMERA'
#!/bin/bash
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
control = "/run/omarchy-face-stub"
model = sys.argv[1]
path = os.path.abspath(__file__ + "/../models/" + model + ".dat")
with open(control + "/log", "a") as handle:
    handle.write("compare %s\n" % model)
word = open(control + "/compare").read().strip() if os.path.exists(control + "/compare") else "ok"
if word == "hang":
    time.sleep(300)
if word == "no_match":
    sys.exit(1)
if word == "slow":
    time.sleep(2)
if not os.path.exists(path):
    sys.exit(10)
models = json.load(open(path))
print("Certainty of winning frame: 2.800")
print('Winning model: 0 ("%s")' % models[0]["label"])
sys.exit(0)
COMPARE

cat >"$STORE/people.json" <<'PEOPLE'
{"people":[
  {"name":"anna","label":"Anna","owner":true,"sudo":true,"lock":false,
   "appearances":[{"label":"Everyday glasses","time":1789400000}]}],
 "sudo_faces":1,"lock_faces":0,"maxAppearances":3,
 "nameRule":"^[a-z][a-z0-9-]{0,23}$","labelRule":"^[^\\u0000-\\u001f\\u007f]{1,32}$",
 "warning":null,"updated":1789400000}
PEOPLE
chmod 0644 "$STORE/people.json"
printf '[{"time":1789400000,"label":"anna/Everyday glasses","id":0,"data":[[0.1]]}]\n' \
  >"$MODELS/omarchy-face.person.anna.dat"
chmod 0600 "$MODELS/omarchy-face.person.anna.dat"

stub() { printf '%s\n' "$1" >"$STUB/compare"; }
stub ok
: >"$STUB/log"

ACTIVATOR_LOG=$LAB/activator.log
python3 "$REPO/dev/socket-activate.py" "$SOCK" /usr/local/bin/omarchy-faced \
  >"$LAB/activator.out" 2>"$ACTIVATOR_LOG" &
ACTIVATOR=$!
for _ in $(seq 1 50); do [[ -S $SOCK ]] && break; sleep 0.1; done
trap 'kill "$ACTIVATOR" 2>/dev/null; rm -rf "$LAB"' EXIT
[[ -S $SOCK ]] || { echo "  ${RED}FAIL${RESET}  the daemon socket never appeared"; exit 1; }

# --- Profiles' half ----------------------------------------------------------

export HOME=$LAB/home
export XDG_CONFIG_HOME=$HOME/.config
export XDG_STATE_HOME=$HOME/.local/state
export XDG_DATA_HOME=$HOME/.local/share
mkdir -p "$XDG_CONFIG_HOME/omarchy/profiles" "$XDG_STATE_HOME/omarchy-profiles" \
         "$XDG_DATA_HOME/applications"

# Stand-ins for the three things a switch reaches out to. The machine running
# this test is using all three, and stage 2 restarts the shell.
STUBBIN=$LAB/bin
mkdir -p "$STUBBIN"
for tool in omarchy omarchy-shell hyprctl; do
  cat >"$STUBBIN/$tool" <<STUBTOOL
#!/bin/bash
printf '%s %s\n' "$tool" "\$*" >>"$LAB/desktop.log"
exit 0
STUBTOOL
  chmod 0755 "$STUBBIN/$tool"
done
export PATH=$STUBBIN:/usr/local/bin:/usr/bin:/bin

PROFILE_DIR=$XDG_CONFIG_HOME/omarchy/profiles
jq -n '{version: 1, master: "master", master_switchable: true,
        pinned_plugins: ["graveklar.profiles"], workspace_span: 10, isolate: []}' \
  >"$PROFILE_DIR/config.json"
profile_json() { # profile_json <name> <master?> <offset>
  jq -n --arg d "for the test" --argjson m "$2" --argjson o "$3" \
    '{_description: $d, master: $m, hidden: false, icon: "",
      theme: "", wallpaper: "", dnd: false,
      idle: {screensaver: 150, lock: 300, inhibit: false},
      workspaces: {offset: $o, span: 10}, browser_profile: "default",
      bar: null, plugins: {disabled: []}, apps: {allowed: []}}' \
    >"$PROFILE_DIR/$1.json"
}
profile_json master true 0
profile_json work false 10
jq -n '{profile: "master", ws_offset: 0, ws_span: 10, updated: "2026-09-14T00:00:00+02:00"}' \
  >"$XDG_STATE_HOME/omarchy-profiles/current.json"

# What binds a face to a profile: a password file (so the profile asks for
# something at all) and a root-side identity naming a Face person. Both are
# written only by Profiles' own root helper on a real machine -- deliberately
# not by anything the user can edit, which is why the binding cannot be
# retargeted by hand (its `migrate_profiles`).
: >/var/lib/omarchy-profiles/passwords/work
printf 'anna\n' >/var/lib/omarchy-profiles/identity/work
chmod 0600 /var/lib/omarchy-profiles/passwords/work /var/lib/omarchy-profiles/identity/work

PROFILE=$PROFILES/bin/omarchy-profile
ms_now() { date +%s%3N; }
camera_free() { flock -n "$RUN/camera.lock" true; }
compare_runs() {
  local count
  count=$(grep -c '^compare ' "$STUB/log" 2>/dev/null)
  [[ $count =~ ^[0-9]+$ ]] || count=0
  printf '%s' "$count"
}
reset_rate() { rm -f "$RUN"/identity-attempts.*; }
current() { jq -r '.profile // ""' "$XDG_STATE_HOME/omarchy-profiles/current.json" 2>/dev/null; }

# Stage 2 outlives stage 1 on purpose (it restarts the shell), so the next
# `set` has to wait for it or Profiles answers `busy` -- correctly, and about
# the wrong thing as far as this suite is concerned.
wait_idle() {
  local journal=$XDG_STATE_HOME/omarchy-profiles/switch.json
  local lock=$XDG_STATE_HOME/omarchy-profiles/.lock
  local _
  for _ in $(seq 1 200); do
    if [[ ! -e $journal ]] && flock -n "$lock" true 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}

# Zombies count as "still there" to pgrep, and a `set` that exits without
# reaping its own `timeout` leaves one behind for the namespace's init to
# collect. What matters is whether anything is still RUNNING.
nothing_running() { # nothing_running <pattern>
  local pid state
  for pid in $(pgrep -f "$1" 2>/dev/null); do
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    [[ $state == Z ]] || return 1
  done
  return 0
}

step "the ground: Profiles sees Face, and Face sees the person"
same "Profiles' own view of the contract: list" "anna" "$(/usr/local/bin/omarchy-face-identity list)"
same "…and it finds the helper where it looks for it" "0" \
  "$(test -x /usr/local/bin/omarchy-face-identity; echo $?)"
same "the profile is the one with a bound face" "anna" "$(cat /var/lib/omarchy-profiles/identity/work)"
same "…and it starts in master" "master" "$(current)"

# =============================================================================
step "GATE: TERM during the face wait (Profiles' own phase-4 gate)"
# =============================================================================
#
# Done FIRST, before the successful switch, because it is the case that must
# leave nothing behind -- and the way to show that is for the switch that
# follows to still be a switch from master.

reset_rate; : >"$STUB/log"; stub hang
"$PROFILE" set work --json </dev/null >"$LAB/cancel.out" 2>"$LAB/cancel.err" &
switching=$!

# Wait until the face check is really in flight: Profiles has to have reached
# auth_entry, started `timeout 12 omarchy-face-identity verify anna`, and the
# daemon has to have the camera.
face_started=0
for _ in $(seq 1 100); do
  if ! camera_free; then face_started=1; break; fi
  sleep 0.05
done
check "Profiles really asked Face, by itself, from its own code path" test "$face_started" -eq 1
check "…and the camera is held while it looks" bash -c '! flock -n /run/omarchy-face/camera.lock true'

started=$(ms_now)
kill -TERM "$switching"
wait "$switching"
status=$?
elapsed=$(( $(ms_now) - started ))

same "the cancelled switch exits 143, the code the panel drops in silence" "143" "$status"
under "…within the ~100 ms Profiles' gate asks for" 400 "$elapsed"

gone=999
freed=999
started=$(ms_now)
for _ in $(seq 1 100); do
  if ! pgrep -f 'compare\.py' >/dev/null 2>&1; then gone=$(( $(ms_now) - started )); break; fi
  sleep 0.01
done
for _ in $(seq 1 100); do
  if camera_free; then freed=$(( $(ms_now) - started )); break; fi
  sleep 0.01
done
under "the engine stops with it" 300 "$gone"
under "…and the camera is free again" 300 "$freed"
same "…and the binding really is what was checked" "omarchy-face.person.anna" \
  "$(sed -n 's/^compare //p' "$STUB/log" | head -1)"
check "nothing of the check is left running" nothing_running omarchy-face-identity

same "the machine is still in the profile it was in" "master" "$(current)"
check "…with no switch journal left behind" test ! -e "$XDG_STATE_HOME/omarchy-profiles/switch.json"
check "…and no state lock held" test ! -e "$XDG_STATE_HOME/omarchy-profiles/.lock"
check "…and nothing was said to the desktop" test ! -s "$LAB/desktop.log"

# =============================================================================
step "GATE: the bound face opens the profile"
# =============================================================================

reset_rate; : >"$STUB/log"; stub ok
started=$(ms_now)
"$PROFILE" set work --json </dev/null >"$LAB/set.out" 2>"$LAB/set.err"
status=$?
elapsed=$(( $(ms_now) - started ))
echo "${DIM}  stdout: $(cat "$LAB/set.out")${RESET}"
echo "${DIM}  stderr: $(sed 's/^/          /' "$LAB/set.err" | head -3)${RESET}"

same "set exits 0" "0" "$status"
same "…with the contract's verdict, not a password prompt" "work" \
  "$(jq -r '.switching // ""' "$LAB/set.out" 2>/dev/null)"
same "…having asked the camera exactly once" "1" "$(compare_runs)"
under "…and answered while somebody is still standing there" 12000 "$elapsed"

# Stage 2 is detached and restarts the shell; it has the temporary HOME and the
# stand-in tools, so it is free to finish while the assertions below wait for
# the one thing that says the switch really happened.
switched=""
for _ in $(seq 1 100); do
  switched=$(current)
  [[ $switched == work ]] && break
  sleep 0.1
done
same "GATE: the machine really is in the profile now" "work" "$switched"
check "…and the shell was asked to restart, the way a real switch does" \
  grep -q '^omarchy restart shell' "$LAB/desktop.log"
check "…leaving no journal behind when it finished" \
  bash -c 'for _ in $(seq 1 50); do [[ -e "$XDG_STATE_HOME/omarchy-profiles/switch.json" ]] || exit 0; sleep 0.1; done; exit 1'

step "and the same switch when the face says no"
# Back to master first, without a password: master has no password of its own.
wait_idle
"$PROFILE" set master --json </dev/null >/dev/null 2>&1
for _ in $(seq 1 100); do [[ $(current) == master ]] && break; sleep 0.1; done
wait_idle
same "back in master" "master" "$(current)"

reset_rate; : >"$STUB/log"; stub no_match
"$PROFILE" set work --json </dev/null >"$LAB/no.out" 2>"$LAB/no.err"
status=$?
same "a face that does not match asks for the password instead" "2" "$status"
same "…saying exactly that, in the contract's words" "needs_password" \
  "$(jq -r '.error // ""' "$LAB/no.out" 2>/dev/null)"
same "…and the machine did not move" "master" "$(current)"

step "…and when Face cannot answer at all"
wait_idle
reset_rate; : >"$STUB/log"; stub ok
kill "$ACTIVATOR" 2>/dev/null; wait "$ACTIVATOR" 2>/dev/null; rm -f "$SOCK"
"$PROFILE" set work --json </dev/null >"$LAB/down.out" 2>"$LAB/down.err"
status=$?
same "a daemon that is not there is a password prompt, not an open profile" "2" "$status"
same "…with the same answer, because any non-zero is 'not verified'" "needs_password" \
  "$(jq -r '.error // ""' "$LAB/down.out" 2>/dev/null)"
same "…and no camera was involved" "0" "$(compare_runs)"
same "…and the machine did not move" "master" "$(current)"
ACTIVATOR=""

echo
if ((failures == 0)); then
  echo "${GREEN}PHASE 6 GATE PASSES.${RESET} ${DIM}$checks checks.${RESET}"
  echo "${DIM}Proven here: Profiles' own code, unmodified, drives"
  echo "omarchy-face-identity through the real daemon; its TERM cancel exits 143"
  echo "and frees the camera; a non-zero verify is a password prompt.${RESET}"
  echo "${DIM}NOT proven here: that a real face matches. The IR emitter on this"
  echo "machine is not driven, so the engine is stood in for -- what the stub"
  echo "cannot say is whether howdy recognises anybody.${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
