#!/bin/bash

# G7: the Remove view, in a real QML runtime, against a throwaway plugins folder
# (plan-merged.md §4 phase 8, plan-gui.md §7.1).
#
#   ./dev/g7-remove-offscreen.sh
#
# Two of the phase-8 gate's clauses are GUI-side and both are proved here:
#
#   * Remove on a fully configured machine SHOWS ITS RESULT before the final
#     step's reload closes the popup. The view is asked, at the moment the
#     result appears, whether the plugins folder has been touched yet -- and
#     only then is the popup closed, which is what runs the final step;
#   * closing the popup during `purge` still completes it, and reopening shows
#     `removal` empty. The popup is closed 300 ms into a five-second purge and
#     the run afterwards reads the status helper again.
#
# The final step really runs. FACE_HARNESS_PLUGIN points at a COPY of this
# checkout inside a throwaway plugins folder, with a stand-in `omarchy` ahead of
# the real one on PATH -- the stand-in does what `omarchy-plugin-remove` does to
# a plugin that is not a git checkout (:105-115): it MOVES it to
# `.graveklar.face.bak.<ts>` rather than deleting it, which is the whole reason
# the command has a third `rm -rf` in it. Nothing outside /tmp is written, and
# the plugin this session is running is never touched.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

failures=0
checks=0

check() { # check <description> <expected> <actual>
  checks=$((checks + 1))
  if [[ $2 == "$3" ]]; then
    echo "  ${GREEN}pass${RESET}  $1"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected '$2', got '$3')${RESET}"
    failures=$((failures + 1))
  fi
}

note() { echo "  ${YELLOW}note${RESET}  $*"; }

command -v quickshell >/dev/null || { echo "g7-remove: quickshell is not installed" >&2; exit 1; }
command -v jq >/dev/null || { echo "g7-remove: jq is not installed" >&2; exit 1; }

SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Commons ]] || {
  echo "g7-remove: no Omarchy shell at $SHELL_PATH/shell" >&2
  exit 1
}

root=$(mktemp -d /tmp/omarchy-face-g7.XXXXXX)
trap 'rm -rf "$root"' EXIT

harness=$root/harness
state=$root/state
PLUGINS=$root/plugins
CALLS=$root/calls.log

mkdir -p "$harness" "$state" "$PLUGINS" "$root/bin"
ln -s "$SHELL_PATH/shell/Commons" "$harness/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$harness/Ui"
# The code under test is this checkout, imported as `face`; the folder the final
# step DELETES is the copy below. Keeping them apart is what lets the command run
# for real without removing the files the runtime is reading.
ln -s "$REPO" "$harness/face"
cp "$REPO/dev/qml-harness/remove.qml" "$harness/shell.qml"
cp "$REPO/dev/fixtures/configured/status.json" "$state/status.json"
cp "$REPO/dev/fixtures/configured/people.json" "$state/people.json"

# The stand-in for `omarchy plugin remove`, with the one behaviour that shapes
# the final step: a plugin folder that is not a git checkout is BACKED UP, not
# deleted. It also refuses without --yes, exactly as the real one does with no
# tty (omarchy-plugin-remove:18-30) -- so a final step that dropped the flag
# would fail here instead of passing quietly.
cat >"$root/bin/omarchy" <<STANDIN
#!/bin/bash
printf 'omarchy %s\n' "\$*" >>"$CALLS"
if [[ "\$1 \$2" == "plugin remove" ]]; then
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
  target=$PLUGINS/\$id
  [[ -n \$id ]] || { echo "a plugin-id is required" >&2; exit 1; }
  [[ -e \$target ]] || { echo "plugin '\$id' is not installed" >&2; exit 1; }
  ((yes)) || { echo "refusing to continue without confirmation; pass --yes" >&2; exit 1; }
  if [[ -d \$target/.git ]]; then
    rm -rf "\$target"
  else
    mv "\$target" "$PLUGINS/.\$id.bak.\$(date -u +%Y%m%d%H%M%S)"
  fi
  exit 0
fi
exit 0
STANDIN
chmod 0755 "$root/bin/omarchy"

reset_plugins() {
  rm -rf "$PLUGINS"
  mkdir -p "$PLUGINS"
  # The plugin, as `install.sh` leaves it: a copy, with no .git, so `plugin
  # remove` backs it up instead of deleting it.
  rsync -a --exclude '.git' --exclude 'dev' "$REPO/" "$PLUGINS/graveklar.face/"
  # The staged wrapper, and the two dot-directories a `stage` interrupted half
  # way leaves behind. §10.3 asserts `.graveklar.face*` is empty afterwards, so
  # these are part of what the final step has to clear.
  cp -r "$REPO/lock" "$PLUGINS/graveklar.face-lock"
  mkdir -p "$PLUGINS/.graveklar.face-lock.old.20260101000000" \
           "$PLUGINS/.graveklar.face-lock.abc123"
  : >"$CALLS"
}

