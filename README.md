# Face Unlock

Look at your laptop instead of typing your password into `sudo` — for you, and
for the people you choose.

> **Being rewritten.** This branch is a ground-up rewrite against a fresh plan,
> built phase by phase. Setup can install Face's system files and take them off
> again, and build the face engine: howdy and a CPU-only dlib, compiled **from
> the Arch User Repository** — at two pinned revisions, by a user systemd invents
> for the job, and installed with `pacman`, which runs a package's install
> scriptlet as root — in a unit that survives the popup being closed.
>
> Faces can be recorded: People and Person, one owner prompt per recording
> session, up to three appearances each, per-person Sudo and Lock screen
> permissions. Display names are world-readable in
> `/var/lib/omarchy-face/people.json`; the faces themselves are not, and never
> leave root's files.
>
> **`sudo` can now be answered by a face.** Settings → *Face for sudo* adds four
> marked lines to `/etc/pam.d/sudo` and takes them out again; nothing else in that
> file is touched, and turning the switch off is what makes the check stop,
> whether or not the lines can be removed.
>
> **The lock screen can now be opened by a face, and it is still Omarchy's lock
> screen.** Face adds no lock screen of its own: a second plugin holds nothing
> but a loader that runs *Omarchy's own* lock code and adds a face check beside
> the password field and the fingerprint reader. When Omarchy changes its lock
> screen, the new one simply runs; if it changes the names the loader depends on,
> face turns itself off there, says so, and the lock screen keeps working exactly
> as Omarchy ships it. **Face acts when you WAKE the screen, never when you lock
> it** — lock, walk away, come back, touch a key and look at the camera. If you
> lock and touch a key straight away the screen never went dark, so face does not
> try and the password field works as always. The limit that comes with that: a
> bump of the mouse wakes the screen, and so can a program running as you, so the
> wake rule makes face *predictable*, not *safe*. It is off until you turn it on
> in Settings, and turning it off needs your password.
>
> **Other programs can now ask "who is at the camera?"** A root daemon answers
> that question over a socket in `/run`, for callers that hold no privilege of
> their own — the Profiles plugin, which can open a profile with a bound face
> instead of its password, and the lock screen loader above. The socket is
> reachable by every local process on purpose; the daemon
> asks the kernel who is on the other end and answers **only** this account.
> Nothing it says authenticates anybody: `sudo` never goes near it, and the worst
> a wrong answer can cost is a profile that opens or a lock screen that does not.
> Each person's page has a **Test** button that asks the same question and says
> what came back; nothing is unlocked by it, and if something asks for root
> while a test is on screen, the test card is the one that gets out of the way.
>
> **What the card on screen is, and is not.** When something asks for root, a card
> appears under the camera saying a check is happening and naming what asked.
> Treat it as *a check is happening*, not as proof of who asked: the command comes
> from `sudo`'s own argument list, but the "from" part is a process name any
> program running as you can set to anything it likes. It is there so that a
> prompt you did not expect is visible, not as a thing to authorise against.
>
> The README this file will become — what it is for, how it works, the limits,
> what to do when something goes wrong, and the contract with the Profiles
> plugin — is written in the last phase, against the GUI that actually shipped.

## What is here now

| | |
|---|---|
| `manifest.json` | `bar-widget` + `service`, nothing else |
| `FacePanel.qml` | the bar button, its five states, the view stack, the status document |
| `Service.qml` | the `keepLoaded` service: the recording card, the indicator, and the home of everything that must outlive a plugin reload |
| `SetupView.qml` … `RemoveView.qml` | one view each |
| `RecordSession.qml`, `RecordCard.qml` | one `enroll-session`: the state machine, and the card on screen |
| `Indicator.qml` | the card that appears while a face is being checked, and what asked |
| `TestCard.qml` | "does it recognise Anna now?" — one `omarchy-face-identity verify`, and what it answered |
| `common/Ask.qml` | every call to the engine: `ask()` and `stream()`, and what the exit codes mean |
| `common/names.js` | the name Profiles binds to, derived from the display name |
| `bin/omarchy-face-status` | the read half of the contract: one JSON document, no privilege, always exit 0 |
| `system/` | what gets installed as root — seven helpers, two units, the polkit action, and the installer the owner's password approves |
| `dev/` | stub engine, fixtures, the old-install checklist, the install → purge gate, development notes |

Installing the plugin is `./install.sh`; see `dev/README.md`. The system half is
installed **from inside the GUI**, under one password prompt, and removed the
same way — nothing in this repo needs `sudo` to develop or to test.

## Licence

MIT.
