#!/bin/bash

# G6 / F6: the lock-screen wrapper and its two views, in a real Quickshell
# runtime with no lock screen and no camera.
#
#   ./dev/g6-lock-offscreen.sh
#
# THIS IS THE SUITE THAT MUST NOT TOUCH THE SESSION IT RUNS IN. Phase 7's
# failure mode is a live desktop stranded behind a lock screen nobody can
# answer, so everything here happens in a throwaway Quickshell instance at a
# temporary config directory, and nothing in it ever calls `beginLock()` on a
# real lock service, enables the clone, or writes ~/.config/omarchy/plugins.
# It refuses to start while the compositor holds a session lock.
#
# Two halves:
#
#   the composition   the SHIPPED lock/Service.qml loading the REAL
#                     /usr/share/omarchy/shell/plugins/lock/Service.qml. This is
#                     E1's first run against the real thing -- the evidence so
#                     far was a synthetic stock that imported no qs.Commons, no
#                     PamContext and no WlSessionLock. A scratch copy with one
#                     public name renamed proves the wrapper notices, and a path
#                     that does not exist proves the Loader error is `failed`.
#
#   the wake rule     the same shipped wrapper against a stand-in stock
#                     (dev/qml-harness/fake-lock-service.qml), because no part of
#                     plan-merged.md §3 can be exercised against the real one
#                     without locking this session. The monitor poll and the face
#                     check are stand-in commands, so a whole lock's worth of
#                     wakes takes ten seconds and no infrared emitter.
#
# What it cannot prove, and what needs a person at a locked screen: that Omarchy
# blanks after 5 s, that a key press really flips `dpmsStatus`, that lid close →
# suspend → open produces either transition, and that `finishUnlock()` on the
# REAL stock lock opens the screen. dev/README.md lists those under the live
# gate.

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
step() { echo; echo "${DIM}== $*${RESET}"; }

command -v quickshell >/dev/null || { echo "g6-offscreen: quickshell is not installed" >&2; exit 1; }

# The one refusal that matters. Creating a second stock lock instance while the
# compositor holds a lock this shell did not take is exactly the state the stock
# lock's own checkStrandedLock acts on (plugins/lock/Service.qml:82-100) -- it
# would take the session lock from a throwaway process.
if command -v omarchy-hyprland-session-locked >/dev/null && omarchy-hyprland-session-locked; then
  echo "g6-offscreen: refusing to run while the session is locked" >&2
  exit 1
fi

SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
STOCK=$SHELL_PATH/shell/plugins/lock
[[ -f $STOCK/Service.qml ]] || {
  echo "g6-offscreen: no Omarchy lock screen at $STOCK" >&2
  exit 1
}

root=$(mktemp -d /tmp/omarchy-face-g6.XXXXXX)
state=$root/state
status=$root/status
trap 'rm -rf "$root"' EXIT
mkdir -p "$state" "$status" "$root/bin"
ln -s "$SHELL_PATH/shell/Commons" "$root/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$root/Ui"
ln -s "$REPO" "$root/face"
cp "$REPO/dev/fixtures/three-people/people.json" "$state/people.json"

# A stand-in Omarchy whose lock screen is the fake one, so the wake rule can be
# driven without a session lock.
mkdir -p "$root/fake/shell/plugins/lock"
cp "$REPO/dev/qml-harness/fake-lock-service.qml" "$root/fake/shell/plugins/lock/Service.qml"

