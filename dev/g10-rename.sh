#!/bin/bash

# G10: Face's rename from graveklar.face to kalinewb.face, run for real against
# a sandbox HOME (plan-suite.md §3.4 and Phase 2R, review-round1.md B1).
#
#   ./dev/g10-rename.sh            every case
#   G10_BLESS=1 ./dev/g10-rename.sh  also rewrite dev/fixtures/rename/after/
#                                    from T6's result (then read the diff)
#   G10_KEEP=1 ./dev/g10-rename.sh   keep the sandbox afterwards, to look at
#
# Round 1 found the failure this suite exists for: a Face whose manifest says
# kalinewb.face, in a shell.json that names only graveklar.face, is installed and
# OFF -- Omarchy enables only ids shell.json names (PluginRegistry.qml:148-164),
# and runs services only for enabled ids (shell.qml:964). So the cases do not
# stop at "the strings changed": each one asks the question Omarchy asks, with
# a jq copy of that rule (ENABLED below, from PluginRegistry.qml:148-164 and
# :231-249), against the plugins actually in the sandbox's folder.
#
# The rename really runs: bin/omarchy-face-rename from a copy of this checkout,
# installed into a throwaway plugins folder, with the real omarchy-shell-config
# writing shell.json and the real lock helper staging the new wrapper. What
# is stood in for is everything that would reach the live desktop:
#
#   omarchy                          records; `restart shell` is refused while the
#                                    case's `locked` file exists, as the real one
#                                    refuses behind a lock screen
#   omarchy-shell                    records; `shell reloadConfig` -- which every
#                                    shell.json commit ends in -- copies the file
#                                    it just wrote, with the lock clones installed
#                                    at that moment, so every write can be checked
#   omarchy-hyprland-session-locked  "locked" while that file exists
#
# Every copy of Face's bin/ scripts is instrumented with one line that records
# `facebin <name>` when it runs, which is how T4 sees that nothing of Face's ran
# after the restart.
#
# Nothing here touches ~/.config/omarchy, ~/.local/state or the running shell:
# every run is `env -i` with HOME, the XDG directories and the runtime directory
# inside a temporary folder, and a PATH of the stand-ins in front of /usr/bin
# only. The last check compares this account's own files before and after.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
DIM=$'\e[2m'
BOLD=$'\e[1m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURES=$REPO/dev/fixtures/rename

checks=0
failures=0
cases=0
cases_failed=0
case_bad=0

check() { # check <description> <expected> <actual>
  checks=$((checks + 1))
  if [[ $2 == "$3" ]]; then
    echo "  ${GREEN}pass${RESET}  $1"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected '$2', got '$3')${RESET}"
    failures=$((failures + 1))
    case_bad=1
  fi
}

begin() { echo; echo "${BOLD}$1${RESET}  ${DIM}$2${RESET}"; case_bad=0; }
end() { cases=$((cases + 1)); ((case_bad)) && cases_failed=$((cases_failed + 1)); }
yes_no() { "$@" >/dev/null 2>&1 && echo true || echo false; }

for tool in jq rsync git setsid flock quickshell; do
  command -v "$tool" >/dev/null || { echo "g10: $tool is not installed" >&2; exit 1; }
done
OMARCHY_BIN=${OMARCHY_PATH:-/usr/share/omarchy}/bin
[[ -f $OMARCHY_BIN/omarchy-shell-config ]] || { echo "g10: no omarchy-shell-config in $OMARCHY_BIN" >&2; exit 1; }

