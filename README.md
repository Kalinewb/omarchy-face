# omarchy-face

Face authentication for Omarchy, using the infrared camera your laptop already
has. Unlocks `sudo` and polkit prompts; your password keeps working everywhere,
and is still the only thing that gets you past the lock screen, the login
screen, and anything arriving over SSH.

Built for **Omarchy 4.x**, which authenticates through its own Quickshell PAM
services rather than hyprlock. Older face-unlock installers for Omarchy patch
`/etc/pam.d/hyprlock`, a file that no longer exists on a 4.x install.

## Requirements

A real infrared sensor — a separate `/dev/video*` node that offers 8-bit
greyscale and nothing else. A colour webcam is not a substitute: it will happily
authenticate a photograph of you held up to the lens.

```bash
omarchy-hw-ir-camera --describe
# HP 5MP Camera: HP IR Camera	/dev/video2	/dev/v4l/by-path/pci-…-video-index0	400x400
```

Most laptops with Windows Hello have one, and it usually needs no coaxing — if
your IR emitter does need enabling, `linux-enable-ir-emitter` from the AUR is
the tool for that.

## Install

```bash
./install.sh                     # helpers into /usr/local/bin, entries into the Omarchy menu
omarchy-setup-security-face      # or: Setup > Security > Face ID
```

Setup installs the engine, pins the camera, walks you through enrollment,
**verifies that the enrollment actually matches you**, and only then edits any
PAM stack. If verification fails, nothing is wired up.

```bash
omarchy-face status              # engine, camera, enrollment, gate verdict, PAM state
omarchy-face test                # match against the live camera, with timings
omarchy-face enroll              # add another model (with glasses, in the dark, …)
omarchy-face disable             # stop PAM attempting face, keep the models
```

To undo:

```bash
omarchy-remove-security-face     # or: Remove > Security > Face ID
./uninstall.sh
```

## How it works

Two lines per PAM stack, in `/etc/pam.d/sudo` and `/etc/pam.d/polkit-1`:

```
auth  [success=1 default=ignore]  pam_exec.so quiet /usr/local/bin/omarchy-face-gate
auth  sufficient                  pam_exec.so quiet /usr/local/bin/omarchy-face-verify
```

The gate runs first and **succeeds when face should be skipped** — `success=1`
jumps over the line below it and PAM drops straight to the password prompt. That
inversion is deliberate and is the same trick Omarchy's own fingerprint setup
uses with `omarchy-hw-laptop-closed`. The gate skips when:

- face is disabled (`/etc/omarchy-face/disabled`)
- the account is root
- the session is remote (`PAM_RHOST`, `SSH_CONNECTION`)
- the lid is closed — otherwise every `sudo` in clamshell mode waits out the engine's timeout
- there is no IR camera, no engine, or nothing enrolled
- another process is holding the sensor, e.g. a video call
- **face already failed for this same authentication** (see below)

Only if none of those apply does `omarchy-face-verify` run, and its exit code is
the entire answer: `0` authenticates, anything else does not.

### One camera attempt per authentication

`sudo` re-runs the entire auth stack for every password retry. Left alone, that
means a fresh eight-second camera attempt before *each* retry: mistype your
password once with `passwd_tries=10` and you can wait more than a minute, with
the prompt frozen between tries.

So a failed attempt is recorded, and the gate skips face for the rest of that
authentication. The retries then go straight to the password prompt.

The key is the parent process, not a timer. sudo's retries all come from one
process, and the next invocation is a different one — so a fresh `sudo` gets a
clean attempt immediately, even a second later. A time-based cooldown would have
refused that perfectly reasonable second try while still being wrong about what
it was actually preventing.

The key includes the parent's start time as well as its PID, because the kernel
recycles PIDs and a recycled one must not inherit a stale marker. Markers live
in `/run/omarchy-face/attempts`, are swept after ten minutes in case PAM is
killed mid-stack, and are removed on a successful match.