# A scratch copy of the REAL lock screen with one of the five public names taken
# out of it. Renamed everywhere, so the file still compiles and still locks --
# what changes is only whether the wrapper can find what it depends on.
mkdir -p "$root/scratch/shell/plugins/lock"
cp "$STOCK"/*.qml "$STOCK/manifest.json" "$root/scratch/shell/plugins/lock/"
sed -i 's/pendingSessionLock/pendingSessionLockRenamed/g' "$root/scratch/shell/plugins/lock/Service.qml"

# The stand-in for polkit's dialog, so a DECLINED prompt can be tested: pkexec is
# what the GUI puts in argv[0], and 126 from it is what `common/Ask.qml` reads as
# `owner_declined` (plan-merged.md §1 row 2).
cat >"$root/bin/pkexec" <<'STANDIN'
#!/bin/bash
[[ ${FACE_HARNESS_DECLINE:-} == 1 ]] && exit 126
exec "$@"
STANDIN
chmod +x "$root/bin/pkexec"

# Unique to this run: a real Hyprland event with this name reaches the harness's
# wrapper and nothing else, because the wrapper this session runs listens for
# `omarchy-face-enter`.
ENTER_EVENT=omarchy-face-enter-g6-$$

run_lock() { # run_lock <case> <omarchy path> [env…]
  local name=$1 omarchy=$2
  shift 2
  cp "$REPO/dev/qml-harness/lock.qml" "$root/shell.qml"
  rm -f "$status/eval.log"
  env FACE_HARNESS_CASE="$name" FACE_HARNESS_OMARCHY="$omarchy" \
    FACE_HARNESS_STATUS="$status" FACE_HARNESS_EVENT="$ENTER_EVENT" "$@" \
    timeout 90 quickshell -p "$root" -n 2>&1 |
    sed -n 's/^.*HARNESS \([a-zA-Z]*\) \(.*\)$/\1=\2/p'
}

run_view() { # run_view <case> [env…]
  local name=$1
  shift
  cp "$REPO/dev/qml-harness/lock-views.qml" "$root/shell.qml"
  env FACE_HARNESS_CASE="$name" FACE_HARNESS_PLUGIN="$REPO" \
    OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_STATE="$state" \
    OMARCHY_FACE_DEV_FIXTURE=three-people PATH="$root/bin:$PATH" "$@" \
    timeout 60 quickshell -p "$root" -n 2>&1 |
    sed -n 's/^.*HARNESS \([a-zA-Z]*\) \(.*\)$/\1=\2/p'
}

field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }
evals() { tr -s ' \n' ' ' <"$status/eval.log" 2>/dev/null | sed 's/ *$//'; }

echo "G6 — the lock screen wrapper, offscreen"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO${RESET}"

# =============================================================================
# The wrapper holds no Omarchy code (plan-engine.md §9.1)
# =============================================================================

step "the wrapper is a composition, not a copy"

check "the template is two files and nothing else" "Service.qml manifest.json.in" \
  "$(cd "$REPO/lock" && ls | sort -r | tr '\n' ' ' | sed 's/ $//')"

# The comments in that file say the words `PamContext`, `IpcHandler` and
# `omarchy-lock-face` out loud, because each is a thing it deliberately does not
# do. So the code is what is searched: comment lines out first.
code() { grep -v '^[[:space:]]*//' "$REPO/lock/Service.qml"; }

check "it runs no PAM stack of its own" "0" "$(code | grep -c 'PamContext')"
check "…takes no session lock of its own" "0" "$(code | grep -c 'WlSessionLock')"
check "…and offers nothing over IPC" "0" "$(code | grep -c 'IpcHandler')"
check "…and never names a PAM service" "0" "$(code | grep -c 'pam\.d\|omarchy-lock-face')"
# The old, deleted version of this plugin ran its own PAM stack on the lock
# screen. The only thing left that names it is the code that DELETES it, so the
# assertion is that every mention is a removal.
check "the only mention of the old lock PAM file is the code that removes it" "0" \
  "$(grep -rn 'pam\.d/omarchy-lock-face' "$REPO/system" 2>/dev/null |
     grep -cv 'rm -f\|removed+=')"
check "it loads Omarchy's own lock service by absolute URL" "1" \
  "$(code | grep -c 'shell/plugins/lock/Service.qml')"
check "no symlink inside the template (omarchy-plugin-validate:111-116)" "" \
  "$(find "$REPO/lock" -type l -print -quit)"
if command -v omarchy >/dev/null; then
  # Validated as `stage` would leave it, not as it sits in the repo: the
  # template's manifest is `manifest.json.in` there and becomes `manifest.json`
  # on the way in (TEMPLATE_MANIFEST in bin/omarchy-face-lock), because a
  # marketplace repository may hold exactly one plugin and a second
  # manifest.json under lock/ made this one look like two.
  staged_probe=$(mktemp -d /tmp/omarchy-face-g6-stage.XXXXXX)
  cp -a "$REPO/lock/." "$staged_probe/"
  mv -T "$staged_probe/manifest.json.in" "$staged_probe/manifest.json"
  omarchy plugin validate "$staged_probe" >/dev/null 2>&1
  check "Omarchy's own plugin validation passes on the staged copy" "0" "$?"
  rm -rf "$staged_probe"
fi

# =============================================================================
# The composition, against the lock screen this machine is running
# =============================================================================

