#!/bin/bash

# E3: the enrol view and its ring, offscreen (plan-face-enroll.md section 7.4,
# Phase 4), in both modes.
#
#   ./dev/e3-enrol-view.sh
#   E3_KEEP=/some/dir ./dev/e3-enrol-view.sh     keep the PNG strip, the GIF and the logs
#
# HEADLESS: QT_QPA_PLATFORM=offscreen, no WAYLAND_DISPLAY, no nested compositor, no
# window anywhere, and no camera -- the picture the circle would hold is a
# counting stand-in (dev/qml-harness/enrol.qml), so "no camera in idle" is a
# count of zero. The REAL EnrolView.qml, EnrolRing.qml and RecordSession.qml run
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

echo "E3 — the enrol view and its ring, offscreen"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO   no window, no camera${RESET}"

# =============================================================================
# static: nothing in the QML the plan forbids
# =============================================================================

step "static checks on the files"
view_files=(EnrolView.qml EnrolRing.qml common/EnrolLink.qml common/enrolring.js)
check "no 'Accessibility options' anywhere in the QML" "0" \
  "$(cd "$REPO" && cat ./*.qml common/*.qml | grep -ci 'accessibility options')"
check "the new files hard-code no colour (hex, rgba or a colour name) outside comments" "" \
  "$(cd "$REPO" && for f in EnrolView.qml EnrolRing.qml common/EnrolLink.qml; do sed -E 's#//.*$##' "$f" | grep -nE '#[0-9a-fA-F]{3,8}\b|Qt\.rgba\(|"(white|black|red|green|blue|gray|grey)"' | sed "s#^#$f:#"; done)"
check "the view has no background of its own (no window, no scrim, no container animation)" "0" \
  "$(cd "$REPO" && sed -E 's#//.*$##' EnrolView.qml | grep -cE 'PanelWindow|PopupWindow|FloatingWindow|ParallelAnimation|enterAnim')"
check "EnrolView and EnrolRing never read Commons.Color.accent (the host's accent arrives in colors); only the fallbacks name the theme" "0" \
  "$(cd "$REPO" && sed -E 's#//.*$##' EnrolRing.qml | grep -c 'Color\.accent') $(sed -E 's#//.*$##' EnrolView.qml | grep -cE 'Color\.accent.*(accentColor|ring)')" | awk '{print $1 + $2}'
check "the mode travels in the sweep line and nowhere else" "1" \
  "$(cd "$REPO" && sed -E 's#//.*$##' RecordSession.qml | grep -E 'send\(' | grep -c 'activeMode\|mode:')"
check "the preview Loader is active only for previewOn AND a device (nothing else opens the camera)" "1" \
  "$(grep -c 'active: view.previewOn && view.previewDevice !== ""' "$REPO/EnrolView.qml")"
check "…and previewOn is the card being live AND the session wanting it (Start pressed)" "1" \
  "$(grep -c 'previewOn: view.live && !!view.session && view.session.previewWanted' "$REPO/EnrolView.qml")"
check "only ScanIsland.qml makes an EnrolView, and only RecordCard.qml makes a ScanIsland (nothing the notch's panel is made of names either)" "ScanIsland.qml|RecordCard.qml" \
  "$(cd "$REPO" && for f in *.qml; do sed -E 's#//.*$##' "$f" | grep -q '\bEnrolView *{' && echo "$f"; done | tr '\n' ' ' | sed 's/ $//')|$(cd "$REPO" && for f in *.qml; do sed -E 's#//.*$##' "$f" | grep -q '\bScanIsland *{' && echo "$f"; done | tr '\n' ' ' | sed 's/ $//')"
check "EnrolView is the only QML file that names RecordPreview" "EnrolView.qml" \
  "$(cd "$REPO" && grep -l 'RecordPreview' ./*.qml | sed 's#^\./##' | tr '\n' ' ' | sed 's/ $//')"
check "a pure #000000 under it is the host's: the view paints no background of its own" "0" \
  "$(cd "$REPO" && sed -E 's#//.*$##' EnrolView.qml EnrolRing.qml | grep -cE '^\s*color: *"?#?(black|000)')"

# =============================================================================
# Simple, start to finish
# =============================================================================

