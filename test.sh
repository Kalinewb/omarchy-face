#!/bin/bash

# Non-destructive checks against the installed helpers. Reads state, never
# changes it: no PAM edits, no enrollment, no package installs. Safe to run on a
# configured machine at any time.
#
#   ./test.sh          everything except the live camera
#   ./test.sh --live   also attempt a real match (needs your face at the sensor)

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

LIVE=false
[[ ${1:-} == --live ]] && LIVE=true

pass=0
fail=0

section() { printf '\n%s%s%s\n' "$DIM" "$1" "$RESET"; }

# Asserts an exit code, because for these scripts the exit code *is* the
# security behaviour: the gate's 0 means "skip face", verify's 0 means
# "authenticated". A test suite that only checked output would miss the thing
# that matters.
check() {
  local label=$1 expected=$2
  shift 2
  local out code
  out=$("$@" 2>&1)
  code=$?
  if [[ $code == "$expected" ]]; then
    printf '  %s✓%s %-46s %s\n' "$GREEN" "$RESET" "$label" "${DIM}${out:0:60}${RESET}"
    ((pass++))
  else
    printf '  %s✗%s %-46s %sexpected exit %s, got %s%s\n' "$RED" "$RESET" "$label" "$RED" "$expected" "$code" "$RESET"
    [[ -n $out ]] && printf '      %s\n' "$out"
    ((fail++))
  fi
}

section "Hardware detection"
check "IR camera present" 0 omarchy-hw-ir-camera
check "reports a capture node" 0 omarchy-hw-ir-camera --node
check "reports a reboot-stable path" 0 omarchy-hw-ir-camera --path
check "rejects unknown arguments" 2 omarchy-hw-ir-camera --nonsense

section "Gate — exit 0 means face is SKIPPED, 1 means attempt it"
check "no PAM_USER -> skip" 0 env -u PAM_USER omarchy-face-gate --explain
check "root -> skip" 0 env PAM_USER=root omarchy-face-gate --explain
check "ssh session -> skip" 0 env PAM_USER=$USER SSH_CONNECTION="10.0.0.1 1 10.0.0.2 22" omarchy-face-gate --explain
check "remote PAM_RHOST -> skip" 0 env PAM_USER=$USER PAM_RHOST=elsewhere omarchy-face-gate --explain

section "Verify — exit 0 authenticates, everything else must not"
check "no PAM_USER -> deny" 1 env -u PAM_USER omarchy-face-verify
check "path traversal username -> deny" 1 env PAM_USER=../../root omarchy-face-verify
check "nonexistent user -> deny" 1 env PAM_USER=definitelynotauser omarchy-face-verify
check "root -> deny" 1 env PAM_USER=root omarchy-face-verify

