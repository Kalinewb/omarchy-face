#!/bin/bash

# H1: the update and boot health check (bin/omarchy-face-health), its two Omarchy
# hooks, and the status helper's Python-upgrade row.
#
#   ./dev/h1-health.sh
#
# What a person gets from this feature is one notification on the day something
# Face depends on changed underneath it, and silence on every other day. So most
# of this suite is about the silence: a healthy machine, a machine where Face was
# never set up, a machine halfway through setting it up, a build that is running
# and a problem that has already been said must all produce NOTHING -- and the
# day that stops being true, exactly one.
#
# Every run of the helper is `env -i` with a temporary HOME and XDG_STATE_HOME,
# a PATH of stand-ins in front of /usr/bin only, and the status document taken
# from dev/fixtures through OMARCHY_FACE_DEV_BIN. The stand-ins record rather
# than act: `omarchy-notification-send`, `notify-send` and `yay` are never the
# real ones (the real `yay -Qua` goes to the network), and Omarchy's own
# /usr/share/omarchy/bin is not on PATH at all. `omarchy-hook` is run for real,
# against the temporary HOME, because what the hook promises is a sentence about
# that script.
#
# The Face service's half -- `install-hooks` at start, and not in development --
# is checked by loading the REAL Service.qml in a throwaway Quickshell instance
# twice, with HOME pointed at a temporary directory and stand-ins in front of
# `omarchy`, `omarchy-shell`, `setsid`, `hyprctl` and `notify-send`, so nothing
# it starts can reach the live shell or this account's ~/.config.
#
# Nothing here touches ~/.config/omarchy or the running shell.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HEALTH=$REPO/bin/omarchy-face-health

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
yes_no() { "$@" && echo true || echo false; }

command -v jq >/dev/null || { echo "h1: jq is not installed" >&2; exit 1; }

REAL_STOCK=/usr/share/omarchy/shell/plugins/lock/Service.qml

