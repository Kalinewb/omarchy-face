# SR1 notes: what a security reviewer must check in Phase 2 of the enrolment sweep

Written by the author of the Phase 2 diff against `plan-face-enroll.md` (Round 5, section 6, the SR1 list of
ten items), so the reviewer does not have to find the new surface. Everything below is in
`system/omarchy-face-admin` (the only privileged file this phase changes besides the pins).
"Root side" means code that runs under `pkexec ... enroll-session`; "user side" is the GUI, which this phase does not touch.

How to read the "tested" column: `e0` is `dev/e0-pose.py` (pure functions, no camera), `e1` is
`dev/e1-enrol-sweep.sh` (the real parent and the real child, a fake camera and a fake dlib, in a private
user namespace), `f3` is `dev/f3-people-store.sh`. Nothing here was run against a real camera, a real dlib, pkexec
or polkit; none of those can be reached from the sandbox.

## What is new, and where it lives

| New | Where | Side |
|---|---|---|
| verbs `sweep`, `finish`, `abort` inside `enroll-session` (and `trial`, refused until Phase 5) | `cmd_enroll_session` | root |
| `set-limits <name> <lock> <sudo>` (owner action, like `set-permission`) | `cmd_set_limits`, the `set-limits)` case | root |
| `SWEEP_PY` capture half: a child program that holds the IR camera for one lap | below `# ==== THE CAPTURE HALF` | root, child |
| the sequencer (pure): `valid_sweep`, `verb_allowed`, `can_finish`, `lap_ended`, `lap_result`, dwell, patience | above the marker | root, parent and child |
| record fields `appearances[].extra[]` and person `limits` | `validate_appearance`, `validate_record` | root (stored in 0600 files) |
| `public()` gains `templates`, `lockTemplates`, `sudoTemplates` (counts only) | `public` | root, leaves in `people.json` (0644) |
| `ready` gains `verbs` and `limits` | `cmd_enroll_session` | root |
| `OMARCHY_FACE_SWEEP_SECONDS` (test override) and `SESSION_SCAN_SECONDS` (600) | `sweep_bounds`, `session_bounds` | root |
| `OMARCHY_FACE_SWEEP_PY` (the wrapper hands SWEEP_PY to the store program) | `store_py`, the `enroll-session)` case | root |

## The ten items (plan section 6)

**1. `valid_sweep` is complete and runs in the parent before any child exists.**
`valid_sweep(mode, lap, targets, prior)` (pure) is called from the `sweep` branch before `run_sweep`; every failure
is the one answer `capture_failed` `bad_sweep` with the reason on stderr only. It rejects: bool-as-int (`type(x) is int`, not
`isinstance`), floats, strings, `None`, repeats, out-of-range bins, Simple other than exactly `[9,3,0,6]`, Advanced other
than exactly the twelve bins (no subset), lap other than the int 1 or 2, lap 2 outside the `swept` state of an Advanced lap 1,
`usual` with targets or without a kept Advanced set, Simple over an appearance that holds more than 5 stored templates
(rule R, read fresh from the store at each sweep), a sweep while a scan runs. The child's argv is built only from the validated
`mode`, `lap`, the ints of `targets` and four finite floats from `sweep_bounds()`; the child validates its argv again.
`verb_allowed` (table V) is checked as well, so a verb the state does not allow is also `bad_sweep`.
Tested: `e0` (every validation case and every table V cell), `e1` ("bad_sweep" step: 24 hostile lines, including `NaN`, `Infinity`, `1e400`, `true`,
a subset, a repeat; asserts no `sweeping` event and no child process for them).
Note: `usual` is validated but refused (`bad_sweep`) in this phase: its engine is Phase 5.

**2. The typed allow-list.**
Everything a sweep says to the client passes `emit_checked` -> `typed_event`: a fixed set of keys, each with a type and a range,
numbers must be finite and not bool (`finite_number`, which also catches `10**400`), the output is serialised with `allow_nan=False`,
`code` is an enum of the twelve codes, `state` of the ten words, `event` of the five sweep event names. One unknown key, wrong type or
out-of-range value drops the whole event (stderr note). The child's own events go through it too; the child's one private line (`{"result": ...}`,
which carries encodings) is recognised by shape in the parent, never forwarded, and would fail the allow-list if it were.
Tested: `e1` unit step (19 drops, every code, `sweeping`, `swept`, `track` pass) and the last step (no list of 100 numbers, no `/dev` path, only known
event names in any transcript of the run).
Accepted, not closed (plan): `bins` just short of full and the word `other` are a coarse oracle for "is this frame within SUPPORT/CHAIN/HARD".

