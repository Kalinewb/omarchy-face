#!/bin/bash

# What libpam actually does with Face's two lines (plan-engine.md §4.1).
#
#   ./dev/f4b-pam-semantics.sh
#
# Everything else in phase 5 tests Face's own code. This tests the sentence the
# whole design rests on, against the libpam that is installed:
#
#   auth  [success=1 default=ignore]  …omarchy-face-gate
#   auth  sufficient                  …omarchy-face-verify
#
# `success=1` is a JUMP. `pam.conf(5)` describes it as "the next N modules are
# skipped", which is a sentence about the common case and not a specification of
# what the dispatcher does at the edges -- in particular what happens when the
# jump runs off the end of a chain, which is exactly the state a block moved to
# the bottom of the stack would be in. Reading pam_dispatch.c answers it for the
# version that is checked out; running it answers it for the version that is
# installed, and keeps answering after the next update.
#
# The stacks here are built from pam_exec, pam_permit and pam_deny, so nothing
# prompts and nothing needs a password. `pam_permit.so` stands in for the
# `auth include system-auth` line a real sudo stack ends with: for dispatch
# purposes what matters is that a module below the block succeeds, not how.
#
# It runs in the same private namespace the rest of dev/ uses -- /etc is a tmpfs
# whose pam.d is a copy -- so the service files it writes cannot reach the
# machine. /usr/lib/security is deliberately NOT replaced: the modules under test
# are the real ones.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ACCOUNT=${SUDO_USER:-${USER:-$(id -un)}}

failures=0
checks=0

same() { # same <description> <expected> <actual>
  checks=$((checks + 1))
  if [[ $2 == "$3" ]]; then
    echo "  ${GREEN}pass${RESET}  $1"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected '$2', got '$3')${RESET}"
    failures=$((failures + 1))
  fi
}

note() { echo "  ${YELLOW}note${RESET}  $*"; }
step() { echo; echo "${DIM}== $*${RESET}"; }

if [[ ${OMARCHY_FACE_F4B_IN_NS:-0} != 1 ]]; then
  command -v unshare >/dev/null || { echo "unshare is not installed" >&2; exit 1; }
  exec env OMARCHY_FACE_F4B_IN_NS=1 OMARCHY_FACE_F4B_ACCOUNT="$ACCOUNT" \
    unshare --map-root-user --mount --pid --fork "$BASH" "$0"
fi

ACCOUNT=${OMARCHY_FACE_F4B_ACCOUNT:-$ACCOUNT}