step "Simple: idle, Start, the centre, four targets, the end"
out=$(run simple)
echo "${DIM}$(sed 's/^/  /' <<<"$out" | head -3)  ...${RESET}"
check "the session opens in idle, in Simple" "idle simple" "$(field idle-phase "$out") $(field idle-mode "$out")"
check "idle: 60 ticks, no 61st" "60 true true true" "$(field idle-ticks "$out")"
check "idle: the four target arcs are at rest (8 px, 0.7)" \
  "rest,rest,rest,rest,rest | rest,rest,rest,rest,rest | rest,rest,rest,rest,rest | rest,rest,rest,rest,rest" "$(field idle-targets "$out")"
check "idle: …drawn 8 px at opacity 0.7" "8/0.7 8/0.7 8/0.7 8/0.7 8/0.7" "$(field idle-target-look "$out")"
check "idle: Simple's other eight bins are 5 px at 0.2 (inactive)" "5/0.2 5/0.2 5/0.2 5/0.2 5/0.2" "$(field idle-inactive "$out")"
check "idle: the demo is playing in the circle (the static glyph is hidden) with a caption under the line" "false demo true true caption Look at the camera" "$(field idle-glyph "$out")"
check "idle: no camera exists, previewOn is false, the preview Loader holds nothing" "0 false true" "$(field idle-cameras "$out")"
check "idle: the line is 'Fit your face in the circle.'" "Fit your face in the circle." "$(field idle-line "$out")"
check "idle: Cancel, Start and the mode link; no Done, Try again or Scan again" \
  "cancel=1 start=1 done=0 again=0 more=0 mode=1" "$(field idle-links "$out")"
check "idle: the mode link names the OTHER mode" "Advanced" "$(field idle-modelink "$out")"
check "idle: nothing was sent and the helper was not started" "ready 0" "$(field idle-state "$out")"
check "authorising: the camera comes on (previewOn) and the line says why we wait" "1 true Waiting for authorisation…" \
  "$(field auth-cameras "$out") $(field auth-line "$out")"
check "authorising: only Cancel; the mode link is gone" "cancel=1 start=0 done=0 again=0 more=0 mode=0" "$(field auth-links "$out")"
check "the mode is fixed from Start: the link and setMode change nothing" "true simple" "$(field mode-after-start "$out") $(field mode-inert-after-start "$out")"
check "ready with verbs: the view sends sweep, lap 1, mode simple, exactly [9,3,0,6], and nothing else" \
  '[{"cmd":"sweep","appearance":"No glasses","mode":"simple","lap":1,"targets":[9,3,0,6]}]' "$(field centre-sent "$out")"
check "…the phase is centre" "centre running" "$(field centre-phase "$out")"
check "centre: 'Look straight at the circle', then 'Hold still' once the dwell runs" \
  "Look straight at the circle|Look straight at the circle|Hold still" "$(field centre-line "$out")|$(field centre0-line "$out")|$(field centre50-line "$out")"
check "centre: the rim arc is half swept at centre 0.5" "0.5" "$(field centre50-arc "$out")"
check "centre: near the middle the head dot is absent (opacity 0)" "0" "$(jq -r .op <<<"$(field centre50-dot "$out")")"
check "centre: only Cancel is on offer (no Start over in the live view)" "cancel=1 start=0 done=0 again=0 more=0 mode=0" "$(field centre50-links "$out")"
check "lap1: the phase moves on and the rim is closed" "lap1 1" "$(field lap1-phase "$out") $(field lap1-arc "$out")"
check "lap1: the engine's first target (left) is current: 14 px, foreground, 1.0, static" \
  "14/1 14/1 14/1 14/1 14/1 | current,current,current,current,current" "$(field lap1-cur "$out")"
check "lap1: the other three targets stay at rest, the eight others inactive" \
  "8/0.7 8/0.7 8/0.7 8/0.7 8/0.7 | 8/0.7 8/0.7 8/0.7 8/0.7 8/0.7 | 8/0.7 8/0.7 8/0.7 8/0.7 8/0.7" "$(field lap1-rest "$out")"
check "…and the inactive ones never change" "5/0.2 5/0.2 5/0.2 5/0.2 5/0.2 | 5/0.2 5/0.2 5/0.2 5/0.2 5/0.2" "$(field lap1-inactive "$out")"
check "lap1: the line names the target" "Turn your head to the left" "$(field lap1-line "$out")"
check "lap1: Done is hidden while a Simple lap runs" "cancel=1 start=0 done=0 again=0 more=0 mode=0" "$(field lap1-links "$out")"
check "progress 0.4: two of the five ticks are covered (20 px accent look), three still current" \
  "done,done,current,current,current | 20/0.9 20/0.9 14/1 14/1 14/1" "$(field p40-kinds "$out") | $(field p40-look "$out")"
