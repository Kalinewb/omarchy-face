#!/bin/bash

# G11: switching the lock screen on survives a cold start (D6).
#
#   ./dev/g11-lock-enable.sh
#
# At every shell start the journal said `the lock screen could not be switched
# on: enable_failed`, and a moment later the clone was enabled and answering.
# `enable` was asking too early and giving up too soon: three tries in 1.5 s
# while the registry was still scanning, then ten seconds for a lock service
# that a cold start can take longer than that to create. Now it backs off for
# about 12 s and waits 30 s for an answer, the Face service's own window.
#
# Same sandbox as dev/f6-lock.sh: XDG_CONFIG_HOME, XDG_RUNTIME_DIR,
# XDG_STATE_HOME and HOME in a temporary directory, and stand-ins ahead of
# `omarchy`, `omarchy-shell`, `omarchy-hyprland-session-locked` and `setsid`, so
# nothing here reaches the running shell. Takes about a minute, most of it the
# 30 s case waiting for the answer that never comes.

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

command -v jq >/dev/null || { echo "g11-lock-enable: jq is not installed" >&2; exit 1; }
command -v inotifywait >/dev/null || { echo "g11-lock-enable: inotifywait is not installed" >&2; exit 1; }

root=$(mktemp -d /tmp/omarchy-face-g11.XXXXXX)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root"/{bin,config/omarchy/plugins,run,home/.local/state,control}

PLUGINS=$root/config/omarchy/plugins
SHELL_JSON=$root/config/omarchy/shell.json
CONTROL=$root/control
CALLS=$root/calls.log

now_ms() { printf '%s' "$(($(date +%s%N) / 1000000))"; }

# Two moments, in milliseconds since the epoch: until `enable_at` the registry
# answers "is not known", and until `answer_at` nothing answers `lock status`.
# Empty means never.
at() { # at <name> <seconds from now | never>
  if [[ $2 == never ]]; then : >"$CONTROL/$1"; else printf '%s\n' "$(($(now_ms) + $2 * 1000))" >"$CONTROL/$1"; fi
}

# --- the stand-ins ------------------------------------------------------------

cat >"$root/bin/omarchy" <<STANDIN
#!/bin/bash
printf 'omarchy %s\n' "\$*" >>"$CALLS"
now=\$((\$(date +%s%N) / 1000000))
case "\$1 \$2" in
  "plugin validate")
    exec /usr/share/omarchy/bin/omarchy-plugin-validate "\$3" ;;
  "plugin enable")
    when=\$(cat "$CONTROL/enable_at" 2>/dev/null)
    if [[ -z \$when ]] || ((now < when)); then
      echo "Plugin \$3 is not known" >&2
      exit 1
    fi
    jq --arg id "\$3" '.plugins += [{id: \$id}]
                       | .disabledPlugins = ((.disabledPlugins // []) + ["omarchy.lock"] | unique)' \
      "$SHELL_JSON" >"$SHELL_JSON.tmp" && mv "$SHELL_JSON.tmp" "$SHELL_JSON"
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
  now=\$((\$(date +%s%N) / 1000000))
  when=\$(cat "$CONTROL/answer_at" 2>/dev/null)
  [[ -n \$when ]] && ((now >= when)) || exit 1
  printf '{"locked":false,"requested":false,"secure":false}\n'
fi
exit 0
STANDIN

cat >"$root/bin/omarchy-hyprland-session-locked" <<'STANDIN'
#!/bin/bash
exit 1
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

fresh_shell_json() { printf '{"plugins":[],"disabledPlugins":[]}\n' >"$SHELL_JSON"; }
calls() { cat "$CALLS" 2>/dev/null; }

echo "G11 — the lock screen switch at a cold start, in a throwaway plugins folder"
echo "${DIM}plugins: $PLUGINS${RESET}"

fresh_shell_json
at enable_at 0
at answer_at 0
out=$(run stage)
[[ $(jq -r '.staged' <<<"$out" 2>/dev/null) == true ]] || {
  echo "  ${RED}FAIL${RESET}  could not stage the wrapper to start from: $out"
  exit 1
}

# =============================================================================
step "GATE: the registry says 'not known' for 4 s and the lock answers at 12 s"
fresh_shell_json
: >"$CALLS"
at enable_at 4
at answer_at 12
start=$SECONDS
out=$(run enable)
elapsed=$((SECONDS - start))
# One check per case, so the gate reads as the plan states it (3/3).
check "enable waits it out: on, in shell.json, and Omarchy's lock not given back" \
  "true|graveklar.face-lock|0" \
  "$(jq -r '.enabled' <<<"$out")|$(jq -r '.plugins[0].id // ""' "$SHELL_JSON")|$(calls | grep -c 'omarchy plugin disable')"
note "took ${elapsed}s, with $(calls | grep -c 'omarchy-shell shell rescanPlugins') rescans; the old 3 × 0.5 s gave up after 1.5 s"

# =============================================================================
step "GATE: nothing answers for 31 s"
fresh_shell_json
rm -f "$root/run/omarchy-face/lock-status.json"
: >"$CALLS"
at enable_at 0
at answer_at never
start=$SECONDS
out=$(run enable)
elapsed=$((SECONDS - start))
check "enable gives up after thirty seconds, not ten, and gives Omarchy's lock back" \
  "enable_failed|true|1|0" \
  "$(jq -r '.error' <<<"$out")|$([[ $elapsed -ge 29 && $elapsed -le 36 ]] && echo true || echo false)|$(calls | grep -c 'omarchy plugin disable graveklar.face-lock')|$(jq -r '(.plugins // []) | length' "$SHELL_JSON")"
note "took ${elapsed}s"

# =============================================================================
step "GATE: sync with the staged folder already current writes nothing"
at answer_at 0
events=$root/events.log
inotifywait -m -r -q -e close_write,create,delete,move --format '%w%f' "$PLUGINS" >"$events" 2>/dev/null &
watcher=$!
sleep 0.4
out=$(run sync)
sleep 0.4
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
check "sync answers ok, stages nothing, and touches nothing under the plugins folder" \
  "true null|" "$(jq -r '"\(.ok) \(.staged)"' <<<"$out")|$(cat "$events")"

echo
if ((failures == 0)); then
  echo "${GREEN}G11 passes.${RESET} ${DIM}$checks checks.${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
