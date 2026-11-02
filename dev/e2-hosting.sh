#!/bin/bash

# E2: Face in both homes -- the stock bar's popup and the notch's panel
# (plan-face-enroll.md section 7.5, Phase 3).
#
#   ./dev/e2-hosting.sh
#   NOTCH_DIR=/path/to/a/clean/notch/copy ./dev/e2-hosting.sh
#
# The two cases that need a real notch (marked *) need NOTCH_DIR and E2_NOTCH=1
# (a compositor, see below). NOTCH_DIR is READ ONLY here: a clean copy of the
# notch at master, e.g.
#
#   mkdir /tmp/notch && git -C ~/Work/omarchy-notch archive origin/master | tar -x -C /tmp/notch
#
# The cases, in the plan's numbers:
#
#   (i)    the shared views render the same PNG from FacePanel and from
#          Surface.qml's panel
#   (ii)   notch-less: no heartbeat, a stale one, `present` false, Face missing
#          from `accepted`, contract 0 -> `record` opens the card and never calls
#          `omarchy-shell notch`
#   (iii)* a fresh heartbeat accepting Face opens the enrol route and no card
#   (iv)   `hidden` and `declined` open the card
#   (v)    a forged heartbeat with no enrol.json `open` opens the card after 2 s
#          and starts no camera and no pkexec; a stale enrol.json is ignored
#   (vi)*  switching the integration off mid-session discards it (EOF seen by the
#          stub); a second `record` answers ok / busy across homes
#   (vii)  `omarchy plugin validate` and the notch's own scan accept the
#          manifest; `available` is false before the status read and while the
#          engine row is missing
#   (ix)   faceroute.js round-trips odd names
#
# (viii) is Phase 6's. (x) is Phase 4's and is in dev/e3-enrol-view.sh (the mode file).
#
# HEADLESS BY DEFAULT: no window opens anywhere. Every Quickshell harness runs
# with QT_QPA_PLATFORM=offscreen and no WAYLAND_DISPLAY. That runs (i) against
# the popup's wiring without its window, (ii), (iv), (v) against NotchRoute.qml,
# (vii) and the fence. What cannot run without a compositor is anything that
# makes a layer-shell window -- FacePanel's KeyboardPanel, the Service's
# Indicator and the notch itself -- and these are SKIPPED, loudly, unless
# E2_NESTED=1, which starts a nested Hyprland (the way dev/g7-preview.sh does)
# and so draws a window on the desktop while it runs:
#
#   * (i)   the REAL FacePanel's PNG, compared with the hosted panel's
#   * (iii) and (vi), against the notch, and the Service end to end
#
# Every stub the code under test could call -- `omarchy-shell`, `pkexec`,
# `hyprctl` -- is earlier in PATH. No camera is opened: the fixture has no RGB
# node (`camera.rgb` is "") and the harness asserts it; nothing here reads
# /dev/video*.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
DIM=$'\e[2m'
YELLOW=$'\e[33m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
NOTCH_DIR=${NOTCH_DIR:-}
NESTED=${E2_NESTED:-0}
SESSION_DISPLAY=${WAYLAND_DISPLAY:-}
# No compositor unless asked for: a stray display would put windows on the desktop.
(( NESTED )) || unset WAYLAND_DISPLAY

failures=0
checks=0

note() { echo "  ${YELLOW}note${RESET}  $*"; }
step() { echo; echo "${DIM}== $*${RESET}"; }
check() { # check <description> <expected> <actual>
  checks=$((checks + 1))
  if [[ $2 == "$3" ]]; then
    echo "  ${GREEN}pass${RESET}  $1"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected '$2', got '$3')${RESET}"
    failures=$((failures + 1))
  fi
}

for tool in quickshell Hyprland hyprctl jq node magick omarchy rsync; do
  command -v "$tool" >/dev/null || { echo "e2: $tool is not installed" >&2; exit 1; }
done

SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Commons ]] || { echo "e2: no Omarchy shell at $SHELL_PATH/shell" >&2; exit 1; }

HYPRCTL=$(command -v hyprctl)
QUICKSHELL=$(command -v quickshell)