run_case() { # run_case <case> [env…]
  local name=$1
  shift
  env FACE_HARNESS_CASE="$name" FACE_HARNESS_PLUGIN="$PLUGINS/graveklar.face" \
    OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_STATE="$state" \
    OMARCHY_FACE_DEV_FIXTURES="$root" OMARCHY_FACE_DEV_FIXTURE="state" \
    PATH="$root/bin:$PATH" "$@" \
    timeout 90 quickshell -p "$harness" -n 2>&1 |
    sed -n 's/^.*HARNESS \([a-zA-Z]*\) \(.*\)$/\1=\2/p'
}

field() { sed -n "s/^$1=//p" <<<"$2" | tail -1; }
verbs() { cat "$state/verbs.log" 2>/dev/null; }

echo "G7 — the Remove view, offscreen (plan-merged.md §4 phase 8)"
echo "${DIM}shell: $SHELL_PATH/shell   plugins folder: $PLUGINS${RESET}"

# The fixture directory is $root/state, so the stub reads the copy above and the
# `purged` marker it drops lands beside it rather than in the checkout.
mkdir -p "$root/state"

echo
echo "${DIM}== what it says it would remove${RESET}"
reset_plugins
rm -f "$state/purged" "$state/verbs.log"
out=$(run_case list)
[[ -n $out ]] || { echo "  ${RED}FAIL${RESET}  the harness printed nothing (QML did not load)"; exit 1; }
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the engine's dry run is rendered, one line per kind of thing" "7" "$(field lines "$out")"
check "…with the people and their faces counted out of removal.people" \
  "3 people and 6 recorded faces / Face's lines in /etc/pam.d/sudo / the lock screen wrapper / 7 helpers in /usr/local/bin / the verification daemon and its socket / the password dialog's policy file / the face engine: howdy, python-dlib" \
  "$(field linesText "$out")"
check "the tick changes the engine line rather than dropping it" "true" \
  "$([[ $(field linesKept "$out") == *"kept: howdy, python-dlib"* ]] && echo true || echo false)"
check "there is something to remove" "false" "$(field nothingLeft "$out")"
check "the button says what it does" "Remove Face Unlock" "$(field actionLabel "$out")"
check "the plugins folder is derived from the plugin's own directory" "$PLUGINS" \
  "$(field pluginsDir "$out")"
check "the final step is one detached command, with --yes in it" "true" \
  "$([[ $(field finalArgv "$out") == '["setsid","-f","bash","-c",'* &&
       $(field finalArgv "$out") == *'plugin remove --yes graveklar.face'* ]] && echo true || echo false)"

echo
echo "${DIM}== GATE: the result is on screen BEFORE anything writes the plugins folder${RESET}"
reset_plugins
rm -f "$state/purged" "$state/verbs.log"
out=$(run_case remove)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the flow ended in its result" "done" "$(field phase "$out")"
check "the lock screen was switched off FIRST, then the system half purged" \
  "lock:disable|purge" "$(verbs | sed 's/ *$//' | paste -sd'|')"
check "the result was shown with the plugins folder still untouched" "present" \
  "$(field cloneAtResult "$out")"
check "…with the final step owed" "true" "$(field armedAtResult "$out")"
check "…and not yet run" "false" "$(field finalRanAtResult "$out")"
check "closing the popup ran it" "true" "$(field finalRan "$out")"
check "the lock screen wrapper is gone" "gone" "$(field cloneAfterClose "$out")"
check "the plugin itself is gone" "gone" "$(field sourceAfterClose "$out")"
check "omarchy plugin remove was asked, with --yes" "1" \
  "$(grep -c 'plugin remove --yes graveklar.face' "$CALLS")"
check "…and the backup it leaves behind was cleared" "" \
  "$(compgen -G "$PLUGINS/.graveklar.face*" | tr '\n' ' ' | sed 's/ *$//')"
check "nothing else is left in the plugins folder" "" \
  "$(ls -A "$PLUGINS" | tr '\n' ' ' | sed 's/ *$//')"

echo
echo "${DIM}== GATE: leaving the view, rather than the popup, still finishes it${RESET}"
# Esc from the Remove view pops back to Settings instead of closing the popup,
# and the view stack's Loader destroys the view. A step that was owed and then
# quietly dropped would leave the system half gone, the plugin on the bar, and
# nothing on screen to say so.
reset_plugins
rm -f "$state/purged" "$state/verbs.log"
out=$(run_case remove-back)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the view was destroyed with the removal finished" "true" "$(field viewGone "$out")"
check "…and the final step ran anyway" "gone" "$(field sourceAfterClose "$out")"
check "…taking the wrapper with it" "gone" "$(field cloneAfterClose "$out")"

echo
echo "${DIM}== the engine can be kept${RESET}"
reset_plugins
rm -f "$state/purged" "$state/verbs.log"
out=$(run_case remove-keep)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "purge was asked to keep the packages" "purge --keep-packages" \
  "$(verbs | sed -n 's/^purge \(.*\) *$/purge \1/p' | tail -1)"
