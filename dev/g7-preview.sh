#!/bin/bash

# preview.png: a real `grim` screenshot of the real People view, taken against
# this checkout (plan-gui.md §7.2 "Preview image", plan-merged.md §4 phase 8).
#
# It used to photograph Setup. Since the post-ship revision (plan-gui.md §4a)
# Setup on a healthy machine is one line saying so -- which is the point, and
# which makes it the wrong view to show somebody deciding whether they want this
# plugin. People is what the bar button opens on a working machine (`barTarget`,
# §3), and it is where the plugin has something to show: who is recorded, what
# each of them may do, and the count sudo matches against.
#
#   ./dev/g7-preview.sh            writes preview.png at the plugin root
#   ./dev/g7-preview.sh --keep     …and leaves the nested session up to look at
#
# Nothing here is drawn by hand, composited or edited. What runs is the Omarchy
# shell, the real bar, the real theme and THIS plugin's own QML, and `grim`
# photographs the result. Two things about it are synthetic, and both are named
# in the README of this directory and in the phase-8 report:
#
#   * the STATUS DOCUMENT is `dev/fixtures/configured/status.json`, served by the
#     dev stub the same way every offscreen suite is fed one. A row can only read
#     `ok` on a machine with howdy built, sudo wired, the lock screen enabled and
#     somebody enrolled, and a screenshot must not depend on the state of
#     whichever machine takes it. The fixture is a machine's answer, not a
#     mock-up of the view;
#   * the DISPLAY is a nested Hyprland with one headless output, so the shot can
#     be taken without touching the session this runs in -- which may be locked,
#     and whose plugin folder must not be written to (every write there reloads
#     every bar widget). The nested instance gets its own HOME, so it loads this
#     checkout and no other third-party plugin.
#
# The crop is measured, not guessed: the popup is photographed closed and open,
# and the bounding box of the pixels that changed IS the card.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
KEEP=0
[[ ${1:-} == --keep ]] && KEEP=1

for tool in Hyprland quickshell qs grim magick jq python3 rsync; do
  command -v "$tool" >/dev/null || { echo "g7-preview: $tool is not installed" >&2; exit 1; }
done
python3 -c 'import numpy' 2>/dev/null || { echo "g7-preview: python-numpy is not installed" >&2; exit 1; }

root=$(mktemp -d /tmp/omarchy-face-preview.XXXXXX)
HOME_DIR=$root/home
CONFIG=$HOME_DIR/.config/omarchy
hypr_pid=""
shell_pid=""

cleanup() {
  [[ -n $shell_pid ]] && kill "$shell_pid" 2>/dev/null
  sleep 0.5
  [[ -n $hypr_pid ]] && kill "$hypr_pid" 2>/dev/null
  rm -rf "$root"
}
if ((KEEP)); then
  trap 'echo "${DIM}left running: $root${RESET}"' EXIT
else
  trap cleanup EXIT
fi

mkdir -p "$HOME_DIR"/.cache "$HOME_DIR"/.local/state "$CONFIG/plugins"

# The real config, entry by entry, as symlinks -- the theme, the fonts and the
# bar's own settings are what make this a screenshot of THIS desktop rather than
# of a default one. `plugins` and `shell.json` are the two that are not copied:
# the first is the whole point (only this checkout is installed), and the second
# is pruned below.
for entry in "${XDG_CONFIG_HOME:-$HOME/.config}"/omarchy/*; do
  name=${entry##*/}
  [[ $name == plugins || $name == shell.json ]] && continue
  ln -s "$entry" "$CONFIG/$name"
done

