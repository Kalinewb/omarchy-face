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
| `omarchy-face-admin` | answers in the contract's shape, writes nothing outside the fixture directory; `enroll-session` is not scripted yet. Setup never installs the system half itself (it opens the README's terminal instructions). `install-engine` and `install-system` start the stand-in build below |
| `omarchy-face-lock` | answers `{ok}` and deliberately never touches the plugins folder. `OMARCHY_FACE_DEV_LOCK_ERROR=<code>` makes the next write verb fail, `OMARCHY_FACE_DEV_LOCK_ENABLED=1` makes `status` report the clone enabled, and every verb is appended to `verbs.log` as `lock:<verb>` — the Settings switch has to be *shown* to call `enable` before `lock-on` and `disable` after a declined prompt |
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

Fixtures: `fresh` (nothing installed), `three-people` (engine installed, sudo
on, an owner and two others) and `configured` (the finished machine — every row
`ok`, the lock screen on, three people; it is what `g7-remove-offscreen.sh` and
`g7-preview.sh` are written against).

Two markers the stubs drop in `$OMARCHY_FACE_DEV_STATE` are part of the same
idea and are git-ignored: `verbs.log` (every verb, in order) and `purged` (the
admin stub's `purge` writes it, and the status stub then answers with an empty
`removal` — a purged machine, read back through the read half rather than
through a second hand-written fixture).

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
| `system/omarchy-face-admin` | every privileged verb, behind `no.graveklar.face.owner`: the installs, the store and its permissions, the sudo wiring, the lock setting, and `purge`. |
| `system/omarchy-face-camera` | which V4L2 node is the infrared one. Runs as anybody, and the status script runs the plugin's own copy before anything is installed. |
| `system/omarchy-face-{gate,verify}` | phase 5: the two lines `sudo-on` puts in `/etc/pam.d/sudo`. The gate decides whether asking the camera is worth it (exit 0 = skip); the verifier is the only file in this project whose exit 0 authenticates somebody. |
| `system/omarchy-faced` | phase 6: the socket daemon, and the one listening thing in the project. It is the only root process that opens the camera for a caller holding no privilege, which is why peer credentials and draining are gates on it rather than details. |
| `system/omarchy-face-lock-verify` | phase 7: the socket client the lock wrapper runs. Two exit codes and nothing else — every reason for a no is the same no, because a lock screen is the one place where telling them apart is telling whoever is standing there. |
| `bin/omarchy-face-status` | the whole read half of the contract. |
| `bin/omarchy-face-lock` | phase 7: the only thing in this plugin allowed to write `~/.config/omarchy/plugins`, and it does so from exactly one verb (`stage`). |
| `lock/` | the wrapper **template** — two files, staged byte-for-byte into a separate `graveklar.face-lock` plugin folder. It holds no Omarchy code at all: a `Loader` on an absolute URL runs Omarchy's own lock `Service.qml`. Not scanned as a plugin where it sits, because the registry only looks one level deep (`PluginRegistry.qml` `scan_thirdparty`). |

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

## G5c — the island's geometry, as numbers

```sh
./dev/g5c-island-offscreen.sh
```

The indicator's shape (`Island.qml`): a bar flush with the top edge of the
screen, square at its top corners, rounded on its bottom two, with a concave
fillet beside each top corner that belongs to the background rather than to the
bar. Whether it looks fused to the edge is a judgement; whether it is *built*
right is arithmetic, and this does the arithmetic twice.

First against the shipped `Indicator.qml` with the real `Style` behind it: the
card is drawn for a second and a half on the built-in screen, and the suite
reads its bar rectangle, both radii and all four arc centres off the `Island`
— in the bar's own coordinates and the screen's — and checks that the top radii
are zero, that the bottom radius is a fifth of the height (a rounded rectangle,
not a capsule), that the fillets are 10 px, that each fillet centre lies one
radius outside its side and one radius below the edge (outside the bar, which is
the only place a circle tangent to both lines can be centred), and that the
entrance is the specified one: height over 350 ms, width from 50 ms over 300 ms,
on a damped spring (ζ = 0.72, one overshoot of about 4 %). It also polls for the
card from before the state file is read and records the first frame it exists
in: top edge at y = 0, non-zero size, fillets already present, corners already
a fifth of the height. The bar grows out of the edge; it never arrives from
anywhere else.

