#!/bin/bash

# Sync this working tree into the live plugin directory.
#
# Development cannot happen in ~/.config/omarchy/plugins: that tree is watched
# recursively, and every write there reloads every plugin bar widget in the
# shell (plan-engine.md E13). Editing in place makes the desktop flicker
# continuously, and running git there is worse. So the repo lives outside it and
# this pushes a copy in: one write burst, one reload, instead of one per
# keystroke.
#
#   ./install.sh              install and restart the shell
#   ./install.sh --no-restart install only (non-entry QML will render stale)
#   ./install.sh --dev        restart the shell with OMARCHY_FACE_DEV_BIN set,
#                             so the GUI talks to dev/bin instead of helpers
#                             that do not exist yet (plan-gui.md §8)
#
# It installs nothing outside the plugin folder. Face's helpers, units and
# polkit policy are installed by the GUI, under one owner prompt, and they are
# not part of this repo's phase 1.

set -euo pipefail

ID="graveklar.face"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID"
SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

MODE=${1:-}

mkdir -p "$DEST"

# dev/ stays out of the installed copy: the stubs are run from the repo through
# $OMARCHY_FACE_DEV_BIN, and a plugin folder should not ship a second set of
# helpers that answer differently from the real ones.
rsync -a --delete \
  --exclude '.git' --exclude 'install.sh' --exclude 'dev' \
  --exclude '*.bak' --exclude '*.bak.*' \
  "$SRC/" "$DEST/"

if command -v omarchy >/dev/null; then
  omarchy plugin validate "$DEST" || { echo "install.sh: plugin failed validation" >&2; exit 1; }
fi
echo "installed $ID -> $DEST"

if [[ $MODE == --no-restart ]]; then
  echo "(shell not restarted — edits to any .qml but the entry points will render stale)"
  exit 0
fi

command -v omarchy >/dev/null || exit 0

if [[ $MODE == --dev ]]; then
  # The shell is spawned by Hyprland, so it inherits Hyprland's environment and
  # not this terminal's (omarchy-restart-shell:68-70). To give the shell a
  # variable for one session, kill it the way the restart script does and ask
  # Hyprland to exec the launcher with the variable in front of it.
  FIXTURE=${OMARCHY_FACE_DEV_FIXTURE:-fresh}
  SHELL_PATH=${OMARCHY_PATH:-$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)}
  echo "restarting the shell with OMARCHY_FACE_DEV_BIN=$SRC/dev/bin (fixture: $FIXTURE)"
  while timeout 5 quickshell kill -p "$SHELL_PATH/shell" --any-display >/dev/null 2>&1; do :; done
  hyprctl dispatch "hl.dsp.exec_cmd(\"env OMARCHY_FACE_DEV_BIN=$SRC/dev/bin OMARCHY_FACE_DEV_FIXTURE=$FIXTURE OMARCHY_FACE_DEV_STATE=$SRC/dev/fixtures/$FIXTURE omarchy-launch-shell\")" >/dev/null
  for _ in $(seq 1 40); do
    omarchy-shell shell ping >/dev/null 2>&1 && break
    sleep 0.25
  done
  echo "shell restarted in development mode"
  exit 0
fi

# A reload re-instantiates the entry point but does not recompile the other QML
# types in the folder, and a keepLoaded service keeps the code it started with.
# Both look exactly like "my change did nothing", so a restart is the honest
# default.
omarchy restart shell >/dev/null 2>&1 && echo "restarted the shell"