# This account's own files, before: whatever they are, they must be so after.
real_state() {
  {
    stat -c '%n %i %s %Y' "$HOME/.config/omarchy/shell.json" 2>/dev/null
    ls -A "$HOME/.config/omarchy/plugins" 2>/dev/null
    ls -A "$HOME/.local/state/omarchy-face" 2>/dev/null
    stat -c '%n %i %Y' "$HOME"/.config/omarchy/hooks/*/*face* 2>/dev/null
    find "$HOME/.config/omarchy/profiles" -maxdepth 1 -printf '%f %T@\n' 2>/dev/null | sort
  } | sha256sum
}
REAL_BEFORE=$(real_state)

root=$(mktemp -d /tmp/omarchy-face-g10.XXXXXX)
cleanup() {
  # A detached rename still waiting for an unlock would outlive the suite.
  pkill -f -- "$root" 2>/dev/null
  if [[ ${G10_KEEP:-} == 1 ]]; then echo "${DIM}kept: $root${RESET}"; else rm -rf "$root"; fi
}
trap cleanup EXIT

# --- stand-ins ---------------------------------------------------------------

stubs=$root/stubs
mkdir -p "$stubs"
cat >"$stubs/omarchy" <<'STUB'
#!/bin/bash
W=${G10_WORLD:?}
if [[ "$1 ${2:-}" == "restart shell" ]]; then
  if [[ -e $W/locked ]]; then echo "restart refused" >>"$W/calls"; exit 1; fi
  echo "restart shell | $(ls "$HOME/.config/omarchy/plugins" 2>/dev/null | tr '\n' ' ')" >>"$W/calls"
  exit 0
fi
echo "omarchy $*" >>"$W/calls"
exit 0
STUB
cat >"$stubs/omarchy-shell" <<'STUB'
#!/bin/bash
W=${G10_WORLD:?}
echo "omarchy-shell $*" >>"$W/calls"
# No IPC target answers: `lock status` is "nothing is drawing a lock screen".
[[ "$1 ${2:-}" == "shell reloadConfig" ]] || exit 1
n=$(printf '%03d' $(($(find "$W/writes" -name '*.json' | wc -l) + 1)))
cp "$HOME/.config/omarchy/shell.json" "$W/writes/$n.json"
for m in "$HOME"/.config/omarchy/plugins/*/manifest.json; do
  jq -r 'select((.omarchy.clonedFrom // "") == "omarchy.lock") | .id' "$m" 2>/dev/null
done >"$W/writes/$n.clones"
[[ -e $W/lock-at-commit ]] && touch "$W/locked"
[[ -s $W/kill-pgid ]] && kill -TERM -- "-$(cat "$W/kill-pgid")" 2>/dev/null
exit 0
STUB
printf '#!/bin/bash\n[[ -e ${G10_WORLD:?}/locked ]]\n' >"$stubs/omarchy-hyprland-session-locked"
for name in notify-send omarchy-notification-send; do
  printf '#!/bin/bash\necho "%s $*" >>"${G10_WORLD:?}/calls"\nexit 0\n' "$name" >"$stubs/$name"
done
cp "$OMARCHY_BIN/omarchy-shell-config" "$stubs/"
chmod 0755 "$stubs"/*

# --- the plugins under test --------------------------------------------------

# 3.0.0, as install.sh would leave it, with every bin/ script recording itself.
FACE30=$root/face30
rsync -a --exclude .git --exclude dev --exclude install.sh --exclude '*.bak' --exclude '*.bak.*' \
  "$REPO/" "$FACE30/"
# shellcheck disable=SC2016
printf '%s\n' '[[ -n ${G10_WORLD:-} ]] && printf '"'"'facebin %s\n'"'"' "${0##*/}" >>"$G10_WORLD/calls"' >"$root/probe"
for f in "$FACE30"/bin/*; do sed -i "1r $root/probe" "$f"; done

# A 2.2.0 stand-in: the same tree under the old id and version. Only its
# manifest and its rename helper are ever asked anything, and 2.2.0 ships the
# same helper as 3.0.0.
FACE22=$root/face22
cp -a "$FACE30" "$FACE22"
jq '.id = "graveklar.face" | .version = "2.2.0"' "$FACE30/manifest.json" >"$FACE22/manifest.json"

# The lock screen wrapper a 2.x Face staged.
OLDLOCK=$root/oldlock
cp -a "$REPO/lock" "$OLDLOCK"
jq '.id = "graveklar.face-lock"' "$REPO/lock/manifest.json.in" >"$OLDLOCK/manifest.json"
rm -f "$OLDLOCK/manifest.json.in"

# The shell.json every case starts from unless it says otherwise: the notch's
# bar with Face on its right and in its hosted panels, and Face's lock screen on.
T1_SHELL=$root/t1-shell.json
jq . >"$T1_SHELL" <<'JSON'
{"version": 1,
 "bar": {"id": "kalinewb.notch",
         "layout": {"left": [], "center": [{"id": "kalinewb.notch-menu"}],
                    "right": [{"id": "x.clock"}, {"id": "graveklar.face"}, {"id": "x.battery"}]},
         "notch": {"hostedPanels": ["x.wifi", "graveklar.face"]}},
 "plugins": [{"id": "x.service"}, {"id": "graveklar.face-lock"}],
 "disabledPlugins": ["omarchy.lock", "omarchy.menu"],
 "cloneSourceRestores": ["graveklar.face-lock", "kalinewb.notch-menu"]}
JSON

# --- a world per case ----------------------------------------------------------

world() { # world <name> -> W, H, P, SJ, SNAP
  W=$root/w-$1
  H=$W/home
  P=$H/.config/omarchy/plugins
  SJ=$H/.config/omarchy/shell.json
  SNAP=$H/.local/state/omarchy-face/rename
  mkdir -p "$W/writes" "$W/run" "$P" "$H/.local/state" \
           "$H/.config/omarchy/hooks/post-boot.d" "$H/.config/omarchy/hooks/post-update.d"
  : >"$W/calls"
}

# What every Face from 2.0 on left in the hooks folder: bin/omarchy-face-health's
# hook_text, under the old id.
old_hooks() {
  local verb
  for verb in post-update post-boot; do
    cat >"$H/.config/omarchy/hooks/$verb.d/graveklar-face.hook" <<HOOK
#!/bin/bash
#
# Face ID (graveklar.face): check that face unlock still works after $verb.

health=\$HOME/.config/omarchy/plugins/graveklar.face/bin/omarchy-face-health

if [[ ! -x \$health ]]; then
  rm -f -- "\$0"
  exit 0
fi

"\$health" $verb || true
exit 0
HOOK
    chmod 0755 "$H/.config/omarchy/hooks/$verb.d/graveklar-face.hook"
  done
}

# The common start: 3.0.0 landed in the old folder (path b's state after the
# update), the old wrapper is the lock screen, the old hooks are in place.
seed() { # seed <name> [shell.json]
  world "$1"
  rsync -a "$FACE30/" "$P/graveklar.face/"
  cp -a "$OLDLOCK" "$P/graveklar.face-lock"
  cp "${2:-$T1_SHELL}" "$SJ"
  old_hooks
}

sandbox() { # sandbox <command…>: run in the current world
  env -i HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" \
    XDG_RUNTIME_DIR="$W/run" OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}" \
    PATH="$stubs:/usr/bin" LC_ALL=C G10_WORLD="$W" \
    OMARCHY_FACE_RENAME_POLL=0.2 OMARCHY_FACE_RENAME_ADMIN="$W/admin" "$@"
}

rn() { # rn <plugin folder> <args…>: that folder's rename helper
  local dir=$1
  shift
  sandbox "$dir/bin/omarchy-face-rename" "$@"
}

field() { jq -r ".$1 // \"\"" <<<"$2" 2>/dev/null; }
writes() { find "$W/writes" -name '*.json' | wc -l; }
restarts() { grep -c '^restart shell' "$W/calls"; }
wait_for() { # wait_for <pattern> [tenths]
  local i
  for ((i = 0; i < ${2:-100}; i++)); do
    grep -q "$1" "$W/calls" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# Enabled, as Omarchy decides it for a third-party plugin: installed (some
# folder's manifest has the id), not in disabledPlugins, and named as the bar,
# in the bar layout or in plugins[].
ENABLED='
  def entry_id: if type == "object" then (.id // "") elif type == "string" then . else "" end;
  (((.disabledPlugins // []) | index($id)) == null)
  and (((.bar.id // "") == $id)
       or ([(.bar.layout // {}) | (.left, .center, .right) | arrays | .[] | entry_id] | index($id) != null)
       or ([(.plugins // [])[] | entry_id] | index($id) != null))'
installed() { local m; for m in "$P"/*/manifest.json; do jq -r '.id // empty' "$m"; done; }
enabled() { # enabled <id> [shell.json]
  # Not `installed | grep -q`: under pipefail, grep leaving early fails the pipe.
  grep -xF -- "$1" <<<"$(installed)" >/dev/null || { echo false; return; }
  jq -r --arg id "$1" "$ENABLED" "${2:-$SJ}"
}
names_old() { jq -e 'any((.. | strings), (.. | objects | keys[]); . == "graveklar.face" or . == "graveklar.face-lock")' "$1" >/dev/null 2>&1 && echo true || echo false; }
listing() { ls -A "$P" | tr '\n' ' '; }

