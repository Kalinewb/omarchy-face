#!/usr/bin/env python3
#
# Print the one install command, decoded from common/Ask.qml.
#
# The panel is now the channel people copy the command from, so the command in
# README.md has to be the same text -- it is what a suspicious reader compares
# against. Keeping one canonical copy and generating the other is the only way
# that stays true; dev/update-pins.sh writes it into the README and
# dev/check-pins.sh fails when the two have drifted.

import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
ask = (root / "common" / "Ask.qml").read_text()

version = re.search(r'readonly property string systemVersion: "([^"]+)"', ask)
if not version:
    sys.exit("install-command: no systemVersion in common/Ask.qml")

block = re.search(r"// pins:command:begin.*?\n(.*?)\n\s*// pins:command:end", ask, re.S)
if not block:
    sys.exit("install-command: no pins:command block in common/Ask.qml")

parts = re.findall(r'"((?:[^"\\]|\\.)*)"', block.group(1))
if not parts:
    sys.exit("install-command: the pins:command block has no string literals")

# json.loads, not ordered str.replace: a chain of replaces decodes a literal
# backslash followed by "n" as a newline, which would put a different command in
# README.md from the one the panel copies -- and the README is what a reader is
# told to compare the clipboard against. JSON's escapes are QML's here, and it
# raises rather than guesses on anything it does not know.
try:
    text = "".join(json.loads('"%s"' % p) for p in parts)
except ValueError as exc:
    sys.exit("install-command: cannot decode the command's string literals: %s" % exc)
if "root.systemVersion" not in block.group(1):
    sys.exit("install-command: the command does not end in root.systemVersion")

sys.stdout.write(text + version.group(1) + "\n")
