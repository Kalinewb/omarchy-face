#!/bin/bash

# F1's gate: install → purge, and the §10.3 checklist afterwards
# (plan-merged.md §4 phase 2, plan-engine.md §10.3).
#
# The whole point of the gate is that it runs the REAL scripts -- the same
# system/install.sh the GUI hands to pkexec, and the same omarchy-face-admin it
# installs -- as uid 0, and then proves that nothing is left. Two ways to do
# that:
#
#   ./dev/f1-round-trip.sh            in a private user namespace (the default)
#   sudo ./dev/f1-round-trip.sh --here   on this machine, for real
#
# The default is the sandbox, because a development loop that installs into
# /usr/local/bin and edits /etc on every run is a development loop that
# eventually leaves something behind. `unshare --map-root-user --mount` gives a
# uid 0 that owns nothing outside the namespace, and tmpfs over /etc, /run,
# /usr/local and polkit's actions directory gives the scripts real directories
# to install into. Everything else -- /usr/lib, /var/lib, the plugin folder,
# pacman's database -- is the machine's own.
#
# What the sandbox changes, and therefore what --here is still worth running for:
#
#   * /etc is a tmpfs whose entries are symlinks back to the real /etc, EXCEPT
#     /etc/pam.d, which is a copy. So the PAM byte-identity check below is a
#     check on a copy; the real /etc/pam.d cannot be written from in here at all.
#   * systemd is not reachable (/run is a tmpfs), so systemctl falls back to its
#     offline mode: `enable` writes the symlink, `--now` and `daemon-reload`
#     report a failure, and the install collects them as warnings.
#   * uid 1000 maps to 0 and every other uid to nobody, so an ownership check
#     inside says root for anything this machine's owner owns.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ACCOUNT=${SUDO_USER:-${USER:-$(id -un)}}
PLUGINS="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"

failures=0
checks=0
bound_plugin=0

check() { # check <description> <command…>
  local description=$1
  shift
  checks=$((checks + 1))
  if "$@" >/dev/null 2>&1; then
    echo "  ${GREEN}pass${RESET}  $description"
  else
    echo "  ${RED}FAIL${RESET}  $description"
    failures=$((failures + 1))
  fi
}

note() { echo "  ${YELLOW}note${RESET}  $*"; }
step() { echo; echo "${DIM}== $*${RESET}"; }

no_glob() { ! compgen -G "$1" >/dev/null; }

# --- the sandbox -------------------------------------------------------------

if [[ ${1:-} != --here && ${OMARCHY_FACE_F1_IN_NS:-0} != 1 ]]; then
  command -v unshare >/dev/null || { echo "unshare is not installed; use --here" >&2; exit 1; }
  exec env OMARCHY_FACE_F1_IN_NS=1 OMARCHY_FACE_F1_ACCOUNT="$ACCOUNT" \
    unshare --map-root-user --mount --pid --fork "$BASH" "$0" --sandboxed
fi

