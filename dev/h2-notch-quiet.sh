#!/bin/bash

# The notch steps out of the way while a Face card is up (Service.qml, common/NotchQuiet.qml).
#
#   ./dev/h2-notch-quiet.sh
#
# Headless apart from the card: the real Service.qml in a QML runtime (dev/qml-harness/quiet.qml),
# the dev stub engine behind it, and a stand-in for `omarchy-shell notch quiet` that only writes
# down what it was asked (OMARCHY_FACE_DEV_QUIET_CMD). Nothing reaches the live notch: in
# development the service asks nobody unless a test names that stand-in.
#
# It proves: the Test card asks when it comes up and lets go when it is answered and dismissed,
# stopped, or destroyed; the recording card the same; one `on` and one `off` for one card, the lease
# renewed while it lives; a card that never came up asks for nothing; a `sudo` card (the
# indicator) never asks; nothing breaks, and nothing is slower, when the notch has no such verb or
# is not there at all; and the in-place Test inside the notch's own panel leaves the notch alone.
# What it cannot: that the notch really hides -- the notch's own dev/quiet.sh proves that, and
# the two meet at the words of `omarchy-shell notch quiet <on|off> <owner>`.

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
step() { echo; echo "${DIM}== $*${RESET}"; }

command -v quickshell >/dev/null || { echo "h2-quiet: quickshell is not installed" >&2; exit 1; }

SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Commons ]] || { echo "h2-quiet: no Omarchy shell at $SHELL_PATH/shell" >&2; exit 1; }

root=$(mktemp -d /tmp/omarchy-face-h2.XXXXXX)
state=$root/state
log=$root/quiet.log
trap 'rm -rf "$root"' EXIT
mkdir -p "$state"
ln -s "$SHELL_PATH/shell/Commons" "$root/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$root/Ui"
ln -s "$REPO" "$root/face"
cp "$REPO/dev/qml-harness/quiet.qml" "$root/shell.qml"
cp "$REPO/dev/fixtures/three-people/people.json" "$state/people.json"

# What the notch would have been told: one line per call, "<ms since epoch> <args>".
cat >"$root/quiet-stub" <<STUB
#!/bin/bash
echo "\$(date +%s%3N) \$*" >>"$log"
exit 0
STUB
chmod +x "$root/quiet-stub"

run_case() { # run_case <case> [env…]
  local name=$1
  shift
  : >"$log"
  env FACE_HARNESS_CASE="$name" FACE_HARNESS_PLUGIN="$REPO" \
    OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_STATE="$state" \
    OMARCHY_FACE_DEV_FIXTURE=three-people \
    "$@" timeout 60 quickshell -p "$root" -n 2>&1 |
    sed -n 's/^.*HARNESS \([a-zA-Z0-9]*\) \(.*\)$/\1\t\2/p'
}

# When the harness stopped, so that an `off` can be shown to have come BEFORE the service was destroyed
# (destroying it lets go too, and would otherwise hide a card that forgot to).
ended() { awk -F'\t' '$1=="ended"{print $2}' <<<"$1"; }
field() { awk -v key="$1" -F'\t' '$1 == key {print $2}' <<<"$2" | head -1; }
# Comments blanked: a comment that says why a call is not made is not the call.
code() { sed -E 's#//.*$##' "$@"; }
calls() { sed 's/^[0-9]* //' "$log" 2>/dev/null | tr '\n' ';'; }
count() { grep -c "$1" "$log" 2>/dev/null; }
stamp() { sed -n "s/^\([0-9]*\) $1\$/\1/p" "$log" | head -1; }

echo "Face — the notch steps aside for a card, offscreen"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO${RESET}"

step "the Test card: asked when it comes up, let go of when it is dismissed"
out=$(run_case test OMARCHY_FACE_DEV_QUIET_CMD="$root/quiet-stub" OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=2)
[[ -n $out ]] || { echo "  ${RED}FAIL${RESET}  the harness printed nothing (QML did not load)"; exit 1; }
check "the card was made" "ok" "$(awk -F'\t' '$1=="call"{print $2}' <<<"$out")"
check "one on, then one off, both under the Test's own owner" "on kalinewb.face:test;off kalinewb.face:test;" "$(calls)"
on_at=$(stamp "on kalinewb.face:test"); off_at=$(stamp "off kalinewb.face:test")
# 2 s of check + 3.2 s on screen after the answer, less slack for timers.
check "…and the off came only once the card had had its time on screen (check + verdict, over 4 s)" "true" \
  "$([[ -n $on_at && -n $off_at && $((off_at - on_at)) -gt 4000 ]] && echo true || echo "false (${on_at:-?} ${off_at:-?})")"
