#!/bin/bash

# E3: the enrol view (the dot scan's card), offscreen (plan-face-enroll.md section 7.4,
# Phase 4). 3.3.0 removed the Advanced scan and its ring; this suite is the dot scan's.
#
#   ./dev/e3-enrol-view.sh
#   E3_KEEP=/some/dir ./dev/e3-enrol-view.sh     keep the PNG strip, the GIF and the logs
#
# HEADLESS: QT_QPA_PLATFORM=offscreen, no WAYLAND_DISPLAY, no nested compositor, no
# window anywhere, and no camera -- the picture the circle would hold is a
# counting stand-in (dev/qml-harness/enrol.qml), so "no camera in idle" is a
# count of zero. The REAL EnrolView.qml, DotCard.qml and RecordSession.qml run
# against the running Omarchy's qs.Commons and qs.Ui, driven by a fake root
# session that enforces table V and counts the verbs it has to refuse.
#
# What it cannot say: that the picture looks right on a real screen, that a real
# VideoOutput paints inside the card's circle (the MultiEffect mask), that pkexec's
# dialog leaves the card alone, or that Qt announces a changed description to a screen reader.
# Those are the live steps in dev/README.md.
#
# Where the view lives: RecordCard.qml, the Face service's own window, in every home.
# It is never hosted in the notch (polkit's dialog takes the notch's focus, and the
# panel collapses with the scan inside it: the Phase 4 live gate).

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
DIM=$'\e[2m'
YELLOW=$'\e[33m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
failures=0
checks=0

note() { echo "  ${YELLOW}note${RESET}  $*"; }
step() { echo; echo "${DIM}== $*${RESET}"; }
check() { # check <description> <expected> <actual>
  checks=$((checks + 1))
  if [[ $2 == "$3" ]]; then
    echo "  ${GREEN}pass${RESET}  $1"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected '$2', got '$3')${RESET}"
    failures=$((failures + 1))
  fi
}
check_ge() { # check_ge <description> <minimum> <actual>
  checks=$((checks + 1))
  if awk -v a="$3" -v m="$2" 'BEGIN { exit !(a + 0 >= m + 0 && a != "") }'; then
    echo "  ${GREEN}pass${RESET}  $1 ${DIM}($3 >= $2)${RESET}"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected at least $2, got '$3')${RESET}"
    failures=$((failures + 1))
  fi
}

for tool in quickshell jq magick; do
  command -v "$tool" >/dev/null || { echo "e3: $tool is not installed" >&2; exit 1; }
done

SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Commons ]] || { echo "e3: no Omarchy shell at $SHELL_PATH/shell" >&2; exit 1; }

# Never a window on the desktop.
unset WAYLAND_DISPLAY
export QT_QPA_PLATFORM=offscreen

root=$(mktemp -d /tmp/omarchy-face-e3.XXXXXX)
logs=$root/logs
mkdir -p "$logs"
cleanup() {
  if [[ -n ${E3_KEEP:-} ]]; then mkdir -p "$E3_KEEP"; cp -r "$root/strip"/. "$E3_KEEP"/ 2>/dev/null; cp -r "$logs" "$E3_KEEP"/ 2>/dev/null; fi
  chmod -R u+rwx "$root" 2>/dev/null
  rm -rf "$root"
}
trap cleanup EXIT

shellDir=$root/shell
mkdir -p "$shellDir"
ln -s "$SHELL_PATH/shell/Commons" "$shellDir/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$shellDir/Ui"
ln -s "$SHELL_PATH/shell/services" "$shellDir/services"
ln -s "$REPO" "$shellDir/face"
cp "$REPO/dev/qml-harness/enrol.qml" "$shellDir/shell.qml"

# run <case> [ENV=value ...] -> the harness's lines, "key=value", in $out
run() {
  local c=$1; shift
  env OMARCHY_FACE_DEV_BIN=/nonexistent E3_CASE="$c" "$@" timeout 90 quickshell -p "$shellDir" -n 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | tee -a "$logs/$c.log" \
    | sed -n 's/^.*HARNESS \([a-zA-Z0-9_-]*\) \(.*\)$/\1=\2/p'
}
field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }

echo "E3 — the enrol view (the dot scan), offscreen"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO   no window, no camera${RESET}"

# =============================================================================
# static: nothing in the QML the plan forbids
# =============================================================================

step "static checks on the files"
check "no 'Accessibility options' anywhere in the QML" "0" \
  "$(cd "$REPO" && cat ./*.qml common/*.qml | grep -ci 'accessibility options')"
check "the new files hard-code no colour (hex, rgba or a colour name) outside comments" "" \
  "$(cd "$REPO" && for f in EnrolView.qml DotCard.qml DotStage.qml common/EnrolLink.qml; do sed -E 's#//.*$##' "$f" | grep -nE '#[0-9a-fA-F]{3,8}\b|Qt\.rgba\(|"(white|black|red|green|blue|gray|grey)"' | sed "s#^#$f:#"; done)"
