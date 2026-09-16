#!/bin/bash

# G5c: the indicator's shape, as numbers (post-ship revision).
#
#   ./dev/g5c-island-offscreen.sh
#
# The card is a bar hanging from the top edge of the screen, fused to it the
# way a Dynamic Island is fused to its notch (Island.qml says how). Whether it
# looks fused is a judgement; whether it is BUILT right is arithmetic, and this
# does the arithmetic:
#
#   the numbers      -- the real Indicator.qml, with the real Style behind it,
#                       drawn for a second and a half on the built-in screen and
#                       asked for its bar rectangle, both radii and all four arc
#                       centres, in the bar's coordinates and the screen's
#   the pixels       -- Island.qml on its own, rendered offscreen at exactly
#                       those dimensions and sampled at the points that tell a
#                       fused bar from a pill and from a notch
#
# Nothing here judges a screenshot. The PNG is kept beside the log for a
# person who wants to look anyway.

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

# check_alpha <description> <opaque|clear> <x> <y>: a pixel is "opaque" at
# alpha >= 0.9 and "clear" at alpha <= 0.1; anything between is an antialiased
# edge, and the points below are chosen to stay off the edges.
check_alpha() {
  local alpha
  alpha=$(magick "$png" -format "%[fx:p{$3,$4}.a]" info: 2>/dev/null)
  local got
  if awk -v a="$alpha" 'BEGIN { exit !(a >= 0.9) }'; then got=opaque
  elif awk -v a="$alpha" 'BEGIN { exit !(a <= 0.1) }'; then got=clear
  else got="edge($alpha)"; fi
  check "$1 ${DIM}@($3,$4) α=$alpha${RESET}" "$2" "$got"
}

note() { echo "  ${YELLOW}note${RESET}  $*"; }
step() { echo; echo "${DIM}== $*${RESET}"; }

for tool in quickshell qml6 magick grim hyprctl jq python3; do
  command -v "$tool" >/dev/null || { echo "g5c: $tool is not installed" >&2; exit 1; }
done

SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Commons ]] || {
  echo "g5c: no Omarchy shell at $SHELL_PATH/shell" >&2
  exit 1
}

root=$(mktemp -d /tmp/omarchy-face-g5c.XXXXXX)
state=$root/state
png=$root/island.png
trap 'rm -rf "$root"' EXIT
mkdir -p "$state"
ln -s "$SHELL_PATH/shell/Commons" "$root/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$root/Ui"
ln -s "$REPO" "$root/face"
cp "$REPO/dev/qml-harness/island.qml" "$root/shell.qml"
cp "$REPO/dev/qml-harness/island-pixels.qml" "$root/island-pixels.qml"
cp "$REPO/dev/fixtures/three-people/people.json" "$state/people.json"

field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }
xof() { cut -d, -f1 <<<"$1"; }
yof() { cut -d, -f2 <<<"$1"; }
# Integer pixel that contains a real coordinate, and integer arithmetic on
# reals that are whole numbers in practice (Style tokens are px).
px() { awk -v v="$1" 'BEGIN { printf "%d", (v < 0 ? -int(-v) : int(v)) }'; }
calc() { awk "BEGIN { printf \"%.3f\", $* }"; }

echo "G5c — the island's geometry, as numbers"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO${RESET}"

# =============================================================================
# The numbers, from the shipped Indicator.qml
# =============================================================================

# =============================================================================
# The compositor: no animation of the card's window
# =============================================================================

step "Hyprland leaves the card's window alone"
# The rule Service.qml applies, rebuilt here from the namespace Indicator.qml
# declares, so that a drift between the two files fails here rather than on
# somebody's screen. `hyprctl eval` is also how the service applies it, and
# running it here means the captures below are taken with the rule in force
# whether or not the live shell has applied it yet.
namespace=$(sed -n 's/^.*readonly property string layerNamespace: "\([^"]*\)".*$/\1/p' "$REPO/Indicator.qml" | head -1)
rule="hl.layer_rule({ match = { namespace = \"$namespace\" }, no_anim = true, animation = \"none\" })"
check "Indicator.qml names its layer namespace" "omarchy-face-indicator" "$namespace"
check "…and the window uses that name" "true" \
  "$(grep -q 'WlrLayershell.namespace: root.layerNamespace' "$REPO/Indicator.qml" && echo true || echo false)"
check "Service.qml builds the rule from that name, with no animation" "true" \
  "$(grep -q 'namespace = "'"'"' + indicator.layerNamespace + '"'"'" }, no_anim = true, animation = "none"' "$REPO/Service.qml" && echo true || echo false)"
