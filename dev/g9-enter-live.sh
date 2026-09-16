#!/bin/bash

# The one thing about Enter that no offscreen suite can show: that a key press
# on a real keyboard fires a runtime Hyprland binding and puts its event on the
# socket.
#
#   ./dev/g9-enter-live.sh              automatic, through /dev/uinput
#   ./dev/g9-enter-live.sh --by-hand    you press Enter (run it in a terminal)
#
# dev/g6-lock-offscreen.sh raises the event itself, and `wtype` cannot stand in
# for a key: Hyprland does not run bindings for the Wayland virtual-keyboard
# protocol. A uinput device is a kernel keyboard, which it does.
#
# Automatic mode proves the two halves separately, because pressing a
# pass-through Enter would send it into whatever window has focus:
#
#   1  the key names   Return and KP_Enter, bound CONSUMING (so the synthetic
#                      presses go nowhere), each raise the event
#   2  pass-through    the exact binding the wrapper makes -- runtime Lua,
#                      locked, non_consuming, hl.dsp.event -- on F24, which
#                      nothing uses, raises the event
#
# Nothing is locked. What neither mode shows is the `locked` half: that the
# binding fires while a session lock holds the keyboard. That is the live lock
# test in dev/README.md.

set -uo pipefail

command -v hyprctl >/dev/null || { echo "g9: no hyprctl" >&2; exit 1; }
command -v socat >/dev/null || { echo "g9: needs socat" >&2; exit 1; }
[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || { echo "g9: not inside Hyprland" >&2; exit 1; }

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOCKET=$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock
TABLE=_G.omarchy_face_g9_$$
EVENT=omarchy-face-enter-g9-$$
LOG=$(mktemp /tmp/omarchy-face-g9.XXXXXX)

cleanup() {
  hyprctl eval "if $TABLE then for _, b in ipairs($TABLE) do pcall(function() b:unbind() end) end end $TABLE = nil" >/dev/null
  rm -f "$LOG"
}
trap cleanup EXIT

failures=0
pass() { echo "pass  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }

bind() { # bind <lua options> <key>... -- every key raises "$EVENT-<key>"
  local options=$1 lua="local t = {} " key
  shift
  for key in "$@"; do
    lua+="table.insert(t, hl.bind(\"$key\", hl.dsp.event(\"$EVENT-$key\"), $options)) "
  done
  hyprctl eval "if $TABLE then for _, b in ipairs($TABLE) do pcall(function() b:unbind() end) end end $lua $TABLE = t" >/dev/null ||
    { echo "g9: Hyprland refused the binding" >&2; exit 1; }
}

listen() { # listen <seconds> -- in the background, into $LOG
  : >"$LOG"
  timeout "$1" socat -u "UNIX-CONNECT:$SOCKET" - >"$LOG" 2>/dev/null &
  sleep 0.3
}

heard() { grep -a -q "^custom>>$EVENT-$1\$" "$LOG"; }

if [[ ${1:-} == --by-hand ]]; then
  [[ -t 0 ]] || { echo "g9: --by-hand needs a terminal to see the prompt in time" >&2; exit 2; }
  bind "{ locked = true, non_consuming = true }" Return KP_Enter
  listen 20
  echo "Press Enter now (within 20 seconds)…"
  for _ in $(seq 200); do
    { heard Return || heard KP_Enter; } && break
    sleep 0.1
  done
  if heard Return || heard KP_Enter; then
    pass "a physical Enter raised the event, and the key still reached this terminal"
  else
    fail "no event within 20 s"
  fi
  exit $((failures > 0))
fi

[[ -w /dev/uinput ]] || { echo "g9: /dev/uinput is not writable here; use --by-hand" >&2; exit 2; }

# Linux key codes: KEY_ENTER 28, KEY_KPENTER 96, KEY_F24 194.
bind "{ locked = true }" Return KP_Enter
listen 6
"$REPO/dev/uinput-key.py" 28 96 || { echo "g9: could not create a uinput keyboard" >&2; exit 1; }
wait
heard Return && pass "a kernel Enter key matches the name Return" ||
  fail "Enter (KEY_ENTER) did not match a binding on Return"
heard KP_Enter && pass "the keypad Enter matches the name KP_Enter" ||
  fail "keypad Enter (KEY_KPENTER) did not match a binding on KP_Enter"

bind "{ locked = true, non_consuming = true }" F24
listen 6
"$REPO/dev/uinput-key.py" 194 || { echo "g9: could not create a uinput keyboard" >&2; exit 1; }
wait
heard F24 && pass "a locked, non-consuming runtime Lua binding raises its event from a real key" ||
  fail "the wrapper's kind of binding raised nothing from a real key"

echo
((failures == 0)) && echo "G9 passes." || echo "$failures failed: Enter on the lock screen will not start a face check."
exit $((failures > 0))
