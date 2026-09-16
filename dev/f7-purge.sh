#!/bin/bash

# F7: the removal, end to end — `purge`'s order and refusals, and the one
# detached command that finishes the job (plan-merged.md §4 phase 8,
# plan-engine.md §10.2, §10.3).
#
#   ./dev/f7-purge.sh            in a private user namespace (the default)
#   sudo ./dev/f7-purge.sh --here    on this machine, for real
#
# `dev/f1-round-trip.sh` already runs install → purge → the §10.3 checklist, and
# this suite does not repeat it for its own sake. What it adds is everything
# phase 8 is actually about:
#
#   * `purge` while the engine build is running exits 3 and removes NOTHING --
#     it will not delete /var/lib from under a compile;
#   * `purge` on a machine it has already been through exits 0 with nothing
#     incomplete, because every step tolerates its target being absent;
#   * the last three items of §10.3 -- the plugin folders, the
#     `.graveklar.face*` backups and `shell.json` -- which `purge` never
#     touches. They belong to the Remove view's final step, and that step is
#     read out of RemoveView.qml itself, so a change to the view that is not a
#     change to this test cannot pass;
#   * that the final step really is detached: its launcher is SIGKILLed with its
#     whole process group mid-flight, the way a plugins-folder reload kills the
#     `Process` children of the popup it destroys, and the work still finishes.
#
# The sandbox is the one `f1-round-trip.sh` documents: `unshare --map-root-user
# --mount` with tmpfs over /etc, /run, /usr/local and polkit's actions
# directory. The throwaway plugins folder is under /tmp either way -- this suite
# never touches ~/.config/omarchy/plugins, whose every write reloads every bar
# widget in the shell.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ACCOUNT=${SUDO_USER:-${USER:-$(id -un)}}

failures=0
checks=0

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

same() { # same <description> <expected> <actual>
  checks=$((checks + 1))
  if [[ $2 == "$3" ]]; then
    echo "  ${GREEN}pass${RESET}  $1"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected '$2', got '$3')${RESET}"
    failures=$((failures + 1))
  fi
}

note() { echo "  ${YELLOW}note${RESET}  $*"; }
step() { echo; echo "${DIM}== $*${RESET}"; }
no_glob() { ! compgen -G "$1" >/dev/null; }

# --- the sandbox -------------------------------------------------------------

if [[ ${1:-} != --here && ${OMARCHY_FACE_F7_IN_NS:-0} != 1 ]]; then
  command -v unshare >/dev/null || { echo "unshare is not installed; use --here" >&2; exit 1; }
  exec env OMARCHY_FACE_F7_IN_NS=1 OMARCHY_FACE_F7_ACCOUNT="$ACCOUNT" \
    unshare --map-root-user --mount --pid --fork "$BASH" "$0" --sandboxed
fi