check "Space is the dot scan's capture, and a held key is one press (RecordCard: Space, not auto-repeat, to island.capture)" "1 1" \
  "$(grep -c 'Keys.onSpacePressed: function (event) { if (!event.isAutoRepeat) island.capture()' "$REPO/RecordCard.qml") $(grep -c 'function capture() { enrol.capture() }' "$REPO/ScanIsland.qml")"
check "only EnrolView makes a DotCard, and only DotCard a DotStage" "EnrolView.qml|DotCard.qml" \
  "$(cd "$REPO" && for f in *.qml; do sed -E 's#//.*$##' "$f" | grep -q '\bDotCard *{' && echo "$f"; done | tr '\n' ' ' | sed 's/ $//')|$(cd "$REPO" && for f in *.qml; do sed -E 's#//.*$##' "$f" | grep -q '\bDotStage *{' && echo "$f"; done | tr '\n' ' ' | sed 's/ $//')"
check "a click leaves no outline on the card's controls: every link hands the focus back after a click" "1" \
  "$(grep -c 'function onClicked() { Qt.callLater(function () { link.focus = false }) }' "$REPO/common/EnrolLink.qml")"
check "the view has no background of its own (no window, no scrim, no container animation)" "0" \
  "$(cd "$REPO" && sed -E 's#//.*$##' EnrolView.qml | grep -cE 'PanelWindow|PopupWindow|FloatingWindow|ParallelAnimation|enterAnim')"
check "EnrolView and DotCard never read Commons.Color.accent (the host's accent arrives in colors); only the fallbacks name the theme" "0" \
  "$(cd "$REPO" && sed -E 's#//.*$##' DotCard.qml | grep -c 'Color\.accent') $(sed -E 's#//.*$##' EnrolView.qml | grep -cE 'Color\.accent.*(accentColor|ring)')" | awk '{print $1 + $2}'
check "the Advanced scan is gone from the plugin (3.3.0): no EnrolRing, EnrolMode, enrolring.js or mode file, and no sweep, trial, finish or abort verb sent" "0 0 0" \
  "$(cd "$REPO" && ls EnrolRing.qml common/EnrolMode.qml common/enrolring.js 2>/dev/null | wc -l) $(cd "$REPO" && cat ./*.qml common/*.qml common/*.js | sed -E 's#//.*$##' | grep -ciE 'enrolring|EnrolMode|enrol-mode|sweepFlow|setMode|simpleAllowed') $(cd "$REPO" && sed -E 's#//.*$##' RecordSession.qml | grep -E 'send\(' | grep -cE 'sweep|trial|finish|abort')"
check "the card sends the verbs create, dot, capture and done and nothing else (sorted)" "capture,create,done,dot" \
  "$(cd "$REPO" && sed -E 's#//.*$##' RecordSession.qml | grep -oE 'send\(\{cmd: "[a-z]+"' | sed -E 's/.*"([a-z]+)"/\1/' | sort -u | paste -sd,)"
check "the preview Loader is active only for previewOn AND a device (nothing else opens the camera)" "1" \
  "$(grep -c 'active: view.previewOn && view.previewDevice !== ""' "$REPO/EnrolView.qml")"
check "…and previewOn is the card being live AND the session wanting it (Start pressed)" "1" \
  "$(grep -c 'previewOn: view.live && !!view.session && view.session.previewWanted' "$REPO/EnrolView.qml")"
check "only ScanIsland.qml makes an EnrolView, and only RecordCard.qml makes a ScanIsland (nothing the notch's panel is made of names either)" "ScanIsland.qml|RecordCard.qml" \
  "$(cd "$REPO" && for f in *.qml; do sed -E 's#//.*$##' "$f" | grep -q '\bEnrolView *{' && echo "$f"; done | tr '\n' ' ' | sed 's/ $//')|$(cd "$REPO" && for f in *.qml; do sed -E 's#//.*$##' "$f" | grep -q '\bScanIsland *{' && echo "$f"; done | tr '\n' ' ' | sed 's/ $//')"
check "EnrolView is the only QML file that names RecordPreview" "EnrolView.qml" \
  "$(cd "$REPO" && grep -l 'RecordPreview' ./*.qml | sed 's#^\./##' | tr '\n' ' ' | sed 's/ $//')"
check "a pure #000000 under it is the host's: the view paints no background of its own" "0" \
  "$(cd "$REPO" && sed -E 's#//.*$##' EnrolView.qml DotCard.qml | grep -cE '^\s*color: *"?#?(black|000)')"


# =============================================================================
# Simple: the dot scan, start to finish
# =============================================================================

ball() { jq -r "$2" <<<"$(field "$1" "$out")"; }

step "The dot scan: idle, Start, the ball at the centre, a press, four more, Done"
out=$(run dot)
echo "${DIM}$(sed 's/^/  /' <<<"$out" | head -3)  ...${RESET}"
check "the session opens in idle, and the card is the dot scan's (the only scan there is)" \
  "idle false|legacy=false dotCard true" "$(field idle-phase "$out")|$(field idle-card "$out")"
