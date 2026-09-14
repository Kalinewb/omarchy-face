#!/bin/bash

# The Setup view's engine row, in a real QML runtime, with no shell to restart.
#
#   ./dev/g2-engine-row-offscreen.sh
#
# dev/g2-engine-row.sh is the live test and the one the gate is written about;
# this is the one that can be run at any time -- including while the session is
# locked, when restarting the shell is exactly what must not happen. It loads
# the REAL SetupView.qml (against the real qs.Commons and qs.Ui, out of the
# running Omarchy) with a fake panel in front of it, and checks what its
# bindings decided in each state a build can be in.
#
# It does not draw anything and so cannot say the row looks right. What it does
# say is that every binding in it evaluates, that the step marks follow the
# contract's step list, and that a failed build fetches its own log tail through
# common/Ask.qml -- which is the part that would otherwise go untested until
# somebody happened to fail a build with the popup open.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
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

command -v quickshell >/dev/null || { echo "g2-offscreen: quickshell is not installed" >&2; exit 1; }

# qs.Commons and qs.Ui are rooted at the config directory, so the harness needs
# a root that has them -- the running Omarchy's, not a copy, or this would test
# the wrong shell.
SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Commons ]] || {
  echo "g2-offscreen: no Omarchy shell at $SHELL_PATH/shell" >&2
  exit 1
}

root=$(mktemp -d /tmp/omarchy-face-g2.XXXXXX)
state=$root/state
trap 'rm -rf "$root"' EXIT
mkdir -p "$state"
ln -s "$SHELL_PATH/shell/Commons" "$root/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$root/Ui"
ln -s "$REPO" "$root/face"
cp "$REPO/dev/qml-harness/shell.qml" "$root/shell.qml"

# A log longer than the tail, so "the last 20 lines" is a claim with something
# behind it.
for i in $(seq 1 60); do printf '12:00:%02d build: line %s\n' "$((i % 60))" "$i"; done >"$state/install.log"

run_case() { # run_case <case>
  FACE_HARNESS_CASE=$1 FACE_HARNESS_PLUGIN=$REPO \
  OMARCHY_FACE_DEV_BIN=$REPO/dev/bin OMARCHY_FACE_DEV_STATE=$state \
    timeout 60 quickshell -p "$root" -n 2>&1 |
    sed -n 's/^.*HARNESS \([a-zA-Z]*\) \(.*\)$/\1=\2/p'
}

field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }

echo "G2 — the engine row, offscreen"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO${RESET}"

echo
echo "${DIM}== a build in progress${RESET}"
out=$(run_case running)
[[ -n $out ]] || { echo "  ${RED}FAIL${RESET}  the harness printed nothing (QML did not load)"; exit 1; }
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the row is showing the build" true "$(field buildShown "$out")"
check "two steps done, one running, three to come" "✓✓→···" "$(field marks "$out")"
check "elapsed reads as minutes and hours, and says nothing for zero" \
  "3m 05s|42s|2h 01m|" "$(field elapsed "$out")"
check "no Fix button while it builds" "" "$(field fixLabel "$out")"
check "the log stays collapsed" false "$(field logExpanded "$out")"
check "install-job is not rendered as a row of its own" 4 "$(field rowsRendered "$out")"

echo
echo "${DIM}== a build that failed${RESET}"
out=$(run_case failed)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the failed step is marked" "✓✓✗···" "$(field marks "$out")"
check "the button says Try again" "Try again" "$(field fixLabel "$out")"
check "the log opens itself" true "$(field logExpanded "$out")"
check "…with the last 20 lines" 20 "$(field tailLines "$out")"
check "…ending at the end of the log" "12:00:00 build: line 60" "$(field tailLast "$out")"

echo
echo "${DIM}== nothing building${RESET}"
out=$(run_case idle)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the build block is not rendered" false "$(field buildShown "$out")"
check "and the Fix offers to build" "Build the face engine" "$(field fixLabel "$out")"

echo
if ((failures == 0)); then
  echo "${GREEN}$checks checks, all passed${RESET}"
else
  echo "${RED}$checks checks, $failures failed${RESET}"
fi
exit $((failures > 0))
