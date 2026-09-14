# Development

Working notes for building this plugin, not documentation for using it.

## Never edit in `~/.config/omarchy/plugins`

Every write under that folder reloads every plugin bar widget in the shell
(`PluginRegistry.qml:663-680` → `shell.qml:1447-1461`), which destroys the Face
popup and everything it was driving. Work in this repo and push a copy in with
`./install.sh`: one write burst, one reload.

`shell.json` is *outside* that folder, so `omarchy plugin enable`/`disable`
reload nothing — which is why the lock-screen switch is config-only.

## The stub engine

The GUI is built ahead of the engine it talks to, so `dev/bin` holds stubs of
the four helpers, answering from `dev/fixtures/<name>/`:

| Helper | What the stub does |
|---|---|
| `omarchy-face-status` | prints `dev/fixtures/$OMARCHY_FACE_DEV_FIXTURE/status.json`, exit 0 always |
| `omarchy-face-admin` | answers in the contract's shape, writes nothing outside the fixture directory; `enroll-session` is not scripted yet. Setup's **first install** also lands here in development (`Ask.firstInstallArgv`), so the `pkexec /bin/bash` form never runs against a fixture. `install-engine` and `install-system` start the stand-in build below |
| `omarchy-face-lock` | answers `{ok}` and deliberately never touches the plugins folder |
| `omarchy-face-identity` | `list` from the fixture; `verify` exits 3 (unavailable) unless `OMARCHY_FACE_DEV_VERIFY=<code>` says otherwise, and `OMARCHY_FACE_DEV_VERIFY_SECONDS=N` makes it take that long first, so a test can watch the Test card while it checks and stop it |

With `OMARCHY_FACE_DEV_BIN` set, the GUI takes every helper from that directory
and drops `pkexec` (`plan-gui.md §2.1`). It grants nothing: a stub running as
the user cannot write root-owned state.

`OMARCHY_FACE_DEV_STATE` does the same for the files the GUI watches directly
(`people.json`, `install.json`, and from phase 5 `state.json`), which on a real
machine live under root-owned paths a stub cannot write. Point it at a fixture
directory. The admin stub also appends every verb it was called with to
`verbs.log` in there — a view that says it turned sudo on has to be shown to have
asked for `sudo-on` — and `OMARCHY_FACE_DEV_VERB_ERROR=<code>` makes the next
write verb answer with that error, so the error copy in a view is testable too.