Then the compositor. Hyprland animates every layer surface as it maps — a fade
on stock Omarchy, a pop-in from 92 % about the centre on this machine's
looknfeel.lua — and the card's window is a fullscreen transparent surface that
exists only while there is something to show. Without a rule the whole window
pops in, and the bar inside it spawns in mid-air and flies to the edge while
every number in QML still says y = 0. `Service.qml` applies the same
`hl.layer_rule` Omarchy gives its own bar (`no_anim`) for the indicator's
namespace, with `hyprctl eval`, at start and after every `configreloaded`. The
suite checks that text, checks this Hyprland accepts the rule, and then proves
the effect on the real screen: `grim` grabs a 340×160 strip around the bar
before the card exists and at 0, 30, 60, 150 and 400 ms after its window comes
up. In every grab that has the bar in it, the first row of new black must be
row 0 and at least the seed width wide; a grab from before the compositor
mapped the window shows nothing and is noted rather than counted, and at least
one grab inside the first 150 ms has to show the bar, so the check cannot pass
by seeing nothing.

Then `Island.qml` on its own, rendered offscreen with `qml6` at exactly those
dimensions and sampled pixel by pixel: the bar's top row solid from corner to
corner (not a pill), each top corner's diagonal solid two pixels out and empty
five pixels out (a fillet, not a notch), the fillet centres empty, the bottom
corners empty, and the bar's first and last columns solid down the height of
the fillet (no seam where the separate items meet). `G5C_KEEP_PNG=/path` keeps
the render for a person who wants to look anyway.

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

## F6/G6 — the lock screen

```sh
./dev/f6-lock.sh              # the verbs, against a throwaway plugins folder
./dev/g6-lock-offscreen.sh    # the wrapper itself, and its two views
```

Phase 7 is the one phase whose failure mode is a **live desktop stranded behind a
lock screen nobody can answer**, so neither suite touches the session it runs in
and neither can:

- `f6-lock.sh` points `XDG_CONFIG_HOME`, `XDG_RUNTIME_DIR`, `XDG_STATE_HOME` and
  `HOME` at a temporary directory, and puts stand-ins ahead of `omarchy`,
  `omarchy-shell`, `omarchy-hyprland-session-locked`, `notify-send` and — the
  one that matters — **`setsid`**, so `sync`'s detached `omarchy restart shell`
  is recorded rather than run. There is no `--here` and there will not be.
- `g6-lock-offscreen.sh` runs a throwaway Quickshell instance at a temporary
  config directory and **refuses to start while the compositor holds a session
  lock** — because creating a second stock lock instance while Hyprland holds a
  lock this shell did not take is exactly the state the stock lock's own
  `checkStrandedLock` acts on (`plugins/lock/Service.qml:82-100`), and it would
  take the session lock from a throwaway process.

`g6` has two halves. The first loads the **shipped** `lock/Service.qml` against
the **real** `/usr/share/omarchy/shell/plugins/lock/Service.qml`: that is E1's
first run against the real thing (the earlier evidence was a synthetic stock that
imported no `qs.Commons`, no `PamContext` and no `WlSessionLock`), and it reports
`compat=ok` with all five public names found. A scratch copy of the real lock with
`pendingSessionLock` renamed reads `incompatible` and names it; a path that does
not exist reads `failed`.

The second half drives the wake rule against
`dev/qml-harness/fake-lock-service.qml`, because none of `plan-merged.md §3` can
be exercised against the real lock without locking this session. The monitor poll
and the face check are **properties** of the wrapper rather than literals, so the
harness hands it a `printf` of monitor JSON and a `bash` that waits and exits —
which is how "two wakes a second apart start one check" and "a stale result is
dropped" become ten-second tests with no camera. The fake is deliberately dumb:
it takes no session lock, draws nothing and authenticates nobody.

`f6` also carries the two "nothing was written" clauses of the gate, measured the
way the shell measures them: a real `inotifywait -m -r` over the throwaway
plugins folder across `sync` (when current), `enable` and `disable`. And it
carries both sides of §9.5 — every verb that writes refuses for a live locker
*and* for the compositor's flag, while `disable --stranded` (the §9.3a recovery)
refuses only for the first, because "Hyprland is locked" is exactly what a
stranded orphan looks like.

`g6` also drives the **real Face service** for the two lock duties that have no
view: a stand-in `omarchy-shell` that never answers is a wrapper that never
compiled, and the case waits out the service's own 30 s deadline to see it run
`disable --stranded`. A second case drops a `failed` status file in front of it
and asserts `notify-once` was called **once**, although the file is re-read every
two seconds — "one notification, never one per check".