check "…and the line says 'Hold still' while the wedge is held" "Hold still" "$(field p40-line "$out")"
check "progress 0.55: the third tick interpolates (monotone, one tick moving)" "20/0.9 20/0.9 18.5/0.93 14/1 14/1" "$(field p55-look "$out")"
check "the dot sits about 90 px out at the engine's ring angle (u -1.5: the left, 270 degrees; it is still easing in over 100 ms)" "true true" \
  "$(jq -r '"\((.x < -88.5 and .x > -90.5)) \(.shown)"' <<<"$(field p40-dot "$out")")"
check "a target that fills stays filled (20 px, covered) after the highlight leaves" \
  "20/0.9 20/0.9 20/0.9 20/0.9 20/0.9 | done,done,done,done,done" "$(field next-9 "$out")"
check "…the next arc is current, and its line changed in the same frame" \
  "14/1 14/1 14/1 14/1 14/1 | current,current,current,current,current | Turn your head to the right" \
  "$(field next-3 "$out") | $(field next-line "$out")"
check "state words: over, edge" "A little less|Centre your face" "$(field over-line "$out")|$(field edge-line "$out")"
check "a skipped bin goes back to the rest look and the line says so" "We will skip that one | 8/0.7 8/0.7 8/0.7 8/0.7 8/0.7 | rest,rest,rest,rest,rest" \
  "$(field skip-line "$out") | $(field skip-rest "$out")"
check "a track with every bin full and canFinish shows no Done in Simple (Done arrives with swept)" \
  "cancel=1 start=0 done=0 again=0 more=0 mode=0" "$(field allfull-links "$out")"
check "swept with kept 5: 'All set.' and Done" "All set. | cancel=1 start=0 done=1 again=0 more=0 mode=0" "$(field swept-line "$out") | $(field swept-links "$out")"
check "…the ring stays full (four covered arcs) and the session holds one capture" "20/0.9 20/0.9 20/0.9 20/0.9 | swept 1" \
  "$(field swept-filled "$out") | $(field swept-state "$out")"
check "swept with kept 5: only Done (no Scan again), and the next lap begins at once through the session" \
  'more=0 | [{"cmd":"sweep","appearance":"No glasses","mode":"simple","lap":1,"targets":[9,3,0,6]}] | 8/0.7 8/0.7 8/0.7 8/0.7 8/0.7 | centre' \
  "$(field kept5-more "$out" | sed 's/^/more=/;s/^more=1$/more=1/') | $(field again-sent "$out") | $(field again-ring "$out")"
check "swept with kept 3: the line is a plain 'Enough to save.', Done and one quiet 'Scan again'" \
  "Enough to save. | cancel=1 start=0 done=1 again=0 more=1 mode=0 | Scan again" "$(field kept3-line "$out") | $(field kept3-links "$out") | $(field kept3-more-text "$out")"
check "Scan again is lap 1 again on the same session and mode (no second password), the ring empties and nothing is offered" \
  '[{"cmd":"sweep","appearance":"No glasses","mode":"simple","lap":1,"targets":[9,3,0,6]}] | 8/0.7 8/0.7 8/0.7 8/0.7 8/0.7 | centre | cancel=1 start=0 done=0 again=0 more=0 mode=0' \
  "$(field more-sent "$out") | $(field more-ring "$out" | sed 's/ | centre | / | centre | /')"
check "after the second lap kept 5 offers Done only" "cancel=1 start=0 done=1 again=0 more=0 mode=0" "$(field kept5-again "$out")"
check "Done on swept sends done and the session ends saved" "done 1 true" "$(field done-sent "$out") $(field done-finished "$out" | tr -d '\n')" 2>/dev/null
check "the view never triggered a bad_sweep (the fake enforces table V)" "0" "$(field violations "$out")"
check "…never sent capture when the helper lists sweep" "true" "$(field capture-never "$out")"
check "…and Simple never sends finish" "true" "$(field finish-never-simple "$out")"
echo "${DIM}  contrast over #000 (rest, current, done, centre arc, done vs rest): theme: $(field contrast-theme "$out"); mono (accent = foreground): $(field contrast-mono "$out"); coloured: $(field contrast-coloured "$out")${RESET}"
for p in theme mono coloured; do
  read -r rest cur done arc dvr <<<"$(field contrast-$p "$out")"
  check_ge "contrast: the rest look is at least 3:1 over #000 ($p palette)" 3 "$rest"
  check_ge "contrast: the current look is at least 3:1 ($p)" 3 "$cur"
  check_ge "contrast: the done look is at least 3:1 ($p)" 3 "$done"
  check_ge "contrast: the centre arc is at least 3:1 ($p)" 3 "$arc"
  check_ge "contrast: the done colour is not within 1.5:1 of the rest colour ($p)" 1.5 "$dvr"