check "idle: the line says what the scan is in plain words, with the Space key in it" "Look at the ball, then press Space." "$(field idle-line "$out")"
check "idle: the demo plays in the circle (the glyph is hidden) with its caption under the line" "false demo true caption 'Look at the ball'" "$(field idle-glyph "$out")"
check "idle: no camera exists, previewOn is false, the preview Loader holds nothing" "0 previewOn false previewLoader empty" "$(field idle-cameras "$out")"
check "idle: Cancel and Start; no Save, Done or Scan again" "cancel=1 start=1 save=0 done=0 again=0" "$(field idle-links "$out")"
check "idle: there is no choice of scan to make (no Simple or Advanced buttons anywhere on the card)" "true true true" "$(field idle-no-choice "$out")"
check "idle: the ball is not on the screen yet (the layer is hidden; the card's little demo shows how it will go)" "shown false opacity 0 output 1600x900" "$(field idle-screen "$out")"
check "idle: the Space key is not offered yet (nothing to press)" "hidden opacity 0 enabled false text to take the picture" "$(field idle-key "$out")"
check "idle: nothing was sent and the helper was not started" "ready sent 0" "$(field idle-state "$out")"
check "authorising: the camera comes on, the line says why we wait, only Cancel is offered" \
  "1 true|Waiting for authorisation…|cancel=1 start=0 save=0 done=0 again=0" "$(field auth-cameras "$out")|$(field auth-line "$out")|$(field auth-links "$out")"
check "a Space before the helper has said ready sends nothing" "0" "$(field auth-space-sent "$out")"
check "ready lists dot: phase dot, the ball waits on the centre, and NOTHING was sent (the first Space sends the first press)" \
  "dot flow true waiting pose centre|[]" "$(field ready-phase "$out")|$(field ready-sent "$out")"
check "the line names the pose, in plain words" "Look at the ball" "$(field ready-line "$out")"
check "the Space key is shown as a key, and Start, Save and Done are not" "cancel=1 start=0 save=0 done=0 again=0" "$(field ready-links "$out")"
check "the ball is on the SCREEN, at the middle of the 1600x900 output (800, 450), its ring open and breathing (between 28 and 34 px, and it moves)" \
  "800 450 waiting centre|within true moves true" "$(ball ready-ball '"\(.x) \(.y) \(.state) \(.pose)"')|$(field breath "$out" | sed 's/^min [0-9.]* max [0-9.]* //')"
check "the camera is on while the ball waits" "1" "$(field ready-cameras "$out")"
check "Space is ONE press: the verb dot with the appearance and the pose, nothing else" '[{"cmd":"dot","appearance":"No glasses","pose":"centre"}]' "$(field press-sent "$out")"
check "...the ball is capturing, the line says to hold still, and the key is off (no second press)" "capturing centre|Hold still|enabled false" "$(field press-state "$out")|$(field press-line "$out")|$(field press-key "$out" | grep -o 'enabled false')"
check "a second Space and a click on the key during the press send nothing" "1 dot" "$(field press-twice "$out")"
check "the ring closes in while frames come, and one of three does not close it" "capturing|1 of 3" "$(ball closing-1of3 .state)|$(field closing-good "$out")"
check "two of three: the ring is held at most 0.3 + 0.7 x 2/3 of the way (0.77) and nothing is taken" "0.77 capturing held 0 line Hold still" "$(field closing-2of3 "$out")"
check "three of three but the helper has not said dotted: the ring is as far as the frames allow, the ball is still capturing" "1 capturing pose centre" "$(field closing-3of3-undotted "$out")"
check "dotted closes the ring on the ball (15.4 px: 11 at 1.4 times, just outside it): landed, 'Got it', the centre is held, one capture is on the session" \
  "landed held centre line Got it|800 450 15.4 1 landed centre|1 No glasses" "$(field landed "$out" | sed 's/ {.*//')|$(field landed "$out" | sed 's/^.* line Got it //' | jq -r '"\(.x) \(.y) \(.r) \(.close) \(.state) \(.pose)"')|$(field landed-captures "$out")"
check "a Space in the beat after the ring closed is ignored" "ignored" "$(field landed-space "$out")"
check "then the ball is on the LEFT EDGE of the screen (64 px in, half way down), its ring open again, and the line names it" "true true waiting left|Turn to the ball on the left" "$(ball left-ball '"\((.x - 64 | fabs) < 3) \((.y - 450 | fabs) < 3) \(.state) \(.pose)"')|$(field left-line "$out")"
check "the centre's station is filled in the accent (taken) and the left's is under the ball" "centre:taken/0.95 left:open/0 top:open/0.55 right:open/0.55 bottom:open/0.55" "$(field left-marks "$out")"
check "the second press is for the left" '[{"cmd":"dot","appearance":"No glasses","pose":"left"}]' "$(field left-sent "$out")"
check "somebody else (not_you): the ring opens again, the ball STAYS on the left, the line says why in plain words and in the urgent colour, and the key offers a retry" \
  "waiting | That did not look like you | true waiting left | shown opacity 1 enabled true text to try again | colour urgent" \
  "$(field fail-notyou "$out" | awk -F' [|] ' '{print $1" | "$2}') | $(field fail-notyou "$out" | awk -F' [|] ' '{print $3}' | jq -r '"\((.x - 64 | fabs) < 3) \(.state) \(.pose)"') | $(field fail-notyou "$out" | awk -F' [|] ' '{print $4" | "$5}')"
