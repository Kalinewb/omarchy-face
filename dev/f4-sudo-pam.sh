#!/bin/bash

# F4's gate: sudo's PAM stack, the gate, the verifier and the attribution
# (plan-merged.md §4 phase 5, plan-engine.md §4).
#
#   ./dev/f4-sudo-pam.sh
#
# There is no `--here`. Every other suite in dev/ offers one; this one must not,
# because the file under test is /etc/pam.d/sudo and a bug in the code being
# written is a machine nobody can become root on. The whole run happens inside
# `unshare --map-root-user --mount`, where /etc is a tmpfs whose pam.d is a COPY
# -- the real one is not reachable from in here at all, by construction rather
# than by care.
#
# What that leaves unproven, and what a person still has to do once, is the half
# that needs the PAM library itself: whether `sudo` really runs these two lines,
# whether pam_exec's `seteuid` really makes the helper root, and whether the card
# appears while a password prompt is up. Everything up to the moment PAM reads
# the file is here.
#
# The three clauses of the phase-5 gate, and where each is proved below:
#
#   1  real sudo shows the card naming the program
#        -- the mechanism: the verifier's attribution parser, run under a parent
#           whose /proc/<pid>/cmdline IS `sudo -u root pacman`, writing a
#           state.json the GUI harness then renders (dev/g5-indicator-offscreen.sh)
#   2  turning on changes only Face's marked block
#        -- five stacks, each round-tripped, each compared line by line
#   3  turning off restores the file byte-for-byte
#        -- sha256, before and after, on every one of them

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

note() { echo "  ${YELLOW}note${RESET}  $*"; }
step() { echo; echo "${DIM}== $*${RESET}"; }

# --- the sandbox -------------------------------------------------------------

if [[ ${OMARCHY_FACE_F4_IN_NS:-0} != 1 ]]; then
  command -v unshare >/dev/null || { echo "unshare is not installed" >&2; exit 1; }
  exec env OMARCHY_FACE_F4_IN_NS=1 OMARCHY_FACE_F4_ACCOUNT="$ACCOUNT" \
    unshare --map-root-user --mount --pid --fork "$BASH" "$0"
fi

ACCOUNT=${OMARCHY_FACE_F4_ACCOUNT:-$ACCOUNT}

# /etc, with everything but pam.d and Face's own directory pointing back at the
# real one. pam.d is a copy: this suite edits it on every check, and the point of
# the sandbox is that those edits cannot reach the machine.
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
chmod 0644 /etc/omarchy-face/config

mount -t tmpfs tmpfs /run || exit 1
chmod 0755 /run

# A PID namespace with the host's /proc is one where a process cannot read its
# own parent -- which is the whole of the attribution test.
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

# The helpers, installed the way the installer installs them: root:root 0755 in
# a root-owned directory. `sudo-on` refuses to point an auth stack at anything
# else, so this is not scene-setting, it is one of the preconditions under test.
mount -t tmpfs tmpfs /usr/local || exit 1
chmod 0755 /usr/local
mkdir -p /usr/local/bin
chmod 0755 /usr/local/bin
for helper in omarchy-face-admin omarchy-face-gate omarchy-face-verify omarchy-face-camera; do
  install -o root -g root -m 0755 "$REPO/system/$helper" /usr/local/bin/
done

ADMIN=/usr/local/bin/omarchy-face-admin
GATE=/usr/local/bin/omarchy-face-gate
VERIFY=/usr/local/bin/omarchy-face-verify
SUDO_PAM=/etc/pam.d/sudo
STATE=/run/omarchy-face/state.json
JOURNAL=/run/journal
STUB=/run/omarchy-face-stub
mkdir -p "$STUB"
LAB=$(mktemp -d /run/f4.XXXXXX)

# The journal, stood in for. The helpers log through `logger`, which in here has
# nothing to talk to -- and the attribution line is one of the things this phase
# is FOR, so it has to be readable. /usr/local/bin is a tmpfs of our own and it
# comes first in the helpers' pinned PATH, so a stand-in there is what they call.
cat >/usr/local/bin/logger <<'LOGGER'
#!/bin/bash
# Stand-in for logger(1): the last argument is the message.
printf '%s\n' "${@: -1}" >>/run/journal
LOGGER
chmod 0755 /usr/local/bin/logger
: >"$JOURNAL"