**3. The channel to the child and the single owner of Done (rule F).**
The child's stdin is a pipe. The parent writes the literal `finish\n` and only after judging the client's `finish` legal (a scan is running and no
result has arrived). The child polls once per frame (zero-timeout `select`) after processing the frame, so a fill in that frame counts and a later one
does not (frame order). It acts only on the exact bytes `finish`; anything else on the pipe is ignored; EOF on it means the parent is gone and the
child exits. `abort` and EOF do not use the pipe: the parent kills the child's process group. At the end the parent recomputes Done from what it
received (`judge`: the templates it was actually handed, each checked for bin, `r`, `support` and 128 finite numbers), with the same pure functions,
and only then sends `swept`; the child's own claim is not used.
A `finish` read when nothing runs (`ready`, `swept`, after a failed `sweep`) is ignored; `done` commits only labels in `committable`.
**Departure from the plan text:** lap 2 and the same-person guard need the appearance's existing encodings in the child. Rule F says the child
reads no number or text from the parent on stdin; I gave it a second pipe (an extra fd passed with `pass_fds`, its number an argv value) that the
parent writes once (reference encodings, lap 1's median eye) and closes. stdin still carries only `finish`.
Tested: `e1` ("finish" step: below the floor `not_enough` and the lap continues; at the floor it ends; one read after the filling frame counts; stray `finish`
ignored in `ready`, `swept` and after a failed sweep), `e0` table V.
The "same frame" race is tested with a stub camera that waits for a line on stdin before releasing a chosen frame; the exact filling frame is not hit to the
frame (the fill is two to three frames wide in that script), the semantic "read after processing" is.

**4. The client cannot make a target filled, skipped or Done allowed.**
The client's whole vocabulary during a scan is `finish` and `abort`; neither carries a value. There is no time, position or "reached" field anywhere on the wire.
`finish` is re-judged in the child (`can_finish`) and again by the parent at lap end (`judge`). `skipped` and unresolved targets never count toward
`SIMPLE_MIN_HELD` (`can_finish` takes the filled set only). Tested: `e0` (`can_finish`, `lap_result`), `e1` ("patience" step: skipped targets do not count, `too_few`).

**5. Simple's floor is enforced in root; nothing from a dropped lap can be committed.**
`lap_result` at lap end (parent, in `judge`): `swept` only if `can_finish`, else `too_few` (centre held) or `lap_timeout` (never held). A dropped lap pops the
appearance from `captured` and `committable`; `changed` drops the whole appearance's pending set; an aborted or failed lap 2 keeps lap 1 (table V). `done`
commits `captured` restricted to `committable`, then `validate_record` runs over the whole record before it is written, as before. The Simple target list is fixed in root;
the client names it and root checks it equals `[9,3,0,6]`.
Retake semantics I chose: a valid lap 1 sweep drops that appearance's earlier pending set when it STARTS, not when it succeeds, so a failed retake leaves nothing
stale and committable. Tested: `e1` ("patience, resolved targets" and "a second identity" steps: `too_few`, `lap_timeout`, `changed` store nothing; `done`
after them is `bad_sweep`; an aborted lap 2 keeps lap 1).

**6. Stored `pose` comes from the bin; no mode is stored; root never reads the preference file.**
`pose` is `pose_name(bin)` computed in the parent from the validated bin index of a template the child returned; the client sends no pose. `band` is decided by the lap (1 near,
2 far). `validate_appearance` requires a pose that is `aNNN` with NNN a multiple of 30 below 360 (or `usual` with band `usual`), unique per band, at most 12/12/2 per band.
No mode, lap or target list is written to a record. Root has no code that opens `enrol-mode` or any user file. Tested: `e1` unit (a pose from client text, `a095`,
`usual` with a bin pose, a repeated slot, 27 extras are all refused by `validate_record`).

**7. `OMARCHY_FACE_SWEEP_SECONDS` only lowers, cannot arrive through the GUI, and ignores junk.**
`sweep_bounds()` takes `min(bound, asked)` for the Simple and Advanced ceilings, patience, prompt lead and stall time; a value that is not a finite number above 0
(`NaN`, `inf`, `-1`, `0`, text, empty) is ignored. **Departure from the plan text (the coordinator's brief):** it is never read at all by root of the machine
(`real_root()`: effective uid 0 and an identity `/proc/self/uid_map`; unreadable counts as real root), while the sandbox's root, a user-namespace root with a non-identity map, may use it.
That is how `e1` runs the same code path in three seconds as in sixty. The plan names only the clamp; the root exclusion is the brief's, adapted so the sandbox can still use it.
The child reads no environment: it is handed the clamped numbers as argv. pkexec drops the caller's environment anyway.
`OMARCHY_FACE_SESSION_SECONDS` keeps its old behaviour (it used to scale a 600 s scan bound too; that bound is gone, see "After SR1" below).
Tested: `e1` unit (`1e9`, `NaN`, `inf`, `-1`, `-inf`, `0`, `abc` and empty lengthen nothing; `real_root()` true ignores it) and the session-bound step.

**8. The legacy `capture` verb.**
Unchanged in behaviour for an old card on a new helper (one `howdy add`, one frame), refused with `bad_sweep` once the session has accepted a `sweep`
(`verb_allowed(..., swept_before)`). Tested: `e1` ("legacy capture works until the first sweep"; `capture` after a sweep is `bad_sweep`).

**9. The coarse oracle** (item 2 above) is accepted by the plan; nothing was added to close it.

**10. The parent loads the same pure text as the child, and can run nothing beyond the pure functions.**
The wrapper sets `OMARCHY_FACE_SWEEP_PY=$SWEEP_PY` on every call of the store program (`store_py` and the `enroll-session` exec), so an inherited value cannot survive.
The store program executes only the text before `# ==== THE CAPTURE HALF`: definitions, imports of `math` and `sys` only, no I/O (asserted in `e0`: imports,
no `open`/`exec`/`eval`/`compile`/`print`/`input`/`__import__` calls, no path in the pure half). The whole text is given to the child as its own `python3 -I -c` argument.
Caveat for the reviewer: the environment variable is a 40 KB string in root's environment, visible to root only. If the marker is missing or appears twice
the store program refuses (`engine_missing`).

## Other things worth a look

- **Can a lap store a different person's face?** Lap 1 has no reference by nature (it is whoever is in front, as `capture` is); once its centre is held the same
  guard as the plan (`CHAIN` 0.40, `HARD` 0.55) applies to every later frame and five consecutive failures end it as `changed`, dropping everything of that appearance.
  Lap 2 starts with the appearance's centre and templates as its reference (second pipe) so a different person is refused from the first frame. `e1`: `lap2-other` and `simple-changed`.
  Before the centre is held there is no guard; the centre needs 2 supported frames within `SUPPORT` 0.30 of each other, so two people alternating cannot make one.
- **Can the child outlive the session?** It runs in its own session under `timeout -k 2 <ceiling+15>`; `run_sweep` kills the process group in `finally` on every exit
  (result, abort, EOF, session expiry, any exception); the child exits by itself on EOF of its stdin. `e1` asserts no `python3 -I -c` remains after abort, EOF and expiry.
  A parent killed with SIGKILL leaves the child until its next frame (it sees EOF) or `timeout`'s limit.
- **Does `extra`/`limits` widen what `validate_record` accepts?** It accepts records with two more optional keys; both are held to stricter rules than the centre (finite numbers,
  bounded counts, a closed vocabulary for `pose` and `band`, limits between 3 and the compiled maxima 36/12). A record without them is valid exactly as before.
  `limits` below 3 is refused so every appearance's centre always fits in the cap. `e1` unit: 18 refusals.
- **`pick`, caps and determinism:** `pick` itself is unchanged from Phase 1 and tested in `e0`; this phase makes `model_entries` use it (per person, under that person's cap,
  centres first in stored order, so a record without extras regenerates byte-for-byte: `f3`'s regenerate checks and `e1` "regenerate is byte-identical").
- **`warning_for`** now takes the people, warns only when one sudo person's templates in the Sudo set exceed the default 4 (needs a deliberate `set-limits`).
  `f3` was edited for it: five faces across three people no longer warn. With `SUDO_POLICY = "centre"` (below) it cannot fire at all, because Sudo has only centres.
- **Camera lock:** the whole lap holds `camera_lock()`; a busy camera is `camera_busy`.
- **600 s:** gone (SR1 S2, below). The whole-session bound stays 300 s from `ready`; idle stays 120 s and restarts after each handled command.

## Plan points that were unspecified, and what I chose (the reviewer should know)

1. The plan lists ten state words and no word for a frame that passed every gate. The code reports `hold` (`ACCEPTED_WORD`) for those, so the view cannot tell
   "accepted, hairline may sweep" from "not steady". Phase 4 needs either a word or a field; the constant is one line.
2. `ready.verbs` lists `capture, sweep, abort, finish` and not `trial`: advertising a verb that is refused would make the view's fallback test lie. Phase 5 adds it.
3. `limits` in `ready` is `{lock, sudo}` (the person's in-effect caps, or the defaults for a new person).
4. A target skipped by patience is announced through `track.skipped` only; the child sends no separate event.
5. The Simple lap's ceiling is rule L's: three filled and one unresolved saves, one filled is `too_few`. A Simple user at 60 s with the centre and one target loses the lap.

## After SR1 (version 3.1.0): what changed, per finding

`review-face-enroll-SR1.md` found one install blocker, two required changes, a stderr/path leak and some minors. All of it is in `system/omarchy-face-admin` unless named.

**B1, version.** The system half and the plugin are bumped together to **3.1.0** (as 3.0.0 did): the `omarchy-face-version` header of the ten pinned files and `system/install.sh`,
`common/Ask.qml` `systemVersion`, `manifest.json`, the four `bin/` markers. 2.1.0 and 2.2.0 changed only the plugin and left the system half at 2.0.4; this release changes the system half,
so both move. `dev/update-pins.sh` rewrote the pins, `install.sh.sha256` and the README command. `dev/check-pins.sh` exits 0 and prints the note that `v3.1.0` is not tagged yet (a note, not an error).
**Not tagged.** `dev/g10-rename.sh` asserted `kalinewb.face 3.0.0` after `install.sh`; it now reads the version from `manifest.json`.

**S1, rule F.** `judge()` now takes the pending centre (lap 2: `captured[label]["encoding"]`; lap 1: the child's own, after the 128-finite check) and drops the lap (`timeout`) unless every template
is within `HARD` of that centre and has `R_MIN <= r <= R_MAX`; lap 2 with no usable held centre is dropped. It still does not re-check `CHAIN` (nearest accepted template), which the child's order of capture makes
awkward to reproduce from an unordered list; a connectivity check over the centre and templates is possible and was not added. Tested: `e1` unit (boundary 0.55 / 0.5501, r 1.0 / 2.2 / 0.99 / 2.21 / 3.9 / 4, NaN,
lap 2 with a missing, short and far centre) and end to end through the real parent with a patched copy of the helper whose child guard passes everything (a stranger's four templates in lap 1, a stranger's lap 2)
or reports r 3.9: all three dropped; before the fix the first two were saved (checked against the previous `judge`).

**S2, 600 s.** Dropped: no sweep lengthens the session. `SESSION_SCAN_SECONDS` and the `ends_at` reset are removed, `session_bounds()` returns two numbers. Two Advanced laps are at most 180 s inside the 300 s. The credit formula
for when `trial` and `usual` need more time is in the comment next to `SESSION_SECONDS` (`ends_at = began + 300 + min(camera seconds actually used, 300)`). Tested: `e1` session-bound step (a sweep sent at once or at 3 s of a 4 s session buys nothing; an abort inside the bound works).

**S4, stderr and paths.** The child's stderr goes to `logger -t omarchy-face-sweep` (the journal), never to the helper's stderr; `DEVNULL` if `logger` cannot start. A session `error` event carries the code only: the record path of
`store_corrupt` goes to the journal (`audit`); the other verbs still answer with `file`. Tested: `e1` (a child patched to write a path and a traceback to stderr; a corrupt record's session error has the one key set and no path).

**m1, camera lock in the child.** The lock fd is passed to the child (`pass_fds`), and the parent now only *closes* its copy after killing the group: `LOCK_UN` would release the lock for the child's copy of the same open file.
A wedged child or a SIGKILLed parent now keeps the lock while the sensor is open, as the daemon does for `compare.py`. Tested: the child and its `timeout` hold the lock file open while a lap runs, and the lock is free afterwards.

**m2.** `RecursionError` is caught with `ValueError` at all three `json.loads` of client or child lines: a 60,000-bracket line is "not JSON", the session continues (tested, in `ready` and during a scan).
**m5.** An invalid or missing label on a `sweep` is `bad_sweep`; `capture` still ends the session on a bad label, as before (tested: four more hostile lines in the bad_sweep step).
**m8.** STORE_PY and SWEEP_PY keep their own copies of the four template numbers (single-sourcing would make every verb depend on the sweep text being present); `e1` asserts the copies are equal.

**S3, decided by the user (2026-11-02): Sudo uses centres only.** `SUDO_POLICY = "centre"` in SWEEP_PY's constants block (the only other value is `"full"`; anything else counts as `"centre"`). `pick` for Sudo returns the centres of
every appearance (a look is never dropped) and nothing else under `"centre"`; under `"full"` it is the previous rule, unchanged (cap 4, bit-reversal band order, `r <= 1.5`, within 0.40 of the centre). Enrolment still stores the whole
pose set and `validate_record`, the caps, `set-limits` and Lock are untouched, so flipping the word needs no re-enrolment. `ready` and `people.json` carry `sudoPolicy`. `warning_for` is as the plan has it and counts what `pick` gives Sudo,
so it fires only under `"full"`. `pure()` now hands out the namespace the functions run in (it was a copy), so a test can set the word. Tested: `e0` (both words, unknown words fail closed to centres) and `e1` unit (both words on the same record, both validate, Lock identical, model sets, warning).
How to flip it: `dev/README.md`, "How to widen Sudo later"; SR1 must re-review the exposure with Phase 0 stranger data first. The constants `CHAIN` 0.40, `HARD` 0.55, `SUDO_CENTRE` 0.40 are still above the 0.35 threshold and uncalibrated; that matters for Lock now.

**Not changed / notes.** m3 (every `sweep` line re-reads the store), m4 (rule R at `done`, and a non-int `stored`), m6 (`time.monotonic` across suspend), m7 (EPIPE on the reference write): not done. m9 (the sweep child runs unconfined; the daemon runs the same
libraries under `ProtectSystem=strict`, seccomp and `DevicePolicy=closed`): a note only. The follow-up is a `systemd-run --pipe --wait` with the daemon's sandbox and `DeviceAllow` for the IR node only (plan 6a.5). m10 (Phase 5 `trial_result{best,threshold,margin}`
would be a continuous distance oracle against stored templates and needs its own SR). m11 is process.

## Delta in 3.1.1 (2026-11-02): the strobing emitter. SR1 must re-read this; it is small, but it is root code

Found live (the user's own recordings, `~/.cache/omarchy-face-enrol/20261102-003658-desk` and `-003814-inlap`): this laptop's IR emitter strobes, so **every other frame is entirely black** (darkness 100%), the lit frames are fine (median 11-14% dark, none above `DARK_MAX` on a face frame). `SWEEP_PY` counted a black frame as `dark` (word, `seen["black"]`), so "Too dark here" showed with the emitter visibly blinking. howdy itself skips a black frame as "a bad camera read" (`add.py`, `compare.py`: `if hist_total == 0 or darkness == 100: continue`) and counts darkness over lit frames only; the sweep now does the same. Files: `system/omarchy-face-admin` only (the SWEEP_PY text), plus the 3.1.1 bump and pins.

What changed, and only this:
1. `is_strobe(total, darkness)` (pure): a frame with no pixels or every pixel in the darkest bin. In the capture loop such a frame is **skipped entirely**: no word, no `track`, no patience, dwell, stall or rule-P start tick, not a `dark` frame; it is counted only as a frame (`seen["strobe"]`) and the lap ceilings, which run on wall time, still advance. `finish` on stdin and EOF are still polled on those frames. Dwell credit is unchanged for lit frames: it is the time since the previous accepted frame capped at `DWELL_GAP_MAX` (0.3 s), and two frames at 15 fps are 0.13 s, so a strobe does not break a hold.
2. `STROBE_SILENCE = 2.0` s (my addition, not asked for): a stream with no lit frame for 2 s is a covered or dead camera, not a strobe, so a black frame after that is called `dark` as before (`seen["black"]`). Without it a covered camera would show no word at all for the whole 60 s ceiling. Delete the constant and the `strobe = blank and ...` condition to drop it.
3. `refine_for(seen)` (pure), replacing the inline chain: `lit = frames - strobe - black`; no lit frame is `black_frames`; every lit frame too dark is `too_dark`; `multiple_faces` and `no_face` are halves of the **lit** frames. The twelve-code enum and `lap_result` are unchanged, no new code. The legacy `capture` verb runs howdy's `add.py`, which already behaves this way (black frames are not counted, `valid_frames == dark_tries` only for lit ones), and `verify`/Test run `compare.py` the same way (black frames are `black_tries`; its `dark_tries == valid_frames` quirk prints "too dark" for a stream with no lit frame at all, which is honest); the plugin patches none of howdy.

Not changed: `frame_word`'s `dark` for a lit frame over `DARK_MAX` or over 6% saturation; the guard, the gates, `pick`, the wire protocol, the allow-list. Tested: `e0` (is_strobe at its boundary, `refine_for` for strobe, black, dim and mixed streams), `e1` (a half-black stream finishes a Simple lap and an Advanced lap with no `dark` word; all-black is `black_frames`, all-dim is `too_dark`, dim behind a strobe is `too_dark`; an all-black stream says `dark` only after the 2 s of silence). SR1: is skipping a black frame in `finish`/EOF polling and the ceilings correct; does the 2 s rule leave a way to hold the lap open with black frames (it cannot: the ceilings run on wall time); is the `refine` change reachable from the client (no).

## Delta in 3.1.2 (2026-11-03): the strobe rule was wrong on real hardware. What SR1 re-reads (root code again)

3.1.1's `is_strobe` tested `darkness >= 100`, and **no real unlit frame is exactly 100%**: 60 raw frames from this laptop's IR camera (`/dev/video2`, GREY 400x400) run through the helper's own CLAHE and 8-bin histogram gave lit frames 26.7-37.3% dark (raw mean 31-65) and unlit frames **99.76-99.96%** dark (mean 1.2-1.7; the first two unlit frames of a stream 89.3%, mean 6.3), because sensor noise survives CLAHE in a few hundred pixels. The fix did nothing on this hardware, and 3.1.1's tests (and SR1's differential tests) used synthetic exactly-black frames. The measured statistics are committed as `dev/fixtures/ir-strobe-stats.json` (the raw frames are not).

What changed (all in `system/omarchy-face-admin`; the child's text, plus one argument and one config read in the store program):
1. **`is_strobe(total, darkness, mean)`** (pure): `total == 0 or (darkness >= STROBE_DARKNESS (85.0) and mean < STROBE_MEAN (12.0))`, where `mean` is the raw frame's mean brightness. The margins from the data are wide: unlit >= 89.3% and mean <= 6.3, lit <= 37.3% and mean >= 31.4. A dim lit frame (80% dark, mean 25) is a `dark` frame as before.
2. **`strobe_phase(blank, now, last_lit)`** (pure, SR1 minor M3): the `STROBE_SILENCE` (2.0 s) rule extracted and tested at its boundary (a blank frame within 2 s of a lit one is skipped, at exactly 2 s it is not, and one with nothing lit seen yet is not). A very dark room, or a covered or dead camera, has no lit frame at all, so after 2 s its frames are `dark` and the lap ends `black_frames` (`refine_for`, unchanged from 3.1.1). Without the silence rule that case would be skipped for the whole ceiling.
3. **Debug trace (off by default).** The store program reads `debug=true` from root's `/etc/omarchy-face/config` (`config_get`, the way `account` is read; **not** an environment variable: `OMARCHY_FACE_SWEEP_SECONDS` is never read by real root, so an env switch could not work in production, and a GUI-settable one is not safe) and hands the child a ninth argument `0` or `1`, validated in `parse_args` like the others. With it, the child writes one line a second (at most 120 a lap) to its stderr, which is the journal under the tag **`omarchy-face-sweep`** (`journalctl -t omarchy-face-sweep`): elapsed time, frames, strobe_off, black, lit, dark, none, multi, the last word, the mean darkness of the lit frames and the refine candidate. Counts and words only, never a frame, a landmark, a path or an encoding. Nothing reaches the client.
4. **M1 (`dev/check-pins.sh`):** every `omarchy-face-version:` header in `system/*` and `bin/*`, and `manifest.json`, must equal `system/install.sh`'s, and a file with no header fails.

Tests: `e0` (the measured stats leave the margin; every measured unlit and lit class on the right side of the rule; the rule is not an equality test, checked on behaviour and on the source text; `strobe_phase`'s boundary), `e1` (the fake camera now produces **measured-distribution frames**: `unlit` 99.8% dark mean 1.3, `unlit-start` 89-93% mean 6, `lit` ~33% dark mean 57, and a step asserts those ranges against the fixture; an alternating unlit/lit stream shows no `dark` word and finishes a Simple lap and an Advanced lap; an all-unlit stream ends `black_frames` with `dark` after the silence; an all-dim lit stream is `too_dark`, also behind a strobe; the debug trace is off by default, appears with `debug=true`, is at most 120 lines, counts the strobe-off frames and holds only words and numbers). SR1: is reading `debug` from root's config and passing a validated `0`/`1` argument safe; can a client reach the trace (no); is skipping a frame on `mean` instead of darkness alone sound (a flat bright frame is not skipped, a lit frame is never skipped).

## Delta in 3.1.3 (2026-11-03): steadiness calibrated on the user's recordings, a fuller trace, SR1 minors. What SR1 re-reads

**The finding.** With 3.1.2 the strobe was handled (dark=0) but the scan never left the centre. `dev/replay-recording.py` (new, user-run; it needs the recordings, which are never committed) replays a recording through the REAL pure functions and the capture loop's decisions (strobe test, CLAHE darkness, saturation, sharpness against the session median, pose from the five recorded landmarks, the smoothed steadiness, `frame_word`, the neutral, the centre dwell with `supported` approximated by 0.2 s spacing, since a recording has no encodings). On the lit one-face frames the per-gate failures were: **unsteady 310 of 319 (desk), 70 of 73 (a held head, `still`), 217 of 217 (in the lap), 816 of 838 (guided)**; the other gates were negligible (dark/saturated 1-3, blurry 1, closer 59 and edge 14 only in the guided turns, roll 1). Cause: a head held still wanders by about 0.4 u (6 degrees; yaw index spread 0.046, lag-1 autocorrelation 0.91), and 3.1.2's test (mean of 3 lit frames, every one of 3 steps under `STEADY_STEP` 0.05) read that as moving: steady in 4% of the held head's frames, so the neutral (the first five steady frames) and the centre dwell never completed. No pose offset is involved: the neutral is already the user's own first steady pose, so a constant offset (a camera above or below the screen) cancels by construction. The synthetic e0/e1 heads had far less jitter than a real one (e0 had 0.25-0.5 px of white noise; the real one drifts slowly and by about 3 px).

**What changed (constants and the trace; nothing on the wire).** `SMOOTH_FRAMES` 3 to 5 and `STEADY_STEP` 0.05 to 0.20, chosen from a sweep over the recordings (`dev/fixtures/ir-held-head-stats.json` holds the held-head statistics only): a held head 97% steady (5, 0.20) against 4%; frames in clear motion (over 0.8 u across the window) 5% steady; the slow desk lap 55%. The replay table (accepted = passed every gate, one-face lit frames; centre held = dwell 0.8 s inside `R_MIN` with two frames 0.2 s apart):

| recording | accepted 3.1.2 -> 3.1.3 | centre held at, 3.1.2 -> 3.1.3 |
|---|---|---|
| held head (`still`) | 3 of 73 (4%) -> 64 (88%) | never -> 2.5 s |
| slow desk lap | 9 of 319 (3%) -> 172 (54%) | never -> 23.0 s (the user was turning) |
| in the lap | 0 of 217 -> 32 (15%) | never -> 2.7 s |
| guided | 22 of 838 (3%) -> 446 (53%) | 29.4 s -> 2.4 s |

The cost is that a slow deliberate turn can now read as steady for a few frames; a target still needs `TARGET_DWELL` 0.8 s inside its wedge and two supported frames (distance `SUPPORT`), and the sharpness gate, so a moving head does not fill a target.

**Trace (still off by default, 1 line a second, 120 a lap, numbers and enum words only).** Adds: `accepted` (cumulative) and `acc_s` (this second), the per-gate failure counts `closer farther edge darkgate blurry roll unsteady`, `other`, `over`, the pose relative to the neutral in whole degrees (`yaw pitch`, u and v times 15, `n/a` before the neutral) and the roll, the centre gate (`in`, `out` of `R_MIN`, or `-`), `centre_held`, `filled`, `target`, and `last_word` printed `skip` for a strobe-off frame and `ok` for an accepted one **in the trace only; the wire's words are unchanged**. The pure `gate_failures` is tested against `frame_word`'s order. **SR1 m1:** the trace write and flush are in `try/except (OSError, ValueError)`, which turns the trace off and never fails the lap.

**SR1 minors.** m3: the 3.1.2 note's claim "a lit frame is never skipped" is stricter than the code. What is true: `is_strobe` is about the frame's content, so a lit frame is skipped only if it is nearly all dark and has a raw mean under 12 (indistinguishable from an unlit one by definition), and a stream with nothing lit for 2 s stops skipping. The e0 margin test now compares the measured lit maximum with `DARK_MAX < STROBE_DARKNESS`. m5: `check-pins` reads the headers as the runtime does (`head -40`, line-anchored, any non-alphanumeric prefix). m6: `config_get` is last-wins like the shell side (`tail -1`; e1 appends `debug=false` after `debug=true` and sees no trace), and e0 runs the child with a bad ninth argument (`2`, `yes`, empty, `01`, `true`, `-1`: refused, exit 2, nothing started), with the old eight-argument form (refused) and with `0` and `1` (past argument parsing).

Not changed: the gates' other thresholds, the guard, `pick`, the wire protocol. SR1: is a looser steadiness a way to store a worse template (the lit frames still pass the guard, `SUPPORT`, sharpness and the dwell); is the trace's extra content (a pose in degrees) acceptable in the journal (root-readable config key, off by default).

## SR1 on 3.1.3: plugin-side fixes (no root change, no re-pin) and what is deferred to 3.1.4

Fixed in the plugin (`bin/omarchy-face-toasts`, `Service.qml`, `EnrolView.qml`; `system/`, `common/Ask.qml`, `manifest.json` and the version untouched):
- **S1.** The do-not-disturb hold lived in two unordered detached `sh` processes, and a release removed its marker before `setDnd off` was known to have worked. `omarchy-shell -q` also hides the answer, so the old `isDnd` check (which used `-q`) could never read `off`. Now one helper, serialised by `flock`, takes a generation on every call (milliseconds since the epoch times 1000 plus a counter, so it grows across restarts) and ignores a call older than the newest seen, so a hold can never run after a later release; the marker is removed only when `isDnd` answers exactly `off` after `setDnd off`, and kept (retried at the next start of the service) otherwise; a hold keeps the marker unless `isDnd` answers exactly `off` afterwards; a do-not-disturb that was already on, or cannot be read, is never touched. The indicator refresh the toggle script does (`omarchy.indicators refresh`) is run after a change. The false comment is corrected: only `omarchy-action`, and `notify-send` at critical urgency, bypass do-not-disturb (`NotificationLogic.js` `shouldBypassDnd`), so Face's own alerts (`omarchy-notification-send --app-name "Face ID"`, `notify-send -a "Face ID"`) do NOT, and a do-not-disturb left on silences Face's own health alerts.
- **m1.** No `/tmp` fallback: no `XDG_RUNTIME_DIR` of the user's own, nothing is done.
- **m7.** "Add more" became "Scan again": the lap replaces the pending set, it does not add to it.
- Tested headless by `dev/e5-toasts.sh` (a stub `omarchy-shell` as the shell's notifications): hold, release, release after a setDnd that did not take (marker kept, then recovered), an unreadable answer, pre-existing do-not-disturb untouched, ordering (a late hold ignored; six fast open/close pairs in either order; 30 and 29 racing calls), no runtime directory, bad arguments. Not testable headless: `Service.qml` itself, and the shell's real persistence.

### Deferred to 3.1.4 (root code; not touched now)
- **m2.** Rename the trace key `darkgate` (it reads like `dark`) and revisit where `ok` is placed for `last_word` (an accepted frame that later fails `other` or `over` reads `ok` or its later word depending on the path).
- **m3.** The remaining wording of the strobe claims in these notes.
- **m4.** Derive the pose history cap (`poses[-8:]`) from `SMOOTH_FRAMES + STEADY_FRAMES` instead of a literal 8, which is only right while they sum to 8.
- **m5.** (check-pins reads headers like the runtime: done in 3.1.3; the remaining part is for 3.1.4.)
- **m6 v2.** A version-2 marker in `check-pins` for the header format.
- **m9, m10.** As SR1 listed them.

## Delta in 3.1.4 (2026-11-04, revised after SR1): the guard is 3.1.3's, measured; a fuller trace that reaches the last line; SR1 minors. What SR1 re-reads

**The measurement** (`dev/measure-guard.py`, user-run; real dlib, the same resnet model the helper uses, taken from howdy's build cache because `/usr/lib/security/howdy/` is root-only and nothing here uses sudo; the recordings and descriptors are never committed, the descriptor cache is a 0700 directory of 0600 files and `.gitignore` covers it). It repeats the helper's steps (CLAHE, the frame and box scaled to `max_height` 320, the five landmarks, `compute_face_descriptor(small, shape, 1)`), takes the pose through the pure functions, and reports distances for the frames that would REACH the guard: steady, through the eye/edge/roll gates, r <= `R_MAX` 2.2 (a frame past `R_MAX` is `over`; an early table over all frames counted 21 refusals in `guided` that were small, far-away faces the eye gate turns back).

Distance of the owner's own frames to the CENTRE template (HARD 0.55), by how far off-centre the head is (r; u is about 15 degrees); p50 / p90 / p99 / max:

| recording | r 0-0.5 | r 0.5-1.0 | r 1.0-1.5 | r 1.5-2.2 |
|---|---|---|---|---|
| held head (60) | .075/.106/.195/.195 | .184/.233/.254/.254 | .182/.201/.206/.206 | |
| slow desk lap (168) | .152/.286/.296/.296 | .276/.318/.383/.385 | .297/.331/.345/.357 | |
| in the lap (25) | .073/.111/.162/.162 | .274/.296/.296/.296 | | .312/.355/.383/.383 |
| tilted (46) | .115/.148/.269/.269 | .169/.331/.331/.331 | .245/.256/.306/.306 | |
| far (33) | n=1 | .090/.113/.137/.137 | .205/.237/.238/.238 | .216/.326/.393/.393 |
| guided (353) | .128/.289/.310/.319 | .273/.391/.395/.395 | .271/.318/.412/.412 (11% over CHAIN) | .364/.392/.461/.461 (12% over CHAIN) |

No owner frame that reaches the guard is over HARD (max 0.461); 11-12% of the guided turn's frames at r 1.0-2.2 are over CHAIN 0.40, because until a target fills the centre is the only template. Against the nearest earlier frame in the same pose neighbourhood they are at most 0.29 there.

**Why the sliding chain was dropped (SR1 S1, S2).** 3.1.4 first measured CHAIN against the centre, the templates and the latest 6 accepted frames of the last 1.5 s. SR1 showed that is wrong: an accepted stranger frame enters that window, so the claim "he never becomes the chain" was false; a stranger at an identity gap of 0.40-0.45 stored in 3-4 of 4 Simple laps against 0-1 of 4 under 3.1.3, and a strict owner/stranger alternation stored a stranger in 5 of 6 laps at a gap of 0.40. And the benefit on the owner's own recordings was nil (the 3.1.3 guard refuses 0 owner frames in five of the six recordings and 4 of 353 in `guided`, never five in a row), and the window cannot recover after a gap over 1.5 s. e1's stranger scenarios had no per-frame spread, so they could not see it (S4). **The guard stays exactly what 3.1.3 shipped.** It will be loosened only by the minimum the live trace shows is needed, with stranger-like data in hand; there is none yet (disclosed since S3). `guard_ok` takes no `recent` frames; `e0` fails if it does, and `simple-foothold` in `e1` (one stranger frame 0.38 from the centre, then frames 0.46 from the centre and near that one: refused as `changed` by a chain of templates, admitted by a chain of accepted frames) fails if a chain of accepted frames comes back.

**The recordings do not reproduce the live "That was not you"**, so the live lap met frames or a centre template these recordings do not contain; the trace is how the next failure explains itself.

**Trace (off by default, 1 line a second while the lap runs plus ONE FINAL LINE when it ends, 120 a lap, numbers and enum words only; SR1 S3).** `hard_max` and `chain_max` (largest distance to the centre and to the nearest accepted template in the last second, 2 decimals), `guard_run` (the run of refused frames; 5 ends the lap), `lap_end` (`none` while it runs; `changed`, `finish` or the ceiling's word on the last line). The last line is written by `trace_line` after the loop, so it is written before `changed` is left; before, `if reason == "changed": break` came ahead of the trace and `guard_run` could never print 5. Reading it: `hard_max` over 0.55 is the centre test failing; `chain_max` over 0.40 with `hard_max` under 0.55 is the chain failing. `exposure` (was `darkgate`) is the dark OR saturated gate; `last_word` is `skip` for a strobe-off frame, `ok` for an accepted one in the trace only, and `other`/`over` for a frame that passed the gates and then failed the guard or r (SR1 m2). The pose history cap is `SMOOTH_FRAMES + STEADY_FRAMES` (SR1 m4).

**Tests.** `e0`: the owner frame at 0.46 is refused, `guard_ok` takes no `recent`, one stranger frame inside CHAIN does not make 0.46 a chain step, HARD unchanged, `guard_distances`, the history cap, one `trace_line` also called at the lap's end. `e1` (the fake dlib gained a `drift` axis and strangers now have per-frame spread): the owner's 0.46 turn ends `changed`; identity gaps 0.46 (wobble 0.04), 0.50 (0.08), 0.54 (0.04), a mid-hold swap and the foothold end `changed` with nothing stored; a stranger on 2 of 3 frames and on every other frame never makes five in a row, the lap completes and every stored descriptor is the owner's; **the known limit is pinned**: a stranger wholly inside CHAIN of the centre (0.38) is accepted, the lap completes; the trace's last line shows `guard_run 5`, `lap_end changed`, `chain_max` over 0.40 and `hard_max` under 0.55.

**SR1 minors.** m1: the comments `(3.1.3: measured; was 0.05)` and `(3.1.3: was 3)` are attributed to the release that made the change. m2 (measure-guard): private cache. m6: `dev/check-pins.sh` requires the `omarchy-face v2` marker in the first 40 lines of every `system/` file (the runtime refuses a snapshot without it, `snapshot_unmarked`), with mutation tests in `dev/check-pins-test.sh` (marker removed, marker past line 40, a `bin/` header that disagrees or is missing, manifest and `Ask.qml` disagreeing). m7, a known limit not fixed: `time.monotonic` across a suspend (the lap's clocks) and the camera lock are as in 3.1.0. m9 and m10 are not in what I was given.

**UI, plugin side, not root (SR1 m3).** The dimming behind the island (`ScanScrim.qml` per screen, `ScrimLayer.qml`): the input region is the layer's absorber, which has no size until the island has started to drop and once it is gone, so the window blocks no click it is not dimming (it stays mapped, transparent, so it keeps its place under the card in the stack); a 2 s watchdog in `Service.qml` removes the scrims if the card never shows presence; `closeCard` clears them first, so a failed card creation cannot strand one. The polkit-above-the-scrim check stays a live step.
