#!/bin/bash

# F6: the lock-screen verbs, against a throwaway plugins folder.
#
#   ./dev/f6-lock.sh
#
# There is no `--here`, and there will not be. The file under test can enable a
# lock screen clone, restart the shell and delete a plugin folder, and getting
# any of those wrong on the machine it runs on is a desktop stranded behind a
# lock screen nobody can answer. So the whole run happens with XDG_CONFIG_HOME,
# XDG_RUNTIME_DIR, XDG_STATE_HOME and HOME pointed at a temporary directory, and
# with stand-ins ahead of `omarchy`, `omarchy-shell`,
# `omarchy-hyprland-session-locked`, `notify-send` and -- above all -- `setsid`,
# so `sync`'s detached restart is recorded rather than run.
#
# What it covers, in the order the plan states it:
#
#   §9.4  stage is byte-for-byte, through a dot-dir the watcher ignores
#   §9.4  sync writes NOTHING when the staged copy matches (inotify says so),
#         re-stages when it does not, and restarts only when the clone is enabled
#   §9.5  every verb that writes refuses for a live locker AND for the
#         compositor's flag -- and `disable --stranded` refuses only for the first
#   §9.3  enable's 10 s health check, and the recovery when nothing answers
#   §10.1 status reports `failed` whether or not the clone is still enabled,
#         which is what makes the Setup row visible on the paths that need it
#   §6.3  one notification per new reason, and never one per check
#
# The one thing it cannot do is enable a real clone in a real shell: `omarchy
# plugin enable` talks to the running shell over IPC and does not read
# XDG_CONFIG_HOME. dev/g6-lock-offscreen.sh covers the wrapper itself; the live
# swap is the part of the gate that needs a person (dev/README.md).

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LOCK=$REPO/bin/omarchy-face-lock

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

command -v jq >/dev/null || { echo "f6-lock: jq is not installed" >&2; exit 1; }

root=$(mktemp -d /tmp/omarchy-face-f6.XXXXXX)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root"/{bin,config/omarchy/plugins,run,home/.local/state}

PLUGINS=$root/config/omarchy/plugins
SHELL_JSON=$root/config/omarchy/shell.json
STAGED=$PLUGINS/graveklar.face-lock
STATUS=$root/run/omarchy-face/lock-status.json
NOTIFIED=$root/home/.local/state/omarchy-face/lock-notified
CONTROL=$root/control
CALLS=$root/calls.log

mkdir -p "$CONTROL"
printf 'unlocked\n' >"$CONTROL/locker"      # secure | requested | unlocked | silent
printf '1\n' >"$CONTROL/compositor"         # 0 locked · 1 unlocked · 2 undetermined
printf '{"plugins":[],"disabledPlugins":[]}\n' >"$SHELL_JSON"

# --- the stand-ins ------------------------------------------------------------

cat >"$root/bin/omarchy" <<STANDIN
#!/bin/bash
printf 'omarchy %s\n' "\$*" >>"$CALLS"
case "\$1 \$2" in
  "plugin validate")
    exec /usr/share/omarchy/bin/omarchy-plugin-validate "\$3" ;;
  "plugin enable")
    # What the registry does to shell.json for a clone (PluginRegistry.qml:540-555):
    # the clone goes into plugins[] and its source into disabledPlugins[].
    jq --arg id "\$3" '.plugins += [{id: \$id}]
                       | .disabledPlugins = ((.disabledPlugins // []) + ["omarchy.lock"] | unique)' \
      "$SHELL_JSON" >"$SHELL_JSON.tmp" && mv "$SHELL_JSON.tmp" "$SHELL_JSON"
    [[ -f "$CONTROL/enable_fails" ]] && exit 1
    exit 0 ;;
  "plugin disable")
    jq --arg id "\$3" '.plugins = [(.plugins // [])[] | select(.id != \$id)]
                       | .disabledPlugins = [((.disabledPlugins // [])[]) | select(. != "omarchy.lock")]' \
      "$SHELL_JSON" >"$SHELL_JSON.tmp" && mv "$SHELL_JSON.tmp" "$SHELL_JSON"
    exit 0 ;;
  "restart shell")
    # NEVER the real thing. This suite runs on somebody's desktop.
    exit 0 ;;
esac
exit 0
STANDIN

cat >"$root/bin/omarchy-shell" <<STANDIN
#!/bin/bash
printf 'omarchy-shell %s\n' "\$*" >>"$CALLS"
if [[ "\$1 \$2" == "lock status" ]]; then
  case \$(cat "$CONTROL/locker") in
    secure)    printf '{"locked":true,"requested":false,"secure":true}\n'; exit 0 ;;
    requested) printf '{"locked":true,"requested":true,"secure":false}\n'; exit 0 ;;
    unlocked)  printf '{"locked":false,"requested":false,"secure":false}\n'; exit 0 ;;
    *)         exit 1 ;;   # nothing answers: no lock service at all
  esac