echo "F4 — sudo's PAM stack, the gate and the verifier (plan-merged.md §4 phase 5)"
echo "${DIM}sandbox: uid $(id -u), /etc /run /var/lib /usr/local and /usr/lib/security are private to this run${RESET}"
echo "${DIM}the real /etc/pam.d is not reachable from in here${RESET}"

# --- the engine, stubbed ------------------------------------------------------
#
# The same two stand-ins dev/f3-people-store.sh uses: howdy's own model format
# in and out, and control files that say what the camera saw. What matters here
# is not the engine but what the verifier does with its exit code and its
# `Winning model` line.

cat >/usr/lib/security/howdy/config.ini <<'INI'
[video]
certainty = 3.5
timeout = 5
dark_threshold = 60
[debug]
end_report = true
INI

cat >/usr/lib/security/howdy/cli.py <<'STUBADD'
import json, os, sys
if os.environ.get("SUDO_USER") is None:
    print("Please run this command as root:"); sys.exit(1)
args = sys.argv[1:]
model = args[args.index("-U") + 1] if "-U" in args else "none"
encoding = [round(0.01 + index * 0.001, 6) for index in range(128)]
path = os.path.abspath(__file__ + "/../models/" + model + ".dat")
json.dump([{"time": 1789400000, "label": "Initial model", "id": 0, "data": [encoding]}],
          open(path, "w"))
os.chmod(path, 0o600)
print("Scan complete")
STUBADD

cat >/usr/lib/security/howdy/compare.py <<'STUBCOMPARE'
import json, os, sys, time
# The stand-in for compare.py. `control/compare` is what the camera saw:
#   ok       a match, reported the way compare.py:277-279 reports it
#   no_match exit 12, howdy's "no face matched"
#   timeout  exit 11
#   silent   a match with no Winning model line (a howdy that changed its report)
#   hang     never answers, so `timeout -k 2 8` has to be what ends it
control = "/run/omarchy-face-stub"
user = sys.argv[1]
path = os.path.abspath(__file__ + "/../models/" + user + ".dat")
with open(control + "/log", "a") as handle:
    handle.write("compare %s parent=%s env=%s\n" %
                 (user, open("/proc/%d/comm" % os.getppid()).read().strip(),
                  ",".join(sorted(os.environ))))
word = open(control + "/compare").read().strip() if os.path.exists(control + "/compare") else "ok"
if word == "timeout":
    sys.exit(11)
if word == "no_match":
    sys.exit(12)
if word == "hang":
    time.sleep(300)
if not os.path.exists(path):
    sys.exit(10)
models = json.load(open(path))
print("Certainty of winning frame: 2.800")
if word != "silent":
    print('Winning model: 0 ("%s")' % models[0]["label"])
sys.exit(0)
STUBCOMPARE

stub_compare() { printf '%s\n' "$1" >"$STUB/compare"; }
stub_compare ok

# --- a store with one Sudo face ------------------------------------------------

record() { # record <name> <label> <appearance> [new]
  local name=$1 label=$2 appearance=$3 new=${4:-}
  local directives=("await ready 30")
  [[ -n $new ]] && directives+=("send {\"cmd\":\"create\",\"label\":\"$label\"}")
  directives+=("send {\"cmd\":\"capture\",\"appearance\":\"$appearance\"}"
               "await captured 60"
               "send {\"cmd\":\"done\"}"
               "await saved 30")
  printf '%s\n' "${directives[@]}" >"$LAB/script"
  python3 "$REPO/dev/enroll-client.py" "$LAB/script" -- "$ADMIN" enroll-session "$name" >/dev/null 2>&1
}

step "a machine with one Sudo face on it"
record "$ACCOUNT" "You" "No glasses" new
sudo_faces=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sudo_faces"])' \
  /var/lib/omarchy-face/people.json 2>/dev/null) || sudo_faces=0
same "the owner is enrolled and has Sudo" "1" "$sudo_faces"
check "the derived sudo set exists" test -e "/usr/lib/security/howdy/models/omarchy-face.sudo.$ACCOUNT.dat"

# =============================================================================
# GATE clauses 2 and 3: the edit, on five different stacks
# =============================================================================
#
# Each one is round-tripped: sha256 before, `sudo-on`, every assertion about
# what the file now is, `sudo-off`, sha256 again. The five differ in the ways a
# PAM stack differs between machines -- and the fourth and fifth are the two
# shapes a line-counting edit gets wrong.

