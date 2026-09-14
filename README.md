# Face Unlock

Look at your laptop instead of typing your password into `sudo` — for you, and
for the people you choose.

> **Being rewritten.** This branch is a ground-up rewrite against a fresh plan,
> built phase by phase, and **it does not authenticate anything yet**. Nothing
> in it edits a PAM stack, installs a helper or opens a camera. The plugin
> currently draws a bar button and a popup with the shell of its views.
>
> The README this file will become — what it is for, how it works, the limits,
> what to do when something goes wrong, and the contract with the Profiles
> plugin — is written in the last phase, against the GUI that actually shipped.

## What is here now

| | |
|---|---|
| `manifest.json` | `bar-widget` + `service`, nothing else |
| `FacePanel.qml` | the bar button, the view stack, the status document |
| `Service.qml` | the `keepLoaded` service: inert, and the home of everything that must outlive a plugin reload |
| `SetupView.qml` … `RemoveView.qml` | one view each |
| `common/Ask.qml` | every call to the engine: `ask()` and `stream()`, and what the exit codes mean |
| `dev/` | stub engine, fixtures, the old-install checklist, development notes |

Installing the plugin is `./install.sh`; see `dev/README.md`. The system half —
helpers, the verification daemon, the polkit policy, the face engine — is
installed from inside the GUI in a later phase, and is not in this repo yet.

## Licence

MIT.