root=$(mktemp -d /tmp/omarchy-face-e2.XXXXXX)
hypr_pid=""
pids=()
cleanup() {
  local pid
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  sleep 0.5
  [[ -n $hypr_pid ]] && kill "$hypr_pid" 2>/dev/null
  # E2_KEEP=<dir> keeps the PNGs and logs for looking at.
  if [[ -n ${E2_KEEP:-} ]]; then mkdir -p "$E2_KEEP"; cp "$root"/*.png "$E2_KEEP"/ 2>/dev/null; cp -r "$root/logs" "$E2_KEEP"/ 2>/dev/null; fi
  rm -rf "$root"
}
trap cleanup EXIT

field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }
now_ms() { echo $(($(date +%s%N) / 1000000)); }

echo "E2 — Face in both homes"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO   notch: ${NOTCH_DIR:-none}${RESET}"

# =============================================================================
# (ix) the route parser, under node
# =============================================================================

step "(ix) faceroute.js round-trips odd names"

cat >"$root/route.js" <<EOF
const vm = require("vm"), fs = require("fs")
const source = fs.readFileSync("$REPO/common/faceroute.js", "utf8").replace(/^\.pragma library/m, "")
const ctx = { console, encodeURIComponent, decodeURIComponent, String, Array, JSON }
vm.createContext(ctx); vm.runInContext(source, ctx)
const R = ctx
const out = []
const say = (k, v) => out.push(k + "=" + v)
const rt = (name, appearance, label, isNew) => {
  const route = R.build("enrol", { name, appearance, label, isNew })
  const p = R.parse(route)
  return JSON.stringify([route.split(":").length, p && p.name === name && p.appearance === appearance && p.label === label && p.isNew === isNew])
}
say("ase", rt("Åse", "No glasses", "Åse", false))
say("colon", rt("a:b", "x:y", "a:b:c", true))
say("percent", rt("%", "100%", "%41", false))
say("percentRoute", R.build("enrol", { name: "%", appearance: "a", label: "b", isNew: false }))
say("empty-label", JSON.stringify(R.parse(R.build("enrol", { name: "anna", appearance: "No glasses", label: "", isNew: false }))))
say("person", JSON.stringify(R.parse(R.build("person", { name: "Åse:1" }))))
for (const v of ["setup", "people", "settings", "remove"]) say(v, JSON.stringify(R.parse(v)))
say("unknown", R.parse("nope"))
say("empty", R.parse(""))
say("null", R.parse(null))
say("person-no-name", R.parse("person:"))
say("person-extra", R.parse("person:a:b"))
say("plain-extra", R.parse("people:x"))
say("enrol-short", R.parse("enrol:a:b:c"))
say("enrol-flag", R.parse("enrol:a:b:c:maybe"))
say("enrol-no-name", R.parse("enrol::b:c:new"))
say("bad-escape", R.parse("person:%E0%A4%A"))
say("long", R.parse("person:" + "x".repeat(2000)))
say("build-unknown", JSON.stringify(R.build("nope", {})))
say("build-person-empty", JSON.stringify(R.build("person", { name: "" })))
console.log(out.join("\n"))
EOF
out=$(node "$root/route.js" 2>&1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "Åse round-trips through five segments" '[5,true]' "$(field ase "$out")"
check "a:b and a:b:c survive the colon separator" '[5,true]' "$(field colon "$out")"
check "% and %41 are not decoded twice" '[5,true]' "$(field percent "$out")"
check "…and a bare % travels as %25" 'enrol:%25:a:b:old' "$(field percentRoute "$out")"
check "an empty label is a field, not a missing one" '{"view":"enrol","name":"anna","appearance":"No glasses","label":"","isNew":false}' "$(field empty-label "$out")"
check "a person with a colon and an accent round-trips" '{"view":"person","name":"Åse:1","appearance":"","label":"","isNew":false}' "$(field person "$out")"
check "the four plain views parse" \
  '{"view":"setup","name":"","appearance":"","label":"","isNew":false} {"view":"people","name":"","appearance":"","label":"","isNew":false} {"view":"settings","name":"","appearance":"","label":"","isNew":false} {"view":"remove","name":"","appearance":"","label":"","isNew":false}' \
  "$(field setup "$out") $(field people "$out") $(field settings "$out") $(field remove "$out")"
check "an unknown view, an empty route and null are null" "null null null" \
  "$(field unknown "$out") $(field empty "$out") $(field null "$out")"
check "a person with no name or with extra segments is null" "null null" \
  "$(field person-no-name "$out") $(field person-extra "$out")"
check "a plain view with a segment, a short enrol and a bad flag are null" "null null null" \
  "$(field plain-extra "$out") $(field enrol-short "$out") $(field enrol-flag "$out")"
check "an enrol with no name, a broken escape and a huge route are null" "null null null" \
  "$(field enrol-no-name "$out") $(field bad-escape "$out") $(field long "$out")"
check "building an unknown view or a nameless person builds nothing" '"" ""' \
  "$(field build-unknown "$out") $(field build-person-empty "$out")"

# =============================================================================
# (vii) the manifest
# =============================================================================

step "(vii) the manifest is accepted"

stage=$root/stage/kalinewb.face
mkdir -p "$stage"
rsync -a --exclude .git --exclude dev --exclude install.sh "$REPO/" "$stage/"
validate=$(omarchy plugin validate "$stage" 2>&1); rc=$?
check "omarchy plugin validate is clean on the plugin folder as installed" "0" "$rc"
[[ $rc -ne 0 ]] && echo "${DIM}$validate${RESET}"
validate=$(omarchy plugin validate "$REPO" 2>&1); rc=$?
check "…and on the repository folder itself" "0" "$rc"
check "the manifest declares the surface entry and contract 1" "Surface.qml 1" \
  "$(jq -r '"\(.entryPoints.surface) \(.surface.contract)"' "$REPO/manifest.json")"
check "…and the bar widget and service entries are as before" "FacePanel.qml Service.qml" \
  "$(jq -r '"\(.entryPoints.barWidget) \(.entryPoints.service)"' "$REPO/manifest.json")"

if [[ -n $NOTCH_DIR && -x $NOTCH_DIR/bin/notch-integrations ]]; then
  scan=$("$NOTCH_DIR/bin/notch-integrations" scan "$root/stage")
  check "the notch's own scan lists Face as a candidate with no problems" "kalinewb.face Surface.qml 1 0" \
    "$(jq -r '.[] | select(.id == "kalinewb.face") | "\(.id) \(.entry) \(.contract) \(.problems | length)"' <<<"$scan")"
  check "…and Surface.qml names no window type (the own-window check)" "0" \
    "$(grep -cE 'PanelWindow|PopupWindow|FloatingWindow' "$REPO/Surface.qml")"
else
  note "skipped: the notch's own scan needs NOTCH_DIR"
fi


# =============================================================================
# the nested compositor (E2_NESTED=1 only; as dev/g7-preview.sh)
# =============================================================================

start_nested() {
  echo "${YELLOW}E2_NESTED=1: starting a nested Hyprland. It draws a window on the desktop while it runs.${RESET}"
  cat >"$root/hypr.conf" <<'CONF'
monitor = HEADLESS-1, 1600x1200@60, 0x0, 1
misc {
  disable_hyprland_logo = true
  disable_splash_rendering = true
  force_default_wallpaper = 0
  vfr = false
}
animations { enabled = false }
decoration { blur { enabled = false } shadow { enabled = false } }
CONF
  local before candidate path display
  before=$(ls "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" 2>/dev/null)
  # The compositor needs the session's display to nest in; it is the one
  # variable this script otherwise unsets.
  WAYLAND_DISPLAY=$SESSION_DISPLAY setsid Hyprland -c "$root/hypr.conf" >"$root/hypr.log" 2>&1 &
  hypr_pid=$!
  signature=""
  for _ in $(seq 1 40); do
    sleep 0.5
    for path in "${XDG_RUNTIME_DIR:-/run/user/$UID}"/hypr/*; do
      [[ -e $path ]] || continue
      candidate=${path##*/}
      grep -qxF "$candidate" <<<"$before" && continue
      signature=$candidate
    done
    [[ -n $signature ]] && break
  done
  [[ -n $signature ]] || { echo "${RED}the nested compositor did not start${RESET}"; exit 1; }
  export HYPRLAND_INSTANCE_SIGNATURE=$signature
  "$HYPRCTL" output create headless >/dev/null
  sleep 1
  "$HYPRCTL" keyword monitor "WAYLAND-1,disable" >/dev/null
  sleep 1
  display=$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$UID}"/wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -n1)
  NESTED_DISPLAY=${display##*/}
  [[ -n $NESTED_DISPLAY ]] || { echo "${RED}no wayland socket for the nested compositor${RESET}"; exit 1; }
  # `quickshell ipc` finds an instance on the current display only.
  export WAYLAND_DISPLAY=$NESTED_DISPLAY
  check "everything below talks to a compositor with a headless output of its own" "true" \
    "$("$HYPRCTL" monitors -j | jq -r 'any(.[]; .name | startswith("HEADLESS"))')"
  echo "${DIM}nested compositor $signature on $NESTED_DISPLAY${RESET}"
}