check "…and it was sent by the card's own teardown, before the harness ended" "true" \
  "$([[ -n $off_at && $off_at -lt $(ended "$out") ]] && echo true || echo "false ($off_at $(ended "$out"))")"

step "stopped by the person"
out=$(run_case stop OMARCHY_FACE_DEV_QUIET_CMD="$root/quiet-stub" OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=8)
check "on, then off at the Stop, not at the safety net 25 s later" "on kalinewb.face:test;off kalinewb.face:test;" "$(calls)"
on_at=$(stamp "on kalinewb.face:test"); off_at=$(stamp "off kalinewb.face:test")
check "…within two seconds of the card coming up" "true" \
  "$([[ -n $on_at && -n $off_at && $((off_at - on_at)) -lt 2000 ]] && echo true || echo "false (${on_at:-?} ${off_at:-?})")"
check "…and before the harness ended, so not by the service being destroyed" "true" \
  "$([[ -n $off_at && $((off_at + 400)) -lt $(ended "$out") ]] && echo true || echo "false ($off_at $(ended "$out"))")"

step "the recording card (the scan island), cancelled with Esc"
rm -f "$state/session.log"
out=$(run_case record OMARCHY_FACE_DEV_QUIET_CMD="$root/quiet-stub")
check "the card was made" "ok" "$(awk -F'\t' '$1=="call"{print $2}' <<<"$out")"
check "on when it came up, off when it had retracted, under the scan's owner" \
  "on kalinewb.face:record;off kalinewb.face:record;" "$(calls)"
on_at=$(stamp "on kalinewb.face:record"); off_at=$(stamp "off kalinewb.face:record")
check "…the off after the Esc (1.2 s in) and its 240 ms retract, not before" "true" \
  "$([[ -n $on_at && -n $off_at && $((off_at - on_at)) -gt 1000 ]] && echo true || echo "false (${on_at:-?} ${off_at:-?})")"
check "…and before the harness ended, so not by the service being destroyed" "true" \
  "$([[ -n $off_at && $((off_at + 400)) -lt $(ended "$out") ]] && echo true || echo "false ($off_at $(ended "$out"))")"
check "…and the card's state was a record while it was up" "record" \
  "$(awk -F'\t' '$1=="state"{print $2}' <<<"$out" | jq -r '.duties | join(",")' 2>/dev/null)"

step "a long card keeps the lease alive (the notch's lease is 35 s; here renewed every second)"
out=$(run_case renew OMARCHY_FACE_DEV_QUIET_CMD="$root/quiet-stub" OMARCHY_FACE_DEV_QUIET_RENEW_MS=1000 \
  OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=3)
ons=$(count "on kalinewb.face:test")
check "more than one on while it lived (the first, then at least two renewals)" "true" "$([[ $ons -ge 3 ]] && echo true || echo "false ($ons)")"
check "…and exactly one off, and it is the last call" "1 off kalinewb.face:test" \
  "$(count "off kalinewb.face:test") $(tail -n 1 "$log" | sed 's/^[0-9]* //')"

step "the service going away with a card up lets go too"
out=$(run_case teardown OMARCHY_FACE_DEV_QUIET_CMD="$root/quiet-stub" OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=8)
check "off is sent when the service is destroyed, not left to the lease" "on kalinewb.face:test;off kalinewb.face:test;" "$(calls)"

step "the in-place Test: the indicator's own verdict card must not land on the notch's panel"
# The daemon writes `matched` the moment the check answers, and the indicator draws "Recognised ..." /
# "Asked by Profiles" for 1.6 s after it. The panel says `off` when its view stops; letting go any earlier
# (at the answer, as 3.3.1 did) drew that card over the panel, a second verdict on top of the first.
rm -f "$state/state.json"
( sleep 1.4; printf '{"state":"matched","service":"identity","requester":{},"person":"anna","detail":"","at":%s}\n' \
    "$(date +%s%3N)" >"$state/state.json" ) &
writer=$!
out=$(run_case inplace OMARCHY_FACE_DEV_QUIET_CMD="$root/quiet-stub")
wait "$writer" 2>/dev/null
echo "${DIM}$(sed 's/^/  /' <<<"$out" | grep -E 'whileOn|justOff|held|after')${RESET}"
check "while the view is up the indicator's identity card is away, though the daemon wrote matched" "false" "$(field whileOn "$out")"
check "GATE: the moment after the view stops it is still away (the matched card has 1.6 s to run)" "false" "$(field justOff "$out")"
check "…and 1.5 s after, still inside the hold" "false" "$(field held "$out")"
check "…and once the hold is over there is no card left to show" "false" "$(field after "$out")"
check "the view does not let go when the check answers: no tellService(off) between the stream and stop()" "0" \
  "$(code "$REPO/TestResultView.qml" | sed -n '/ask.stream(/,/safety.restart()/p' | grep -c 'tellService("off")')"