# Face's hooks in this account's real hooks folder, before and after: whatever
# they are (installed or not), this suite must leave them so.
real_hooks() { stat -c '%n %i %y' "$HOME"/.config/omarchy/hooks/*/graveklar-face.hook 2>/dev/null; }
REAL_HOOKS_BEFORE=$(real_hooks)

root=$(mktemp -d /tmp/omarchy-face-h1.XXXXXX)
trap 'rm -rf "$root"' EXIT

home=$root/home
stubs=$root/stubs
fixtures=$root/fixtures
omarchy=$root/omarchy
CALLS=$root/calls.log
mkdir -p "$home" "$stubs" "$fixtures" "$omarchy/shell/plugins/lock" "$root/devstate"

NOTIFIED=$home/.local/state/omarchy-face/health-notified

# --- stand-ins ---------------------------------------------------------------

# Both notifiers record their argv as one JSON array per call, NUL-split the way
# omarchy-notification-send itself hands --exec to jq, so an empty argument
# survives and can be asserted on. H1_NOTIFY_RC makes them fail.
for name in omarchy-notification-send notify-send; do
  cat >"$stubs/$name" <<STANDIN
#!/bin/bash
printf '%s\0' "$name" "\$@" | jq -Rsc 'split("\u0000")[:-1]' >>"$CALLS"
exit \${H1_NOTIFY_RC:-0}
STANDIN
done

# `yay -Qua`: whatever H1_YAY_OUT says, and exit 1 when it says nothing, which
# is what yay does with no updates (and with no network).
cat >"$stubs/yay" <<STANDIN
#!/bin/bash
printf 'yay %s\n' "\$*" >>"$CALLS"
[[ -n \${H1_YAY_OUT:-} ]] || exit 1
printf '%b' "\$H1_YAY_OUT"
STANDIN
chmod 0755 "$stubs"/*

# The fixtures. Three from the repository, and the rest derived from
# `configured` by one edit each, so every case below differs from a known-good
# machine in exactly the way it says.
for name in configured fresh three-people broken-engine; do
  mkdir -p "$fixtures/$name"
  cp "$REPO/dev/fixtures/$name/status.json" "$fixtures/$name/status.json"
done

derive() { # derive <name> <jq filter over configured>
  mkdir -p "$fixtures/$1"
  jq "$2" "$REPO/dev/fixtures/configured/status.json" >"$fixtures/$1/status.json"
}
set_row() { # set_row <id> <state> <detail> <fix> -> a jq filter
  printf '.rows = [.rows[] | if .id == "%s" then .state = "%s" | .detail = "%s" | .fix = "%s" else . end]' \
    "$1" "$2" "$3" "$4"
}

derive broken-sudo "$(set_row sudo broken "Face for sudo is on but /etc/pam.d/sudo is not what Face wrote" sudo-off)"
derive building "$(set_row engine unknown "building the face engine — build" "") | $(set_row install-job unknown "building — build" "")"
derive lock-incompatible "$(set_row lock broken "Omarchy's lock screen changed, so face is off on it (missing: locked)" "") | .lock.compat = \"incompatible\" | .lock.missing = [\"locked\"]"
derive lock-other "$(set_row lock broken "another lock screen plugin (someone.lock) is in use, so face is off on the lock screen" "") | .lock.otherLock = \"someone.lock\""
derive lock-off ".config.lock = false | .lock.enabled = false | .rows = [.rows[] | select(.id != \"lock\")]"
derive engine-gone "$(set_row engine needs_action "the face engine is not built yet" install-engine)"
# Installed, nobody recorded, both switches off: every row that is not `ok` is a
# step of Setup, and none of them is news.
derive half-set-up "$(set_row engine needs_action "the face engine is not built yet" install-engine) | $(set_row people needs_action "record your face first" "") | $(set_row sudo needs_action off sudo-on) | .config.sudo = false | .config.lock = false | .lock.enabled = false | .engine.installed = false | .removal.packages = [] | .rows = [.rows[] | select(.id != \"lock\")]"
# No infrared camera: the status helper hides every row but these two.
derive no-camera "$(set_row camera needs_action "no infrared camera — Face cannot work on this machine" "") | .rows = [.rows[] | select(.id == \"camera\" or .id == \"legacy\")]"
derive no-camera-fresh "$(set_row camera needs_action "no infrared camera — Face cannot work on this machine" "") | .rows = [.rows[] | select(.id == \"camera\" or .id == \"legacy\")] | .removal = {people: [], pam: [], lockWrapper: true, helpers: 0, daemon: false, policy: false, packages: []} | .config.account = \"\""

cp "$REAL_STOCK" "$omarchy/shell/plugins/lock/Service.qml" 2>/dev/null

# One run of the helper, as the hook runs it: a clean environment, this HOME.
health() { # health <verb> <fixture> [VAR=value…]
  local verb=$1 fixture=$2
  shift 2
  env -i HOME="$home" XDG_STATE_HOME="$home/.local/state" PATH="$stubs:/usr/bin" \
    OMARCHY_PATH="$omarchy" \
    OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_FIXTURES="$fixtures" \
    OMARCHY_FACE_DEV_FIXTURE="$fixture" OMARCHY_FACE_DEV_STATE="$root/devstate" \
    "$@" "$HEALTH" "$verb"
}

notifications() { grep -c '^\["\(omarchy-notification-send\|notify-send\)"' "$CALLS" 2>/dev/null || true; }
reset_calls() { : >"$CALLS"; rm -f "$NOTIFIED"; }

echo "H1 — the update and boot health check"
echo "${DIM}helper: $HEALTH   home: $home${RESET}"

# =============================================================================
step "the lock screen contract is ONE list"
# =============================================================================

wrapper_list=$(grep -A2 'readonly property var contractProperties:' "$REPO/lock/Service.qml" |
  tr '\n' ' ' | sed 's/\].*//' | grep -o '"[A-Za-z]*"' | tr -d '"' | paste -sd' ')
health_list=$(sed -n 's/^LOCK_CONTRACT_PROPERTIES=(\(.*\))$/\1/p' "$HEALTH")
check "the health check names the wrapper's contractProperties, in order" "$wrapper_list" "$health_list"
check "…and the function the wrapper calls is the one it looks for" "true" \
  "$(yes_no grep -q "typeof item.$(sed -n 's/^LOCK_CONTRACT_FUNCTION=//p' "$HEALTH") !== \"function\"" "$REPO/lock/Service.qml")"