echo "${BOLD}G10 — Face's rename, in a sandbox HOME${RESET}"
echo "${DIM}repo: $REPO   sandbox: $root${RESET}"

# =============================================================================
seed basic
out=$(rn "$P/graveklar.face" --repair)
wait_for '^restart shell' || true
sleep 0.5

begin T1 "shell.json naming only graveklar.face, folder at 3.0.0: --repair leaves kalinewb.face enabled, in place"
check "the helper says it renamed" "renamed|move" "$(field state "$out")|$(field case "$out")"
check "kalinewb.face is enabled, as Omarchy decides it" true "$(enabled kalinewb.face)"
check "…in the old layout slot" '[{"id":"x.clock"},{"id":"kalinewb.face"},{"id":"x.battery"}]' \
  "$(jq -c .bar.layout.right "$SJ")"
check "…and the old hostedPanels slot" '["x.wifi","kalinewb.face"]' "$(jq -c .bar.notch.hostedPanels "$SJ")"
check "the folder has the new name, and only the new name" "kalinewb.face kalinewb.face-lock x" \
  "$(listing | sed 's/ $/ x/')"
end

begin T2 "the old clone is moved and named nowhere; the new one is the lock screen"
check "graveklar.face-lock is no longer installed" false "$(yes_no test -e "$P/graveklar.face-lock")"
check "…it is in the snapshot" true "$(yes_no test -f "$SNAP/graveklar.face-lock/manifest.json")"
check "shell.json names no old id anywhere" false "$(names_old "$SJ")"
check "kalinewb.face-lock is enabled" true "$(enabled kalinewb.face-lock)"
check "omarchy.lock stays disabled" true "$(jq -e '.disabledPlugins | index("omarchy.lock") != null' "$SJ" >/dev/null && echo true || echo false)"
check "cloneSourceRestores is swapped in place" '["kalinewb.face-lock","kalinewb.notch-menu"]' \
  "$(jq -c .cloneSourceRestores "$SJ")"
