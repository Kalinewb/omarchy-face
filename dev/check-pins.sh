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

# The installer's own checksum is no longer published inside the README's
# command -- the command fetches it from this release's tag -- so what has to
# match is the file that tag will serve.
installer=$(sha256sum -- system/install.sh | cut -d' ' -f1)
if [[ ! -f system/install.sh.sha256 ]]; then
  echo "check-pins: system/install.sh.sha256 is missing" >&2; bad=1
elif [[ $(cat system/install.sh.sha256) != "$installer" ]]; then
  echo "check-pins: system/install.sh.sha256 is not system/install.sh's checksum" >&2; bad=1
fi

# One version, in two files that cannot ask each other at runtime: the panel
# builds the fetch URL from its copy, and a drift would point the install at a
# tag that describes different bytes.
qml_version=$(sed -n 's/^[[:space:]]*readonly property string systemVersion: "\([^"]*\)"/\1/p' common/Ask.qml)
sh_version=$(sed -n 's/^# omarchy-face-version: //p' system/install.sh)
if [[ -z $qml_version || -z $sh_version ]]; then
  echo "check-pins: could not read the version from common/Ask.qml or system/install.sh" >&2; bad=1
elif [[ $qml_version != "$sh_version" ]]; then
  echo "check-pins: common/Ask.qml says $qml_version, system/install.sh says $sh_version" >&2; bad=1
fi

# The README's command is what a suspicious reader compares the clipboard
# against, so it has to be the panel's command exactly.
qml_command=$(dev/install-command.py) || bad=1
readme_command=$(sed -n '/^### Installing or updating the system files$/,/^```$/p' README.md |
                 sed -n '/^```bash$/,/^```$/p' | sed '1d;$d')
# Both empty compares equal, and two empties is the likely shape of a renamed
# heading plus a broken extractor -- the one case where a silent pass would ship
# a README the panel does not agree with.
if [[ -z $qml_command || -z $readme_command ]]; then
  echo "check-pins: the install command is empty in common/Ask.qml or in README.md" >&2; bad=1
elif [[ $qml_command != "$readme_command" ]]; then
  echo "check-pins: README.md's install command is not the one common/Ask.qml builds" >&2; bad=1
fi

# A release the command's URL cannot reach installs for nobody. This is a
# warning while the version is still unreleased, and an error once the tag
# exists and disagrees with the tree.
if [[ -n $qml_version ]]; then
  if ! git rev-parse -q --verify "refs/tags/v$qml_version" >/dev/null 2>&1; then
    echo "check-pins: note — v$qml_version is not tagged yet; the install command 404s until it is" >&2
  else
    # What users fetch is the tag's .sha256, and what they hash is the tag's
    # install.sh. Those two have to agree with each other whatever the working
    # tree says -- a tag cut before update-pins.sh ran serves a pin for bytes it
    # does not carry, and every install on it reads as tampering.
    tagged_pin=$(git show "v$qml_version:system/install.sh.sha256" 2>/dev/null)
    tagged_installer=$(git show "v$qml_version:system/install.sh" 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [[ -z $tagged_pin ]]; then
      echo "check-pins: tag v$qml_version carries no system/install.sh.sha256" >&2; bad=1
    elif [[ $tagged_pin != "$tagged_installer" ]]; then
      echo "check-pins: tag v$qml_version serves a pin that is not its own system/install.sh" >&2; bad=1
    elif [[ $tagged_pin != "$installer" ]]; then
      echo "check-pins: system/install.sh has changed since v$qml_version was tagged — bump the version" >&2; bad=1
    fi
  fi
fi

if ((bad)); then
  echo "check-pins: run dev/update-pins.sh" >&2
  exit 1
fi
echo "check-pins: ok — ${#names[@]} files, the installer checksum and the published command match"
