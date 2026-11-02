#!/bin/bash

# E2: Face in both homes -- the stock bar's popup and the notch's panel
# (plan-face-enroll.md section 7.5, Phases 3 and 4).
#
#   ./dev/e2-hosting.sh
#   NOTCH_DIR=/path/to/a/clean/notch/copy ./dev/e2-hosting.sh
#
# NOTCH_DIR is READ ONLY here: a clean copy of the notch at master, e.g.
#
#   mkdir /tmp/notch && git -C ~/Work/omarchy-notch archive origin/master | tar -x -C /tmp/notch
#
# The cases, in the plan's numbers:
#
#   (i)    the shared views render the same PNG from FacePanel and from
#          Surface.qml's panel, inside the margin the notch does not give
#   (vii)  `omarchy plugin validate` and the notch's own scan accept the
#          manifest; `available` is false before the status read and while the
#          engine row is missing
#   (ix)   faceroute.js round-trips odd names, and has no enrol route
#   (xi)   the hosted panel pads its content on all four sides
#   (xii)  Test, in the notch: its own view in place, not a card over the rows
#   (xiii) a scan is never hosted: Scan in the notch asks the service for its
#          card (RecordCard.qml, a window of its own) and closes the panel; the
#          panel never shows a recording and the notch is never asked for one
#
# (iii)-(vi), the heartbeat routing of `record` to an in-notch scan and its
# enrol.json confirmation, are gone with the in-notch scan (Phase 4's live gate:
# polkit's dialog collapses the notch). (viii) is Phase 6's. (x) is Phase 4's and is
# in dev/e3-enrol-view.sh (the mode file).
#
# HEADLESS BY DEFAULT: no window opens anywhere. Every Quickshell harness runs
# with QT_QPA_PLATFORM=offscreen and no WAYLAND_DISPLAY. What cannot run without a
# compositor is anything that makes a layer-shell window -- FacePanel's
# KeyboardPanel, the Service, its cards and the notch itself -- and these are
# SKIPPED, loudly, unless E2_NESTED=1, which starts a nested Hyprland (the way
# dev/g7-preview.sh does) and so draws a window on the desktop while it runs:
#
#   * (i)   the REAL FacePanel's PNG, compared with the hosted panel's
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

step "(ix) faceroute.js round-trips odd names, and has no enrol route"

cat >"$root/route.js" <<EOF
const vm = require("vm"), fs = require("fs")
const source = fs.readFileSync("$REPO/common/faceroute.js", "utf8").replace(/^\.pragma library/m, "")
const ctx = { console, encodeURIComponent, decodeURIComponent, String, Array, JSON }
vm.createContext(ctx); vm.runInContext(source, ctx)
const R = ctx
const out = []
const say = (k, v) => out.push(k + "=" + v)
say("person", JSON.stringify(R.parse(R.build("person", { name: "Åse:1" }))))
for (const v of ["setup", "people", "settings", "remove"]) say(v, JSON.stringify(R.parse(v)))
say("unknown", R.parse("nope"))
say("empty", R.parse(""))
say("null", R.parse(null))
say("person-no-name", R.parse("person:"))
say("person-extra", R.parse("person:a:b"))
say("plain-extra", R.parse("people:x"))
say("enrol-full", R.parse("enrol:anna:No%20glasses:Anna:old"))
say("enrol-short", R.parse("enrol:a:b:c"))
say("enrol-build", JSON.stringify(R.build("enrol", { name: "anna", appearance: "x", label: "y", isNew: false })))
say("odd", JSON.stringify([R.parse(R.build("person", { name: "%" })).name, R.parse(R.build("person", { name: "a:b" })).name, R.build("person", { name: "%" })]))
say("bad-escape", R.parse("person:%E0%A4%A"))
say("long", R.parse("person:" + "x".repeat(2000)))
say("build-unknown", JSON.stringify(R.build("nope", {})))
say("build-person-empty", JSON.stringify(R.build("person", { name: "" })))
console.log(out.join("\n"))
EOF
out=$(node "$root/route.js" 2>&1)
echo "${DIM}$(sed 's/^/  /' <<<"$out")${RESET}"
check "odd names (a bare %, a colon) round-trip through the person route, a bare % travelling as %25" '["%","a:b","person:%25"]' "$(field odd "$out")"
check "a person with a colon and an accent round-trips" '{"view":"person","name":"Åse:1"}' "$(field person "$out")"
check "the four plain views parse" \
  '{"view":"setup","name":""} {"view":"people","name":""} {"view":"settings","name":""} {"view":"remove","name":""}' \
  "$(field setup "$out") $(field people "$out") $(field settings "$out") $(field remove "$out")"
