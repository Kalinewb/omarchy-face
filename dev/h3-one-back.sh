#!/bin/bash

# One way back, and the zone nothing collides with (Surface.qml, FaceViews.qml, FaceModel.qml).
#
#   ./dev/h3-one-back.sh
#
# Under the notch, the strip at the top centre of the panel is the one back control and Esc is its
# invisible alias (SURFACE-HOSTING.md section 15 of the notch). Face's panel used to show three: that strip, a
# "<-" at the right of its header, and a footer hint saying "esc goes back". This runs the REAL Surface.qml's
# panel on a stand-in host (dev/qml-harness/onecontrol.qml), headless, view by view, and checks:
#
#   * with a host that has the strip (features panelBack and backZone): no "Back" button of the panel's own
#     in any view, no hint but "esc stops the check" (the one thing Esc does that is not obvious), and no
#     control and no text inside the strip's zone (180 x 32 at the top centre) -- by the header's layout,
#     with nothing pushed down;
#   * with a host that says neither (an older notch, another host): the views keep their "<-" and their
#     hints, as the stock popup does, so nothing runs without a way back;
#   * the detector can fail: on that second host the header is the popup's own (icon and a long title), and
#     it finds the title in the zone.
#
# What it cannot: that the notch's strip really takes the press. That is the notch's dev/backone.sh and
# dev/back.sh, and the two meet at `panelBack`, `backZoneHeight` and `goBackInside()`.

set -uo pipefail

GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; RESET=$'\e[0m'
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
failures=0; checks=0
check() { # check <description> <expected> <actual>
  checks=$((checks + 1))
  if [[ $2 == "$3" ]]; then echo "  ${GREEN}pass${RESET}  $1"
  else echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected '$2', got '$3')${RESET}"; failures=$((failures + 1)); fi
}
step() { echo; echo "${DIM}== $*${RESET}"; }

command -v quickshell >/dev/null || { echo "h3: quickshell is not installed" >&2; exit 1; }
SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Commons ]] || { echo "h3: no Omarchy shell at $SHELL_PATH/shell" >&2; exit 1; }

root=$(mktemp -d /tmp/omarchy-face-h3.XXXXXX)
state=$root/state
trap 'rm -rf "$root"' EXIT
mkdir -p "$state"
ln -s "$SHELL_PATH/shell/Commons" "$root/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$root/Ui"
ln -s "$REPO" "$root/face"
cp "$REPO/dev/qml-harness/onecontrol.qml" "$root/shell.qml"
cp "$REPO/dev/fixtures/configured/people.json" "$state/people.json"

run() { # run <host kind>
  env FACE_HARNESS_HOST="$1" OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_STATE="$state" \
    OMARCHY_FACE_DEV_FIXTURE=configured OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=5 \
    QT_QPA_PLATFORM=offscreen timeout 60 quickshell -p "$root" -n 2>&1 </dev/null |
    sed -n 's/^.*HARNESS \([a-zA-Z0-9:-]*\) \(.*\)$/\1\t\2/p'
}
field() { awk -v key="$1" -F'\t' '$1 == key {print $2}' <<<"$2" | head -1; }
unset WAYLAND_DISPLAY

step "a host with the notch's strip (panelBack, backZone: a 180 x 32 zone at the top centre)"
out=$(run strip)
[[ -n $out ]] || { echo "  ${RED}FAIL${RESET}  the harness printed nothing (QML did not load)"; exit 1; }
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the host's zone is read as said" "180x32 features=panel,panelBack,backZone" "$(field zone "$out")"
for v in setup people person:anna settings remove; do
  check "$v: no Back button of its own, no hint, no control and no text in the zone" "back=0 hint='' hits=[] texts=[]" \
    "$(field "$v" "$out" | sed -E 's/ view=.*//')"
done
check "test: no Back button, one hint for what Esc does that is not obvious, no control and no text in the zone" \
  "back=0 hint='esc stops the check' hits=[] texts=[]" "$(field test "$out" | sed -E 's/ view=.*//')"
check "…and the test view really was up when that was read" "view=test" "$(field test "$out" | sed -E 's/.* (view=)/\1/')"

step "a host with no strip of its own to offer (no panelBack): the views keep their way back"
out=$(run plain)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the home has nothing to go back to: no button, its hint says it closes" "back=0 hint='esc closes'" \
  "$(field setup "$out" | sed -E 's/ hits=.*//')"
for v in people person:anna settings remove; do
  check "$v: the popup's own Back button and its hint" "back=1 hint='esc goes back' hits=[]" \
    "$(field "$v" "$out" | sed -E 's/ texts=.*//')"
done
check "test: the same, with the check's own sentence" "back=1" "$(field test "$out" | sed -E 's/ hint=.*//')"
check "the detector can fail: without the strip's layout the popup's own title is found in the zone" "true" \
  "$(field setup "$out" | grep -q 'texts=\[Face ID@' && echo true || echo false)"

step "asserted as text"
code() { sed -E 's#//.*$##' "$@"; }
check "the panel's own Back button is drawn only without a host strip" "1" \
  "$(code "$REPO/FaceViews.qml" | grep -c 'viewStack.length > 1 && !root.model.hostHasBack')"
check "the host's strip is detected by the panelBack feature word, and by nothing else" "1" \
  "$(code "$REPO/FaceModel.qml" | grep -c 'features.indexOf("panelBack") !== -1')"
check "the panel is not pushed down for the zone: its top inset is the plain one" "1 0" \
  "$(code "$REPO/Surface.qml" | grep -c 'topInset: hosted.inset') $(code "$REPO/Surface.qml" | grep -c 'surfaceHost.backZoneHeight')"
check "…the header keeps the centre clear by layout: under a strip its title is short of the zone and has no icon" "1 1" \
  "$(code "$REPO/FaceViews.qml" | grep -c 'titleRoom: Math.max') $(code "$REPO/FaceViews.qml" | grep -c 'iconComponent: heroBlock.strip ? null')"

echo
if ((failures)); then echo "${RED}$failures of $checks checks failed.${RESET}"; exit 1; fi
echo "${GREEN}All $checks checks pass.${RESET}"