check "the old hooks are out of the hooks folder, and in the snapshot" "0|2" \
  "$(find "$H/.config/omarchy/hooks" -name 'graveklar-face.hook' | wc -l)|$(find "$SNAP/hooks" -name 'graveklar-face.hook' | wc -l)"
end

begin T3 "every recorded shell.json names exactly one installed lock clone"
check "the rename wrote shell.json once" 1 "$(writes)"
bad=0
for record in "$W"/writes/*.json; do
  named=0
  while IFS= read -r clone; do
    [[ -n $clone ]] || continue
    [[ $(jq -r --arg id "$clone" "$ENABLED" "$record") == true ]] && named=$((named + 1))
  done <"${record%.json}.clones"
  ((named == 1)) || bad=$((bad + 1))
done
check "…and every write named exactly one of the clones installed at that moment" 0 "$bad"
end

begin T4 "one restart, after the last move, and no Face bin/ call after it"
check "one restart" 1 "$(restarts)"
check "…with both old folders already gone when it ran" "false|false" \
  "$(grep '^restart shell' "$W/calls" | grep -q ' graveklar.face ' && echo true || echo false)|$(grep '^restart shell' "$W/calls" | grep -q 'graveklar.face-lock' && echo true || echo false)"
check "…and nothing of Face's ran after it" 0 \
  "$(awk '/^restart shell/ { after = 1; next } after && /^facebin/ { n++ } END { print n + 0 }' "$W/calls")"
end
BASIC_W=$W BASIC_SJ=$SJ

# =============================================================================
begin T5 "--prename (2.2.0), then 3.0.0 lands, then --finish: ends as T1"
world bridge
rsync -a "$FACE22/" "$P/graveklar.face/"
cp -a "$OLDLOCK" "$P/graveklar.face-lock"
cp "$T1_SHELL" "$SJ"
old_hooks
out=$(rn "$P/graveklar.face" --prename)
check "2.2.0 marks the new id" "marked|1" "$(field state "$out")|$(writes)"
check "…once: a second --prename writes nothing" "nothing|1" "$(field state "$(rn "$P/graveklar.face" --prename)")|$(writes)"
check "…and while 2.2.0 is installed, the marker enables nothing" false "$(enabled kalinewb.face)"
rsync -a --delete "$FACE30/" "$P/graveklar.face/"
check "3.0.0 in the old folder starts enabled, by the marker" true "$(enabled kalinewb.face)"
out=$(rn "$P/graveklar.face" --finish)
check "--finish answers 'renaming' and goes on detached" renaming "$(field state "$out")"
wait_for '^restart shell' || true
sleep 0.3
check "it ends exactly as T1 did" "$(cat "$BASIC_SJ")" "$(cat "$SJ")"
check "…with one restart" 1 "$(restarts)"
end

# =============================================================================
begin T6 "the golden fixture: every step-4 key, an object key, profiles and config.json"
world golden
rsync -a "$FACE30/" "$P/graveklar.face/"
cp -a "$OLDLOCK" "$P/graveklar.face-lock"
cp "$FIXTURES/before/shell.json" "$SJ"
mkdir -p "$H/.config/omarchy/profiles"
cp "$FIXTURES"/before/profiles/*.json "$H/.config/omarchy/profiles/"
out=$(rn "$P/graveklar.face" --repair)
wait_for '^restart shell' || true
if [[ ${G10_BLESS:-} == 1 ]]; then
  mkdir -p "$FIXTURES/after/profiles"
  cp "$SJ" "$FIXTURES/after/shell.json"
  cp "$H"/.config/omarchy/profiles/*.json "$FIXTURES/after/profiles/"
  echo "  ${DIM}blessed: dev/fixtures/rename/after/ rewritten — read the diff${RESET}"
fi
check "shell.json comes out byte for byte" true "$(yes_no cmp -s "$SJ" "$FIXTURES/after/shell.json")"
for f in "$FIXTURES"/before/profiles/*.json; do
  name=${f##*/}
  check "profiles/$name comes out byte for byte" true \
    "$(yes_no cmp -s "$H/.config/omarchy/profiles/$name" "$FIXTURES/after/profiles/$name")"