if [[ ${OMARCHY_FACE_F7_IN_NS:-0} == 1 ]]; then
  ACCOUNT=${OMARCHY_FACE_F7_ACCOUNT:-$ACCOUNT}
  mount --bind /etc /mnt || exit 1
  mount -t tmpfs tmpfs /etc || exit 1
  chmod 0755 /etc
  for real in /mnt/*; do ln -s "$real" "/etc/${real#/mnt/}"; done
  rm -f /etc/pam.d
  cp -rp /mnt/pam.d /etc/pam.d 2>/dev/null
  chown -R root:root /etc/pam.d
  rm -f /etc/systemd
  mkdir /etc/systemd
  for real in /mnt/systemd/*; do ln -s "$real" "/etc/systemd/${real#/mnt/systemd/}"; done
  rm -f /etc/systemd/system
  cp -rp /mnt/systemd/system /etc/systemd/system 2>/dev/null
  chown -R root:root /etc/systemd/system
  mount -t tmpfs tmpfs /run || exit 1
  chmod 0755 /run
  mount -t tmpfs tmpfs /usr/local || exit 1
  chmod 0755 /usr/local
  mkdir -p /usr/local/bin
  chmod 0755 /usr/local/bin
  mount -t tmpfs tmpfs /usr/share/polkit-1/actions || exit 1
  chmod 0755 /usr/share/polkit-1/actions
  # /var/lib and /usr/lib/security, so `purge` has a store and derived model
  # files to delete. Both are root-owned outside the namespace, where a mapped
  # uid 0 is still this account -- so they have to be tmpfs, not directories we
  # ask to write into. pacman's database is linked back in: without it
  # `pacman -Q howdy` cannot answer, and the package step would look clean on a
  # machine where howdy is installed.
  mkdir -p /run/host-var-lib
  mount --bind /var/lib /run/host-var-lib || exit 1
  mount -t tmpfs tmpfs /var/lib || exit 1
  chmod 0755 /var/lib
  ln -s /run/host-var-lib/pacman /var/lib/pacman
  mount -t tmpfs tmpfs /usr/lib/security || exit 1
  chmod 0755 /usr/lib/security
  echo "${DIM}sandbox: uid $(id -u); /etc /run /usr/local /var/lib /usr/lib/security and polkit actions are private to this run${RESET}"
fi

[[ $EUID -eq 0 ]] || { echo "f7-purge: needs to be root (use --here under sudo, or drop the flag)" >&2; exit 1; }

echo "F7 — removal (plan-merged.md §4 phase 8)"
echo "${DIM}plugin: $REPO   account: $ACCOUNT${RESET}"

pam_before=$(find /etc/pam.d -type f -exec sha256sum {} + 2>/dev/null | sort -k2)
[[ -n $pam_before ]] || { echo "could not read /etc/pam.d" >&2; exit 1; }

pam_now() { find /etc/pam.d -type f -exec sha256sum {} + 2>/dev/null | sort -k2; }

# --- install, so there is something to remove --------------------------------

step "install (the form the GUI uses, plan-engine.md §5.1)"
install_out=$(/bin/bash -c "$(cat "$REPO/system/install.sh")" omarchy-face-install "$REPO" "$ACCOUNT" 2>/dev/null)
echo "  ${DIM}$install_out${RESET}"
check "the install exited 0 and left the admin helper" test -x /usr/local/bin/omarchy-face-admin
# A marked block in one stack, so purge's PAM step has something to remove and
# the byte-identity assertion has something to be about.
pam_sudo=/etc/pam.d/omarchy-face-f7
cat >"$pam_sudo" <<'STACK'
#%PAM-1.0
auth		include		system-auth
# omarchy-face begin
auth  [success=1 default=ignore]  pam_exec.so seteuid quiet /usr/local/bin/omarchy-face-gate
auth  sufficient                  pam_exec.so seteuid quiet /usr/local/bin/omarchy-face-verify
# omarchy-face end
account		include		system-auth
STACK
pam_sudo_expected=$(grep -v 'omarchy-face' "$pam_sudo")
# Derived model files and a store, so the middle steps of §10.2 have targets.
install -d -o root -g root -m 0755 /usr/lib/security/howdy/models
: >/usr/lib/security/howdy/models/omarchy-face.anna.no-glasses.dat
install -d -o root -g root -m 0755 /var/lib/omarchy-face
printf '{"people":[]}\n' >/var/lib/omarchy-face/people.json
printf '{"howdy":"2.6.1-3"}\n' >/var/lib/omarchy-face/engine.json
check "the sandbox has a store and a derived model file to remove" \
  bash -c "[[ -e /var/lib/omarchy-face/people.json &&
              -e /usr/lib/security/howdy/models/omarchy-face.anna.no-glasses.dat ]]"

# Two snapshots, because they answer two different questions: this one is
# "did the refused purge below touch anything", and `pam_before` above is
# "is /etc/pam.d what it was before Face was ever installed".
pam_with_block=$(pam_now)

# --- GATE: purge during a build exits 3 --------------------------------------

step "GATE: purge while the engine is building exits 3 (plan-merged.md §2.3)"
# The helper pins PATH=/usr/local/bin:/usr/bin, so a file of this name in
# /usr/local/bin is the systemctl it finds. It answers "the install unit is
# active" and records everything it was asked, which is how "and it removed
# nothing" is checked rather than assumed.
cat >/usr/local/bin/systemctl <<'STUB'
#!/bin/bash
printf '%s\n' "systemctl $*" >>/run/f7-systemctl.log
[[ $* == *is-active*omarchy-face-install* ]] && exit 0
exit 0
STUB
chmod 0755 /usr/local/bin/systemctl
: >/run/f7-systemctl.log

busy_out=$(/usr/local/bin/omarchy-face-admin purge 2>/dev/null)
busy_rc=$?
echo "  ${DIM}exit $busy_rc${RESET}  $busy_out"
same "purge exits 3" "3" "$busy_rc"
same "…with install_running" "install_running" "$(jq -r '.error' <<<"$busy_out" 2>/dev/null)"
check "it asked systemd about the install unit first" \
  grep -q 'is-active --quiet omarchy-face-install.service' /run/f7-systemctl.log
check "…and did nothing else to systemd" \
  bash -c "[[ \$(grep -c . /run/f7-systemctl.log) == 1 ]]"
check "every helper is still installed" \
  bash -c "for f in omarchy-face-admin omarchy-face-gate omarchy-face-verify omarchy-faced \
                    omarchy-face-identity omarchy-face-lock-verify omarchy-face-camera; do
             [[ -e /usr/local/bin/\$f ]] || exit 1; done"
check "the policy, the units and the config are still there" \
  bash -c "[[ -e /usr/share/polkit-1/actions/no.graveklar.face.policy &&
              -e /etc/systemd/system/omarchy-faced.socket &&
              -e /etc/omarchy-face/config ]]"
check "the store and the model files are still there" \
  bash -c "[[ -e /var/lib/omarchy-face/people.json &&
              -e /usr/lib/security/howdy/models/omarchy-face.anna.no-glasses.dat ]]"
same "…and no PAM stack was touched" "$pam_with_block" "$(pam_now)"
rm -f /usr/local/bin/systemctl

# --- GATE: purge, and §10.3 --------------------------------------------------

step "purge (plan-engine.md §10.2 step 2)"
purge_out=$(/usr/local/bin/omarchy-face-admin purge 2>/dev/null)
purge_rc=$?
echo "  ${DIM}exit $purge_rc${RESET}  $purge_out"
same "purge exits 0" "0" "$purge_rc"
same "nothing incomplete" "[]" "$(jq -c '.incomplete' <<<"$purge_out" 2>/dev/null)"
same "the marked block went and every other line stayed" "$pam_sudo_expected" "$(cat "$pam_sudo")"
rm -f "$pam_sudo"

step "GATE: the post-purge checklist (plan-engine.md §10.3)"
check "no helper left in /usr/local/bin" \
  bash -c "for f in omarchy-face-admin omarchy-face-gate omarchy-face-verify omarchy-faced \
                    omarchy-face-identity omarchy-face-lock-verify omarchy-face-camera; do
             [[ ! -e /usr/local/bin/\$f ]] || exit 1; done"
check "no polkit policy" test ! -e /usr/share/polkit-1/actions/no.graveklar.face.policy
check "no units, and the socket is not enabled" \
  bash -c "[[ ! -e /etc/systemd/system/omarchy-faced.socket && ! -e /etc/systemd/system/omarchy-faced.service ]] &&
           ! systemctl is-enabled --quiet omarchy-faced.socket 2>/dev/null"
check "no omarchy-face block or helper line in any PAM stack" \
  bash -c "! grep -rlE '^# omarchy-face begin|omarchy-face-(gate|verify)' /etc/pam.d/ 2>/dev/null | grep -q ."
check "no state, store, config or build directory" \
  bash -c "[[ ! -e /run/omarchy-face && ! -e /var/lib/omarchy-face && ! -e /etc/omarchy-face &&
              ! -e /var/lib/private/omarchy-face-build && ! -L /var/lib/omarchy-face-build ]]"
check "no derived model files" no_glob '/usr/lib/security/howdy/models/omarchy-face.*.dat'
check "no snapshot directory left in /run" no_glob '/run/omarchy-face-install.*'
check "howdy and python-dlib are not installed" \
  bash -c "! pacman -Q howdy >/dev/null 2>&1 && ! pacman -Q python-dlib >/dev/null 2>&1"
same "every file in /etc/pam.d is byte-identical to before the install" "$pam_before" "$(pam_now)"

step "purge again: every step tolerates its target being absent"
# The admin helper deletes itself last, so a second purge has to be run from the
# plugin's own copy -- which is also the one case a half-installed machine has:
# a `purge` that starts with nothing of Face on the machine at all.
again_out=$("$REPO/system/omarchy-face-admin" purge 2>/dev/null)
again_rc=$?
echo "  ${DIM}exit $again_rc${RESET}  $again_out"
same "a purge with nothing to purge exits 0" "0" "$again_rc"
same "…with nothing incomplete" "[]" "$(jq -c '.incomplete' <<<"$again_out" 2>/dev/null)"
same "…and still nothing in /etc/pam.d was touched" "$pam_before" "$(pam_now)"

# --- the final step, read out of the view ------------------------------------

step "GATE: the final step, as RemoveView.qml writes it (plan-engine.md §10.2 step 3)"

# The script the view runs, extracted from the view. A single-quoted string per
# line, concatenated with `+`, each ending in an escaped newline.
final_script=$(sed -n "/readonly property string finalScript:/,/^$/p" "$REPO/RemoveView.qml" |
  sed -n "s/^[[:space:]]*'\(.*\)'[[:space:]]*+*[[:space:]]*$/\1/p" |
  sed 's/\\n$//')
echo "${DIM}$(sed 's/^/    /' <<<"$final_script")${RESET}"
check "four commands, and it came out of the view" \
  bash -c "[[ \$(grep -c . <<<'$final_script') == 4 ]]"
check "Face's two Omarchy hooks go first, by argument rather than by text in the script" \
  bash -c "head -1 <<<'$final_script' | grep -qxF 'rm -f -- \"\$3\" \"\$4\"'"
check "the plugin is removed with --yes (no tty here, omarchy-plugin-remove:18-30)" \
  bash -c "grep -q 'omarchy plugin remove --yes graveklar.face' <<<'$final_script'"

root=$(mktemp -d /tmp/omarchy-face-f7.XXXXXX)
PLUGINS=$root/plugins
# The hooks folder beside it, as RemoveView.qml derives it (`hooksDir`).
HOOKS=$root/hooks
HOOK_ARGS=("$HOOKS/post-update.d/graveklar-face.hook" "$HOOKS/post-boot.d/graveklar-face.hook")
CALLS=$root/calls.log
SHELL_JSON=$root/config/omarchy/shell.json
mkdir -p "$PLUGINS" "$root/bin" "$root/config/omarchy"

# `shell.json` as it stands with face on the lock screen: the clone in plugins[]
# and Omarchy's own lock put aside in disabledPlugins[] (PluginRegistry.qml:540-555).
cat >"$SHELL_JSON" <<'JSON'
{"plugins":[{"id":"graveklar.face"},{"id":"graveklar.face-lock"}],
 "disabledPlugins":["omarchy.lock"]}
JSON

# The stand-ins. `omarchy plugin remove` BACKS UP a plugin folder that is not a
# git checkout rather than deleting it (omarchy-plugin-remove:105-115), and it
# refuses without --yes when it has no tty -- both of which the final step is
# shaped by, so both are here. The sleep is what the SIGKILL below has to arrive
# in the middle of.
cat >"$root/bin/omarchy" <<STANDIN
#!/bin/bash
printf 'omarchy %s\n' "\$*" >>"$CALLS"
case "\$1 \$2" in
  "plugin disable")
    jq --arg id "\$3" '.plugins = [(.plugins // [])[] | select(.id != \$id)]
                       | .disabledPlugins = [((.disabledPlugins // [])[]) | select(. != "omarchy.lock")]' \
      "$SHELL_JSON" >"$SHELL_JSON.tmp" && mv "$SHELL_JSON.tmp" "$SHELL_JSON"
    exit 0 ;;
  "plugin remove")
    id=""
    yes=0
    shift 2
    for arg in "\$@"; do
      case \$arg in
        --yes | -y) yes=1 ;;
        -*) ;;
        *) id=\$arg ;;
      esac
    done
    [[ -n \$id ]] || { echo "a plugin-id is required" >&2; exit 1; }
    [[ -e $PLUGINS/\$id ]] || { echo "plugin '\$id' is not installed" >&2; exit 1; }
    ((yes)) || { echo "refusing to continue without confirmation; pass --yes" >&2; exit 1; }
    sleep "\${F7_REMOVE_DELAY:-0}"
    if [[ -d $PLUGINS/\$id/.git ]]; then
      rm -rf "$PLUGINS/\$id"
    else
      mv "$PLUGINS/\$id" "$PLUGINS/.\$id.bak.\$(date -u +%Y%m%d%H%M%S)"
    fi
    jq --arg id "\$id" '.plugins = [(.plugins // [])[] | select(.id != \$id)]' \
      "$SHELL_JSON" >"$SHELL_JSON.tmp" && mv "$SHELL_JSON.tmp" "$SHELL_JSON"
    exit 0 ;;
esac
exit 0
STANDIN
chmod 0755 "$root/bin/omarchy"

seed_plugins() {
  rm -rf "$PLUGINS"
  mkdir -p "$PLUGINS/graveklar.face" "$PLUGINS/graveklar.face-lock"
  cp "$REPO/manifest.json" "$PLUGINS/graveklar.face/"
  # Staged, so it is a manifest.json here even though the template calls it
  # manifest.json.in (see TEMPLATE_MANIFEST in bin/omarchy-face-lock).
  cp "$REPO/lock/manifest.json.in" "$PLUGINS/graveklar.face-lock/manifest.json"
  # The dot-directories a `stage` interrupted half way leaves behind. §10.3
  # asserts the whole `.graveklar.face*` glob is empty afterwards, which is
  # wider than the `.bak` §10.2 names -- so the view's last `rm -rf` is wider too.
  mkdir -p "$PLUGINS/.graveklar.face-lock.old.20260101000000" \
           "$PLUGINS/.graveklar.face-lock.Ab3De9" \
           "$PLUGINS/.graveklar.face.bak.20260101000000"
  # The two hooks bin/omarchy-face-health install-hooks writes.
  mkdir -p "$HOOKS/post-update.d" "$HOOKS/post-boot.d"
  : >"${HOOK_ARGS[0]}"
  : >"${HOOK_ARGS[1]}"
  : >"$CALLS"
}

# Step 1 of the flow, for shell.json's sake: the lock screen goes back to
# Omarchy's own before anything is deleted.
seed_plugins
PATH="$root/bin:$PATH" omarchy plugin disable graveklar.face-lock >/dev/null 2>&1

# The final step, launched the way the popup launches it and then orphaned. The
# launcher is its own session leader, so SIGKILLing its whole process group is
# exactly what a plugins-folder reload does to the `Process` children of the
# popup it destroys -- and `setsid -f` is what the work has to survive it with.
printf '%s\n' "$final_script" >"$root/final.sh"
cat >"$root/launcher.sh" <<LAUNCH
#!/bin/bash
echo \$\$ >"$root/launcher.pid"
setsid -f bash -c "\$(cat '$root/final.sh')" _ "$PLUGINS/graveklar.face-lock" "$PLUGINS" "${HOOK_ARGS[0]}" "${HOOK_ARGS[1]}"
sleep 60
LAUNCH
chmod 0755 "$root/launcher.sh"

F7_REMOVE_DELAY=2 PATH="$root/bin:$PATH" setsid "$root/launcher.sh" >/dev/null 2>&1 &
launcher_job=$!
for _ in $(seq 1 40); do [[ -s $root/launcher.pid ]] && break; sleep 0.05; done
launcher_pid=$(cat "$root/launcher.pid" 2>/dev/null)
sleep 0.3
if [[ $launcher_pid =~ ^[0-9]+$ ]]; then
  kill -KILL -- "-$launcher_pid" 2>/dev/null
  # Reaped first: a SIGKILLed child of this script is a zombie until it is
  # waited for, and a zombie still answers `kill -0`.
  wait "$launcher_job" 2>/dev/null
  same "the launcher is gone, killed with its whole process group" "gone" \
    "$(kill -0 "$launcher_pid" 2>/dev/null && echo alive || echo gone)"
else
  note "could not read the launcher's pid; the detachment check is not conclusive"
  wait "$launcher_job" 2>/dev/null
fi

# The work was still in `plugin remove`'s two-second sleep when the group died.
for _ in $(seq 1 60); do
  [[ -e $PLUGINS/graveklar.face ]] || break
  sleep 0.25
done
sleep 0.5

check "the detached command finished after its launcher was killed" \
  bash -c "grep -q 'plugin remove --yes graveklar.face' '$CALLS'"
check "the lock screen wrapper folder is gone" test ! -e "$PLUGINS/graveklar.face-lock"
check "both of Face's Omarchy hooks are gone" \
  bash -c "[[ ! -e '${HOOK_ARGS[0]}' && ! -e '${HOOK_ARGS[1]}' ]]"
check "the plugin folder is gone" test ! -e "$PLUGINS/graveklar.face"
check "no .graveklar.face* backup or staging directory is left" \
  bash -c "! compgen -G '$PLUGINS/.graveklar.face*' >/dev/null"
check "nothing at all is left in the plugins folder" \
  bash -c "[[ -z \$(ls -A '$PLUGINS') ]]"
check "shell.json holds neither plugin id" \
  bash -c "! grep -q 'graveklar.face' '$SHELL_JSON'"
check "…and omarchy.lock is not in disabledPlugins" \
  bash -c "! jq -e '.disabledPlugins // [] | index(\"omarchy.lock\")' '$SHELL_JSON' >/dev/null"

step "the same command on a git checkout, which leaves no backup"
seed_plugins
rm -rf "$PLUGINS/.graveklar.face.bak.20260101000000"
mkdir -p "$PLUGINS/graveklar.face/.git"
PATH="$root/bin:$PATH" bash -c "$final_script" _ "$PLUGINS/graveklar.face-lock" "$PLUGINS" "${HOOK_ARGS[@]}"
check "a git checkout is deleted rather than backed up" test ! -e "$PLUGINS/graveklar.face"
check "…and the wider glob still cleared the staging directories" \
  bash -c "! compgen -G '$PLUGINS/.graveklar.face*' >/dev/null"

step "the same command with nothing there: no output, no failure"
seed_plugins
rm -rf "$PLUGINS"
mkdir -p "$PLUGINS"
out=$(PATH="$root/bin:$PATH" bash -c "$final_script" _ "$PLUGINS/graveklar.face-lock" "$PLUGINS" "${HOOK_ARGS[@]}" 2>&1)
same "an already-removed plugin leaves the command with nothing to say on stdout" "" \
  "$(grep -v 'is not installed' <<<"$out")"

rm -rf "$root"

echo
if ((failures == 0)); then
  echo "${GREEN}F7 gate passes.${RESET} ${DIM}$checks checks.${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
