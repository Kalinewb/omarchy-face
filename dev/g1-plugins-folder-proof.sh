#!/bin/bash

# The phase-1 gate proof, as something that can be re-run (plan-merged.md §4).
#
# Two claims, opposite answers, and the whole design leans on both:
#
#   E13  ANY write under ~/.config/omarchy/plugins reloads every plugin bar
#        widget, so the Face popup is destroyed. Hence: no routine user action
#        writes that folder, and the three flows that do are each a flow's last
#        step, announced first (plan-gui.md §1).
#   E12  `omarchy plugin enable|disable` writes only shell.json, which is
#        OUTSIDE that folder, and the lock service is swapped live. Hence: the
#        lock-screen toggle can complete with the popup open (phase 7's gate).
#
# Phase 7 asserts the same property again for the real lock toggle, which is
# why this is a script and not something somebody once ran by hand.
#
# It creates and removes one throwaway plugin. It never writes the Face plugin
# folder, never touches another plugin, and leaves shell.json as it found it.
#
# Requires: the Face plugin installed and enabled, and a shell that answers.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

PLUGINS="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
THROWAWAY="zz.face-proof"
DIR="$PLUGINS/$THROWAWAY"
failures=0

face_state() { omarchy-shell graveklar.face state 2>/dev/null; }
field() { jq -r "$2" <<<"$1" 2>/dev/null; }
shell_pid() { pgrep -f 'quickshell -n -p' | head -n 1; }

pass() { echo "  ${GREEN}pass${RESET}  $1"; }
fail() { echo "  ${RED}FAIL${RESET}  $1"; ((failures++)); }
note() { echo "        ${DIM}$1${RESET}"; }

cleanup() {
  omarchy plugin disable "$THROWAWAY" >/dev/null 2>&1
  rm -rf "$DIR"
  sleep 2
  if grep -q "$THROWAWAY" "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json" 2>/dev/null; then
    echo "${YELLOW}note:${RESET} $THROWAWAY is still named in shell.json — remove it by hand" >&2
  fi
}
trap cleanup EXIT

# --- preconditions -------------------------------------------------------

command -v jq >/dev/null || { echo "g1-proof: jq is required" >&2; exit 1; }
omarchy-shell shell ping >/dev/null 2>&1 || { echo "g1-proof: the shell does not answer" >&2; exit 1; }
[[ -n "$(face_state)" ]] || {
  echo "g1-proof: graveklar.face does not answer IPC — install and enable it first" >&2
  exit 1
}

PID_BEFORE=$(shell_pid)
echo "G1 — plugins-folder proof (shell pid $PID_BEFORE)"

# --- a throwaway plugin, created BEFORE the popup is open ----------------

# Creating it is itself a plugins-folder write, so it happens while nothing is
# open and costs nothing. A `service` kind, not a bar widget: enabling a widget
# would edit the bar layout, and the point is to write shell.json and nothing
# else.
mkdir -p "$DIR"
cat > "$DIR/manifest.json" <<EOF
{
  "schemaVersion": 1,
  "id": "$THROWAWAY",
  "name": "Face proof",
  "version": "1.0.0",
  "author": "graveklar",
  "description": "Disposable plugin used to prove what does and does not reload the shell's bar widgets.",
  "kinds": ["service"],
  "entryPoints": {"service": "Service.qml"}
}
EOF
cat > "$DIR/Service.qml" <<'EOF'
import QtQuick
Item { Component.onCompleted: console.log("zz.face-proof loaded") }
EOF

omarchy plugin validate "$DIR" >/dev/null || { echo "g1-proof: the throwaway plugin does not validate" >&2; exit 1; }
sleep 3
omarchy-shell shell rescanPlugins >/dev/null 2>&1
sleep 2

# --- 1. the popup opens, on a view that is not the root one --------------

# Not the root view, deliberately: a reload rebuilds the panel from scratch, so
# the view stack resetting to ["setup"] is how a DESTROYED popup is told apart
# from one merely closed (an outside click closes it with the stack intact).
omarchy-shell graveklar.face open people "" >/dev/null 2>&1
sleep 1
STATE=$(face_state)
if [[ $(field "$STATE" .open) == true && $(field "$STATE" .view) == people ]]; then
  pass "the popup opens and holds a view stack"
  note "$STATE"
else
  fail "the popup did not open on the people view"
  note "$STATE"
  exit 1
fi
[[ $(field "$STATE" .rows) -gt 0 ]] \
  && pass "it is rendering $(field "$STATE" .rows) rows from the engine" \
  || note "no rows: no engine and no stub bin — the reload halves below still hold"

# --- 2. enable/disable a plugin: shell.json only, popup survives ---------

T0=$(date '+%Y-%m-%d %H:%M:%S')
omarchy plugin enable "$THROWAWAY" >/dev/null 2>&1
sleep 2
AFTER_ENABLE=$(face_state)
omarchy plugin disable "$THROWAWAY" >/dev/null 2>&1
sleep 2
AFTER_DISABLE=$(face_state)

RELOADS=$(journalctl --user -t omarchy-shell --since "$T0" --no-pager 2>/dev/null |
          grep -c "Local plugin changed")

if [[ $(field "$AFTER_ENABLE" .open) == true && $(field "$AFTER_ENABLE" .view) == people \
   && $(field "$AFTER_DISABLE" .open) == true && $(field "$AFTER_DISABLE" .view) == people ]]; then
  pass "enable and disable leave the popup open, view stack intact (E12)"
else
  fail "enable/disable closed the popup"
  note "after enable:  $AFTER_ENABLE"
  note "after disable: $AFTER_DISABLE"
fi

(( RELOADS == 0 )) \
  && pass "no plugin reload was triggered by either (shell.json is outside the folder)" \
  || fail "$RELOADS plugin reload(s) during enable/disable — something wrote the plugins folder"

# --- 3. a write inside the plugins folder: popup goes --------------------

T1=$(date '+%Y-%m-%d %H:%M:%S')
touch "$DIR/marker"
sleep 3
AFTER_TOUCH=$(face_state)
RELOADED=$(journalctl --user -t omarchy-shell --since "$T1" --no-pager 2>/dev/null |
           grep -c "Local plugin changed")
CLOSED=$(journalctl --user -t omarchy-shell --since "$T1" --no-pager 2>/dev/null |
         grep -c "graveklar.face popup closed")

if [[ $(field "$AFTER_TOUCH" .open) == false && $(field "$AFTER_TOUCH" .view) == setup && $RELOADED -gt 0 ]]; then
  pass "a touch inside the folder reloaded the plugins and took the popup with it (E13)"
  note "the panel came back as a fresh instance: stack reset to [\"setup\"], no \"popup closed\" line"
elif (( CLOSED > 0 && RELOADED == 0 )); then
  fail "INCONCLUSIVE: the popup was closed by a click, not by a reload — rerun without touching the machine"
else
  fail "the popup survived a plugins-folder write, or closed for another reason"
  note "after touch: $AFTER_TOUCH  (reload lines: $RELOADED, close lines: $CLOSED)"
fi

# --- the shell must be the one we started with ---------------------------

PID_AFTER=$(shell_pid)
[[ $PID_BEFORE == "$PID_AFTER" ]] \
  && pass "one shell process throughout (pid $PID_AFTER) — no restart confused the result" \
  || fail "the shell restarted during the proof (pid $PID_BEFORE -> $PID_AFTER); rerun"

echo
if (( failures == 0 )); then
  echo "${GREEN}G1 plugins-folder proof passes.${RESET}"
else
  echo "${RED}$failures check(s) failed.${RESET}"
fi
exit $(( failures > 0 ))
