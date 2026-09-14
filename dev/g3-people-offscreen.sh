#!/bin/bash

# G3/G4: the People and Person views, the name rule, and the recording session,
# in a real QML runtime with no shell and no window (plan-merged.md §4 phase 4).
#
#   ./dev/g3-people-offscreen.sh
#
# Three of the gate's five clauses are GUI-side, and this is where they are
# proved:
#
#   * a slow polkit dialog still yields a full 3-2-1 after `ready` -- the
#     session is started through a stand-in `pkexec` that sits for ten seconds
#     before exec'ing, and the countdown is measured from `ready`, not from the
#     click;
#   * Esc before a capture writes nothing -- the session is cancelled the only
#     way a root process can be cancelled, by closing its stdin, and the
#     stand-in engine records whether it ended `discarded` or was killed;
#   * names derive as "Åse" → ase, "2 Kids" → p-2-kids, a second "Anna" →
#     anna-2, against the real common/names.js.
#
# The owner-cannot-be-removed clause is here too, as the half that belongs to
# the GUI (the Person view has no Remove row for the owner). The other half --
# the verb refusing it -- is dev/f3-people-store.sh, because a control that is
# not rendered is not an enforcement.

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

at_least() { # at_least <description> <minimum> <actual>
  checks=$((checks + 1))
  if [[ ${3:-} =~ ^-?[0-9]+$ ]] && (( $3 >= $2 )); then
    echo "  ${GREEN}pass${RESET}  $1 ${DIM}($3)${RESET}"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected at least $2, got '${3:-}')${RESET}"
    failures=$((failures + 1))
  fi
}

between() { # between <description> <low> <high> <actual>
  checks=$((checks + 1))
  if [[ ${4:-} =~ ^-?[0-9]+$ ]] && (( $4 >= $2 && $4 <= $3 )); then
    echo "  ${GREEN}pass${RESET}  $1 ${DIM}($4 ms)${RESET}"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected $2-$3 ms, got '${4:-}')${RESET}"
    failures=$((failures + 1))
  fi
}

command -v quickshell >/dev/null || { echo "g3-offscreen: quickshell is not installed" >&2; exit 1; }

SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Commons ]] || {
  echo "g3-offscreen: no Omarchy shell at $SHELL_PATH/shell" >&2
  exit 1
}

root=$(mktemp -d /tmp/omarchy-face-g3.XXXXXX)
state=$root/state
trap 'rm -rf "$root"' EXIT
mkdir -p "$state" "$root/bin"
ln -s "$SHELL_PATH/shell/Commons" "$root/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$root/Ui"
ln -s "$REPO" "$root/face"
cp "$REPO/dev/qml-harness/people.qml" "$root/shell.qml"
cp "$REPO/dev/fixtures/three-people/people.json" "$state/people.json"

# The stand-in for polkit's dialog. `pkexec` is what the GUI puts in argv[0] for
# every admin verb, and argv[0] is what decides how the stream is cancelled
# (common/Ask.qml: a prompting process is cancelled by closing its stdin, never
# by a signal). This one holds the exec for as long as a person takes to type a
# password, then becomes the helper -- so stdin, stdout and the exit code belong
# to the session, exactly as pkexec's own exec does.
cat >"$root/bin/pkexec" <<'STANDIN'
#!/bin/bash
# A stand-in for pkexec: the delay is the dialog, and `exec` is the handover.
sleep "${OMARCHY_FACE_DEV_PKEXEC_DELAY:-0}"
exec "$@"
STANDIN
chmod +x "$root/bin/pkexec"

run_case() { # run_case <case> [env…]
  local name=$1
  shift
  env FACE_HARNESS_CASE="$name" FACE_HARNESS_PLUGIN="$REPO" \
    OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_STATE="$state" \
    PATH="$root/bin:$PATH" "$@" \
    timeout 90 quickshell -p "$root" -n 2>&1 |
    sed -n 's/^.*HARNESS \([a-zA-Z]*\) \(.*\)$/\1=\2/p'
}

field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }

echo "G3/G4 — People, Person and the recording session, offscreen"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO${RESET}"

echo
echo "${DIM}== GATE: names derive as the plan says (common/names.js)${RESET}"
out=$(run_case names)
[[ -n $out ]] || { echo "  ${RED}FAIL${RESET}  the harness printed nothing (QML did not load)"; exit 1; }
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "\"Åse\" → ase" "ase" "$(field ase "$out")"
check "\"2 Kids\" → p-2-kids" "p-2-kids" "$(field twoKids "$out")"
check "a second \"Anna\" → anna-2" "anna-2" "$(field annaAgain "$out")"
check "…and a third → anna-3" "anna-3" "$(field annaThird "$out")"
check "\"Bjørn\" folds rather than losing the ø" "bjorn" "$(field bjorn "$out")"
check "\"Straße\" → strasse" "strasse" "$(field strasse "$out")"
check "\"José\" → jose" "jose" "$(field jose "$out")"
check "a long label is cut at 24" "a-very-long-name-indeed" "$(field long "$out")"
check "…and a collision keeps the suffix inside 24" "a-very-long-name-indee-2" "$(field longCollision "$out")"
check "a label with no letters at all still makes a name" "person" "$(field symbols "$out")"
check "punctuation and spaces collapse" "anna-marie" "$(field trailing "$out")"
check "people.json's own records count as taken names" "anna-2" "$(field fromRecords "$out")"
check "a plain label passes labelRule" "true" "$(field labelOkPlain "$out")"
check "a label with a line break does not" "false" "$(field labelOkNewline "$out")"
check "an empty label does not" "false" "$(field labelOkEmpty "$out")"
check "a 33-character label does not" "false" "$(field labelOkLong "$out")"

