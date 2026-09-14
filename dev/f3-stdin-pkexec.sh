#!/bin/bash

# Does a session survive pkexec? (plan-merged.md §1 row 19, §4 phase 4's
# "stdin-through-pkexec test first".)
#
#   ./dev/f3-stdin-pkexec.sh            the stand-in: no password, no root
#   ./dev/f3-stdin-pkexec.sh --real     the real pkexec — YOU have to type the
#                                       password into the dialog it raises
#
# `enroll-session` is the only verb in the contract that is a conversation
# rather than a call: a long-lived root process, fed JSON command lines on stdin
# and answering with event lines on stdout, for as long as somebody is recording
# faces. Everything phase 4 builds rests on pkexec handing its own standard
# streams to the program it execs and not buffering, closing or reordering them.
#
# So this measures the channel with the engine taken out (dev/bin/stdin-echo):
#
#   * `ready` arrives only after the dialog is answered, and arrives at once;
#   * a command line written afterwards reaches the child, and its answer comes
#     back before the next one is sent -- so neither direction is block-buffered
#     into silence;
#   * closing stdin ends the process with exit 0, which is the only cancel a
#     root session has (§2 rule 7).
#
# The default run proves those three things through a stand-in `pkexec` that
# sleeps for ten seconds and then execs, which is what pkexec does around its
# dialog. It cannot prove pkexec ITSELF behaves that way -- only --real can, and
# only with the owner at the keyboard, because Face's action is `auth_self` and
# polkit has no way to be answered by a script. Run it once per machine; the
# answer is a property of pkexec, not of this plugin.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MODE=${1:-}

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

between() { # between <description> <low> <high> <actual>
  checks=$((checks + 1))
  if [[ ${4:-} =~ ^-?[0-9]+$ ]] && (( $4 >= $2 && $4 <= $3 )); then
    echo "  ${GREEN}pass${RESET}  $1 ${DIM}($4 ms)${RESET}"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected $2-$3 ms, got '${4:-}')${RESET}"
    failures=$((failures + 1))
  fi
}

note() { echo "  ${YELLOW}note${RESET}  $*"; }

lab=$(mktemp -d /tmp/omarchy-face-f3-pkexec.XXXXXX)
trap 'rm -rf "$lab"' EXIT

# The stand-in: a delay, then exec. Same shape as pkexec's own handover.
cat >"$lab/pkexec" <<'STANDIN'
#!/bin/bash
sleep "${OMARCHY_FACE_DEV_PKEXEC_DELAY:-10}"
exec "$@"
STANDIN
chmod +x "$lab/pkexec"

# One session, scripted: wait for ready, send two commands with a pause between
# them, then close stdin.
cat >"$lab/script" <<'SCRIPT'
await ready 90
send {"cmd":"create","label":"Anna"}
await echo 10
sleep 0.4
send {"cmd":"capture","appearance":"No glasses"}
await echo 10
eof
SCRIPT

echo "Does a session survive pkexec? (plan-merged.md §1 row 19)"

if [[ $MODE == --real ]]; then
  echo "${DIM}the real pkexec — answer the dialog it raises${RESET}"
  launcher=(pkexec "$REPO/dev/bin/stdin-echo")
else
  echo "${DIM}stand-in pkexec: a ten-second dialog, then exec${RESET}"
  launcher=("$lab/pkexec" "$REPO/dev/bin/stdin-echo")
fi

out=$(PATH="$lab:$PATH" python3 "$REPO/dev/enroll-client.py" "$lab/script" -- "${launcher[@]}" 2>&1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"

events=$(sed -n 's/^EV //p' <<<"$out")
first=$(head -1 <<<"$events")
exit_line=$(sed -n 's/^EXIT //p' <<<"$out" | head -1)

if [[ -z $first ]]; then
  if [[ $MODE == --real ]]; then
    note "nothing came back: the dialog was dismissed, or no polkit agent answered it"
    note "this is the one check that needs a person at the keyboard"
  fi
  echo "  ${RED}FAIL${RESET}  the session printed nothing"
  exit 1
fi

check "the first line is one JSON event, and it is ready" "ready" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["event"])' "$first")"
between "…and it arrives at once once the dialog is answered" 0 500 \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["at"])' "$first")"
uid=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("uid"))' "$first")
if [[ $MODE == --real ]]; then
  check "…from a process that really is root" "0" "$uid"
else
  # The stand-in execs as whoever ran it; only the real pkexec can answer this.
  note "the stand-in ran as uid $uid — only --real can say root"
fi

echoes=$(grep -c '"event":"echo"' <<<"$events")
check "both command lines crossed pkexec" "2" "$echoes"
check "…in order" "create capture" \
  "$(python3 -c '
import json, sys
print(" ".join(json.loads(line)["cmd"] for line in sys.stdin if "\"echo\"" in line))' <<<"$events")"

# The client only sends the second command after the first answer arrives, so
# two echoes at all means neither direction was block-buffered.
check "the answers came back live, not in one lump at exit" "true" \
  "$(python3 -c '
import json, sys
times = [json.loads(line)["at"] for line in sys.stdin if "\"echo\"" in line]
print(str(len(times) == 2 and times[1] - times[0] >= 300).lower())' <<<"$events")"

check "closing stdin ended the session" "discarded" \
  "$(python3 -c '
import json, sys
last = [json.loads(line) for line in sys.stdin][-1]
print(last["event"])' <<<"$events")"
check "…with exit 0" "0" "$exit_line"

if [[ $MODE != --real ]]; then
  echo
  note "this was the stand-in. The real one, once per machine:"
  note "  ./dev/f3-stdin-pkexec.sh --real"
fi

echo
if ((failures == 0)); then
  echo "${GREEN}$checks checks, all passed${RESET}"
else
  echo "${RED}$checks checks, $failures failed${RESET}"
fi
exit $((failures > 0))
