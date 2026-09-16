#!/bin/bash

# The four post-ship fixes, offscreen.
#
#   ./dev/g8-post-ship.sh
#
# These are not a phase: they are what a week of real use found, and each one is
# a thing the eight phases' gates could not have caught, because each is about a
# tenth of a second on somebody's screen or about what a view chooses NOT to
# show. They are gated here for the same reason everything else is -- so the next
# change to these files has something to break.
#
#   1  a status read asked for while another is in flight is queued, not dropped
#   2  the popup returning from a recording card opens on a re-read people.json
#   3  the appearance picker says which appearances are already recorded, and its
#      button says whether pressing it adds or replaces
#   4  Setup collapses to one line when everything it covers is `ok`, offers ONE
#      action when nothing is installed, and comes back the moment either stops
#      being true
#
# It loads the REAL FacePanel.qml, SetupView.qml, RecordCard.qml and
# RecordSession.qml against the running Omarchy's qs.Commons and qs.Ui. It draws
# nothing, so it cannot say any of it looks right; it says every binding
# evaluates and decided what the fix says it should.

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

command -v quickshell >/dev/null || { echo "g8: quickshell is not installed" >&2; exit 1; }

SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Commons ]] || {
  echo "g8: no Omarchy shell at $SHELL_PATH/shell" >&2
  exit 1
}

root=$(mktemp -d /tmp/omarchy-face-g8.XXXXXX)
state=$root/state
bin=$root/bin
fixtures=$root/fixtures
trap 'rm -rf "$root"' EXIT
mkdir -p "$state" "$bin" "$fixtures"
ln -s "$SHELL_PATH/shell/Commons" "$root/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$root/Ui"
ln -s "$REPO" "$root/face"
cp "$REPO/dev/qml-harness/post-ship.qml" "$root/shell.qml"