echo
echo "${DIM}== the People view${RESET}"
out=$(run_case people)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "three people" "3" "$(field people "$out")"
check "the footer counts the engine's sudo faces" "5" "$(field sudoFaces "$out")"
check "the engine's warning is carried verbatim" \
  "Sudo now matches against 5 faces. Every extra face is another chance that the wrong one is accepted." \
  "$(field warning "$out")"
check "the add form derives Åse live" "ase" "$(field derivedFromAse "$out")"
check "…and avoids the Anna already in the store" "anna-2" "$(field derivedFromAnna "$out")"
check "…and prefixes a label that starts with a digit" "p-2-kids" "$(field derivedFromDigits "$out")"
check "an empty label is not offered" "false" "$(field emptyLabelValid "$out")"
at_least "the view has a height" 1 "$(field height "$out")"

out=$(run_case people FACE_HARNESS_NO_ENGINE=1)
check "with no engine there is nothing to record into" "false" "$(field engineReady "$out")"

echo
echo "${DIM}== GATE: the owner has no Remove row${RESET}"
out=$(run_case person FACE_HARNESS_PERSON=graveklar)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the owner is found" "true" "$(field found "$out")"
check "…and known to be the owner" "true" "$(field owner "$out")"
check "…rendered as You" "You" "$(field shown "$out")"
check "…with the possessive to match" "Your" "$(field possessive "$out")"
check "…and NO Remove row" "false" "$(field removeVisible "$out")"

out=$(run_case person FACE_HARNESS_PERSON=anna)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "somebody else does have one" "true" "$(field removeVisible "$out")"
check "…named by their label" "Anna's" "$(field possessive "$out")"
check "…with three appearances, which is the most" "true" "$(field full "$out")"
check "…Sudo on" "true" "$(field sudoOn "$out")"
check "…Lock on, even though the feature is off" "true" "$(field lockOn "$out")"
check "…and the feature reported as off" "false" "$(field lockCaption "$out")"

out=$(run_case person FACE_HARNESS_PERSON=nobody)
check "a person who is not in the store renders a reason" "false" "$(field found "$out")"

echo
echo "${DIM}== GATE: a slow dialog still yields a full 3-2-1 after ready${RESET}"
before_log=$state/session.log
rm -f "$before_log"
out=$(run_case record-slow OMARCHY_FACE_DEV_PKEXEC=1 OMARCHY_FACE_DEV_PKEXEC_DELAY=10)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
at_least "authorisation took ten seconds" 10000 "$(field readyDelayMs "$out")"
check "the countdown ran 3 · 2 · 1" "3,2,1" "$(field countdownValues "$out")"
between "…for its full length, measured FROM ready" 2200 3200 "$(field countdownMs "$out")"
check "one capture was taken" "1" "$(field captures "$out")"
check "…and Done saved it" "true" "$(field saved "$out")"
check "the session ended by saying done, not by being killed" "done captures=1" \
  "$(grep -E '^(done|discarded|killed)' "$before_log" | head -1)"

echo
echo "${DIM}== GATE: Esc before a capture writes nothing${RESET}"
rm -f "$state/session.log"
people_before=$(sha256sum "$state/people.json" | cut -d' ' -f1)
people_mtime_before=$(stat -c '%y' "$state/people.json")
out=$(run_case record-esc OMARCHY_FACE_DEV_PKEXEC=1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "nothing was captured" "0" "$(field captures "$out")"
check "…so nothing was saved" "false" "$(field saved "$out")"
check "the session ended discarded, by stdin closing" "discarded" \
  "$(grep -E '^(done|discarded|killed)' "$state/session.log" | head -1)"
check "people.json is byte-identical" "$people_before" "$(sha256sum "$state/people.json" | cut -d' ' -f1)"
check "…and was not even touched" "$people_mtime_before" "$(stat -c '%y' "$state/people.json")"

echo
echo "${DIM}== GATE: a session destroyed with its card cannot be orphaned${RESET}"
rm -f "$state/session.log"
out=$(run_case record-orphan OMARCHY_FACE_DEV_PKEXEC=1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the session object is gone" "true" "$(field sessionGone "$out")"
check "…and it closed its stdin on the way out, rather than leaving root reading" \
  "discarded" "$(grep -E '^(done|discarded|killed)' "$state/session.log" | head -1)"

echo
echo "${DIM}== the card and the service compile${RESET}"
out=$(run_case card)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the recording card is built (never shown here)" "true" "$(field cardCreated "$out")"
check "…in its framing phase" "framing" "$(field cardPhase "$out")"
check "…knowing who it is recording" "Anna" "$(field cardWho "$out")"
check "the Face service loads beside it" "true" "$(field serviceCreated "$out")"

echo
echo "${DIM}== a session that cannot start says why${RESET}"
out=$(run_case record-slow OMARCHY_FACE_DEV_PKEXEC=1 OMARCHY_FACE_DEV_SESSION_ERROR=exists)
check "a session-fatal error comes back as copy, not a code" \
  "Somebody is already called that." "$(field message "$out")"
check "…and nothing was captured" "0" "$(field captures "$out")"

echo
if ((failures == 0)); then
  echo "${GREEN}$checks checks, all passed${RESET}"
else
  echo "${RED}$checks checks, $failures failed${RESET}"
fi
exit $((failures > 0))
