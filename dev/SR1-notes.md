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
`OMARCHY_FACE_SESSION_SECONDS` keeps its old behaviour (and now scales the scan bound to twice the plain one, so a test can watch a sweep outlive one and stop at the other).
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
  `f3` was edited for it: five faces across three people no longer warn.
- **Camera lock:** the whole lap holds `camera_lock()`; a busy camera is `camera_busy`.
- **600 s:** `SESSION_SCAN_SECONDS`, from `ready`, applies from the first accepted `sweep`; idle stays 120 s and restarts after each handled command.

## Plan points that were unspecified, and what I chose (the reviewer should know)

1. The plan lists ten state words and no word for a frame that passed every gate. The code reports `hold` (`ACCEPTED_WORD`) for those, so the view cannot tell
   "accepted, hairline may sweep" from "not steady". Phase 4 needs either a word or a field; the constant is one line.
2. `ready.verbs` lists `capture, sweep, abort, finish` and not `trial`: advertising a verb that is refused would make the view's fallback test lie. Phase 5 adds it.
3. `limits` in `ready` is `{lock, sudo}` (the person's in-effect caps, or the defaults for a new person).
4. A target skipped by patience is announced through `track.skipped` only; the child sends no separate event.
5. The Simple lap's ceiling is rule L's: three filled and one unresolved saves, one filled is `too_few`. A Simple user at 60 s with the centre and one target loses the lap.
