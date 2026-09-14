#!/bin/bash

# G5: the indicator and the Settings sudo switch, in a real QML runtime with no
# shell and no window (plan-merged.md §4 phase 5, plan-gui.md §6.1, §6.2).
#
#   ./dev/g5-indicator-offscreen.sh
#
# The half of the phase-5 gate that belongs to the GUI is one sentence: *real
# sudo shows the card on the built-in screen naming the program*. It has three
# parts, and two of them are here:
#
#   the card renders with the program's name    -- every case below, from a
#                                                  state.json shaped exactly as
#                                                  the verifier writes it
#   it is the built-in screen it renders on     -- the screen filter, asserted
#                                                  against the real screen list
#
# The third -- that a real `sudo` produces that state.json -- is engine side and
# is dev/f4-sudo-pam.sh's business; the two meet at the file, and the fixtures
# here are copies of what that suite's verifier actually wrote.

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

command -v quickshell >/dev/null || { echo "g5-offscreen: quickshell is not installed" >&2; exit 1; }

SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Commons ]] || {
  echo "g5-offscreen: no Omarchy shell at $SHELL_PATH/shell" >&2
  exit 1
}

root=$(mktemp -d /tmp/omarchy-face-g5.XXXXXX)
state=$root/state
trap 'rm -rf "$root"' EXIT
mkdir -p "$state"
ln -s "$SHELL_PATH/shell/Commons" "$root/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$root/Ui"
ln -s "$REPO" "$root/face"
cp "$REPO/dev/qml-harness/indicator.qml" "$root/shell.qml"
cp "$REPO/dev/fixtures/three-people/people.json" "$state/people.json"

# One state document, in the shape omarchy-face-verify writes (plan-merged.md
# §2.6). `at` is milliseconds and `now` is what the 10 s stale filter measures
# against, so it is written fresh for every case.
write_state() { # write_state <state> <service> <person> <requester json> [age ms]
  local at
  at=$(( $(date +%s%3N) - ${5:-0} ))
  printf '{"state":"%s","service":"%s","requester":%s,"person":"%s","detail":"","at":%s}\n' \
    "$1" "$2" "$4" "$3" "$at" >"$state/state.json"
}

run_case() { # run_case <case> [env…]
  local name=$1
  shift
  env FACE_HARNESS_CASE="$name" FACE_HARNESS_PLUGIN="$REPO" \
    OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_STATE="$state" \
    "$@" timeout 60 quickshell -p "$root" -n 2>&1 |
    sed -n 's/^.*HARNESS \([a-zA-Z]*\) \(.*\)$/\1=\2/p'
}

field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }

echo "G5 — the indicator and the sudo switch, offscreen"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO${RESET}"

# =============================================================================
# The indicator (plan-gui.md §6.2)
# =============================================================================

step "GATE: the card names the program that asked for root"
write_state start sudo "" '{"command":"pacman","from":"foot"}'
out=$(run_case sudo-start)
[[ -n $out ]] || { echo "  ${RED}FAIL${RESET}  the harness printed nothing (QML did not load)"; exit 1; }
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the card is up" "true" "$(field showing "$out")"
check "…saying what to do" "Look at the camera" "$(field headline "$out")"
check "…and naming the program and the place it was asked from" \
  "sudo · pacman, from foot" "$(field detail "$out")"

write_state start sudo "" '{"command":""}'
out=$(run_case sudo-start)
check "a sudo with no command at all still says it is sudo" "sudo" "$(field detail "$out")"

write_state start sudo "" '{"command":"","from":"foot"}'
out=$(run_case sudo-start)
check "…and where it came from, when that is all there is" "sudo · from foot" \
  "$(field detail "$out")"

step "what it says when the answer arrives"
write_state matched sudo anna '{"command":"pacman","from":"foot"}'
out=$(run_case sudo-matched)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "a match is Approved, by the person's label" "Approved · Anna" "$(field headline "$out")"
check "…and nothing on screen says it unlocked anything" "true" \
  "$([[ $(field headline "$out") != *nlock* ]] && echo true || echo false)"

write_state matched sudo "" '{"command":"pacman"}'
out=$(run_case sudo-matched)
check "an unattributed match is still Approved" "Approved" "$(field headline "$out")"

write_state failed sudo "" '{"command":"pacman","from":"foot"}'
out=$(run_case sudo-failed)
check "a failure sends you to your password" "Not recognised — use your password" \
  "$(field headline "$out")"
check "…and the card is still up to say so" "true" "$(field showing "$out")"

step "when it says nothing at all"
write_state skipped sudo "" '{}'
out=$(run_case sudo-skipped)
check "a gate that skipped draws nothing" "false" "$(field showing "$out")"

write_state start lock anna '{}'
out=$(run_case lock-start)
check "the lock screen never draws a card over itself" "false" "$(field showing "$out")"

write_state start sudo "" '{"command":"pacman","from":"foot"}' 60000
out=$(run_case sudo-stale)
check "an authentication from a minute ago is not drawn" "false" "$(field showing "$out")"

write_state start sudo "" '{"command":"pacman","from":"foot"}'
out=$(run_case sudo-start FACE_HARNESS_SUPPRESSED=1)
check "it stands down while the recording card is up" "false" "$(field showing "$out")"
# Standing down is not the same as saying nothing. Any process running as this
# account can open a recording card over IPC, and somebody looking into the lens
# for a countdown is somebody not reading anything else -- so the line goes to
# the card instead (Service.qml binds it), and this is where it comes from.
check "…but it hands the card a line saying what asked while it was up" \
  "sudo · pacman asked while this was open" "$(field suppressedNotice "$out")"

