#!/bin/bash

# The GUI half of F2's gate, on the live shell (plan-merged.md §4 phase 3):
#
#   closing the popup or restarting the shell mid-build loses nothing
#
# It runs against the shell in development mode, where `install-engine` starts
# dev/bin/omarchy-face-build-standin as a transient unit of the user manager --
# the same shape as the real job's transient ROOT unit, and the only part of it
# the GUI can tell apart is that nothing gets compiled.
#
#   ./dev/g2-engine-row.sh
#
# It restarts the shell twice (once to enter development mode, once mid-build),
# so it refuses while the session is locked, like install.sh does.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURE=${OMARCHY_FACE_DEV_FIXTURE:-fresh}
STATE=$REPO/dev/fixtures/$FIXTURE
SECONDS_PER_STEP=${OMARCHY_FACE_DEV_BUILD_SECONDS:-12}

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

note() { echo "  ${YELLOW}note${RESET}  $*"; }
step() { echo; echo "${DIM}== $*${RESET}"; }

face_state() { omarchy-shell graveklar.face state 2>/dev/null; }
build_field() { jq -r ".install.$1" <<<"$(face_state)" 2>/dev/null; }

if command -v omarchy-hyprland-session-locked >/dev/null && omarchy-hyprland-session-locked; then
  echo "g2: refusing while the session is locked (the shell has to be restarted)" >&2
  exit 1
fi

echo "G2 — the engine row on the live shell"
echo "${DIM}fixture: $FIXTURE   stand-in: ${SECONDS_PER_STEP}s per step${RESET}"

step "development mode, with a build slow enough to close a popup during"
systemctl --user stop omarchy-face-dev-build.service >/dev/null 2>&1
rm -f "$STATE/install.json" "$STATE/install.log"
OMARCHY_FACE_DEV_BUILD_SECONDS=$SECONDS_PER_STEP \
  OMARCHY_FACE_DEV_FIXTURE=$FIXTURE "$REPO/install.sh" --dev >/dev/null || {
  echo "g2: could not restart the shell in development mode" >&2
  exit 1
}
check "the shell answers" bash -c "omarchy-shell shell ping >/dev/null"
check "the panel is in development mode" bash -c "[[ \$(jq -r .dev <<<\"\$(omarchy-shell graveklar.face state)\") == true ]]"

step "open Setup and start a build, the way the Fix button does"
omarchy-shell graveklar.face open setup "" >/dev/null
check "the popup is open on setup" bash -c "[[ \$(jq -r .view <<<\"\$(omarchy-shell graveklar.face state)\") == setup ]]"
OMARCHY_FACE_DEV_STATE=$STATE OMARCHY_FACE_DEV_BUILD_SECONDS=$SECONDS_PER_STEP \
  "$REPO/dev/bin/omarchy-face-admin" install-engine >/dev/null
sleep 3
check "the panel sees a build running" bash -c "[[ \$(jq -r .install.state <<<\"\$(omarchy-shell graveklar.face state)\") == running ]]"
started=$(build_field startedAt)
step_a=$(build_field step)
echo "  ${DIM}step $step_a, started $started${RESET}"
check "a second install-engine is refused" \
  bash -c "OMARCHY_FACE_DEV_STATE='$STATE' '$REPO/dev/bin/omarchy-face-admin' install-engine; [[ \$? == 3 ]]"

step "close the popup mid-build"
omarchy-shell graveklar.face hide >/dev/null
sleep 1
check "the popup is closed" bash -c "[[ \$(jq -r .open <<<\"\$(omarchy-shell graveklar.face state)\") == false ]]"
check "the build is still running" systemctl --user is-active --quiet omarchy-face-dev-build.service
sleep 4
omarchy-shell graveklar.face open setup "" >/dev/null
sleep 2
check "reopening shows the same build" bash -c "[[ \$(jq -r .install.startedAt <<<\"\$(omarchy-shell graveklar.face state)\") == $started ]]"
check "…further on than it was" bash -c "[[ \$(jq -r .install.updatedAt <<<\"\$(omarchy-shell graveklar.face state)\") -gt 0 ]]"
check "…and it is still the build, not a second one" \
  bash -c "[[ \$(systemctl --user show -p NRestarts --value omarchy-face-dev-build.service) == 0 ]]"

step "restart the whole shell mid-build"
check "the build is still running before the restart" systemctl --user is-active --quiet omarchy-face-dev-build.service
omarchy restart shell >/dev/null 2>&1
for _ in $(seq 1 40); do
  omarchy-shell shell ping >/dev/null 2>&1 && break
  sleep 0.25
done
sleep 1
check "the shell came back" bash -c "omarchy-shell shell ping >/dev/null"
check "the build survived it" systemctl --user is-active --quiet omarchy-face-dev-build.service
omarchy-shell graveklar.face open setup "" >/dev/null
sleep 2
after=$(face_state)
echo "  ${DIM}$(jq -c .install <<<"$after")${RESET}"
check "the new shell is showing the same build" bash -c "[[ \$(jq -r .install.startedAt <<<'$after') == $started ]]"
check "…and it has moved on" bash -c "[[ \$(jq -r .install.step <<<'$after') != '$step_a' ]]"

step "and it finishes"
for _ in $(seq 1 120); do
  [[ $(jq -r .state "$STATE/install.json" 2>/dev/null) == "done" ]] && break
  sleep 1
done
sleep 2
check "install.json says done" bash -c "[[ \$(jq -r .state '$STATE/install.json') == done ]]"
check "the panel agrees" bash -c "[[ \$(jq -r .install.state <<<\"\$(omarchy-shell graveklar.face state)\") == done ]]"
check "the log tail is there and bounded" \
  bash -c "[[ \$(OMARCHY_FACE_DEV_STATE='$STATE' '$REPO/dev/bin/omarchy-face-status' --install-log | wc -l) -gt 0 ]]"

step "tidy up"
rm -f "$STATE/install.json" "$STATE/install.log"
note "the shell is still in development mode; ./install.sh restores it"

echo
if ((failures == 0)); then
  echo "${GREEN}$checks checks, all passed${RESET}"
else
  echo "${RED}$checks checks, $failures failed${RESET}"
fi
exit $((failures > 0))
