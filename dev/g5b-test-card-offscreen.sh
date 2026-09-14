#!/bin/bash

# Phase 6's GUI half: the Test card, and the indicator standing down behind it
# (plan-merged.md §4 phase 6, plan-gui.md §5.2, §6.2).
#
#   ./dev/g5b-test-card-offscreen.sh
#
# The sibling of g5-indicator-offscreen.sh -- same runtime, same fixture
# directory, same trick of reading what a card SAYS off its properties rather
# than off a screen -- and it is numbered after it rather than after the phase
# because it is the same machinery: the Test card is the indicator's card with
# a different sentence in it, and the indicator's `identity` states are the ones
# phase 5 already built and phase 6 finally has a producer for.
#
# **It briefly puts a real card on your screen.** The card is a layer-shell
# window and the shipped file cannot be instantiated without one. It takes no
# keyboard focus and its input region is the card itself, so nothing is stolen
# and nothing else is covered.
#
# The helper behind it is the dev stub, told which exit code to answer with
# (OMARCHY_FACE_DEV_VERIFY): what is under test here is that each of the five
# codes in the Profiles contract becomes the right sentence, and that stopping a
# check really signals the helper. Whether the codes themselves are right is
# dev/f5-daemon.sh's business, and the two meet at the exit code.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

failures=0
checks=0

check() { # check <description> <expected> <actual>
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

command -v quickshell >/dev/null || { echo "g5b-offscreen: quickshell is not installed" >&2; exit 1; }

SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Commons ]] || {
  echo "g5b-offscreen: no Omarchy shell at $SHELL_PATH/shell" >&2
  exit 1
}

root=$(mktemp -d /tmp/omarchy-face-g5b.XXXXXX)
state=$root/state
trap 'rm -rf "$root"' EXIT
mkdir -p "$state"
ln -s "$SHELL_PATH/shell/Commons" "$root/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$root/Ui"
ln -s "$REPO" "$root/face"
cp "$REPO/dev/qml-harness/test-card.qml" "$root/shell.qml"
cp "$REPO/dev/fixtures/three-people/people.json" "$state/people.json"

# An `identity` check in flight, in the shape omarchy-faced writes it
# (plan-merged.md §2.6). It is what the indicator would draw if it were not
# standing down for the card.
identity_state() {
  printf '{"state":"start","service":"identity","requester":{},"person":"","detail":"looking","at":%s}\n' \
    "$(date +%s%3N)" >"$state/state.json"
}

# The other kind: something asked for root, in the shape omarchy-face-verify
# writes it. This is the card a person has to be able to read.
sudo_state() {
  printf '{"state":"start","service":"sudo","requester":{"command":"pacman","from":"foot"},"person":"","detail":"looking","at":%s}\n' \
    "$(date +%s%3N)" >"$state/state.json"
}

run_case() { # run_case <case> [env…]
  local name=$1
  shift
  env FACE_HARNESS_CASE="$name" FACE_HARNESS_PLUGIN="$REPO" \
    OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_STATE="$state" \
    OMARCHY_FACE_DEV_FIXTURE=three-people \
    "$@" timeout 60 quickshell -p "$root" -n 2>&1 |
    sed -n 's/^.*HARNESS \([a-zA-Z]*\) \(.*\)$/\1\t\2/p'
}

field() { # field <key> <output>
  awk -v key="$1" -F'\t' '$1 == key {print $2}' <<<"$2" | head -1
}

# One value out of the service's own `state()` document.
say() { # say <key> <output> <jq filter>
  jq -r "$3" <<<"$(field "$1" "$2")" 2>/dev/null
}

echo "Phase 6 GUI — the Test card, offscreen"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO${RESET}"

# =============================================================================
step "GATE: the five sentences of the Profiles contract (plan-gui.md §5.2)"
# =============================================================================

# code : what the card must say. The labels come from people.json, so "Anna" and
# not "anna" -- the name is the key Profiles binds to and is never shown here.
declare -A expected=(
  [0]="Recognised Anna"
  [1]="Did not recognise Anna"
  [2]="Anna is not set up"
  [3]="Face Unlock cannot check right now"
  [4]="Checked too recently — try again in a moment"
)