rm -f "$state/state.json"

step "a sudo card is never a reason to hide the notch"
printf '{"state":"start","service":"sudo","requester":{"command":"pacman","from":"foot"},"person":"","detail":"looking","at":%s}\n' \
  "$(date +%s%3N)" >"$state/state.json"
out=$(run_case idle OMARCHY_FACE_DEV_QUIET_CMD="$root/quiet-stub")
check "the indicator was drawing it" "true sudo" \
  "$(awk -F'\t' '$1=="state"{print $2}' <<<"$out" | jq -r '"\(.indicator.showing) \(.indicator.service)"' 2>/dev/null)"
check "…and nothing was asked of the notch" "" "$(calls)"
rm -f "$state/state.json"
check "the indicator and the lock screen have no notch call in them" "0 0" \
  "$(grep -c 'NotchQuiet\|notch quiet' "$REPO/Indicator.qml" "$REPO/IndicatorCard.qml" 2>/dev/null | awk -F: '{s+=$2} END {print s}') $(grep -rc 'NotchQuiet\|notch quiet' "$REPO/lock" | awk -F: '{s+=$2} END {print s}')"

step "in development nothing reaches a real notch unless a test says where"
out=$(run_case test OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=1)
check "no stand-in named: the card ran and nobody was called" "ok" "$(awk -F'\t' '$1=="call"{print $2}' <<<"$out")"
check "…the stand-in heard nothing" "" "$(calls)"

step "a notch with no such verb, or no notch at all, changes nothing"
start=$(date +%s%3N)
out=$(run_case test OMARCHY_FACE_DEV_QUIET_CMD="$root/does-not-exist" OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=1)
check "a command that is not there: the card still runs and answers" "ok" "$(awk -F'\t' '$1=="call"{print $2}' <<<"$out")"
check "…with no error from the QML (nothing in the output but the harness's own lines)" "0" \
  "$(timeout 60 env FACE_HARNESS_CASE=test FACE_HARNESS_PLUGIN="$REPO" OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_STATE="$state" \
       OMARCHY_FACE_DEV_FIXTURE=three-people OMARCHY_FACE_DEV_QUIET_CMD="$root/does-not-exist" OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=1 \
       quickshell -p "$root" -n 2>&1 | grep -aEc '\.qml:[0-9]+.*(TypeError|ReferenceError)')"
printf '#!/bin/bash\necho "Target not found." >&2\nexit 1\n' >"$root/refusing"
chmod +x "$root/refusing"
out=$(run_case test OMARCHY_FACE_DEV_QUIET_CMD="$root/refusing" OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=1)
check "a notch that answers 'Target not found' (another bar): the same" "ok" "$(awk -F'\t' '$1=="call"{print $2}' <<<"$out")"
printf '#!/bin/bash\nsleep 30\n' >"$root/hanging"
chmod +x "$root/hanging"
out=$(run_case test OMARCHY_FACE_DEV_QUIET_CMD="$root/hanging" OMARCHY_FACE_DEV_VERIFY=0 OMARCHY_FACE_DEV_VERIFY_SECONDS=1)
check "a verb that never answers does not hold the card up either" "ok" "$(awk -F'\t' '$1=="call"{print $2}' <<<"$out")"

step "asserted as text (the card's windows cannot be asked what they said)"
check "the in-place Test, inside the notch's own panel, does not ask the notch to hide" "0" \
  "$(code "$REPO/TestResultView.qml" | grep -cE 'NotchQuiet|notchQuiet|notch quiet')"
check "Face's panel (Surface.qml) and views never call it either: only the service's two cards do" "0" \
  "$(for f in "$REPO"/*.qml; do [[ $f == "$REPO/Service.qml" ]] && continue; code "$f" | grep -qE 'NotchQuiet|notchQuiet' && echo "$f"; done | wc -l)"
check "the card is asked for once per card, in the one place each is made" "1 1" \
  "$(grep -c 'notchQuiet.on("record")' "$REPO/Service.qml") $(grep -c 'notchQuiet.on("test")' "$REPO/Service.qml")"
check "…and let go of in the one place each is torn down" "1 1" \
  "$(grep -c 'notchQuiet.off("record")' "$REPO/Service.qml") $(grep -c 'notchQuiet.off("test")' "$REPO/Service.qml")"
check "the client keeps no state of the notch's: a hold is a reason, the lease is the notch's" "true" \
  "$(grep -q 'The notch holds the request as a lease' "$REPO/common/NotchQuiet.qml" && echo true || echo false)"

echo
if ((failures)); then
  echo "${RED}$failures of $checks checks failed.${RESET}"
  exit 1
fi
echo "${GREEN}All $checks checks pass.${RESET}"