round_trip() { # round_trip <description>
  local description=$1 before after original first_auth block_line
  before=$(sha256sum "$SUDO_PAM" | cut -d' ' -f1)
  original=$(grep -v 'omarchy-face' "$SUDO_PAM")
  first_auth=$(grep -n '^auth' "$SUDO_PAM" | head -1 | cut -d: -f1)

  echo "  ${DIM}-- $description${RESET}"
  out=$("$ADMIN" sudo-on 2>"$LAB/err")
  rc=$?
  [[ -s $LAB/err ]] && echo "  ${DIM}stderr:${RESET} $(cat "$LAB/err")"
  same "sudo-on exits 0 ($description)" "0" "$rc"
  check "…with one JSON document" bash -c "jq -e . <<<'$out' >/dev/null"

  check "…exactly one marked block, four lines of ours" \
    bash -c "[[ \$(grep -c '^# omarchy-face begin\$' '$SUDO_PAM') == 1 &&
                \$(grep -c '^# omarchy-face end\$' '$SUDO_PAM') == 1 &&
                \$(grep -c 'omarchy-face' '$SUDO_PAM') == 4 ]]"
  check "…the two lines are pam_exec on the gate and the verifier" \
    bash -c "grep -qx 'auth  \[success=1 default=ignore\]  pam_exec.so seteuid quiet /usr/local/bin/omarchy-face-gate' '$SUDO_PAM' &&
             grep -qx 'auth  sufficient                  pam_exec.so seteuid quiet /usr/local/bin/omarchy-face-verify' '$SUDO_PAM'"
  block_line=$(grep -n '^# omarchy-face begin$' "$SUDO_PAM" | cut -d: -f1)
  same "…inserted directly above the first auth line" "$first_auth" "$block_line"
  # THE clause-2 assertion: take our four lines back out, and what is left is
  # the file we started from -- every byte of it, in order.
  check "…every other line is byte-identical" \
    bash -c "[[ \"\$(grep -v 'omarchy-face' '$SUDO_PAM')\" == \"\$(cat <<'ORIGINAL'
$original
ORIGINAL
)\" ]]"
  same "…and the config now says sudo is on" "sudo=true" \
    "$(grep '^sudo=' /etc/omarchy-face/config)"

  out=$("$ADMIN" sudo-off 2>"$LAB/err")
  rc=$?
  same "sudo-off exits 0 ($description)" "0" "$rc"
  after=$(sha256sum "$SUDO_PAM" | cut -d' ' -f1)
  same "…and the stack is byte-for-byte what it was" "$before" "$after"
  same "…with the config back to off" "sudo=false" \
    "$(grep '^sudo=' /etc/omarchy-face/config)"
}

step "GATE: on changes only Face's block, off restores the file (clauses 2 and 3)"

# 1. This machine's own /etc/pam.d/sudo, copied into the sandbox.
echo "  ${DIM}this machine's stack:${RESET}"
sed 's/^/    /' "$SUDO_PAM"
round_trip "the machine's own sudo stack"

# 2. Stock Arch, including the line the plan names: pam_systemd.so class=none.
#    Some sudo stacks carry it and it must survive the edit verbatim -- it is a
#    session line, it sits below everything we touch, and an edit that counted
#    lines from the wrong end would take it with it.
cat >"$SUDO_PAM" <<'STOCK'
#%PAM-1.0
auth		include		system-auth
account		include		system-auth
session		include		system-auth
session		optional	pam_systemd.so class=none
STOCK
round_trip "stock Arch, with pam_systemd.so class=none"
check "the pam_systemd line survived the round trip, verbatim" \
  bash -c "grep -qx 'session		optional	pam_systemd.so class=none' '$SUDO_PAM'"

# 3. Comments and blank lines above the first auth line, and a stack whose auth
#    lines are not the first lines in the file.
printf '%s\n' \
  '#%PAM-1.0' \
  '# edited by hand, 2026' \
  '' \
  'session		optional	pam_systemd.so class=none' \
  'account		include		system-auth' \
  '' \
  'auth		required	pam_faillock.so preauth' \
  'auth		include		system-auth' \
  'auth		[default=die]	pam_faillock.so authfail' \
  'session		include		system-auth' >"$SUDO_PAM"
round_trip "comments, blanks, and auth lines in the middle"