**Enter** is the wrapper's second trigger, and its harder half to test: the key
never reaches QML the wrapper can see, so a Hyprland binding raises a `custom>>`
event while a lock is up. `g6` hands the wrapper a stand-in `evalCommand` that logs
`arm`/`disarm` instead of binding a real key, and a per-run event name, then raises
that event through the **real** compositor (`hl.dispatch(hl.dsp.event(...))`) —
so the name, `Quickshell.Hyprland`'s event parsing and the wrapper's guards are
all under test, and the wrapper this session runs never hears it. Two cases pin
the part that matters most: an Enter that submits a typed password starts no face
check, both while PAM is still checking and when PAM said no before the wrapper
looked. `lock-lines.qml` measures every line the wrapper writes against the real
lock font and the field's real room — the line this replaced was 360 px in 339.

`g9-enter-live.sh` is the part a suite cannot do: virtual keyboards do not fire
Hyprland bindings, so it registers the same binding unlocked and asks a person to
press Enter once.

`lock-on`/`lock-off` are tested in `f3-people-store.sh`, which is the suite with
a store and a derived lock set in it. They wire nothing: the assertion beside
them is that `/etc/pam.d` is byte-identical across both. The socket client the
wrapper runs, `omarchy-face-lock-verify`, is tested in `f5-daemon.sh` against the
sandboxed daemon — two exit codes, and a name on stdout only when there is one.

### What only a person at a locked screen can prove

Everything above is about code. These are about a laptop, and each one needs the
session actually locked — **with a way back in prepared first** (a root shell on
a TTY, or an ssh session from another device):

| | |
|---|---|
| the blank is 5 s | that Omarchy's `idleBlankTimer` really fires, and that a key press really flips `dpmsStatus` back |
| face opens the real lock | `finishUnlock()` on the REAL stock instance, with a real match through the real engine |
| the live swap | `enable`/`disable` on the running shell: no restart, no plugin reload, the popup stays open, `omarchy-shell lock status` keeps answering |
| Enter on the lock screen | lit screen: Enter on the empty field → *Looking for your face…* → opens. A typed wrong password + Enter → *Authentication failed*, and `journalctl --user -t quickshell` says "Enter submitted a password: no face check". After unlocking, `hyprctl binds -j \| jq '.[] \| select(.key=="Return" and .modmask==0)'` is empty |
| the resume line | close the lid, wait for suspend, open, Enter at once: a no within 15 s reads *Camera waking? Enter to retry* |
| the lid | close → suspend → open: which of `dpmsStatus` or `disabled` fires, if either. The README's wording is chosen from the answer |
| the stranded case | a broken staged wrapper present at a shell start while Hyprland holds the lock: a password field has to appear on its own within 30 s, with no TTY used |
| the **non**-drawing clone | the same run, read the other way: destroying a stranded clone that nobody is looking at must disturb nothing else — no other plugin disabled, no bar widget lost, `shell.json` otherwise untouched |
| a **drawing** clone under load | with face on the lock screen and the session locked, put artificial load on the shell's IPC (`for i in $(seq 200); do omarchy-shell -q shell ping & done`) and confirm `omarchy-shell lock status` still answers `secure` throughout. That is the margin `locker_settled`'s three probes are betting on; if it does not answer reliably under load, the retry count is not enough |

## F7/G7 — removal, the README and the preview

```sh
./dev/f7-purge.sh                # the purge order, its refusals, and the final step
./dev/g7-remove-offscreen.sh     # THE PHASE-8 GATE: the Remove view end to end
./dev/g7-preview.sh              # writes preview.png
```

`f1-round-trip.sh` already runs install → purge → the §10.3 checklist, so
`f7-purge.sh` does not repeat it for its own sake: it adds `purge` refusing with
exit 3 while the engine builds (and removing *nothing* when it does), a second
purge on a machine it has already been through, and the last three items of
§10.3 — the plugin folders, the `.graveklar.face*` backups and `shell.json` —
which `purge` never touches because they belong to the Remove view's final step.
That step is **read out of `RemoveView.qml`** rather than copied into the test,
and it is launched from a process whose whole group is then SIGKILLed, which is
what a plugins-folder reload does to the `Process` children of the popup it
destroys. `setsid -f` is what the work has to survive it with.