# shell.json with every third-party plugin but this one taken out, and Omarchy's
# own background put back (the one that draws it here is third-party). Edited
# from the real document rather than rebuilt, because a shell.json without its
# `version` is a shell.json the shell ignores in favour of the defaults.
jq '
  def keep(id): (id | startswith("omarchy.")) or id == "graveklar.face";
  .plugins = [ (.plugins // [])[] | select(keep(.id // "")) ]
  | .bar.layout = (.bar.layout | with_entries(.value = [ .value[] | select(keep(.id // .)) ]))
  | .disabledPlugins = [ (.disabledPlugins // [])[] | select(. != "omarchy.background") ]
' "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json" >"$CONFIG/shell.json" || exit 1

XDG_CONFIG_HOME="$HOME_DIR/.config" "$REPO/install.sh" --no-restart >/dev/null || exit 1
echo "${DIM}this checkout installed at $CONFIG/plugins/graveklar.face${RESET}"

# --- the nested compositor ---------------------------------------------------

cat >"$root/hypr.conf" <<'CONF'
# One headless output, created below; the nested window is disabled so the shell
# draws exactly one bar.
monitor = HEADLESS-1, 2000x1800@60, 0x0, 2
misc {
  disable_hyprland_logo = true
  disable_splash_rendering = true
  force_default_wallpaper = 0
  vfr = false
}
animations { enabled = false }
decoration { blur { enabled = false } shadow { enabled = false } }
CONF

before=$(ls "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" 2>/dev/null)
setsid Hyprland -c "$root/hypr.conf" >"$root/hypr.log" 2>&1 &
hypr_pid=$!

signature=""
for _ in $(seq 1 40); do
  sleep 0.5
  for candidate in $(ls "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" 2>/dev/null); do
    grep -qxF "$candidate" <<<"$before" && continue
    signature=$candidate
  done
  [[ -n $signature ]] && break
done
[[ -n $signature ]] || { echo "${RED}the nested compositor did not start${RESET}"; exit 1; }
export HYPRLAND_INSTANCE_SIGNATURE=$signature
echo "${DIM}nested compositor: $signature${RESET}"

# A headless output renders on its own clock. The nested window does not: while
# the session this runs in is locked, its parent surface gets no frames, and a
# screencopy of it never completes.
hyprctl output create headless >/dev/null
sleep 1
hyprctl keyword monitor "WAYLAND-1,disable" >/dev/null
sleep 1
display=$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$UID}"/wayland-[0-9]* 2>/dev/null |
          grep -v '\.lock$' | head -n1)
export WAYLAND_DISPLAY=${display##*/}
hyprctl -j monitors | jq -c '.[] | {name, width, height, scale}' | sed "s/^/  ${DIM}/;s/\$/${RESET}/"

# --- the shell ---------------------------------------------------------------

env HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" OMARCHY_PATH=/usr/share/omarchy \
    OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_FIXTURE=configured \
    OMARCHY_FACE_DEV_STATE="$REPO/dev/fixtures/configured" \
    QS_DISABLE_FILE_WATCHER=1 QS_NO_RELOAD_POPUP=1 \
    setsid quickshell -n -p /usr/share/omarchy/shell >"$root/shell.log" 2>&1 &
shell_pid=$!

# Every row `ok` is the whole point of the picture, so it is waited for and then
# asserted rather than hoped for: `barState` is `on` only when nothing is broken,
# nothing needs doing and a face can actually approve sudo (FacePanel.qml). The
# first status read lands a moment after the plugin does.
state=""
bar_state=""
for _ in $(seq 1 60); do
  sleep 0.5
  state=$(timeout 5 qs ipc --pid "$shell_pid" call graveklar.face state 2>/dev/null)
  [[ $state == \{* ]] || continue
  bar_state=$(jq -r '.barState' <<<"$state")
  [[ $bar_state == on ]] && break
done
[[ $state == \{* ]] || { echo "${RED}the Face plugin never answered in the nested shell${RESET}"; tail -5 "$root/shell.log"; exit 1; }
[[ $bar_state == on ]] || { echo "${RED}the fixture is not a finished machine (barState=$bar_state)${RESET}"; exit 1; }

# --- the two shots, and the crop between them --------------------------------

qs ipc --pid "$shell_pid" call graveklar.face hide >/dev/null 2>&1

# Hyprland puts its own banner on screen when it is started outside
# `start-hyprland`, and a banner that fades between the two shots would be
# measured as part of the popup. Dismissed, and then the screen is required to
# hold still: two identical shots in a row before the popup is opened.
for _ in 1 2 3; do hyprctl dismissnotify >/dev/null 2>&1; sleep 1; done
settled=0
for _ in $(seq 1 30); do
  timeout 20 grim -o HEADLESS-1 "$root/closed.png" || exit 1
  sleep 1.5
  timeout 20 grim -o HEADLESS-1 "$root/closed-2.png" || exit 1
  if cmp -s "$root/closed.png" "$root/closed-2.png"; then settled=1; break; fi
  hyprctl dismissnotify >/dev/null 2>&1
done
((settled)) || { echo "${RED}the nested screen never held still${RESET}"; exit 1; }

qs ipc --pid "$shell_pid" call graveklar.face open people "" >/dev/null || exit 1
sleep 2
timeout 20 grim -o HEADLESS-1 "$root/open.png" || exit 1

crop=$(python3 - "$root/closed.png" "$root/open.png" <<'PY'
import subprocess, sys
import numpy as np

def load(path):
    raw = subprocess.run(["magick", path, "-depth", "8", "ppm:-"],
                         capture_output=True, check=True).stdout
    magic, size, depth, body = raw.split(b"\n", 3)
    width, height = map(int, size.split())
    return np.frombuffer(body, dtype=np.uint8).reshape(height, width, 3)

closed, opened = load(sys.argv[1]), load(sys.argv[2])
changed = np.abs(closed.astype(int) - opened.astype(int)).sum(axis=2) > 12

# The bar button changes too when the popup opens, and it is a few tens of
# pixels wide; the card is hundreds. Rows wide enough to be the card are the
# card, and the columns are measured inside them.
rows = changed.sum(axis=1)
wide = np.nonzero(rows > 100)[0]
if wide.size == 0:
    sys.exit("nothing opened")
top, bottom = int(wide.min()), int(wide.max())
cols = np.nonzero(changed[top:bottom + 1].sum(axis=0) > 0)[0]
left, right = int(cols.min()), int(cols.max())
print(f"{right - left + 1}x{bottom - top + 1}+{left}+{top}")
PY
) || { echo "${RED}could not measure the popup${RESET}"; exit 1; }

magick "$root/open.png" -crop "$crop" +repage -strip "$REPO/preview.png" || exit 1

echo
echo "${GREEN}preview.png${RESET}  $(identify -format '%wx%h, %B bytes' "$REPO/preview.png")  ${DIM}(crop $crop)${RESET}"
echo "${DIM}rows in the shot: $(jq -r '[.rows[] | select(.state == "ok") | .id] | join(", ")' \
      "$REPO/dev/fixtures/configured/status.json")${RESET}"