Measured on this machine: eight password retries in one `sudo`, one camera
attempt.

### Engines

The matcher is behind a one-file adapter. `omarchy-face-engine-howdy` ships;
adding `omarchy-face-engine-<name>` next to it and running
`omarchy-face engine <name>` is the whole swap procedure. Adapters answer:
`describe`, `installed`, `install`, `uninstall`, `configure`, `get-device`,
`set-device`, `enroll`, `list`, `remove`, `clear`, `count-models`, `verify`,
`verify-verbose`.

The howdy adapter calls `compare.py` directly rather than using howdy's shipped
`pam.py`, which needs `pam-python` — a Python 2 C module that no longer builds
on current Arch. Its exit codes are the contract: `0` match, `10` no models,
`11` timeout, `12` abort, `13` too dark.

### Why the installer builds dlib itself

`yay -S howdy` pulls `python-dlib`, which is a **split package**: one PKGBUILD
produces a CPU variant built with `DLIB_USE_CUDA=OFF` and a separate CUDA
variant. Only the CUDA half needs `cuda` and `cudnn` — about **2.7 GB of
downloads and 6 GB installed** — and howdy never touches it. It runs dlib's HOG
detector on the CPU, because `use_cnn` is off by default and the CNN model wants
a GPU to be worth using.

So `omarchy-face-engine-howdy install` fetches the build files, sets
`_build_cuda=0`, and builds only the CPU package. If upstream ever renames that
flag, the edit is skipped rather than guessed at and the build proceeds the
expensive way — noisily, not silently.

One default is changed from howdy's stock config, on purpose:

- `capture_failed` and `capture_successful` **off**. Upstream photographs every
  authentication attempt and writes it under `/usr/lib` with no rotation.

The recorder is left on stock `opencv`. howdy's config warns it can struggle
with greyscale, but it was measured driving this IR sensor correctly, and the
`ffmpeg` alternative needs the `python-ffmpeg-python` module from the AUR. If
frames do come back black on some other camera, `omarchy-face test` says "every
frame was too dark" and that is the knob to reach for.

Worth knowing when probing any IR sensor: **the first frame after opening the
device is near-black** because the emitter takes a moment to fire. On this
laptop frame one reads a mean level of 7 and frame twenty reads 85. Anything
testing the camera has to read a run of frames, or it will conclude the sensor
is broken.

The match threshold (`certainty`) is left at howdy's stock value. Loosening it is
the one knob that trades security directly for convenience, and it should be a
decision you make rather than a default you inherit.

## Security

**What this is.** A convenience factor that stops a shoulder-surfer and saves
you typing a password thirty times a day.

**What it is not.** Windows Hello ESS. There is no secure enclave and no
attestation: the models and the matching code sit on the root filesystem, and
anyone who is already root can change what "your face" means. It is a
second-rate factor by construction, which is why it is wired into `sudo` and
polkit only, never into the lock screen, login, or `su`.

It will not stop someone with an IR-capable photograph of you.

Concretely:

- The PAM helpers must be root-owned and writable by nobody else. `pam_exec`
  runs them as root, so a group-writable helper is a local root exploit. Setup
  checks this and refuses to wire anything up if it fails.
- `pam_exec` hands those helpers an environment chosen by an unprivileged user,
  so they pin `PATH`, unset `IFS`/`BASH_ENV`, and never `source` anything.
- `/etc/omarchy-face/config` is read with `sed`, never `source`d. A config format
  that can execute code eventually executes someone else's.
- Face models are root-owned and mode `0600`.
- Everything fails closed. A bug in here should cost you a password prompt.

**Keep a root shell open on another TTY while editing PAM.** A broken `auth`
stack means no `sudo`, and the way out is a TTY that is already authenticated.

## UI state

Every authentication publishes its state to `/run/omarchy-face/state.json`
(`0644`, written and renamed atomically, root-writable only):

```json
{"state":"start","detail":"","user":"alice","service":"sudo","at":1757700000000}
```