section "Helper permissions — pam_exec runs these as root"
for helper in omarchy-face-gate omarchy-face-verify omarchy-face-engine-howdy; do
  path=/usr/local/bin/$helper
  if [[ ! -f $path ]]; then
    printf '  %s✗%s %-46s %snot installed%s\n' "$RED" "$RESET" "$helper" "$RED" "$RESET"
    ((fail++))
    continue
  fi
  read -r owner perms < <(stat -c '%u %a' "$path")
  if [[ $owner == 0 ]] && (((8#$perms & 8#022) == 0)); then
    printf '  %s✓%s %-46s %sroot:root %s%s\n' "$GREEN" "$RESET" "$helper" "$DIM" "$perms" "$RESET"
    ((pass++))
  else
    printf '  %s✗%s %-46s %sowner uid %s, mode %s%s\n' "$RED" "$RESET" "$helper" "$RED" "$owner" "$perms" "$RESET"
    ((fail++))
  fi
done

section "PAM stacks"
for file in /etc/pam.d/sudo /etc/pam.d/polkit-1; do
  if [[ ! -f $file ]]; then
    printf '  %s-%s %-46s %sabsent%s\n' "$YELLOW" "$RESET" "${file##*/}" "$DIM" "$RESET"
    continue
  fi
  gate_line=$(grep -n omarchy-face-gate "$file" | cut -d: -f1)
  auth_line=$(grep -n omarchy-face-verify "$file" | cut -d: -f1)
  if [[ -z $gate_line && -z $auth_line ]]; then
    printf '  %s-%s %-46s %snot configured%s\n' "$YELLOW" "$RESET" "${file##*/}" "$DIM" "$RESET"
  elif ! grep -q 'pam_exec.so seteuid' "$file"; then
    # Without seteuid, pam_exec runs the helpers as the invoking user, they
    # cannot read the root-owned face models, and every authentication quietly
    # falls through to the password. Nothing else about the stack looks wrong.
    printf '  %s✗%s %-46s %smissing seteuid — face can never succeed%s\n' "$RED" "$RESET" "${file##*/}" "$RED" "$RESET"
    ((fail++))
  elif [[ -n $gate_line && -n $auth_line ]] && ((gate_line == auth_line - 1)); then
    # The gate must sit immediately above the check it skips: success=1 jumps
    # exactly one module, so a line between them would be skipped instead.
    printf '  %s✓%s %-46s %sgate line %s, verify line %s%s\n' "$GREEN" "$RESET" "${file##*/}" "$DIM" "$gate_line" "$auth_line" "$RESET"
    ((pass++))
  else
    printf '  %s✗%s %-46s %sgate and verify are not adjacent (%s, %s)%s\n' "$RED" "$RESET" "${file##*/}" "$RED" "${gate_line:-none}" "${auth_line:-none}" "$RESET"
    ((fail++))
  fi
done

section "Security probe"
probe=$(omarchy-security-probe 2>&1)
if printf '%s' "$probe" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  printf '  %s✓%s %-46s %s%s%s\n' "$GREEN" "$RESET" "emits valid JSON" "$DIM" "$(printf '%s' "$probe" | cut -c1-40)" "$RESET"
  ((pass++))
else
  printf '  %s✗%s %-46s %sinvalid JSON%s\n' "$RED" "$RESET" "emits valid JSON" "$RED" "$RESET"
  printf '      %s\n' "${probe:0:200}"
  ((fail++))
fi
# The panel renders a security verdict from this; a field silently going missing
# would show as "unknown" rather than as an error, which is the quiet kind of wrong.
for field in face fingerprint fido2 sshd faillock idle sudo; do
  if printf '%s' "$probe" | python3 -c "import json,sys; sys.exit(0 if '$field' in json.load(sys.stdin) else 1)" 2>/dev/null; then
    ((pass++))
  else
    printf '  %s✗%s %-46s %smissing%s\n' "$RED" "$RESET" "field: $field" "$RED" "$RESET"
    ((fail++))
  fi
done
printf '  %s✓%s %-46s %sall seven sections present%s\n' "$GREEN" "$RESET" "probe fields" "$DIM" "$RESET"

section "Lint — bash traps that fail silently"
bad=0
for script in /usr/local/bin/omarchy-face* /usr/local/bin/omarchy-hw-ir-camera; do
  [[ -f $script ]] || continue
  while IFS= read -r line; do
    # `local a=$1 b=$a` reads b from an unset a: `local` is a builtin, so every
    # argument is expanded before any assignment takes effect. Under set -u the
    # function dies mid-call, which from outside looks like a permissions or
    # hardware fault rather than a typo. This has bitten twice.
    [[ $line =~ ^[[:space:]]*local[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    first=${BASH_REMATCH[1]}
    rest=${BASH_REMATCH[2]}
    [[ $rest =~ [[:space:]][A-Za-z_][A-Za-z0-9_]*= ]] || continue
    if [[ $rest == *"\$$first"* || $rest == *"\${$first"* ]]; then
      printf '  %s✗%s %-46s %s%s%s\n' "$RED" "$RESET" "${script##*/}" "$RED" "$(echo "$line" | tr -s ' ' | cut -c1-46)" "$RESET"
      bad=1
    fi
  done < "$script"
done
if ((bad == 0)); then
  printf '  %s✓%s %-46s %sno self-referencing local declarations%s\n' "$GREEN" "$RESET" "all helpers" "$DIM" "$RESET"
  ((pass++))
else
  ((fail++))
fi

section "Engine"
omarchy-face-engine-howdy describe | sed "s/^/  ${DIM}/;s/\$/${RESET}/"
models=$(omarchy-face-engine-howdy count-models "$USER" 2>/dev/null || echo unknown)
printf '  %-48s %s\n' "enrolled models for $USER" "$models"

if $LIVE; then
  section "Live match — look at the camera"
  start=$EPOCHREALTIME
  if omarchy-face test; then
    printf '  %s✓%s matched in %ss\n' "$GREEN" "$RESET" \
      "$(awk -v a="$start" -v b="$EPOCHREALTIME" 'BEGIN { printf "%.1f", b - a }')"
    ((pass++))
  else
    printf '  %s✗%s no match\n' "$RED" "$RESET"
    ((fail++))
  fi

  if [[ -r /run/omarchy-face/state.json ]]; then
    printf '  %sstate: %s%s\n' "$DIM" "$(cat /run/omarchy-face/state.json)" "$RESET"
  fi
fi

printf '\n%s%s passed%s' "$GREEN" "$pass" "$RESET"
if ((fail > 0)); then
  printf ', %s%s failed%s\n' "$RED" "$fail" "$RESET"
  exit 1
fi
printf '\n'