done
check "accessibility: the ring says its step and progress" \
  "A demonstration of the scan, nothing is recording|Step 2 of 5, turn your head to the left, 0 percent|Step 2 of 5, turn your head to the left, 40 percent|Step 3 of 5, turn your head to the right, 0 percent|Step 3 of 5, turn your head to the right, 40 percent" \
  "$(field idle-descr "$out")|$(field lap1-descr "$out")|$(field p40-descr "$out")|$(field next-descr "$out")|$(field three-descr "$out")"

# =============================================================================
# Advanced
# =============================================================================

step "Advanced: twelve spots, any order, Done = finish, then done"
out=$(run advanced)
check "the remembered choice can be switched in idle; the link then names Simple" "advanced advanced | Simple setup" \
  "$(field adv-mode "$out") | $(field adv-idle-modelink "$out")"
check "idle: all twelve bins are on the ring at rest" "rest,rest,rest,rest,rest | rest,rest,rest,rest,rest | rest,rest,rest,rest,rest" "$(field adv-idle-rest "$out")"
check "the sweep names all twelve bins in ascending order, mode advanced" \
  '[{"cmd":"sweep","appearance":"No glasses","mode":"advanced","lap":1,"targets":[0,1,2,3,4,5,6,7,8,9,10,11]}]' "$(field adv-sent "$out")"
check "lap1 with no target under the head: no highlight at all" "rest,rest,rest,rest,rest" "$(field adv-no-current "$out")"
check "the reference's line, kept" "lap1 | Move your head slowly to complete the circle." "$(field adv-phase "$out") | $(field adv-line "$out")"
check "no Done while canFinish is false" "cancel=1 start=0 done=0 again=0 more=0 mode=0" "$(field adv-links "$out")"
check "a wedge being held: highlight on it, 'Hold still'" "Hold still | done,current,current,current,current | 20/0.9 14/1 14/1 14/1 14/1" \
  "$(field adv-hold-line "$out") | $(field adv-current "$out")"
check "any fill order renders (5 full, 2 partial)" "done,done,done,done,done | done,done,current,current,current | 20/0.9 20/0.9 14/1 14/1 14/1" "$(field adv-any-order "$out")"
check "Done appears once canFinish is true" "cancel=1 start=0 done=1 again=0 more=0 mode=0" "$(field adv-done-shown "$out")"
check "…and sends finish; swept then offers Done again (done), twice by design" "finish | All set. | done" \
  "$(field adv-finish-sent "$out") | $(field adv-swept-line "$out") | $(field adv-done-sent "$out")"
check "accessibility: one ProgressBar for the ring plus one per target (13 in Advanced)" "13" "$(field adv-target-items "$out")"
check "accessibility: 'N of 12 positions'" "1 of 12 positions|5 of 12 positions" "$(field adv-descr "$out")|$(field adv-descr-5 "$out")"
check "the view never triggered a bad_sweep and never sent capture" "0 true" "$(field adv-violations "$out") $(field adv-capture-never "$out")"

# =============================================================================
# Esc from every phase, failures, version skew
# =============================================================================

step "Esc is honoured in every phase and sends EOF"
out=$(run esc)
check "idle: Esc closes with nothing to discard (no process)" "0 1 false" "$(field esc-idle "$out")"
check "authorising: Esc is EOF to the pkexec'd session; no camera" "1 closing 1 0" "$(field esc-authorising "$out")"
check "centre: Esc is EOF, the camera is gone, the line says 'Nothing was saved'" "1 1 0 Nothing was saved" "$(field esc-centre "$out")"
check "lap1: Esc is EOF and saves nothing" "1 1 false 0" "$(field esc-lap1 "$out")"
check "swept: Esc discards (it never saves; Done does)" "1 1 false 0 sent=EOF" "$(field esc-swept "$out")"
check "verdict: Esc is EOF" "1 1 false" "$(field esc-verdict "$out")"
check "…and never a bad_sweep along the way" "0" "$(field esc-done "$out")"