# =============================================================================
step "silence"
# =============================================================================

reset_calls
out=$(health post-update configured); rc=$?
check "a healthy machine: post-update exits 0" "0" "$rc"
check "…prints nothing" "" "$out"
check "…and notifies nobody" "0" "$(notifications)"
out=$(health post-boot configured); rc=$?
check "…and post-boot is as quiet" "0|" "$rc|$out"
check "…still with no notification" "0" "$(notifications)"
check "yay was asked, once, by post-update only" "yay -Qua" "$(grep '^yay' "$CALLS" | paste -sd'|')"

reset_calls
check "Face never set up: silent" "0||0" "$(health post-update fresh; echo "$?|$(health post-boot fresh)|$(notifications)")"
check "…and yay is not asked about an engine that is not there" "" "$(grep '^yay' "$CALLS")"

reset_calls
check "no infrared camera and nothing installed: silent" "0||0" \
  "$(health post-update no-camera-fresh; echo "$?|$(health post-boot no-camera-fresh)|$(notifications)")"

reset_calls
check "halfway through Setup (engine not built, nobody recorded, sudo off): silent" "|0" \
  "$(health post-boot half-set-up)|$(notifications)"
check "three-people (lock wrapper not staged, config.lock off): silent" "|0" \
  "$(health post-boot three-people)|$(notifications)"
check "an engine build running (rows unknown): silent" "|0" \
  "$(health post-update building)|$(notifications)"
check "Omarchy's lock screen incompatible: silent, the service's notify-once says that one" "|0" \
  "$(health post-boot lock-incompatible)|$(notifications)"

# An unreadable status document is not healthy: it must not clear a problem
# that was already said.
mkdir -p "$root/garbage-bin"
printf '#!/bin/bash\necho not json\n' >"$root/garbage-bin/omarchy-face-status"
chmod 0755 "$root/garbage-bin/omarchy-face-status"
reset_calls
mkdir -p "${NOTIFIED%/*}"
echo remembered >"$NOTIFIED"
out=$(health post-update configured OMARCHY_FACE_DEV_BIN="$root/garbage-bin"); rc=$?
check "a status helper that prints no JSON: exit 0, silent" "0||0" "$rc|$out|$(notifications)"
check "…and what was already notified is remembered, not cleared" "remembered" "$(cat "$NOTIFIED" 2>/dev/null)"

# =============================================================================
step "one notification per problem, and the terminal every time"
# =============================================================================

reset_calls
out=$(health post-update broken-engine); rc=$?
echo "${DIM}$(sed 's/^/    │ /' <<<"$out")${RESET}"
check "a Python upgrade: post-update exits 0 all the same" "0" "$rc"
check "…prints the problem in the update terminal" "true" \
  "$(yes_no grep -qxF '  · Face engine: Python was upgraded to 3.15, but the face engine was built for 3.14 — build the engine again' <<<"$out")"
check "…and where to go" "true" "$(yes_no grep -qF 'Face ID → Setup' <<<"$out")"
check "…and nothing else" "1" "$(grep -c '^  · ' <<<"$out")"
check "ONE notification" "1" "$(notifications)"
sent=$(grep '^\["omarchy-notification-send"' "$CALLS" | head -1)
check "…through Omarchy's sender, critical, with Face's glyph" \
  "[\"-u\",\"critical\",\"-g\",\"$(printf '\U000f004d')\"]" "$(jq -c '.[3:7]' <<<"$sent")"
check "…titled, with the row as its body" \
  '["Face ID needs attention","Face engine: Python was upgraded to 3.15, but the face engine was built for 3.14 — build the engine again"]' \
  "$(jq -c '.[7:9]' <<<"$sent")"
check "…and a click that opens the panel on Setup (both IPC arguments)" \
  '["--exec","omarchy-shell","graveklar.face","open","setup",""]' "$(jq -c '.[9:]' <<<"$sent")"
check "the problem set is remembered" "true" "$(yes_no test -s "$NOTIFIED")"

out=$(health post-boot broken-engine)
check "the same problem at the next boot: not notified again" "1|" "$(notifications)|$out"
out=$(health post-update broken-engine)
check "…nor at the next update" "1" "$(notifications)"
check "…which still prints it in the terminal" "true" "$(yes_no grep -qF 'Python was upgraded to 3.15' <<<"$out")"

