#!/bin/bash

# Install the omarchy-face helpers into /usr/local/bin and add the menu entries.
# Installing does not configure anything: run `omarchy-setup-security-face`
# (or Setup > Security > Face ID) afterwards.

set -e

GREEN=$'\e[32m'
RED=$'\e[31m'
DIM=$'\e[2m'
RESET=$'\e[0m'

SRC_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/bin
BIN_DIR=/usr/local/bin
MENU_FILE=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc

HELPERS=(
  omarchy-face-admin
  omarchy-face-identity
  omarchy-security-probe
  omarchy-face-set-idle-lock
  omarchy-faced
  omarchy-hw-ir-camera
  omarchy-face
  omarchy-face-gate
  omarchy-face-verify
  omarchy-face-notify
  omarchy-face-engine-howdy
  omarchy-setup-security-face
  omarchy-remove-security-face
  omarchy-setup-security-face-lock
  omarchy-remove-security-face-lock
)

echo -e "${GREEN}Installing omarchy-face helpers to ${BIN_DIR}.\n${RESET}"

sources=()
for helper in "${HELPERS[@]}"; do
  [[ -f $SRC_DIR/$helper ]] || {
    echo "Missing $SRC_DIR/$helper" >&2
    exit 1
  }
  sources+=("$SRC_DIR/$helper")
done

# One privileged call for the lot, rather than one per file: on a machine where
# sudo cannot cache a credential -- no controlling terminal, for instance --
# per-file calls mean one password prompt per helper.
#
# Honour SUDO_ASKPASS when there is no terminal to prompt on, so this is
# drivable from a script or an editor as well as from a shell.
SUDO=(sudo)
[[ ! -t 0 && -n ${SUDO_ASKPASS:-} ]] && SUDO=(sudo -A)

# root:root 0755 is not housekeeping: two of these are executed by root from a
# PAM stack, and the setup script refuses to wire them in if they are writable
# by anyone else.
"${SUDO[@]}" install -o root -g root -m 0755 -t "$BIN_DIR" "${sources[@]}"

for helper in "${HELPERS[@]}"; do
  echo "  $helper"
done

if [[ -f $MENU_FILE ]]; then
  echo -e "\nUpdating the Omarchy menu..."
  # Entry by entry, not all-or-nothing. The previous version skipped the whole
  # block when any face entry was already present, so on an upgrade a newly
  # added entry could never appear -- indistinguishable from the menu ignoring
  # it.
  python3 - "$MENU_FILE" <<'PYMENU'
import sys

path = sys.argv[1]
text = open(path).read()

entries = [
    ("setup.security.face",
     '  "setup.security.face": {"icon":"","label":"Face ID","when":"omarchy-hw-ir-camera","action":"omarchy-launch-floating-terminal-with-presentation omarchy-setup-security-face"},'),
    ("remove.security.face",
     '  "remove.security.face": {"icon":"","label":"Face ID","when":"grep -q omarchy-face-verify /etc/pam.d/sudo","action":"omarchy-launch-floating-terminal-with-presentation omarchy-remove-security-face"},'),
    ("setup.security.face-models",
     '  "setup.security.face-models": {"icon":"","label":"Manage Face ID","when":"omarchy-hw-ir-camera","action":"omarchy-shell shell summon graveklar.face \'{}\'"},'),
    ("setup.security.face-lock",
     '  "setup.security.face-lock": {"icon":"","label":"Face ID on Lock Screen","when":"omarchy-hw-ir-camera","action":"omarchy-launch-floating-terminal-with-presentation omarchy-setup-security-face-lock"},'),
]

# The id is matched with its quotes. "setup.security.face" is a prefix of
# "setup.security.face-models", so a bare substring test answers wrongly for
# three of these four.
missing = [line for key, line in entries if ('"%s"' % key) not in text]

if not missing:
    print("  already up to date")
else:
    block = "\n"
    if "// omarchy-face" not in text:
        block += "  // omarchy-face\n"
    block += "\n".join(missing) + "\n"

    # JSONC, with comments and trailing commas: edited as text because
    # reserializing would throw away the commentary Omarchy ships in it.
    close = text.rindex("}")
    open(path, "w").write(text[:close] + block + text[close:])
    for line in missing:
        print("  added: %s" % line.split('"label":"')[1].split('"')[0])