step "Failures: the outcome list, the shake, Try again"
out=$(run fail)
for code in too_few lap_timeout bad_sweep changed; do
  case $code in
    too_few) text="Only a few positions were reached. Try again." ;;
    lap_timeout) text="That took too long. Nothing was saved." ;;
    bad_sweep) text="Something went wrong. Try again." ;;
    changed) text="That was not you" ;;
  esac
  check "$code: verdict, its line, Try again, the circle shakes, the ring is empty, no camera" \
    "verdict | $text | cancel=1 start=0 done=0 again=1 more=0 mode=0 | shake true | ring 8/0.7 | cameras 0 | ready" "$(field fail-$code "$out")"
  check "$code: Try again is lap 1 again, same mode, and the camera is back" \
    'centre | {"cmd":"sweep","appearance":"No glasses","mode":"simple","lap":1,"targets":[9,3,0,6]} | cameras 1' "$(field retry-$code "$out")"
done
check "'other' is a word: its line, no shake, the lap goes on" "Face the circle and hold still. | shake false | phase lap1" "$(field other-line "$out")"
check "not_enough leaves the lap running with its line" "lap1 | A few more positions first. | running" "$(field not-enough "$out")"
check "sweep_stalled leaves the lap running with its line" "lap1 | Try turning a little further." "$(field stalled "$out")"
check "polkit refused: back to idle with the reason, a shake, no camera, Start offered again" \
  "idle | Fit your face in the circle. | Not authorised. | shake true | previewOn false | cameras 0 | cancel=1 start=1 done=0 again=0 more=0 mode=1" "$(field declined "$out")"
check "no failure case made the view send a verb the table refuses" "0" "$(field fail-violations "$out")"

step "Version skew: a helper older than 3.1.0 gets the existing single capture"
out=$(run skew)
check "before Start nothing is different (the idle view)" "idle false" "$(field skew-idle "$out")"
check "ready without verbs: the countdown of the single capture, in the legacy view" "countdown true | true" "$(field skew-phase "$out") | $(field skew-legacy-view "$out")"
check "…the picker and its Start are the old ones" "Start" "$(field skew-picker "$out")"
check "…it says why, in the old helper's note" "Finish the update in a terminal for the full scan" "$(field skew-note-text "$out")"
check "…capture (not sweep) is what it sends" "capture | countdown" "$(field skew-capture-after-countdown "$out")"
check "…and no sweep was ever sent" "true" "$(field skew-no-sweep "$out")"
check "…the verdict closes the preview" "verdict good cameras 0" "$(field skew-verdict "$out")"

step "A session that is not the scan (what g3 and g8 drive) is untouched"
out=$(run plain)
check "framing, scan off, the legacy view, the camera as before" "framing scan=false legacy=true" "$(field plain-phase "$out")"
check "ready with verbs on a non-scan session still goes to the countdown" "countdown  sweepFlow=false" "$(field plain-after-ready "$out")"

# =============================================================================
# Reduced motion, the hairline, the fence
# =============================================================================

step "Reduced motion: nothing depends on a running animation"
out=$(run reduced)
check "the done look, the highlight, and the dot are all there with every animation off" \
  "20/0.9 20/0.9 20/0.9 14/1 14/1" "$(field reduced-shown "$out")"
check "…the dot is at its place without easing" "-90 true" \
  "$(jq -r '"\((.x | round)) \(.shown)"' <<<"$(field reduced-dot "$out")")"
check "…no hairline frames" "false false" "$(field reduced-hairline "$out") $(field reduced-hairline-after-frames "$out")"
check "…and no demo: not running, not drawn, the clock never moved (a scan is running, so no static glyph either)" "false false t 0 glyph false" "$(field reduced-demo "$out")"

step "The hairline runs on accepted frames only"
out=$(run hairline)
check "it rests before any frame, and on dark, blurry, other, searching, multiple, edge" "false false false false false false false" \
  "$(field hair-before "$out") $(field hair-dark "$out") $(field hair-blurry "$out") $(field hair-other "$out") $(field hair-searching "$out") $(field hair-multiple "$out") $(field hair-edge "$out")"
check "…runs on an accepted frame, rests when done, re-arms on the next" "true false true false" \
  "$(field hair-hold "$out") $(field hair-rested "$out") $(field hair-rearmed "$out") $(field hair-done "$out")"

step "The idle demo: what the scan will ask, played while nothing runs (no camera)"
out=$(run demo)
check "idle: it plays, in the circle, with no camera object and the static glyph hidden" "true true cameras 0 glyph false" "$(field demo-state "$out")"
check "Simple: the captions follow the order the engine takes (centre, left, right, up, down, all set)" \
  "Look at the camera | Turn your head to the left | Turn your head to the right | Tilt your head up | Tilt your head down | All set." "$(field simple-captions "$out")"
