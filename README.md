# Face Unlock

Look at your laptop instead of typing your password into `sudo` — for you, and
for the people you choose.

> **Being rewritten.** This branch is a ground-up rewrite against a fresh plan,
> built phase by phase, and **it does not authenticate anything yet**. No PAM
> stack is edited, no camera is opened, and no face is recorded. Setup can now
> install Face's system files and take them off again, and build the face
> engine: howdy and a CPU-only dlib, compiled **from the Arch User Repository**
> — at two pinned revisions, by a user systemd invents for the job, and
> installed with `pacman`, which runs a package's install scriptlet as root — in
> a unit that survives the popup being closed. The helpers it installs
> are in their safe state — the sudo gate always skips, the verifier never
> authenticates, and the daemon answers nothing.
>
> The README this file will become — what it is for, how it works, the limits,
> what to do when something goes wrong, and the contract with the Profiles
> plugin — is written in the last phase, against the GUI that actually shipped.

## What is here now

| | |
|---|---|
| `manifest.json` | `bar-widget` + `service`, nothing else |
| `FacePanel.qml` | the bar button, its five states, the view stack, the status document |
| `Service.qml` | the `keepLoaded` service: inert, and the home of everything that must outlive a plugin reload |
| `SetupView.qml` … `RemoveView.qml` | one view each |
| `common/Ask.qml` | every call to the engine: `ask()` and `stream()`, and what the exit codes mean |
| `bin/omarchy-face-status` | the read half of the contract: one JSON document, no privilege, always exit 0 |
| `system/` | what gets installed as root — seven helpers, two units, the polkit action, and the installer the owner's password approves |
| `dev/` | stub engine, fixtures, the old-install checklist, the install → purge gate, development notes |

Installing the plugin is `./install.sh`; see `dev/README.md`. The system half is
installed **from inside the GUI**, under one password prompt, and removed the
same way — nothing in this repo needs `sudo` to develop or to test.

## Licence

MIT.