`state` is one of `start`, `matched`, `failed`, `skipped`. `detail` is free text
— an engine exit code, a gate reason — and is never parsed for control flow.
This exists for the shell overlay in the roadmap below; nothing reads it yet, and
publishing costs one file write per authentication.

## The panel

`omarchy-shell shell summon graveklar.face '{}'` — or **Setup > Security > Face
Models** — opens a security panel. It has two views.

**Overview** reports what is actually protecting the machine: whether face
unlock is wired into sudo and polkit and how many models are enrolled, whether
a fingerprint reader exists and is enrolled, whether a security key is set up,
whether sshd is listening, how many failed logins are on record, the idle lock
timeout, and whether passwordless sudo is on. All of it comes from
`omarchy-security-probe`, which reads only what the session owner may already
read — no privilege escalation to render a status page, because a panel that
demands a password before it will tell you anything is a panel nobody opens.
"Unknown" is a distinct state from "fine"; reporting something as healthy when
it could not be determined is the one mistake this must not make.

The camera is not opened for the overview. The webcam light has no business
coming on for someone reading a status page.

**Face models** is the guided enrolment flow: a mirrored live preview from the
RGB camera with an oval framing guide, a label for the model being recorded, a
three-second countdown, and then a verdict. The verdict is measured, not
assumed — enrolment is followed immediately by a verification, and the match
certainty is compared against the configured threshold. A model that only just
scrapes under is reported as weak and worth redoing, because one that clears by
a hair works at this desk, in this light, once.

Enrolment goes through `omarchy-face-admin` under the polkit action
`no.graveklar.face.admin` (`auth_self_keep`, so recording three models for
three pairs of glasses is one prompt rather than three). That helper refuses to
manage models for root, and refuses to manage them for anyone but the calling
user — `PKEXEC_UID` decides, not the argument.

## Named identities

PAM answers one question: is this the account owner. Sometimes the question is
"is this a particular other person" — a profile that should open for a partner,
say. PAM cannot express that; there is one Unix user and face unlock proves you
are them.

So identities exist alongside PAM, not inside it:

```bash
omarchy-face-identity list                 # names only
omarchy-face-identity verify partner       # exit 0 if that face is present
```

Enrolling one goes through `omarchy-face-admin enroll-identity`, behind the
owner's polkit prompt — deciding *who else* may open something is the machine
owner's call, and the other person cannot authorise as them. Verification, by
contrast, must work with no prompt at all, or the feature is impossible: the
person being checked for cannot authenticate as you. That is its own polkit
action (`no.graveklar.face.verify`, `allow_active: yes`) pointing at a helper
that can *only* verify and list names — it cannot enrol, delete, or emit an
encoding.

Identity names are namespaced on disk as `identity-<name>.dat`, so an identity
called `alice` can never shadow the model store PAM authenticates the real
account against.

**Understand what the no-prompt verifier grants**: any process running as you
can ask whether a given enrolled face is in front of the camera, and turn the IR
emitter on asking. It returns a boolean and nothing else. That is acceptable for
gating things that are not security boundaries — a profile switch, a UI state —
and it must never become the basis for one.

## The indicator

`./install.sh` also installs a small Quickshell plugin, `graveklar.face`. While
the engine is looking it shows a spinner captioned "Look at the camera"; on a
match the ring closes into a full circle with a check and "Unlocked".

It sits at the top of the built-in display rather than the middle, directly
below the webcam: looking at the prompt then points your face at the lens,
which is the one thing you have to get right. It is deliberately not shown on
external monitors, where it would aim your gaze away from the camera.

The overlay takes no keyboard focus and has an empty input region, so clicks and
keystrokes pass straight through to whatever is underneath — a password prompt
you are already typing into is never interrupted. It reads
`/run/omarchy-face/state.json` and plays no part in authentication: PAM has
already decided by the time a state is written, so the indicator being late,
wrong, or absent cannot affect whether you get in.

