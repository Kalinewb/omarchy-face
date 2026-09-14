#!/bin/bash

# F0 — the old install is gone (plan-engine.md §2).
#
# Run it BEFORE installing the plugin: the last three checks are about the
# plugin folders themselves, and `./install.sh` makes two of them fail by doing
# exactly what it says on the tin.
#
# A checklist of checks whose success means clean. It reads and never removes:
# anything it reports is either removed by hand once, or by
# `omarchy-face-admin purge-legacy` when that verb exists (plan-engine.md §10.1,
# row `legacy`). Safe to run on any machine, at any time, without privilege.
#
# Left alone on purpose: ~/.cache/yay/{howdy,python-dlib} and the third-party
# lock-explorer plugin.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
DIM=$'\e[2m'
RESET=$'\e[0m'

PLUGINS="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
failures=0

check() { # check <description> <command…>
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ${GREEN}pass${RESET}  $description"
  else
    echo "  ${RED}FAIL${RESET}  $description"
    ((failures++))
  fi
}

no_helpers() {
  local f left=()
  for f in face face-admin faced face-engine-howdy face-gate face-identity face-notify \
           face-set-idle-lock face-uninstall face-verify hw-ir-camera remove-security-face \
           remove-security-face-lock security-probe setup-security-face setup-security-face-lock; do
    [[ -e /usr/local/bin/omarchy-$f ]] && left+=("omarchy-$f")
  done
  (( ${#left[@]} == 0 )) || { echo "left: ${left[*]}" >&2; return 1; }
}

no_packages() {
  # One `pacman -Q` per package, not one call with three names: a single call
  # exits non-zero as soon as ANY of them is missing, so `! pacman -Q a b c`
  # passes while a is still installed. That is the same trap as the helper list
  # above, and it would have hidden exactly the package this rewrite rebuilds.
  local p left=()
  for p in howdy python-dlib python-dlib-cuda; do
    pacman -Q "$p" >/dev/null 2>&1 && left+=("$p")
  done
  (( ${#left[@]} == 0 )) || { echo "installed: ${left[*]}" >&2; return 1; }
}

no_glob() { ! compgen -G "$1" >/dev/null; }

echo "F0 — old install verification (plan-engine.md §2)"

check "no old helper in /usr/local/bin (16 names)" no_helpers
check "no omarchy-faced units" \
  bash -c '[[ ! -e /etc/systemd/system/omarchy-faced.socket && ! -e /etc/systemd/system/omarchy-faced.service ]]'
check "omarchy-faced.socket is not enabled" \
  bash -c '! systemctl is-enabled --quiet omarchy-faced.socket 2>/dev/null'
check "no polkit policy, no /etc/pam.d/omarchy-lock-face" \
  bash -c '[[ ! -e /usr/share/polkit-1/actions/no.graveklar.face.policy && ! -e /etc/pam.d/omarchy-lock-face ]]'
check "no face lines in any PAM stack" \
  bash -c '! grep -lE "omarchy-face-(gate|verify)" /etc/pam.d/* 2>/dev/null'
check "no state, store or config directory" \
  bash -c '[[ ! -e /run/omarchy-face && ! -e /var/lib/omarchy-face && ! -e /etc/omarchy-face ]]'
check "howdy and python-dlib are not installed" no_packages
check "no howdy polkit drop-in, no /usr/lib/security/howdy" \
  bash -c '[[ ! -e /usr/lib/systemd/system/polkit-agent-helper@.service.d/10-howdy.conf && ! -d /usr/lib/security/howdy ]]'
check "no build temp directory" no_glob '/tmp/omarchy-face-build.*'
check "no graveklar.face in shell.json" \
  bash -c '! grep -q "graveklar.face" "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"'
check "no face entries in the Omarchy menu" \
  bash -c '! grep -q "security.face" "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc" 2>/dev/null'
check "no patched lock clone" \
  bash -c '! grep -rl "added by omarchy-face" "${XDG_CONFIG_HOME:-$HOME/.config}"/omarchy/plugins/*/Service.qml 2>/dev/null'

# The plugin folders, and the backup `omarchy plugin remove` leaves behind for a
# plugin that is not a git checkout (plan-engine.md §10.3). §2's list checks only
# the live folder, which is why a removal from the old design can look clean and
# still leave the whole old tree on disk under a dot name.
check "no graveklar.face plugin folder" bash -c "[[ ! -e '$PLUGINS/graveklar.face' ]]"
check "no graveklar.face-lock plugin folder" bash -c "[[ ! -e '$PLUGINS/graveklar.face-lock' ]]"
check "no .graveklar.face* backup or staging folder" no_glob "$PLUGINS/.graveklar.face*"

echo
if (( failures == 0 )); then
  echo "${GREEN}Clean.${RESET} ${DIM}F0 passes; F1 may install.${RESET}"
else
  echo "${RED}$failures check(s) failed.${RESET} ${DIM}Remove what is listed, then run this again.${RESET}"
fi
exit $(( failures > 0 ))