step "GATE: the shipped wrapper composed with the REAL Omarchy lock screen"
rm -f "$status/lock-status.json"
out=$(run_lock compose "$SHELL_PATH")
[[ -n $out ]] || { echo "  ${RED}FAIL${RESET}  the harness printed nothing (QML did not load)"; exit 1; }
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "Omarchy's lock service loaded inside the wrapper" "true" "$(field stockLoaded "$out")"
check "…and every public name the wrapper depends on is there (E3)" \
  "lockRequested,pendingSessionLock,locked,authenticatingPassword,finishUnlock()" \
  "$(field names "$out")"
check "…so the composition fits" "ok" "$(field compat "$out")"
check "…with nothing missing" "" "$(field missing "$out")"
check "the wrapper wrote its verdict where the Face service reads it" "ok" \
  "$(jq -r '.compat' "$status/lock-status.json" 2>/dev/null)"
check "…stamped with a time, which is the whole staleness rule" "true" \
  "$(jq -e '.at > 0' "$status/lock-status.json" >/dev/null 2>&1 && echo true || echo false)"
check "…and nothing was locked to find out" "false" \
  "$(field locked "$out")"

step "GATE (F6 test 4): Omarchy renames one of the five names"
out=$(run_lock incompatible "$root/scratch")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the stock lock still loaded and still runs" "true" "$(field stockLoaded "$out")"
check "…but face turns itself off" "incompatible" "$(field compat "$out")"
check "…and says exactly which name went" "pendingSessionLock" "$(field missing "$out")"

step "the lock screen file moved or will not load"
out=$(run_lock failed "$root/nowhere")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "there is no stock instance at all" "false" "$(field stockLoaded "$out")"
check "…which is 'failed', and reads to everything outside as no answer" "failed" \
  "$(field compat "$out")"

# =============================================================================
# The wake rule (plan-merged.md §3)
# =============================================================================

step "GATE: lock by hand and sit still — face never looks"
out=$(run_lock wake-quiet "$root/fake")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the screen never blanked, so nothing woke" "0" "$(field wakes "$out")"
check "…so no face was ever checked" "0" "$(field attempts "$out")"
check "…and it is still locked" "true" "$(field locked "$out")"
note "this is also 'press a key within 5 s': a key press with the display already lit"
note "leaves dpmsStatus true, so there is no transition for the poll to see"

step "GATE: lock, wait for the blank, press a key"
out=$(run_lock wake-blank "$root/fake")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the wake was seen" "1" "$(field wakes "$out")"
check "…one check ran" "1" "$(field attempts "$out")"
check "…it opened the lock" "unlocked" "$(field outcome "$out")"
check "…exactly once" "1" "$(field unlocks "$out")"
check "…and the lock is over" "false" "$(field locked "$out")"
# The only record that a lock was opened by a face. It is written with `logger`,
# unprivileged, so anything running as this account could forge it -- which is
# exactly why the README says lock-screen attribution is weaker than sudo's
# (plan-merged.md §5 risk 5). It still has to be there.
if journalctl --user -b --since "-2 min" -t omarchy-face -o cat >/dev/null 2>&1; then
  check "…and the journal says who, advisory and by name" "true" \
    "$(journalctl --user -b --since '-2 min' -t omarchy-face -o cat 2>/dev/null |
       grep -q '^unlocked by face: anna$' && echo true || echo false)"
else
  note "no readable user journal here, so the advisory record is unchecked"
fi

step "GATE: two wakes a second apart — one check, never two"
out=$(run_lock wake-busy "$root/fake")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "both wakes were seen" "2" "$(field wakes "$out")"
check "…and only the first started a check" "1" "$(field attempts "$out")"
note "a queued second check would cost a camera_busy and a slot of the daemon's"
note "shared rate budget (plan-engine.md §6.2)"
check "…which still opened the lock" "1" "$(field unlocks "$out")"

step "GATE (F6 test 7b): a stale result against a fresh lock"
out=$(run_lock wake-stale "$root/fake")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "one check ran" "1" "$(field attempts "$out")"
check "…the password ended that lock and a new one began" "2" "$(field generation "$out")"
check "…the check came back with a yes, for a lock that was over" "stale" \
  "$(field outcome "$out")"
check "…it was dropped" "1" "$(field stale "$out")"
check "…nothing was unlocked by it" "0" "$(field unlocks "$out")"
check "…and the new lock is still locked" "true" "$(field locked "$out")"
if journalctl --user -b --since "-2 min" -t omarchy-face -o cat >/dev/null 2>&1; then
  check "…and the drop is on the record, not silent" "true" \
    "$(journalctl --user -b --since '-2 min' -t omarchy-face -o cat 2>/dev/null |
       grep -q '^stale face result ignored$' && echo true || echo false)"
