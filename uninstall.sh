#!/bin/bash

# Remove everything this project installed, in the order that keeps the machine
# usable at every step.
#
# PAM first and always: a stack pointing at helpers that no longer exist means
# no sudo, and the way out of that is a root shell you had the foresight to
# leave open. This refuses to get there.

set -e

GREEN=$'\e[32m'
RED=$'\e[31m'
DIM=$'\e[2m'
RESET=$'\e[0m'

MENU_FILE=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc
PLUGIN_DIR=$HOME/.config/omarchy/plugins/graveklar.face
SHELL_CONFIG=$HOME/.config/omarchy/shell.json

SUDO=(sudo)
[[ ! -t 0 && -n ${SUDO_ASKPASS:-} ]] && SUDO=(sudo -A)

for file in /etc/pam.d/sudo /etc/pam.d/polkit-1; do
  [[ -f $file ]] || continue
  if grep -qE 'omarchy-face-gate|omarchy-face-verify' "$file"; then
    echo -e "${RED}${file} still references the face helpers.${RESET}" >&2
    echo "Run omarchy-remove-security-face first, or sudo will start failing." >&2
    exit 1
  fi
done

echo -e "${GREEN}Removing omarchy-face.\n${RESET}"

# The shell holds the plugin open; stopping it from being enabled first means
# the restart at the end does not race a directory being deleted underneath it.
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin disable graveklar.face >/dev/null 2>&1 || true
fi

if [[ -d $PLUGIN_DIR ]]; then
  rm -rf "$PLUGIN_DIR"
  echo "  plugin directory"
fi

# `omarchy plugin disable` may only mark it disabled rather than removing the
# entry, and an entry pointing at a directory that is gone is a warning on every
# shell start.
if [[ -f $SHELL_CONFIG ]] && grep -q 'graveklar.face' "$SHELL_CONFIG"; then
  python3 - "$SHELL_CONFIG" <<'PY'
import json, sys

path = sys.argv[1]
try:
    config = json.load(open(path))
except Exception:
    sys.exit(0)

for key in ("plugins", "disabledPlugins"):
    value = config.get(key)
    if isinstance(value, list):
        config[key] = [
            entry for entry in value
            if not (entry == "graveklar.face"
                    or (isinstance(entry, dict) and entry.get("id") == "graveklar.face"))
        ]

json.dump(config, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
  echo "  shell.json entry"
fi

# Every privileged removal in one call. By this point face unlock has already
# been taken out of the PAM stacks, so each separate sudo would be a fresh
# password prompt -- five of them to uninstall one thing.
#
# Enrolled identities go too: they are face data belonging to people who are
# not the account owner, and leaving that on disk after an uninstall is the
# kind of thing nobody expects and nobody thinks to check.
"${SUDO[@]}" bash -s <<'ROOT'
set -e
rm -f /usr/local/bin/omarchy-hw-ir-camera       /usr/local/bin/omarchy-face       /usr/local/bin/omarchy-face-gate       /usr/local/bin/omarchy-face-verify       /usr/local/bin/omarchy-face-notify       /usr/local/bin/omarchy-face-engine-howdy       /usr/local/bin/omarchy-face-admin       /usr/local/bin/omarchy-face-identity       /usr/local/bin/omarchy-security-probe       /usr/local/bin/omarchy-setup-security-face       /usr/local/bin/omarchy-remove-security-face \
      /usr/local/bin/omarchy-setup-security-face-lock \
      /usr/local/bin/omarchy-remove-security-face-lock
rm -f /usr/share/polkit-1/actions/no.graveklar.face.policy
rm -f /etc/pam.d/omarchy-lock-face
rm -f /usr/lib/security/howdy/models/identity-*.dat 2>/dev/null || true
rm -rf /run/omarchy-face /var/lib/omarchy-face /etc/omarchy-face
ROOT
echo "  helpers, polkit policy, identities, runtime and persistent state"

rm -f "${XDG_RUNTIME_DIR:-/run/user/$UID}/omarchy-face-setup-open"

if [[ -f $MENU_FILE ]] && grep -q 'security.face' "$MENU_FILE"; then
  sed -i -e '/\/\/ omarchy-face/d' -e '/"setup.security.face"/d' \
    -e '/"remove.security.face"/d' -e '/"setup.security.face-models"/d' "$MENU_FILE"
  echo "  menu entries"
fi

if command -v omarchy >/dev/null 2>&1; then
  omarchy restart shell >/dev/null 2>&1 || true
fi

echo
echo -e "${GREEN}Done.${RESET}"
echo "${DIM}Your own face models and the howdy package are left alone --${RESET}"
echo "${DIM}omarchy-remove-security-face handles those.${RESET}"
