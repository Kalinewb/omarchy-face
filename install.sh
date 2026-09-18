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

# Stale pins would make every install of the system half refuse for everyone on
# this commit, so they are caught before anything is synced.
"$SRC/dev/check-pins.sh" || exit 1

# A QML error in a third-party plugin reaches no journal: the plugin just fails
# to appear in the bar. Catch it here rather than from a user's screenshot.
"$SRC/dev/lint.sh" || exit 1

# Validate a staging copy BEFORE anything lands in the watched folder. Validating
# $DEST afterwards is validating the damage: by then the broken plugin is
# installed and the reload has already run, and the exit code only tells you so.
# The staging directory is a dot name, which the plugin watcher ignores
# (PluginRegistry.qml:735), so building it costs no reload either.
STAGE=$(mktemp -d "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/.graveklar.face.stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

# dev/ stays out of the installed copy: the stubs are run from the repo through
# $OMARCHY_FACE_DEV_BIN, and a plugin folder should not ship a second set of
# helpers that answer differently from the real ones. The excludes are
# --exclude with --delete-excluded, not bare --exclude: bare excludes also
# protect a file of that name AT THE DESTINATION from --delete, so a dev/ left
# by an older revision would sit in the installed plugin for ever, unreachable
# by any later install.
RSYNC_EXCLUDES=(--exclude '.git' --exclude 'install.sh' --exclude 'dev'
                --exclude '*.bak' --exclude '*.bak.*')

rsync -a "${RSYNC_EXCLUDES[@]}" "$SRC/" "$STAGE/"

if command -v omarchy >/dev/null; then
  omarchy plugin validate "$STAGE" || { echo "install.sh: plugin failed validation" >&2; exit 1; }
fi

mkdir -p "$DEST"
# One rsync from the validated staging copy, --delete-excluded so a stale dev/
# or install.sh at the destination goes too.
rsync -a --delete --delete-excluded "${RSYNC_EXCLUDES[@]}" "$STAGE/" "$DEST/"
rm -rf "$STAGE"
trap - EXIT
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

  # The session's value first, this process's OMARCHY_PATH only as a fallback --
  # upstream's precedence (omarchy-restart-shell:8-9). A terminal opened after a
  # dev link/unlink disagrees with the desktop that is actually running, and
  # killing "the shell at $OMARCHY_PATH" then kills nothing while the launcher
  # starts a second one.
  SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
  : "${SHELL_PATH:=${OMARCHY_PATH:-}}"
  [[ -f $SHELL_PATH/shell/shell.qml ]] || {
    echo "install.sh: Omarchy shell config not found: ${SHELL_PATH:-<unset>}/shell" >&2
    exit 1
  }

  # Never restart a shell that is holding a lock screen: killing a live locker
  # strands the session behind Hyprland's failsafe, which outlives its client.
  # `omarchy restart shell` refuses for this reason (omarchy-restart-shell:28-37)
  # and a development convenience has no business being the one path that does
  # not. The compositor flag alone is enough here: unlike the recovery in
  # plan-engine.md §9.3a, this is not trying to rescue a stranded lock -- it is
  # declining to make one.
  if command -v omarchy-hyprland-session-locked >/dev/null && omarchy-hyprland-session-locked; then
    echo "install.sh: refusing while the session is locked" >&2
    exit 1
  fi

  echo "restarting the shell with OMARCHY_FACE_DEV_BIN=$SRC/dev/bin (fixture: $FIXTURE)"
  while timeout 5 quickshell kill -p "$SHELL_PATH/shell" --any-display >/dev/null 2>&1; do :; done
  hyprctl dispatch "hl.dsp.exec_cmd(\"env OMARCHY_FACE_DEV_BIN=$SRC/dev/bin OMARCHY_FACE_DEV_FIXTURE=$FIXTURE OMARCHY_FACE_DEV_STATE=$SRC/dev/fixtures/$FIXTURE omarchy-launch-shell\")" >/dev/null

  # Only claim the restart worked when the new shell actually answers. Printing
  # success unconditionally is worse than printing nothing: the one case that
  # matters is the shell that never came back.
  for _ in $(seq 1 40); do
    if omarchy-shell shell ping >/dev/null 2>&1; then
      echo "shell restarted in development mode"
      exit 0
    fi
    sleep 0.25
  done
  echo "install.sh: the shell did not answer within 10 s of the restart" >&2
  exit 1
fi

# A reload re-instantiates the entry point but does not recompile the other QML
# types in the folder, and a keepLoaded service keeps the code it started with.
# Both look exactly like "my change did nothing", so a restart is the honest
# default.
omarchy restart shell >/dev/null 2>&1 && echo "restarted the shell"
