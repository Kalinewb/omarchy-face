#!/bin/bash
#
# Rewrite the SHA-256 pins in system/install.sh from the files they describe.
# Run after changing anything installed as root: the helpers, the units or the
# polkit policy. Commit the pins in the same commit as the files.
#
# The pins are what make installing from a user-writable plugin folder safe:
# root installs only a snapshot whose bytes hash to these values, and the pins
# are part of the script text the administrator authorises.
#
# The list of files is the admin helper's own SYSTEM_FILES table, so the two
# cannot disagree about what is installed.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mapfile -t names < <(sed -n '/^SYSTEM_FILES=(/,/^)/p' system/omarchy-face-admin |
  sed -n 's/^[[:space:]]*"\([^:"]*\):.*/\1/p')
((${#names[@]} > 0)) || { echo "update-pins: no SYSTEM_FILES table found" >&2; exit 1; }

block="declare -A PINS=("$'\n'
for name in "${names[@]}"; do
  [[ -f system/$name ]] || { echo "update-pins: system/$name is missing" >&2; exit 1; }
  block+="  [$name]=$(sha256sum -- "system/$name" | cut -d' ' -f1)"$'\n'
done
block+=")"

python3 - "$block" <<'PY'
import sys, re
block = sys.argv[1]
p = "system/install.sh"
s = open(p).read()
new, n = re.subn(r"(# pins:begin\n).*?(\n# pins:end)", lambda m: m.group(1) + block + m.group(2), s, flags=re.S)
if n != 1:
    sys.exit("update-pins: pins markers not found in system/install.sh")
open(p, "w").write(new)
PY

# And the installer's own checksum, published in the README's install command.
# After the pins, because the pins are part of the installer.
installer=$(sha256sum -- system/install.sh | cut -d' ' -f1)
python3 - "$installer" <<'PY'
import sys, re
sha = sys.argv[1]
p = "README.md"
s = open(p).read()
new, n = re.subn(r'echo "(?:[0-9a-f]{64}|INSTALL_SHA256)  \$t/install\.sh"', 'echo "%s  $t/install.sh"' % sha, s)
if n != 1:
    sys.exit("update-pins: the install command's checksum was not found exactly once in README.md")
open(p, "w").write(new)
PY

echo "pins updated for ${#names[@]} files; installer checksum $installer written to README.md"
