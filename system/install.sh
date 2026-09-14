#!/bin/bash
#
# omarchy-face v2
# omarchy-face-version: 2.0.0-dev
#
# The first install, and the only call Face ever makes through polkit's generic
# exec action (plan-engine.md §5.1).
#
#   pkexec /bin/bash -c "$INSTALL_SCRIPT" omarchy-face-install "$PLUGIN_DIR" "$USER"
#
# The GUI reads this file and passes its TEXT inline, so what polkit authorised
# is exactly the text that runs. That is also why this script is short and why
# it does as little as it can get away with: the dialog the owner sees says
# "run /bin/bash as the super user" with no message of Face's own, so every line
# here has to be worth reading. Setup warns about that wording before the dialog
# appears, and it is the only time it is ever shown (§5.1: every later update
# goes through `pkexec omarchy-face-admin install-system`, under Face's own
# message).
#
# What it does: snapshot the plugin's system/ into a directory only root could
# have created, check the snapshot, install omarchy-face-admin out of it, and
# hand over. The rest of the install -- the other six helpers, the units, the
# policy, the config, systemd -- is one procedure inside omarchy-face-admin, so
# the first install and every later update install the same set the same way.

set -uo pipefail
unset IFS BASH_ENV ENV CDPATH
PATH=/usr/local/bin:/usr/bin
umask 022

CONFIG_FILE=/etc/omarchy-face/config
ADMIN=/usr/local/bin/omarchy-face-admin

die() {
  printf '{"error":"%s"}\n' "$1"
  exit 1
}

[[ $EUID -eq 0 ]] || die "not_root"

PLUGIN_DIR=${1:-}
ACCOUNT=${2:-}

[[ -n $PLUGIN_DIR && -n $ACCOUNT ]] || die "bad_arguments"
[[ $PLUGIN_DIR == /* && $PLUGIN_DIR != *..* ]] || die "plugin_missing"
[[ -d $PLUGIN_DIR/system ]] || die "plugin_missing"
[[ $ACCOUNT != root ]] || die "unknown_account"
account_uid=$(id -u -- "$ACCOUNT" 2>/dev/null) || die "unknown_account"

# pkexec reports who authenticated, and it cannot be forged by the caller. The
# generic exec action is auth_admin, so this is an administrator -- but it need
# not be the account the plugin folder belongs to, and installing somebody
# else's scripts as root is not something an administrator meant to ask for.
[[ -z ${PKEXEC_UID:-} || ${PKEXEC_UID:-} == "$account_uid" ]] || die "not_owner"

# The plugin folder is the account's own or the system's. Anything else is a
# third party's directory (§5.1's trust boundary is "the owner's own files",
# not "any path handed to root").
owner_uid=$(stat -c %u "$PLUGIN_DIR/system" 2>/dev/null) || die "plugin_missing"
[[ $owner_uid == 0 || $owner_uid == "$account_uid" ]] || die "plugin_not_owned"

# First install only. A machine that already has a config is updated with
# `omarchy-face-admin install-system`, under Face's own polkit message and with
# the version check that goes with it.
[[ ! -e $CONFIG_FILE ]] || die "already_installed"

logger -t omarchy-face -p auth.notice -- \
  "first install requested by uid ${PKEXEC_UID:-0} for $ACCOUNT from $PLUGIN_DIR" 2>/dev/null || true

# Snapshot, then check, then install from the snapshot (§5.1, round-3
# hardening). The plugin folder is writable by the account, so checking a file
# there and copying that same path afterwards is a race a process running as the
# owner can win. /run is root-owned, and mktemp -d makes the directory 0700
# before anything is written into it, so what gets checked below is what gets
# installed.
tmp=$(mktemp -d /run/omarchy-face-install.XXXXXX) || die "snapshot_failed"
trap 'rm -rf -- "$tmp"' EXIT
chmod 0700 "$tmp" || die "snapshot_failed"
cp -a --no-dereference "$PLUGIN_DIR/system/." "$tmp/" 2>/dev/null || die "snapshot_failed"

# Plain files only. A symlink would have been followed back out of the snapshot
# when it was installed, and a hard link leaves the same inode writable from
# outside it.
[[ -z $(find "$tmp" -mindepth 1 \( -type l -o -links +1 -o ! -type f \) -print -quit 2>/dev/null) ]] ||
  die "snapshot_unsafe"

# One file is installed here: the helper that installs the rest. It has to carry
# both headers, because from the next line on it is trusted to do the whole job
# (§8.1) -- and because a plugin folder holding somebody's unrelated system/
# directory should stop here rather than at a mode bit.
head -40 "$tmp/omarchy-face-admin" 2>/dev/null | grep -q 'omarchy-face v2' || die "snapshot_unmarked"
head -40 "$tmp/omarchy-face-admin" 2>/dev/null | grep -q 'omarchy-face-version:' || die "snapshot_unversioned"

[[ -d /usr/local/bin ]] || install -d -o root -g root -m 0755 /usr/local/bin || die "install_failed"
install -o root -g root -m 0755 "$tmp/omarchy-face-admin" "$ADMIN" || die "install_failed"

# `env -u PKEXEC_UID`: --first-install is refused when PKEXEC_UID is set, so
# that entry point cannot be reached through Face's own auth_self action by a
# second user naming a plugin folder of their own (omarchy-face-admin, "who may
# run this"). Here the caller is already root, and the account is passed
# explicitly rather than inferred from whoever answered the dialog.
#
# Not `exec`: exec replaces this process, the EXIT trap never runs, and the
# snapshot directory stays in /run until the next boot. The handover is one
# call, and its JSON document and exit status are this script's.
env -u PKEXEC_UID "$ADMIN" install-system --first-install "$PLUGIN_DIR" "$ACCOUNT"
exit $?