check "…applies it with hyprctl eval when it starts" "true" \
  "$(grep -A2 'command: \["hyprctl", "eval", root.indicatorLayerRule\]' "$REPO/Service.qml" | grep -q 'running: true' && echo true || echo false)"
check "…and again after every config reload" "true" \
  "$(grep -q '"configreloaded") indicatorLayerRuleProcess.running = true' "$REPO/Service.qml" && echo true || echo false)"
check "this Hyprland accepts that rule" "ok" "$(hyprctl eval "$rule" 2>&1 | tr -d '\n')"

# =============================================================================
# The numbers, from the shipped Indicator.qml
# =============================================================================

step "the shipped card, at rest, on the built-in screen"
# A strip of the real screen, 340 px wide around the horizontal centre of the
# built-in panel and 160 px down from its top edge, in logical pixels. Grabbed
# once now, before the card exists, and again by the harness at 0/60/150/400 ms
# after the card's window comes up.
captures=$root/captures
mkdir -p "$captures"
monitor=$(hyprctl -j monitors | jq -c '([.[] | select(.name | test("^(eDP|LVDS|DSI)"; "i"))] + .)[0]')
geometry=$(jq -r '"\(.x + ((.width / .scale) / 2 | floor) - 170),\(.y) 340x160"' <<<"$monitor")
timeout 10 grim -s 1 -g "$geometry" "$captures/baseline.png" || note "no baseline grab (grim failed); the screen check will be skipped"

at=$(date +%s%3N)
printf '{"state":"start","service":"sudo","requester":{"command":"pacman","from":"foot"},"person":"","detail":"","at":%s}\n' \
  "$at" >"$state/state.json"
out=$(env OMARCHY_FACE_DEV_BIN="$REPO/dev/bin" OMARCHY_FACE_DEV_STATE="$state" \
  FACE_HARNESS_CAPTURE_DIR="$captures" FACE_HARNESS_CAPTURE_GEOMETRY="$geometry" \
  timeout 60 quickshell -p "$root" -n 2>&1 | sed -n 's/^.*HARNESS \([a-zA-Z0-9]*\) \(.*\)$/\1=\2/p')
[[ -n $out ]] || { echo "  ${RED}FAIL${RESET}  the harness printed nothing (QML did not load)"; exit 1; }
check "the card is up" "true" "$(field showing "$out")"
check "…and its entrance has finished, in both dimensions" "1 1" "$(field heightP "$out") $(field widthP "$out")"
check "…and the shape could be reached inside its window" "true" "$(field cardFound "$out")"
[[ $(field cardFound "$out") == true ]] || exit 1

W=$(field barWidth "$out")
H=$(field barHeight "$out")
R=$(field bottomRadius "$out")
F=$(field filletRadius "$out")
BX=$(field barX "$out")
BY=$(field barY "$out")

echo
echo "  ${DIM}screen${RESET}                 $(field screen "$out") (logical px)"
echo "  ${DIM}bar rectangle${RESET}          x=$BX y=$BY w=$W h=$H  ${DIM}(island x=$(field islandX "$out"), w=$(field islandWidth "$out"))${RESET}"
echo "  ${DIM}top corner radii${RESET}       left=$(field topLeftRadius "$out") right=$(field topRightRadius "$out")"
fmt() { awk -v v="$1" 'BEGIN { printf "%.4g", v }'; }
echo "  ${DIM}bottom corner radius${RESET}   $(fmt "$R")  ${DIM}(requested $(fmt "$(field bottomRadiusRequested "$out")") = $(field bottomRadiusFraction "$out") × height; convex, both corners)${RESET}"
echo "  ${DIM}fillet radius${RESET}          $(fmt "$F")  ${DIM}(requested $(fmt "$(field filletRadiusRequested "$out")") = $(field filletFull "$out") px × height/settled height; concave, both sides)${RESET}"
echo "  ${DIM}arc centres, bar coordinates (origin: bar's top-left, y down)${RESET}"
echo "    left fillet    $(field leftFilletCentreBar "$out")"
echo "    right fillet   $(field rightFilletCentreBar "$out")"
echo "    bottom-left    $(field bottomLeftCentreBar "$out")"
echo "    bottom-right   $(field bottomRightCentreBar "$out")"
echo "  ${DIM}arc centres, screen coordinates${RESET}"
echo "    left fillet    $(field leftFilletCentreScreen "$out")"
echo "    right fillet   $(field rightFilletCentreScreen "$out")"
echo "    bottom-left    $(field bottomLeftCentreScreen "$out")"
echo "    bottom-right   $(field bottomRightCentreScreen "$out")"
echo "  ${DIM}entrance${RESET}               height $(field heightDuration "$out") ms; width after $(field widthDelay "$out") ms, over $(field widthDuration "$out") ms"
echo "  ${DIM}spring${RESET}                 damping ratio $(field springDamping "$out"), overshoot $(awk -v m="$(field springOvershoot "$out")" 'BEGIN { printf "%.1f%%", m * 100 }'), peak at $(field springPeakAt "$out") of the duration"
echo "  ${DIM}bezier${RESET}                 $(field springCurve "$out")"
echo "  ${DIM}seed (progress 0)${RESET}      $(field seedWidthFraction "$out") × width, $(field seedHeightFraction "$out") × height; exit retracts to progress $(field widthGone "$out") / $(field heightGone "$out") (zero size)"
echo "  ${DIM}first sight of the card${RESET} y=$(field firstY "$out") w=$(field firstBarWidth "$out") h=$(field firstBarHeight "$out") bottom r=$(field firstBottomRadius "$out") fillet r=$(field firstFilletRadius "$out")  ${DIM}(heightP $(field firstHeightP "$out"), widthP $(field firstWidthP "$out"))${RESET}"
echo