# 4. No trailing newline on the last line. `head`/`tail` keep it that way and
#    `wc -l` counts one fewer line than there are; an edit that assumed either
#    would either add a byte or lose one.
printf '#%%PAM-1.0\nauth\t\tinclude\t\tsystem-auth\naccount\t\tinclude\t\tsystem-auth\nsession\t\tinclude\t\tsystem-auth' >"$SUDO_PAM"
round_trip "no trailing newline"
check "…and it still has no trailing newline" \
  bash -c "[[ \$(tail -c 1 '$SUDO_PAM' | od -An -c | tr -d ' ') != '\\n' ]]"

# 5. A stack carrying something that is not ours but looks close: another
#    pam_exec line, and a comment mentioning a face.
printf '%s\n' \
  '#%PAM-1.0' \
  '# face recognition is handled elsewhere on this machine' \
  'auth		optional	pam_exec.so seteuid quiet /usr/local/bin/somebody-elses-helper' \
  'auth		include		system-auth' \
  'account		include		system-auth' \
  'session		include		system-auth' >"$SUDO_PAM"
round_trip "a stack with somebody else's pam_exec line"
check "…somebody else's pam_exec line is still there" \
  bash -c "grep -q 'somebody-elses-helper' '$SUDO_PAM'"

# Back to the machine's own stack for everything below.
cp /mnt/pam.d/sudo "$SUDO_PAM"
chmod 0644 "$SUDO_PAM"

# =============================================================================
# What sudo-on refuses, and what it leaves behind when it does
# =============================================================================

step "what sudo-on refuses (plan-engine.md §4.1, plan-merged.md §2.3)"

refuse() { # refuse <description> <expected code> <command…>
  local description=$1 expected=$2
  shift 2
  local before out code
  before=$(sha256sum "$SUDO_PAM" | cut -d' ' -f1)
  out=$("$@" 2>/dev/null)
  code=$(jq -r '.error // "none"' <<<"$out" 2>/dev/null) || code="not json"
  echo "  ${DIM}$out${RESET}"
  same "$description" "$expected" "$code"
  same "…and /etc/pam.d/sudo is untouched" "$before" \
    "$(sha256sum "$SUDO_PAM" | cut -d' ' -f1)"
}

# Nobody with Sudo. The permission is taken off the only person who has it,
# which is also the store verb's own unwire path (§3.4 invariant 1).
"$ADMIN" set-permission "$ACCOUNT" sudo off >/dev/null 2>&1
refuse "an empty sudo set is no_sudo_faces" no_sudo_faces "$ADMIN" sudo-on
"$ADMIN" set-permission "$ACCOUNT" sudo on >/dev/null 2>&1

# A helper somebody else can write is a helper sudo must not run as root.
chmod 0757 "$VERIFY"
refuse "a world-writable verifier is helper_unsafe" helper_unsafe "$ADMIN" sudo-on
chmod 0755 "$VERIFY"

chown "$(id -u nobody 2>/dev/null || echo 65534)" "$GATE" 2>/dev/null &&
  { refuse "a gate that is not root's is helper_unsafe" helper_unsafe "$ADMIN" sudo-on
    chown 0 "$GATE"; } ||
  note "skipped: this namespace cannot chown the gate away from root"

# A block that is not the shape we wrote. `pam_insert_block` refuses on any
# mention of omarchy-face outside a block of ours, and `pam_block_intact` is
# what stops the refusal from being reached when the block IS ours.
printf '# omarchy-face begin\n' >>"$SUDO_PAM"
refuse "a stray marker makes the insert refuse" pam_edit_failed "$ADMIN" sudo-on
sed -i '/^# omarchy-face begin$/d' "$SUDO_PAM"

# And the repair it is allowed to make: a block that IS exactly ours, with a
# config that says sudo is off (a purge interrupted after the config was
# rewritten, a config restored from a backup).
"$ADMIN" sudo-on >/dev/null 2>&1
sed -i 's/^sudo=true/sudo=false/' /etc/omarchy-face/config
out=$("$ADMIN" sudo-on 2>/dev/null)
same "an intact block with sudo=false is repaired, not refused" "true" \
  "$(jq -r '.ok // false' <<<"$out")"
check "…and the block was not written twice" \
  bash -c "[[ \$(grep -c '^# omarchy-face begin\$' '$SUDO_PAM') == 1 ]]"
same "…with the config put right" "sudo=true" "$(grep '^sudo=' /etc/omarchy-face/config)"

step "sudo-off is always allowed (plan-engine.md §4.4)"
"$ADMIN" sudo-off >/dev/null 2>&1
out=$("$ADMIN" sudo-off 2>/dev/null)
same "…including when it is already off" "true" "$(jq -r '.ok // false' <<<"$out")"