check "…the head turns to each side as the matching arc fills (turn left/right to the limit, nod up/down), the rim closes, all four fill" \
  '{"rim":true,"leftYaw":true,"leftFill":"done,done,done,done,done","rightYaw":true,"rightFill":"done,done,done,done,done","upPitch":true,"downPitch":true,"allFilled":true}' "$(field simple-seen "$out")"
check "Advanced: one slow turn under the reference's line, and all twelve arcs fill in one sweep, never emptying on the way" \
  'advanced|Move your head slowly to complete the circle. | The circle is complete.|{"top":12,"monotone":true}' \
  "$(field adv-mode "$out")|$(field adv-captions "$out")|$(field adv-seen "$out")"
check "Start stops it at once: not running, not drawn, its clock frozen, no caption, and the ring is the session's (empty, no target)" \
  "false false true caption '' [0,0,0,0] target null cameras 1" "$(field start-stopped "$out") $(field start-ring "$out")"
out=$(run demo-reduced)
check "reduced motion: not running, not drawn, the clock never moves, the static glyph and one caption line (per mode)" \
  "false false|0|true|Then turn left, right, up and down.|Then turn slowly all the way round." \
  "$(field running "$out")|$(field t "$out")|$(field glyph "$out")|$(field caption "$out")|$(field caption-advanced "$out")"
check "…and the ring is at rest (nothing fills, no rim)" "8/0.7 8/0.7 8/0.7 8/0.7 8/0.7 | 0" "$(field ring "$out")"
out=$(run demo-hidden)
check "a card that is not on screen costs nothing: not running, clock frozen; and it plays again when shown" "false true|true" "$(field hidden "$out")|$(field shown "$out")"

step "The camera fence (6a.1): the preview exists only after Start and only while the host shows the view"
out=$(run fence)
check "idle: no camera object, and the demo has been running (it needs none)" "0 false false true true" "$(field fence-idle "$out")"
check "Start (authorising): the camera is wanted and exists" "1 true authorising" "$(field fence-authorising "$out")"
check "lap1: still on" "1 true lap1" "$(field fence-lap1 "$out")"
check "the host stops showing the view (route change, notch closed, bar hidden): gone within 200 ms" "0 false" "$(field fence-host-hidden "$out")"
check "…and back when it shows the view again" "1 true" "$(field fence-host-shown "$out")"
check "a failed lap (verdict): gone" "0 false verdict" "$(field fence-verdict "$out")"
check "Try again: back" "1 true centre" "$(field fence-retry "$out")"
check "Done (closing): gone" "0 closing false" "$(field fence-closing "$out")"
check "a new session starts at zero cameras and a destroyed session leaves none" "1 0" "$(field fence-second-auth "$out") $(field fence-destroyed "$out")"

# =============================================================================
# The remembered mode and its file
# =============================================================================

step "The mode file: path, one word, 16 bytes, fallback, FIFO, symlink, unwritable"
mkhome() { local h=$root/state-$1; rm -rf "$h"; mkdir -p "$h/omarchy-face"; echo "$h"; }
mode_run() { # mode_run <state home> [ACT] [STORED]
  run mode OMARCHY_FACE_DEV_STATE_HOME="$1" E3_MODE_ACT="${2:-none}" E3_STORED="${3:-0}"
}

h=$(mkhome missing)
out=$(mode_run "$h")
check "no file: simple, idle at once" "simple phase idle" "$(field mode-first "$out" | sed 's/ after.*//')"
check "…Start works" "authorising" "$(field mode-start-works "$out")"

h=$(mkhome adv); printf 'advanced' >"$h/omarchy-face/enrol-mode"
out=$(mode_run "$h")
check "the word 'advanced' is read (within a second, while idle)" "advanced" "$(field mode-settled "$out")"
h=$(mkhome advnl); printf 'advanced\n' >"$h/omarchy-face/enrol-mode"
check "…with a newline too" "advanced" "$(field mode-settled "$(mode_run "$h")")"
h=$(mkhome garbage); printf 'turbo\x00\xff\n' >"$h/omarchy-face/enrol-mode"
check "garbage reads as simple" "simple" "$(field mode-settled "$(mode_run "$h")")"
h=$(mkhome long); printf 'advancedxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >"$h/omarchy-face/enrol-mode"
check "more than 16 bytes: only the first 16 are read, so it is not the word" "simple" "$(field mode-settled "$(mode_run "$h")")"
h=$(mkhome empty); : >"$h/omarchy-face/enrol-mode"
check "an empty file reads as simple" "simple" "$(field mode-settled "$(mode_run "$h")")"