for code in 0 1 2 3 4; do
  rm -f "$state/identity.log"
  out=$(run_case verdict OMARCHY_FACE_DEV_VERIFY="$code" OMARCHY_FACE_DEV_VERIFY_SECONDS=1)
  [[ -n $out ]] || { echo "  ${RED}FAIL${RESET}  the harness printed nothing (QML did not load)"; exit 1; }
  check "exit $code reads as: ${expected[$code]}" "${expected[$code]}" \
    "$(say done "$out" '.test.headline')"
  check "…and it really asked about that person" "verify anna" \
    "$(cat "$state/identity.log" 2>/dev/null)"
done

step "while it is looking"
rm -f "$state/identity.log"
identity_state
out=$(run_case verdict OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=2)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the card is up while the helper runs" "checking" "$(say checking "$out" '.test.phase')"
check "…saying what to do" "Look at the camera" "$(say checking "$out" '.test.headline')"
check "…and the service reports it as a duty" "test" "$(say checking "$out" '.duties | join(",")')"
check "GATE: the indicator stands down behind it" "false" \
  "$(say checking "$out" '.indicator.showing')"
check "…and comes back once the card has gone" "true" \
  "$(say gone "$out" '.indicator.showing')"
check "the card takes itself away without being asked" "null" "$(say gone "$out" '.test')"

step "a sudo that lands during a test is NOT the thing that gets hidden"
# The phase-6 security review's MEDIUM. Any process running as this account can
# raise a Test card over IPC; if that card suppressed the indicator outright, it
# would be a way to pick a three-second window in which `sudo -n` draws nothing
# on screen -- switching off exactly the mitigation phase 5 added. So identity
# checks are the only ones a Test card suppresses, and for anything else the
# CARD stands down.
rm -f "$state/identity.log"
identity_state
( sleep 1.4; sudo_state ) &
writer=$!
out=$(run_case sudo-during OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=6)
wait "$writer" 2>/dev/null
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "GATE: the sudo card draws, test card or no test card" "true" \
  "$(say checking "$out" '.indicator.showing')"
check "…still naming the program that asked" "sudo · pacman, from foot" \
  "$(say checking "$out" '.indicator.detail')"
check "…and it is the Test card that gets out of the way" "true" \
  "$(say checking "$out" '.test.standDown')"
check "…without the check it was running being cancelled" "checking" \
  "$(say checking "$out" '.test.phase')"

step "GATE: stopping a check signals the helper (plan-merged.md §2.5)"
rm -f "$state/identity.log"
identity_state
out=$(run_case cancel OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=8)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the card is gone" "null" "$(say cancelled "$out" '.test')"
# The stub traps TERM and records it. A helper that was merely abandoned would
# have written nothing here -- and on a real machine an abandoned `verify` is a
# camera still held, which is the whole reason §2.5 promises 300 ms.
check "…and the helper was really told to stop, not just forgotten" "cancelled anna" \
  "$(sed -n '2p' "$state/identity.log" 2>/dev/null)"

step "one card at a time"
rm -f "$state/identity.log"
out=$(run_case busy OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=2)
check "a test of somebody else while one is running is refused" "busy" "$(field second "$out")"
check "…asking again about the same person is the card already up" "ok" "$(field again "$out")"
check "…and only one check was ever started" "1" \
  "$(grep -c '^verify ' "$state/identity.log" 2>/dev/null)"

step "the card's shape, asserted as text (no compositor can be asked offscreen)"
check "it never takes keyboard focus" "true" \
  "$(grep -q 'WlrKeyboardFocus.None' "$REPO/TestCard.qml" && echo true || echo false)"
check "…its input region is the card itself, so clicks elsewhere pass through" "true" \
  "$(grep -q 'mask: Region { item: panel }' "$REPO/TestCard.qml" && echo true || echo false)"
check "…it draws no scrim over the machine" "true" \
  "$(grep -q 'rgba(0, 0, 0' "$REPO/TestCard.qml" && echo false || echo true)"
check "…and it says nothing was unlocked" "true" \
  "$(grep -q 'Nothing was unlocked' "$REPO/TestCard.qml" && echo true || echo false)"
check "the person view calls the service, not the helper" "true" \
  "$(grep -q 'cardArgv(\["testMatch", view.name\])' "$REPO/PersonView.qml" && echo true || echo false)"

echo
if ((failures == 0)); then
  echo "${GREEN}Phase 6 GUI checks pass.${RESET} ${DIM}$checks checks.${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
