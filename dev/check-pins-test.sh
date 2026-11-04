#!/bin/bash

# Mutation tests for dev/check-pins.sh: each case copies the tree to scratch, breaks one thing the
# check is meant to catch, regenerates the pins (so that only THAT thing is wrong) and requires
# check-pins to fail with the expected message; the unmutated copy must pass.
#
#   ./dev/check-pins-test.sh

set -uo pipefail
GREEN=$'\e[32m'; RED=$'\e[31m'; RESET=$'\e[0m'
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
failures=0; checks=0
root=$(mktemp -d /tmp/omarchy-face-pins.XXXXXX)
trap 'rm -rf "$root"' EXIT

fresh() { rm -rf "$root/t"; mkdir "$root/t"; (cd "$REPO" && tar --exclude=.git -cf - .) | tar -xf - -C "$root/t"; }
run() { (cd "$root/t" && ./dev/update-pins.sh >/dev/null 2>&1; ./dev/check-pins.sh 2>&1); }
expect() { # expect <description> <pattern or ok>
  checks=$((checks + 1))
  local out; out=$(run); local rc=$?
  if [[ $2 == ok ]]; then
    if grep -q '^check-pins: ok' <<<"$out"; then echo "  ${GREEN}pass${RESET}  $1"; else echo "  ${RED}FAIL${RESET}  $1"; echo "$out" | sed 's/^/        /'; failures=$((failures + 1)); fi
  else
    if ! grep -q '^check-pins: ok' <<<"$out" && grep -q "$2" <<<"$out"; then echo "  ${GREEN}pass${RESET}  $1"; else echo "  ${RED}FAIL${RESET}  $1 (wanted '$2')"; echo "$out" | sed 's/^/        /'; failures=$((failures + 1)); fi
  fi
}

echo "check-pins mutations"
fresh; expect "the tree as it is passes" ok
fresh; sed -i 's/omarchy-face v2/omarchy-face v1/' "$root/t/system/omarchy-faced.socket"
expect "a system file without the 'omarchy-face v2' marker (the installer's snapshot_unmarked) fails" "no 'omarchy-face v2' marker"
fresh; python3 - "$root/t/system/omarchy-face-gate" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n")
# the marker pushed past line 40 is as good as absent for the runtime
lines = [l for l in lines if "omarchy-face v2" not in l]
lines = lines[:40] + ["# omarchy-face v2"] + lines[40:]
open(p, "w").write("\n".join(lines))
PY
expect "a marker beyond the first 40 lines fails" "no 'omarchy-face v2' marker"
fresh; sed -i 's/^# omarchy-face-version: .*/# omarchy-face-version: 0.0.1/' "$root/t/bin/omarchy-face-status"
expect "a bin/ header that disagrees with install.sh fails" "bin/omarchy-face-status says 0.0.1"
fresh; sed -i '/omarchy-face-version/d' "$root/t/bin/omarchy-face-lock"
expect "a bin/ file with no version header fails" "no omarchy-face-version header"
fresh; sed -i 's/"version": "[^"]*"/"version": "9.9.9"/' "$root/t/manifest.json"
expect "a manifest that disagrees fails" "manifest.json says 9.9.9"
fresh; sed -i 's/systemVersion: "[^"]*"/systemVersion: "9.9.9"/' "$root/t/common/Ask.qml"
expect "common/Ask.qml that disagrees with install.sh fails" "says 9.9.9"

echo
if ((failures == 0)); then echo "${GREEN}$checks checks, all passed${RESET}"; else echo "${RED}$checks checks, $failures failed${RESET}"; fi
exit $((failures > 0))