fi

step "a face that is not on the list"
out=$(run_lock wake-no "$root/fake")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the check ran" "1" "$(field attempts "$out")"
check "…said no" "no" "$(field outcome "$out")"
check "…and the lock stayed locked" "true" "$(field locked "$out")"

step "GATE (F6 test 6): Face removed, the clone left behind"
out=$(run_lock wake-missing "$root/fake")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the wake was still seen" "1" "$(field wakes "$out")"
check "…the check could not even start" "no" "$(field outcome "$out")"
check "…nothing was unlocked" "0" "$(field unlocks "$out")"
check "…and the lock screen is Omarchy's, with its password field" "true" \
  "$(field locked "$out")"
note "a plugin removed without Remove Face leaves this state; the README says to"
note "reinstall the plugin to take the rest off"

step "clamshell: the monitor comes back rather than the DPMS (E7)"
out=$(run_lock wake-clamshell "$root/fake")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "a disabled monitor coming back is a wake too" "1" "$(field wakes "$out")"
check "…and starts one check" "1" "$(field attempts "$out")"

step "the composed wrapper never arms Enter on a lock screen it does not fit"
out=$(run_lock incompatible "$root/scratch")
check "…it only ever clears a stale binding, at start" "disarm" "$(evals)"

# =============================================================================
# Enter on an empty password field
# =============================================================================

step "GATE: the Enter binding exists only while a lock does"
out=$(run_lock enter-arming "$root/fake")
check "cleared at start, then armed and disarmed once per lock" \
  "disarm arm disarm arm disarm" "$(evals)"
check "…every registration names this wrapper's own event, and a plain word" \
  "0" "$(grep -c 'wrong-event' "$status/eval.log" 2>/dev/null)"
check "the shipped Lua binds both Enters, locked and non-consuming" "true" \
  "$(grep -q 'pairs({ Return = .*, KP_Enter = .*-keypad" })' "$REPO/lock/Service.qml" &&
     grep -q 'locked = true, non_consuming = true' "$REPO/lock/Service.qml" &&
     echo true || echo false)"
check "…and raises an event, never a command" "0" \
  "$(code | grep -c 'dsp.exec')"

step "GATE: a config reload inside a lock arms Enter again"
out=$(run_lock enter-reload "$root/fake")
check "start, reload while unlocked (nothing), lock, reload (again), unlock" \
  "disarm arm arm disarm" "$(evals)"
note "monitor daemons reload Hyprland's config on every display wake, so without"
note "this Enter works only until a lock first blanks"

step "GATE: Enter on a lit lock screen"
out=$(run_lock enter-lit "$root/fake")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
enter_path=$(field enterPath "$out")
[[ $enter_path == hyprland ]] ||
  note "no compositor here: Enter was called directly, the event path is untested"
check "nothing woke" "0" "$(field wakes "$out")"
check "…Enter was heard" "1" "$(field enters "$out")"
check "…one check ran" "1" "$(field attempts "$out")"
check "…and it opened the lock" "unlocked" "$(field outcome "$out")"

step "Enter with no lock up"
out=$(run_lock enter-unlocked "$root/fake")
check "is not counted" "0" "$(field enters "$out")"
check "…and starts nothing" "0" "$(field attempts "$out")"

step "GATE: Enter that submits a typed password"
out=$(run_lock enter-password "$root/fake")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "Enter was heard" "1" "$(field enters "$out")"
check "…but no face check ran beside the password" "0" "$(field attempts "$out")"
check "…and the lock is still the password's to open" "true" "$(field locked "$out")"

step "GATE: the same, with PAM rejecting before the wrapper looks"
out=$(run_lock enter-fast-reject "$root/fake")
check "no face check ran" "0" "$(field attempts "$out")"

step "Enter twice while a check runs"
out=$(run_lock enter-busy "$root/fake")
check "both were heard" "2" "$(field enters "$out")"
check "…one check" "1" "$(field attempts "$out")"
check "…and the stock blank countdown was restarted while it ran (start, every 2 s, answer)" "true" \
  "$( (( $(field blankArms "$out") >= 3 )) && echo true || echo false)"

step "a keypad Enter fires both bindings"
out=$(run_lock enter-keypad "$root/fake")
check "both events were heard" "2" "$(field enters "$out")"
check "…and folded into one check" "1" "$(field attempts "$out")"