# The stubs, with the status helper replaced by one that is SLOW and that
# changes its answer. The repo's own stub is instant, and a fix about two reads
# overlapping cannot be tested against a helper that never overlaps anything.
cp "$REPO"/dev/bin/* "$bin/"
cat >"$bin/omarchy-face-status" <<'STUB'
#!/bin/bash
# A status read that takes its time, and that can be asked to change the world
# while it is out.
#
# It decides its answer FIRST, then -- if armed -- makes the change, then sleeps,
# then answers with what it decided. So a read that was already in flight when
# the change happened answers without it, however long it takes to come back.
# That is the timeline the queued-read fix is about, and arming the change from
# inside the read is the only way to have it without a sleep race between two
# processes.
set -uo pipefail
STATE=${OMARCHY_FACE_DEV_STATE:-}
[[ ${1:-} == --install-log ]] && exit 0
sudo_on=false
[[ -e $STATE/sudo-on ]] && sudo_on=true
printf 'read %s\n' "$sudo_on" >>"$STATE/status.log"
if [[ -e $STATE/arm ]]; then
  rm -f "$STATE/arm"
  : >"$STATE/sudo-on"
fi
sleep "${FACE_STATUS_DELAY:-0.6}"
sed "s/\"sudo\": false/\"sudo\": $sudo_on/" "$STATE/status.json"
STUB
chmod +x "$bin/omarchy-face-status"

# --- the fixtures ------------------------------------------------------------
#
# Written here rather than added to dev/fixtures, because each is one row away
# from `configured` and a fixture directory of near-identical machines is a
# fixture directory nobody can tell apart.

# A row, as `omarchy-face-status` sends it. Written through a function because
# the fixtures below differ from each other by one or two rows, and nine rows
# repeated five times is five places for a typo to look like a finding.
#
# The arguments go in as positional parameters and never into a double-quoted
# command substitution: "Face's system files" and "Omarchy's lock screen" both
# carry an apostrophe, which inside "$(...)" opens a quote and swallows the rest
# of the file.
row() { # row <id> <label> <state> <detail> <fixable> <fix>
  printf '{"id":"%s","label":"%s","state":"%s","detail":"%s","fixable":%s,"fix":"%s"},' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

rows() { # rows <name> -- prints the fixture's rows array
  {
    printf '['
    row legacy "Old install" ok "nothing left from the old version" false ""
    row camera "Infrared camera" ok "HP IR Camera, 400x400 infrared" false ""
    case $1 in
      fresh)
        row system "Face's system files" needs_action "not installed" true install-first
        row engine "Face engine" needs_action "not built" true install-engine ;;
      building)
        row system "Face's system files" ok "installed, version 2.0.0" false ""
        row engine "Face engine" needs_action "not built" true install-engine ;;
      *)
        row system "Face's system files" ok "installed, version 2.0.0" false ""
        row engine "Face engine" ok "howdy 2.6.1-3" false "" ;;
    esac
    row install-job "Engine build" ok "" false ""
    case $1 in
      fresh | building)
        row people "People" needs_action "record your face first" false "" ;;
      *)
        row people "People" ok "1 on this machine" false ""
        case $1 in
          # Somebody edited the PAM stack by hand. None of Setup's own five rows
          # moved, which is exactly why the calm state has to key on more than
          # them.
          broken) row sudo "Face for sudo" broken "the lines in /etc/pam.d/sudo are not the ones Face wrote" false "" ;;
          *)      row sudo "Face for sudo" ok "2 faces can approve sudo" false "" ;;
        esac
        row polkit-1 "polkit" ok "no face line in /etc/pam.d/polkit-1" false ""
        case $1 in
          # A repair on a row that is not one of Setup's five: the calm state
          # must not swallow it.
          lockfix) row lock "Lock screen" needs_action "the lock screen files are not in place" true lock-stage ;;
          *)       row lock "Lock screen" ok "face follows Omarchy own lock screen" false "" ;;
        esac ;;
    esac
  } | sed 's/,$//'
  printf ']'
}

idle_install='{"state":"idle","step":"","steps":["deps","fetch","build","install","configure","done"],"startedAt":0,"updatedAt":0,"error":"","notes":[]}'
running_install="{\"state\":\"running\",\"step\":\"build\",\"steps\":[\"deps\",\"fetch\",\"build\",\"install\",\"configure\",\"done\"],\"startedAt\":$(( $(date +%s) - 200 )),\"updatedAt\":$(( $(date +%s) - 20 )),\"error\":\"\",\"notes\":[]}"

# The rest of the document, around whichever rows array the case wants. Every
# field the panel reads has to be here: a status document missing a key is a
# development mistake that reads on screen as a machine in trouble.
status_doc() { # status_doc <rows-json> <install-json> <lock-compat>
  cat <<EOF
{
  "rows": $1,
  "camera": {"ir": "/dev/video2", "irSize": "400x400", "rgb": "/dev/video0"},
  "config": {"account": "graveklar", "sudo": false, "lock": true},
  "engine": {"installed": true, "howdy": "2.6.1-3", "threshold": 0.35},
  "install": $2,
  "lock": {"enabled": true, "compat": "$3", "missing": [], "otherLock": ""},
  "removal": {"people": [], "pam": [], "lockWrapper": true, "helpers": 6,
              "daemon": true, "policy": true, "packages": []}
}
EOF
}

write_status() { # write_status <fixture> [install-json]
  status_doc "$(rows "$1")" "${2:-$idle_install}" "${3:-ok}" >"$state/status.json"
}

people_one='{"people":[{"name":"testy","label":"Testy","owner":true,"sudo":true,"lock":true,
 "appearances":APPEARANCES}],"sudo_faces":2,"lock_faces":2,"maxAppearances":3,
 "appearanceLabels":["No glasses","Everyday glasses","Reading glasses"],"warning":null,"updated":1}'

run_case() { # run_case <case> [extra env assignments...]
  local name=$1; shift
  env FACE_HARNESS_CASE="$name" FACE_HARNESS_PLUGIN="$REPO" \
      OMARCHY_FACE_DEV_BIN="$bin" OMARCHY_FACE_DEV_STATE="$state" \
      OMARCHY_FACE_DEV_FIXTURES="$fixtures" "$@" \
      timeout 60 quickshell -p "$root" -n 2>&1 |
    sed -n 's/^.*HARNESS \([a-zA-Z]*\) \(.*\)$/\1=\2/p'
}

field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }

echo "G8 — the post-ship fixes, offscreen"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO${RESET}"

# --- 1 -----------------------------------------------------------------------

echo
echo "${DIM}== 1. a status read asked for while one is in flight${RESET}"
write_status ok
printf '%s' "${people_one/APPEARANCES/[]}" >"$state/people.json"
rm -f "$state/sudo-on" "$state/status.log" "$state/arm"
out=$(run_case refresh)
[[ -n $out ]] || { echo "  ${RED}FAIL${RESET}  the harness printed nothing (QML did not load)"; exit 1; }
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the config starts with sudo off" false "$(field sudoBefore "$out")"
check "the second call lands while the first is out" true "$(field busyDuring "$out")"
check "…and is remembered rather than dropped" true "$(field queuedAfterFivePokes "$out")"
check "the newest answer is on screen, long before the 30 s poll" true "$(field sudoAfter "$out")"
check "nothing is left queued" false "$(field queuedAtEnd "$out")"
# One read on start, one asked for, one queued behind it: five pokes do not buy
# five subprocesses.
# One read on start, the armed one, and exactly ONE queued behind it however
# many times it was asked for -- and the queued one is the only one that sees
# the change.
check "five overlapping calls cost exactly one extra read" "read false|read false|read true|" "$(field statusLog "$out")"

# --- 2 -----------------------------------------------------------------------

echo
echo "${DIM}== 2. the handoff back from a recording card${RESET}"
write_status ok
printf '%s' "$people_one" >"$state/people.template"
printf '%s' "${people_one/APPEARANCES/[{\"label\":\"No glasses\",\"time\":1}]}" >"$state/people.json"
rm -f "$state/status.log"
out=$(run_case handoff FACE_STATUS_DELAY=0.1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the popup was showing one appearance before the session" 1 "$(field countBefore "$out")"
check "the call is accepted" ok "$(field openAt "$out")"
check "the store is still stale at the moment of the call" 1 "$(field countAtCall "$out")"
check "the popup does not open on it" false "$(field openedImmediately "$out")"
check "it opens on the appearance that was just recorded" 2 "$(field countAtOpen "$out")"
check "…on that person's view" person "$(field view "$out")"
check "…and that person" testy "$(field person "$out")"
opened_after=$(field openedAfterMs "$out")
checks=$((checks + 1))
if [[ $opened_after -lt 400 ]]; then
  echo "  ${GREEN}pass${RESET}  the wait is the read's, not the guard timer's (${opened_after} ms)"
else
  echo "  ${RED}FAIL${RESET}  the guard timer was what opened it (${opened_after} ms)"
  failures=$((failures + 1))
fi

# --- 3 -----------------------------------------------------------------------

echo
echo "${DIM}== 3. the appearance picker${RESET}"
out=$(run_case picker FACE_STATUS_DELAY=0.1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "two recorded, one not" "✓✓·" "$(field marks "$out")"
check "the button says what each one would do" "Record again|Record again|Start" "$(field actions "$out")"
check "a capture taken in this session is marked apart from a saved one" "●" \
  "$(field markAfterCapture "$out")"
check "…and only then is the word Again" "Again" "$(field actionAfterCapture "$out")"
check "…said as the unsaved thing it is" \
  "Reading glasses was taken just now — recording it again replaces what you took, and nothing is written until you finish." \
  "$(field noteAfterCapture "$out")"
check "a recorded appearance says it would be replaced" \
  "Everyday glasses is already recorded — recording it again replaces it. A person keeps one recording per appearance." \
  "$(field noteForRecorded "$out")"
check "the marks of the other two do not move" "✓✓●" "$(field marksAtEnd "$out")"
check "a capture that failed says try again, not start" "Try again" "$(field actionAfterFailure "$out")"

echo
echo "${DIM}== 3b. the People list's appearance counts${RESET}"
write_status ok
# Three people with 2, 3 and 1 appearances, so a count that is dropped on the
# floor cannot pass by coinciding with a count that is kept.
cat >"$state/people.json" <<'PEOPLE'
{"people":[
 {"name":"graveklar","label":"Graveklar","owner":true,"sudo":true,"lock":false,
  "appearances":[{"label":"No glasses","time":1},{"label":"Everyday glasses","time":2}]},
 {"name":"anna","label":"Anna","owner":false,"sudo":true,"lock":true,
  "appearances":[{"label":"No glasses","time":3},{"label":"Everyday glasses","time":4},
                 {"label":"Reading glasses","time":5}]},
 {"name":"mia","label":"Mia","owner":false,"sudo":false,"lock":false,
  "appearances":[{"label":"No glasses","time":6}]}],
 "sudo_faces":5,"lock_faces":3,"maxAppearances":3,
 "appearanceLabels":["No glasses","Everyday glasses","Reading glasses"],
 "warning":null,"updated":6}
PEOPLE
out=$(run_case people FACE_STATUS_DELAY=0.1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the store really holds 2, 3 and 1" "2|3|1" "$(field storeCounts "$out")"
# The bug this replaces: a Repeater hands `modelData` through a QVariant, so
# Array.isArray() on a nested array is false and every count rendered as 0.
check "…and the list says so, person by person" "2|3|1" "$(field counts "$out")"
check "the owner is still rendered as You" "You|Anna|Mia" "$(field labels "$out")"

# --- 4 -----------------------------------------------------------------------

echo
echo "${DIM}== 4a. Setup on a machine where everything is in place${RESET}"
write_status ok
printf '%s' "${people_one/APPEARANCES/[{\"label\":\"No glasses\",\"time\":1}]}" >"$state/people.json"
out=$(run_case setup FACE_STATUS_DELAY=0.1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "it is calm" true "$(field calm "$out")"
check "no row is on screen" 0 "$(field rowsVisible "$out")"
check "nothing is offering an action" "" "$(field primaryLabel "$out")"
check "…what is in place, counted from the store" \
  "Camera, system files and engine are in place · 1 person recorded." "$(field calmDetail "$out")"
check "…and where a face is accepted is still said" \
  "a face unlocks the lock screen." "$(field calmWhere "$out")"
# Nine rows, less `install-job` (folded into `engine`) and `legacy` (which
# renders only when there is something left of an old install).
check "the checklist is one click away" 7 "$(field rowsVisibleWithDetails "$out")"

echo
echo "${DIM}== 4b. …and nothing installed${RESET}"
write_status fresh
rm -f "$state/people.json"
out=$(run_case setup FACE_STATUS_DELAY=0.1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "it is not calm" false "$(field calm "$out")"
check "it offers one action" "Install Face ID" "$(field primaryLabel "$out")"
check "…and not a checklist" 0 "$(field rowsVisible "$out")"
check "the rows are still there to read" 4 "$(field rowsVisibleWithDetails "$out")"
check "the bar button says set up" setup "$(field barState "$out")"

echo
echo "${DIM}== 4c. …while the engine builds${RESET}"
write_status building "$running_install"
out=$(run_case setup FACE_STATUS_DELAY=0.1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the build is on screen" true "$(field buildShown "$out")"
check "with no button beside it" "" "$(field primaryLabel "$out")"
check "it is not calm" false "$(field calm "$out")"

echo
echo "${DIM}== 4d. …and when something breaks afterwards${RESET}"
write_status broken
printf '%s' "${people_one/APPEARANCES/[{\"label\":\"No glasses\",\"time\":1}]}" >"$state/people.json"
out=$(run_case setup FACE_STATUS_DELAY=0.1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the calm state is gone" false "$(field calm "$out")"
check "every row is back without being asked for" 7 "$(field rowsVisible "$out")"
check "nothing is folded away" false "$(field collapsible "$out")"
check "and the bar button is lit" attention "$(field barState "$out")"

echo
echo "${DIM}== 4e. …and when a row that is not a setup row asks for something${RESET}"
write_status lockfix
out=$(run_case setup FACE_STATUS_DELAY=0.1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "a lock screen repair keeps the checklist open" true "$(field asking "$out")"
check "…so it is not calm" false "$(field calm "$out")"
check "…and the row with the repair is on screen" 7 "$(field rowsVisible "$out")"

echo
if ((failures == 0)); then
  echo "${GREEN}$checks checks, all passed${RESET}"
else
  echo "${RED}$checks checks, $failures failed${RESET}"
fi
exit $((failures > 0))