if (( NESTED )); then
  start_nested
else
  note "headless: the cases marked [nested] below are skipped; E2_NESTED=1 runs them (it draws a window while it runs)"
fi

# =============================================================================
# the sandbox every harness shares
# =============================================================================

state=$root/state            # the fixtures' own state: people.json, session.log
rt=$root/runtime             # stands in for $XDG_RUNTIME_DIR (OMARCHY_FACE_DEV_RUNTIME)
fixtures=$root/fixtures
bin=$root/bin
logs=$root/logs
mkdir -p "$state" "$rt/kalinewb.notch" "$fixtures" "$bin" "$logs"
cp -r "$REPO/dev/fixtures/." "$fixtures/"
cp "$REPO/dev/fixtures/three-people/people.json" "$state/people.json"
# No RGB node anywhere: a card or a panel opened below has nothing to point a
# camera at. Asserted per case through state().
for f in "$fixtures"/*/status.json; do
  jq '.camera.rgb = ""' "$f" >"$f.new" && mv "$f.new" "$f"
done

# The stand-ins. `omarchy-shell` logs every call and never reaches the live
# shell; `hyprctl` is a no-op (the Service applies a layer rule at start); and
# `pkexec` logs, then becomes the helper, as dev/g3-people-offscreen.sh does.
cat >"$bin/omarchy-shell" <<STUB
#!/bin/bash
echo "\$*" >>"$logs/omarchy-shell.log"
if [[ \${1:-} == notch && -n \${E2_NOTCH_ROOT:-} ]]; then
  exec "$QUICKSHELL" ipc -p "\$E2_NOTCH_ROOT" call notch "\${@:2}"
fi
# No throwaway notch behind it: the call "succeeds" and nothing is shown, which
# is what a forged or stale heartbeat looks like to the service.
if [[ \${1:-} == notch && \${2:-} == panel ]]; then echo opened; exit 0; fi
echo "Target not found." >&2
exit 1
STUB
cat >"$bin/hyprctl" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$bin/pkexec" <<STUB
#!/bin/bash
echo "\$*" >>"$logs/pkexec.log"
exec "\$@"
STUB
chmod +x "$bin"/*

# The environment of every process started below.
face_env=(
  PATH="$bin:$PATH"
  OMARCHY_FACE_DEV_BIN="$REPO/dev/bin"
  OMARCHY_FACE_DEV_STATE="$state"
  OMARCHY_FACE_DEV_FIXTURES="$fixtures"
  OMARCHY_FACE_DEV_FIXTURE=configured
  OMARCHY_FACE_DEV_RUNTIME="$rt"
  OMARCHY_FACE_DEV_PKEXEC=1
)
# Headless: the offscreen platform, and no display to find. Nested: the nested
# compositor's (exported by start_nested).
(( NESTED )) || face_env+=(QT_QPA_PLATFORM=offscreen)

mkshell() { # mkshell <dir> <qml file in dev/qml-harness>
  mkdir -p "$1"
  ln -s "$SHELL_PATH/shell/Commons" "$1/Commons"
  ln -s "$SHELL_PATH/shell/Ui" "$1/Ui"
  ln -s "$SHELL_PATH/shell/services" "$1/services" 2>/dev/null
  ln -s "$REPO" "$1/face"
  cp "$REPO/dev/qml-harness/$2" "$1/shell.qml"
}

# =============================================================================
# (ii) (iv) (v): `record`, routed by the heartbeat -- NotchRoute.qml, headless
# =============================================================================

rtr=$root/router
mkshell "$rtr" hosting-route.qml
env "${face_env[@]}" timeout 300 quickshell -p "$rtr" -n >"$logs/router.log" 2>&1 &
pids+=($!)

rtr_ipc() { "$QUICKSHELL" ipc -p "$rtr" call harness "$@" 2>/dev/null; }
for _ in $(seq 1 60); do
  sleep 0.25
  [[ $(rtr_ipc state) == \{* ]] && break
done
[[ $(rtr_ipc state) == \{* ]] || {
  echo "${RED}the router harness never answered${RESET}"
  "$QUICKSHELL" ipc -p "$rtr" call harness state 2>&1 | head -5
  tail -8 "$logs/router.log"; exit 1
}

cards() { rtr_ipc state | jq -r '[.cards[].name] | join(",")'; }
notch_calls() { local n; n=$(grep -c '^notch ' "$logs/omarchy-shell.log" 2>/dev/null); echo "${n:-0}"; }
pkexec_calls() { [[ -f $logs/pkexec.log ]] && wc -l <"$logs/pkexec.log" || echo 0; }
reset_router() {
  # A request still waiting on the notch (2 s) is let run out first: it ends in
  # a card request, which the clear below forgets.
  for _ in $(seq 1 16); do
    [[ -z $(rtr_ipc state | jq -r '.pending') ]] && break
    sleep 0.25
  done
  rtr_ipc clear >/dev/null
  rm -f "$rt/kalinewb.face/enrol.json" "$rt/kalinewb.notch/platform.json" "$logs/omarchy-shell.log"
}
write_beat() { # write_beat <jq filter applied to a good beat>
  local beat
  beat=$(jq -n --argjson now "$(now_ms)" '{contract: 1, features: ["panel"], beatAt: $now, staleAfterMs: 6000,
      present: true, hidden: false, accepted: {"kalinewb.face": {contract: 1}}, declined: {}}')
  jq -c "$1" <<<"$beat" >"$rt/kalinewb.notch/platform.json"
}
write_flag() { # write_flag <state> <name> <age in ms>
  mkdir -p "$rt/kalinewb.face"
  jq -n --arg s "$1" --arg n "$2" --argjson at "$(( $(now_ms) - $3 ))" '{state: $s, name: $n, at: $at}' >"$rt/kalinewb.face/enrol.json"
}
record_anna() { rtr_ipc record anna "No glasses" Anna ""; }

step "the sandbox itself"
check "no fixture has an RGB node, so no camera has anything to open" "" \
  "$(jq -r '.camera.rgb' "$fixtures"/*/status.json | sort -u | tr -d '\n')"
