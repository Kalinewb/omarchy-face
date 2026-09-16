# Face ID

Look at your laptop instead of typing your password into `sudo` — for you, and for the
people you choose.

## What it is for

**Thirty passwords a day.** Updates, package installs, a file in `/etc`. With Face ID,
`sudo` shows a small card under the camera naming what asked, you glance at it, and the
command runs. Your password still works every time, and it is still what gets you past a
login screen or an SSH session.

**A family machine.** You and your partner both look after this laptop, so both of your
faces can approve `sudo`. Your kid is a person too — not for `sudo`, but so the Profiles
plugin can open their own desk when they sit down. Who can do what is a switch per
person, and only your password changes it.

**Glasses on, glasses off.** Every person has up to three appearances — no glasses,
everyday glasses, reading glasses — because an infrared camera sees those as different
faces.

**The lock screen, if you want it.** Off by default. Turn it on, lock, walk away; when
you come back, touch a key and look at the screen. The password field says
*Looking for your face…* while it checks, and tells you if it did not recognise you — so
you can see it working and decide whether to wait or just type. It follows Omarchy's own
lock screen as it updates, and if an update changes too much it steps aside, tells you,
and your password works as always.

![Face ID's People view on a finished machine](preview.png)

## What it is, and what it is not

**It is a convenience.** It saves typing and stops someone reading your password over
your shoulder. It is not a security upgrade.

**A face is always on.** A password has to be typed and a fingerprint has to be touched.
Your face is simply there. Any program running as you can start `sudo`, and if you are
in front of the camera your face can answer before you have read what asked. The card
names the command and what started it so you can notice a request you did not make —
noticing is all it can do. Such a program could already wait for you to type your
password; face unlock removes the wait, not the permission.

**The lock screen wakes to anything.** A key, a bump of the mouse — or a program running
as you — wakes the screen and starts one face check. If you are sitting nearby, it can
open.

**Giving someone Sudo gives them root.** Everyone on this laptop uses the same account.
When Anna's face approves `sudo`, Anna runs commands as the machine's owner. The switch
says so.

**Sudo keeps a better record than the lock screen.** Every `sudo` answered by a face is
written to the system journal *by root* — whose face it was, which appearance matched, the
command that asked and what it was started from — and so is every attempt that failed. The
lock screen is written by root too, but it is a smaller claim: the daemon records
`lock verify matched: <name>` when it recognises somebody, and since it also records the
reason when it does not, a run of refusals can be read back afterwards.

What root cannot say is that the screen opened. The daemon only ever learns that a face
matched; what was done with that answer is not its business and it never finds out. The
line saying the lock was opened is written by your own session — so that part, and only
that part, a program running as you could still fake or remove.

**Names are visible on this computer.** The list of people and their display names can be
read by every account on the machine. Faces cannot. So is the record of what was last
checked and who it matched — any account can ask "is Anna at the camera right now?" and
get an answer, and can read who last approved what.

**It is not Windows Hello.** There is no secure chip. The face data and the matching code
live on this computer's disk, and anyone with root can change what "your face" means.

**A good infrared photograph of you can fool it.** It refuses to run without an infrared
camera, because a normal webcam accepts a printed picture — but an infrared image of a
face is not impossible to make.

**Your password is never replaced.** If face does not recognise you in a few seconds, or
the lid is closed, or a call is using the camera, the password prompt appears as always.

## How it works

**The engine is howdy.** Face builds it for you: howdy and a CPU-only dlib, compiled from
the Arch User Repository at the two revisions this version of Face was tested against, and
installed with `pacman`. It takes several minutes and about half a gigabyte of disk while
it runs, and it keeps going if you close the panel or restart the shell.

**Face's own half is small and readable:** seven scripts in `/usr/local/bin`, two systemd
units, one polkit action, one configuration file. They are installed from this plugin
folder, under one password dialog, and removed the same way.

**`sudo`** is wired by adding one marked four-line block to `/etc/pam.d/sudo`. Nothing
else in that file is touched, turning the switch off takes the block back out, and the
file goes back byte for byte. There is at most one face attempt per `sudo` call — a
password retry does not re-open the camera — and at most six attempts a minute across
separate calls.

**The lock screen** is a second plugin, `graveklar.face-lock`, that holds no copy of
Omarchy's lock screen: it loads *Omarchy's own* lock code and adds a face check alongside
the password field and the fingerprint reader. It draws nothing of its own — nothing may
draw over a session-lock surface, and a plugin that tried would be defeating the one
guarantee a lock screen makes. What it does instead is write a line into Omarchy's own
password field, the same place Omarchy puts *Authentication failed*: *Looking for your
face…* while the camera is open, and *Face not recognised — use your password.* when it
was not you. Omarchy clears it the moment you start typing. If an Omarchy update renames
that field the line stops and face unlock carries on without it, never the other way
round. When Omarchy updates its lock screen, the new
one simply runs. If an update changes the names that loader depends on, face turns itself
off there and says why, and the lock screen keeps working exactly as Omarchy ships it.
Face is tried when the screen **wakes**, never when you lock it — otherwise locking the
machine while you are still sitting in front of it would undo itself.

**"Who is at the camera?"** is answered by a small root daemon on a socket in `/run`, for
callers that hold no privilege of their own: the Profiles plugin and the lock screen
loader. The socket is reachable by every local process on purpose; the daemon asks the
kernel who is on the other end and answers only this account. Nothing it says
authenticates anybody — `sudo` never goes near it.

**What is stored where.** The face data lives in howdy's own model files, readable only by
root, and it is not a photograph: it is a list of numbers, and no picture of you is kept.
Display names and appearance labels live in `/var/lib/omarchy-face/people.json`, which
every account on the machine can read.

## Installing it

```sh
omarchy plugin add https://github.com/Kalinewb/omarchy-face.git --enable
```

A face icon appears in the bar. Click it and work down Setup:

1. **Install Face's system files** — one password dialog. It is the only one that says it
   wants to run `/bin/bash` as the super user, because Face's own helpers do not exist yet
   to ask with their own message; the panel warns you before the dialog appears.
2. **Build the face engine** — the howdy and dlib build above.
3. **Record your face** — People → Add person. The first person recorded on the machine is
   its owner.
4. **Give that person Sudo, or Lock screen, or both** — Person → the switches. This says
   *who may*; on its own it changes nothing.
5. **Settings → Face for sudo**, and **Lock screen** if you want it. This is the other
   half, and it is the one that wires the machine: until it is on, no face is tried
   anywhere, however many people have the permission.

Both halves are needed, and that is deliberate rather than a nuisance: the per-person
switch is a list of names, and the Settings switch is the one that edits
`/etc/pam.d/sudo`. Each screen says when the other is missing — Settings will not turn on
before somebody has the permission, and the Person page says when the machine-wide switch
is off.

You need an infrared camera (Face refuses to work without one), and an account that can
already administer this machine — Face never grants more than the owner's password already
grants.

## The views

| | |
|---|---|
| **Setup** | one row per thing that has to be true, with the button that repairs it where a button can |
| **People** | who this machine knows, how many faces can approve `sudo`, and Add person |
| **Person** | their appearances, their Sudo and Lock screen switches, a **Test** button that asks "does it recognise you now?" and unlocks nothing, and Remove |
| **Settings** | the two places a face is accepted, why the lock screen is or is not active, and the way out |
| **Remove** | what would be taken off this machine, and the button that does it |

Every change to who Face knows, and to where a face is accepted, asks for the owner's
password: a face can never grant itself Sudo, because Face is deliberately not part of the
password dialog's own stack.

## If something goes wrong

**The lock screen does not react to your face.** Take your hands off it first. The check
starts when the screen **wakes**, so the screen has to go dark before there is anything to
wake: leave it alone for five seconds and let it black out. A key pressed while it is
still lit does not start a check — it puts those five seconds back to the beginning, so
tapping away at a lit lock screen is the one reliable way to never see a face check at
all. Once it is dark, tap a key and look at the camera: the password field says
*Looking for your face…*, the infrared light comes on, and the screen opens about three
seconds later. If that line never appears, no check was started, and the reason is the
paragraph above rather than your face.

Your password works the whole time, and it is quicker than the check — so if you type it
straight away it wins, and the face result arrives too late and is thrown away. That is
not a fault, and with the line on screen you can now see it happen and wait a moment
instead. If the lid was closed, the camera was closed with it: open it and press a key.

**You want to know what it actually did.** Every face check for the lock screen is
recorded by Face's root daemon, match or no, with the reason when it says no:

```sh
journalctl -t omarchy-face --since -10min
```

`lock verify matched: <name>` is a face it recognised. A line saying no gives the engine's
own reason — gave up, too dark, timed out. Nothing at all means no check was ever started,
which sends you back to the blanking rule above.

**The lock screen came back looking like Omarchy's own.** That is on purpose. If Face's
copy of the lock screen cannot run — after an Omarchy update, or a bad Face update — Face
steps aside within half a minute and Omarchy's lock screen takes over, with a notification
saying why. Nothing is lost: your password and fingerprint are unchanged, and Face ID →
Settings shows the reason.

**You are looking at a locked screen with nothing on it.** Give it thirty seconds without
touching anything: if Face's lock screen failed to start, the shell notices, hands the
screen back to Omarchy's own lock, and a password box appears by itself. If after a minute
there is still no password box, switch to a text console (Ctrl+Alt+F2), log in, and run
`omarchy restart shell` from there.

## For the Profiles plugin

Two calls, and they are the whole contract:

```sh
omarchy-face-identity list            # the names Face knows, one per line
omarchy-face-identity verify <name>   # exit 0 = that person is at the camera
```

Any non-zero exit means "not verified". Any person can be bound to a profile; they do not
need Sudo. Names never change, so a binding never silently retargets somebody else.

## Removing it

**Settings → Remove Face ID from this machine.** It lists what would go, asks for your
password once, removes Face's system files, the people, the PAM lines, the daemon and the
engine — and then, as its last step, deletes both plugin folders, which is what closes the
panel and takes the button off the bar. There is a tick for keeping howdy and dlib
installed if you expect to come back.

Removing the plugin any other way leaves the system half working: face still answers
`sudo`, nothing dangles, and nothing is lost — but to take that half off as well, install
the plugin again and use Remove.

## Licence

MIT.
