#!/bin/bash

# F2's gate: the engine build job (plan-merged.md §4 phase 3, plan-engine.md §5).
#
#   a fresh machine gets howdy with no CUDA;
#   closing the popup or restarting the shell mid-build loses nothing.
#
# Four runs, because the gate has four halves and they need different things:
#
#   ./dev/f2-engine-job.sh              everything that needs no password
#   ./dev/f2-engine-job.sh --builder    the REAL compile, as this account
#   ./dev/f2-engine-job.sh --detach     the job outlives whatever started it
#   sudo ./dev/f2-engine-job.sh --build-user
#                                       plan-engine.md §5.3: does makepkg run
#                                       under systemd's DynamicUser at all?
#
# The default run does three things:
#
#   * the patches, against the PKGBUILDs the AUR actually ships -- the shipped
#     build script is extracted out of system/omarchy-face-admin and run with
#     makepkg stubbed, so what is tested is the text that will run as the build
#     user, not a copy of it in this file;
#   * the whole of `build-engine` in a private user namespace, with pacman,
#     systemd-run and the camera stubbed, which is what lets the package
#     verification be tested with packages that are deliberately wrong (a dlib
#     that wants CUDA, a howdy carrying the polkit drop-in);
#   * the reading half: what omarchy-face-status makes of install.json in each
#     of its states, including a build whose unit is gone.
#
# What no sandbox can answer is whether makepkg runs under DynamicUser on this
# machine, which is why --build-user is its own run and needs root.

set -uo pipefail

GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'
RESET=$'\e[0m'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ADMIN_SRC=$REPO/system/omarchy-face-admin
STATUS_SRC=$REPO/bin/omarchy-face-status

failures=0
checks=0

check() { # check <description> <command…>
  local description=$1
  shift
  checks=$((checks + 1))
  if "$@" >/dev/null 2>&1; then
    echo "  ${GREEN}pass${RESET}  $description"
  else
    echo "  ${RED}FAIL${RESET}  $description"
    failures=$((failures + 1))
  fi
}

note() { echo "  ${YELLOW}note${RESET}  $*"; }
step() { echo; echo "${DIM}== $*${RESET}"; }

summary() {
  echo
  if ((failures == 0)); then
    echo "${GREEN}$checks checks, all passed${RESET}"
  else
    echo "${RED}$checks checks, $failures failed${RESET}"
  fi
  exit $((failures > 0))
}

# The build user's script, taken out of the helper that ships it. Every test
# below that touches a PKGBUILD runs THIS, so a patch that is edited in the
# helper and not here cannot pass.
extract_build_script() { # extract_build_script <file>
  sed -n "/^read -r -d '' BUILD_SCRIPT <<'BUILD_SCRIPT_END'/,/^BUILD_SCRIPT_END$/p" "$ADMIN_SRC" |
    sed '1d;$d' >"$1"
  [[ -s $1 ]] || { echo "f2: could not find BUILD_SCRIPT in $ADMIN_SRC" >&2; return 1; }
}

# --- the PKGBUILDs ------------------------------------------------------------
#
# From the yay cache when it is there (the evidence note of plan-engine.md E8
# left a v2.6.1 checkout on this machine), and from the AUR when it is not.
# Either way these are the real files, not fixtures written to pass.
fetch_pkgbuilds() { # fetch_pkgbuilds <dir>
  local dir=$1 name cache
  for name in python-dlib howdy; do
    mkdir -p "$dir/$name" || return 1
    cache=$HOME/.cache/yay/$name/PKGBUILD
    if [[ -r $cache ]]; then
      cp "$cache" "$dir/$name/PKGBUILD" || return 1
    elif command -v git >/dev/null; then
      git clone --quiet --depth 1 "https://aur.archlinux.org/$name.git" "$dir/$name.git" &&
        cp "$dir/$name.git/PKGBUILD" "$dir/$name/PKGBUILD" || return 1
    else
      return 1
    fi
  done
}

# ==============================================================================
# --build-user: plan-engine.md §5.3's uncertainty, and nothing else
# ==============================================================================