mount --bind /etc /mnt || exit 1
mount -t tmpfs tmpfs /etc || exit 1
chmod 0755 /etc
for real in /mnt/*; do ln -s "$real" "/etc/${real#/mnt/}"; done
rm -f /etc/pam.d
cp -r /mnt/pam.d /etc/pam.d 2>/dev/null
chmod 0755 /etc/pam.d

LAB=$(mktemp -d /tmp/omarchy-face-f4b.XXXXXX)
trap 'rm -rf "$LAB"' EXIT
LOG=$LAB/log
SERVICE=omarchy-face-semantics

echo "F4b — what libpam does with Face's two lines"
echo "${DIM}pam $(pacman -Q pam 2>/dev/null | awk '{print $2}')   modules: /usr/lib/security (the real ones)${RESET}"

# Three stand-ins for the helpers, each recording that it ran and exiting with
# whatever the case asked for. What they are is irrelevant; that pam_exec runs
# them, and when, is the whole point.
for name in gate verify after; do
  cat >"$LAB/$name" <<STANDIN
#!/bin/bash
printf '%s\n' "$name" >>"$LOG"
exit \$(cat "$LAB/$name.code" 2>/dev/null || printf 0)
STANDIN
  chmod 0755 "$LAB/$name"
  printf '0\n' >"$LAB/$name.code"
done

code() { printf '%s\n' "$2" >"$LAB/$1.code"; }

# The stack Face writes, with pam_permit standing in for `auth include
# system-auth` and an `after` marker in front of it so the log says whether the
# stack carried on past the block.
stack_normal() {
  cat >"/etc/pam.d/$SERVICE" <<STACK
auth  [success=1 default=ignore]  pam_exec.so quiet $LAB/gate
auth  sufficient                  pam_exec.so quiet $LAB/verify
auth  required                    pam_exec.so quiet $LAB/after
auth  required                    pam_permit.so
STACK
}

# The same block, moved below the last auth line of the stack -- which is what
# `pam_block_intact` refuses to call "already wired", and this is why.
stack_at_the_bottom() {
  cat >"/etc/pam.d/$SERVICE" <<STACK
auth  required                    pam_exec.so quiet $LAB/after
auth  required                    pam_permit.so
auth  [success=1 default=ignore]  pam_exec.so quiet $LAB/gate
auth  sufficient                  pam_exec.so quiet $LAB/verify
STACK
}

# The same, with the password line FAILING above it. The pair answers the real
# question -- what a jump off the end returns -- rather than one half of it.
stack_at_the_bottom_after_a_failure() {
  cat >"/etc/pam.d/$SERVICE" <<STACK
auth  required                    pam_exec.so quiet $LAB/after
auth  required                    pam_deny.so
auth  [success=1 default=ignore]  pam_exec.so quiet $LAB/gate
auth  sufficient                  pam_exec.so quiet $LAB/verify
STACK
}

run() { # run -> "<pam result> <modules that ran>"
  : >"$LOG"
  local answer
  answer=$(python3 "$REPO/dev/pam-probe.py" "$SERVICE" "$ACCOUNT" 2>&1)
  printf '%s | %s' "$answer" "$(tr '\n' ',' <"$LOG" | sed 's/,$//')"
}

step "the stack Face writes"
stack_normal

# 1. The gate skips. `success=1` must jump over the VERIFIER and land on
#    whatever follows -- on a real machine, the password prompt. If this ever
#    changes, sudo stops asking for a password when the gate declines, which is
#    the one failure this arrangement must never have.
code gate 0
code verify 0
result=$(run)
echo "  ${DIM}$result${RESET}"
same "a gate that skips jumps over the verifier and carries on" \
  "0 Success | gate,after" "$result"

# 2. The gate lets it through and the face matches: `sufficient` ends the chain
#    then and there, and nothing below it runs.
code gate 1
code verify 0
result=$(run)
echo "  ${DIM}$result${RESET}"
same "a matched face ends the auth chain, successfully" \
  "0 Success | gate,verify" "$result"

# 3. The face does not match: a failing `sufficient` is ignored and the stack
#    carries on to the password.
code gate 1
code verify 1
result=$(run)
echo "  ${DIM}$result${RESET}"
same "a face that does not match falls through to what follows" \
  "0 Success | gate,verify,after" "$result"

step "a gate or a verifier that cannot run at all"
# pam_exec returns PAM_SYSTEM_ERR when it cannot execute the command. On the gate
# line that is `default=ignore`; on the verifier it is a failing `sufficient`.
# Both must end at the password, which is what `chmod 000` on a helper is
# supposed to cost somebody (plan-engine.md §4.5 test 6).
chmod 000 "$LAB/gate"
result=$(run)
echo "  ${DIM}$result${RESET}"
same "a gate that will not execute is ignored, and the verifier still runs" \
  "0 Success | verify,after" "$result"
chmod 0755 "$LAB/gate"

chmod 000 "$LAB/verify"
code gate 1
result=$(run)
echo "  ${DIM}$result${RESET}"
same "a verifier that will not execute is ignored, and the password follows" \
  "0 Success | gate,after" "$result"
chmod 0755 "$LAB/verify"

step "the hazard: the block moved below the last auth line"
# This is what pam_block_intact's position check exists for. `success=1` from the
# last-but-one line jumps past the end of the chain, and what the dispatcher does
# with that is not something to assume -- so it is recorded here, against the
# installed libpam, and asserted only as "it is not a silent success".
stack_at_the_bottom
code gate 0
code verify 0
after_success=$(run)
echo "  ${DIM}with the password line succeeding above it: $after_success${RESET}"

stack_at_the_bottom_after_a_failure
failure=$(run)
echo "  ${DIM}with it failing above it:                   $failure${RESET}"

# The finding, recorded as an assertion so a libpam that changes it says so: this
# dispatcher carries the status the chain had already reached, rather than
# inventing one for the jump. A jump off the end is therefore NOT a way to turn a
# correct password into a refusal -- and not a way to turn a wrong one into an
# acceptance either, which is the direction that would matter.
same "a jump off the end keeps the status the chain already had (success)" \
  "0 Success | after,gate" "$after_success"
same "…and keeps it when that status was a failure" \
  "7 Authentication failure | after,gate" "$failure"
note "so the block sitting at the bottom is survivable on this libpam --"
note "  sudo-on still refuses to call it 'already wired', because nothing in"
note "  pam.conf(5) promises this and only root could put it there anyway"

step "Face's real lines, as text"
# The two lines in the file above are the ones omarchy-face-admin writes, with
# only the helper paths changed. If the helper ever changes its control flags,
# this suite stops describing it -- so the flags are compared.
admin_gate=$(sed -n "s/^PAM_GATE_LINE='\(.*\)'$/\1/p" "$REPO/system/omarchy-face-admin")
admin_verify=$(sed -n "s/^PAM_VERIFY_LINE='\(.*\)'$/\1/p" "$REPO/system/omarchy-face-admin")
echo "  ${DIM}$admin_gate${RESET}"
echo "  ${DIM}$admin_verify${RESET}"
same "the gate line is the jump this suite exercised" "[success=1 default=ignore]" \
  "$(sed -n 's/^auth[[:space:]]*\(\[[^]]*\]\).*/\1/p' <<<"$admin_gate")"
same "the verifier line is sufficient" "sufficient" \
  "$(awk '{print $2}' <<<"$admin_verify")"
same "both run their helper through pam_exec, with seteuid" "2" \
  "$(printf '%s\n%s\n' "$admin_gate" "$admin_verify" | grep -c 'pam_exec\.so seteuid quiet')"

echo
if ((failures == 0)); then
  echo "${GREEN}F4b passes.${RESET} ${DIM}$checks checks, against pam $(pacman -Q pam 2>/dev/null | awk '{print $2}').${RESET}"
else
  echo "${RED}$failures of $checks checks failed.${RESET}"
  echo "${DIM}A change here is a change in what sudo does when a face is declined.${RESET}"
fi
exit $((failures > 0))
