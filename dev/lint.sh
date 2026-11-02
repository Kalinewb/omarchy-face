#!/bin/bash

# Check this plugin before Omarchy runs it.
#
#   ./dev/lint.sh
#
# A third-party plugin with a QML error does not reach the journal: it just
# fails to appear in the bar, with no message anywhere. qmllint catches that
# first, resolving `qs.*` imports against the installed Omarchy shell.
#
# It also runs `bash -n` over every shipped script, and `shellcheck -S error`
# when it is installed, so one command says whether this copy is fit to install.
#
# Fails when:
#   - qmllint exits non-zero (a syntax error exits 255), or
#   - any warning in a category that means "this will not load or bind"
#     (syntax, import, missing-type, unresolved-type, incompatible-type,
#     read-only-property, duplicated-name, required, ...), or
#   - a `missing-property` warning on a real type. Those are typos against
#     somebody else's API -- a name that does not exist binds to undefined and
#     fails silently at runtime, which is the hardest kind to find.
#
# Reported but not fatal:
#   - `unqualified` access (the QML is written that way throughout)
#   - members "not found on type QObject" (`bar` and Style tokens arrive
#     untyped, so qmllint cannot know them), and on a Loader's untyped `item`
#   - `uncreatable-type` on PanelWindow and `signal-handler-parameters` on
#     Process.onExited, which are Quickshell's own type info being incomplete:
#     Omarchy's shipped QML produces both, and they run fine.

set -uo pipefail

GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
QMLLINT=/usr/lib/qt6/bin/qmllint
SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -x $QMLLINT ]] || { echo "lint: $QMLLINT is not installed (qt6-declarative)" >&2; exit 1; }
[[ -d $SHELL_PATH/shell ]] || { echo "lint: no Omarchy shell at $SHELL_PATH/shell" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-face-lint.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/qmlpath"
ln -sfn "$SHELL_PATH/shell" "$work/qmlpath/qs"

FATAL='syntax|import|missing-type|unresolved-type|incompatible-type|read-only-property|duplicated-name|required|unresolved-alias|missing-enum-entry|recursion-depth-errors|attached-property-reuse|non-list-property'

cd "$REPO"
mapfile -t files < <(git ls-files '*.qml' ':!dev/**' 2>/dev/null || find . -maxdepth 1 -name '*.qml' -printf '%P\n')
failures=0

echo "${BOLD}QML lint${RESET}  ${DIM}${#files[@]} files, qs.* → $SHELL_PATH/shell${RESET}"
out=$("$QMLLINT" -I "$work/qmlpath" -I /usr/lib/qt6/qml "${files[@]}" 2>&1); rc=$?

# Load-breaking categories.
fatal=$(sed -nE "s#^(Warning|Error): (.*) \[($FATAL)\]\$#  \2 [\3]#p" <<<"$out")
# A member missing on a real type: a typo against someone's API. Members on
# QObject are the untyped injections and are expected.
# `QObject` is the untyped injection above, and qmllint names it two ways: `on
# type "QObject"` for an injected property, and `…::item with type QObject` for
# a Loader's `item`, which is untyped by definition (the newer wording, which
# made this check fail at a clean HEAD). Anything else still fails.
#
# There used to be a third exception, for `QMediaDevices`, on the theory that
# qmllint's type info lacked `videoInputs`. It did not: RecordPreview.qml was
# reading those off the TYPE, where they are undefined, and the recording
# card's preview never showed a camera. The warning was the bug.
typos=$(grep -E '\[missing-property\]' <<<"$out" \
  | grep -v 'on type "QObject"' | grep -v 'with type QObject \[missing-property\]$' \
  | sed -E 's#^Warning: #  #')

counts=$(sed -nE 's#.*\[([a-z-]+)\]$#\1#p' <<<"$out" | sort | uniq -c | sort -rn | awk '{printf "%s %s, ", $1, $2}')
echo "  ${DIM}qmllint exit $rc; ${counts%, }${RESET}"

if (( rc != 0 )); then
  echo "  ${RED}FAIL${RESET}  qmllint exited $rc"
  grep -E '^Error:' <<<"$out" | head -20
  failures=$((failures + 1))
elif [[ -n $fatal ]]; then
  echo "  ${RED}FAIL${RESET}  warnings that mean the QML will not load or bind:"
  printf '%s\n' "$fatal" | head -20
  failures=$((failures + 1))
elif [[ -n $typos ]]; then
  echo "  ${RED}FAIL${RESET}  a member that does not exist on a real type:"
  printf '%s\n' "$typos" | head -20
  failures=$((failures + 1))
else
  echo "  ${GREEN}pass${RESET}  no QML errors, nothing that stops it loading, and no unknown members"
fi

echo
echo "${BOLD}Shell${RESET}"
mapfile -t scripts < <(git ls-files "bin/*" "system/omarchy-face-*" "dev/*.sh" "*.sh" 2>/dev/null)
# Only the shell ones: this repo's system half includes python helpers, and
# neither bash -n nor shellcheck has anything to say about those.
bad=() shell_scripts=()
for script in "${scripts[@]}"; do
  [[ -f $script ]] || continue
  head -n1 "$script" | grep -qE '^#!.*[/ ](bash|sh)$' || continue
  shell_scripts+=("$script")
  bash -n "$script" 2>/dev/null || bad+=("$script")
done
if (( ${#bad[@]} )); then
  echo "  ${RED}FAIL${RESET}  syntax errors: ${bad[*]}"
  failures=$((failures + 1))
else
  echo "  ${GREEN}pass${RESET}  ${#shell_scripts[@]} shell scripts parse"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S error "${shell_scripts[@]}" >/dev/null 2>&1; then
    echo "  ${GREEN}pass${RESET}  shellcheck (errors only) is clean"
  else
    echo "  ${RED}FAIL${RESET}  shellcheck reports errors:"
    shellcheck -S error "${shell_scripts[@]}" 2>&1 | head -20
    failures=$((failures + 1))
  fi
else
  echo "  ${DIM}skip  shellcheck is not installed${RESET}"
fi

# Hosting (plan-face-enroll.md 6a.2c): the integration draws inside the host and
# never opens a window of its own. The host's own check reads the entry file
# only, so this one reads every file Surface.qml instantiates, with `//`
# comments blanked (a window type named in a comment is not a window). The
# card, which is a window, is named by the Face service alone.
echo
echo "${BOLD}Hosting${RESET}"
hosted_files=(Surface.qml FaceViews.qml FaceModel.qml TestResultView.qml EnrolView.qml EnrolRing.qml RecordView.qml RecordSession.qml RecordPreview.qml
              PeopleView.qml PersonView.qml SetupView.qml SettingsView.qml RemoveView.qml common/Ask.qml common/EnrolLink.qml)
window_type() { sed -E 's#//.*$##' | grep -nE '\b(PanelWindow|PopupWindow|FloatingWindow)\b'; }
card_name() { sed -E 's#//.*$##' | grep -nE '\bRecordCard\b'; }
if ! printf 'Item {\n  // PanelWindow in a comment\n  PanelWindow { }\n}\n' | window_type | grep -q 'PanelWindow { }' \
   || printf '// PanelWindow, PopupWindow, FloatingWindow\n' | window_type | grep -q .; then
  echo "  ${RED}FAIL${RESET}  the window check's own self-test (a planted PanelWindow must match, a comment must not)"
  failures=$((failures + 1))
fi
named=()
for f in "${hosted_files[@]}"; do
  [[ -f $f ]] || { named+=("$f is missing"); continue; }
  window_type <"$f" | grep -q . && named+=("$f opens a window")
  card_name <"$f" | grep -q . && named+=("$f names RecordCard")
done
for f in *.qml; do
  [[ $f == Service.qml || $f == RecordCard.qml ]] && continue
  card_name <"$f" | grep -q . && named+=("$f names RecordCard")
done
if (( ${#named[@]} )); then
  echo "  ${RED}FAIL${RESET}  ${named[*]}"
  failures=$((failures + 1))
else
  echo "  ${GREEN}pass${RESET}  the ${#hosted_files[@]} files Surface.qml is made of open no window, and only the service names the card"
fi

# The RGB camera is fenced to the enrol view (plan-face-enroll.md 6a.2). One file
# may touch QtMultimedia, one file may name that one, and nothing that sets a
# camera up may appear anywhere else. Comments and string literals are blanked
# first, so prose that says "Camera" is not a Camera (SetupView.qml:151 and the
# lock screen's "Camera waking?" are the self-test).
echo
echo "${BOLD}The RGB camera${RESET}"
camera_re='import QtMultimedia|\bCamera\s*\{|MediaDevices\s*\{|CaptureSession\s*\{|ImageCapture|MediaRecorder|VideoSink'
blank() { sed -E 's#"([^"\\]|\\.)*"##g; s#//.*$##'; }
camera_hits() { blank | grep -nE "$camera_re"; }
if printf 'Text { text: "Camera, system files and engine..." }\n' | camera_hits | grep -q . \
   || printf 'Text { text: "Camera waking?" } // Camera { in a comment\n' | camera_hits | grep -q . \
   || ! printf 'Item {\n  Camera {\n  }\n}\n' | camera_hits | grep -q 'Camera {'; then
  echo "  ${RED}FAIL${RESET}  the camera check's own self-test (the prose lines must not match, a planted Camera { must)"
  failures=$((failures + 1))
fi
camera_bad=()
mapfile -t all_qml < <(git ls-files '*.qml')
for f in "${all_qml[@]}"; do
  [[ $f == dev/* || $f == RecordPreview.qml ]] && continue
  camera_hits <"$f" | grep -q . && camera_bad+=("$f sets up a camera")
done
camera_hits <RecordPreview.qml | grep -q 'Camera {' || camera_bad+=("RecordPreview.qml no longer has the one Camera")
for f in "${all_qml[@]}"; do
  [[ $f == dev/* || $f == EnrolView.qml || $f == RecordPreview.qml ]] && continue
  sed -E 's#//.*$##' "$f" | grep -q 'RecordPreview' && camera_bad+=("$f names RecordPreview")
  case $f in EnrolView.qml|RecordCard.qml|FaceModel.qml|FaceViews.qml|Surface.qml|Service.qml) continue ;; esac
  sed -E 's#//.*$##' "$f" | grep -qE 'previewDevice|camera\.rgb' && camera_bad+=("$f reads the RGB node")
done
# Nothing that recognises a face on its own names the RGB node (omarchy-face-camera
# only prints names; omarchy-face-status may read `--describe` for the view).
for f in system/omarchy-faced system/omarchy-face-verify system/omarchy-face-lock-verify system/omarchy-face-gate \
         system/omarchy-face-identity system/omarchy-face-admin system/omarchy-faced.service system/omarchy-faced.socket \
         bin/omarchy-face-lock lock/Service.qml; do
  [[ -f $f ]] || continue
  grep -qEi -- '--rgb-node|/dev/video|\brgb\b' "$f" && camera_bad+=("$f names an RGB node or a video device")
done
# systemd's DeviceAllow cannot name the IR node (its /dev/videoN is not stable), so
# the daemon is not fenced by the unit; this pin makes a change to it deliberate.
allow=$(grep -E '^(DeviceAllow|DevicePolicy)=' system/omarchy-faced.service | tr '\n' '|')
[[ $allow == 'DevicePolicy=closed|DeviceAllow=char-video4linux rw|' ]] || camera_bad+=("omarchy-faced.service's DevicePolicy/DeviceAllow lines changed (got: $allow)")
if (( ${#camera_bad[@]} )); then
  echo "  ${RED}FAIL${RESET}  ${camera_bad[*]}"
  failures=$((failures + 1))
else
  echo "  ${GREEN}pass${RESET}  only RecordPreview.qml sets up a camera, only EnrolView.qml names it, no RGB node is named in the daemon, gate, lock or admin, and the unit's DeviceAllow line is as pinned"
fi

echo
if (( failures )); then echo "${RED}$failures check(s) failed${RESET}"; exit 1; fi
echo "${GREEN}everything passes${RESET}"