if [[ ${1:-} == --build-user ]]; then
  [[ $EUID -eq 0 ]] || { echo "f2: --build-user needs root (sudo $0 --build-user)" >&2; exit 1; }
  echo "F2 — makepkg under systemd's DynamicUser (plan-engine.md §5.3)"

  # A package that builds in a second and still exercises the two things in
  # doubt: makepkg refusing to run as root, and fakeroot needing SysV IPC for
  # package(). If this works, the real build differs only in how long it takes.
  probe=$(cat <<'PKGBUILD'
pkgname=omarchy-face-build-probe
pkgver=1
pkgrel=1
arch=('any')
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/omarchy-face-build-probe/ok"
}
PKGBUILD
)
  out=$(systemd-run --wait --pipe --quiet --collect \
    --property=DynamicUser=yes \
    --property=StateDirectory=omarchy-face-build \
    --property=WorkingDirectory=/var/lib/omarchy-face-build \
    --setenv=HOME=/var/lib/omarchy-face-build \
    --setenv=LANG=C \
    /bin/bash -c '
      set -uo pipefail
      cd /var/lib/omarchy-face-build || exit 1
      rm -rf probe; mkdir probe; cd probe
      printf "%s\n" "$1" >PKGBUILD
      id -un
      makepkg -f --noconfirm --nodeps
    ' omarchy-face-probe "$probe" 2>&1)
  rc=$?
  echo "${DIM}${out}${RESET}"
  checks=$((checks + 1))
  if ((rc == 0)); then
    echo "  ${GREEN}pass${RESET}  makepkg ran under DynamicUser and built a package"
  else
    echo "  ${RED}FAIL${RESET}  makepkg under DynamicUser exited $rc"
    failures=$((failures + 1))
    note "plan-engine.md §5.3's fallback applies: build under runuser as the"
    note "invoking user, with root checking .PKGINFO before pacman -U."
  fi
  rm -rf /var/lib/private/omarchy-face-build
  [[ -L /var/lib/omarchy-face-build ]] && rm -f /var/lib/omarchy-face-build
  summary
fi

# ==============================================================================
# --builder: the real compile, as this account
# ==============================================================================

if [[ ${1:-} == --builder ]]; then
  echo "F2 — the shipped build script, for real (this takes a while)"
  [[ $EUID -ne 0 ]] || { echo "f2: --builder must NOT be root; makepkg refuses" >&2; exit 1; }

  work=${OMARCHY_FACE_F2_WORK:-$(mktemp -d /tmp/omarchy-face-f2.XXXXXX)}
  mkdir -p "$work" || exit 1
  echo "${DIM}building in $work${RESET}"

  script=$work/build-script
  extract_build_script "$script"
  check "the build script came out of the helper" test -s "$script"

  step "fetch"
  if [[ -d $work/python-dlib && -d $work/howdy ]]; then
    note "reusing the clones already in $work"
  else
    bash -c "$(cat "$script")" omarchy-face-build "$work" fetch
    check "fetch left a python-dlib PKGBUILD" test -f "$work/python-dlib/PKGBUILD"
    check "fetch left a howdy PKGBUILD" test -f "$work/howdy/PKGBUILD"
  fi

  step "build (dlib is a long compile)"
  time bash -c "$(cat "$script")" omarchy-face-build "$work" build
  build_rc=$?
  check "the build script finished" test "$build_rc" -eq 0
  [[ -s $work/result ]] && note "result: $(cat "$work/result")"

  step "what came out"
  dlib_pkg=$(compgen -G "$work/python-dlib/python-dlib-[0-9]*.pkg.tar.*" | head -1)
  howdy_pkg=$(compgen -G "$work/howdy/howdy-[0-9]*.pkg.tar.*" | head -1)
  check "one python-dlib package" test -f "$dlib_pkg"
  check "one howdy package" test -f "$howdy_pkg"
  check "no python-dlib-cuda package was built" \
    bash -c "! compgen -G '$work/python-dlib/python-dlib-cuda-*.pkg.tar.*' >/dev/null"
  check "the PKGBUILD says _build_cuda=0" grep -qx '_build_cuda=0' "$work/python-dlib/PKGBUILD"
  if [[ -f $dlib_pkg ]]; then
    info=$(bsdtar -xOqf "$dlib_pkg" .PKGINFO)
    echo "${DIM}$(grep -E '^(pkgname|pkgver|depend) ' <<<"$info" | head -12)${RESET}"
    check "it is python-dlib" bash -c "grep -qx 'pkgname = python-dlib' <<<'$info'"
    check "nothing in it depends on cuda or cudnn" \
      bash -c "! grep -qiE '^depend = (cuda|cudnn)' <<<'$info'"
    check "no CUDA shared library was linked in" \
      bash -c "! bsdtar -tf '$dlib_pkg' | grep -qi 'libcud'"
  fi
  if [[ -f $howdy_pkg ]]; then
    check "the howdy package carries no polkit drop-in" \
      bash -c "! bsdtar -tf '$howdy_pkg' | grep -q '10-howdy.conf'"
    check "and it still carries compare.py" \
      bash -c "bsdtar -tf '$howdy_pkg' | grep -q 'usr/lib/security/howdy/compare.py'"
  fi
  note "packages left in $work; pacman -U them by hand, or let the GUI build its own"
  summary
fi

# ==============================================================================
# --detach: the job outlives whatever started it (the gate's second half)
# ==============================================================================

if [[ ${1:-} == --detach ]]; then
  echo "F2 — a build nothing can lose (plan-merged.md §4 phase 3)"
  command -v systemd-run >/dev/null || { echo "f2: systemd-run is missing" >&2; exit 1; }

  unit=omarchy-face-f2-detach
  state=$(mktemp -d /tmp/omarchy-face-f2-state.XXXXXX)
  trap 'systemctl --user stop "$unit.service" >/dev/null 2>&1; rm -rf "$state"' EXIT
  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1

  # The real job is a transient unit of the SYSTEM manager started by a pkexec'd
  # verb; this is the same shape in the user manager, started by a subshell that
  # then exits. What is being tested is the property, not the manager: a
  # transient unit is not a child of whatever asked for it.
  step "start it from a process that then dies"
  starter_pid=$(
    bash -c "systemd-run --user --unit=$unit --collect --quiet --property=Type=exec \
               '$REPO/dev/bin/omarchy-face-build-standin' '$state' 2 >/dev/null 2>&1; echo \$\$"
  )
  sleep 1
  check "the starter is gone" bash -c "! kill -0 $starter_pid 2>/dev/null"
  check "the unit is running" systemctl --user is-active --quiet "$unit.service"
  main_pid=$(systemctl --user show -p MainPID --value "$unit.service")
  ppid=$(awk '{print $4}' "/proc/$main_pid/stat" 2>/dev/null)
  echo "  ${DIM}main pid $main_pid, parent $ppid${RESET}"
  check "its parent is the manager, not the caller" test "$ppid" != "$starter_pid"

  step "a second start while it runs is refused"
  check "systemd says the unit is active" systemctl --user is-active --quiet "$unit.service"
  out=$(systemd-run --user --unit=$unit --collect --quiet --property=Type=exec /bin/true 2>&1)
  check "and systemd-run refuses the name" test -n "$out"

  step "reattaching sees the same build, further on"
  first=$(cat "$state/install.json")
  started_a=$(jq -r .startedAt <<<"$first")
  updated_a=$(jq -r .updatedAt <<<"$first")
  step_a=$(jq -r .step <<<"$first")
  sleep 4
  second=$(cat "$state/install.json")
  started_b=$(jq -r .startedAt <<<"$second")
  updated_b=$(jq -r .updatedAt <<<"$second")
  echo "  ${DIM}first: step $step_a, started $started_a   later: step $(jq -r .step <<<"$second")${RESET}"
  check "startedAt is the same build" test "$started_a" == "$started_b"
  check "updatedAt moved on" test "$updated_b" -gt "$updated_a"
  check "the log grew" test -s "$state/install.log"
  check "the tail is bounded to 20 lines" \
    bash -c "[[ \$(OMARCHY_FACE_DEV_STATE=$state '$REPO/dev/bin/omarchy-face-status' --install-log | wc -l) -le 20 ]]"

  step "and it finishes on its own"
  for _ in $(seq 1 60); do
    [[ $(jq -r .state "$state/install.json") == done ]] && break
    sleep 1
  done
  check "state is done" bash -c "[[ \$(jq -r .state '$state/install.json') == done ]]"
  check "every step was visited" \
    bash -c "grep -q '== configure' '$state/install.log'"
  summary
fi

# ==============================================================================
# the default run
# ==============================================================================

if [[ ${1:-} != --sandboxed && ${OMARCHY_FACE_F2_IN_NS:-0} != 1 ]]; then
  [[ ${1:-} == "" ]] || { echo "usage: $0 [--builder|--detach|--build-user]" >&2; exit 2; }
  command -v unshare >/dev/null || { echo "f2: unshare is not installed" >&2; exit 1; }
  echo "F2 engine build job — plan-merged.md §4 phase 3"
  echo "${DIM}plugin: $REPO${RESET}"

  step "the shape of the job (read from the shipped files)"
  check "install-engine starts a transient unit" \
    grep -q 'systemd-run --unit=omarchy-face-install' "$ADMIN_SRC"
  check "…that is collected when it ends" grep -q -- '--collect' "$ADMIN_SRC"
  check "…and whose start is Type=exec, so {started:true} means started" \
    grep -q -- '--property=Type=exec' "$ADMIN_SRC"
  check "…and is bounded, so a hung build does not say 'building' for ever" \
    grep -q -- '--property=RuntimeMaxSec=' "$ADMIN_SRC"
  check "build-engine refuses to run under pkexec" \
    bash -c "grep -A3 '^  build-engine)' '$ADMIN_SRC' | grep -q caller_uid || grep -q 'Refused when PKEXEC_UID' '$ADMIN_SRC'"
  check "makepkg runs under DynamicUser, never as root or as the owner" \
    grep -q 'DynamicUser=yes' "$ADMIN_SRC"
  check "…in a unit bound to the job, so stopping the job stops the build" \
    grep -q 'BindsTo=\$INSTALL_UNIT' "$ADMIN_SRC"
  check "the GUI never runs a build itself" \
    bash -c "! grep -rn 'makepkg\|pacman ' '$REPO'/*.qml '$REPO'/common/*.qml"
  check "the GUI's only engine verb is install-engine" \
    grep -q 'adminArgv(\["install-engine"\])' "$REPO/SetupView.qml"

  # The checks above ran before the namespace, and `exec` throws this process
  # away -- so the count goes with it unless it is carried across.
  exec env OMARCHY_FACE_F2_IN_NS=1 \
    OMARCHY_FACE_F2_CHECKS=$checks OMARCHY_FACE_F2_FAILURES=$failures \
    unshare --map-root-user --mount --pid --fork "$BASH" "$0" --sandboxed
fi

# --- inside the namespace -----------------------------------------------------

if [[ ${OMARCHY_FACE_F2_IN_NS:-0} == 1 ]]; then
  checks=${OMARCHY_FACE_F2_CHECKS:-0}
  failures=${OMARCHY_FACE_F2_FAILURES:-0}
  # /etc as a farm of symlinks to the real one, except the two directories the
  # job writes; the same trick f1-round-trip.sh uses, and for the same reason:
  # a bare tmpfs leaves the namespace without /etc/passwd.
  mount --bind /etc /mnt || exit 1
  mount -t tmpfs tmpfs /etc || exit 1
  chmod 0755 /etc
  for real in /mnt/*; do ln -s "$real" "/etc/${real#/mnt/}"; done
  mount -t tmpfs tmpfs /run || exit 1
  chmod 0755 /run
  mount -t tmpfs tmpfs /usr/local || exit 1
  chmod 0755 /usr/local
  mkdir -p /usr/local/bin
  chmod 0755 /usr/local/bin
  mount -t tmpfs tmpfs /var/lib || exit 1
  chmod 0755 /var/lib
  # howdy's own directory and the systemd unit directory the drop-in lands in.
  mount -t tmpfs tmpfs /usr/lib/security || exit 1
  chmod 0755 /usr/lib/security
  mount -t tmpfs tmpfs /usr/lib/systemd/system || exit 1
  chmod 0755 /usr/lib/systemd/system
  echo "${DIM}sandbox: uid $(id -u); /etc /run /var/lib /usr/local and howdy's directory are private${RESET}"
fi

[[ $EUID -eq 0 ]] || { echo "f2: the sandbox did not give us uid 0" >&2; exit 1; }

CONTROL=/run/f2
mkdir -p "$CONTROL/installed" "$CONTROL/pkg"

install -o root -g root -m 0755 "$ADMIN_SRC" /usr/local/bin/omarchy-face-admin || exit 1
install -d -o root -g root -m 0755 /etc/omarchy-face
printf 'account=%s\nsudo=false\nlock=false\n' "${SUDO_USER:-${USER:-root}}" >/etc/omarchy-face/config

# --- the stubs ----------------------------------------------------------------
#
# omarchy-face-admin pins PATH=/usr/local/bin:/usr/bin, and /usr/local is a
# tmpfs in here, so a file of the right name in /usr/local/bin is what it finds.
# Everything the job does to the machine goes through one of these four, and
# each records what it was asked to do.

cat >/usr/local/bin/pacman <<'STUB'
#!/bin/bash
CONTROL=/run/f2
printf '%s\n' "pacman $*" >>"$CONTROL/pacman.log"
case ${1:-} in
  -Q)  [[ -e $CONTROL/installed/${2:-} ]] || exit 1; printf '%s 1.0-1\n' "${2:-}" ;;
  -Qi) cat "$CONTROL/installed/${2:-}" 2>/dev/null ;;
  -S)  [[ -e $CONTROL/fail-deps ]] && exit 1; echo "stub: would install ${*:2}"; exit 0 ;;
  -U)
    for arg in "$@"; do
      [[ -f $arg ]] || continue
      name=$(bsdtar -xOqf "$arg" .PKGINFO | sed -n 's/^pkgname = //p' | head -1)
      [[ -n $name ]] || continue
      printf 'Depends On : none\n' >"$CONTROL/installed/$name"
      # The package's own files, so `configure` finds howdy's config.ini and the
      # drop-in check has something to find.
      bsdtar -C / -xf "$arg" --exclude '.PKGINFO' --exclude '.MTREE' 2>/dev/null
    done
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB

cat >/usr/local/bin/systemctl <<'STUB'
#!/bin/bash
CONTROL=/run/f2
printf '%s\n' "systemctl $*" >>"$CONTROL/systemctl.log"
[[ $* == *is-active* ]] && exit "$(cat "$CONTROL/unit-active" 2>/dev/null || echo 3)"
exit 0
STUB

# The one stub that does real work: it stands in for both uses of systemd-run --
# starting the job, and running a phase as the build user.
cat >/usr/local/bin/systemd-run <<'STUB'
#!/bin/bash
CONTROL=/run/f2
printf '%s\n' "systemd-run $*" >>"$CONTROL/systemd-run.log"

if [[ $* == *--unit=omarchy-face-install* ]]; then
  # install-engine's call. The real one returns as soon as the job has exec'd.
  exit "$(cat "$CONTROL/start-fails" 2>/dev/null || echo 0)"
fi

if [[ $* == *DynamicUser=yes* ]]; then
  # run_as_builder. The phase is the last argument; the build directory the one
  # before it. Instead of compiling, leave behind exactly what the build user
  # would have left -- or the failure the test asked for.
  phase=${*: -1}
  dir=${*: -2:1}
  # systemd puts a DynamicUser unit's StateDirectory in /var/lib/private and
  # leaves /var/lib/<name> as a symlink to it. Root reads the private path, the
  # unit sees the link, and the test has to have both or it tests neither.
  mkdir -p /var/lib/private/omarchy-face-build
  [[ -e $dir ]] || ln -s /var/lib/private/omarchy-face-build "$dir"
  : >"$dir/result"
  if [[ -e $CONTROL/builder-fail-$phase ]]; then
    cat "$CONTROL/builder-fail-$phase" >"$dir/result"
    echo "stub builder: failing $phase"
    exit 1
  fi
  case $phase in
    fetch)
      mkdir -p "$dir/python-dlib" "$dir/howdy"
      echo "stub builder: cloned"
      ;;
    build)
      cp "$CONTROL/pkg"/*.pkg.tar.zst "$dir/python-dlib/" 2>/dev/null
      mv "$dir/python-dlib"/howdy-*.pkg.tar.zst "$dir/howdy/" 2>/dev/null
      [[ -e $CONTROL/builder-note ]] && cp "$CONTROL/builder-note" "$dir/notes"
      echo "stub builder: built"
      ;;
  esac
  exit 0
fi
exit 0
STUB

cat >/usr/local/bin/omarchy-face-camera <<'STUB'
#!/bin/bash
[[ ${1:-} == --describe ]] || exit 2
printf '{"ir":"/dev/v4l/by-path/pci-0000:00:14.0-usb-0:8:1.0-video-index2","irNode":"/dev/video2","irSize":"400x400","name":"Stub IR Camera","rgb":"/dev/video0"}\n'
STUB

chmod 0755 /usr/local/bin/{pacman,systemctl,systemd-run,omarchy-face-camera}

# --- package fixtures ---------------------------------------------------------
#
# Real .pkg.tar.zst files, because the job's checks are `bsdtar` on the package
# and nothing else would exercise them.

# The config `configure` edits is howdy's own, so the fixture is howdy's own
# wherever it can be had: out of a package this machine has built, else out of
# the tag in the yay cache. Hand-written keys would test the seds against the
# spelling this file happens to use, which is the one spelling that cannot be
# wrong. The fallback is there so the test still runs on a machine with neither.
config_source="a copy in this test"
STOCK_CONFIG=""
built_howdy=$(compgen -G '/tmp/omarchy-face-f2.*/howdy/howdy-[0-9]*.pkg.tar.*' 2>/dev/null | head -1)
if [[ -n $built_howdy ]]; then
  STOCK_CONFIG=$(bsdtar -xOqf "$built_howdy" usr/lib/security/howdy/config.ini 2>/dev/null)
  [[ -n $STOCK_CONFIG ]] && config_source="the howdy package built by --builder"
fi
if [[ -z $STOCK_CONFIG ]]; then
  STOCK_CONFIG=$(git -C "$HOME/.cache/yay/howdy/howdy" show v2.6.1:src/config.ini 2>/dev/null)
  [[ -n $STOCK_CONFIG ]] && config_source="howdy v2.6.1 in the yay cache"
fi
if [[ -z $STOCK_CONFIG ]]; then
  STOCK_CONFIG=$(cat <<'INI'
[core]
disabled = false
[video]
certainty = 3.5
timeout = 4
device_path = none
frame_width = -1
frame_height = -1
dark_threshold = 50
recording_plugin = opencv
[snapshots]
capture_failed = true
capture_successful = true
[debug]
end_report = false
INI
)
fi
echo "${DIM}howdy's config.ini for this run: $config_source${RESET}"

make_package() { # make_package <out> <pkgname> <depends…> -- called with EXTRA=… for files
  local out=$1 name=$2
  shift 2
  local root
  root=$(mktemp -d)
  {
    printf 'pkgname = %s\n' "$name"
    printf 'pkgver = 1.0-1\narch = x86_64\n'
    local dependency
    for dependency in "$@"; do printf 'depend = %s\n' "$dependency"; done
  } >"$root/.PKGINFO"
  if [[ $name == howdy ]]; then
    mkdir -p "$root/usr/lib/security/howdy"
    printf '%s\n' "$STOCK_CONFIG" >"$root/usr/lib/security/howdy/config.ini"
    printf '# compare\n' >"$root/usr/lib/security/howdy/compare.py"
  fi
  if [[ -n ${WITH_DROPIN:-} ]]; then
    mkdir -p "$root/usr/lib/systemd/system/polkit-agent-helper@.service.d"
    printf '[Service]\n' >"$root/usr/lib/systemd/system/polkit-agent-helper@.service.d/10-howdy.conf"
  fi
  # `.PKGINFO *` would leave a package of one file when the glob matches
  # nothing, and bsdtar would refuse the literal `*`.
  ( cd "$root" && bsdtar -c --zstd -f "$out" $(ls -A) )
  rm -rf "$root"
}

reset_state() {
  rm -rf "$CONTROL" /run/omarchy-face /var/lib/omarchy-face /var/lib/private
  rm -f /usr/lib/security/howdy/config.ini
  mkdir -p "$CONTROL/installed" "$CONTROL/pkg"
}

# --- the happy path -----------------------------------------------------------

step "a fresh machine: build-engine from nothing"
reset_state
make_package "$CONTROL/pkg/python-dlib-20.0.1-2-x86_64.pkg.tar.zst" python-dlib python cblas lapack
# makepkg leaves a debug package beside the real one whenever `debug` is in
# OPTIONS, which it is in Arch's stock makepkg.conf. It must not be mistaken for
# the package to install, and neither must python-dlib-cuda.
make_package "$CONTROL/pkg/python-dlib-debug-20.0.1-2-x86_64.pkg.tar.zst" python-dlib-debug
make_package "$CONTROL/pkg/howdy-2.6.1-3-x86_64.pkg.tar.zst" howdy python python-dlib
out=$(/usr/local/bin/omarchy-face-admin build-engine 2>&1)
rc=$?
echo "  ${DIM}${out}${RESET}"
check "build-engine exits 0" test $rc -eq 0
check "install.json says done" bash -c "[[ \$(jq -r .state /run/omarchy-face/install.json) == done ]]"
check "…on the last step" bash -c "[[ \$(jq -r .step /run/omarchy-face/install.json) == done ]]"
check "…with no error" bash -c "[[ \$(jq -r .error /run/omarchy-face/install.json) == '' ]]"
check "the step list is the contract's" \
  bash -c "[[ \$(jq -c .steps /run/omarchy-face/install.json) == '[\"deps\",\"fetch\",\"build\",\"install\",\"configure\",\"done\"]' ]]"
check "install.log is world-readable" bash -c "[[ \$(stat -c %a /run/omarchy-face/install.log) == 644 ]]"
check "install.json is world-readable" bash -c "[[ \$(stat -c %a /run/omarchy-face/install.json) == 644 ]]"
check "every step reached the log" \
  bash -c "for s in deps fetch build install configure done; do grep -q \"== \$s\" /run/omarchy-face/install.log || exit 1; done"

step "what it did to the machine"
check "dlib was installed as a dependency" grep -q -- '-U --noconfirm --asdeps' "$CONTROL/pacman.log"
check "howdy was installed" grep -qE -- '-U --noconfirm /.*howdy-' "$CONTROL/pacman.log"
check "the build deps were installed first" grep -q -- '-S --needed --noconfirm base-devel' "$CONTROL/pacman.log"
check "the debug package was left alone" bash -c "! grep -q 'python-dlib-debug' '$CONTROL/pacman.log'"
check "dlib went in before howdy" \
  bash -c "[[ \$(grep -n -- '-U' '$CONTROL/pacman.log' | head -1) == *python-dlib* ]]"
check "no polkit drop-in was left behind" test ! -e /usr/lib/systemd/system/polkit-agent-helper@.service.d/10-howdy.conf

step "configure (plan-engine.md §5.2 step 5)"
config=/usr/lib/security/howdy/config.ini
echo "  ${DIM}$(grep -E 'device_path|timeout|frame_|end_report|capture_|disabled|certainty' "$config" | tr '\n' ' ')${RESET}"
check "device_path is the camera's by-path name" grep -qx 'device_path = /dev/v4l/by-path/pci-0000:00:14.0-usb-0:8:1.0-video-index2' "$config"
check "timeout is 5" grep -qx 'timeout = 5' "$config"
check "the frame size came from the sensor" bash -c "grep -qx 'frame_width = 400' '$config' && grep -qx 'frame_height = 400' '$config'"
check "end_report is on, so a match can be attributed" grep -qx 'end_report = true' "$config"
check "snapshots are off" bash -c "grep -qx 'capture_failed = false' '$config' && grep -qx 'capture_successful = false' '$config'"
check "howdy is not disabled" grep -qx 'disabled = false' "$config"
check "certainty was left stock" grep -qx 'certainty = 3.5' "$config"
check "dark_threshold was left stock" grep -qx 'dark_threshold = 50' "$config"
check "the config stays root-only" bash -c "[[ \$(stat -c '%U %a' '$config') == 'root 600' ]]"

step "engine.json (plan-engine.md §11.4)"
echo "  ${DIM}$(cat /var/lib/omarchy-face/engine.json)${RESET}"
check "it parses" jq -e . /var/lib/omarchy-face/engine.json
check "threshold is on the 0-1 scale" \
  bash -c "[[ \$(jq -r .threshold /var/lib/omarchy-face/engine.json) == 0.35 ]]"
check "it names the howdy that is installed" \
  bash -c "[[ \$(jq -r .howdy /var/lib/omarchy-face/engine.json) == 1.0-1 ]]"
check "it is world-readable" bash -c "[[ \$(stat -c %a /var/lib/omarchy-face/engine.json) == 644 ]]"
check "the build directory is gone" test ! -e /var/lib/private/omarchy-face-build

# The document goes through a file, not a here-string: row labels carry
# apostrophes ("Face's system files"), and a quoted status document pasted into
# a `bash -c` is a check that fails for a reason that has nothing to do with the
# thing being checked.
STATUS_OUT=$CONTROL/status.json
read_status() { "$STATUS_SRC" --json >"$STATUS_OUT"; }
row_field() { jq -r ".rows[] | select(.id == \"$1\") | .$2" "$STATUS_OUT"; }

step "the status helper reads it back"
read_status
echo "  ${DIM}$(jq -c '.rows[] | select(.id == "engine" or .id == "install-job")' "$STATUS_OUT")${RESET}"
check "the engine row is ok" bash -c "[[ \$(jq -r '.rows[]|select(.id==\"engine\")|.state' '$STATUS_OUT') == ok ]]"
check "engine.threshold reached the contract" \
  bash -c "[[ \$(jq -r .engine.threshold '$STATUS_OUT') == 0.35 ]]"
check "install.state is done" bash -c "[[ \$(jq -r .install.state '$STATUS_OUT') == done ]]"

# --- a second build, with the packages already there --------------------------

step "running it again keeps the packages (the --keep-packages path)"
: >"$CONTROL/pacman.log"
rm -f /var/lib/omarchy-face/engine.json
out=$(/usr/local/bin/omarchy-face-admin build-engine 2>&1)
check "it still succeeds" test $? -eq 0
check "and rebuilt nothing" bash -c "! grep -q -- '-U ' '$CONTROL/pacman.log'"
check "but configured again" test -f /var/lib/omarchy-face/engine.json
check "and said so in notes" \
  bash -c "jq -r '.notes[]' /run/omarchy-face/install.json | grep -q 'already installed'"

step "a CUDA dlib is not 'already installed'"
: >"$CONTROL/pacman.log"
printf 'Depends On : cuda cudnn python\n' >"$CONTROL/installed/python-dlib"
out=$(/usr/local/bin/omarchy-face-admin build-engine 2>&1)
check "it rebuilds rather than keeping it" grep -q -- '-U --noconfirm --asdeps' "$CONTROL/pacman.log"

# --- the refusals -------------------------------------------------------------

step "a dlib package that wants CUDA is never installed (E9)"
reset_state
make_package "$CONTROL/pkg/python-dlib-20.0.1-2-x86_64.pkg.tar.zst" python-dlib python cuda cudnn
make_package "$CONTROL/pkg/howdy-2.6.1-3-x86_64.pkg.tar.zst" howdy python
out=$(/usr/local/bin/omarchy-face-admin build-engine 2>&1)
rc=$?
echo "  ${DIM}${out}${RESET}"
check "build-engine exits 1" test $rc -eq 1
check "with cuda_in_package" bash -c "[[ \$(jq -r .error <<<'$out') == cuda_in_package ]]"
check "install.json says failed" bash -c "[[ \$(jq -r .state /run/omarchy-face/install.json) == failed ]]"
check "…at the install step" bash -c "[[ \$(jq -r .step /run/omarchy-face/install.json) == install ]]"
check "nothing was installed" bash -c "! grep -q -- '-U ' '$CONTROL/pacman.log'"
check "the build directory was cleaned up" test ! -e /var/lib/private/omarchy-face-build

step "a howdy package still carrying the polkit drop-in is stripped after install"
reset_state
make_package "$CONTROL/pkg/python-dlib-20.0.1-2-x86_64.pkg.tar.zst" python-dlib python
WITH_DROPIN=1 make_package "$CONTROL/pkg/howdy-2.6.1-3-x86_64.pkg.tar.zst" howdy python
out=$(/usr/local/bin/omarchy-face-admin build-engine 2>&1)
check "the build still finishes" test $? -eq 0
check "the drop-in is not on the machine" \
  test ! -e /usr/lib/systemd/system/polkit-agent-helper@.service.d/10-howdy.conf
check "and the job said so" \
  bash -c "jq -r '.notes[]' /run/omarchy-face/install.json | grep -q 'polkit drop-in'"

step "a build user that stops on the CUDA switch"
reset_state
printf 'cuda_flag_missing\n' >"$CONTROL/builder-fail-build"
out=$(/usr/local/bin/omarchy-face-admin build-engine 2>&1)
check "exits 1" test $? -eq 1
check "with the build user's own code" bash -c "[[ \$(jq -r .error <<<'$out') == cuda_flag_missing ]]"
check "install.json carries it too" \
  bash -c "[[ \$(jq -r .error /run/omarchy-face/install.json) == cuda_flag_missing ]]"
read_status
check "the engine row is broken, with a Fix" \
  bash -c "[[ \$(jq -r '.rows[]|select(.id==\"engine\")|.state + \" \" + .fix' '$STATUS_OUT') == 'broken install-engine' ]]"

step "a machine whose pacman database is locked"
reset_state
mkdir -p /var/lib/pacman && touch /var/lib/pacman/db.lck
out=$(/usr/local/bin/omarchy-face-admin build-engine 2>&1)
check "it says so before installing anything" bash -c "[[ \$(jq -r .error <<<'$out') == pacman_locked ]]"
rm -f /var/lib/pacman/db.lck

step "two builds at once"
reset_state
make_package "$CONTROL/pkg/python-dlib-20.0.1-2-x86_64.pkg.tar.zst" python-dlib python
make_package "$CONTROL/pkg/howdy-2.6.1-3-x86_64.pkg.tar.zst" howdy python
mkdir -p /run/omarchy-face
# Hold the job's own lock and ask for another build.
( flock -n 9 && sleep 5 ) 9>>/run/omarchy-face/install.lock &
holder=$!
sleep 0.3
out=$(/usr/local/bin/omarchy-face-admin build-engine 2>&1)
rc=$?
kill $holder 2>/dev/null
wait $holder 2>/dev/null
check "the second build exits 3" test $rc -eq 3
check "and says install_running" bash -c "[[ \$(jq -r .error <<<'$out') == install_running ]]"

# --- install-engine, the verb the GUI presses ---------------------------------

step "install-engine starts the job and returns"
reset_state
echo 3 >"$CONTROL/unit-active"    # is-active: inactive
out=$(/usr/local/bin/omarchy-face-admin install-engine 2>&1)
rc=$?
echo "  ${DIM}${out}${RESET}"
check "exits 0" test $rc -eq 0
check "with {started:true}" bash -c "[[ \$(jq -r .started <<<'$out') == true ]]"
check "it asked systemd for a transient unit" \
  grep -q -- '--unit=omarchy-face-install.*build-engine' "$CONTROL/systemd-run.log"
check "…which is collected when it ends" grep -q -- '--collect' "$CONTROL/systemd-run.log"
check "install.json is already running, so the GUI has something to show" \
  bash -c "[[ \$(jq -r .state /run/omarchy-face/install.json) == running ]]"
check "…with a startedAt for the elapsed clock" \
  bash -c "[[ \$(jq -r .startedAt /run/omarchy-face/install.json) -gt 0 ]]"

step "while it runs, a second click is refused"
echo 0 >"$CONTROL/unit-active"    # is-active: active
out=$(/usr/local/bin/omarchy-face-admin install-engine 2>&1)
rc=$?
check "exit 3" test $rc -eq 3
check "install_running" bash -c "[[ \$(jq -r .error <<<'$out') == install_running ]]"
read_status
check "the engine row does not offer a Fix while the build runs" \
  bash -c "[[ \$(jq -r '.rows[]|select(.id==\"engine\")|.state + \" \" + (.fixable|tostring)' '$STATUS_OUT') == 'unknown false' ]]"

step "a build whose unit vanished is not 'building' for ever"
mkdir -p /run/systemd/system
echo 3 >"$CONTROL/unit-active"    # is-active: inactive, with install.json still running
read_status
echo "  ${DIM}$(jq -c '.rows[] | select(.id == "engine" or .id == "install-job")' "$STATUS_OUT")${RESET}"
check "the engine row is broken" \
  bash -c "[[ \$(jq -r '.rows[]|select(.id==\"engine\")|.state' '$STATUS_OUT') == broken ]]"
check "…and offers the build again" \
  bash -c "[[ \$(jq -r '.rows[]|select(.id==\"engine\")|.fix' '$STATUS_OUT') == install-engine ]]"

step "systemd refusing the job is not a lie about having started it"
reset_state
echo 3 >"$CONTROL/unit-active"
echo 1 >"$CONTROL/start-fails"
out=$(/usr/local/bin/omarchy-face-admin install-engine 2>&1)
rc=$?
check "exit 1" test $rc -eq 1
check "start_failed" bash -c "[[ \$(jq -r .error <<<'$out') == start_failed ]]"
check "install.json says failed, not running" \
  bash -c "[[ \$(jq -r .state /run/omarchy-face/install.json) == failed ]]"

# --- the patches, against the real PKGBUILDs ---------------------------------

step "the patches, against the PKGBUILDs the AUR ships"
work=$(mktemp -d)
script=$work/build-script
extract_build_script "$script"
if fetch_pkgbuilds "$work"; then
  # makepkg stubbed: this test is about the two edits, not the compile.
  cat >/usr/local/bin/makepkg <<'STUB'
#!/bin/bash
touch "$(basename "$PWD")-1.0-1-x86_64.pkg.tar.zst"
exit 0
STUB
  chmod 0755 /usr/local/bin/makepkg
  PATH=/usr/local/bin:/usr/bin bash -c "$(cat "$script")" omarchy-face-build "$work" build >/dev/null 2>&1
  check "dlib's CUDA switch is off" grep -qx '_build_cuda=0' "$work/python-dlib/PKGBUILD"
  check "and nothing else in that file changed" \
    bash -c "diff <(sed 's/^_build_cuda=0$/_build_cuda=1/' '$work/python-dlib/PKGBUILD') \
                  <(cat '$HOME/.cache/yay/python-dlib/PKGBUILD' 2>/dev/null || cat '$work/python-dlib.git/PKGBUILD')"
  check "howdy's package() no longer installs the polkit drop-in" \
    bash -c "! grep -q '10-howdy.conf' '$work/howdy/PKGBUILD'"
  check "…and still installs everything else" \
    bash -c "grep -q 'cp -r src/\*' '$work/howdy/PKGBUILD' && grep -q 'bash-completion' '$work/howdy/PKGBUILD'"
  check "the patched PKGBUILD is still valid shell" bash -n "$work/howdy/PKGBUILD"

  # And the refusal: no switch, no build.
  sed -i 's/^_build_cuda=0$/_build_cuda=/' "$work/python-dlib/PKGBUILD"
  PATH=/usr/local/bin:/usr/bin bash -c "$(cat "$script")" omarchy-face-build "$work" build >/dev/null 2>&1
  check "a dlib PKGBUILD without the switch stops the build" \
    bash -c "[[ \$(cat '$work/result') == cuda_flag_missing ]]"
else
  note "no PKGBUILDs available (no yay cache and no network) — patch checks skipped"
fi
rm -rf "$work"

summary