The shell is spawned by Hyprland and inherits *its* environment, not a
terminal's, so exporting the variables in a shell does nothing. `./install.sh
--dev` restarts the shell with them set:

```sh
./install.sh --dev                                  # fixture: fresh
OMARCHY_FACE_DEV_FIXTURE=three-people ./install.sh --dev
```

Fixtures so far: `fresh` (nothing installed) and `three-people` (engine
installed, sudo on, an owner and two others). More arrive with the views that
need them.

## Asking the popup what it is doing

```sh
omarchy-shell graveklar.face state             # {"open":true,"view":"setup",…}
omarchy-shell graveklar.face open people ""    # open on a view
omarchy-shell graveklar.face open person anna  # open on one person
omarchy-shell graveklar.face.card state        # the keepLoaded service
```

**Both arguments of `open` are required.** Quickshell checks arity, so
`… open people` fails with "Too few arguments provided"; the empty string is how
you say "no name".

`state` is how the plugins-folder proof is observed: a destroyed popup cannot be
asked, and a reload takes the popup with it. `dev/g1-plugins-folder-proof.sh`
runs that proof end to end.

## The system half

`system/` holds everything that is installed as root, and `bin/` the two
unprivileged helpers that ship with the plugin (`plan-engine.md §8.1`):

| | |
|---|---|
| `system/install.sh` | the first install. The GUI reads it and passes its **text** to `pkexec /bin/bash -c`, so what polkit authorised is what runs. It installs `omarchy-face-admin` from a root-owned snapshot and hands over. |
| `system/omarchy-face-admin` | every privileged verb, behind `no.graveklar.face.owner`. Phase 2 implements `install-system`, `purge` and `purge-legacy`; the rest answer `not_implemented`. |
| `system/omarchy-face-camera` | which V4L2 node is the infrared one. Runs as anybody, and the status script runs the plugin's own copy before anything is installed. |
| `system/omarchy-face-{gate,verify}` | phase 5: the two lines `sudo-on` puts in `/etc/pam.d/sudo`. The gate decides whether asking the camera is worth it (exit 0 = skip); the verifier is the only file in this project whose exit 0 authenticates somebody. |
| `system/omarchy-faced` | phase 6: the socket daemon, and the one listening thing in the project. It is the only root process that opens the camera for a caller holding no privilege, which is why peer credentials and draining are gates on it rather than details. |
| `system/omarchy-face-lock-verify` | phase 7. Ships in its safe state — answers nothing — because the `system` row installs and compares all seven helpers as a set. |
| `bin/omarchy-face-status` | the whole read half of the contract. |

Every installed file carries two headers, `omarchy-face v2` and
`omarchy-face-version: X.Y.Z`. The version is a **literal**, bumped by hand when
the plugin is released: nothing substitutes it at install time, because the
`system` row compares the installed files byte for byte with the plugin's
`system/` copies, and a substitution would make every machine look modified.

## F1 — install → purge

```sh
./dev/f1-round-trip.sh          # in a private user namespace (the default)
sudo ./dev/f1-round-trip.sh --here   # on this machine, for real
```

The gate of `plan-merged.md §4` phase 2: install the system half the way the GUI
does, check what landed, refuse the things that must be refused, purge, and run
the §10.3 checklist — with every file in `/etc/pam.d` hashed before and after.

It also covers three things that have no verb yet and would otherwise go
untested until the phase that depends on them:

- **`pam_insert_block` / `pam_remove_block`**, sourced straight out of the
  installed `omarchy-face-admin` (everything above its verb dispatch). Insert,
  refuse a second insert, refuse a block somebody has edited, remove, and assert
  the stack is byte-identical to what it was. Phase 5's `sudo-on`/`sudo-off`
  call these functions; they do not get their own copy.
- **The daemon drains its socket.** `Accept=no` hands over the *listening*
  socket, so a daemon that exits without `accept()`ing leaves the client pending
  and systemd re-activates it until the start-rate limit puts the socket unit
  itself into `failed` — a denial of service any local user can run, needing
  root to undo. Every exit path of the real daemon must keep this property.
- **A first install for a non-administrator account is refused.** Face's own
  polkit action is `auth_self`, so the owner can later install system files with
  their own password; an owner who is not already an administrator would be an
  owner who just became one.

The default run is sandboxed with `unshare --map-root-user --mount`: uid 0 that
owns nothing, tmpfs over `/etc`, `/run`, `/usr/local` and polkit's actions
directory, and the checkout bound over the account's plugin folder so the update
path is tested against the code being written. Nothing outside the namespace is
written, and no password is needed. What the sandbox cannot do is talk to
systemd, so `systemctl --now` and `daemon-reload` come back as warnings; `--here`
is the run that proves the socket really starts.

## The stand-in engine build

`dev/bin/omarchy-face-build-standin` walks the real step list into
`$OMARCHY_FACE_DEV_STATE/install.json` and writes a log beside it, without
compiling anything. `install-engine` (and the first install) start it as a
transient unit of the **user** manager — `systemd-run --user --unit=
omarchy-face-dev-build` — which gives it the one property the real job's gate is
about: it is not a child of the popup, so closing the popup or restarting the
shell does not touch it.

```sh
./install.sh --dev                                       # click Build the face engine
OMARCHY_FACE_DEV_BUILD_SECONDS=20 ./install.sh --dev     # a longer build to close the popup during
OMARCHY_FACE_DEV_BUILD_FAIL=build:dlib_build_failed ./install.sh --dev   # the failed path
systemctl --user status omarchy-face-dev-build           # it is a unit, not a child
```

The variables have to reach the *shell*, which inherits Hyprland's environment;
`install.sh --dev` passes `OMARCHY_FACE_DEV_*` through, so set them in front of
it rather than exporting them in a terminal.

## F2 — the engine build

```sh
./dev/f2-engine-job.sh              # sandbox: build-engine end to end, stubs for pacman and systemd
./dev/f2-engine-job.sh --detach     # the job outlives whatever started it
./dev/f2-engine-job.sh --builder    # the REAL compile, as this account (dlib takes a while)
sudo ./dev/f2-engine-job.sh --build-user   # plan-engine.md §5.3: makepkg under DynamicUser
```

The gate of `plan-merged.md §4` phase 3. The default run is the same private
user namespace `f1-round-trip.sh` uses, with `pacman`, `systemctl`,
`systemd-run` and the camera stubbed in `/usr/local/bin` (which is where the
helper's pinned `PATH` looks first). That is what lets the package verification
be tested with packages that are deliberately wrong: a dlib whose `.PKGINFO`
depends on CUDA, and a howdy still carrying the polkit drop-in.

`--builder` runs the **shipped** build script — extracted out of
`system/omarchy-face-admin`, so a patch that is edited in the helper and not in
the test cannot pass — and checks what came out: one `python-dlib` package, no
`python-dlib-cuda`, nothing depending on cuda or cudnn, no `libcud*` in the
package, and no `10-howdy.conf` in howdy's.

`--build-user` is the only run that needs root, and it answers the one question
a sandbox cannot: whether `makepkg` (and `fakeroot` inside it) runs under
systemd's `DynamicUser`. If it does not, `plan-engine.md §5.3`'s fallback
applies.

### The AUR revisions are pinned

`AUR_PIN_PYTHON_DLIB` and `AUR_PIN_HOWDY` at the top of
`system/omarchy-face-admin` are the two commits Face builds from. They are not a
convenience: `pacman -U` runs a package's install scriptlet as root, and a
PKGBUILD can add files Face does not own, so "whatever the AUR has today" is a
thing nobody reviewed running as root on the owner's say-so. `.PKGINFO` cannot
help — it is generated *from* the PKGBUILD.

When either package is updated in the AUR, builds stop with `pkgbuild_changed`
until the pins here move. **Updating them is a review job**, not a bump: read
both PKGBUILDs (and `howdy.install`, which runs as root) for what they do, run
`./dev/f2-engine-job.sh --builder` against the new revisions, then change the two
lines. The default run tells you when a pin has fallen behind HEAD.

## G2 — the engine row

```sh
./dev/g2-engine-row.sh            # on the live shell: close the popup, restart the shell, mid-build
./dev/g2-engine-row-offscreen.sh  # the same view in a QML runtime with no shell to restart
```

The live one is what the gate is written about, and it restarts the shell twice,
so it refuses while the session is locked. The offscreen one loads the **real**
`SetupView.qml` against the running Omarchy's `qs.Commons` and `qs.Ui` with a
fake panel in front of it (`dev/qml-harness/shell.qml`), drives it through
`running`, `failed` and `idle`, and checks the step marks, the elapsed
formatting, the Fix button's three states, the folded `install-job` row and the
log tail it fetches through `common/Ask.qml`. It draws nothing, so it cannot say
the row *looks* right — only that every binding in it evaluates and agrees with
the contract.

## F3 — the people store

```sh
./dev/f3-stdin-pkexec.sh            # first: does a session survive pkexec?
./dev/f3-stdin-pkexec.sh --real     # the same, through the real dialog (needs you)
./dev/f3-people-store.sh            # the store, the session, the derived sets
./dev/f3-people-store.sh --real     # the REAL howdy against the REAL IR camera
./dev/f3-people-store.sh --measure  # --real, plus §7's 3/6/9 measurement
```

`f3-stdin-pkexec.sh` comes first on purpose (`plan-merged.md §1` row 19): every
other thing in this phase assumes pkexec hands its standard streams to the
program it execs, and a session is a conversation on those streams. The default
run proves the channel through a stand-in that delays and then `exec`s; only
`--real` can prove pkexec itself, and only with somebody at the keyboard —
Face's action is `auth_self`, and polkit has no way to be answered by a script.

`f3-people-store.sh` runs in the same private namespace `f1-round-trip.sh` uses,
with tmpfs over `/etc`, `/run`, `/var/lib`, `/usr/local` and
`/usr/lib/security`, so no person is ever recorded on this machine. By default
the engine is stubbed — two small scripts that speak howdy's model format and can
be told to fail the way `add.py` does — which is what lets `no_face`,
`multiple_faces`, `too_dark`, `black_frames` and a busy camera all be tested.

Three of its steps are about a session being a **standing authorisation**
(`plan-engine.md §12` risk 9): one nobody drives expires and discards the
captures it was holding rather than committing them, a commit re-decides
`owner`/`sudo` from the locked read so two first-time sessions cannot both become
the owner, and a person removed while their session is open is not brought back
by it. The expiry is watched through `OMARCHY_FACE_SESSION_SECONDS`, which the
helper clamps **downwards** — it can only shorten a session, never lengthen one,
and pkexec drops the caller's environment anyway.

`--real` unpacks the howdy and python-dlib **packages the engine build produced**
into the sandbox (`/tmp/omarchy-face-f2.*`, from `f2-engine-job.sh --builder`)
and runs them against `/dev/video2`: a real capture, a real `compare.py`, and E8
confirmed on the installed file — the winning model's label really is
`<name>/<appearance>`, and the printed certainty really is ten times the JSON
one. Nothing is installed on the machine; the packages are bind-mounted into the
namespace and gone when it exits.

## G3/G4 — People, Person and the recording card

```sh
./dev/g3-people-offscreen.sh
```

The same shape as `g2-engine-row-offscreen.sh`: the real `PeopleView.qml`,
`PersonView.qml` and `RecordSession.qml` in a QML runtime, against the running
Omarchy's `qs.Commons` and `qs.Ui`, with a fake panel in front of them. Three of
phase 4's five gate clauses are proved here — the countdown starting at `ready`
rather than at the click, Esc before a capture closing stdin and writing nothing,
and the name rule.

Two knobs exist for it, both GUI-side and both development-only:
`OMARCHY_FACE_DEV_PKEXEC=1` keeps `pkexec` in argv[0] in front of the stub
(argv[0] is what decides whether a stream is cancelled by closing stdin or by a
signal), and the harness puts a stand-in `pkexec` earlier in `PATH` that sleeps
for ten seconds and then `exec`s — the dialog, without the password.

The fourth clause added here is the other half of risk 9: the `record-orphan`
case destroys a running session the way closing a card does and checks the
stand-in's transcript says `discarded`. The session's `Process` belongs to
`common/Ask.qml`, not to the session item, so a session that did not close its
own stdin on the way out would leave an authorised root `enroll-session` reading
a pipe nothing will ever close.

The recording card itself (`RecordCard.qml`) is a layer-shell window and is not
covered offscreen: what it draws is checked by opening it. Everything it decides
is in `RecordSession.qml`, which is.

## F4 — sudo's PAM stack

```sh
./dev/f4-sudo-pam.sh
```

**There is no `--here`, and there will not be.** The file under test is
`/etc/pam.d/sudo`, and a bug in it is a machine nobody can become root on. The
whole run happens in the same private namespace the other suites use, where
`/etc/pam.d` is a **copy** — the real one is not reachable from inside at all,
by construction rather than by care.

It proves clauses 2 and 3 of the phase-5 gate five times over: the machine's own
`sudo` stack, stock Arch with `pam_systemd.so class=none`, a stack whose `auth`
lines are in the middle of the file, one with no trailing newline, and one
carrying somebody else's `pam_exec` line. Each is round-tripped, and each time
the assertions are the same two: with the block in, `grep -v omarchy-face` is the
file we started from, byte for byte; with it out, `sha256sum` is.

Then the gate's nine skip reasons, the verifier's fail-closed paths, and the two
things this phase is really for:

- **one authentication attempt per sudo call.** The gate, the verifier and the
  gate again are run from **one** process wearing sudo's argv, which is what a
  password retry is: same pid, same start time, same attempt key. The second
  gate must skip, and the engine must have been asked exactly once.
- **attribution.** The verifier's parent is a process whose
  `/proc/<pid>/cmdline` really is `sudo -s -u root pacman` (`os.execv` can set a
  whole argv), and *its* parent is `timeout`, standing in for the terminal. So
  `requester.command` is parsed from the same shape of data as on a live
  machine, and the ancestor walk really has a shell to skip. The parser is also
  driven directly over eleven argv shapes, including the two a "last letter
  decides" rule gets wrong (`-Hu root` and `-uroot`).

It also holds the two rules the phase-5 security review turned into invariants:
**`sudo-off` writes the config before it edits the file** (both helpers read
`sudo` from the config before anything else, so that write — not the edit — is
what makes them inert, and a refused edit must not leave the camera live while
the GUI says the feature is off), and **the camera has a ceiling**: six attempts
a minute across separate `sudo` calls, because the per-call marker cannot bound a
`sudo -n` loop.

`logger` is stood in for by a **bind mount over `/usr/bin/logger`**, because the
helpers pin `PATH=/usr/bin:/usr/local/bin` — the distribution's tools win every
name — so a stand-in in `/usr/local/bin` would never be reached.

**What it cannot prove, and what needs a person:** that `sudo` itself runs these
lines, that `pam_exec … seteuid` hands them root, and that the card appears while
the password prompt is up. Those need a live `sudo` and a face.

## F4b — what libpam does with Face's two lines

```sh
./dev/f4b-pam-semantics.sh
```

Everything else in phase 5 tests Face's code. This tests the sentence the design
rests on, against the libpam that is **installed**: `success=1` is a jump, and
`pam.conf(5)`'s "the next N modules are skipped" is a sentence about the common
case rather than a specification of the edges. It builds throwaway services out
of `pam_exec`, `pam_permit` and `pam_deny` in the sandbox's copy of `/etc/pam.d`
and calls `pam_authenticate` through `ctypes` (`dev/pam-probe.py`), then reads
back both the result and which modules ran.

Five behaviours, each one a thing sudo must keep doing: a gate that skips jumps
over the verifier and lands on the password; a matched face ends the chain; a
face that does not match falls through; and a gate or a verifier that **cannot be
executed at all** is ignored rather than fatal — which is what `chmod 000` on a
helper is supposed to cost somebody.

The sixth is the hazard `pam_block_intact`'s position check exists for: a block
moved below the last `auth` line, so the gate's jump runs off the end of the
chain. On pam 1.7.2 the dispatcher carries the status the chain had already
reached — success stays success, failure stays failure — so it is survivable,
and **not** a way to turn a wrong password into an acceptance. The check stays
anyway: nothing in `pam.conf(5)` promises that, and this suite is what will say
so if an update changes it.

## G5 — the indicator and the sudo switch

```sh
./dev/g5-indicator-offscreen.sh
```

The real `Indicator.qml` and `SettingsView.qml` in a QML runtime, fed state
documents in exactly the shape `omarchy-face-verify` writes (`plan-merged.md
§2.6`). It reads the card's text off its properties rather than off a screen: the
gate's GUI half is "the card names the requesting program", which is a question
about a string, and a test that opened an overlay on somebody's display to answer
it would be a worse test.

Covered: the requester line in all three of its shapes (`sudo · pacman, from
foot`, `sudo` alone for `sudo -v`, and `sudo · from foot`), `Approved · Anna`
against `people.json`'s label, the 10 s stale filter, the 12 s safety timer,
`skipped` and `lock` drawing nothing, standing down while the recording card is
up, and the Settings switch calling exactly `sudo-on`/`sudo-off` with the pending
value snapping back when the verb answers.

Standing down is not the same as saying nothing: any process running as this
account can open a recording card over IPC, and somebody looking into the lens
for a countdown is somebody not reading anything else. So a `sudo` that lands
while the card is up hands its line to the card instead, which the suite checks
both ways — a real check reports, a `skipped` one does not interrupt.

Three things in it are asserted as *text* rather than exercised, because an
offscreen runtime has no compositor to ask: the built-in screen filter
(`/^(eDP|LVDS|DSI)/`), `WlrKeyboardFocus.None` and the empty input region. The
card on a real screen is checked by looking at it.

## F5 — the daemon, the client, and the Profiles gate

```sh
./dev/f5-daemon.sh              # omarchy-faced and omarchy-face-identity
./dev/f5-profiles-contract.sh   # THE PHASE-6 GATE: Profiles' bound-face `set`
```

Phase 6 adds the first thing in this project that **listens**: a socket in
`/run` any local process can connect to, answered by a root daemon that opens
the infrared camera. So `f5-daemon.sh` is written around the three properties
that make that safe rather than around the happy path —

- **peer credentials.** The socket is `0666` because "only this account" is not
  something a mode bit can say; `SO_PEERCRED` is. A connection whose uid is not
  the config account's is refused before the request is read, and costs no
  camera, no fork and no rate-limit slot. The sandbox cannot become a second
  uid, so the refusal is expressed the other way round: the config names an
  account whose uid is not the caller's, which is the same check answering the
  same way.
- **draining.** `Accept=no` means a connection nobody accepted stays pending and
  re-activates the unit; a loop of those puts the **socket** into `failed`,
  which any local user could do and only root could undo. Every exit path
  accepts what is waiting first — including SIGTERM, which is why the handler
  raises instead of exiting.
- **hangup.** A client that goes away takes `compare.py` and the camera lock
  with it inside 300 ms, which is what `plan-merged.md §2.5` promises Profiles.

systemd is not reachable from the sandbox, so `dev/socket-activate.py` plays it:
it holds the listening socket, hands it over on fd 3 with `LISTEN_FDS`, and
starts the daemon again for the next connection. That is what lets idle-exit and
re-activation be tested at all. `dev/socket-say.py` is the raw protocol client
for the cases the two shipped clients cannot express (a connection that says
nothing, one that hangs up mid-check).

`f5-profiles-contract.sh` is the gate, and it is the only suite here that runs
**somebody else's code**: the installed `graveklar.profiles`, unmodified,
switching into a profile with a bound face. Its two halves are Profiles' own
sentences — `set` with empty stdin opens the profile by face, and a SIGTERM
during the face wait exits 143 within ~100 ms leaving nothing behind — with the
camera and the journal checked from this side. A temporary `HOME` and stand-ins
for `omarchy`, `omarchy-shell` and `hyprctl` keep a real profile switch inside
the sandbox; nothing on the machine moves.

Both stub the engine, for the reason `f3` gives and one more: **this machine's
IR emitter is not driven**, so a real `compare.py` ends in `black_frames`
whoever is sitting in front of it. Everything about the protocol, the
refusals, the timing and Profiles' side of the contract is real; "howdy
recognised Anna" is the one sentence only a live run can say.

## Phase 6 GUI — the Test card

```sh
./dev/g5b-test-card-offscreen.sh
```

Numbered after `g5` rather than after the phase because it is the same
machinery: the Test card is the indicator's card with a different sentence in
it, and the indicator's `identity` states — built in phase 5 — finally have a
producer. It drives the real `Service.qml` through the same `testMatch(name)`
the popup calls, with the dev stub told which of the five contract exit codes to
answer with, and reads the card's text out of the service's own `state()`.

Three things it proves that are not about copy. The indicator **stands down**
for the card's own identity checks (the same check would otherwise be announced
twice) — but a **`sudo` that lands during a test still draws, and the card is
what gets out of the way**. That way round is the phase-6 review's MEDIUM: any
process running as this account can raise a Test card over IPC, so a blanket
suppression would be a way to choose a three-second window in which `sudo -n`
draws nothing on screen. And stopping a check really **signals** the helper —
the stub traps `TERM` and records it, because a helper that was merely
abandoned is a camera still held.

Unlike the other offscreen suites this one really does put a card on the screen
for a second: the card is a layer-shell window and the shipped file cannot be
instantiated without one. It takes no keyboard focus and its input region is the
card itself, so nothing is stolen and nothing else is covered.

## F0

`./dev/f0-verify.sh` is `plan-engine.md §2` as a runnable checklist, plus the
`.graveklar.face*` backup glob from `§10.3` that §2's list does not cover. Run
it before `install.sh`: its last checks are about the plugin folders, which
installing legitimately fills.

That extra glob is not pedantry. On this machine §2's own list passed while
`.graveklar.face.bak.20260912221457` still held the entire old plugin — the
backup `omarchy plugin remove` leaves behind for a plugin that is not a git
checkout (`omarchy-plugin-remove:105-115`).