done
check "a profile that never named Face was not rewritten at all" true \
  "$(yes_no cmp -s "$H/.config/omarchy/profiles/quiet.json" "$FIXTURES/before/profiles/quiet.json")"
end

# =============================================================================
begin T7 "a disabled Face stays disabled"
jq '.disabledPlugins += ["graveklar.face"]' "$T1_SHELL" >"$root/t7-shell.json"
seed disabled "$root/t7-shell.json"
out=$(rn "$P/graveklar.face" --repair)
wait_for '^restart shell' || true
check "renamed" renamed "$(field state "$out")"
check "kalinewb.face is installed and NOT enabled" "true|false" \
  "$(grep -xF kalinewb.face <<<"$(installed)" >/dev/null && echo true || echo false)|$(enabled kalinewb.face)"
check "…because disabledPlugins carries the new id in the old one's place" \
  '["omarchy.lock","omarchy.menu","kalinewb.face"]' "$(jq -c .disabledPlugins "$SJ")"
end

# =============================================================================
begin T8 "locked, local edits, Profiles' lock held or switch.json present: nothing written"
refused() { # refused <label> <expected error> <expected exit>
  local before after rc
  before=$(listing)
  cp "$SJ" "$W/before.json"
  out=$(rn "$P/graveklar.face" --repair)
  rc=$?
  after=$(listing)
  check "$1: refused" "$2|$3" "$(field error "$out")|$rc"
  check "$1: shell.json, the plugins folder, the snapshot: untouched" "true|true|false|0|0" \
    "$(yes_no cmp -s "$SJ" "$W/before.json")|$([[ $before == "$after" ]] && echo true || echo false)|$(yes_no test -e "$SNAP")|$(writes)|$(restarts)"
}
seed locked
touch "$W/locked"
refused "locked" locked 1

seed edits
(cd "$P/graveklar.face" && git init -q && git add -A &&
  git -c user.name=g10 -c user.email=g10@localhost commit -qm 3.0.0 && echo edit >>README.md)
refused "local edits" local_edits 1

seed profiles-lock
mkdir -p "$H/.local/state/omarchy-profiles"
(exec 7>"$H/.local/state/omarchy-profiles/.lock" && flock -n 7 && sleep 5) &
holder=$!
sleep 0.3
refused "Profiles' lock held" profiles_busy 3
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

seed profiles-switch
mkdir -p "$H/.local/state/omarchy-profiles"
echo '{}' >"$H/.local/state/omarchy-profiles/switch.json"
refused "switch.json present" profiles_busy 3
end

