import QtQuick
import Quickshell
import Quickshell.Io
import "common/dotscan.js" as Dot

// One `enroll-session`, as a state machine with no window around it
// (plan-merged.md §2.4, plan-gui.md §5.3).
//
// The card draws this; nothing here draws anything. That split is not tidiness:
// the timing rules below are the phase-4 gate, and a gate that can only be run
// by looking at a layer surface on somebody's screen is a gate nobody runs.
//
// The rule the whole file exists for:
//
//   **the countdown starts on `ready`, never on the click.**
//
// pkexec draws the owner's password dialog before the admin helper runs at all,
// so the first line the session prints -- `{"event":"ready"}` -- *is* the
// authorised signal (plan-merged.md §1 row 4). A countdown started when the
// button was pressed would be a countdown that finished while the dialog was
// still up, and the camera would fire at an empty chair. Ten seconds of typing
// a password still gets a full 3-2-1 afterwards.
Item {
  id: session

  // Set before start(). `label` is only used for a new person's `create`.
  property string name: ""
  property string appearance: "No glasses"
  property string label: ""
  property bool isNew: false

  // Whether the owner wants the full scan: the ring, one target at a time or all
  // twelve (plan-face-enroll.md sections 2 and 3). Off, this is the single
  // capture it always was; on, it is that only when the helper is older than
  // 3.1.0 and does not list `sweep` in `ready.verbs` (version skew, section 6).
  property bool scan: false
  // How many templates this appearance already holds (people.json `templates`).
  // More than Simple can produce means Simple would shrink it: rule R.
  property int stored: 0

  // The Ask instance to launch through (common/Ask.qml).
  property var ask: null

  // The single capture (a session with `scan` off, or one on an old helper):
  //   framing      nothing running yet; Start is on screen
  //   authorising  the session is starting: polkit's dialog is up
  //   countdown    3 · 2 · 1 at 800 ms, started by `ready`
  //   capturing    the IR sensor is open; Esc is ignored here
  //   verdict      what came back, with Again / Done
  //   closing      the session is finishing; the card is on its way out
  // The scan (`scan` on, helper 3.1.0 or later): `idle` in place of `framing`,
  //   centre       Advanced: the middle is the first target
  //   lap1         Advanced's first lap
  //   dot          Simple (3.2.0): the ball, from the centre to the last pose; what is
  //                taken and what the ball waits for are `dotHeld` and `dotState`
  // and `verdict` is a lap that ended in failure, with Try again. `swept` is not a
  // phase: the view stays in lap1 with the ring full and only its links change.
  property string phase: "framing"

  property int countdown: 0
  // good | weak | failed
  property string verdict: ""
  property string failCode: ""
  property string message: ""
  // How many appearances this session has committed to memory. It decides what
  // closing means: discard, or done (plan-gui.md §5.3).
  property int captures: 0
  property bool saved: false

  // WHICH appearances this session has in hand, and which one the last capture
  // was for. `captures` is a count and cannot answer either question, and the
  // card's picker has to: a person who has just taken "No glasses" and moved the
  // picker to "Reading glasses" is about to do something different from one who
  // left it where it was, and the button must not say the same word for both
  // (post-ship revision, plan-gui.md §5.3).
  property var capturedLabels: []
  property string lastAttempt: ""

  function hasCaptured(label) {
    return session.capturedLabels.indexOf(String(label)) >= 0
  }

  readonly property bool running: proc !== null
  property var proc: null

  signal finished(bool saved)

  readonly property int countdownFrom: 3
  readonly property int countdownStep: 800

  // The card's half of the bound on a standing authorisation (plan-engine.md
  // §12 risk 9). One password opens the session and every capture inside it is
  // unprompted, so a card left open on an unlocked machine is a way for whoever
  // walks up to add their face -- to a Sudo person, at that. The engine has
  // deadlines of its own (IDLE_SECONDS, SESSION_SECONDS); these are shorter, so
  // in normal use the card is what closes, with a reason on it, rather than the
  // session dying under it.
  readonly property int idleSeconds: 75
  readonly property int sessionSeconds: 240

  // --- the scan (plan-face-enroll.md sections 2, 3 and 6) ----------------------
  //
  // What the engine says, held as it says it: the view draws these and decides
  // nothing. A target is reached or filled by the engine alone; nothing
  // here (or anywhere on the client) says so.

  // The helper listed `sweep` in `ready.verbs`; false on an old helper, which
  // gets the single capture and a line saying why.
  property bool sweepFlow: false
  // ...and the helper did not: the single capture, in the scan's own view.
  property bool legacy: false
  readonly property string legacyNote: "Finish the update in a terminal for the full scan"
  // Table V's scan state, mirrored from events: ready | running | swept.
  property string scanState: "ready"

  property string trackState: ""
  property real u: 0
  property real v: 0
  // "centre", a bin 0..11, or null (Advanced: the head is in no unfilled wedge).
  property var target: "centre"
  property real centre: 0
  property var bins: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  property bool canFinish: false

  // --- the dot scan (Simple, 3.2.0) -------------------------------------------------
  // The helper listed `dot`. The ball is on the first pose it does not hold; Space (`capture`)
  // sends ONE press for it and everything after that is the helper's word: `dot` counts the
  // frames it has gathered, `dotted` says the pose is taken (and which are), `capture_failed`
  // says why it was not. Nothing here decides whether a face is good.
  //   waiting    the ball is on its pose, the ring breathes; Space presses
  //   capturing  a press is running; the ring closes in, never past what the helper has gathered
  //   landed     the pose was taken: the ring is closed for a beat, then the ball moves on
  //   done       all five are held
  property bool dotFlow: false
  property string dotState: "waiting"
  property var dotHeld: []
  property int dotGood: 0
  property int dotNeed: 3
  // The helper's code for why the last press did not work, "" when it did or none was made
  property string dotWhy: ""
  // Presses of this session that did not look like the first picture; at Dot.NOT_YOU_CAP the helper closes the session
  // How much bigger (percent) the helper said the face must look, with a too_far; 0 when it did not say
  property int dotShort: 0
  property int dotNotYou: 0
  property bool dotCapped: false
  // The pose the last `dotted` took: the ball stays on it for a beat before it moves on
  property string dotLast: ""
  property real dotPressedAt: 0
  property var dotPending: null
  readonly property string dotPose: session.dotFlow ? Dot.nextPose(session.dotHeld) : ""
  // What the ball on the screen (ScanBall.qml) draws: it is there while the dot scan is on its ball, it stays on the
  // pose just taken for the beat the ring is closed, and then moves on
  readonly property bool dotOnBall: session.dotFlow && session.phase === "dot"
  readonly property string dotBallState: session.dotState
  readonly property string dotBallPose: session.dotState === "landed" || session.dotPose === "" ? session.dotLast : session.dotPose
  // The card's Save: the centre, left and right are held (the helper's own floor)
  readonly property bool dotCanSave: session.dotFlow && Dot.canSave(session.dotHeld)
  readonly property bool dotAllHeld: session.dotFlow && session.dotHeld.length >= Dot.POSES.length

  property var targets: []
  property var filled: []
  property int kept: 0
  // Counted at every track whose state is the engine's accepted word. The scan
  // hairline re-arms on this and on nothing else.
  property int acceptedFrames: 0
  // Bumped by every failure that shakes the circle, so the view can react to the
  // same code twice in a row.
  property int failSerial: 0
  // The reason a lap ended without a result, for the outcome list's line. A
  // non-terminal one (`not_enough`, `sweep_stalled`) leaves the lap running.
  property string notice: ""
  property bool discarding: false
  readonly property string acceptedWord: "hold"

  // Whether the RGB preview may be open: from the moment Start is pressed until
  // a verdict, closing or a failure (plan-face-enroll.md 6a.1). A session that
  // is not the scan keeps the card's old behaviour (the card decides).
  readonly property bool previewWanted: !scan
      || phase === "authorising" || phase === "centre" || phase === "lap1" || phase === "lap2" || phase === "dot"
      || phase === "trial" || phase === "countdown" || phase === "capturing"

  // --- the mode: Simple or Advanced, remembered ----------------------------------
  //
  // One word in $XDG_STATE_HOME/omarchy-face/enrol-mode, read once when the
  // session is made and written when the link is used. The helper never reads it:
  // the mode travels in each `sweep` line and nowhere else. The read is never
  // waited for -- `timeout 1 head -c 16` in a process of its own -- so a FIFO or a
  // symlink planted at the path costs a second and not a hung view, and only the
  // first 16 bytes are ever looked at. Anything but the word `advanced` is
  // Simple.
  property string mode: "simple"
  // Rule R: Simple may not replace a set it cannot match, so for such an
  // appearance the mode is Advanced whatever the file says (the file is not
  // rewritten).
  readonly property bool simpleAllowed: stored <= 5
  readonly property string activeMode: simpleAllowed ? mode : "advanced"
  // Once Start is pressed the mode is the lap's and the link does nothing.
  readonly property bool modeFixed: phase !== "idle"

  // Where the state home is. Under a harness (OMARCHY_FACE_DEV_BIN) it is empty
  // unless the harness names a state home of its own, as RemoveView's is.
  readonly property string modeDir: {
    if ((Quickshell.env("OMARCHY_FACE_DEV_BIN") || "") !== "") {
      var sandbox = Quickshell.env("OMARCHY_FACE_DEV_STATE_HOME") || ""
      return sandbox === "" ? "" : sandbox + "/omarchy-face"
    }
    var base = Quickshell.env("XDG_STATE_HOME") || ""
    if (base === "") {
      var home = Quickshell.env("HOME") || ""
      if (home === "") return ""
      base = home + "/.local/state"
    }
    return base + "/omarchy-face"
  }
  readonly property string modePath: modeDir !== "" ? modeDir + "/enrol-mode" : ""

  function parseMode(text) {
    return String(text || "").trim().slice(0, 16) === "advanced" ? "advanced" : "simple"
  }

  function setMode(word) {
    if (session.modeFixed || (word !== "simple" && word !== "advanced")) return
    if (word === "simple" && !session.simpleAllowed) return
    session.modeTouched = true
    session.mode = word
    session.writeMode(word)
  }

  // A rename over the path, not a write through it: a symlink or a FIFO planted
  // there is replaced and never opened. An unwritable state home fails silently.
  function writeMode(word) {
    if (session.modePath === "" || modeWriter.running) return
    modeWriter.command = ["timeout", "2", "sh", "-c",
      'mkdir -p -- "$1" 2>/dev/null && printf %s "$3" >"$1/.enrol-mode.$$" 2>/dev/null ' +
      '&& mv -f -- "$1/.enrol-mode.$$" "$2" 2>/dev/null; rm -f -- "$1/.enrol-mode.$$" 2>/dev/null; true',
      "sh", session.modeDir, session.modePath, word]
    modeWriter.running = true
  }

  function readMode() {
    if (session.modePath === "") return
    modeReader.command = ["timeout", "1", "head", "-c", "16", "--", session.modePath]
    modeReader.running = true
  }

  Process { id: modeWriter }

  Process {
    id: modeReader
    stdout: StdioCollector {
      onStreamFinished: {
        // Only while the view is still waiting to be asked: a word that arrives
        // after Start must not change a lap that has begun.
        if (session.phase === "idle" && !session.modeTouched) session.mode = session.parseMode(text)
      }
    }
  }
  property bool modeTouched: false

  Component.onCompleted: {
    if (session.scan && session.phase === "framing") session.phase = "idle"
    if (session.scan) session.readMode()
  }

  // --- copy, in one place ---------------------------------------------------

  readonly property var failText: ({
    "no_face": "No face found",
    "multiple_faces": "Only one person in view",
    "too_dark": "Too dark for the camera",
    "black_frames": "Too dark for the camera",
    "camera_busy": "The camera is in use — try again",
    "timeout": "Took too long",
    "too_few": "Only a few positions were reached. Try again.",
    "lap_timeout": "That took too long. Nothing was saved.",
    "bad_sweep": "Something went wrong. Try again.",
    "changed": "That was not you"
  })

  readonly property var errorText: ({
    "exists": "Somebody is already called that.",
    "invalid_name": "That name cannot be used.",
    "invalid_label": "That name is too long, or has a line break in it.",
    "person_limit": "This machine already knows as many people as Face keeps.",
    "appearance_limit": "Three appearances is the most.",
    "store_corrupt": "Face's people store is damaged; nothing was changed.",
    "not_installed": "Face's system files are not installed.",
    "not_owner": "Only this machine's owner can record a face.",
    "busy": "Face is busy — try again in a moment."
  })

  function verdictText() {
    if (session.verdict === "good") return "Recognised " + session.who() + " comfortably."
    if (session.verdict === "weak") return "Recognised, but only just — try again in different light"
    if (session.verdict === "failed")
      return session.failText[session.failCode] !== undefined
             ? session.failText[session.failCode] : "That did not work"
    return ""
  }

  function who() { return session.label !== "" ? session.label : session.name }

  // --- the session ----------------------------------------------------------

  function start() {
    if (session.proc || !session.ask) return
    session.message = ""
    session.verdict = ""
    session.failCode = ""
    session.notice = ""
    session.discarding = false
    session.dotNotYou = 0
    session.dotCapped = false
    session.phase = "authorising"
    session.proc = session.ask.stream(
      session.ask.adminArgv(["enroll-session", session.name]),
      session.onEvent, session.onExit)
    if (!session.proc) {
      session.phase = session.scan ? "idle" : "framing"
      session.message = "Face's system files are not installed."
      return
    }
    idleTimer.restart()
    lifeTimer.restart()
  }

  function send(object) {
    if (session.proc) session.proc.send(object)
  }

  function onEvent(event) {
    if (!event || typeof event !== "object") return
    // Something happened, so the idle clock starts again. It measures a card
    // nobody is using, not an engine taking its time over a capture.
    if (session.proc) idleTimer.restart()

    // A caller-check refusal ({"error":…} with no `event`) and a session-fatal
    // error event are the same thing to the card: the session is over and the
    // reason is a code (§2.3, §2.4).
    if (event.event === "error" || (event.event === undefined && event.error !== undefined)) {
      session.fail(String(event.error || "error"))
      return
    }

    if (event.event === "ready") {
      // Authorised. A new person is created first, then the countdown -- the
      // record itself is not written until `done`, so this is still a session
      // that can be discarded without trace.
      if (session.isNew) session.send({cmd: "create", label: session.label})
      // The scan only on a helper that says it knows the verb: an older one would
      // ignore it and the view would wait for ever (section 6). Simple is the dot scan
      // (`dot`, 3.2.0), Advanced the sweep.
      if (session.scan && session.activeMode === "simple") {
        if (session.listsVerb(event.verbs, "dot")) {
          session.sweepFlow = true
          session.dotFlow = true
          session.startDots()
          return
        }
      } else if (session.scan && session.listsVerb(event.verbs, "sweep")) {
        session.sweepFlow = true
        session.sendSweep()
        return
      }
      if (session.scan) session.legacy = true
      session.beginCountdown()
      return
    }

    if (session.sweepFlow && session.onScanEvent(event)) return

    if (event.event === "capturing") {
      session.phase = "capturing"
      return
    }

    if (event.event === "captured") {
      session.captures += 1
      // The engine names the appearance it captured (§2.4); `lastAttempt` is the
      // fallback for an event that did not, and never a guess at the picker's
      // CURRENT value -- that may have been moved while the capture was running.
      var label = event.appearance !== undefined && String(event.appearance) !== ""
                  ? String(event.appearance) : session.lastAttempt
      if (label !== "" && !session.hasCaptured(label))
        session.capturedLabels = session.capturedLabels.concat([label])
      session.verdict = event.weak ? "weak" : "good"
      session.failCode = ""
      session.phase = "verdict"
      return
    }

    if (event.event === "capture_failed") {
      session.verdict = "failed"
      session.failCode = String(event.code || "timeout")
      session.phase = "verdict"
      return
    }

    if (event.event === "saved") {
      session.saved = true
      session.phase = "closing"
      return
    }

    if (event.event === "discarded") {
      // a session the helper closed on its own (too many presses that did not look like you) goes back
      // to the start, with the reason on it; the card stays so Start can be pressed again
      if (!session.dotCapped) session.phase = "closing"
      return
    }
  }

  // A session ends in one of three ways, and only two of them close the card.
  //
  //   saved      the store took it; the card closes and the popup opens on the
  //              person (plan-gui.md §5.3)
  //   discarded  the cancel; the card closes and nothing was written
  //   anything else -- a session-fatal error, a declined prompt, a helper that
  //              vanished -- puts the card back to `framing` WITH the reason on
  //              it, so Start can be pressed again. Closing the card on an
  //              error would take the error away with it.
  function onExit(result) {
    session.proc = null
    countdownTimer.stop()
    idleTimer.stop()
    lifeTimer.stop()
    if (session.saved) { session.finished(true); return }
    if (session.phase === "closing") { session.finished(false); return }
    if (result && result.outcome === "owner_declined") {
      // 126/127 from pkexec: the dialog was dismissed (plan-merged.md §1 row 2).
      session.message = "Not authorised."
    } else if (session.message === "") {
      session.message = "The recording stopped."
    }
    if (session.scan) {
      // Back to the start, with the reason on it and the circle shaking.
      session.sweepFlow = false
      session.dotFlow = false
      session.dotState = "waiting"
      landTimer.stop()
      beatTimer.stop()
      session.legacy = false
      session.scanState = "ready"
      session.failSerial += 1
    }
    session.phase = session.scan ? "idle" : "framing"
  }

  // The message is set before the phase, so anything watching `phase` sees the
  // reason in the same change rather than one assignment later.
  function fail(code) {
    countdownTimer.stop()
    session.message = session.errorText[code] !== undefined
                      ? session.errorText[code] : "That did not work: " + code + "."
    if (session.scan) session.failSerial += 1
    session.phase = session.scan ? "idle" : "framing"
  }

  function beginCountdown() {
    session.message = ""
    session.verdict = ""
    session.failCode = ""
    session.countdown = session.countdownFrom
    session.phase = "countdown"
    countdownTimer.restart()
  }

  // Again: another capture inside the same session, so no second prompt
  // (plan-merged.md §1 row 4). The appearance may have changed in the picker.
  function again() {
    if (session.phase !== "verdict") return
    idleTimer.restart()
    session.beginCountdown()
  }

  // --- the scan's verbs and events -------------------------------------------------

  function listsVerb(verbs, word) {
    if (!verbs || verbs.length === undefined) return false
    for (var i = 0; i < verbs.length; i++) if (String(verbs[i]) === word) return true
    return false
  }

  function clearRing() {
    session.trackState = ""
    session.u = 0
    session.v = 0
    session.target = "centre"
    session.centre = 0
    session.bins = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    session.canFinish = false
    session.filled = []
    session.kept = 0
    session.notice = ""
  }

  // Advanced's lap 1. The targets are all twelve, never a choice the view makes; root refuses
  // anything else (and a sweep in any other mode: Simple is the dot scan).
  function sendSweep() {
    session.clearRing()
    session.message = ""
    session.verdict = ""
    session.failCode = ""
    // A lap 1 replaces the appearance's pending set, so nothing is held until it
    // sweeps again.
    session.captures = 0
    session.capturedLabels = session.capturedLabels.filter(function (l) { return l !== session.appearance })
    session.scanState = "running"
    session.phase = "centre"
    session.lastAttempt = session.appearance
    var all = []
    for (var i = 0; i < 12; i++) all.push(i)
    session.send({cmd: "sweep", appearance: session.appearance, mode: session.activeMode, lap: 1, targets: all})
  }

  // "Scan again" after a lap that has ended (`swept`): lap 1 again at once, which
  // replaces the pending set (root's rule). Same session, same mode, no second
  // password. There is no way to restart a lap that is running: Cancel is EOF.
  function startOver() {
    if (session.dotFlow) { if (session.dotAllHeld) session.startDots(); return }
    if (session.sweepFlow && session.scanState === "swept") session.sendSweep()
  }

  // Try again after a lap that ended without a result.
  function tryAgain() {
    if (session.sweepFlow && session.scanState === "ready") session.sendSweep()
  }

  // Done while a lap runs (Advanced, once the engine says `canFinish`): `finish`.
  // The engine checks it again and answers `not_enough` if it was a race.
  function finish() {
    if (session.sweepFlow && session.scanState === "running" && session.activeMode === "advanced"
        && session.canFinish)
      session.send({cmd: "finish"})
  }

  // --- the dot scan's verbs and events --------------------------------------------------

  // The ball at the centre, nothing held. No helper message: the first press (Space) sends the
  // centre, and a centre that is taken replaces whatever the helper still holds (a retake).
  function startDots() {
    landTimer.stop()
    beatTimer.stop()
    session.clearRing()
    session.message = ""
    session.verdict = ""
    session.failCode = ""
    session.captures = 0
    session.capturedLabels = session.capturedLabels.filter(function (l) { return l !== session.appearance })
    session.dotHeld = []
    session.dotWhy = ""
    session.dotGood = 0
    session.dotPending = null
    session.dotState = "waiting"
    session.scanState = "running"
    session.phase = "dot"
    session.lastAttempt = session.appearance
  }

  // Space: one press, for the pose the ball is on. Only while the ball waits, so a second Space
  // (or a held key) during a press does nothing; the helper refuses it as well.
  function capture() {
    if (!session.dotFlow || session.phase !== "dot" || session.dotState !== "waiting" || !session.proc) return
    var pose = Dot.nextPose(session.dotHeld)
    if (pose === "") return
    session.dotWhy = ""
    session.dotShort = 0
    session.dotGood = 0
    session.dotState = "capturing"
    session.dotPressedAt = Date.now()
    session.lastAttempt = session.appearance
    session.send({cmd: "dot", appearance: session.appearance, pose: pose})
  }

  // `dotted` ends a press well, and it may arrive before the ring has had its second: the ring
  // is what the person sees, so the pose is applied when it has closed.
  function onDotEvent(event) {
    if (event.event === "dotting") {
      session.dotNeed = Number(event.need) || 3
      return true
    }
    if (event.event === "dot") {
      if (session.dotState === "capturing") session.dotGood = Number(event.good) || 0
      return true
    }
    if (event.event === "dotted") {
      session.dotPending = event
      var wait = Dot.RING_MS - (Date.now() - session.dotPressedAt)
      if (wait > 0) { landTimer.interval = wait; landTimer.restart() }
      else session.applyDotted()
      return true
    }
    if (event.event === "capture_failed") {
      var code = String(event.code || "timeout")
      // A press that did not work: the ring opens again and the line says why. Anything the
      // helper refuses at another moment (a Save before its floor) is not a press.
      if (session.dotState === "capturing") {
        session.dotWhy = code
        session.dotShort = code === "too_far" ? (Number(event.short) || 0) : 0
        session.dotState = "waiting"
        session.failSerial += 1
        if (code === "not_you") {
          session.dotNotYou += 1
          // The helper ends the session on this press (its cap, the same number): say why, in words, and
          // let the scan start over. The `discarded` that follows must not close the card.
          if (session.dotNotYou >= Dot.NOT_YOU_CAP) {
            session.dotCapped = true
            session.message = "That did not look like you too many times. Nothing was saved."
          }
        }
      }
      return true
    }
    return event.event === "aborted"
  }

  function applyDotted() {
    var event = session.dotPending
    session.dotPending = null
    if (!event) return
    session.dotHeld = event.poses || []
    session.dotLast = String(event.pose || "")
    session.dotGood = session.dotNeed
    session.dotWhy = ""
    session.kept = Number(event.kept) || 0
    session.captures = 1
    session.capturedLabels = session.hasCaptured(session.appearance)
                             ? session.capturedLabels : session.capturedLabels.concat([session.appearance])
    session.scanState = Dot.canSave(session.dotHeld) ? "swept" : "running"
    session.dotState = "landed"
    beatTimer.restart()
  }

  Timer { id: landTimer; onTriggered: session.applyDotted() }
  // The ring stays closed for a beat before the ball moves on
  Timer {
    id: beatTimer
    interval: 320
    onTriggered: if (session.dotState === "landed") session.dotState = session.dotAllHeld ? "done" : "waiting"
  }

  // The scan's events. True when taken.
  function onScanEvent(event) {
    if (session.dotFlow) return session.onDotEvent(event)
    if (event.event === "sweeping") {
      session.targets = event.targets || []
      return true
    }
    if (event.event === "track") {
      session.trackState = String(event.state || "")
      session.u = Number(event.u) || 0
      session.v = Number(event.v) || 0
      session.target = event.target === undefined ? null : event.target
      session.centre = Number(event.centre) || 0
      if (event.bins && event.bins.length === 12) session.bins = event.bins
      session.canFinish = event.canFinish === true
      if (session.trackState === session.acceptedWord) session.acceptedFrames += 1
      // The centre is the first target; anything after it is the lap proper.
      if (session.phase === "centre" && session.target !== "centre") session.phase = "lap1"
      return true
    }
    if (event.event === "swept") {
      session.scanState = "swept"
      session.filled = event.filled || []
      session.kept = Number(event.kept) || 0
      session.canFinish = false
      session.captures = 1
      session.capturedLabels = session.hasCaptured(session.appearance)
                               ? session.capturedLabels : session.capturedLabels.concat([session.appearance])
      session.notice = ""
      if (session.phase === "centre") session.phase = "lap1"
      return true
    }
    if (event.event === "aborted") {
      session.scanState = "ready"
      return true
    }
    if (event.event === "capture_failed") {
      var code = String(event.code || "timeout")
      // The two that leave the lap running: a line, no shake, no new phase.
      if (code === "not_enough") { session.notice = "A few more positions first."; return true }
      if (code === "sweep_stalled") { session.notice = "Try turning a little further."; return true }
      session.verdict = "failed"
      session.failCode = code
      session.scanState = "ready"
      session.failSerial += 1
      session.clearRingKeepNothing()
      session.phase = "verdict"
      return true
    }
    return false
  }

  // After a failed lap the ring empties; the reason stays in failCode.
  function clearRingKeepNothing() {
    var code = session.failCode
    session.clearRing()
    session.failCode = code
  }

  // A session that stood still for too long, or has simply been open too long.
  // It ends the way stdin closing does -- discarded, nothing written -- and
  // never with a commit: a card nobody is driving must not save a face on its
  // own, whatever it has in hand (plan-engine.md §12 risk 9).
  function expire(reason) {
    if (!session.proc) return
    console.log("kalinewb.face", "the recording session expired:", reason)
    session.message = reason === "idle"
                      ? "Recording closed — nothing happened for a while."
                      : "Recording closed — a session does not stay open."
    session.discard()
  }

  function done() {
    if (!session.proc) { session.finished(session.saved); return }
    // Table V: `done` is legal in `swept` and nowhere else in the scan.
    if (session.sweepFlow && session.scanState !== "swept") return
    if (session.captures === 0) { session.discard(); return }
    session.phase = "closing"
    session.send({cmd: "done"})
  }

  // The only cancel there is. The session runs as root and cannot be signalled
  // by the user, so closing its stdin is what ends it -- and before `done` that
  // means nothing was written (plan-merged.md §2 rule 7, §2.4).
  function discard() {
    landTimer.stop()
    beatTimer.stop()
    countdownTimer.stop()
    idleTimer.stop()
    lifeTimer.stop()
    if (!session.proc) { session.finished(false); return }
    session.discarding = true
    session.phase = "closing"
    session.ask.cancel(session.proc)
  }

  // Esc, or the card being closed. Three different things depending on where
  // the session is (plan-gui.md §5.3).
  function requestClose() {
    // The scan is abortable in every phase and Esc never saves: Done is the one
    // way to keep what was recorded (plan-face-enroll.md section 3, Phases).
    if (session.scan && !session.legacy) { session.discard(); return true }
    if (session.phase === "capturing") {
      session.message = "Almost done"
      return false
    }
    if (session.captures > 0) { session.done(); return true }
    session.discard()
    return true
  }

  Timer {
    id: countdownTimer
    interval: session.countdownStep
    repeat: true
    onTriggered: {
      session.countdown -= 1
      if (session.countdown > 0) return
      countdownTimer.stop()
      // The camera is opened here and nowhere else (§2.4: the IR sensor is
      // opened only on `capture`).
      session.lastAttempt = session.appearance
      session.send({cmd: "capture", appearance: session.appearance})
    }
  }

  Timer {
    id: idleTimer
    interval: session.idleSeconds * 1000
    onTriggered: session.expire("idle")
  }

  Timer {
    id: lifeTimer
    interval: session.sessionSeconds * 1000
    onTriggered: session.expire("the session limit")
  }

  // The backstop, for a session item destroyed while its process still runs.
  //
  // The Process is parented to the Ask instance, not to this item, so it does
  // not go when this does: without this line a destroyed session leaves an
  // authorised root `enroll-session` blocked on a stdin nothing will ever close
  // (plan-engine.md §12 risk 9). The callbacks are dropped first -- they are
  // methods of an object that is on its way out, and Ask calls the exit one
  // when the process finally goes.
  Component.onDestruction: {
    if (!session.proc) return
    var going = session.proc
    session.proc = null
    going.eventCb = null
    going.exitCb = null
    if (session.ask) session.ask.cancel(going)
  }
}