`g7-remove-offscreen.sh` runs the real `RemoveView.qml` against a **throwaway
plugins folder** with a stand-in `omarchy` in front of the real one, so the final
command really deletes a plugin folder, really calls `plugin remove --yes`, and
really clears the backup that leaves behind. The fake panel has a real `opened`,
so "the result is on screen before the reload closes the popup" is measured at
the moment the result appears — the view is asked whether the plugins folder has
been touched yet, and only then is the popup closed.

### preview.png

`g7-preview.sh` starts a **nested Hyprland with one headless output**, gives it
its own `HOME` holding only this checkout, runs the real Omarchy shell in it
against the `configured` fixture, opens the popup and photographs it with `grim`.
The crop is measured rather than guessed: the popup is shot closed and open, and
the bounding box of the pixels that changed is the card.

Two things in it are synthetic and both are deliberate. The **status document**
is the fixture, so that the shot does not depend on the state of whichever
machine takes it: a row only reads `ok` with howdy built, sudo wired, the lock
screen on and somebody enrolled. (An earlier version of this paragraph said the
development machine's IR emitter was not driven and nobody could be enrolled on
it at all. That was wrong: the emitter works, and this machine has a real person
enrolled from a real capture. The fixture stays for the reason above.) The
**display** is nested, because the session this runs in may be locked and its
plugin folder must not be written to. Everything else — the shell, the bar, the
theme, the QML, the fonts — is real, and `grim` is the same tool Omarchy's own
screenshots use.

## G8 — the post-ship fixes

```
./dev/g8-post-ship.sh
```

Four things a week of real use found, after the eight phases shipped. None of
them could have been caught by the phase gates: two are about a tenth of a second
on somebody's screen, and two are about what a view chooses *not* to say.

1. **A status read asked for while one is in flight was dropped.** The periodic
   30 s poll and the follow-up read a verb makes when it lands overlap often, and
   the one that lost was always the one that knew something. A Settings toggle
   shows `config.sudo` again the moment its pending value clears, so a dropped
   follow-up was a switch that visibly fell back to its old position and stayed
   there until the next tick. It is queued now, at most one deep.
2. **The popup returning from a recording card opened on the store as it was
   before the recording.** `FileView.reload()` is asynchronous — 110–145 ms
   measured on this machine, and `blockLoading` does not make it synchronous,
   only the initial load — so the first frames showed an appearance count short
   by the one just taken. The panel now starts the read and opens on its answer.
3. **The appearance picker could not say which appearances were already
   recorded**, and its button said "Again" whichever was chosen. Marks in the
   picker, and a button that names what it would do to the appearance the picker
   is on.
3b. **The People list said "0 appearances" about everybody.** A `Repeater` hands
   its delegate `modelData` through a QVariant: a nested array arrives with a
   correct `length` and with `Array.isArray()` answering **false**, so the guard
   in front of it threw away every appearance of every person. A rendering bug,
   not a staleness one — the document was right and the row drew it wrong. It was
   found by looking at `preview.png`, which is the argument for having a
   screenshot in the repository at all.
4. **Setup collapses.** An all-`ok` machine gets one line, a machine with nothing
   installed gets one button, and anything actionable brings the whole checklist
   back (`plan-gui.md §4a`).

The two timing cases are the interesting ones to run, because both are
reproducible only against a helper that is slow on purpose:

- the status stub here sleeps 600 ms, and **arms its own change from inside the
  read**: it decides its answer, then creates the marker, then sleeps. So the
  read that caused the change is the one read that cannot see it, with no sleep
  race between two processes deciding who got there first.
- the handoff case rewrites `people.json` by temp + rename with the popup closed
  — which is exactly what drops the panel's inotify watch — and then calls
  `openAt()`, the IPC handler's own body, and records the appearance count at the
  instant the popup opens.

Run it against a checkout with the fixes backed out and cases 1 and 2 fail: that
is the only evidence that it is testing anything.

## F0

`./dev/f0-verify.sh` is `plan-engine.md §2` as a runnable checklist, plus the
`.graveklar.face*` backup glob from `§10.3` that §2's list does not cover. Run
it before `install.sh`: its last checks are about the plugin folders, which
installing legitimately fills.

That extra glob is not pedantry. On this machine §2's own list passed while
`.graveklar.face.bak.20260912221457` still held the entire old plugin — the
backup `omarchy plugin remove` leaves behind for a plugin that is not a git
checkout (`omarchy-plugin-remove:105-115`).
