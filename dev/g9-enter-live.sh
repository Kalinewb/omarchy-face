#!/bin/bash

# The one thing about Enter that no offscreen suite can show: that a PHYSICAL
# key press fires a runtime Hyprland binding and puts its event on the socket.
#
#   ./dev/g9-enter-live.sh
#
# dev/g6-lock-offscreen.sh raises the event itself, and virtual keyboards
# (wtype) do not trigger Hyprland bindings at all, so this needs a person. It
# registers the same binding the lock wrapper registers -- Return and KP_Enter,
# non-consuming, raising an event -- under a name no wrapper listens for, waits
# for one Enter, and removes it. Nothing is locked. The key still reaches
# whatever window has focus, which is the non-consuming half of the proof, so
# press it somewhere harmless: this terminal is fine.
#
# What it still cannot show is the `locked` half: that the binding fires while a
# session lock holds the keyboard. That is the live lock test in dev/README.md.

set -uo pipefail

command -v hyprctl >/dev/null || { echo "g9: no hyprctl" >&2; exit 1; }
command -v socat >/dev/null || { echo "g9: needs socat" >&2; exit 1; }
[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || { echo "g9: not inside Hyprland" >&2; exit 1; }

EVENT=omarchy-face-enter-g9-$$
SOCKET=$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock
TABLE=_G.omarchy_face_g9_$$

cleanup() {
  hyprctl eval "if $TABLE then for _, b in ipairs($TABLE) do pcall(function() b:unbind() end) end end $TABLE = nil" >/dev/null
}
trap cleanup EXIT

hyprctl eval "local t = {} for _, key in ipairs({\"Return\", \"KP_Enter\"}) do table.insert(t, hl.bind(key, hl.dsp.event(\"$EVENT\"), { locked = true, non_consuming = true })) end $TABLE = t" >/dev/null ||
  { echo "g9: Hyprland refused the binding" >&2; exit 1; }

echo "Press Enter now (within 20 seconds)…"
if timeout 20 socat -u "UNIX-CONNECT:$SOCKET" - 2>/dev/null | grep -a -m1 -q "^custom>>$EVENT\$"; then
  echo "pass  a physical Enter raised the event, and the key still reached this terminal"
  exit 0
fi
echo "FAIL  no event within 20 s: Enter on the lock screen will not start a face check"
exit 1
