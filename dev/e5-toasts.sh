#!/bin/bash

# E5: bin/omarchy-face-toasts, the helper that holds the notch's notification toasts back
# while the scan island is up (Service.qml). Headless and sandboxed: a stub `omarchy-shell`
# earlier in PATH plays the shell's notifications do-not-disturb (isDnd / setDnd), nothing
# talks to the real shell, and XDG_RUNTIME_DIR is a scratch directory.
#
#   ./dev/e5-toasts.sh
#
# What it proves: a hold and its release; a hold never runs after a later release (any
# order, and under load); a release the shell did not honour keeps the marker and the
# next start retries it; a do-not-disturb that was already on, or cannot be read, is
# never touched; no runtime directory of the user's own means nothing is done.
# What it cannot: the shell's real persistence of the setting, or Service.qml (a window).

set -uo pipefail

GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; RESET=$'\e[0m'
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TOASTS=$REPO/bin/omarchy-face-toasts
failures=0; checks=0
check() { # check <description> <expected> <actual>
  checks=$((checks + 1))
  if [[ $2 == "$3" ]]; then echo "  ${GREEN}pass${RESET}  $1"
  else echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected '$2', got '$3')${RESET}"; failures=$((failures + 1)); fi
}
step() { echo; echo "${DIM}== $*${RESET}"; }

root=$(mktemp -d /tmp/omarchy-face-e5.XXXXXX)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/run"
chmod 700 "$root/run"

# The shell's notifications service: `dnd` holds on|off. STUB_FAIL_SET=1 makes setDnd do
# nothing (a shell that is gone: `omarchy-shell` exits 0 and prints nothing), STUB_BLIND=1
# makes isDnd print nothing, STUB_BLIND_AFTER_SET=1 makes isDnd blind once setDnd has run.
cat >"$root/bin/omarchy-shell" <<'STUB'
#!/bin/bash
echo "$*" >>"$STUB_DIR/calls"
args=("$@"); [[ ${args[0]} == -q ]] && args=("${args[@]:1}")
case "${args[0]} ${args[1]}" in
  "notifications isDnd")
    [[ -e $STUB_DIR/blind || -e $STUB_DIR/blind-now ]] && exit 0
    cat "$STUB_DIR/dnd" ;;
  "notifications setDnd")
    touch "$STUB_DIR/set-ran"
    [[ -n ${STUB_FAIL_SET:-} ]] && exit 0
    [[ ${args[2]} == on ]] && echo on >"$STUB_DIR/dnd" || echo off >"$STUB_DIR/dnd"
    [[ -n ${STUB_BLIND_AFTER_SET:-} ]] && touch "$STUB_DIR/blind-now"
    cat "$STUB_DIR/dnd" ;;
  "omarchy.indicators refresh") echo refreshed >>"$STUB_DIR/refresh" ;;
esac
exit 0
STUB
chmod +x "$root/bin/omarchy-shell"
export STUB_DIR=$root/stub XDG_RUNTIME_DIR=$root/run PATH="$root/bin:$PATH"

reset() { rm -rf "$STUB_DIR" "$root/run/kalinewb.face"; mkdir -p "$STUB_DIR"; echo "${1:-off}" >"$STUB_DIR/dnd"; unset STUB_FAIL_SET STUB_BLIND_AFTER_SET; }
dnd() { cat "$STUB_DIR/dnd"; }
held() { [[ -e $root/run/kalinewb.face/dnd-held ]] && echo yes || echo no; }
calls() { local n; n=$(grep -c "^notifications setDnd" "$STUB_DIR/calls" 2>/dev/null); echo "${n:-0}"; }

step "a hold and its release"
reset off
"$TOASTS" hold 100
check "hold turns do-not-disturb on and leaves the marker" "on yes" "$(dnd) $(held)"
check "...and asks the shell to refresh its indicators" "refreshed" "$(cat "$STUB_DIR/refresh" 2>/dev/null | head -1)"
"$TOASTS" hold 101
check "a second hold while held does nothing more" "1" "$(calls)"
"$TOASTS" release 102
check "release turns it off and removes the marker only after the shell says off" "off no" "$(dnd) $(held)"

step "a do-not-disturb that was already on is never touched"
reset on
"$TOASTS" hold 100; "$TOASTS" release 101
check "hold and release leave it on, make no marker and call setDnd never" "on no 0" "$(dnd) $(held) $(calls)"
reset off
touch "$STUB_DIR/blind"
"$TOASTS" hold 100
check "a state that cannot be read is not touched either" "off no 0" "$(dnd) $(held) $(calls)"