Two notes for anyone editing it:

- It is `keepLoaded`, so `omarchy plugin` rescans will not pick up changes to
  `Service.qml`. Run `omarchy restart shell`.
- Third-party plugins are inert until they appear in `shell.json`. A valid
  manifest in the plugins directory does nothing on its own; `omarchy plugin
  enable graveklar.face` is what mounts it.

Its card is forced opaque. The theme's polkit surface token is semi-transparent
because Hyprland blurs that dialog through a layer rule matched on its
namespace, and this overlay has no such rule — left translucent, whatever is
behind it reads straight through the text. Adding `omarchy-face-indicator` to
the blur list in `~/.config/hypr/looknfeel.lua` is the nicer fix if you want it.

## Roadmap

- **Lock screen.** Omarchy 4's lock plugin hardcodes exactly two PAM contexts,
  password and fingerprint, and a third-party plugin cannot add a third. The
  options are forking `omarchy.lock` or upstreaming pluggable auth methods.
- **Live preview.** Only one process can stream from a given sensor at a time,
  so an overlay cannot show live IR while the engine is matching — but it does
  not need to. A laptop with Windows Hello has *two* cameras, and they are
  separate V4L2 devices: the IR sensor authenticates while the ordinary RGB
  camera feeds the preview. Measured on an HP OmniBook: RGB capturing 640x480
  and IR streaming at full brightness, concurrently, over one USB 2.0 device.
  No broker and no `v4l2loopback` required.
- **Security panel.** A Quickshell panel over these scripts plus Omarchy's
  existing fingerprint/FIDO2/sshd setup, with faillock state and lock timeouts.

### The shell plugin, specified

Face unlock with no visible feedback is the wrong experience: `sudo` simply
pauses for up to eight seconds while a camera you cannot see decides whether it
knows you. The plugin exists to fix that, and it has three jobs.

**1. An authentication popup.** Appears the moment `state.json` turns `start`,
telling you to look at the camera, and plays an unlock animation on `matched`.
It must appear fast — the state file is written before the engine opens the
device, so an inotify watch has the whole camera-open window (~840ms measured)
to get on screen.

**2. A visually guided setup.** Live RGB preview with overlays that position
your face, capture on cue, then report whether the model is actually any good
and offer a retry when it is not. "Good enough" is measurable: a verification
immediately after enrollment yields a certainty against the threshold, and a
model that only just clears it should be re-taken rather than kept.

**3. Guided multi-model enrollment.** Glasses are the main reason face unlock
fails in practice — people take them off, or swap to reading glasses, and an
IR sensor sees a very different face each time. howdy matches against every
enrolled model and picks the best, so the answer is one model per state. The
setup flow should walk through them by name (bare, everyday, reading) rather
than capturing one anonymous model and hoping. Past three models matching slows
measurably, so the flow should stop offering more.

What the backend already provides for this:

- `omarchy-hw-ir-camera --preview` — the ordinary RGB camera to show on screen,
  which is a *different device* from the IR sensor doing the authenticating.
  The IR sensor can only be streamed by one process at a time and the engine
  owns it during a match; the RGB camera is free throughout.
- `/run/omarchy-face/state.json` — `start` / `matched` / `failed` / `skipped`,
  with the PAM service that triggered it.
- `omarchy-face enroll [label]` — non-interactive when there is no terminal, and
  takes a label, so named models can be captured from a GUI.
- Every verb answers with an exit code rather than only prose.

What it still needs:

- Enrollment progress on the state channel, not just authentication.
- A machine-readable mode (`--json`) for status and test, including the
  certainty and threshold so "not good enough" is a number and not a guess.
- A polkit action, so the panel can run enrollment as root without shelling out
  to a terminal.

## Credits

[howdy](https://github.com/boltgolt/howdy) does the actual face recognition.
[cld3d/omarchy-faceid](https://github.com/cld3d/omarchy-faceid) covered the same
ground first, against an earlier Omarchy.