# A foreign line inside our block is not ours to delete: the removal refuses and
# the config stays as it was, so the `sudo` row keeps saying something is wrong.
"$ADMIN" sudo-on >/dev/null 2>&1
sed -i '/^# omarchy-face end$/i auth  optional  pam_permit.so' "$SUDO_PAM"
before=$(sha256sum "$SUDO_PAM" | cut -d' ' -f1)
out=$("$ADMIN" sudo-off 2>/dev/null)
same "a foreign line inside the block makes sudo-off refuse" "pam_edit_failed" \
  "$(jq -r '.error // "none"' <<<"$out")"
same "…and the stack is untouched" "$before" "$(sha256sum "$SUDO_PAM" | cut -d' ' -f1)"
same "…and the config still says sudo is on, so the row stays broken" "sudo=true" \
  "$(grep '^sudo=' /etc/omarchy-face/config)"
sed -i '/pam_permit.so/d' "$SUDO_PAM"
"$ADMIN" sudo-off >/dev/null 2>&1

step "the status row reads the wiring back (plan-engine.md §10.1)"
row() { "$REPO/bin/omarchy-face-status" --json | jq -r ".rows[] | select(.id==\"sudo\") | .$1"; }
same "off, with the fix that turns it on" "needs_action sudo-on" "$(row state) $(row fix)"
"$ADMIN" sudo-on >/dev/null 2>&1
same "on, and nothing to fix" "ok false" "$(row state) $(row fixable)"
# Half-wired: the config says on, the stack says nothing.
sed -i '/omarchy-face/d' "$SUDO_PAM"
same "a config and a stack that disagree are broken, with sudo-off to repair it" \
  "broken sudo-off" "$(row state) $(row fix)"
"$ADMIN" sudo-on >/dev/null 2>&1

# =============================================================================
# The gate: nine reasons to leave the camera alone
# =============================================================================

step "the gate skips (exit 0), or lets the verifier try (exit 1) — §4.2"

# The camera helper, stood in for. The gate's own camera checks are two of the
# nine, and a laptop whose IR sensor happens to be in a video call would
# otherwise make this suite flaky. /dev/full is a character device nothing has
# open; /dev/null is one everything has open, which is exactly what "the camera
# is in use" looks like to fuser.
cat >/usr/local/bin/omarchy-face-camera <<'CAMERA'
#!/bin/bash
# Stand-in for omarchy-face-camera --ir-node.
node=$(cat /run/omarchy-face-stub/camera 2>/dev/null)
[[ -n $node ]] || exit 1
printf '%s\n' "$node"
CAMERA
chmod 0755 /usr/local/bin/omarchy-face-camera
printf '/dev/full\n' >"$STUB/camera"

gate_run() { # gate_run [env…] -> exit code, with the reason on stdout
  rm -f "$STATE"
  env PAM_SERVICE=sudo PAM_USER="$ACCOUNT" "$@" "$GATE"
  local code=$?
  printf '%s' "$(jq -r '.detail // ""' "$STATE" 2>/dev/null)"
  return $code
}

gate_case() { # gate_case <description> <expected code> <expected reason> [env…]
  local description=$1 expected_code=$2 expected_reason=$3
  shift 3
  local reason code
  reason=$(gate_run "$@")
  code=$?
  same "$description" "$expected_code|$expected_reason" "$code|$reason"
}

gate_case "everything in place: the verifier gets its attempt" 1 ""
gate_case "another service is never face-authenticated" 0 "" PAM_SERVICE=polkit-1
gate_case "another user is not this machine's face" 0 "face is not set up for somebodyelse" PAM_USER=somebodyelse
gate_case "root is never authenticated by face" 0 "root is never authenticated by face" PAM_USER=root
gate_case "a stack with no PAM_USER at all is skipped" 0 "face is not set up for this user" PAM_USER=
gate_case "a remote session is skipped" 0 "remote session from elsewhere.example" PAM_RHOST=elsewhere.example
gate_case "localhost is not remote" 1 "" PAM_RHOST=localhost

printf '/dev/null\n' >"$STUB/camera"
gate_case "a camera somebody else is streaming is skipped" 0 "the infrared camera is in use"
: >"$STUB/camera"
gate_case "no infrared camera at all is skipped" 0 "no infrared camera"
printf '/dev/full\n' >"$STUB/camera"