if [[ ${OMARCHY_FACE_F1_IN_NS:-0} == 1 ]]; then
  ACCOUNT=${OMARCHY_FACE_F1_ACCOUNT:-$ACCOUNT}
  # /etc, with everything but pam.d pointing back at the real one. A bare tmpfs
  # would leave the namespace without /etc/passwd, and then `install -o root`
  # and `id -u <account>` both stop working.
  mount --bind /etc /mnt || exit 1
  mount -t tmpfs tmpfs /etc || exit 1
  chmod 0755 /etc
  for real in /mnt/*; do ln -s "$real" "/etc/${real#/mnt/}"; done
  rm -f /etc/pam.d
  cp -rp /mnt/pam.d /etc/pam.d 2>/dev/null
  chown -R root:root /etc/pam.d
  # /etc/systemd/system has to be a real directory: two units are installed
  # into it, and `systemctl enable` writes a symlink beside them.
  rm -f /etc/systemd
  mkdir /etc/systemd
  for real in /mnt/systemd/*; do ln -s "$real" "/etc/systemd/${real#/mnt/systemd/}"; done
  rm -f /etc/systemd/system
  cp -rp /mnt/systemd/system /etc/systemd/system 2>/dev/null
  chown -R root:root /etc/systemd/system
  # tmpfs is mode 1777 by default. /usr/local/bin and the polkit actions
  # directory are places root helpers are installed into, and the install now
  # refuses a world-writable one -- correctly -- so the sandbox has to give them
  # the modes a real machine has.
  mount -t tmpfs tmpfs /run || exit 1
  chmod 0755 /run
  mount -t tmpfs tmpfs /usr/local || exit 1
  chmod 0755 /usr/local
  mkdir -p /usr/local/bin
  chmod 0755 /usr/local/bin
  mount -t tmpfs tmpfs /usr/share/polkit-1/actions || exit 1
  chmod 0755 /usr/share/polkit-1/actions
  # `install-system` (no arguments) derives the plugin folder from the config
  # account's home, which is the INSTALLED plugin, not this checkout. Binding the
  # checkout over it inside the namespace is how the update path gets tested
  # against the code being written. The bind is namespace-local: nothing is
  # written under ~/.config/omarchy/plugins, which would reload every bar widget
  # (E13) on a machine somebody is using.
  if [[ -d $PLUGINS/graveklar.face ]]; then
    mount --bind "$REPO" "$PLUGINS/graveklar.face" && bound_plugin=1
  fi
  echo "${DIM}sandbox: uid $(id -u), /etc /run /usr/local and polkit actions are private to this run${RESET}"
fi

[[ $EUID -eq 0 ]] || { echo "f1-round-trip: needs to be root (use --here under sudo, or drop the flag)" >&2; exit 1; }

echo "F1 round trip — install → purge (plan-merged.md §4 phase 2)"
echo "${DIM}plugin: $REPO   account: $ACCOUNT${RESET}"

# --- before ------------------------------------------------------------------

pam_before=$(find /etc/pam.d -type f -exec sha256sum {} + 2>/dev/null | sort -k2)
[[ -n $pam_before ]] || { echo "could not read /etc/pam.d" >&2; exit 1; }

step "no terminal anywhere in the GUI (plan-merged.md §4 phase 2)"
# The gate says the whole flow runs through the popup. The GUI has exactly one
# way to run anything -- common/Ask.qml's bash -c 'exec "$@"' -- so the check is
# that no view reaches for a terminal emulator or one of Omarchy's launchers.
# Comment lines are stripped first. The indicator's second line is "sudo ·
# pacman, from foot" (plan-gui.md §6.2), so the plan's own example copy names a
# terminal in a comment -- and a word in a comment is not a launch. Anything on
# a line of code, including a trailing comment on one, still counts.
check "no terminal launcher in any .qml" \
  bash -c "! sed 's#^[[:space:]]*//.*##' '$REPO'/*.qml '$REPO'/common/*.qml |
           grep -nE '\\b(foot|alacritty|kitty|ghostty|wezterm|xterm)\\b|launch-floating-terminal|launch-editor|x-terminal-emulator'"
check "the first install is the pkexec /bin/bash form, not a terminal" \
  bash -c "grep -q 'firstInstallArgv' '$REPO/common/Ask.qml'"

step "who Face may be set up for (plan-engine.md §8.2, the auth_self boundary)"
# Face's own action is auth_self, so the owner can later run install-system with
# their own password -- which installs scripts that phase 5 runs as root from
# sudo's PAM stack. An owner who is not already an administrator would therefore
# be an owner who just became one.
nonadmin=nobody
if id -Gn -- "$nonadmin" >/dev/null 2>&1 &&
   ! id -Gn -- "$nonadmin" 2>/dev/null | tr ' ' '\n' | grep -qxF wheel; then
  refuse_out=$(/bin/bash -c "$(cat "$REPO/system/install.sh")" omarchy-face-install "$REPO" "$nonadmin" 2>/dev/null)
  echo "  ${DIM}install.sh … $nonadmin${RESET}  $refuse_out"
  check "a first install for a non-administrator account is not_admin" \
    bash -c "[[ \$(jq -r '.error' <<<'$refuse_out') == not_admin ]]"
  check "and it installed nothing" test ! -e /usr/local/bin/omarchy-face-admin