step "GATE: nothing starts a check on locking"
out=$(run_lock wake-quiet "$root/fake")
check "a lock with no key and no wake: no Enter, no check" "0|0" \
  "$(field enters "$out")|$(field attempts "$out")"

step "Enter on a dark screen is a wake and an Enter"
out=$(run_lock enter-wake "$root/fake")
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "one check between them" "1" "$(field attempts "$out")"

step "what a no says"
out=$(run_lock enter-no "$root/fake")
check "the line says to press Enter" "$(field lineNo "$out")" "$(field line "$out")"
check "…and nothing claims a resume" "false" "$(field resumed "$out")"
out=$(run_lock enter-no-resumed "$root/fake")
check "a no just after a resume says the camera may be waking" \
  "$(field lineNoResumed "$out")" "$(field line "$out")"
check "…because the frozen poll was read as a resume" "true" "$(field resumed "$out")"
out=$(run_lock enter-no-resume-last-lock "$root/fake")
check "a resume in the LAST lock does not follow into the next one" \
  "$(field lineNo "$out")" "$(field line "$out")"

step "GATE: every line fits the password field (LockView elides it)"
lines=$(sed -n 's/^ *readonly property string line[A-Za-z]*: "\(.*\)"$/\1/p' "$REPO/lock/Service.qml")
cp "$REPO/dev/qml-harness/lock-lines.qml" "$root/shell.qml"
measured=$(FACE_HARNESS_LINES="$(paste -sd'|' <<<"$lines")" timeout 30 quickshell -p "$root" -n 2>&1 |
  sed -n 's/^.*HARNESS \([a-zA-Z0-9]*\) \(.*\)$/\1=\2/p')
room=$(field roomFingerprint "$measured")
i=0
while IFS= read -r text; do
  width=$(field "width$i" "$measured")
  check "\"$text\" is ${width:-?} px of $room" "true" \
    "$([[ -n $width && -n $room ]] && ((width <= room)) && echo true || echo false)"
  i=$((i + 1))
done <<<"$lines"
check "…and all three lines were measured" "3" "$i"

# =============================================================================
# The Settings switch and the Setup row (plan-gui.md §6.1, §4 row 8)
# =============================================================================

step "what Settings says for each of the engine's compat words"
for case_name in settings-off settings-loading settings-ok settings-incompatible \
                 settings-failed settings-otherlock; do
  out=$(run_view "$case_name")
  printf '  %-24s %s\n' "$case_name" "${DIM}$(field statusText "$out")${RESET}"
done
out=$(run_view settings-ok FACE_HARNESS_LOCK=1)
check "on and working reads as active" "Active · follows Omarchy's lock screen." \
  "$(field statusText "$out")"
check "…with the switch on" "true" "$(field lockOn "$out")"
check "…and the count from people.json" "3" "$(field lockFaces "$out")"
out=$(run_view settings-incompatible FACE_HARNESS_LOCK=1)
check "a renamed name says so, and that the lock screen still works" \
  "Face is off on the lock screen: Omarchy's lock changed (missing: pendingSessionLock). Password and fingerprint work as normal." \
  "$(field statusText "$out")"
out=$(run_view settings-otherlock)
check "another lock plugin replaces the off line rather than joining it" \
  "Another lock screen plugin (io.github.sirjul1337.lock-explorer) is in use." \
  "$(field statusText "$out")"

step "GATE: turning it on is two calls, in this order"
rm -f "$state/verbs.log"
out=$(run_view settings-toggle-on)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the clone is enabled first, then the owner is asked" "lock:enable lock-on" \
  "$(tr -s ' \n' ' ' <"$state/verbs.log" | sed 's/ *$//')"
check "…and the switch lets go of its pending value when it lands" "true" \
  "$(field pendingAfter "$out")"