out=$(health post-boot broken-sudo)
check "a DIFFERENT problem is news" "2" "$(notifications)"
check "…and says its own row" "Face for sudo: Face for sudo is on but /etc/pam.d/sudo is not what Face wrote" \
  "$(tail -1 "$CALLS" | jq -r '.[8]')"

health post-boot configured >/dev/null
check "a healthy run clears the memory" "false" "$(yes_no test -e "$NOTIFIED")"
health post-boot broken-sudo >/dev/null
check "…so the same breakage coming back is notified again" "3" "$(notifications)"

reset_calls
health post-boot broken-engine H1_NOTIFY_RC=1 >/dev/null
check "a notification that could not be sent is not remembered as said" "false" "$(yes_no test -e "$NOTIFIED")"
check "…and it fell back to notify-send before giving up" "omarchy-notification-send notify-send" \
  "$(jq -r '.[0]' "$CALLS" | paste -sd' ')"
health post-boot broken-engine >/dev/null
check "…so the next run tries again" "3" "$(wc -l <"$CALLS" | tr -d ' ')"

reset_calls
mkdir -p "$root/stubs-nosend"
cp "$stubs/notify-send" "$stubs/yay" "$root/stubs-nosend/"
env -i HOME="$home" XDG_STATE_HOME="$home/.local/state" PATH="$root/stubs-nosend:/usr/bin" \
  OMARCHY_PATH="$omarchy" OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_FIXTURES="$fixtures" \
  OMARCHY_FACE_DEV_FIXTURE=broken-engine OMARCHY_FACE_DEV_STATE="$root/devstate" \
  "$HEALTH" post-boot >/dev/null
check "no omarchy-notification-send on the machine: notify-send, once" \
  '["notify-send","-a","Face ID","-u","critical","Face ID needs attention"]' "$(jq -c '.[:6]' "$CALLS")"

# The click, through the REAL omarchy-notification-send with only busctl stood in:
# its own --exec validation has to accept the argv, and the hint it sends is what
# the shell will run.
if [[ -x /usr/share/omarchy/bin/omarchy-notification-send ]]; then
  reset_calls
  mkdir -p "$root/stubs-real"
  cp "$stubs/yay" "$root/stubs-real/"
  ln -s /usr/share/omarchy/bin/omarchy-notification-send "$root/stubs-real/omarchy-notification-send"
  cat >"$root/stubs-real/busctl" <<STANDIN
#!/bin/bash
printf '%s\0' busctl "\$@" | jq -Rsc 'split("\u0000")[:-1]' >>"$CALLS"
echo "u 7"
STANDIN
  chmod 0755 "$root/stubs-real/busctl"
  env -i HOME="$home" XDG_STATE_HOME="$home/.local/state" PATH="$root/stubs-real:/usr/bin" \
    OMARCHY_PATH="$omarchy" OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_FIXTURES="$fixtures" \
    OMARCHY_FACE_DEV_FIXTURE=broken-engine OMARCHY_FACE_DEV_STATE="$root/devstate" \
    "$HEALTH" post-boot >/dev/null
  hint=$(jq -r 'index("omarchy-exec-argv") as $i | if $i then .[$i + 2] else "" end' "$CALLS" 2>/dev/null | head -1)
  check "the real omarchy-notification-send accepts it, and the click it carries is" \
    '["omarchy-shell","graveklar.face","open","setup",""]' "$hint"
  check "…as app Face ID" "Face ID" "$(jq -r '.[9]' "$CALLS" | head -1)"
  check "…and it counts as said" "true" "$(yes_no test -s "$NOTIFIED")"
else
  note "no /usr/share/omarchy/bin/omarchy-notification-send; the real sender's --exec parsing is not checked"
fi

# =============================================================================
step "which rows are news"
# =============================================================================

reset_calls
check "the engine gone after somebody was recorded: news" \
  "Face engine: the face engine is not built yet" "$(health post-boot engine-gone >/dev/null; tail -1 "$CALLS" | jq -r '.[8]')"
