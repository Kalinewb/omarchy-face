#!/bin/bash

# Which format lists `omarchy-face-camera` reads as an infrared sensor.
#
#   ./dev/c1-camera-formats.sh
#
# Pass 2 of find_ir_node goes by formats alone, and no machine here has a 10- or
# 16-bit sensor to prove the wider rule on. So `formats_look_ir` is lifted out
# of the shipped file as it stands and run against the exact `v4l2-ctl
# --list-formats` text of each case, with v4l2-ctl a shell function. Nothing is
# opened, and the real camera is asked once at the end, read-only.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CAMERA=$REPO/system/omarchy-face-camera

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

# The two tables and the function, verbatim from the shipped file.
eval "$(sed -n '/^LUMA_FORMATS=/p; /^READABLE_LUMA_FORMATS=/p; /^formats_look_ir() {/,/^}/p' "$CAMERA")"
declare -F formats_look_ir >/dev/null || { echo "c1: formats_look_ir not found in $CAMERA" >&2; exit 1; }

LISTING=""
v4l2-ctl() { printf '%s' "$LISTING"; }
command() { [[ $1 == -v && $2 == v4l2-ctl ]] && return 0; builtin command "$@"; }

listing() { # listing <fourcc>... -> v4l2-ctl --list-formats text
  local i=0 fourcc
  printf "ioctl: VIDIOC_ENUM_FMT\n\tType: Video Capture\n\n"
  for fourcc in "$@"; do
    printf "\t[%d]: '%s' (some description)\n" "$i" "$fourcc"
    i=$((i + 1))
  done
}

verdict() { LISTING=$(listing "$@"); formats_look_ir /dev/null && echo ir || echo not; }

echo "C1 — which format lists are an infrared camera"

check "8-bit GREY alone, as on this machine" ir "$(verdict GREY)"
check "10-bit Y10 alone" ir "$(verdict 'Y10 ')"
check "16-bit Y16 alone" ir "$(verdict 'Y16 ')"
check "big-endian Y16 alone" ir "$(verdict 'Y16 -BE')"
check "GREY and Y16 together" ir "$(verdict GREY 'Y16 ')"
check "a readable luminance format beside an unreadable one" ir "$(verdict Y8I GREY)"
check "Y12 alone: OpenCV tries it and cannot convert it" not "$(verdict 'Y12 ')"
check "Y10B, Y14, Y8I, Y12I: not in OpenCV's V4L2 backend" not "$(verdict Y10B 'Y14 ' 'Y8I ' Y12I)"
check "the colour webcam" not "$(verdict MJPG YUYV)"
check "GREY beside a colour format is not format-only IR" not "$(verdict GREY NV12)"
check "the old rule's hole: GREY beside a colour format that is not YUYV or MJPG" not "$(verdict GREY 'RGB3')"
check "a metadata node, which lists no formats" not "$(verdict)"
check "'Y8  ', which OpenCV does not know by that name" not "$(verdict 'Y8  ')"

if command -v v4l2-ctl >/dev/null && ls /dev/video* >/dev/null 2>&1; then
  unset -f v4l2-ctl command
  echo "  ${DIM}this machine: $("$CAMERA" --describe 2>/dev/null)${RESET}"
fi

echo
if ((failures == 0)); then
  echo "${GREEN}C1 passes.${RESET} ${DIM}$checks checks.${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
fi
exit $((failures > 0))