step "a release the shell did not honour keeps the marker (the shell fails silently)"
reset off
"$TOASTS" hold 100
STUB_FAIL_SET=1 "$TOASTS" release 101
check "setDnd off that did not take: do-not-disturb is still on and the marker is KEPT" "on yes" "$(dnd) $(held)"
"$TOASTS" release 102                                  # the next start of the service
check "restart recovery: the next release turns it off and removes the marker" "off no" "$(dnd) $(held)"
reset off
"$TOASTS" hold 100
STUB_BLIND_AFTER_SET=1 "$TOASTS" release 101
check "a release whose answer cannot be read keeps the marker too" "yes" "$(held)"
rm -f "$STUB_DIR/blind-now"
"$TOASTS" release 102
check "...and retries to a clean state" "off no" "$(dnd) $(held)"
reset off
STUB_FAIL_SET=1 "$TOASTS" hold 100
check "a hold that did not take (still off) leaves no marker" "off no" "$(dnd) $(held)"
reset off
STUB_BLIND_AFTER_SET=1 "$TOASTS" hold 100
check "a hold whose answer cannot be read keeps the marker, so a release will try" "on yes" "$(dnd) $(held)"

step "ordering: a hold never runs after a later release"
reset off
"$TOASTS" release 200; "$TOASTS" hold 199
check "a late hold (older generation) after a release is ignored" "off no 0" "$(dnd) $(held) $(calls)"
"$TOASTS" hold 200
check "...and so is a repeat of the same generation" "off no 0" "$(dnd) $(held) $(calls)"
reset off
"$TOASTS" hold 300; "$TOASTS" release 301; "$TOASTS" hold 300
check "hold, release, then the first hold again (a stale duplicate): still released" "off no" "$(dnd) $(held)"
reset off
for round in 1 2 3 4 5 6; do
  base=$((round * 1000))
  if (( round % 2 )); then
    "$TOASTS" release $((base + 2)) & "$TOASTS" hold $((base + 1)) & wait
  else
    "$TOASTS" hold $((base + 1)) & "$TOASTS" release $((base + 2)) & wait
  fi
done
check "six fast open/close pairs run in either order: always ends released, with no marker" "off no" "$(dnd) $(held)"
reset off
for g in $(seq 1 30); do
  if (( g % 2 )); then "$TOASTS" hold $((5000 + g)) & else "$TOASTS" release $((5000 + g)) & fi
done; wait
check "30 racing calls (generation 5030, a release, is the newest): ends released" "off no" "$(dnd) $(held)"
reset off
for g in $(seq 1 29); do
  if (( g % 2 )); then "$TOASTS" hold $((6000 + g)) & else "$TOASTS" release $((6000 + g)) & fi
done; wait
check "29 racing calls (the newest, 6029, a hold): ends held, marker and do-not-disturb agree" "on yes" "$(dnd) $(held)"

step "no safe place for the marker: nothing is done"
reset off
env -u XDG_RUNTIME_DIR "$TOASTS" hold 100
check "no XDG_RUNTIME_DIR: no hold, no shell call, no /tmp fallback" "off 0 no" "$(dnd) $(calls) $([[ -e /tmp/kalinewb.face ]] && echo yes || echo no)"
XDG_RUNTIME_DIR=/proc/1 "$TOASTS" hold 100
check "a runtime directory that is not the user's: nothing" "off 0" "$(dnd) $(calls)"
XDG_RUNTIME_DIR=$root/missing "$TOASTS" hold 100
check "one that does not exist: nothing" "off 0" "$(dnd) $(calls)"

step "arguments"
reset off
"$TOASTS" frob 1; a=$?; "$TOASTS" hold; b=$?; "$TOASTS" hold abc; c=$?; "$TOASTS" hold -5; d=$?; "$TOASTS" hold 1234567890123456789012; e=$?
check "an unknown verb, a missing, non-numeric, negative or oversized generation: exit 2, nothing done" "2 2 2 2 2 off 0" "$a $b $c $d $e $(dnd) $(calls)"
check "the helper carries the version header the pins check reads" "$(sed -n 's/^# omarchy-face-version: //p' "$REPO/system/install.sh")" "$(head -40 "$TOASTS" | sed -n 's/^[^[:alnum:]]*omarchy-face-version:[[:space:]]*\([0-9A-Za-z.+-]*\).*/\1/p' | head -1)"

echo
if ((failures == 0)); then echo "${GREEN}$checks checks, all passed${RESET}"; else echo "${RED}$checks checks, $failures failed${RESET}"; fi
exit $((failures > 0))