step "GATE: declining the prompt leaves the clone disabled"
rm -f "$state/verbs.log"
out=$(run_view settings-toggle-on OMARCHY_FACE_DEV_PKEXEC=1 FACE_HARNESS_DECLINE=1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
# The admin verb is absent from the log on purpose: polkit refused before exec,
# so `lock-on` never ran at all. What follows it is the rollback, and it needs no
# password of its own -- that is the whole point of enabling the clone first.
check "the declined verb never ran, and the enable is rolled back" "lock:enable lock:disable" \
  "$(tr -s ' \n' ' ' <"$state/verbs.log" | sed 's/ *$//')"
check "…and the page says nothing changed" "Not authorised — nothing changed." \
  "$(field note "$out")"

step "an enable that never brought a lock screen up"
rm -f "$state/verbs.log"
out=$(run_view settings-toggle-on OMARCHY_FACE_DEV_LOCK_ERROR=enable_failed)
check "the owner is never asked for a password after it failed" "lock:enable" \
  "$(tr -s ' \n' ' ' <"$state/verbs.log" | sed 's/ *$//')"
check "…and the page says Omarchy's lock screen is back" \
  "Face's lock screen did not start, so Omarchy's is back — nothing changed." \
  "$(field note "$out")"

step "GATE: turning it off is the setting first, then the clone"
rm -f "$state/verbs.log"
out=$(run_view settings-toggle-off FACE_HARNESS_LOCK=1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the daemon is told to stop looking before the lock screen is swapped" \
  "lock-off lock:disable" "$(tr -s ' \n' ' ' <"$state/verbs.log" | sed 's/ *$//')"

step "the Setup row's three repairs"
for case_name in setup-notstaged setup-stale setup-notenabled; do
  rm -f "$state/verbs.log"
  out=$(run_view "$case_name")
  printf '  %-20s %-32s %s\n' "$case_name" "$(field fixLabel "$out")" \
    "${DIM}$(tr -s ' \n' ' ' <"$state/verbs.log" | sed 's/ *$//')${RESET}"
done
rm -f "$state/verbs.log"
out=$(run_view setup-notstaged)
check "not staged offers the one fix that writes the plugins folder" \
  "Finish lock screen setup" "$(field fixLabel "$out")"
check "…and it runs 'stage'" "lock:stage" \
  "$(tr -s ' \n' ' ' <"$state/verbs.log" | sed 's/ *$//')"
rm -f "$state/verbs.log"
out=$(run_view setup-stale)
check "an update waiting offers the restart" "Finish the update" "$(field fixLabel "$out")"
check "…and it runs 'sync'" "lock:sync" \
  "$(tr -s ' \n' ' ' <"$state/verbs.log" | sed 's/ *$//')"
rm -f "$state/verbs.log"
out=$(run_view setup-notenabled)
check "a staged but switched-off clone offers 'enable'" "lock:enable" \
  "$(tr -s ' \n' ' ' <"$state/verbs.log" | sed 's/ *$//')"
out=$(run_view setup-failed)
check "a failed lock screen is broken with NO button (plan-gui.md §4 row 8)" "" \
  "$(field fixLabel "$out")"
check "…and is rendered, although config lock is false" "broken" "$(field rowState "$out")"

# =============================================================================
# The Face service's own two lock duties (plan-gui.md §6.3)
# =============================================================================

# `omarchy-shell lock status` is what the health check asks, so a stand-in that
# never answers is a wrapper that never compiled, as far as the check can tell.
cat >"$root/bin/omarchy-shell" <<'SILENT'
#!/bin/bash
# Nothing answers on the `lock` target: the state a wrapper that did not compile
# leaves behind (shell.qml:916-918 logs a warning and creates no service).
exit 1
SILENT
chmod +x "$root/bin/omarchy-shell"

step "GATE: the start-up health check takes a silent wrapper back out (§9.3a)"
rm -f "$state/verbs.log"
out=$(run_view service-recover OMARCHY_FACE_DEV_LOCK_ENABLED=1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the service ran sync, found the clone enabled, and checked" "recovered" \
  "$(field phase "$out")"
check "…and gave Omarchy's lock screen back, whatever Hyprland says" \
  "lock:disable --stranded" \
  "$(grep 'lock:disable' "$state/verbs.log" | tr -s ' \n' ' ' | sed 's/ *$//')"
check "…having run sync first, at shell start, as the plan orders it" "lock:sync" \
  "$(head -1 "$state/verbs.log" | tr -s ' \n' ' ' | sed 's/ *$//')"

step "GATE: exactly one notification, not one per check"
rm -f "$state/verbs.log"
now=$(($(date +%s%N) / 1000000))
printf '{"compat":"failed","missing":["no lock service answered"],"at":%s}\n' "$now" \
  >"$state/lock-status.json"
out=$(run_view service-notify)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "the reason was noticed" "failed|no lock service answered" "$(field notified "$out")"
check "…and said exactly once, although the file is re-read every two seconds" "1" \
  "$(grep -c 'lock:notify-once' "$state/verbs.log")"
rm -f "$state/lock-status.json"

echo
if ((failures == 0)); then
  echo "${GREEN}G6 offscreen gate passes.${RESET} ${DIM}$checks checks.${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
