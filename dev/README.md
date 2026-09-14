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
| `omarchy-face-admin` | answers in the contract's shape, writes nothing; `enroll-session` is not scripted yet. Setup's **first install** also lands here in development (`Ask.firstInstallArgv`), so the `pkexec /bin/bash` form never runs against a fixture |
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

The default run is sandboxed with `unshare --map-root-user --mount`: uid 0 that
owns nothing, tmpfs over `/etc`, `/run`, `/usr/local` and polkit's actions
directory, and the checkout bound over the account's plugin folder so the update
path is tested against the code being written. Nothing outside the namespace is
written, and no password is needed. What the sandbox cannot do is talk to
systemd, so `systemctl --now` and `daemon-reload` come back as warnings; `--here`
is the run that proves the socket really starts.

## F0

`./dev/f0-verify.sh` is `plan-engine.md §2` as a runnable checklist, plus the
`.graveklar.face*` backup glob from `§10.3` that §2's list does not cover. Run
it before `install.sh`: its last checks are about the plugin folders, which
installing legitimately fills.

That extra glob is not pedantry. On this machine §2's own list passed while
`.graveklar.face.bak.20260912221457` still held the entire old plugin — the
backup `omarchy plugin remove` leaves behind for a plugin that is not a git
checkout (`omarchy-plugin-remove:105-115`).
