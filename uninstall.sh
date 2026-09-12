#!/bin/bash

# Thin wrapper. The real uninstaller is installed to /usr/local/bin, because
# removing a plugin deletes its directory -- so an uninstaller that only lives
# in the repository is exactly the thing that disappears when it is needed.

set -euo pipefail

if command -v omarchy-face-uninstall >/dev/null 2>&1; then
  exec omarchy-face-uninstall "$@"
fi

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -x $SELF_DIR/bin/omarchy-face-uninstall ]]; then
  exec "$SELF_DIR/bin/omarchy-face-uninstall" "$@"
fi

echo "uninstall.sh: cannot find omarchy-face-uninstall" >&2
exit 1