mv "/usr/lib/security/howdy/models/omarchy-face.sudo.$ACCOUNT.dat" "$LAB/sudo-set.dat"
gate_case "nobody with Sudo means nothing to compare against" 0 "nobody has Sudo"
mv "$LAB/sudo-set.dat" "/usr/lib/security/howdy/models/omarchy-face.sudo.$ACCOUNT.dat"

# Held by THIS shell on a descriptor of its own, not by a background `flock
# sleep`: flock's child inherits the lock and outlives the kill that was meant
# to release it, and a lock still held three checks later is a suite that fails
# in places that have nothing to do with it. Closing the descriptor releases it
# at a moment this script chooses.
exec 8>/run/omarchy-face/camera.lock
flock -n 8 || note "could not take the camera lock for the busy test"
gate_case "a camera lock somebody else holds is skipped" 0 "the camera is busy"
exec 8>&-
check "…and the lock is free again afterwards" \
  bash -c "flock -n -E 75 /run/omarchy-face/camera.lock true"

sed -i 's/^sudo=true/sudo=false/' /etc/omarchy-face/config
gate_case "the feature turned off is skipped" 0 "face for sudo is off"
sed -i 's/^sudo=false/sudo=true/' /etc/omarchy-face/config

# The lid. /proc/acpi is the kernel's; in here it is whatever this machine has,
# so the check is exercised only on a laptop that reports one.
if compgen -G '/proc/acpi/button/lid/*/state' >/dev/null; then
  lid_state=$(grep -ho 'open\|closed' /proc/acpi/button/lid/*/state | head -1)
  if [[ $lid_state == open ]]; then
    note "the lid is open, so the lid check is exercised only in its negative direction"
    gate_case "an open lid does not skip" 1 ""
  else
    gate_case "a closed lid is skipped" 0 "the laptop lid is closed"
  fi
else
  note "no /proc/acpi/button/lid on this machine: the lid check cannot be exercised here"
fi

step "the gate never writes to stdout or stderr (§4.2)"
out=$(PAM_SERVICE=sudo PAM_USER="$ACCOUNT" "$GATE" 2>&1)
same "nothing on fds 1 and 2" "" "$out"

# =============================================================================
# The verifier: one attempt, and who asked
# =============================================================================
#
# The verifier is run as the child of a process whose /proc/<pid>/cmdline IS
# `sudo -s -u root pacman` -- os.execv can set a process's whole argv, so this is
# the same read the real thing makes, against the same shape of data. Its own
# parent is `timeout`, which stands in for the terminal: the walk skips shells
# and stops at the first thing that is not one.

cat >"$LAB/fake-sudo.py" <<'FAKESUDO'
import os, sys
# argv[1] is the script the faked process runs; argv[2:] is the argv it wears.
fd = os.open(sys.argv[1], os.O_RDONLY)
os.dup2(fd, 0)
os.execv("/usr/bin/bash", sys.argv[2:])
FAKESUDO

cat >"$LAB/one-sudo.sh" <<'ONESUDO'
# Three runs of the stack from ONE sudo process, which is what a password retry
# is: same pid, same start time, same attempt key.
/usr/local/bin/omarchy-face-gate; echo "gate1=$?"
/usr/local/bin/omarchy-face-verify; echo "verify=$?"
cp /run/omarchy-face/state.json /run/state-after-verify.json
/usr/local/bin/omarchy-face-gate; echo "gate2=$?"
cp /run/omarchy-face/state.json /run/state-after-gate2.json
ONESUDO

one_sudo() { # one_sudo -> the transcript of a whole sudo call
  rm -f "$STATE" /run/state-after-verify.json /run/state-after-gate2.json
  rm -rf /run/omarchy-face/attempts
  env -i PATH=/usr/bin:/usr/local/bin PAM_SERVICE=sudo PAM_USER="$ACCOUNT" \
    timeout 60 python3 "$LAB/fake-sudo.py" "$LAB/one-sudo.sh" \
    sudo -s -u root pacman 2>&1
}

field() { jq -r "$2" "$1" 2>/dev/null; }

step "GATE clause 1's mechanism: who asked, and one attempt per sudo call"
stub_compare ok
: >"$JOURNAL"
transcript=$(one_sudo)
echo "${DIM}$(sed 's/^/  /' <<<"$transcript")${RESET}"
same "the gate let it through" "gate1=1" "$(grep -o 'gate1=[0-9]*' <<<"$transcript")"
same "the verifier authenticated" "verify=0" "$(grep -o 'verify=[0-9]*' <<<"$transcript")"
same "the state document names the service" "sudo" "$(field /run/state-after-verify.json .service)"
same "…and says it matched" "matched" "$(field /run/state-after-verify.json .state)"
same "…naming the person" "$ACCOUNT" "$(field /run/state-after-verify.json .person)"
same "…and the program that asked for root" "pacman" \
  "$(field /run/state-after-verify.json .requester.command)"
same "…and where it was asked from" "timeout" \
  "$(field /run/state-after-verify.json .requester.from)"
check "the journal names the person, the appearance, the command and the place" \
  bash -c "grep -q 'sudo approved by face: $ACCOUNT (No glasses) for pacman from timeout' '$JOURNAL'"
# A match is not an attempt spent: the next sudo gets its own.
same "a successful attempt leaves no marker behind" "0" \
  "$(find /run/omarchy-face/attempts -type f 2>/dev/null | wc -l)"

step "one authentication attempt per sudo call (§4.3 step 6)"
stub_compare no_match
: >"$JOURNAL"
: >"$STUB/log"
transcript=$(one_sudo)
echo "${DIM}$(sed 's/^/  /' <<<"$transcript")${RESET}"
same "the verifier did not authenticate" "verify=1" "$(grep -o 'verify=[0-9]*' <<<"$transcript")"
same "…and said so in the state document" "failed" "$(field /run/state-after-verify.json .state)"
same "the SAME sudo call is not given a second camera attempt" "gate2=0" \
  "$(grep -o 'gate2=[0-9]*' <<<"$transcript")"
same "…and the reason says why" "face already had its attempt for this sudo" \
  "$(field /run/state-after-gate2.json .detail)"
same "the engine was asked exactly once" "1" "$(grep -c '^compare ' "$STUB/log")"
check "the failure is in the journal, with the same attribution" \
  bash -c "grep -q 'sudo face attempt failed (engine exit 12) for pacman from timeout' '$JOURNAL'"
# A different sudo call is a different process, and gets its own attempt.
transcript=$(one_sudo)
same "a NEW sudo call is given its own attempt" "gate1=1" \
  "$(grep -o 'gate1=[0-9]*' <<<"$transcript")"

step "the verifier fails closed (§4.2's exit rule)"
verify_case() { # verify_case <description> <expected> [env…]
  local description=$1 expected=$2
  shift 2
  rm -rf /run/omarchy-face/attempts
  env PAM_SERVICE=sudo PAM_USER="$ACCOUNT" "$@" "$VERIFY"
  same "$description" "$expected" "$?"
}
stub_compare ok
verify_case "a stack that is not sudo is never authenticated" 1 PAM_SERVICE=polkit-1
verify_case "a user who is not the account is never authenticated" 1 PAM_USER=somebodyelse
verify_case "root is never authenticated" 1 PAM_USER=root
stub_compare timeout
verify_case "an engine that gives up does not authenticate" 1
stub_compare silent
verify_case "a match with no attribution still authenticates" 0
check "…logged as unattributed rather than guessed" \
  bash -c "grep -q 'sudo approved by face: unattributed' '$JOURNAL'"
stub_compare hang
start=$(date +%s)
verify_case "an engine that never answers is killed, and does not authenticate" 1
elapsed=$(( $(date +%s) - start ))
# `timeout -k 2 8` and nothing else: a camera lock held by a process nothing can
# kill is the failure this bound exists for (§2 rule 9).
check "…by the timeout at 8 s, not by waiting for the camera to be given back ($elapsed s)" \
  test "$elapsed" -lt 15
check "…and the camera lock was given back" \
  bash -c "flock -n -E 75 /run/omarchy-face/camera.lock true"
stub_compare ok

sed -i 's/^sudo=true/sudo=false/' /etc/omarchy-face/config
verify_case "the feature turned off is never an authentication" 1
sed -i 's/^sudo=false/sudo=true/' /etc/omarchy-face/config

mv "/usr/lib/security/howdy/models/omarchy-face.sudo.$ACCOUNT.dat" "$LAB/sudo-set.dat"
verify_case "no sudo set is never an authentication" 1
mv "$LAB/sudo-set.dat" "/usr/lib/security/howdy/models/omarchy-face.sudo.$ACCOUNT.dat"

step "the engine runs in a pinned environment (§4.2, §4.3 step 4)"
: >"$STUB/log"
env PAM_SERVICE=sudo PAM_USER="$ACCOUNT" LD_PRELOAD=/tmp/evil.so PYTHONPATH=/tmp \
  BASH_ENV=/tmp/evil.sh "$VERIFY" >/dev/null 2>&1
check "nothing the caller set reaches compare.py" \
  bash -c "! grep -qE 'LD_PRELOAD|PYTHONPATH|BASH_ENV' '$STUB/log'"
check "…and what it does get is the fixed set" \
  bash -c "grep -q 'env=HOME,LC_ALL,PATH,PYTHONDONTWRITEBYTECODE' '$STUB/log'"

step "the verifier's attribution parser, over sudo's own argv shapes (§2.6)"
# The parser reads a file, so it can be asked about argv shapes no test could
# produce as a live process. Sourced out of the installed helper, which is the
# code that runs under PAM.
parser() { # parser <argv…> -> the command as the state document would carry it
  local file
  file=$(mktemp "$LAB/cmdline.XXXXXX")
  printf '%s\0' "$@" >"$file"
  # Both halves, because in the verifier they are one step: the parser picks the
  # word and json_safe is what makes it safe to write. Testing the parser alone
  # would be testing half of what runs.
  FACE_CMDLINE=$file bash -c '
    source <(sed -n "/^json_safe()/,/^}$/p;/^sudo_command_from()/,/^}$/p" /usr/local/bin/omarchy-face-verify)
    json_safe "$(sudo_command_from "$FACE_CMDLINE")"'
  rm -f "$file"
}
same "sudo true" "true" "$(parser sudo true)"
same "sudo -u root pacman -Syu" "pacman" "$(parser sudo -u root pacman -Syu)"
same "sudo -v (no command at all)" "" "$(parser sudo -v)"
same "sudo -- ls" "ls" "$(parser sudo -- ls -la)"
same "sudo -Hu root id (a cluster whose last letter takes the argument)" "id" \
  "$(parser sudo -Hu root id)"
same "sudo -uroot id (an argument attached to its option)" "id" "$(parser sudo -uroot id)"
same "sudo --user=root id" "id" "$(parser sudo --user=root id)"
same "sudo --user root id" "id" "$(parser sudo --user root id)"
same "sudo /usr/bin/pacman (basename only)" "pacman" "$(parser sudo /usr/bin/pacman -Syu)"
same "sudo -p 'a prompt' systemctl" "systemctl" "$(parser sudo -p "Password for %p: " systemctl restart foo)"
same "sudo -T 30 -g wheel bash" "bash" "$(parser sudo -T 30 -g wheel bash)"
# A command name is another program's data by the time it reaches a JSON
# document and a journal line.
same "a name with control characters in it is stripped" "rm" "$(parser sudo "$(printf 'rm\001\002')")"
same "…and one longer than 32 characters is cut" 32 \
  "$(printf '%s' "$(parser sudo "$(printf 'a%.0s' {1..80})")" | wc -c)"

# =============================================================================
# Nothing else was touched
# =============================================================================

step "never in any other stack (§4.1)"
"$ADMIN" sudo-off >/dev/null 2>&1
check "no omarchy-face line in any PAM stack but the one we wired" \
  bash -c "! grep -rl 'omarchy-face' /etc/pam.d/ 2>/dev/null | grep -q ."

pam_after=$(find /etc/pam.d -type f -exec sha256sum {} + 2>/dev/null | sort -k2)
# /etc/pam.d/sudo was deliberately rewritten five times above, so it is compared
# against the copy this run started from rather than against the others.
check "every OTHER file in /etc/pam.d is byte-identical to the machine's" \
  bash -c "diff <(find /mnt/pam.d -type f ! -name sudo -exec sha256sum {} + | sed 's#/mnt/pam.d#PAMD#' | sort -k2) \
                <(find /etc/pam.d -type f ! -name sudo -exec sha256sum {} + | sed 's#/etc/pam.d#PAMD#' | sort -k2)"
check "…and sudo itself is back to the machine's own bytes" \
  bash -c "cmp -s /mnt/pam.d/sudo /etc/pam.d/sudo"

echo
if ((failures == 0)); then
  echo "${GREEN}F4 gate passes.${RESET} ${DIM}$checks checks.${RESET}"
  echo "${DIM}Still unproven here, and only provable on a live machine: that sudo's own"
  echo "PAM stack runs these lines, that pam_exec seteuid hands them root, and that"
  echo "the card appears while the password prompt is up.${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