else
  note "skipped: no non-administrator account to test with"
fi

step "install (the form the GUI uses, plan-engine.md §5.1)"
echo "  ${DIM}pkexec /bin/bash -c \"\$(cat system/install.sh)\" omarchy-face-install $REPO $ACCOUNT${RESET}"
echo "  ${DIM}(pkexec dropped: this is already uid 0)${RESET}"
# stdout and stderr are captured apart, because "one JSON document on stdout,
# prose on stderr" is itself part of the contract (plan-merged.md §2 rule 3) and
# a 2>&1 here would hide every violation of it.
install_err=$(mktemp)
install_out=$(/bin/bash -c "$(cat "$REPO/system/install.sh")" omarchy-face-install "$REPO" "$ACCOUNT" 2>"$install_err")
install_rc=$?
echo "  ${DIM}exit $install_rc${RESET}  $install_out"
[[ -s $install_err ]] && echo "  ${DIM}stderr:${RESET} $(cat "$install_err")"
check "the install exited 0" test "$install_rc" -eq 0
check "stdout is one JSON document" bash -c "jq -e . <<<'$install_out' >/dev/null"

step "installed state (plan-engine.md §8.1, §10.1 row system)"
for helper in omarchy-face-admin omarchy-face-gate omarchy-face-verify omarchy-faced \
              omarchy-face-identity omarchy-face-lock-verify omarchy-face-camera; do
  check "/usr/local/bin/$helper is root:root 0755" \
    bash -c "[[ \$(stat -c '%U %G %a' /usr/local/bin/$helper) == 'root root 755' ]]"
done
for unit in omarchy-faced.socket omarchy-faced.service; do
  check "/etc/systemd/system/$unit is root:root 0644" \
    bash -c "[[ \$(stat -c '%U %G %a' /etc/systemd/system/$unit) == 'root root 644' ]]"
done
check "the polkit policy is root:root 0644" \
  bash -c "[[ \$(stat -c '%U %G %a' /usr/share/polkit-1/actions/no.graveklar.face.policy) == 'root root 644' ]]"
check "the policy is the owner action, annotated with exec.path" \
  bash -c "grep -q 'no.graveklar.face.owner' /usr/share/polkit-1/actions/no.graveklar.face.policy &&
           grep -q 'policykit.exec.path' /usr/share/polkit-1/actions/no.graveklar.face.policy"
check "/etc/omarchy-face/config is root:root 0644 and names the account" \
  bash -c "[[ \$(stat -c '%U %G %a' /etc/omarchy-face/config) == 'root root 644' ]] &&
           grep -qx 'account=$ACCOUNT' /etc/omarchy-face/config &&
           grep -qx 'sudo=false' /etc/omarchy-face/config &&
           grep -qx 'lock=false' /etc/omarchy-face/config"
check "every installed file is byte-identical to the plugin's system/ copy" \
  bash -c "for f in omarchy-face-admin omarchy-face-gate omarchy-face-verify omarchy-faced \
                    omarchy-face-identity omarchy-face-lock-verify omarchy-face-camera; do
             diff -q '$REPO/system/'\$f /usr/local/bin/\$f >/dev/null || exit 1
           done
           diff -q '$REPO/system/omarchy-faced.socket' /etc/systemd/system/omarchy-faced.socket >/dev/null &&
           diff -q '$REPO/system/omarchy-faced.service' /etc/systemd/system/omarchy-faced.service >/dev/null &&
           diff -q '$REPO/system/no.graveklar.face.policy' /usr/share/polkit-1/actions/no.graveklar.face.policy >/dev/null"
