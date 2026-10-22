#!/usr/bin/env python3
#
# Print the one install command, decoded from common/Ask.qml.
#
# Setup runs the install script through pkexec, and README.md prints the same
# script as a terminal command -- for anyone who would rather read it before it
# runs, and for a machine whose panel will not open. The README copy has to be
# the panel's text exactly, or it is worth nothing to compare against. Keeping
# one canonical copy and generating the other is the only way that stays true;
# dev/update-pins.sh writes it into the README and dev/check-pins.sh fails when
# the two have drifted.
#
# The script is `installBody`, between the pins:command markers. The terminal
# form around it is `installCommand`, evaluated here from its own expression
# rather than retyped, so the wrapper cannot drift either.

import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
ask = (root / "common" / "Ask.qml").read_text()

version = re.search(r'readonly property string systemVersion: "([^"]+)"', ask)
if not version:
    sys.exit("install-command: no systemVersion in common/Ask.qml")

LITERAL = r'"((?:[^"\\]|\\.)*)"'


def decode(literal):
    # json.loads, not ordered str.replace: a chain of replaces decodes a literal
    # backslash followed by "n" as a newline, which would put a different command
    # in README.md from the one the panel runs. JSON's escapes are QML's here,
    # and it raises rather than guesses on anything it does not know.
    try:
        return json.loads('"%s"' % literal)
    except ValueError as exc:
        sys.exit("install-command: cannot decode a string literal: %s" % exc)


block = re.search(r"// pins:command:begin.*?\n(.*?)\n\s*// pins:command:end", ask, re.S)
if not block:
    sys.exit("install-command: no pins:command block in common/Ask.qml")
body_source = re.search(r"readonly property string installBody:\s*\n(.*)", block.group(1), re.S)
if not body_source:
    sys.exit("install-command: the pins:command block has no installBody")
parts = re.findall(LITERAL, body_source.group(1))
if not parts:
    sys.exit("install-command: installBody has no string literals")
body = "".join(decode(p) for p in parts)

command_source = re.search(r"readonly property string installCommand:\s*\n(.*?)\n\s*\n", ask, re.S)
if not command_source:
    sys.exit("install-command: no installCommand in common/Ask.qml")

values = {"installBody": body, "systemVersion": version.group(1)}
text = ""
for literal, name in re.findall(LITERAL + r"|root\.([A-Za-z]+)", command_source.group(1)):
    if name:
        if name not in values:
            sys.exit("install-command: installCommand uses root.%s, which this script cannot evaluate" % name)
        text += values[name]
    else:
        text += decode(literal)
if body not in text or not text.endswith(version.group(1)):
    sys.exit("install-command: installCommand does not wrap installBody and end in the version")

sys.stdout.write(text + "\n")