check "the result says so" "done" "$(field phase "$out")"
check "…and nothing was deleted, because the popup was never closed" "present" \
  "$(field cloneAtResult "$out")"

echo
echo "${DIM}== GATE: closing the popup during purge still completes it${RESET}"
reset_plugins
rm -f "$state/purged" "$state/verbs.log"
out=$(run_case remove-close OMARCHY_FACE_DEV_PURGE_SECONDS=5)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the popup was closed in the middle of purge" "true" "$(field closedDuringPurge "$out")"
check "…and purge finished anyway" "done" "$(field phase "$out")"
check "…having been called exactly once" "1" "$(verbs | grep -c '^purge')"
check "the final step was not run behind a closed popup" "false" "$(field finalRan "$out")"
check "…so the plugin is still installed, and the view can finish the job" "present" \
  "$([[ -e $PLUGINS/graveklar.face ]] && echo present || echo gone)"

echo
echo "${DIM}== GATE: reopening shows removal empty${RESET}"
out=$(run_case reopen)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the engine now reports nothing left to remove" "true" "$(field nothingLeft "$out")"
check "…so there are no lines" "0" "$(field lines "$out")"
check "…and the button offers the one step that is left" "Remove the plugin" \
  "$(field actionLabel "$out")"

echo
echo "${DIM}== a purge that left something behind stops before the plugin${RESET}"
reset_plugins
rm -f "$state/purged" "$state/verbs.log"
out=$(run_case remove-incomplete OMARCHY_FACE_DEV_PURGE_INCOMPLETE=/usr/local/bin/omarchy-faced)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the view stops on the incomplete result" "incomplete" "$(field phase "$out")"
check "…listing what is still there" "/usr/local/bin/omarchy-faced" "$(field incomplete "$out")"
check "…offering Try again" "Try again" "$(field actionLabel "$out")"
check "the final step is not armed" "false" "$(field armed "$out")"
check "…so closing the popup removes nothing" "present" "$(field sourceAfterClose "$out")"
check "…not even the wrapper" "present" "$(field cloneAfterClose "$out")"

echo
echo "${DIM}== purge during an engine build: the view says wait${RESET}"
reset_plugins
rm -f "$state/purged" "$state/verbs.log"
systemctl --user reset-failed omarchy-face-dev-build.service >/dev/null 2>&1
systemd-run --user --unit=omarchy-face-dev-build --collect --quiet --property=Type=exec \
  /usr/bin/sleep 20 >/dev/null 2>&1
if systemctl --user is-active --quiet omarchy-face-dev-build.service; then
  out=$(run_case remove-busy)
  echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
  check "the flow stopped" "stopped" "$(field phase "$out")"
  check "…saying what to wait for" "Wait for the engine build to finish, then try again." \
    "$(field note "$out")"
  check "nothing was removed" "present" "$(field sourceAfterClose "$out")"
  systemctl --user stop omarchy-face-dev-build.service >/dev/null 2>&1
else
  note "could not start the stand-in build unit; the exit-3 path is covered by dev/f7-purge.sh"
fi

echo
echo "${DIM}== a lock screen that will not switch off stops the removal${RESET}"
reset_plugins
rm -f "$state/purged" "$state/verbs.log"
out=$(run_case remove-locked FACE_HARNESS_LOCK_ENABLED=1 OMARCHY_FACE_DEV_LOCK_ERROR=locked)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the flow stopped at step 1" "stopped" "$(field phase "$out")"
check "…before asking for a password" "" "$(verbs | grep '^purge' | paste -sd'|')"
check "…and said what is in the way" \
  "Nothing is changed behind a lock screen — unlock the session and try again." \
  "$(field note "$out")"

echo
echo "${DIM}== a clone that was never enabled does not block one${RESET}"
reset_plugins
rm -f "$state/purged" "$state/verbs.log"
out=$(run_case remove-unstaged OMARCHY_FACE_DEV_LOCK_ERROR=not_staged)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the removal went ahead" "done" "$(field phase "$out")"
check "…and purge was asked" "1" "$(verbs | grep -c '^purge')"

echo
echo "${DIM}== a refused purge is a stop, not a half-removal${RESET}"
reset_plugins
rm -f "$state/purged" "$state/verbs.log"
out=$(run_case remove-error OMARCHY_FACE_DEV_PURGE_ERROR=not_owner)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the flow stopped" "stopped" "$(field phase "$out")"
check "…in words" "Face is set up for another account on this machine." "$(field note "$out")"
check "…and the plugin is still here" "present" "$(field sourceAfterClose "$out")"

echo
if ((failures == 0)); then
  echo "${GREEN}$checks checks, all passed${RESET}"
else
  echo "${RED}$checks checks, $failures failed${RESET}"
fi
exit $((failures > 0))