check "...a failed press holds nothing new, and the retry is the same pose" 'centre|[{"cmd":"dot","appearance":"No glasses","pose":"left"}]' "$(field fail-held "$out" | sed 's/ links.*//')|$(field retry-sent "$out" | sed 's/ line.*//')"
check "the top: the ball is on the TOP EDGE (64 px down, in the middle), 'Look up at the ball', two stations filled" "true true waiting top|Look up at the ball|centre:taken/0.95 left:taken/0.95 top:open/0 right:open/0.55 bottom:open/0.55" \
  "$(ball top-ball '"\((.x - 800 | fabs) < 3) \((.y - 64 | fabs) < 3) \(.state) \(.pose)"')|$(field top-line "$out")|$(field top-marks "$out")"
check "the right: the RIGHT EDGE (64 px in from 1600), half way down" "true true waiting right|Turn to the ball on the right" "$(ball right-ball '"\((.x - 1536 | fabs) < 3) \((.y - 450 | fabs) < 3) \(.state) \(.pose)"')|$(field right-line "$out")"
check "after the right, Save is offered (the centre, left and right are held) and Done is not: the ball is on the bottom" \
  "true true waiting bottom|Look down at the ball|cancel=1 start=0 save=1 done=0 again=0" "$(ball bottom-ball '"\((.x - 800 | fabs) < 3) \((.y - 836 | fabs) < 3) \(.state) \(.pose)"')|$(field bottom-line "$out")|$(field bottom-links "$out")"
check "...four stations are filled" "centre:taken/0.95 left:taken/0.95 top:taken/0.95 right:taken/0.95 bottom:open/0" "$(field bottom-marks "$out")"
check "too dark at the bottom says so; Save stays on offer" "Too dark | cancel=1 start=0 save=1 done=0 again=0 | shown opacity 1 enabled true text to try again" "$(field bottom-fail "$out")"
check "all five held: 'All set.', Done and Scan again, no Save; the ball is gone, the check is drawn, five stations filled" \
  "done all true line All set. | cancel=1 start=0 save=0 done=1 again=1|true|centre:taken/0.95 left:taken/0.95 top:taken/0.95 right:taken/0.95 bottom:taken/0.95" \
  "$(field done-state "$out")|$(field done-ball "$out" | grep -o 'check [a-z]*' | sed 's/check //')|$(field done-marks "$out")"
check "...the session holds one capture and is swept (Done is legal), the key is gone, a screen reader is told" "swept 1|hidden opacity 0 enabled false text to take the picture|All five pictures taken" \
  "$(field done-state-scan "$out")|$(field done-key "$out" | sed 's/^shown /hidden /')|$(field done-descr "$out")"
check "the idle description told a screen reader the demo is not recording" "A demonstration of the scan, nothing is recording" "$(field idle-descr "$out")"
check "Scan again: nothing is sent (the next centre replaces the pending set), the centre is the ball's again, nothing is held" \
  "waiting held 0 pose centre line Look at the ball | cancel=1 start=0 save=0 done=0 again=0|7 dots in all|running 0" \
  "$(field again "$out")|$(field again-sent "$out" | sed 's/no new message: //')|$(field again-state "$out")"
check "Return before all five does nothing, and the next Space is the centre again" "dot|{\"cmd\":\"dot\",\"appearance\":\"No glasses\",\"pose\":\"centre\"}" \
  "$(field again-return "$out")|$(field retake-sent "$out" | sed 's/^\[\(.*\)\]$/\1/')"
check "Return does not save a partial scan; the Save link does, and the session ends saved" "dot|done|1 true" "$(field save-return "$out")|$(field save-sent "$out")|$(field save-finished "$out")"
check "the view never triggered a bad_sweep, never sent capture, sweep or finish" "0 true true true" "$(field violations "$out") $(field capture-never "$out") $(field sweep-never "$out") $(field finish-never "$out")"