PYMENU
else
  echo -e "\n${DIM}No $MENU_FILE -- skipping menu entries.${RESET}"
fi

# The setup panel runs as the user and must ask root to touch the face models.
# Without this policy pkexec falls back to demanding the root password, which on
# a single-user laptop is usually not even set.
# The verification daemon, for PAM stacks that run unprivileged. Socket
# activated: it is started by the first request and exits when idle.
UNIT_SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/systemd
if [[ -d $UNIT_SRC ]] && command -v systemctl >/dev/null 2>&1; then
  echo -e "\nInstalling the verification daemon..."
  "${SUDO[@]}" install -o root -g root -m 0644 \
    "$UNIT_SRC/omarchy-faced.socket" "$UNIT_SRC/omarchy-faced.service" \
    -t /etc/systemd/system
  "${SUDO[@]}" systemctl daemon-reload
  "${SUDO[@]}" systemctl enable --now omarchy-faced.socket >/dev/null 2>&1 ||
    echo "  ${RED}could not enable omarchy-faced.socket${RESET}"
  echo "  omarchy-faced.socket"
fi

POLICY_SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/polkit/no.graveklar.face.policy
if [[ -f $POLICY_SRC ]]; then
  echo -e "\nInstalling the polkit policy..."
  "${SUDO[@]}" install -o root -g root -m 0644 "$POLICY_SRC" \
    /usr/share/polkit-1/actions/no.graveklar.face.policy
  echo "  no.graveklar.face.admin (auth_self_keep)"
fi

PLUGIN_SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_DIR=$HOME/.config/omarchy/plugins/graveklar.face

if command -v omarchy-shell >/dev/null 2>&1; then
  echo -e "\nInstalling the shell plugin..."

  if [[ $PLUGIN_SRC == "$PLUGIN_DIR" ]]; then
    # `omarchy plugin add` already cloned the repository here, so the plugin is
    # in place and copying it over itself would only destroy the checkout.
    echo "  already in the plugins directory"
  else
    # Staged alongside and moved into place, rather than copied over the live
    # one. The shell watches that directory and reloads on any change, so a slow
    # copy gets read half-finished and reported as a broken plugin. The staging
    # name starts with a dot; the registry's glob skips it.
    staging=$(mktemp -d "$HOME/.config/omarchy/plugins/.graveklar.face.XXXXXX")
    cp -r "$PLUGIN_SRC/manifest.json" "$PLUGIN_SRC/Service.qml" "$PLUGIN_SRC/Panel.qml" "$staging/"
    rm -rf "$PLUGIN_DIR"
    mv "$staging" "$PLUGIN_DIR"
  fi

  # Third-party plugins are inert until they appear in shell.json, however
  # valid the manifest is. Enabling is what actually mounts the service.
  #
  # `enable` resolves the id against the shell's registry, not the directory on
  # disk, so calling it the instant after creating that directory can fail --
  # the shell has not noticed yet. Nudge the registry, then retry rather than
  # assume. And do NOT swallow the outcome: a silent failure here installs
  # everything correctly and leaves the plugin switched off, which looks like
  # the plugin being broken rather than not enabled.
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

  enabled=false
  for _ in 1 2 3; do
    if omarchy plugin enable graveklar.face >/dev/null 2>&1; then
      enabled=true
      break
    fi
    sleep 1
  done

  if [[ $enabled == true ]]; then
    echo "  graveklar.face (spinner while authenticating, flourish on unlock)"
  else
    echo "  ${RED}graveklar.face installed but could not be enabled${RESET}"
    echo "  run: omarchy plugin enable graveklar.face"
  fi

  # rescanPlugins is not enough here. This plugin is keepLoaded, and a rescan
  # leaves an already-mounted service instance running the code it started
  # with -- so an updated Service.qml installs cleanly, reports no errors, and
  # changes nothing on screen. Only a restart re-instantiates it.
  omarchy restart shell >/dev/null 2>&1 || true
fi

echo
echo -e "${GREEN}Installed.${RESET} Next:"
echo "  ${DIM}omarchy-setup-security-face${RESET}   install an engine, enroll, and wire up PAM"