h=$(mkhome fifo); mkfifo "$h/omarchy-face/enrol-mode"
t0=$(date +%s%3N)
out=$(mode_run "$h" start)
t1=$(date +%s%3N)
check "a FIFO at the path: the view draws in simple at once and reaches idle" "simple phase idle" "$(field mode-first "$out" | sed 's/ after.*//')"
check "…Start still works, the mode link is gone, and the link changes nothing after Start" "authorising 0 | simple" \
  "$(field mode-start-phase "$out" | sed 's/^\(.*\) \(.\)$/\1 \2/' | awk '{print $1" "$2}') | $(field mode-after-start-click "$out")"
check "…and the whole run (a second's wait for the read included) finished in time" "true" "$([[ $((t1 - t0)) -lt 20000 ]] && echo true || echo false)"
sleep 1.2
check "…no 'head' is left blocked on the FIFO afterwards" "0" "$(pgrep -fc "head -c 16 -- $h" || true)"

h=$(mkhome symlink); printf 'advanced' >"$h/real"; ln -s "$h/real" "$h/omarchy-face/enrol-mode"
check "a symlink to an ordinary file is read as the file (harmless)" "advanced" "$(field mode-settled "$(mode_run "$h")")"
h=$(mkhome symfifo); mkfifo "$h/fifo"; ln -s "$h/fifo" "$h/omarchy-face/enrol-mode"
out=$(mode_run "$h")
check "a symlink to a FIFO: simple, idle, no hang" "simple phase idle" "$(field mode-first "$out" | sed 's/ after.*//')"
h=$(mkhome symzero); ln -s /dev/zero "$h/omarchy-face/enrol-mode"
check "a symlink to /dev/zero reads 16 bytes and no more: simple" "simple" "$(field mode-settled "$(mode_run "$h")")"

h=$(mkhome click)
out=$(mode_run "$h" click)
check "the mode link switches the mode in the view" "advanced" "$(field mode-clicked "$out")"
sleep 0.4
check "…and writes exactly the one word (8 bytes, no newline)" "advanced 8" "$(cat "$h/omarchy-face/enrol-mode" 2>/dev/null) $(stat -c %s "$h/omarchy-face/enrol-mode" 2>/dev/null)"
check "…and the next session (the other home reading the same file) opens in advanced" "advanced" "$(field mode-settled "$(mode_run "$h")")"
out=$(mode_run "$h" click)
sleep 0.4
check "…and clicking again goes back to simple" "simple" "$(cat "$h/omarchy-face/enrol-mode" 2>/dev/null)"
check "…leaving no temporary file behind" "enrol-mode" "$(ls -A "$h/omarchy-face")"

h=$(mkhome clickfifo); mkfifo "$h/omarchy-face/enrol-mode"
out=$(mode_run "$h" click)
sleep 0.5
check "writing over a FIFO replaces it with an ordinary file and never blocks" "regular file" "$(stat -c %F "$h/omarchy-face/enrol-mode")"

h=$root/state-nodir
out=$(mode_run "$h" click)
sleep 0.4
check "a state home that does not exist yet is made, with the file in it" "advanced" "$(cat "$h/omarchy-face/enrol-mode" 2>/dev/null)"

h=$(mkhome ro); chmod 555 "$h/omarchy-face"
out=$(mode_run "$h" click)
sleep 0.4
check "an unwritable state home is silent: the view switches, no file, no error line" "advanced | no file | none" \
  "$(field mode-clicked "$out") | $([[ -e $h/omarchy-face/enrol-mode ]] && echo file || echo "no file") | $(grep -ciE 'error|permission denied' "$logs/mode.log" | awk '{print ($1 > 0) ? "some" : "none"}')"
chmod 755 "$h/omarchy-face"

real=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-face/enrol-mode
before=$(stat -c %Y "$real" 2>/dev/null || echo none)
out=$(run mode E3_MODE_ACT=click)
sleep 0.4
check "a harness with no named state home touches no real state (the path is empty)" "$before" "$(stat -c %Y "$real" 2>/dev/null || echo none)"