check "the router has no card request and nothing waiting on the notch" " " "$(cards) $(rtr_ipc state | jq -r '.pending')"

step "(ii) notch-less: record asks for the card and never calls the notch"
for variant in \
  "no heartbeat file|NONE" \
  "a stale heartbeat|.beatAt = (.beatAt - 20000)" \
  "present false|.present = false" \
  "Face missing from accepted|.accepted = {}" \
  "contract 0|.contract = 0"
do
  label=${variant%%|*}
  filter=${variant#*|}
  reset_router
  [[ $filter == NONE ]] || write_beat "$filter"
  answer=$(record_anna)
  check "$label: record answers ok" "ok" "$answer"
  check "$label: the card is asked for, for anna" "anna" "$(cards)"
  check "$label: omarchy-shell notch was never called" "0" "$(notch_calls)"
done

step "(iv) a hidden bar and a declined integration ask for the card"
reset_router
write_beat '.hidden = true'
answer=$(record_anna)
check "hidden: record answers ok" "ok" "$answer"
check "hidden: the card is asked for (the user pressed Scan)" "anna" "$(cards)"
check "hidden: the notch was never called" "0" "$(notch_calls)"
reset_router
write_beat '.accepted = {} | .declined = {"kalinewb.face": "user-off"}'
answer=$(record_anna)
check "declined:user-off: record answers ok" "ok" "$answer"
check "declined:user-off: the card is asked for" "anna" "$(cards)"
check "declined:user-off: the notch was never called" "0" "$(notch_calls)"

step "(v) a forged heartbeat shows nothing and starts nothing"
reset_router
before=$(pkexec_calls)
write_beat '.'
answer=$(record_anna)
check "a good-looking heartbeat: record answers opening" "opening" "$answer"
sleep 0.5
check "…the request went to the notch, once, as an enrol route" \
  "notch panel kalinewb.face enrol:anna:No%20glasses:Anna:old" "$(grep '^notch ' "$logs/omarchy-shell.log" | head -1)"
check "…and the router is waiting for it, with no card asked for yet" "anna|" \
  "$(rtr_ipc state | jq -r '.pending')|$(cards)"
check "a second record for anna while it waits answers ok" "ok" "$(record_anna)"
check "…and one for somebody else answers busy" "busy" "$(rtr_ipc record mia "No glasses" Mia "")"
sleep 2.4
check "after 2 s with no enrol.json open the card is asked for" "anna" "$(cards)"
check "…the wait is over" "" "$(rtr_ipc state | jq -r '.pending')"
check "…no pkexec was started by any of it" "$before" "$(pkexec_calls)"

reset_router
write_beat '.'
write_flag open anna 10000
answer=$(record_anna)
check "a stale enrol.json (10 s old) does not count as a session: record answers opening" "opening" "$answer"
sleep 2.6
check "…and the card is asked for after 2 s" "anna" "$(cards)"

reset_router
write_beat '.'
write_flag open mia 0
check "a fresh enrol.json for mia: record for anna answers busy" "busy" "$(record_anna)"
check "…and for mia answers ok" "ok" "$(rtr_ipc record mia "No glasses" Mia "")"
check "…neither asked the notch" "0" "$(notch_calls)"
write_flag closed "" 0
answer=$(record_anna)
check "once it says closed, record goes on to the notch again" "opening" "$answer"
check "…which it was asked once" "1" "$(notch_calls)"
reset_router
mkdir -p "$rt/kalinewb.face"; printf 'not json' >"$rt/kalinewb.face/enrol.json"
write_beat '.'
check "garbage in enrol.json is no session either" "opening" "$(record_anna)"
reset_router

rtr_ipc quit >/dev/null
sleep 0.5

# =============================================================================
# (vii) available is honest; (i) the same views in both homes
# =============================================================================

render() { # render <case> <route> <host> <out png> [<WxH to fit>]
  local out try
  for try in 1 2; do
    out=$(env "${face_env[@]}" FACE_HARNESS_CASE="$1" FACE_HARNESS_ROUTE="$2" FACE_HARNESS_HOST="$3" FACE_HARNESS_OUT="$4" \
      FACE_HARNESS_SIZE="${5:-}" timeout 60 quickshell -p "$panel_root" -n 2>&1 | tee -a "$logs/render.log")
    # A render that never printed its picture (the first window of a fresh
    # compositor can lose its first frame) is tried once more.
    grep -q 'HARNESS saved true' <<<"$out" && break
  done
  sed -n 's/^.*HARNESS \([a-zA-Z0-9]*\) \(.*\)$/\1=\2/p' <<<"$out"
}

panel_root=$root/panel
mkshell "$panel_root" hosting-panel.qml

step "(i) the same views, from the popup's wiring and from Surface.qml's panel"
# png-diff.py compares premultiplied RGBA, the pixels the compositor adds up. A
# difference of one or two levels on an anti-aliased edge is rasterisation
# rounding (the same view drawn twice in one home differs by as much), not a
# different picture; MAX_LEVEL is that bound, and a real change (a colour, a
# radius, a position) is tens of levels.
MAX_LEVEL=2
pngdiff() { "$REPO/dev/png-diff.py" "$1" "$2"; } # -> "<size> <pixels that differ> <max level>"
within() { awk -v d="$1" -v m="$MAX_LEVEL" 'BEGIN { print (d + 0 >= 0 && d + 0 <= m) ? "true" : "false" }'; }
for route in people person:anna setup; do
  tag=${route//:/-}
  stock=$(render stock "$route" identity "$root/stock-$tag.png")
  stock2=$(render stock "$route" identity "$root/stock2-$tag.png")
  # The popup's content is 305 wide and at most 560 high; the notch gives a
  # panel what it asks for. Both are the same views, so the hosted panel is
  # given the stock content's own size to compare like with like.
  hosted=$(render hosted "$route" identity "$root/hosted-$tag.png" "$(field size "$stock")")
  echo "${DIM}  $route: stock $(field size "$stock"), hosted $(field size "$hosted")${RESET}"
  check "$route: both homes drew a PNG" "true true" "$(field saved "$stock") $(field saved "$hosted")"
  check "$route: at the same size" "$(field size "$stock")" "$(field size "$hosted")"
  read -r _ n_same max_same < <(pngdiff "$root/stock-$tag.png" "$root/stock2-$tag.png")
  read -r _ n_diff max_diff < <(pngdiff "$root/stock-$tag.png" "$root/hosted-$tag.png")
  echo "${DIM}  $route: stock against stock again: $n_same pixels differ, at most $max_same levels; stock against hosted: $n_diff pixels, at most $max_diff levels${RESET}"
  check "$route: drawn twice, the popup differs by at most $MAX_LEVEL levels (the harness's own noise)" "true" "$(within "$max_same")"
  check "$route: the notch's panel (on a host with the theme's palette) differs from the popup by at most $MAX_LEVEL levels" "true" "$(within "$max_diff")"
  if (( NESTED )); then
    popup=$(render popup "$route" identity "$root/popup-$tag.png")
    read -r _ n_pop max_pop < <(pngdiff "$root/popup-$tag.png" "$root/hosted-$tag.png")
    echo "${DIM}  $route: the real FacePanel against hosted: $(field size "$popup"), $n_pop pixels, at most $max_pop levels${RESET}"
    check "$route: [nested] the real FacePanel's content is the same size as the hosted panel's" "$(field size "$hosted")" "$(field size "$popup")"
    check "$route: [nested] …and differs from it by at most $MAX_LEVEL levels" "true" "$(within "$max_pop")"
  fi
done
(( NESTED )) || note "[nested] SKIPPED: the real FacePanel's PNG (its KeyboardPanel is a layer-shell window); the popup side above is its wiring without the window"

step "(i) what the hosted-panel rules change, and only that"
for route in people person:anna setup; do
  tag=${route//:/-}
  size=$(magick identify -format '%wx%h' "$root/stock-$tag.png")
  render hosted "$route" realistic "$root/real-$tag.png" "$size" >/dev/null
  render hosted "$route" other "$root/other-$tag.png" "$size" >/dev/null
  read -r _ n_real max_real < <(pngdiff "$root/stock-$tag.png" "$root/real-$tag.png")
  read -r _ n_other max_other < <(pngdiff "$root/stock-$tag.png" "$root/other-$tag.png")
  echo "${DIM}  $route: against the stock popup, on the notch's own rule (urgent becomes the host's accent) $n_real pixels differ (at most $max_real levels); on an unrelated palette $n_other pixels${RESET}"
  check "$route: a host with another palette is followed, not the theme" "true" \
    "$(awk -v d="$max_other" -v m="$MAX_LEVEL" 'BEGIN { print (d + 0 > m) ? "true" : "false" }')"
done

step "the preview camera's fence (6a.1; round-3 notes S1 and S3)"
fence=$(env "${face_env[@]}" FACE_HARNESS_CASE=fence timeout 60 quickshell -p "$panel_root" -n 2>&1 \
  | tee -a "$logs/render.log" | sed -n 's/^.*HARNESS \([a-zA-Z0-9-]*\) \(.*\)$/\1=\2/p')
echo "${DIM}$(sed 's/^/  /' <<<"$fence")${RESET}"
check "S1: an enrol view pushed in process (no enrol: route) is what the fence reads" "enrol" "$(field fence-view "$fence")"
check "before Start nothing is on: previewOn is false on both screens (the camera waits for Start, 6a.1)" "false,false" "$(field fence-idle "$fence")"
check "S3: two panels, one per screen: only the one on the host's panelScreen is live" "true,false" "$(field fence-live "$fence")"
check "S3: …and once Start has been pressed (authorising) only that one has previewOn" "true,false" "$(field fence-screen1 "$fence")"
check "S3: …and when the host's panel moves to the other screen, so does the fence" "false,true" "$(field fence-screen2 "$fence")"
check "the notch closing turns it off in both, though neither panel was destroyed" "false,false" "$(field fence-closed "$fence")"
check "…opening it again makes the right one live, with a new session that has not been started: no camera until Start" "true,false false,false" \
  "$(field fence-reopened-live "$fence") $(field fence-reopened "$fence")"
check "leaving the enrol view removes the view and ends the session" "none,none" "$(field fence-left "$fence")"
check "…the Surface holds no session after it" "true" "$(field fence-session "$fence")"
check "the preview Loader is active only for previewOn AND a device (nothing else opens the camera)" "1" \
  "$(grep -c 'active: view.previewOn && view.previewDevice !== ""' "$REPO/EnrolView.qml")"
check "…and previewOn is the host being live AND the session wanting it (Start pressed)" "1" \
  "$(grep -c 'previewOn: view.live && !!view.session && view.session.previewWanted' "$REPO/EnrolView.qml")"
check "RecordPreview.qml is named by EnrolView.qml alone" "EnrolView.qml" \
  "$(grep -l 'RecordPreview' "$REPO"/*.qml | xargs -n1 basename | tr '\n' ' ' | sed 's/ $//')"

step "(vii) available is false until the status has answered and the engine row says installed"
avail() { # avail <fixture> -> "<at creation> <after the read>"
  env "${face_env[@]}" OMARCHY_FACE_DEV_FIXTURE="$1" FACE_HARNESS_CASE=available \
    timeout 60 quickshell -p "$avail_root" -n 2>&1 | sed -n 's/^.*HARNESS available \(.*\)$/\1/p' | tr '\n' ' '
}
avail_root=$root/avail
mkshell "$avail_root" hosting-available.qml
check "configured: false at creation, true once the status has been read" "false true " "$(avail configured)"
check "fresh (the engine not built): false, and stays false" "false false " "$(avail fresh)"
check "broken-engine (the row says broken): false, and stays false" "false false " "$(avail broken-engine)"

# =============================================================================
# (iii) (vi) in a throwaway notch
# =============================================================================

step "(iii) (vi) in a throwaway notch [nested]"
if (( ! NESTED )); then
  note "[nested] SKIPPED: (iii) and (vi) need the notch, whose windows are layer-shell windows: no compositor, no notch. Run with E2_NESTED=1 NOTCH_DIR=<a copy of the notch>"
elif [[ -z $NOTCH_DIR || ! -f $NOTCH_DIR/dev/harness/platform-shell.qml ]]; then
  note "SKIPPED: these two cases need a read-only copy of the notch at master in NOTCH_DIR"
else
  nplugins=$root/notch-plugins
  mkdir -p "$nplugins/kalinewb.face" "$root/notch-markers"
  rsync -a --exclude .git --exclude dev --exclude install.sh "$REPO/" "$nplugins/kalinewb.face/"
  nroot=$root/notch-shell
  mkdir -p "$nroot"
  ln -s "$SHELL_PATH/shell/Commons" "$nroot/Commons"
  ln -s "$SHELL_PATH/shell/Ui" "$nroot/Ui"
  ln -s "$SHELL_PATH/shell/services" "$nroot/services"
  ln -s "$NOTCH_DIR" "$nroot/notch"
  printf 'import QtQuick\nimport qs.Commons\nimport qs.Ui\nItem { }\n' >"$nroot/Probe.qml"
  # The notch's own harness, plus one handler: what the integration is doing,
  # and a Start press the harness cannot click. The notch is not modified.
  python3 - "$NOTCH_DIR/dev/harness/platform-shell.qml" "$nroot/shell.qml" <<'PY'
import sys
src = open(sys.argv[1]).read().rstrip()
assert src.endswith("}")
extra = '''
  IpcHandler {
    target: "facetest"
    function surface(): string {
      var item = notch.platform.itemFor("kalinewb.face")
      if (!item) return JSON.stringify({loaded: false})
      var s = item.session
      return JSON.stringify({
        loaded: true, available: item.available, view: item.model.view,
        stack: item.model.viewStack, opened: item.model.opened,
        enrol: item.model.enrol ? item.model.enrol.name : "",
        session: s !== null, phase: s ? s.phase : "", running: s ? s.running : false,
        sessionName: s ? s.name : ""
      })
    }
    function start(): string {
      var item = notch.platform.itemFor("kalinewb.face")
      if (!item || !item.session) return "no-session"
      item.session.start()
      return "started"
    }
    function press(): string {
      var item = notch.platform.itemFor("kalinewb.face")
      return item ? "ok" : "no-item"
    }
  }
'''
open(sys.argv[2], "w").write(src[:-1] + extra + "}\n")
PY
  : >"$state/session.log"
  rm -rf "$rt/kalinewb.notch" "$rt/kalinewb.face"; mkdir -p "$rt/kalinewb.notch"
  notch_env=(
    "${face_env[@]}"
    NOTCH_HARNESS=1 NOTCH_NO_KEYBINDS=1 NOTCH_MENU_DRY_RUN=1
    NOTCH_FORCE_PLATFORM=1 NOTCH_PLUGINS_DIR="$nplugins" NOTCH_PLATFORM_ENABLED='*'
    NOTCH_PLATFORM_STATE_DIR="$rt/kalinewb.notch" NOTCH_FIXTURE_MARKER_DIR="$root/notch-markers"
    NOTCH_PLATFORM_WIDGETS='{"kalinewb.face": "kalinewb.face/FacePanel.qml"}'
    NOTCH_HARNESS_CONFIG='{"batteryPeek":false,"bottomRadius":8}'
    E2_NOTCH_ROOT="$nroot"
  )
  env "${notch_env[@]}" timeout 300 quickshell -p "$nroot" -n >"$logs/notch.log" 2>&1 &
  pids+=($!)
  nipc() { "$QUICKSHELL" ipc -p "$nroot" call notch "$@" 2>/dev/null; }
  nharness() { "$QUICKSHELL" ipc -p "$nroot" call harness "$@" 2>/dev/null; }
  ntest() { "$QUICKSHELL" ipc -p "$nroot" call facetest "$@" 2>/dev/null; }
  for _ in $(seq 1 80); do sleep 0.25; [[ $(nipc geometry) == \{* ]] && break; done
  for _ in $(seq 1 80); do sleep 0.25; [[ $(nipc integrations | jq -r '.scannedAt > 0' 2>/dev/null) == true ]] && break; done
  # The integration says `available` only after its first status read; the
  # notch accepts it from then on, and the heartbeat follows.
  for _ in $(seq 1 60); do
    sleep 0.25
    [[ $(nipc integrations | jq -r '.list[] | select(.id == "kalinewb.face") | .accepted' 2>/dev/null) == true ]] && break
  done
  sleep 2.5
  report=$(nipc integrations)
  echo "  ${DIM}$(jq -c '[.list[] | {id, accepted, reason, hasPanel, loadStatus}]' <<<"$report" 2>/dev/null)${RESET}"

  check "(vii) the notch accepts Face's integration, with a panel and no problems" "true true ready" \
    "$(jq -r '.list[] | select(.id == "kalinewb.face") | "\(.accepted) \(.hasPanel) \(.loadStatus)"' <<<"$report")"
  check "(vii) …the reason it gives is none (no own-window)" "" \
    "$(jq -r '.list[] | select(.id == "kalinewb.face") | .reason' <<<"$report")"
  beat="$rt/kalinewb.notch/platform.json"
  check "the notch's own heartbeat lists Face as accepted" "1" "$(jq -r '.accepted["kalinewb.face"].contract' "$beat" 2>/dev/null)"
  check "(vii) available is true once the status says the engine is installed" "true" \
    "$(ntest surface | jq -r '.available')"

  # The service, in its own instance, asked to record: the heartbeat is the
  # notch's real one, and `omarchy-shell notch panel` reaches the throwaway notch.
  svc2=$root/service2
  mkshell "$svc2" hosting-service.qml
  env "${face_env[@]}" E2_NOTCH_ROOT="$nroot" timeout 300 quickshell -p "$svc2" -n >"$logs/service2.log" 2>&1 &
  pids+=($!)
  svc2_ipc() { "$QUICKSHELL" ipc -p "$svc2" call "$@" 2>/dev/null; }
  for _ in $(seq 1 60); do sleep 0.5; [[ $(svc2_ipc kalinewb.face.card state) == \{* ]] && break; done
  rm -f "$logs/omarchy-shell.log"
  before=$(pkexec_calls)

  answer=$(svc2_ipc kalinewb.face.card record anna "No glasses" Anna "")
  check "(iii) a fresh heartbeat accepting Face: record answers opening" "opening" "$answer"
  for _ in $(seq 1 20); do sleep 0.25; [[ $(ntest surface | jq -r '.view') == enrol ]] && break; done
  surf=$(ntest surface)
  check "(iii) the notch is showing the enrol route for anna" "enrol anna true" \
    "$(jq -r '"\(.view) \(.enrol) \(.opened)"' <<<"$surf")"
  check "(iii) …the integration made the one session, not started" "true framing false" \
    "$(jq -r '"\(.session) \(.phase) \(.running)"' <<<"$surf")"
  check "(iii) …and the geometry says the panel is open on that route" "true enrol:anna:No%20glasses:Anna:old" \
    "$(nipc geometry | jq -r '"\(.integration.open) \(.integration.route)"')"
  for _ in $(seq 1 12); do sleep 0.25; [[ -f $rt/kalinewb.face/enrol.json ]] && break; done
  check "(iii) enrol.json says open for anna" "open anna" \
    "$(jq -r '"\(.state) \(.name)"' "$rt/kalinewb.face/enrol.json" 2>/dev/null)"
  sleep 2.6
  check "(iii) no card opened, because the notch confirmed" "- " \
    "$(svc2_ipc kalinewb.face.card state | jq -r '.card.name // "-"') $(svc2_ipc kalinewb.face.card state | jq -r '.notch')"
  check "(iii) enrol.json is still being rewritten (fresher than 2 s)" "true" \
    "$(jq -r '((now * 1000) - .at) < 2000' "$rt/kalinewb.face/enrol.json" 2>/dev/null)"
  check "(vi) a second record for anna while it is open answers ok" "ok" \
    "$(svc2_ipc kalinewb.face.card record anna "No glasses" Anna "")"
  check "(vi) …and one for somebody else answers busy" "busy" \
    "$(svc2_ipc kalinewb.face.card record mia "No glasses" Mia "")"
  check "(iii) nothing started pkexec before Start was pressed" "$before" "$(pkexec_calls)"

  # Start, from outside the panel (the harness cannot click): the stub session
  # begins and is waiting on its stdin.
  check "(vi) the session starts" "started" "$(ntest start)"
  for _ in $(seq 1 40); do sleep 0.25; grep -q '^ready$' "$state/session.log" && break; done
  check "(vi) the stub root session is running (pkexec was the one start)" "start anna ready" \
    "$(grep -E '^(start|ready)' "$state/session.log" | tr '\n' ' ' | sed 's/ $//')"
  check "(vi) …through the stand-in pkexec, once" "$((before + 1))" "$(pkexec_calls)"

  # Switch the integration off mid-session.
  nharness setNotch '{"batteryPeek":false,"bottomRadius":8,"disabledIntegrations":["kalinewb.face"]}' >/dev/null
  for _ in $(seq 1 40); do
    sleep 0.25
    grep -qE '^(discarded|killed|done)' "$state/session.log" && break
  done
  check "(vi) switching the integration off mid-session: the stub saw EOF (discarded), not a kill" "discarded" \
    "$(grep -E '^(discarded|killed|done)' "$state/session.log" | head -1)"
  check "(vi) …the integration is gone from the notch" "false user-off" \
    "$(nipc integrations | jq -r '.list[] | select(.id == "kalinewb.face") | "\(.accepted) \(.reason)"')"
  sleep 0.5
  check "(vi) …enrol.json says closed" "closed" "$(jq -r .state "$rt/kalinewb.face/enrol.json" 2>/dev/null)"
  check "(vi) …and after it a record goes to the card, not the notch" "ok" \
    "$(sleep 1; svc2_ipc kalinewb.face.card record anna "No glasses" Anna "")"
  sleep 1.5
  check "(vi) …the card opened for anna" "anna" "$(svc2_ipc kalinewb.face.card state | jq -r '.card.name // "-"')"
  svc2_ipc kalinewb.face.card cancel >/dev/null

  check "no QML errors in the notch's log from Face's files" "none" \
    "$(grep -E '(Surface|FaceModel|FaceViews|EnrolView|EnrolRing|RecordView|FacePanel)\.qml:[0-9]+.*(TypeError|ReferenceError|Unable to assign|is not a)' "$logs/notch.log" | head -1 | cut -c1-120)$(grep -qE '(Surface|FaceModel|FaceViews|EnrolView|EnrolRing|RecordView|FacePanel)\.qml:[0-9]+.*(TypeError|ReferenceError|Unable to assign|is not a)' "$logs/notch.log" || echo none)"
  nharness quit >/dev/null
  svc2_ipc harness quit >/dev/null
  sleep 1
fi

step "no QML errors from Face's files in any harness"
errors=$(cat "$logs"/*.log 2>/dev/null | grep -E '(Surface|FaceModel|FaceViews|EnrolView|EnrolRing|RecordView|RecordCard|FacePanel|Service)\.qml:[0-9]+.*(TypeError|ReferenceError|Unable to assign)' | head -3 | cut -c1-140)
check "the service, the panels and the notch logged none" "" "$errors"

echo
if ((failures == 0)); then
  echo "${GREEN}$checks checks, all passed${RESET}"
else
  echo "${RED}$checks checks, $failures failed${RESET}"
fi
exit $((failures > 0))