step "what the numbers have to satisfy"
check "the bar's top edge is on the screen's top edge" "0" "$BY"
check "the settled bar is a little wider than tall (1.1 to 1.4 times)" "true" \
  "$(awk -v w="$W" -v h="$H" 'BEGIN { r = w / h; print (r >= 1.1 && r <= 1.4) ? "true" : "false" }')"
check "the top corners have no radius" "0 0" "$(field topLeftRadius "$out") $(field topRightRadius "$out")"
check "the bottom radius is a fifth of the height" "true" \
  "$(awk -v r="$R" -v h="$H" 'BEGIN { d = r / h - 0.2; print (d < 0.005 && d > -0.005) ? "true" : "false" }')"
check "…which is well short of half the height (a rounded rectangle, not a pill)" "true" \
  "$(awk -v r="$R" -v h="$H" 'BEGIN { print (r < 0.3 * h) ? "true" : "false" }')"
check "…and fits the bar" "true" \
  "$(awk -v r="$R" -v w="$W" -v h="$H" 'BEGIN { print (r > 0 && r <= w / 2 && r <= h) ? "true" : "false" }')"
check "the fillet radius is 10 px when settled" "10" "$(awk -v f="$F" 'BEGIN { printf "%g", f }')"
check "…and leaves a straight side above the bottom corner" "true" \
  "$(awk -v f="$F" -v r="$R" -v h="$H" 'BEGIN { print (f > 0 && f <= h - r) ? "true" : "false" }')"
lc=$(field leftFilletCentreBar "$out"); rc=$(field rightFilletCentreBar "$out")
check "the left fillet's centre is one radius outside the bar's left side, one radius down" \
  "$(calc -"$F"),$(calc "$F")" "$lc"
check "the right fillet's centre is one radius outside the bar's right side, one radius down" \
  "$(calc "$W" + "$F"),$(calc "$F")" "$rc"
check "neither fillet centre lies inside the bar" "true" \
  "$(awk -v lx="$(xof "$lc")" -v rx="$(xof "$rc")" -v w="$W" 'BEGIN { print (lx < 0 && rx > w) ? "true" : "false" }')"
check "the entrance is height first, width 50 ms later, both landing together" "true" \
  "$(awk -v h="$(field heightDuration "$out")" -v d="$(field widthDelay "$out")" -v w="$(field widthDuration "$out")" \
     'BEGIN { print (h == 350 && d == 50 && w == 300 && d + w == h) ? "true" : "false" }')"
check "the spring overshoots once, by roughly four percent" "true" \
  "$(awk -v m="$(field springOvershoot "$out")" 'BEGIN { print (m >= 0.03 && m <= 0.05) ? "true" : "false" }')"
check "…with a damping ratio near three quarters" "true" \
  "$(awk -v z="$(field springDamping "$out")" 'BEGIN { print (z >= 0.7 && z <= 0.8) ? "true" : "false" }')"
check "…and its easing curve actually rises past 1 before it ends there" "true" \
  "$(python3 -c '
import json,sys
pts=json.loads(sys.argv[1]); ys=pts[1::2]
print("true" if max(ys) > 1.02 and pts[-2] == 1 and pts[-1] == 1 else "false")' "$(field springCurve "$out")")"
check "the card was seen before its entrance had finished" "true" \
  "$(awk -v p="$(field firstHeightP "$out")" 'BEGIN { print (p < 1) ? "true" : "false" }')"