reset_calls
check "another lock screen plugin in the way: news" \
  "Lock screen: another lock screen plugin (someone.lock) is in use, so face is off on the lock screen" \
  "$(health post-boot lock-other >/dev/null; tail -1 "$CALLS" | jq -r '.[8]')"
reset_calls
check "Face installed and the infrared camera gone: news" \
  "Infrared camera: no infrared camera — Face cannot work on this machine" \
  "$(health post-boot no-camera >/dev/null; tail -1 "$CALLS" | jq -r '.[8]')"

# =============================================================================
step "post-update: the lock screen Omarchy just installed"
# =============================================================================

if [[ -r $REAL_STOCK ]]; then
  reset_calls
  check "the real on-disk lock screen fits the contract" "|0" "$(health post-update configured)|$(notifications)"

  sed 's/\bauthenticatingPassword\b/passwordAuthenticating/g' "$REAL_STOCK" >"$omarchy/shell/plugins/lock/Service.qml"
  reset_calls
  out=$(health post-update configured); rc=$?
  echo "${DIM}$(sed 's/^/    │ /' <<<"$out")${RESET}"
  check "one property renamed: exit 0, and the terminal names it" "0|true" \
    "$rc|$(yes_no grep -qxF "  · after this update's restart, face will be off on the lock screen: Omarchy's lock screen changed (missing: authenticatingPassword)" <<<"$out")"
  check "…in one notification" "1" "$(notifications)"
  reset_calls
  check "post-boot does not preview it (the wrapper reports what actually loaded)" "|0" \
    "$(health post-boot configured)|$(notifications)"
  check "…and neither does post-update with face off on the lock screen" "|0" \
    "$(health post-update lock-off)|$(notifications)"

  sed -e 's/\bfinishUnlock\b/completeUnlock/g' -e 's/property bool locked:/property bool isLocked:/' \
    "$REAL_STOCK" >"$omarchy/shell/plugins/lock/Service.qml"
  reset_calls
  out=$(health post-update configured)
  check "a declaration renamed while the word stays in bindings, and the function renamed" "true" \
    "$(yes_no grep -qF '(missing: locked, finishUnlock())' <<<"$out")"

  # A comment or a binding that mentions a name is not a declaration of it.
  grep -v 'property bool pendingSessionLock' "$REAL_STOCK" >"$omarchy/shell/plugins/lock/Service.qml"
  check "…and a name still used everywhere but no longer declared" "true" \
    "$(yes_no grep -qF '(missing: pendingSessionLock)' <<<"$(health post-update configured)")"

  rm -f "$omarchy/shell/plugins/lock/Service.qml"
  reset_calls
  check "no lock screen at that path at all" "true" \
    "$(yes_no grep -qF "Omarchy's lock screen is no longer at $omarchy/shell/plugins/lock/Service.qml" <<<"$(health post-update configured)")"
  cp "$REAL_STOCK" "$omarchy/shell/plugins/lock/Service.qml"
else
  note "no $REAL_STOCK; the lock preview is not checked"
fi

# =============================================================================
step "post-update: the AUR step that runs next"
# =============================================================================

reset_calls
out=$(health post-update configured H1_YAY_OUT='some-font 1.0-1 -> 1.1-1\nhowdy 2.6.1-3 -> 2.7.0-1\npython-dlib 20.0.1-2 -> 20.0.2-1\npython-dlib-debug 20.0.1-2 -> 20.0.2-1\n')
echo "${DIM}$(sed 's/^/    │ /' <<<"$out")${RESET}"
check "howdy and python-dlib pending: said before it happens" "true" \
  "$(yes_no grep -qxF "  · the AUR update that runs next will rebuild howdy, python-dlib; Face's engine will need building again afterwards (Face ID → Setup)" <<<"$out")"
check "…once" "1" "$(notifications)"
reset_calls
check "only somebody else's AUR packages pending: silent" "|0" \
  "$(health post-update configured H1_YAY_OUT='some-font 1.0-1 -> 1.1-1\n')|$(notifications)"
check "no answer from the AUR (yay fails): silent" "|0" "$(health post-update configured)|$(notifications)"
reset_calls
check "post-boot never asks the AUR" "|0|0" \
  "$(health post-boot configured H1_YAY_OUT='howdy 2.6.1-3 -> 2.7.0-1\n')|$(grep -c '^yay' "$CALLS")|$(notifications)"