write_state skipped sudo "" '{"command":"pacman"}'
out=$(run_case sudo-skipped FACE_HARNESS_SUPPRESSED=1)
check "a gate that skipped is not worth interrupting a recording for" "" \
  "$(field suppressedNotice "$out")"

step "Profiles asking who you are (service identity)"
write_state start identity "" '{}'
out=$(run_case identity-start)
check "the second line says who is asking" "Profiles is checking who you are" \
  "$(field detail "$out")"
write_state matched identity anna '{}'
out=$(run_case identity-matched)
check "…and a match names them" "Recognised Anna" "$(field headline "$out")"

step "GATE: the safety timer (12 s), for a verifier that never answers"
write_state start sudo "" '{"command":"pacman","from":"foot"}'
out=$(run_case sudo-safety)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the card was up" "true" "$(field showing "$out")"
check "…and took itself away when no answer came" "false" "$(field showingAfterSafety "$out")"

step "the built-in screen (plan-gui.md §0)"
# The rule is a name test on the screen list: eDP, LVDS or DSI is a panel with a
# camera above it; anything else is a monitor the person is not looking at.
builtin=$(qml6 -e 'import QtQuick; import Quickshell; Item { Component.onCompleted: {
  var names = []
  for (var i = 0; i < Quickshell.screens.length; i++) names.push(Quickshell.screens[i].name)
  console.log("SCREENS " + names.join(","))
  Qt.exit(0)
} }' 2>/dev/null | sed -n 's/^.*SCREENS //p' | head -1) || builtin=""
echo "  ${DIM}screens: ${builtin:-none visible from here}${RESET}"
check "the filter in Indicator.qml is the plan's" "true" \
  "$(grep -q '\^(eDP|LVDS|DSI)' "$REPO/Indicator.qml" && echo true || echo false)"
check "…and falls back to every screen when there is no built-in one" "true" \
  "$(grep -q 'builtin.length > 0 ? builtin : Quickshell.screens' "$REPO/Indicator.qml" && echo true || echo false)"
check "the card never takes keyboard focus" "true" \
  "$(grep -q 'WlrKeyboardFocus.None' "$REPO/Indicator.qml" && echo true || echo false)"
check "…and clicks pass straight through it" "true" \
  "$(grep -q 'mask: Region {}' "$REPO/Indicator.qml" && echo true || echo false)"

step "the service carries the indicator (plan-gui.md §1)"
# The indicator has to live in the keepLoaded service and not in the popup: the
# popup is destroyed by any write under the plugins folder, and an authentication
# that happens during one of those would otherwise draw nothing.
write_state start sudo "" '{"command":"pacman","from":"foot"}'
out=$(run_case service)
service_state=$(field serviceState "$out")
echo "${DIM}  $service_state${RESET}"
check "the service answers on the card's IPC target" "true" "$(field handlerFound "$out")"
check "…reporting the indicator as one of its duties" "indicator" \
  "$(jq -r '.duties | join(",")' <<<"$service_state" 2>/dev/null)"
check "…and what the card is saying, for a live test to read back" \
  "sudo · pacman, from foot" "$(jq -r '.indicator.detail' <<<"$service_state" 2>/dev/null)"
check "…with the card up and no recording card in the way" "true|null" \
  "$(jq -r '"\(.indicator.showing)|\(.card)"' <<<"$service_state" 2>/dev/null)"

# =============================================================================
# The Settings sudo switch (plan-gui.md §6.1)
# =============================================================================

step "GATE: the Settings switch, and the verb behind it"
rm -f "$state/verbs.log"
out=$(run_case settings-toggle FACE_HARNESS_SUDO=1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the switch reads the engine's config" "true" "$(field sudoOn "$out")"
check "…and the counts from people.json" "5 3" \
  "$(field sudoFaces "$out") $(field lockFaces "$out")"
check "turning it off shows the pending value while the password is asked for" \
  "false" "$(field pendingWhileAsking "$out")"
check "…and lets go of it when the verb answers" "true" "$(field pendingAfter "$out")"
check "…having called exactly sudo-off" "sudo-off" "$(cat "$state/verbs.log" | tr -d ' ')"

rm -f "$state/verbs.log"
out=$(run_case settings-toggle)
check "with sudo off, the switch turns it on" "sudo-on" "$(cat "$state/verbs.log" | tr -d ' ')"

rm -f "$state/verbs.log"
out=$(run_case settings-toggle OMARCHY_FACE_DEV_VERB_ERROR=no_sudo_faces)
check "a refusal is said in words, not in codes" "Give someone Sudo first." \
  "$(field note "$out")"

out=$(run_case settings FACE_HARNESS_SUDO=1 FACE_HARNESS_SUDO_ROW=broken \
  FACE_HARNESS_SUDO_DETAIL="0 marked block(s)")
check "a row that says the config and the stack disagree is carried through" \
  "broken" "$(field rowState "$out")"

echo
if ((failures == 0)); then
  echo "${GREEN}G5 gate passes.${RESET} ${DIM}$checks checks.${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