# =============================================================================
begin T9 "idempotent"
W=$BASIC_W H=$W/home P=$H/.config/omarchy/plugins SJ=$H/.config/omarchy/shell.json SNAP=$H/.local/state/omarchy-face/rename
cp "$SJ" "$W/again.json"
out=$(rn "$P/kalinewb.face" --repair)
check "a second --repair finds nothing to do" nothing "$(field state "$out")"
out=$(rn "$P/kalinewb.face" --finish)
check "…and so does --finish" nothing "$(field state "$out")"
check "…and the boot hook's form says nothing at all" "" "$(rn "$P/kalinewb.face" --repair --if-needed)"
sleep 0.5
check "no write, no restart" "true|1|1" "$(yes_no cmp -s "$SJ" "$W/again.json")|$(writes)|$(restarts)"
check "--check agrees" '{"needed":false,"reason":""}' "$(rn "$P/kalinewb.face" --check)"
end

# =============================================================================
begin T10 "--rollback is byte-exact, and graveklar.face is enabled again"
world rollback
# A git checkout that `omarchy plugin update` fast-forwarded from 2.2.0 to 3.0.0:
# ORIG_HEAD is where it came from.
face=$P/graveklar.face
rsync -a "$FACE22/" "$face/"
(cd "$face" && git init -q && git add -A && git -c user.name=g10 -c user.email=g10@localhost commit -qm 2.2.0 &&
  git -c user.name=g10 -c user.email=g10@localhost tag -a v2.2.0 -m 2.2.0)
from=$(git -C "$face" rev-parse HEAD)
rsync -a --delete --exclude .git "$FACE30/" "$face/"
(cd "$face" && git add -A && git -c user.name=g10 -c user.email=g10@localhost commit -qm 3.0.0 &&
  git update-ref ORIG_HEAD "$from")
