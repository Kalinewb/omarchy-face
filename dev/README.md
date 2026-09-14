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
| `omarchy-face-identity` | `list` from the fixture; `verify` always exits 3, unavailable |

With `OMARCHY_FACE_DEV_BIN` set, the GUI takes every helper from that directory
and drops `pkexec` (`plan-gui.md §2.1`). It grants nothing: a stub running as
the user cannot write root-owned state.

`OMARCHY_FACE_DEV_STATE` does the same for the two files the panel watches
directly (`people.json`, `install.json`), which on a real machine live under
root-owned paths a stub cannot write. Point it at a fixture directory.

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
| `system/omarchy-face-{gate,verify,lock-verify}`, `system/omarchy-faced` | phases 5 to 7. They ship in their safe state — skip, never authenticate, answer nothing — because the `system` row installs and compares all seven helpers as a set. |
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

## F0

`./dev/f0-verify.sh` is `plan-engine.md §2` as a runnable checklist, plus the
`.graveklar.face*` backup glob from `§10.3` that §2's list does not cover. Run
it before `install.sh`: its last checks are about the plugin folders, which
installing legitimately fills.

That extra glob is not pedantry. On this machine §2's own list passed while
`.graveklar.face.bak.20260912221457` still held the entire old plugin — the
backup `omarchy plugin remove` leaves behind for a plugin that is not a git
checkout (`omarchy-plugin-remove:105-115`).