step "The dot scan: Esc and Cancel in every state discard (they never save)"
out=$(run dot-esc)
check "idle: Esc closes with nothing to discard (no process)" "0 1 false" "$(field esc-idle "$out")"
check "authorising: EOF to the pkexec'd session, no camera" "1 closing 1 0" "$(field esc-authorising "$out")"
check "the ball waiting: EOF, no camera, nothing saved" "dot waiting|1 1 false 0 last EOF" "$(field esc-waiting-phase "$out")|$(field esc-waiting "$out")"
check "a press running: EOF ends it, the camera goes" "capturing|1 1 false 0" "$(field esc-capturing-phase "$out")|$(field esc-capturing "$out")"
check "Cancel with the centre, left and right held (Save was on offer): EOF, nothing saved" "cancel=1 start=0 save=1 done=0 again=0|1 1 false sent EOF" "$(field esc-save-offered "$out")|$(field esc-save "$out")"
check "all five held: Esc discards (Done is the one way to keep a scan)" "done cancel=1 start=0 save=0 done=1 again=1|1 1 false" "$(field esc-done-phase "$out")|$(field esc-done "$out")"
check "the 'Nothing was saved' line stays until the session finishes, and nothing the view sent was refused" "Nothing was saved|0" "$(field esc-line-discarding "$out")|$(field esc-end "$out")"

