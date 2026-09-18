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
#     untyped, so qmllint cannot know them)
#   - `uncreatable-type` on PanelWindow and `signal-handler-parameters` on
#     Process.onExited, which are Quickshell's own type info being incomplete:
#     Omarchy's shipped QML produces both, and they run fine. QtMultimedia's
#     MediaDevices members are in the same class.

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
# `QObject` is the untyped injection above. `QMediaDevices` is Qt's own
# singleton, whose `videoInputs` and `defaultVideoInput` are real properties
# qmllint's type info does not carry -- named here rather than widening the
# check, so a genuine typo on any other type still fails.
typos=$(grep -E '\[missing-property\]' <<<"$out" \
  | grep -v 'on type "QObject"' | grep -v 'on type "QMediaDevices"' \
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

echo
if (( failures )); then echo "${RED}$failures check(s) failed${RESET}"; exit 1; fi
echo "${GREEN}everything passes${RESET}"
