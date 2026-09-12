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
# There is deliberately no "SSH_CONNECTION makes it skip" case here. A test
# like that passed for weeks against a gate that read the variable, while real
# PAM never set it -- so the suite was confirming a guard that could not fire.
# The replacement guard reads logind, and the lint section below is what keeps
# the env version from coming back.
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

section "State that must survive a reboot"
# /run is tmpfs. A summary kept there vanishes overnight and every UI reading it
# reports "nothing enrolled" while the models sit on disk -- which reads as face
# unlock having broken itself.
if grep -rq "/run/omarchy-face/models.json" /usr/local/bin/omarchy-face* 2>/dev/null; then
  printf '  %s✗%s %-46s %smodel summary kept on tmpfs%s\n' "$RED" "$RESET" "summary is persistent" "$RED" "$RESET"
  ((fail++))
else
  printf '  %s✓%s %-46s %snot under /run%s\n' "$GREEN" "$RESET" "summary is persistent" "$DIM" "$RESET"
  ((pass++))
fi

section "Authorisation surface"
# Only one action now. Verification moved into the daemon, which removed a
# root process started with an argv the caller chose.
for action in no.graveklar.face.admin; do
    if pkaction --action-id "$action" >/dev/null 2>&1; then
    printf '  %s✓%s %-46s %sregistered%s\n' "$GREEN" "$RESET" "$action" "$DIM" "$RESET"
    ((pass++))
  else
    printf '  %s✗%s %-46s %smissing%s\n' "$RED" "$RESET" "$action" "$RED" "$RESET"
    ((fail++))
  fi
done
if pkaction --action-id no.graveklar.face.verify >/dev/null 2>&1; then
  printf '  %s✗%s %-46s %sstill registered%s\n' "$RED" "$RESET" "no-prompt polkit action is gone" "$RED" "$RESET"
  ((fail++))
else
  printf '  %s✓%s %-46s %sretired%s\n' "$GREEN" "$RESET" "no-prompt polkit action is gone" "$DIM" "$RESET"
  ((pass++))
fi

# The no-prompt verifier must never grow the ability to change anything.
# Captured first, then matched: this file runs under `set -o pipefail`, so
# `cmd | grep -q` reports cmd's exit status even when grep matched happily.
identity_out=$(omarchy-face-identity enroll evil 2>&1 || true)
if grep -qi usage <<<"$identity_out"; then
  printf '  %s✓%s %-46s %sverify/list only%s\n' "$GREEN" "$RESET" "identity helper cannot enrol" "$DIM" "$RESET"
  ((pass++))
else
  printf '  %s✗%s %-46s %saccepted an unexpected verb%s\n' "$RED" "$RESET" "identity helper cannot enrol" "$RED" "$RESET"
  ((fail++))
fi

section "Guards that must not be decorative"
# An earlier version checked SSH_CONNECTION here. pam_exec never passes the
# caller's environ, so it could not fire, and the README documented a
# protection that did not exist. Nothing should reintroduce it.
if grep -qE 'SSH_CONNECTION|SSH_TTY|SSH_CLIENT' /usr/local/bin/omarchy-face-gate 2>/dev/null; then
  printf '  %s✗%s %-46s %sreads env pam_exec never passes%s\n' "$RED" "$RESET" "gate does not rely on caller env" "$RED" "$RESET"
  ((fail++))
else
  printf '  %s✓%s %-46s %suses logind, not env%s\n' "$GREEN" "$RESET" "gate does not rely on caller env" "$DIM" "$RESET"
  ((pass++))
fi

# A kept authorisation is a window in which any process running as this user
# can enrol its own face.
if grep -q 'auth_self_keep' /usr/share/polkit-1/actions/no.graveklar.face.policy 2>/dev/null; then
  printf '  %s✗%s %-46s %skept authorisation window%s\n' "$RED" "$RESET" "enrolment prompts every time" "$RED" "$RESET"
  ((fail++))
else
  printf '  %s✓%s %-46s %sauth_self, no keep%s\n' "$GREEN" "$RESET" "enrolment prompts every time" "$DIM" "$RESET"
  ((pass++))
fi

# The identity verifier must hold no privilege of its own.
if grep -qE 'pkexec|^\s*sudo ' /usr/local/bin/omarchy-face-identity 2>/dev/null; then
  printf '  %s✗%s %-46s %sstill escalates%s\n' "$RED" "$RESET" "identity helper is unprivileged" "$RED" "$RESET"
  ((fail++))
else
  printf '  %s✓%s %-46s %ssocket client only%s\n' "$GREEN" "$RESET" "identity helper is unprivileged" "$DIM" "$RESET"
  ((pass++))
fi

# The daemon should not hold capabilities it does not use.
if systemctl show omarchy-faced.service -p NoNewPrivileges 2>/dev/null | grep -q 'yes'; then
  printf '  %s✓%s %-46s %sNoNewPrivileges, bounded caps%s\n' "$GREEN" "$RESET" "daemon is least-privilege" "$DIM" "$RESET"
  ((pass++))
else
  printf '  %s✗%s %-46s %sruns with full root%s\n' "$RED" "$RESET" "daemon is least-privilege" "$RED" "$RESET"
  ((fail++))
fi

section "Daemon refusals"
daemon_says() {
  OMARCHY_TEST_REQ="$1" python3 -c '
import os, socket, sys
try:
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(20)
    c.connect("/run/omarchy-face/verify.sock")
    c.sendall((os.environ["OMARCHY_TEST_REQ"] + "\n").encode())
    sys.stdout.write(c.recv(128).decode().strip().split("\n")[0])
except Exception:
    sys.stdout.write("UNREACHABLE")
' 2>/dev/null
}
if [[ -S /run/omarchy-face/verify.sock ]]; then
  for probe in "VERIFY root 2:not-your-account" "VERIFY-IDENTITY ../evil 2:bad-identity" "NONSENSE:bad-request"; do
    request=${probe%%:*}
    expect=${probe##*:}
    got=$(daemon_says "$request")
    if [[ $got == *"$expect"* ]]; then
      printf '  %s✓%s %-46s %s%s%s\n' "$GREEN" "$RESET" "${request:0:40}" "$DIM" "$got" "$RESET"
      ((pass++))
    else
      printf '  %s✗%s %-46s %sgot: %s%s\n' "$RED" "$RESET" "${request:0:40}" "$RED" "$got" "$RESET"
      ((fail++))
    fi
  done
else
  printf '  %s-%s %-46s %ssocket absent%s\n' "$YELLOW" "$RESET" "daemon refusals" "$DIM" "$RESET"
fi

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
# The published summary, same as every other reader: asking the engine directly
# needs root, and this suite must not raise a password prompt.
if [[ -r /var/lib/omarchy-face/models.json ]]; then
  models=$(python3 -c 'import json; print(len(json.load(open("/var/lib/omarchy-face/models.json"))["models"]))' 2>/dev/null || echo unknown)
else
  models="none recorded"
fi
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