step "The dot scan: a press that did not work says why, in plain words, and the ball stays"
out=$(run dot-fail)
for pair in no_face:"No face found" too_dark:"Too dark" multiple_faces:"More than one face" not_you:"That did not look like you" black_frames:"Too dark" too_far:"Come a little closer" too_close:"Move back a little" face_cut_off:"Keep your whole face in view" face_tilted:"Keep your head level" timeout:"That took too long" camera_busy:"The camera is in use" bad_sweep:"Something went wrong"; do
  code=${pair%%:*}; text=${pair#*:}
  check "$code: '$text', the ball waits on the centre, nothing is held, the key offers a retry" \
    "waiting | $text | held 0 pose centre | shown opacity 1 enabled true text to try again" "$(field fail-$code "$out" | sed 's/opacity 0\.9[0-9]*/opacity 1/')"
done
check "a too small face with the helper's percent says how much bigger (3.2.1), and a percent on any other code is ignored" "Come a little closer (about 14% bigger) | short 14|No face found | short 0" "$(field fail-short "$out")|$(field fail-short-ignored "$out")"
check "a code from a later release still says something plain" "That did not work" "$(field fail-unknown "$out")"
check "a failed press leaves what is held as it was; the next press is for the same pose" "left,left held centre" "$(field fail-same-pose "$out")"
check "a refusal that is not about a press (a Save before the floor) is not a failed press: no reason appears" "| state waiting line Look up at the ball" "$(field fail-not-a-press "$out")"
check "no failure made the view send a verb the table refuses" "0" "$(field fail-violations "$out")"

step "The dot scan: the ball is on the real screen, positioned by the OUTPUT's size and nothing of the card's"
out=$(run dot-screen E3_OUT_W=1000 E3_OUT_H=1200)
idx=0
for size in 1920x1080 2560x1440 1366x768 1080x1920 3840x1080; do
  w=${size%x*}; h=${size#*x}
  check "output $size: centre in the middle, left and right edges 64 px in half way down, top and bottom edges 64 px in, in the middle" \
    "$size $((w / 2)),$((h / 2))|$size 64,$((h / 2))|$size $((w / 2)),64|$size $((w - 64)),$((h / 2))|$size $((w / 2)),$((h - 64))" \
    "$(field out$idx-centre "$out")|$(field out$idx-left "$out")|$(field out$idx-top "$out")|$(field out$idx-right "$out")|$(field out$idx-bottom "$out")"
  idx=$((idx + 1))
done
check "the session's own ball surface is the size of ITS output (1000x1200 here: the middle is 500,600), and the card's column is 320 px wide whatever the output" \
  "1000x1200 500,600|the card's column is 320 px wide whatever the output" "$(field screen-centre "$out")|$(field card "$out")"
least=$(field clearance "$out" | sed 's/.*: \(-\?[0-9]*\) px/\1/')
check_ge "the whole ball, its ring at its widest, is inside every output: the least gap to the physical edge is at least 20 px" 20 "$least"
check "the ball's code names no card, island or window size (only the output's width and height and the pose)" "0" \
  "$(cd "$REPO" && sed -E 's#//.*$##' BallLayer.qml BallScreen.qml DotBall.qml | grep -cE '\b(card|island|ScanIsland|RecordCard|enrol|EnrolView|implicitHeight)\b')"
check "the ball's window has no keyboard and no input, and is made after the card (so it is mapped above it)" "1 1 1 1" \
  "$(grep -c 'WlrKeyboardFocus.None' "$REPO/ScanBall.qml") $(grep -c 'mask: Region { item: noInput }' "$REPO/ScanBall.qml") $(grep -c 'width: 0; height: 0' "$REPO/ScanBall.qml") $(grep -c 'interval: 220' "$REPO/ScanBall.qml")"
check "the service makes ONE ball window, for the card's output only (the scrims stay on every output)" "1 1" \
  "$(sed -E 's#//.*$##' "$REPO/Service.qml" | grep -c 'model: root.card && root.cardScreen ? \[root.cardScreen\] : \[\]') $(sed -E 's#//.*$##' "$REPO/Service.qml" | grep -c 'model: root.scrimOn ? Quickshell.screens : \[\]')"

step "The dot scan: the helper closes a session after five presses that did not look like you, and the scan can start over"
out=$(run dot-cap)
check "four such presses: counted, the card still plays, no message yet" "notyou 4 capped false phase dot message '' line That did not look like you" "$(field cap-4 "$out")"
check "the fifth: the card says so in plain words" "notyou 5 capped true phase dot message 'That did not look like you too many times. Nothing was saved.'" "$(field cap-5 "$out")"
check "the helper then closes the session: the card is NOT closed, it is back at the start with the reason on it and Start offered, no camera" \
  "phase idle finished 0 | note 'That did not look like you too many times. Nothing was saved.' | cancel=1 start=1 save=0 done=0 again=0 | cameras 0" "$(field cap-after "$out")"
check "a new session counts from zero" "notyou 0 capped false phase dot waiting message ''" "$(field cap-restart "$out")"

step "The dot scan: the ring completes only with enough good frames, and never early"
out=$(run dot-ring)
check "two good frames of three, held for over two seconds: the ring never passes 0.77 and nothing is taken" "true|state capturing good 2 held 0" "$(field held-short-below "$out")|$(field held-short "$out" | sed 's/^max close [0-9.]* state/state/;s/ ring.*//')"
check "dotted closes it (1, 15.4 px) and the pose is held" "1 landed held centre ring 15" "$(field closed "$out" | sed 's/ ring 15\.[0-9]*/ ring 15/')"
check "a dotted that arrives early (a quick camera) still waits for the ring's second before the pose is applied" "held 1 state capturing|a second" "$(field early-dotted "$out")|$(field early-waited "$out")"
check "a press that fails opens the ring again, from wherever it had got to, and the ball waits" "mid closing then 0 ring 2" "$(field reopened "$out" | sed 's/ ring 2[0-9.]* state waiting/ ring 2/;s/ ring 20\.[0-9]*.*/ ring 2/')"

step "The dot scan under reduced motion: nothing depends on a running animation"
out=$(run dot-reduced)
check "idle: no demo, the glyph and one caption line" "demo none glyph true caption 'The ball moves left, up, right and down.'" "$(field reduced-idle "$out" | sed 's/^demo present/demo none/')"
check "the ring is still (30.8 px, no breath), and stays so" "r 30.8 pulse running 0|r 30.8 pulse 0|waiting r 30.8" "$(field reduced-ring "$out")|$(field reduced-static "$out")|$(field reduced-waiting "$out")"
check "a press closes the ring in steps with the frames (1 of 3: 0.53), and the ball is on its next station at once, no easing" "0.53|64 450 waiting left easing true" \
  "$(ball reduced-1of3 .close)|$(ball reduced-moved '"\(.x) \(.y) \(.state) \(.pose)"') easing $(field reduced-moved "$out" | sed 's/.*easing //')"
check "a failed press opens the ring at once and says why" "close 0 line Too dark" "$(field reduced-failed "$out")"

step "The dot scan: the idle demo is the scan, played with no camera"
out=$(run dot-demo)
check "idle: it plays, in the circle, with no camera object and the static glyph hidden" "true true cameras 0 glyph false" "$(field demo-state "$out")"
check "the captions follow the ball (centre, left, top, right, bottom, all set)" "Look at the ball | Turn left | Look up | Turn right | Look down | All set." "$(field demo-captions "$out")"
check "the ball goes to each station, the head turns to it to the limit, the ring closes in, the key is shown pressed, four are taken before the last, then the check" \
  '{"keyPressed":true,"leftBall":true,"leftYaw":true,"leftClosed":true,"topBall":true,"upPitch":true,"rightBall":true,"rightYaw":true,"fourTaken":true,"bottomBall":true,"downPitch":true,"check":true}' "$(field demo-seen "$out")"
check "Start stops it: the demo is gone (it exists only while idle on screen), and the camera is on" "gone cameras 1" "$(field start-stopped "$out")"

step "A helper that does not know dot (before 3.2.0): the single capture, with a plain note"
out=$(run dot-skew)
check "before Start nothing is different" "idle legacy=false" "$(field skew-idle "$out")"
check "ready without dot: the old single capture's countdown, in the legacy view, and the dot scan is not used" "countdown legacy true dotFlow false scanFlow false|legacy true" "$(field skew-phase "$out")|$(field skew-view "$out")"
check "...nothing was sent (no sweep and no dot to a helper that would ignore them), and it says why" "|Update Face's system files in Setup for the new scan" "$(field skew-sent "$out")|$(field skew-note "$out")"

step "A 3.2.x helper (it lists sweep as well as dot) with this card: the dot scan, and the Advanced verbs are never sent"
out=$(run dot-skew-326)
check "ready with capture, sweep, dot, abort and finish: the scan is the dot scan, not the single capture" "dot legacy false dotFlow true|legacy false pose centre" "$(field skew326-phase "$out")|$(field skew326-view "$out")"
check "the first press is a dot press and nothing else was sent: no sweep, no finish, no abort; the table refused nothing" "dot violations 0" "$(field skew326-sent "$out")"


# =============================================================================
# Version skew and sessions that are not the scan
# =============================================================================

step "Version skew: a helper that lists no verbs at all (before 3.1.0) gets the single capture"
out=$(run skew)
check "before Start nothing is different (the idle view)" "idle false" "$(field skew-idle "$out")"
check "ready without verbs: the countdown of the single capture, in the legacy view" "countdown true | true" "$(field skew-phase "$out") | $(field skew-legacy-view "$out")"
check "…the picker and its Start are the old ones" "Start" "$(field skew-picker "$out")"
check "…it says why, in the old helper's note" "Update Face's system files in Setup for the new scan" "$(field skew-note-text "$out")"
check "…capture (not dot) is what it sends" "capture | countdown" "$(field skew-capture-after-countdown "$out")"
check "…and no sweep was ever sent" "true" "$(field skew-no-sweep "$out")"
check "…the verdict closes the preview" "verdict good cameras 0" "$(field skew-verdict "$out")"

step "A session that is not the scan (what g3 and g8 drive) is untouched"
out=$(run plain)
check "framing, scan off, the legacy view, the camera as before" "framing scan=false legacy=true" "$(field plain-phase "$out")"
check "ready with verbs on a non-scan session still goes to the countdown" "countdown  scanFlow=false" "$(field plain-after-ready "$out")"

# =============================================================================
# The camera fence, the island and the scrim
# =============================================================================

step "The camera fence (6a.1): the preview exists only after Start and only while the host shows the view"
out=$(run fence)
check "idle: no camera object, and the demo has been running (it needs none)" "0 false false true true" "$(field fence-idle "$out")"
check "Start (authorising): the camera is wanted and exists" "1 true authorising" "$(field fence-authorising "$out")"
check "the ball waiting (dot): still on" "1 true dot" "$(field fence-dot "$out")"
check "the host stops showing the view (route change, notch closed, bar hidden): gone within 200 ms" "0 false" "$(field fence-host-hidden "$out")"
check "…and back when it shows the view again" "1 true" "$(field fence-host-shown "$out")"
check "a press that did not work does not take the camera away (the ball stays, the next press is one Space away)" "1 true dot waiting" "$(field fence-failed-press "$out")"
check "all five taken: the camera is still on while the card waits for Done" "1 dot swept" "$(field fence-held "$out")"
check "Done (closing): gone" "0 closing false" "$(field fence-closing "$out")"
check "a new session starts at zero cameras and a destroyed session leaves none" "1 0" "$(field fence-second-auth "$out") $(field fence-destroyed "$out")"

step "The island: the notch's silhouette, centred, flush, dropping from the top edge and retracting"
out=$(run island)
echo "${DIM}$(sed 's/^/  /' <<<"$out" | head -14)${RESET}"
check "full motion is on (not reduced)" "reduced false" "$(field first "$out")"
check "it drops to full height and width, overshooting by under 5% on the spring" "true" \
  "$(awk -v p="$(field drop-peak "$out")" 'BEGIN { print (p >= 1 && p < 1.05) ? "true" : "false" }')"
check "…landing on 1" "1 1" "$(field drop-end "$out")"
check "…the height is rising in the first frames" "true" "$(field drop-monotone-early "$out")"
check "…its top edge is on the screen edge at every frame (only height and width move)" "flush" "$(field drop-top "$out")"
check "the bottom corners and the fillets are the notch's (8 and 8 from shell.json)" "8 8" "$(field radii "$out")"
check "the surface is true #000000" "#000000" "$(field colour "$out")"
check "its top is flush with the strip's top edge" "0 0" "$(field flush "$out")"
read -r cx _ cw <<<"$(field centred "$out")"
check "it is centred in the strip, as the notch is on its monitor (within a pixel)" "true" \
  "$(awk -v a="$cx" -v b="$cw" 'BEGIN { d = a - b; if (d < 0) d = -d; print (d <= 1) ? "true" : "false" }')"
check "it is tall enough for the view plus the notch's side padding top and bottom" "true" "$(field fits "$out")"
echo "${DIM}  bar $(field bar "$out"), view at $(field inner "$out")${RESET}"
check "retracting: still on its way after 120 ms, and gone (answered once) a moment later" "0 true|1 0 0" \
  "$(field retract-early "$out" | awk '{print $1" "($2 > 0 && $2 < 1 ? "true" : "false")}')|$(field retract-late "$out")"
check "retracting twice answers once, and it can drop again" "1 1 1" "$(field retract-twice "$out") $(field retract-twice-late "$out") $(field again "$out")"
check "the card's keys reach the session through the island: Space is ONE press for the centre, and a second does nothing while it runs" \
  '[{"cmd":"dot","appearance":"No glasses","pose":"centre"}]|dot' "$(field island-space "$out")|$(field island-space-twice "$out")"
out=$(run island-reduced)
check "reduced motion: reduced is on, and it is simply there (1, 1)" "reduced true|1 1" "$(field first "$out")|$(field drop-end "$out")"
check "reduced motion: it never leaves its place while it 'drops' (no frames of motion: the peak is exactly 1)" "1" "$(field drop-peak "$out")"
check "reduced motion: retracting is immediate (answered, closed) well inside 120 ms" "1 0" "$(field retract-early "$out" | awk '{print $1" "$2}')"

step "The dimming behind the island: 55% black, following the drop, instant under reduced motion, taking every click"
out=$(run scrim)
check "it follows the island's drop exactly (55% of the clamped drop at every sample), never over 55%, and settles at 0.55" \
  "within 0.0001 of 0.55 x the drop over 17 samples|0.55 settled 0.55" "$(field follows "$out")|$(field peak "$out")"
check "it is true #000000 and absorbs the pointer: every button, hover, covering the whole screen" "#000000 true true covers true" \
  "$(field colour "$out") $(field input "$out")"
check "retracting fades it out with the island (it is gone when the island is)" "0 0" "$(field retracted "$out")"
check "no invisible blocker: its input region is empty before the island drops (presence 0) and once it has gone" "0x0 0x0" "$(field input-idle "$out") $(field input-after "$out")"
out=$(run scrim-reduced)
check "reduced motion: 55% from the very first frame (no fade of its own), and 0 the moment the island leaves" "0.55 reduced true|0" "$(field first "$out")|$(field retract-first "$out")"
scrim_shape=no
if grep -q 'PanelWindow' "$REPO/ScanScrim.qml" && grep -q 'WlrKeyboardFocus.None' "$REPO/ScanScrim.qml" \
   && grep -q 'mask: Region { item: layer.input }' "$REPO/ScanScrim.qml" && [[ $(sed -E 's#//.*$##' "$REPO/ScrimLayer.qml" | grep -c 'PanelWindow') -eq 0 ]]; then scrim_shape=yes; fi
scrim_namers=$(cd "$REPO" && for f in *.qml; do [[ $(sed -E 's#//.*$##' "$f" | grep -c 'ScanScrim') -gt 0 ]] && echo "$f"; done | tr '\n' ' ')
check "the files: ScrimLayer is no window; ScanScrim is one (Overlay, no keyboard, input region = the absorber) named only by the service" "yes Service.qml " "$scrim_shape $scrim_namers"

step "The dot scan on the island, rendered: a strip and a short GIF"
mkdir -p "$root/strip"
run strip E3_OUT="$root/strip" >/dev/null
frames=$(ls "$root/strip"/*.png 2>/dev/null | wc -l)
check "frames were drawn (seven scan frames and five demo steps)" "12" "$frames"
if (( frames > 0 )); then
  for f in "$root/strip"/*.png; do
    # The window's grey is the desktop; the island is black on it. Flatten onto it
    # and cut the strip to the island's height.
    magick "$f" -background '#3a3a46' -flatten -gravity north -crop 400x520+0+0 +repage "$f"
  done
  magick montage "$root/strip"/simple-[0-9]-*.png -tile x1 -geometry +4+4 -background '#3a3a46' "$root/strip/strip-simple.png" 2>/dev/null
  magick montage "$root/strip"/simple-d[0-9]-*.png -tile x1 -geometry +4+4 -background '#3a3a46' "$root/strip/demo-simple.png" 2>/dev/null
  magick -delay 90 -loop 0 "$root/strip"/simple-[0-9]-*.png -layers optimize "$root/strip/scan-simple.gif" 2>/dev/null
  check "the strip, the demo strip and the GIF were assembled" "3" "$(ls "$root/strip"/strip-*.png "$root/strip"/demo-*.png "$root/strip"/scan-*.gif 2>/dev/null | wc -l)"
  # The island's top edge is flush: the pixel row 0 is black across its width and
  # the desktop's grey beyond the fillets; the corner pixel of the strip is grey.
  check "the silhouette is black on the grey desktop (centre of the top edge black, far corner grey)" "true true" \
    "$(magick "$root/strip/simple-4-left.png" -format '%[fx:p{200,2}.r < 0.02 ? 1 : 0] %[fx:p{3,2}.r > 0.15 ? 1 : 0]' info: | sed 's/1/true/g;s/0/false/g')"
fi
[[ -n ${E3_KEEP:-} ]] && note "PNG strip and GIF kept in $E3_KEEP"

# =============================================================================

step "no QML errors from Face's files in any harness run"
errors=$(cat "$logs"/*.log 2>/dev/null | grep -E '(Enrol[A-Za-z]*|DotCard|DotStage|DotBall|RecordSession|RecordView|EnrolLink|enrol)\.(qml|js):[0-9]+.*(TypeError|ReferenceError|Unable to assign|is not a|Cannot|binding loop)' | sort -u | head -5 | cut -c1-160)
check "none" "" "$errors"

echo
if ((failures == 0)); then
  echo "${GREEN}$checks checks, all passed${RESET}"
else
  echo "${RED}$checks checks, $failures failed${RESET}"
fi
exit $((failures > 0))