check "an unknown view, an empty route and null are null" "null null null" \
  "$(field unknown "$out") $(field empty "$out") $(field null "$out")"
check "a person with no name or with extra segments is null" "null null" \
  "$(field person-no-name "$out") $(field person-extra "$out")"
check "a plain view with a segment, a broken escape and a huge route are null" "null null null" \
  "$(field plain-extra "$out") $(field bad-escape "$out") $(field long "$out")"
check "there is no enrol route: a scan is the standalone card in every home (it parses to null and builds nothing)" 'null null ""' \
  "$(field enrol-full "$out") $(field enrol-short "$out") $(field enrol-build "$out")"
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

step "(xi) the hosted panel pads its content the way the old hostedPanels slot and the stock popup do"
# The notch gives an integration's panel its own size and no margin (ExpandedHost
# in Bar.qml; maxWidth is already net of the notch's side padding), while the old
# hostedPanels slot had a margin of notchSidePadding, Style.space(14), on every
# side and KeyboardPanel pads by Style.spacing.popupPadding (14 too). So the panel
# adds 14 on every side inside its implicit size. (i) above compares it, pixel for
# pixel, with the stock content inside that same margin.
for route in people person:anna setup; do
  out=$(render hosted "$route" identity "$root/inset-${route//:/-}.png")
  insets=$(field insets "$out")
  # Style.space() scales with the theme's spacing: read what 14 is from the harness
  # itself (left), then require the same on the other three sides.
  read -r _ l _ t _ r _ b _ w <<<"$insets"
  check "$route: content has the same margin on all four sides, not zero" "true" \
    "$([[ $l -gt 0 && $l == "$t" && $l == "$r" && $l == "$b" ]] && echo true || echo false)"
  check "$route: …and the implicit size is the content's 320 plus that margin twice (not the bare 320)" "true" \
    "$(awk -v l="$l" -v w="${w%%x*}" 'BEGIN { print (w - 2 * l >= 300 && w > 320) ? "true" : "false" }')"
done
echo "${DIM}  margin and size, hosted: $insets${RESET}"

step "(xii) Test, inside the notch: its own view in the same home, not a card over the rows"
test_run() { # test_run <verify exit code> -> lines; PNGs at $root/testv-<code>-{a,b,c}.png
  : >"$logs/omarchy-shell.log"
  env "${face_env[@]}" OMARCHY_FACE_DEV_VERIFY="$1" FACE_HARNESS_CASE=test FACE_HARNESS_ROUTE=person:anna \
    FACE_HARNESS_HOST=identity FACE_HARNESS_OUT="$root/testv-$1.png" timeout 60 quickshell -p "$panel_root" -n 2>&1 \
    | tee -a "$logs/render.log" | sed -n 's/^.*HARNESS \([a-zA-Z0-9-]*\) \(.*\)$/\1=\2/p'
}
t0=$(test_run 0)
echo "${DIM}$(sed 's/^/  /' <<<"$t0")${RESET}"
check "before: the person view is up, and it is the hosted panel's current view" "person person-view true" "$(field before-view "$t0")"
check "pressing Test pushes a view of its own (a second step on the stack)" "test stack 3" "$(field test-view "$t0")"
check "…the verdict is in words, with the line that nothing was unlocked" "Recognised Anna|Nothing was unlocked — this was only a test." \
  "$(field headline "$t0")|$(field subline "$t0")"
check "…and the person view is NOT drawn under it (nothing to overlap)" "false" "$(field during-person-view "$t0")"
check "…it fits the panel: no taller than the person view was" "true" \
  "$(awk -v a="$(field size-a "$t0" | sed 's/.*x//')" -v b="$(field size-b "$t0" | sed 's/.*x//')" 'BEGIN { print (b > 0 && b <= a) ? "true" : "false" }')"
