import QtQuick
import Quickshell

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

  // The Ask instance to launch through (common/Ask.qml).
  property var ask: null

  //   framing      nothing running yet; Start is on screen
  //   authorising  the session is starting: polkit's dialog is up
  //   countdown    3 · 2 · 1 at 800 ms, started by `ready`
  //   capturing    the IR sensor is open; Esc is ignored here
  //   verdict      what came back, with Again / Done
  //   closing      the session is finishing; the card is on its way out
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

  // --- copy, in one place ---------------------------------------------------

  readonly property var failText: ({
    "no_face": "No face found",
    "multiple_faces": "Only one person in view",
    "too_dark": "Too dark for the camera",
    "black_frames": "Too dark for the camera",
    "camera_busy": "The camera is in use — try again",
    "timeout": "Took too long"
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
    session.phase = "authorising"
    session.proc = session.ask.stream(
      session.ask.adminArgv(["enroll-session", session.name]),
      session.onEvent, session.onExit)
    if (!session.proc) {
      session.phase = "framing"
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
      session.beginCountdown()
      return
    }

    if (event.event === "capturing") {
      session.phase = "capturing"
      return
    }

    if (event.event === "captured") {
      session.captures += 1
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
      session.phase = "closing"
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
    session.phase = "framing"
  }

  // The message is set before the phase, so anything watching `phase` sees the
  // reason in the same change rather than one assignment later.
  function fail(code) {
    countdownTimer.stop()
    session.message = session.errorText[code] !== undefined
                      ? session.errorText[code] : "That did not work: " + code + "."
    session.phase = "framing"
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

  // A session that stood still for too long, or has simply been open too long.
  // It ends the way stdin closing does -- discarded, nothing written -- and
  // never with a commit: a card nobody is driving must not save a face on its
  // own, whatever it has in hand (plan-engine.md §12 risk 9).
  function expire(reason) {
    if (!session.proc) return
    console.log("graveklar.face", "the recording session expired:", reason)
    session.message = reason === "idle"
                      ? "Recording closed — nothing happened for a while."
                      : "Recording closed — a session does not stay open."
    session.discard()
  }

  function done() {
    if (!session.proc) { session.finished(session.saved); return }
    if (session.captures === 0) { session.discard(); return }
    session.phase = "closing"
    session.send({cmd: "done"})
  }

  // The only cancel there is. The session runs as root and cannot be signalled
  // by the user, so closing its stdin is what ends it -- and before `done` that
  // means nothing was written (plan-merged.md §2 rule 7, §2.4).
  function discard() {
    countdownTimer.stop()
    idleTimer.stop()
    lifeTimer.stop()
    if (!session.proc) { session.finished(false); return }
    session.phase = "closing"
    session.ask.cancel(session.proc)
  }

  // Esc, or the card being closed. Three different things depending on where
  // the session is (plan-gui.md §5.3).
  function requestClose() {
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