check "nothing in /etc/pam.d was touched by the install" \
  bash -c "[[ \"\$(find /etc/pam.d -type f -exec sha256sum {} + | sort -k2)\" == \"\$(cat <<'PAM'
$pam_before
PAM
)\" ]]"

if systemctl is-enabled --quiet omarchy-faced.socket 2>/dev/null; then
  check "omarchy-faced.socket is enabled" true
else
  note "omarchy-faced.socket is not enabled (expected in the sandbox: systemd is unreachable)"
fi

step "the status document reads the install back (plan-merged.md §2.2)"
# In a file, not in a bash -c string: the document contains an apostrophe
# ("Face's system files"), and a check that cannot survive its own input is not
# a check.
status_file=$(mktemp)
"$REPO/bin/omarchy-face-status" --json >"$status_file"
status_rc=$?
check "omarchy-face-status exits 0" test "$status_rc" -eq 0
check "it is one JSON document" jq -e . "$status_file"
system_state=$(jq -r '.rows[] | select(.id=="system") | .state' "$status_file")
system_detail=$(jq -r '.rows[] | select(.id=="system") | .detail' "$status_file")
echo "  ${DIM}system row: $system_state — $system_detail${RESET}"
if systemctl is-enabled --quiet omarchy-faced.socket 2>/dev/null; then
  check "the system row is ok" test "$system_state" = ok
else
  check "the system row names the one thing the sandbox cannot do" \
    bash -c "[[ \"$system_state\" == broken && \"$system_detail\" == *'socket is not enabled'* ]]"
fi
check "the camera row found the infrared sensor" \
  bash -c "[[ \$(jq -r '.rows[] | select(.id==\"camera\") | .state' '$status_file') == ok ]]"
check "removal counts seven helpers, the daemon and the policy" \
  bash -c "[[ \$(jq -r '.removal.helpers' '$status_file') == 7 &&
              \$(jq -r '.removal.daemon' '$status_file') == true &&
              \$(jq -r '.removal.policy' '$status_file') == true ]]"

step "a second install-system is a no-op, not a version_mismatch"
if ((bound_plugin == 0)); then
  note "skipped: the account's plugin folder is not this checkout (run ./install.sh first)"
else
update_err=$(mktemp)
update_out=$(/usr/local/bin/omarchy-face-admin install-system 2>"$update_err")
update_rc=$?
echo "  ${DIM}exit $update_rc${RESET}  $update_out"
[[ -s $update_err ]] && echo "  ${DIM}stderr:${RESET} $(cat "$update_err")"
check "install-system exits 0 on an up-to-date machine" test "$update_rc" -eq 0
check "it changed nothing" bash -c "[[ \$(jq -r '.changed | length' <<<'$update_out') == 0 ]]"
fi

step "what the privileged half refuses (plan-engine.md §5.1, §8.2)"
owner_uid=$(id -u -- "$ACCOUNT")
refuse_out=$(PKEXEC_UID=65534 /usr/local/bin/omarchy-face-admin purge 2>/dev/null)
echo "  ${DIM}PKEXEC_UID=65534 … purge${RESET}  $refuse_out"
check "another user's pkexec is not_owner, whatever polkit authenticated" \
  bash -c "[[ \$(jq -r '.error' <<<'$refuse_out') == not_owner ]]"

refuse_out=$(PKEXEC_UID=$owner_uid /usr/local/bin/omarchy-face-admin install-system --first-install /tmp x 2>/dev/null)
echo "  ${DIM}PKEXEC_UID=$owner_uid … install-system --first-install /tmp x${RESET}  $refuse_out"
check "--first-install is unreachable through Face's own polkit action" \
  bash -c "[[ \$(jq -r '.error' <<<'$refuse_out') == not_owner ]]"