check "post-update and post-boot wrote no file under HOME but the memory file" "" \
  "$(find "$home" -type f ! -path "$NOTIFIED" | paste -sd' ')"

# =============================================================================
step "install-hooks"
# =============================================================================

hooks=$home/.config/omarchy/hooks
H_UPDATE=$hooks/post-update.d/graveklar-face.hook
H_BOOT=$hooks/post-boot.d/graveklar-face.hook

hooks_cmd() { env -i HOME="$home" PATH="/usr/bin" "$HEALTH" "$1"; }

out=$(hooks_cmd install-hooks); rc=$?
check "into an empty HOME: exit 0" "0" "$rc"
check "…both written" '{"ok":true,"written":2}' "$out"
check "…755" "755 755" "$(stat -c '%a' "$H_UPDATE" "$H_BOOT" 2>/dev/null | paste -sd' ')"
check "…and nothing else left in either folder (no temp files)" "graveklar-face.hook graveklar-face.hook" \
  "$(ls -A "${H_UPDATE%/*}" "${H_BOOT%/*}" 2>/dev/null | grep -v '^$\|:$' | paste -sd' ')"
check "each hook passes its own verb" "post-update|post-boot" \
  "$(grep -ho '"\$health" post-[a-z]*' "$H_UPDATE" "$H_BOOT" | sed 's/"$health" //' | paste -sd'|')"
check "…and parses" "0" "$(bash -n "$H_UPDATE" && bash -n "$H_BOOT"; echo $?)"

before=$(stat -c '%i %y' "$H_UPDATE" "$H_BOOT")
sleep 0.05
out=$(hooks_cmd install-hooks)
check "a second run rewrites nothing" '{"ok":true,"written":0}' "$out"
check "…same inode, same mtime" "$before" "$(stat -c '%i %y' "$H_UPDATE" "$H_BOOT")"

chmod 0644 "$H_BOOT"
out=$(hooks_cmd install-hooks)
check "a hook with the right text and the wrong mode is chmodded, not rewritten" \
  '{"ok":true,"written":0}|755' "$out|$(stat -c '%a' "$H_BOOT")"
check "…mtime unchanged" "$before" "$(stat -c '%i %y' "$H_UPDATE" "$H_BOOT")"

echo '# edited' >>"$H_UPDATE"
out=$(hooks_cmd install-hooks)
check "a hook somebody edited is put back" '{"ok":true,"written":1}' "$out"
check "…as the same text as its sibling, verb aside" "" \
  "$(diff <(sed 's/post-update/VERB/g' "$H_UPDATE") <(sed 's/post-boot/VERB/g' "$H_BOOT"))"

# =============================================================================
step "the hooks themselves"
# =============================================================================

plugin_bin=$home/.config/omarchy/plugins/graveklar.face/bin
mkdir -p "$plugin_bin"
cat >"$plugin_bin/omarchy-face-health" <<STANDIN
#!/bin/bash
echo "health \$*" >>"$CALLS"
exit 7
STANDIN
chmod 0755 "$plugin_bin/omarchy-face-health"

: >"$CALLS"
env -i HOME="$home" PATH=/usr/bin bash "$H_UPDATE"; rc=$?
check "with the plugin installed, the hook runs its verb" "health post-update" "$(cat "$CALLS")"
check "…and exits 0 although the helper did not" "0" "$rc"
check "…and stays" "true" "$(yes_no test -e "$H_UPDATE")"

if [[ -x /usr/share/omarchy/bin/omarchy-hook ]]; then
  : >"$CALLS"
  out=$(env -i HOME="$home" PATH=/usr/bin /usr/share/omarchy/bin/omarchy-hook post-boot 2>&1); rc=$?
  check "through Omarchy's own omarchy-hook: exit 0, no 'Hook failed'" "0|" "$rc|$(grep 'Hook failed' <<<"$out")"
  check "…having run it" "health post-boot" "$(cat "$CALLS")"
else
  note "no /usr/share/omarchy/bin/omarchy-hook; the hook is not run through it"
fi

rm -rf "$home/.config/omarchy/plugins"
: >"$CALLS"
env -i HOME="$home" PATH=/usr/bin bash "$H_BOOT"; rc=$?
check "the plugin gone: the hook exits 0" "0" "$rc"
check "…runs nothing" "" "$(cat "$CALLS")"
check "…and deletes itself" "false" "$(yes_no test -e "$H_BOOT")"
check "…and only itself" "true" "$(yes_no test -e "$H_UPDATE")"
if [[ -x /usr/share/omarchy/bin/omarchy-hook ]]; then
  out=$(env -i HOME="$home" PATH=/usr/bin /usr/share/omarchy/bin/omarchy-hook post-update 2>&1); rc=$?
  check "…and through omarchy-hook as well, silently" "0||false" "$rc|$out|$(yes_no test -e "$H_UPDATE")"
fi

# =============================================================================
step "remove-hooks"
# =============================================================================

hooks_cmd install-hooks >/dev/null
check "installed again" "true" "$(yes_no test -e "$H_UPDATE" -a -e "$H_BOOT")"
hooks_cmd remove-hooks; rc=$?
check "remove-hooks: exit 0, both gone" "0|false|false" \
  "$rc|$(yes_no test -e "$H_UPDATE")|$(yes_no test -e "$H_BOOT")"
hooks_cmd remove-hooks; rc=$?
check "…and again with nothing there: still 0" "0" "$rc"
check "the folders themselves are Omarchy's, and stay" "true" \
  "$(yes_no test -d "${H_UPDATE%/*}" -a -d "${H_BOOT%/*}")"
env -i HOME="$home" PATH=/usr/bin "$HEALTH" nonsense 2>/dev/null; rc=$?
check "an unknown verb is usage, exit 2" "2" "$rc"

# =============================================================================
step "the status helper: the engine built for another Python"
# =============================================================================

running=$(readlink -f /usr/bin/python3 2>/dev/null | sed -n 's#^.*/python\([0-9][0-9]*\.[0-9][0-9]*\)$#\1#p')
mkdir -p "$root/pacman-bin"
# pacman, as far as the engine rows ask it: both packages installed, and
# python-dlib's file list naming whichever site-packages H1_PY says (none when it
# is empty, two when it holds two).
cat >"$root/pacman-bin/pacman" <<'STANDIN'
#!/bin/bash
case "$*" in
  "-Q howdy") echo "howdy ${H1_HOWDY:-2.6.1-3}" ;;
  "-Q python-dlib") echo "python-dlib 20.0.1-2" ;;
  "-Qlq python-dlib")
    for v in ${H1_PY:-}; do
      printf '%s\n' "/usr/lib/python$v/site-packages/" \
        "/usr/lib/python$v/site-packages/_dlib_pybind11.cpython-x86_64-linux-gnu.so"
    done
    printf '%s\n' /usr/share/licenses/python-dlib/ ;;
  *) exec /usr/bin/pacman "$@" ;;