check "…and it never asked the service for its card (no testMatch call, no window)" "0" "$(grep -c testMatch "$logs/omarchy-shell.log")"
check "Esc goes back to the person view, and the request is dropped" "person person-view true test-request true" "$(field after-view "$t0")"
check "…the person view draws exactly as it did before (the PNG matches within the harness's noise)" "true" \
  "$(read -r _ n mx < <(pngdiff "$root/testv-0-a.png" "$root/testv-0-c.png"); within "$mx")"
check "…and the result is not the person view (different pixels, fully replacing it)" "true" \
  "$(read -r _ n mx < <(pngdiff "$root/testv-0-a.png" "$root/testv-0-b.png"); awk -v d="$n" 'BEGIN { print (d > 500) ? "true" : "false" }')"
t1=$(test_run 1)
check "a check that did not recognise says so" "Did not recognise Anna" "$(field headline "$t1")"
t3=$(test_run 3)
check "a helper that cannot check says that, not something about the person" "Face ID cannot check right now" "$(field headline "$t3")"
check "no case drew a TestCard in the notch: the panel's files name no window, and the card's copy is shared" "1 1" \
  "$(grep -c '^import "common/testverdict.js"' "$REPO/TestCard.qml") $(grep -c '^import "common/testverdict.js"' "$REPO/TestResultView.qml")"

step "(xiii) a scan is never hosted: Scan in the notch asks the service for its card and closes the panel"
# Start brings up polkit's password dialog, the notch loses focus to it and
# collapses, and a scan drawn inside it dies there (Phase 4's live gate). So the
# Scan buttons of People and Person do what the stock popup's do -- one call to
# the Face service, which owns RecordCard.qml (a window of its own) -- and the
# panel closes so there are not two surfaces.
record_run() { # record_run <route> -> lines; the stub logs the shell calls
  : >"$logs/omarchy-shell.log"
  env "${face_env[@]}" FACE_HARNESS_CASE=record FACE_HARNESS_ROUTE="$1" FACE_HARNESS_HOST=identity \
    timeout 60 quickshell -p "$panel_root" -n 2>&1 | tee -a "$logs/render.log" \
    | sed -n 's/^.*HARNESS \([a-zA-Z0-9-]*\) \(.*\)$/\1=\2/p'
}
r1=$(record_run people)
check "People: the Scan button is found on the hosted panel, which is on people" "found | people closes 0" "$(field button "$r1") | $(field before "$r1")"
check "People: pressing it leaves the view on people (no recording view pushed) and closes the panel" "people closes 1 stack 2" "$(field after "$r1")"
check "People: the shell was asked for the service's card for anna, and for nothing else" "kalinewb.face.card record anna No glasses Anna " "$(grep '^kalinewb.face.card' "$logs/omarchy-shell.log" | head -1)"
check "…and never for a panel in the notch (the only notch call is the integration's own rescan)" "0" "$(grep -c '^notch panel' "$logs/omarchy-shell.log")"
r2=$(record_run person:anna)
check "Person: the Re-record button closes the panel, with the view left on the person" "found | person closes 0 | person closes 1" \
  "$(field button "$r2") | $(field before "$r2" | sed 's/ stack.*//') | $(field after "$r2" | sed 's/ stack.*//')"
check "Person: the card is asked for anna's No glasses with her label" "kalinewb.face.card record anna No glasses Anna " "$(grep '^kalinewb.face.card' "$logs/omarchy-shell.log" | head -1)"
check "nothing in the panel's files shows or hosts a recording any more" "0" \
  "$(cd "$REPO" && sed -E 's#//.*$##' Surface.qml FaceViews.qml FaceModel.qml PeopleView.qml PersonView.qml SetupView.qml | grep -cE 'EnrolView|RecordSession|RecordView|showEnrol|enrolSession|previewLive|enrol\.json')"
check "the Face service answers record with the card and never asks the notch (no routing, no heartbeat, no enrol.json)" "0" \
  "$(cd "$REPO" && ls NotchRoute.qml 2>/dev/null | wc -l; sed -E 's#//.*$##' Service.qml | grep -cE 'NotchRoute|omarchy-shell.*notch|platform\.json|enrol\.json|notchPending')" | awk '{s+=$1} END {print s}'

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