cp -a "$OLDLOCK" "$P/graveklar.face-lock"
cp "$T1_SHELL" "$SJ"
mkdir -p "$H/.config/omarchy/profiles"
cp "$FIXTURES"/before/profiles/*.json "$H/.config/omarchy/profiles/"
old_hooks
cp -a "$H" "$W/home-before"
out=$(rn "$face" --repair)
wait_for '^restart shell' || true
check "renamed, remembering where it came from" "renamed|$from" "$(field state "$out")|$(cat "$SNAP/from" 2>/dev/null)"
out=$(rn "$P/kalinewb.face" --rollback)
check "rolled back, to that commit" "rolledback|$from" \
  "$(field state "$out")|$(git -C "$face" rev-parse HEAD 2>/dev/null)"
check "shell.json is byte for byte what it was" true "$(yes_no cmp -s "$SJ" "$W/home-before/.config/omarchy/shell.json")"
check "…and so is every profile" true \
  "$(yes_no diff -r "$H/.config/omarchy/profiles" "$W/home-before/.config/omarchy/profiles")"
check "…and the hooks" true "$(yes_no diff -r "$H/.config/omarchy/hooks" "$W/home-before/.config/omarchy/hooks")"
check "the plugins folder is as it was" "graveklar.face graveklar.face-lock " "$(listing)"
check "graveklar.face is enabled again" true "$(enabled graveklar.face)"
check "…and its lock clone" true "$(enabled graveklar.face-lock)"
check "a second restart, for the rollback" 2 "$(wait_for 'x' 1; restarts)"
end

# =============================================================================
begin T11 "a held lock exits 0, and writes nothing"
seed held
(exec 7>"$W/run/omarchy-face-rename.lock" && flock -n 7 && sleep 5) &
holder=$!
sleep 0.3
cp "$SJ" "$W/before.json"
out=$(rn "$P/graveklar.face" --finish); rc=$?
check "--finish: 'renaming', exit 0" "renaming|0" "$(field state "$out")|$rc"
out=$(rn "$P/graveklar.face" --repair); rc=$?
check "--repair: 'renaming', exit 0" "renaming|0" "$(field state "$out")|$rc"
sleep 0.5
check "nothing written" "true|0|false" "$(yes_no cmp -s "$SJ" "$W/before.json")|$(writes)|$(yes_no test -e "$SNAP")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
end

# =============================================================================
begin T12 "an old 2.x beside a 3.x kalinewb.face; a kalinewb.face below 3.0.0; install.sh"
world beside
rsync -a "$FACE30/" "$P/kalinewb.face/"
rsync -a "$FACE22/" "$P/graveklar.face/"
cp -a "$OLDLOCK" "$P/graveklar.face-lock"
cp "$T1_SHELL" "$SJ"
cp -a "$H" "$W/home-before"
check "--check sees two folders" '{"needed":true,"reason":"two_folders"}' "$(rn "$P/kalinewb.face" --check)"
out=$(rn "$P/kalinewb.face" --repair)
wait_for '^restart shell' || true
check "renamed, the old folder into the snapshot" "renamed|beside|true" \
  "$(field state "$out")|$(field case "$out")|$(yes_no test -f "$SNAP/graveklar.face/manifest.json")"
check "…ending as T1" "$(cat "$BASIC_SJ")" "$(cat "$SJ")"
check "…with one Face left installed" "kalinewb.face kalinewb.face-lock " "$(listing)"
out=$(rn "$P/kalinewb.face" --rollback)
check "--rollback puts both folders back" "rolledback|graveklar.face graveklar.face-lock kalinewb.face " \
  "$(field state "$out")|$(listing)"
check "…and shell.json byte for byte" true "$(yes_no cmp -s "$SJ" "$W/home-before/.config/omarchy/shell.json")"

world too-old
rsync -a "$FACE30/" "$P/kalinewb.face/"
jq '.version = "2.9.0"' "$FACE30/manifest.json" >"$P/kalinewb.face/manifest.json"
rsync -a "$FACE22/" "$P/graveklar.face/"
cp "$T1_SHELL" "$SJ"
before=$(listing)
out=$(rn "$P/graveklar.face" --repair); rc=$?
check "a kalinewb.face below 3.0.0 is refused" "face_too_old|1" "$(field error "$out")|$rc"
check "…nothing written" "true|0|false|true" \
  "$(yes_no cmp -s "$SJ" "$T1_SHELL")|$(writes)|$(yes_no test -e "$SNAP")|$([[ $(listing) == "$before" ]] && echo true || echo false)"

world install
rsync -a "$FACE22/" "$P/graveklar.face/"
install_out=$(sandbox "$REPO/install.sh" --no-restart 2>&1); rc=$?
check "install.sh with only graveklar.face installed syncs into it" "0|kalinewb.face 3.0.0|graveklar.face " \
  "$rc|$(jq -r '.id + " " + .version' "$P/graveklar.face/manifest.json")|$(listing)"
rsync -a "$FACE30/" "$P/kalinewb.face/"
before=$(find "$P" -type f -printf '%P %s %T@\n' | sort | sha256sum)
install_out=$(sandbox "$REPO/install.sh" --no-restart 2>&1); rc=$?
check "…and with both, refuses, pointing at --repair, changing nothing" "1|true|true" \
  "$rc|$(grep -q -- '--repair' <<<"$install_out" && echo true || echo false)|$([[ $(find "$P" -type f -printf '%P %s %T@\n' | sort | sha256sum) == "$before" ]] && echo true || echo false)"
end

# =============================================================================
begin T13 "3.0.0's health, run by the old hook: nothing while locked, T1 once unlocked; a refused restart is retried"
seed hook
touch "$W/locked"
cp "$SJ" "$W/before.json"
before=$(listing)
sandbox bash "$H/.config/omarchy/hooks/post-boot.d/graveklar-face.hook" >/dev/null 2>&1
sleep 1
check "the hook ran 3.0.0's health from the old folder" true "$(grep -q '^facebin omarchy-face-health' "$W/calls" && echo true || echo false)"
check "while locked: nothing written" "true|0|false|true" \
  "$(yes_no cmp -s "$SJ" "$W/before.json")|$(writes)|$(yes_no test -e "$SNAP")|$([[ $(listing) == "$before" ]] && echo true || echo false)"
rm -f "$W/locked"
wait_for '^restart shell' 150 || true
sleep 0.3
check "once unlocked, it ends as T1" "$(cat "$BASIC_SJ")" "$(cat "$SJ")"
check "…in the new folder, with one restart" "kalinewb.face kalinewb.face-lock |1" "$(listing)|$(restarts)"

seed relock
touch "$W/lock-at-commit"
out=$(rn "$P/graveklar.face" --repair)
check "a session locked during the rename: the rename still finishes" renamed "$(field state "$out")"
wait_for '^restart refused' 50 || true
sleep 0.5
check "…its restart is refused while locked" "true|0" \
  "$(grep -q '^restart refused' "$W/calls" && echo true || echo false)|$(restarts)"
rm -f "$W/lock-at-commit" "$W/locked"
wait_for '^restart shell' 50 || true
check "…and retried once after the unlock" 1 "$(restarts)"
end

# =============================================================================
begin T14 "Face off after --prename: 3.0.0 starts enabled, says 'renaming', skips lockSync(), ends as T7"
world off
rsync -a "$FACE22/" "$P/graveklar.face/"
cp -a "$OLDLOCK" "$P/graveklar.face-lock"
cp "$T1_SHELL" "$SJ"
rn "$P/graveklar.face" --prename >/dev/null
# The person then takes Face off the bar; the marker stays.
jq '.bar.layout.right -= [{"id": "graveklar.face"}] | .bar.notch.hostedPanels -= ["graveklar.face"]' "$SJ" >"$W/x" &&
  mv "$W/x" "$SJ"
rsync -a --delete "$FACE30/" "$P/graveklar.face/"
check "3.0.0 starts enabled anyway, by the marker" true "$(enabled kalinewb.face)"
# The service that starts runs --finish as its child, in a process group of its
# own; the stand-in for `omarchy-shell shell reloadConfig` kills that whole group
# at step 4's commit, as Omarchy does to a service its id has just been switched
# off for. The detached rename must not go with it.
( sandbox setsid bash -c 'printf %s $$ >"$G10_WORLD/kill-pgid"; "$1" --finish >"$G10_WORLD/finish.out"; exec sleep 30' \
  _ "$P/graveklar.face/bin/omarchy-face-rename" & ) 2>/dev/null
wait_for '^restart shell' || true
sleep 0.3
pgid=$(cat "$W/kill-pgid" 2>/dev/null)
check "the service said 'renaming'" renaming "$(field state "$(cat "$W/finish.out" 2>/dev/null)")"
check "…and its process group was killed at the commit" false "$(yes_no kill -0 -- "-$pgid")"
check "the detached rename finished anyway" "kalinewb.face kalinewb.face-lock |1" "$(listing)|$(restarts)"
check "ending as T7: kalinewb.face installed and not enabled" false "$(enabled kalinewb.face)"
check "…the marker gone" false "$(jq -e 'any((.plugins // [])[]; type == "object" and has("renamedFrom"))' "$SJ" >/dev/null && echo true || echo false)"
check "…and the lock screen moved over with it" true "$(enabled kalinewb.face-lock)"

# The service's half, in a real QML runtime: Service.qml asks its rename helper
# first, and on "renaming" leaves the lock screen alone. dev/bin's stand-in
# answers the state it is told to, and the lock helper stand-in records `sync`.
harness=$root/harness
mkdir -p "$harness" "$root/qhome" "$root/qstate" "$root/qstubs"
SHELL_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
ln -s "$SHELL_PATH/shell/Commons" "$harness/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$harness/Ui"
ln -s "$REPO" "$harness/face"
cat >"$harness/shell.qml" <<'QML'
import QtQuick
import Quickshell
import "face" as Face

ShellRoot {
  Face.Service { omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy" }
  Timer { interval: 3000; running: true; onTriggered: Qt.exit(0) }
}
QML
for name in omarchy omarchy-shell setsid hyprctl notify-send omarchy-hyprland-session-locked; do
  printf '#!/bin/bash\nexit 1\n' >"$root/qstubs/$name"
done
chmod 0755 "$root/qstubs"/*
service() { # service <rename state>
  rm -f "$root/qstate/verbs.log"
  env HOME="$root/qhome" XDG_CONFIG_HOME="$root/qhome/.config" XDG_STATE_HOME="$root/qhome/.local/state" \
    PATH="$root/qstubs:$PATH" OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_STATE="$root/qstate" \
    OMARCHY_FACE_DEV_FIXTURE=configured OMARCHY_FACE_DEV_RENAME="$1" \
    timeout 30 quickshell -p "$harness" -n 2>&1
}
qout=$(service renaming)
check "Service.qml on 'renaming': says so, and no lock sync" "true|0" \
  "$(grep -q 'moving to its new name' <<<"$qout" && echo true || echo false)|$(cat "$root/qstate/verbs.log" 2>/dev/null | grep -c '^lock:sync')"
qout=$(service nothing)
check "…on 'nothing': the lock sync runs as it always has" 1 "$(cat "$root/qstate/verbs.log" 2>/dev/null | grep -c '^lock:sync')"
end

# =============================================================================
echo
check "this account's own ~/.config/omarchy and ~/.local/state/omarchy-face are as they were" \
  "$REAL_BEFORE" "$(real_state)"

echo
if ((failures == 0)); then
  echo "${GREEN}G10 passes: $cases/$cases cases, $checks checks.${RESET}"
else
  echo "${RED}G10 fails: $((cases - cases_failed))/$cases cases, $failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