esac
STANDIN
chmod 0755 "$root/pacman-bin/pacman"

engine_row() { # engine_row [VAR=value…] -> "state|fix|detail"
  env PATH="$root/pacman-bin:$PATH" "$@" "$REPO/bin/omarchy-face-status" --json 2>/dev/null |
    jq -r 'first(.rows[] | select(.id == "engine")) | "\(.state)|\(.fix)|\(.detail)"'
}

if [[ -z $running ]]; then
  note "/usr/bin/python3 is not a link to pythonX.Y here; the Python row is not checked"
elif [[ -z $(engine_row H1_PY="$running") ]]; then
  note "the status helper shows no engine row on this machine (no infrared camera?); not checked"
elif [[ $(engine_row H1_PY="$running") == unknown* ]]; then
  note "an engine build is running on this machine; the Python row is not checked"
else
  check "built for an older Python: broken, with the build as its fix" \
    "broken|install-engine|Python was upgraded to $running, but the face engine was built for 3.1 — build the engine again" \
    "$(engine_row H1_PY=3.1)"
  check "built for a newer one (a downgrade): said the other way round" \
    "broken|install-engine|Python is now $running, but the face engine was built for 99.0 — build the engine again" \
    "$(engine_row H1_PY=99.0)"
  check "…and it wins over howdy's own version disagreeing (one rebuild fixes both)" \
    "broken|install-engine|Python was upgraded to $running, but the face engine was built for 3.1 — build the engine again" \
    "$(engine_row H1_PY=3.1 H1_HOWDY=0.0.0-1)"
  check "built for the Python that is running: not this problem" "false" \
    "$(yes_no grep -q 'built for' <<<"$(engine_row H1_PY="$running")")"
  check "a package list naming no site-packages: no invented problem" "false" \
    "$(yes_no grep -q 'Python' <<<"$(engine_row H1_PY=)")"
  check "…nor one naming two" "false" \
    "$(yes_no grep -q 'Python' <<<"$(engine_row H1_PY="3.1 $running")")"