h=$(mkhome r6); printf 'simple' >"$h/omarchy-face/enrol-mode"
out=$(mode_run "$h" none 6)
check "rule R: an appearance with 6 stored templates opens in Advanced, with no Simple link" "false advanced link 0 Advanced" "$(field mode-allowed "$out" | sed 's/^\(false advanced link 0\) .*/\1 Advanced/;s/^\(true.*\)$/\1/')"
check "…and the remembered file is not rewritten" "simple" "$(cat "$h/omarchy-face/enrol-mode")"
h=$(mkhome r5)
out=$(mode_run "$h" none 5)
check "rule R: 5 stored templates may still be re-scanned in Simple" "true simple link 1 Advanced" "$(field mode-allowed "$out")"

# =============================================================================
# The PNG strip and the GIF
# =============================================================================

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
out=$(run scrim-reduced)
check "reduced motion: 55% from the very first frame (no fade of its own), and 0 the moment the island leaves" "0.55 reduced true|0" "$(field first "$out")|$(field retract-first "$out")"
scrim_shape=no
if grep -q 'PanelWindow' "$REPO/ScanScrim.qml" && grep -q 'WlrKeyboardFocus.None' "$REPO/ScanScrim.qml" \
   && ! grep -q 'mask:' "$REPO/ScanScrim.qml" && ! sed -E 's#//.*$##' "$REPO/ScrimLayer.qml" | grep -q 'PanelWindow'; then scrim_shape=yes; fi
scrim_namers=$(cd "$REPO" && for f in *.qml; do sed -E 's#//.*$##' "$f" | grep -q 'ScanScrim' && echo "$f"; done | tr '\n' ' ')
check "the files: ScrimLayer is no window; ScanScrim is one (Overlay, no keyboard, no mask) named only by the service" "yes Service.qml " "$scrim_shape $scrim_namers"

step "The ring on the island, rendered (Simple and Advanced), a strip and a short GIF"
mkdir -p "$root/strip"
for m in simple advanced; do
  run strip E3_OUT="$root/strip" E3_MODE_ACT=$m >/dev/null
done
frames=$(ls "$root/strip"/*.png 2>/dev/null | wc -l)
check "frames were drawn (Simple: seven scan frames and five demo steps; Advanced: six and four)" "22" "$frames"
if (( frames > 0 )); then
  for f in "$root/strip"/*.png; do
    # The window's grey is the desktop; the island is black on it. Flatten onto it
    # and cut the strip to the island's height.
    magick "$f" -background '#3a3a46' -flatten -gravity north -crop 400x520+0+0 +repage "$f"
  done
  for m in simple advanced; do
    magick montage "$root/strip/$m"-[0-9]-*.png -tile x1 -geometry +4+4 -background '#3a3a46' "$root/strip/strip-$m.png" 2>/dev/null
    magick montage "$root/strip/$m"-d[0-9]-*.png -tile x1 -geometry +4+4 -background '#3a3a46' "$root/strip/demo-$m.png" 2>/dev/null
    magick -delay 90 -loop 0 "$root/strip/$m"-[0-9]-*.png -layers optimize "$root/strip/ring-$m.gif" 2>/dev/null
  done
  check "the strips and the GIFs were assembled" "6" "$(ls "$root/strip"/strip-*.png "$root/strip"/demo-*.png "$root/strip"/ring-*.gif 2>/dev/null | wc -l)"
  # The island's top edge is flush: the pixel row 0 is black across its width and
  # the desktop's grey beyond the fillets; the corner pixel of the strip is grey.
  check "the silhouette is black on the grey desktop (centre of the top edge black, far corner grey)" "true true" \
    "$(magick "$root/strip/simple-3-left30.png" -format '%[fx:p{200,2}.r < 0.02 ? 1 : 0] %[fx:p{3,2}.r > 0.15 ? 1 : 0]' info: | sed 's/1/true/g;s/0/false/g')"
fi
[[ -n ${E3_KEEP:-} ]] && note "PNG strip and GIF kept in $E3_KEEP"

# =============================================================================

step "no QML errors from Face's files in any harness run"
errors=$(cat "$logs"/*.log 2>/dev/null | grep -E '(Enrol[A-Za-z]*|RecordSession|RecordView|EnrolLink|enrol)\.(qml|js):[0-9]+.*(TypeError|ReferenceError|Unable to assign|is not a|Cannot|binding loop)' | sort -u | head -5 | cut -c1-160)
check "none" "" "$errors"

echo
if ((failures == 0)); then
  echo "${GREEN}$checks checks, all passed${RESET}"
else
  echo "${RED}$checks checks, $failures failed${RESET}"
fi
exit $((failures > 0))