if ((bound_plugin == 1)); then
  # A plugin folder whose system/ holds a symlink. The snapshot is taken before
  # anything is read, and it is the snapshot that is rejected -- so this is the
  # TOCTOU hardening of §5.1 being exercised, not a check on the plugin folder.
  evil=$(mktemp -d)
  mkdir -p "$evil/system"
  cp "$REPO/system/." "$evil/system/" -a
  rm -f "$evil/system/omarchy-face-camera"
  ln -s /etc/shadow "$evil/system/omarchy-face-camera"
  mount --bind "$evil" "$PLUGINS/graveklar.face"
  refuse_out=$(/usr/local/bin/omarchy-face-admin install-system 2>/dev/null)
  echo "  ${DIM}install-system with a symlink in system/${RESET}  $refuse_out"
  check "a symlink in the snapshot is refused" \
    bash -c "[[ \$(jq -r '.error' <<<'$refuse_out') == snapshot_unsafe ]]"
  umount "$PLUGINS/graveklar.face"

  # A group-writable /usr/local/bin is a way to replace a file PAM runs as root.
  chmod g+w /usr/local/bin
  refuse_out=$(/usr/local/bin/omarchy-face-admin install-system 2>/dev/null)
  chmod g-w /usr/local/bin
  echo "  ${DIM}install-system into a group-writable /usr/local/bin${RESET}  $refuse_out"
  check "an unsafe destination directory is refused" \
    bash -c "[[ \$(jq -r '.error' <<<'$refuse_out') == install_dir_unsafe ]]"

  # An older release version than the one installed. Not a repair and never
  # offered by the Setup row, so it is refused rather than quietly downgrading
  # the root-owned half.
  older=$(mktemp -d)
  mkdir -p "$older/system"
  cp "$REPO/system/." "$older/system/" -a
  sed -i 's/omarchy-face-version: .*/omarchy-face-version: 1.0.0/' "$older"/system/*
  mount --bind "$older" "$PLUGINS/graveklar.face"
  refuse_out=$(/usr/local/bin/omarchy-face-admin install-system 2>/dev/null)
  echo "  ${DIM}install-system from an older release version${RESET}  $refuse_out"
  check "an older release version is version_mismatch, not a downgrade" \
    bash -c "[[ \$(jq -r '.error' <<<'$refuse_out') == version_mismatch ]]"
  umount "$PLUGINS/graveklar.face"
  check "the refused installs changed nothing" \
    bash -c "diff -q '$REPO/system/omarchy-face-camera' /usr/local/bin/omarchy-face-camera >/dev/null &&
             [[ \$(head -40 /usr/local/bin/omarchy-face-admin | sed -n 's/.*omarchy-face-version: //p') == '2.0.0' ]]"
  rm -rf "$evil" "$older"
else
  note "refusal tests on the plugin folder skipped: it is not this checkout"
fi

# purge-legacy deletes things Face never installed -- a howdy polkit drop-in
# owned by the howdy package, stock model files, PAM backups. With no config
# there is no owner it could be doing that on behalf of.
mv /etc/omarchy-face/config /etc/omarchy-face/config.away
refuse_out=$(/usr/local/bin/omarchy-face-admin purge-legacy 2>/dev/null)
mv /etc/omarchy-face/config.away /etc/omarchy-face/config
echo "  ${DIM}purge-legacy with no config${RESET}  $refuse_out"
check "purge-legacy is not offered to anybody on an unconfigured machine" \
  bash -c "[[ \$(jq -r '.error' <<<'$refuse_out') == not_installed ]]"

step "the PAM block library, both directions (plan-engine.md §4.1)"
# phase 5's sudo-on and sudo-off are the callers, and they do not exist yet --
# so the functions are exercised here, before an auth stack depends on them.
# The library is sourced straight out of the installed helper (everything above
# its verb dispatch), which is the same code phase 5 will call.
insert_probe=/etc/pam.d/omarchy-face-insert-probe
cat >"$insert_probe" <<'PAMINSERT'
#%PAM-1.0
auth		include		system-auth
account		include		system-auth
session		include		system-auth
session		optional	pam_systemd.so class=none
PAMINSERT
insert_before=$(sha256sum "$insert_probe" | cut -d' ' -f1)

pam_lib() { # pam_lib <function> <file>
  # The function name travels in the environment, not in $@: the sourced prefix
  # ends with the helper's own `shift`, which would eat the positional
  # parameters this needs afterwards. `set -- purge` gives that prefix a verb to
  # shift, so its "no verb" check does not exit the shell.
  FACE_FN=$1 FACE_ARG=$2 bash -c '
    set -- purge
    source <(sed -n "1,/^# --- verbs/p" /usr/local/bin/omarchy-face-admin) >/dev/null
    "$FACE_FN" "$FACE_ARG"'
}

pam_lib pam_insert_block "$insert_probe"
check "pam_insert_block wrote exactly one marked block above the first auth line" \
  bash -c "[[ \$(grep -c '^# omarchy-face begin\$' '$insert_probe') == 1 &&
              \$(grep -c '^# omarchy-face end\$' '$insert_probe') == 1 &&
              \$(grep -c 'omarchy-face' '$insert_probe') == 4 ]] &&
           [[ \$(sed -n '2p' '$insert_probe') == '# omarchy-face begin' ]] &&
           grep -q '^auth[[:space:]]*include[[:space:]]*system-auth' '$insert_probe'"
pam_lib pam_insert_block "$insert_probe"
check "a second insert is refused, not stacked" \
  bash -c "[[ \$(grep -c '^# omarchy-face begin\$' '$insert_probe') == 1 ]]"

# A line somebody added inside the block is not ours to delete.
sed -i '/^# omarchy-face end$/i auth  optional  pam_permit.so' "$insert_probe"
pam_lib pam_remove_block "$insert_probe"
check "a foreign line inside the block makes removal refuse" \
  bash -c "grep -q 'pam_permit.so' '$insert_probe' &&
           [[ \$(grep -c '^# omarchy-face begin\$' '$insert_probe') == 1 ]]"
sed -i '/pam_permit.so/d' "$insert_probe"

pam_lib pam_remove_block "$insert_probe"
check "insert then remove leaves the stack byte-identical" \
  bash -c "[[ \$(sha256sum '$insert_probe' | cut -d' ' -f1) == '$insert_before' ]]"
rm -f "$insert_probe"

step "the daemon drains its socket (plan-engine.md §6.1)"
# Accept=no means systemd hands over the LISTENING socket. A daemon that exits
# without accepting leaves the client pending, systemd re-activates immediately,
# and five of those in ten seconds put the socket unit itself into `failed` with
# its path unlinked -- a denial of service any local user can run, and root is
# needed to undo it.
python3 - "$REPO/system/omarchy-faced" <<'DRAIN'
import os, socket, sys, tempfile
daemon = sys.argv[1]
path = os.path.join(tempfile.mkdtemp(), "verify.sock")
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(16)
# A connection already waiting when the daemon starts, exactly as activation
# hands it over.
early = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
early.connect(path)
os.set_inheritable(server.fileno(), True)
pid = os.fork()
if pid == 0:
    os.dup2(server.fileno(), 3)
    os.set_inheritable(3, True)
    # The daemon says what it refuses, at syslog priorities, because on a real
    # machine that goes to the journal. Here it would go to this suite's output.
    null = os.open(os.devnull, os.O_WRONLY)
    os.dup2(null, 2)
    os.environ["LISTEN_FDS"] = "1"
    os.environ["LISTEN_PID"] = str(os.getpid())
    os.execv(daemon, [daemon])
try:
    early.settimeout(5)
    early.sendall(b"VERIFY-LOCK\n")
    if not early.recv(64).startswith(b"NO "):
        sys.exit(1)
    for _ in range(3):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        client.connect(path)
        client.sendall(b"VERIFY-PERSON anna\n")
        if not client.recv(64).startswith(b"NO "):
            sys.exit(1)
        client.close()
    # Still there: it drained the backlog instead of dying with one pending.
    sys.exit(0 if os.waitpid(pid, os.WNOHANG) == (0, 0) else 1)
finally:
    try:
        os.kill(pid, 15)
        os.waitpid(pid, 0)
    except OSError:
        pass
DRAIN
check "four connections, four answers, and the daemon is still up" test $? -eq 0

step "purge (plan-engine.md §10.2 step 2)"
# A stack WITH a marked block, so purge's PAM step is exercised rather than
# skipped. Phase 5 is what writes this block for real; here it stands in for it,
# and the assertion is the one that matters in both phases: the marked lines go
# and every other byte of the file stays.
pam_probe=/etc/pam.d/omarchy-face-probe
cat >"$pam_probe" <<'PAMPROBE'
#%PAM-1.0
auth		include		system-auth
# omarchy-face begin
auth  [success=1 default=ignore]  pam_exec.so seteuid quiet /usr/local/bin/omarchy-face-gate
auth  sufficient                  pam_exec.so seteuid quiet /usr/local/bin/omarchy-face-verify
# omarchy-face end
account		include		system-auth
session		optional	pam_systemd.so class=none
PAMPROBE
pam_probe_expected=$(grep -v 'omarchy-face' "$pam_probe")

# And a stack with a begin marker and NO end marker. `sed '/begin/,/end/d'`
# would delete from there to the end of the file, which on an auth stack is a
# machine nobody can authenticate to; purge has to leave it alone and say so.
pam_broken=/etc/pam.d/omarchy-face-probe-unterminated
cat >"$pam_broken" <<'PAMBROKEN'
#%PAM-1.0
auth		include		system-auth
# omarchy-face begin
auth  sufficient  pam_exec.so seteuid quiet /usr/local/bin/omarchy-face-verify
account		include		system-auth
session		include		system-auth
PAMBROKEN
pam_broken_before=$(sha256sum "$pam_broken" | cut -d' ' -f1)

echo "  ${DIM}pkexec /usr/local/bin/omarchy-face-admin purge${RESET}"
purge_err=$(mktemp)
purge_out=$(/usr/local/bin/omarchy-face-admin purge 2>"$purge_err")
purge_rc=$?
echo "  ${DIM}exit $purge_rc${RESET}  $purge_out"
[[ -s $purge_err ]] && echo "  ${DIM}stderr:${RESET} $(cat "$purge_err")"
check "purge exited 0" test "$purge_rc" -eq 0
check "stdout is one JSON document" bash -c "jq -e . <<<'$purge_out' >/dev/null"
check "purge reported nothing incomplete but the deliberately broken stack" \
  bash -c "[[ \$(jq -c '.incomplete' <<<'$purge_out') == '[\"$pam_broken\"]' ]]"
check "an unterminated marker leaves the stack byte-identical, not truncated" \
  bash -c "[[ \$(sha256sum '$pam_broken' | cut -d' ' -f1) == '$pam_broken_before' ]]"
check "purge removed the marked block and left every other line untouched" \
  bash -c "[[ \"\$(cat '$pam_probe')\" == \"\$(cat <<'PROBE'
$pam_probe_expected
PROBE
)\" ]]"
rm -f "$pam_probe" "$pam_broken"

step "post-purge checklist (plan-engine.md §10.3)"
check "no helper left in /usr/local/bin" \
  bash -c "for f in omarchy-face-admin omarchy-face-gate omarchy-face-verify omarchy-faced \
                    omarchy-face-identity omarchy-face-lock-verify omarchy-face-camera; do
             [[ ! -e /usr/local/bin/\$f ]] || exit 1; done"
check "no polkit policy" test ! -e /usr/share/polkit-1/actions/no.graveklar.face.policy
check "no units, and the socket is not enabled" \
  bash -c "[[ ! -e /etc/systemd/system/omarchy-faced.socket && ! -e /etc/systemd/system/omarchy-faced.service ]] &&
           ! systemctl is-enabled --quiet omarchy-faced.socket 2>/dev/null"
# The marked block and the helper lines are what `sudo-on` writes and `purge`
# removes. A file NAMED *.omarchy-face.bak is the old install's leaving, which
# `purge-legacy` removes and `purge` deliberately does not touch -- it is not
# ours to delete during a removal that never wrote it.
check "no omarchy-face block or helper line in any PAM stack" \
  bash -c "! grep -rlE '^# omarchy-face begin|omarchy-face-(gate|verify)' /etc/pam.d/ 2>/dev/null | grep -q ."
if compgen -G '/etc/pam.d/*.omarchy-face.bak' >/dev/null; then
  note "a *.omarchy-face.bak file from the old install is still in /etc/pam.d (the legacy row reports it; purge-legacy removes it)"
fi
# /var/lib/omarchy-face-build is the symlink systemd leaves beside a DynamicUser
# unit's StateDirectory (phase 3); `-e` is false for a dangling one, hence `-L`.
check "no state, store or config directory" \
  bash -c "[[ ! -e /run/omarchy-face && ! -e /var/lib/omarchy-face && ! -e /etc/omarchy-face &&
              ! -e /var/lib/private/omarchy-face-build && ! -L /var/lib/omarchy-face-build ]]"
check "no derived model files" no_glob '/usr/lib/security/howdy/models/omarchy-face.*.dat'
check "no snapshot directory left in /run" no_glob '/run/omarchy-face-install.*'
check "howdy and python-dlib are not installed" \
  bash -c "! pacman -Q howdy >/dev/null 2>&1 && ! pacman -Q python-dlib >/dev/null 2>&1"
# The last three items of §10.3 are about the PLUGIN, which `purge` never
# touches: the Remove view's final detached command deletes the folders and asks
# `omarchy plugin remove` to clear shell.json, and that is phase 8's work
# (plan-engine.md §10.2 step 3). They are checked here anyway -- a machine where
# the plugin is gone must pass them -- but on a development machine the plugin
# is installed on purpose, and failing the gate for that would be noise.
SHELL_JSON=/home/$ACCOUNT/.config/omarchy/shell.json
if [[ -e $PLUGINS/graveklar.face || -e $PLUGINS/graveklar.face-lock ]] ||
   compgen -G "$PLUGINS/.graveklar.face*" >/dev/null ||
   grep -q 'graveklar.face' "$SHELL_JSON" 2>/dev/null; then
  note "the plugin is still installed in $PLUGINS and named in shell.json"
  note "  -- removed by the Remove view's final step (phase 8), never by purge"
else
  check "no plugin folder and no .graveklar.face* backup" true
  check "shell.json holds neither plugin id, and omarchy.lock is not disabled" \
    bash -c "[[ ! -f '$SHELL_JSON' ]] ||
             { ! grep -q 'graveklar.face' '$SHELL_JSON' &&
               ! jq -e '.disabledPlugins // [] | index(\"omarchy.lock\")' '$SHELL_JSON' >/dev/null; }"
fi

step "the PAM stacks, before and after the whole round trip"
pam_after=$(find /etc/pam.d -type f -exec sha256sum {} + 2>/dev/null | sort -k2)
if [[ $pam_before == "$pam_after" ]]; then
  checks=$((checks + 1))
  echo "  ${GREEN}pass${RESET}  every file in /etc/pam.d is byte-identical"
else
  checks=$((checks + 1))
  failures=$((failures + 1))
  echo "  ${RED}FAIL${RESET}  /etc/pam.d changed:"
  diff <(printf '%s\n' "$pam_before") <(printf '%s\n' "$pam_after") | sed 's/^/        /'
fi

echo
if ((failures == 0)); then
  echo "${GREEN}F1 gate passes.${RESET} ${DIM}$checks checks.${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
