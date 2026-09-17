#!/bin/bash
#
# Do the pins in system/install.sh match the files, and cover exactly the admin
# helper's SYSTEM_FILES table? A stale pin weakens nothing -- root refuses the
# install -- but it breaks installing for everyone on that commit, so it is
# caught here, before a sync or a release.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

mapfile -t names < <(sed -n '/^SYSTEM_FILES=(/,/^)/p' system/omarchy-face-admin |
  sed -n 's/^[[:space:]]*"\([^:"]*\):.*/\1/p')
mapfile -t pinned < <(sed -n '/^# pins:begin$/,/^# pins:end$/p' system/install.sh |
  sed -n 's/^[[:space:]]*\[\([^]]*\)\]=\([0-9a-f]*\)$/\1 \2/p')

bad=0
declare -A pin=()
for line in "${pinned[@]}"; do pin[${line%% *}]=${line##* }; done

for name in "${names[@]}"; do
  if [[ -z ${pin[$name]:-} ]]; then
    echo "check-pins: system/$name has no pin" >&2; bad=1; continue
  fi
  got=$(sha256sum -- "system/$name" 2>/dev/null | cut -d' ' -f1)
  [[ $got == "${pin[$name]}" ]] || { echo "check-pins: system/$name does not match its pin" >&2; bad=1; }
  unset "pin[$name]"
done
for extra in "${!pin[@]}"; do
  echo "check-pins: $extra is pinned but not in SYSTEM_FILES" >&2; bad=1
done

if ((bad)); then
  echo "check-pins: run dev/update-pins.sh" >&2
  exit 1
fi
echo "check-pins: ok — ${#names[@]} files match"