check "at first sight its top edge was on the screen's top edge" "0" "$(field firstY "$out")"
check "…it already had height and width" "true" \
  "$(awk -v w="$(field firstBarWidth "$out")" -v h="$(field firstBarHeight "$out")" 'BEGIN { print (w > 0 && h > 0) ? "true" : "false" }')"
check "…its fillets were already on it" "true" \
  "$(awk -v f="$(field firstFilletRadius "$out")" 'BEGIN { print (f > 0) ? "true" : "false" }')"
check "…and its bottom radius was still a fifth of its height, not half" "true" \
  "$(awk -v r="$(field firstBottomRadius "$out")" -v h="$(field firstBarHeight "$out")" 'BEGIN { d = r / h - 0.2; print (d < 0.005 && d > -0.005) ? "true" : "false" }')"
check "the island is centred on the screen" "true" \
  "$(awk -v x="$(field islandX "$out")" -v w="$(field islandWidth "$out")" -v s="$(field screen "$out" | cut -dx -f1)" \
     'BEGIN { d = x + w / 2 - s / 2; print (d < 1 && d > -1) ? "true" : "false" }')"

step "the first frames, on the real screen ($geometry)"
# Each grab against the baseline: a pixel is "new black" when it is within 16
# of pure black now and was not that before. The bar is the widest run of new
# black in each row. In every grab that has the bar in it at all, the first
# row that has one must be row 0 -- the screen's top edge -- and the run there
# must be at least the seed width: a compositor pop-in would put the first row
# tens of pixels down and shrink the run; a slide would move it; a fade would
# thin it below black. The bar is a BLOCK: the tallest stretch of consecutive
# rows that each have such a run, and it has to be at least five rows tall to
# count -- a lone row of new black is something else on the desktop changing
# under the strip (a cursor, a glyph), not a bar. A grab with no block in it is
# a grab from before the compositor had mapped the window (the first one, a
# few dozen ms after the window object existed, usually is) and proves nothing
# either way -- so at least one grab inside the first 150 ms has to show the
# bar, or the check is vacuous.
if [[ -f $captures/baseline.png ]]; then
  early_seen=false
  for i in 0 1 2 3 4; do
    when=$(field "capture${i}At" "$out")
    [[ -f $captures/capture-$i.png ]] || { check "grab $i (at ${when:-?} ms) exists" "true" "false"; continue; }
    read -r top run0 bottom < <(python3 - "$captures/baseline.png" "$captures/capture-$i.png" <<'PY'
import subprocess, sys
def load(path):
    data = subprocess.run(["magick", path, "-depth", "8", "ppm:-"], capture_output=True, check=True).stdout
    # P6 header: magic, width, height, maxval, then binary
    parts = data.split(maxsplit=4)
    w, h = int(parts[1]), int(parts[2])
    px = parts[4][: w * h * 3]
    return w, h, px
w, h, base = load(sys.argv[1])
w2, h2, cap = load(sys.argv[2])
assert (w, h) == (w2, h2)
def black(px, i): return max(px[i], px[i + 1], px[i + 2]) <= 16
runs = []
for y in range(h):
    best = 0; run = 0
    for x in range(w):
        i = (y * w + x) * 3
        if black(cap, i) and not black(base, i):
            run += 1; best = max(best, run)
        else:
            run = 0
    runs.append(best)
# The tallest block of consecutive rows with a run of at least 20 px.
top = -1; bottom = -1; y = 0
while y < h:
    if runs[y] >= 20:
        start = y
        while y < h and runs[y] >= 20: y += 1
        if y - start > bottom - top: top, bottom = start, y - 1
    else:
        y += 1
if top >= 0 and bottom - top + 1 < 5: top = bottom = -1
print(top, runs[0], bottom)
PY
)
    if [[ $top == -1 ]]; then
      note "grab $i at ${when:-?} ms: no bar on screen yet (the window was not mapped)"
      continue
    fi
    echo "  ${DIM}grab $i at ${when:-?} ms: new black from row $top to $bottom, run on row 0 = $run0 px${RESET}"
    check "grab $i (at ${when:-?} ms): the bar's first row is the screen's top row" "0" "$top"
    check "…and it already spans at least the seed width there" "true" \
      "$(awk -v r="$run0" -v w="$W" -v f="$(field seedWidthFraction "$out")" 'BEGIN { print (r >= w * f * 0.9) ? "true" : "false" }')"
    if awk -v t="${when:-9999}" 'BEGIN { exit !(t <= 150) }'; then early_seen=true; fi
  done
  check "at least one grab inside the first 150 ms had the bar in it" "true" "$early_seen"
  [[ -n ${G5C_KEEP_PNG:-} ]] && cp "$captures"/*.png "$(dirname "$G5C_KEEP_PNG")/" 2>/dev/null
fi

# =============================================================================
# The pixels, from Island.qml at those dimensions
# =============================================================================

step "Island.qml offscreen at ${W}×${H}, bottom r=$(fmt "$R"), fillet r=$(fmt "$F")"
# QT_FORCE_STDERR_LOGGING: Arch's Qt sends messages to the journal when stderr is
# not a terminal, and qml6 has no handler of its own to say otherwise.
geom=$(QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 timeout 30 qml6 "$root/island-pixels.qml" -- \
  "w=$W" "h=$H" "r=$R" "fillet=$F" "out=$png" 2>&1 | sed -n 's/^.*GEOM \([a-zA-Z]*\) \(.*\)$/\1=\2/p')
check "the shape rendered to a PNG" "true" "$(field saved "$geom")"
[[ -f $png ]] || exit 1
echo "  ${DIM}$(identify -format '%wx%h' "$png"); bar at x=$(field barX "$geom"), fillet centres $(field leftFilletCentre "$geom") and $(field rightFilletCentre "$geom")${RESET}"

bx=$(px "$(field barX "$geom")")           # first pixel column of the bar
bw=$(px "$W"); bh=$(px "$H"); f=$(px "$F"); r=$(px "$R")
bxr=$((bx + bw - 1))                        # last pixel column of the bar
top=0

step "the bar is a rectangle with square top corners (not a pill)"
check_alpha "the bar's top-left corner pixel is solid" opaque "$bx" "$top"
check_alpha "the bar's top-right corner pixel is solid" opaque "$bxr" "$top"
check_alpha "so is the bar just inside its top-left corner" opaque "$((bx + 5))" 5
check_alpha "so is the bar just inside its top-right corner" opaque "$((bxr - 5))" 5
check "every pixel of the bar's top row is solid" "1" \
  "$(magick "$png" -crop "${bw}x1+${bx}+0" +repage -channel A -separate -format '%[fx:minima]' info:)"

step "the bottom corners are ordinary convex rounds"
check_alpha "the bottom-left corner pixel is empty" clear "$bx" "$((bh - 1))"
check_alpha "the bottom-right corner pixel is empty" clear "$bxr" "$((bh - 1))"
check_alpha "the bottom edge is solid one radius in" opaque "$((bx + r + 2))" "$((bh - 1))"
check_alpha "the side is solid one radius up" opaque "$bx" "$((bh - 3 - r))"

step "the fillets hug the corners from outside (not a notch)"
# The fillet is thickest on the diagonal from the bar's corner toward the arc
# centre: r(√2−1) ≈ 0.41 r. Two pixels in along it is material; five is past
# the arc, back in the open; the centre itself is open.
check_alpha "left: the screen edge just outside the bar is solid" opaque "$((bx - 1))" "$top"
check_alpha "left: two pixels down the diagonal is fillet" opaque "$((bx - 2))" 2
check_alpha "left: five pixels down the diagonal is past the arc" clear "$((bx - 5))" 5
check_alpha "left: the arc's centre is open background" clear "$((bx - f))" "$f"
check_alpha "right: the screen edge just outside the bar is solid" opaque "$((bxr + 1))" "$top"
check_alpha "right: two pixels down the diagonal is fillet" opaque "$((bxr + 2))" 2
check_alpha "right: five pixels down the diagonal is past the arc" clear "$((bxr + 5))" 5
check_alpha "right: the arc's centre is open background" clear "$((bxr + f))" "$f"
check_alpha "left: below the fillet the side is bare" clear "$((bx - 1))" "$((f + 2))"
check_alpha "right: below the fillet the side is bare" clear "$((bxr + 1))" "$((f + 2))"

step "no seam where a fillet meets the bar"
check "the bar's first column is solid all the way down the fillet" "1" \
  "$(magick "$png" -crop "1x${f}+${bx}+0" +repage -channel A -separate -format '%[fx:minima]' info:)"
check "so is its last column" "1" \
  "$(magick "$png" -crop "1x${f}+${bxr}+0" +repage -channel A -separate -format '%[fx:minima]' info:)"

keep=${G5C_KEEP_PNG:-}
if [[ -n $keep ]]; then cp "$png" "$keep" && note "png kept at $keep"; fi

echo
if ((failures == 0)); then
  echo "${GREEN}G5c passes.${RESET} ${DIM}$checks checks.${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