fi
check "the Python row reads paths, and never imports anything" "false" \
  "$(yes_no grep -Eq 'python3?[[:space:]]+-c|import dlib' <(grep -v '^[[:space:]]*#' "$REPO/bin/omarchy-face-status"))"

# =============================================================================
step "the Face service installs the hooks at start, and not in development"
# =============================================================================

if ! command -v quickshell >/dev/null; then
  note "quickshell is not installed; Service.qml is not loaded"
else
  SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
  : "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
  harness=$root/harness
  qhome=$root/qhome
  qstubs=$root/qstubs
  mkdir -p "$harness" "$qhome" "$qstubs"
  ln -s "$SHELL_PATH/shell/Commons" "$harness/Commons"
  ln -s "$SHELL_PATH/shell/Ui" "$harness/Ui"
  ln -s "$REPO" "$harness/face"
  cat >"$harness/shell.qml" <<'QML'
import QtQuick
import Quickshell
import "face" as Face

// The real Face service, for as long as its start-up takes, and nothing else.
ShellRoot {
  Face.Service { omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy" }
  Timer { interval: 4000; running: true; onTriggered: Qt.exit(0) }
}
QML
  # Everything the service starts besides the health helper, recorded and inert:
  # the lock verbs' restart and IPC, the layer rule, the notifier.
  for name in omarchy omarchy-shell setsid hyprctl notify-send omarchy-hyprland-session-locked; do
    printf '#!/bin/bash\necho "%s $*" >>"%s"\nexit 1\n' "$name" "$root/qcalls.log" >"$qstubs/$name"
  done
  chmod 0755 "$qstubs"/*

  run_service() { # run_service [VAR=value…]
    env HOME="$qhome" XDG_CONFIG_HOME="$qhome/.config" XDG_STATE_HOME="$qhome/.local/state" \
      PATH="$qstubs:$PATH" OMARCHY_FACE_DEV_BIN= "$@" \
      timeout 30 quickshell -p "$harness" -n 2>&1
  }

  out=$(run_service OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_STATE="$root/devstate" \
    OMARCHY_FACE_DEV_FIXTURE=configured)
  check "development: the service loads" "true" "$(yes_no grep -q 'graveklar.face service loaded' <<<"$out")"
  check "…says it is not installing the hooks" "true" \
    "$(yes_no grep -q 'development: not installing the update and boot hooks' <<<"$out")"
  check "…and writes none" "false" "$(yes_no test -e "$qhome/.config/omarchy/hooks")"

  out=$(run_service)
  for _ in $(seq 1 20); do
    [[ -e $qhome/.config/omarchy/hooks/post-boot.d/graveklar-face.hook ]] && break
    sleep 0.1
  done
  check "installed plugin: the service loads" "true" "$(yes_no grep -q 'graveklar.face service loaded' <<<"$out")"
  check "…and both hooks are in place under its HOME" "true" \
    "$(yes_no test -x "$qhome/.config/omarchy/hooks/post-update.d/graveklar-face.hook" -a \
       -x "$qhome/.config/omarchy/hooks/post-boot.d/graveklar-face.hook")"
fi

check "this account's own ~/.config/omarchy/hooks are as they were" "$REAL_HOOKS_BEFORE" "$(real_hooks)"

echo
if ((failures == 0)); then
  echo "${GREEN}$checks checks, all passed${RESET}"
else
  echo "${RED}$checks checks, $failures failed${RESET}"
fi
exit $((failures > 0))