fi
exit 0
STANDIN

cat >"$root/bin/omarchy-hyprland-session-locked" <<STANDIN
#!/bin/bash
exit \$(cat "$CONTROL/compositor")
STANDIN

cat >"$root/bin/notify-send" <<STANDIN
#!/bin/bash
printf 'notify-send %s\n' "\$*" >>"$CALLS"
exit 0
STANDIN

# The one stand-in that exists purely so this suite cannot hurt the machine.
cat >"$root/bin/setsid" <<STANDIN
#!/bin/bash
printf 'setsid %s\n' "\$*" >>"$CALLS"
exit 0
STANDIN

chmod +x "$root/bin"/*

run() { # run <verb…>
  env HOME="$root/home" XDG_CONFIG_HOME="$root/config" XDG_RUNTIME_DIR="$root/run" \
      XDG_STATE_HOME="$root/home/.local/state" PATH="$root/bin:$PATH" \
      "$LOCK" "$@" 2>/dev/null
}

locker() { printf '%s\n' "$1" >"$CONTROL/locker"; }
compositor() { printf '%s\n' "$1" >"$CONTROL/compositor"; }
calls() { cat "$CALLS" 2>/dev/null; }
reset_calls() { : >"$CALLS"; }

# Every write under the plugins folder reloads every bar widget (E13). Several
# clauses of the gate are "and nothing was written there", so they are measured
# the same way the shell measures it.
watch_plugins() { # watch_plugins <command…> -> prints the events
  local events=$root/events.log
  : >"$events"
  inotifywait -m -r -q -e close_write,create,delete,move --format '%w%f' "$PLUGINS" \
    >"$events" 2>/dev/null &
  local watcher=$!
  sleep 0.4
  "$@" >/dev/null 2>&1
  sleep 0.4
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  # Dot entries map to no plugin id, so the watcher ignores them
  # (PluginRegistry.qml:728-740); count what the shell would actually act on.
  grep -v "^$PLUGINS/\." "$events" | sed "s|^$PLUGINS/||" | cut -d/ -f1 | sort -u
}

echo "F6 — the lock screen verbs, in a throwaway plugins folder"
echo "${DIM}plugins: $PLUGINS${RESET}"

# =============================================================================
step "status, before anything is staged"
out=$(run status --json)
check "nothing staged, nothing enabled, nothing to report" \
  "false n/a  " "$(jq -r '"\(.enabled) \(.compat) \(.missing|join(",")) \(.otherLock)"' <<<"$out")"

# =============================================================================
step "GATE: stage puts the wrapper in place, byte for byte"
out=$(run stage)
check "it says it staged" "true" "$(jq -r '.ok' <<<"$out")"
check "…the folder is there" "true" "$([[ -d $STAGED ]] && echo true || echo false)"
diff -rq "$REPO/lock" "$STAGED" >/dev/null 2>&1
check "…and it is the template, byte for byte (no substitution, §9.2)" "0" "$?"
check "…with the manifest's version left a literal" "1.0.0" \
  "$(jq -r '.version' "$STAGED/manifest.json")"
check "…and the clone declared against Omarchy's own lock" "omarchy.lock" \
  "$(jq -r '.omarchy.clonedFrom' "$STAGED/manifest.json")"
check "…readable like any plugin folder" "755" "$(stat -c '%a' "$STAGED")"
check "no staging directory was left behind" "" \
  "$(compgen -G "$PLUGINS/.graveklar.face-lock.*" || true)"
/usr/share/omarchy/bin/omarchy-plugin-validate "$STAGED" >/dev/null 2>&1
check "Omarchy's own validation passes on what landed" "0" "$?"

step "staging over an existing folder replaces it and cleans up"
printf 'stale\n' >"$STAGED/leftover"
out=$(run stage)
check "it staged again" "true" "$(jq -r '.ok' <<<"$out")"
check "…and the leftover is gone" "false" \
  "$([[ -e $STAGED/leftover ]] && echo true || echo false)"
check "…with no .old directory left" "" \
  "$(compgen -G "$PLUGINS/.graveklar.face-lock.old.*" || true)"

# =============================================================================
step "GATE: sync writes nothing when the staged copy is current"
events=$(watch_plugins run sync)
check "not one event the plugin watcher would act on" "" "$events"
out=$(run sync)
check "…and it says so without claiming to have staged" "true|null" \
  "$(jq -r '"\(.ok)|\(.staged)"' <<<"$out")"
note "this is what stops a shell start re-staging and restarting for ever (§9.2)"

step "sync re-stages when a Face update changed the template"
printf '\n' >>"$STAGED/Service.qml"
out=$(run sync)
check "it staged" "true" "$(jq -r '.staged' <<<"$out")"
diff -rq "$REPO/lock" "$STAGED" >/dev/null 2>&1
check "…and the staged copy matches the template again" "0" "$?"
reset_calls
out=$(run sync)
check "…and the next sync writes nothing (no re-stage loop)" "null" \
  "$(jq -r '.staged' <<<"$out")"
check "…and asks for no restart" "" "$(calls | grep -c setsid | sed 's/^0$//')"

# F6 test 8's loop clause, as far as it can be run without restarting a real
# shell five times: five consecutive syncs after an update, none of which may
# stage or restart. A `stage` that rewrote one byte -- a version, a path -- would
# make every one of them differ, and with the clone enabled every shell start
# would restart the shell, for ever.
run enable >/dev/null
reset_calls
staged_again=0
for _ in 1 2 3 4 5; do
  [[ $(run sync | jq -r '.staged') == "true" ]] && staged_again=$((staged_again + 1))
done
check "five syncs in a row after the update stage nothing" "0" "$staged_again"
check "…and restart nothing" "0" "$(calls | grep -c '^setsid')"
run disable >/dev/null

# =============================================================================
step "GATE: enable and disable never write the plugins folder"
reset_calls
locker unlocked
events=$(watch_plugins run enable)
check "enabling wrote nothing under the plugins folder" "" "$events"
check "…it edited shell.json instead" "graveklar.face-lock" \
  "$(jq -r '.plugins[0].id // ""' "$SHELL_JSON")"
check "…and put Omarchy's own lock aside, the way the registry does (E4)" "omarchy.lock" \
  "$(jq -r '.disabledPlugins[0] // ""' "$SHELL_JSON")"
out=$(run status --json)
check "…so status says the clone is the lock screen" "true" "$(jq -r '.enabled' <<<"$out")"

events=$(watch_plugins run disable)
check "disabling wrote nothing either" "" "$events"
check "…and Omarchy's lock is back" "0" \
  "$(jq -r '(.disabledPlugins // []) | length' "$SHELL_JSON")"

step "sync restarts the shell only when the clone is enabled, and only detached"
run enable >/dev/null
printf '\n' >>"$STAGED/Service.qml"
reset_calls
out=$(run sync)
check "it asked for a restart" "requested" "$(jq -r '.restart' <<<"$out")"
check "…detached, outside the shell's process tree (§9.4)" "setsid -f omarchy restart shell" \
  "$(calls | grep '^setsid' | head -1)"
run disable >/dev/null
printf '\n' >>"$STAGED/Service.qml"
reset_calls
out=$(run sync)
check "with the clone off, a re-stage needs no restart at all" "true|null" \
  "$(jq -r '"\(.staged)|\(.restart)"' <<<"$out")"
check "…and nothing was detached" "0" "$(calls | grep -c '^setsid')"

# =============================================================================
step "GATE (§9.5): both questions refuse a verb that writes"
locker secure
compositor 1
for verb in stage sync enable disable; do
  check "a live locker refuses $verb" "locked" "$(run $verb | jq -r '.error')"
done
locker unlocked
compositor 0
for verb in stage sync enable disable; do
  check "the compositor's flag refuses $verb" "locked" "$(run $verb | jq -r '.error')"
done
locker unlocked
compositor 1

# =============================================================================
step "enable refuses before it changes anything"
mv "$STAGED" "$root/held"
check "a folder that was never staged" "not_staged" "$(run enable | jq -r '.error')"
mv "$root/held" "$STAGED"

mkdir -p "$PLUGINS/somebody.else-lock"
cat >"$PLUGINS/somebody.else-lock/manifest.json" <<'OTHER'
{"schemaVersion":1,"id":"somebody.else-lock","name":"Another lock","version":"1.0.0",
 "kinds":["service"],"entryPoints":{"service":"Service.qml"},
 "omarchy":{"clonedFrom":"omarchy.lock"}}
OTHER
out=$(run enable)
check "another lock plugin that is merely INSTALLED blocks nothing" "true" "$(jq -r '.ok' <<<"$out")"
run disable >/dev/null
jq '.plugins += [{id:"somebody.else-lock"}]' "$SHELL_JSON" >"$SHELL_JSON.tmp" &&
  mv "$SHELL_JSON.tmp" "$SHELL_JSON"
out=$(run enable)
check "…but an ENABLED one is refused, by name" "other_lock somebody.else-lock" \
  "$(jq -r '"\(.error) \(.id)"' <<<"$out")"
out=$(run status --json)
check "…and status says so rather than blaming the wrapper" "n/a somebody.else-lock" \
  "$(jq -r '"\(.compat) \(.otherLock)"' <<<"$out")"
jq '.plugins = [(.plugins[] | select(.id != "somebody.else-lock"))]' "$SHELL_JSON" >"$SHELL_JSON.tmp" &&
  mv "$SHELL_JSON.tmp" "$SHELL_JSON"
rm -rf "$PLUGINS/somebody.else-lock"

# =============================================================================
step "GATE: a wrapper that never comes up is taken back out (§9.3, §9.3a)"
run disable >/dev/null
rm -f "$STATUS"
# The runtime case of §9.3: the owner moved the switch on an unlocked session
# and the wrapper does not compile, so nothing answers `lock status` and there
# is no lock service at all until the recovery runs.
locker silent
compositor 1
reset_calls
start=$SECONDS
out=$(run enable)
elapsed=$((SECONDS - start))
check "enable gives up and says so" "enable_failed" "$(jq -r '.error' <<<"$out")"
check "…inside its ten seconds" "true" "$([[ $elapsed -ge 9 && $elapsed -le 16 ]] && echo true || echo false)"
note "took ${elapsed}s"
check "…having put Omarchy's own lock screen back, whatever the compositor says" "1" \
  "$(calls | grep -c 'omarchy plugin disable graveklar.face-lock')"
check "…and the clone really is off in shell.json" "0" \
  "$(jq -r '(.plugins // []) | length' "$SHELL_JSON")"
check "…with the reason written where the Setup row reads it" "failed" \
  "$(jq -r '.compat' "$STATUS")"
check "…in words" "no lock service answered" "$(jq -r '.missing[0]' "$STATUS")"

step "GATE: the health check's recovery, run by the Face service"
run enable >/dev/null 2>&1
rm -f "$STATUS"
reset_calls
locker silent
compositor 0
out=$(run disable --stranded)
check "it disables regardless of Hyprland's lock flag (§9.3a)" "true true" \
  "$(jq -r '"\(.ok) \(.recovered)"' <<<"$out")"
check "…and writes failed" "failed" "$(jq -r '.compat' "$STATUS")"
note "disabling is what re-creates Omarchy's stock lock service, whose own"
note "checkStrandedLock puts a password field over the orphaned compositor lock"

step "GATE: a locker that DOES answer is never destroyed"
run enable >/dev/null 2>&1
reset_calls
locker secure
compositor 0
out=$(run disable --stranded)
check "the recovery refuses" "live_locker" "$(jq -r '.error' <<<"$out")"
check "…and nothing was disabled" "0" "$(calls | grep -c 'plugin disable')"
note "destroying a live locker is the crashed-lockscreen fallback (shell.qml:1030-1032)"
locker unlocked
compositor 1
run disable >/dev/null

# =============================================================================
step "GATE (§10.1): status reports failed even with the clone switched off"
now=$(($(date +%s%N) / 1000000))
mkdir -p "$(dirname "$STATUS")"
printf '{"compat":"failed","missing":["no lock service answered"],"at":%s}\n' "$now" >"$STATUS"
out=$(run status --json)
check "the clone is off…" "false" "$(jq -r '.enabled' <<<"$out")"
check "…and the reason is still reported, so the Setup row renders" "failed" \
  "$(jq -r '.compat' <<<"$out")"
note "keying this on enablement would hide the row on the two paths that need it"

step "a verdict from before this shell started is not a verdict"
printf '{"compat":"ok","missing":[],"at":1}\n' >"$STATUS"
run enable >/dev/null
out=$(run status --json)
if pgrep -x -u "$(id -u)" quickshell >/dev/null 2>&1; then
  check "an 'ok' written before the running shell started is ignored" "loading" \
    "$(jq -r '.compat' <<<"$out")"
else
  note "no quickshell is running, so the freshness rule has no shell to measure against"
fi
now=$(($(date +%s%N) / 1000000))
printf '{"compat":"ok","missing":[],"at":%s}\n' "$now" >"$STATUS"
out=$(run status --json)
check "…and a fresh one is taken" "ok" "$(jq -r '.compat' <<<"$out")"
run disable >/dev/null

# =============================================================================
step "GATE: one notification per reason, never one per check"
reset_calls
rm -f "$NOTIFIED"
out=$(run notify-once "failed|no lock service answered" "Omarchy's own lock screen is back.")
check "the first time, it is said" "true" "$(jq -r '.said' <<<"$out")"
check "…once" "1" "$(calls | grep -c '^notify-send')"
for _ in 1 2 3 4 5; do run notify-once "failed|no lock service answered" "again" >/dev/null; done
check "…and five more checks with the same reason say nothing" "1" \
  "$(calls | grep -c '^notify-send')"
out=$(run notify-once "incompatible|pendingSessionLock" "Omarchy's lock screen changed.")
check "a NEW reason is worth one more" "true" "$(jq -r '.said' <<<"$out")"
check "…and only one" "2" "$(calls | grep -c '^notify-send')"
check "the last reason is remembered on disk, so a restart does not repeat it" \
  "incompatible|pendingSessionLock" "$(cat "$NOTIFIED")"

echo
if ((failures == 0)); then
  echo "${GREEN}F6 gate passes.${RESET} ${DIM}$checks checks.${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
