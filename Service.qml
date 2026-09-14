import QtQuick
import Quickshell
import Quickshell.Io
import "common"

// The Face service: everything that has to outlive the popup.
//
// The popup is a bar widget, and every write under ~/.config/omarchy/plugins
// destroys and rebuilds every bar widget (plan-engine.md E13). This service is
// keepLoaded, so it survives that, and it is therefore where the plan puts the
// four duties that cannot be interrupted by a reload (plan-gui.md §1, §6):
//
//   · the sudo/identity indicator, which draws under the webcam (G5, G6)
//   · the recording card, which needs exclusive focus and would close a popup
//     anyway (G3)
//   · the lock-screen duties: `omarchy-face-lock sync` at shell start, the
//     30 s wrapper health check, and the single notification per new reason
//     (G6, plan-merged.md §1 row 13 and §3)
//
// Phase 4 builds the recording card, phase 5 the indicator and phase 6 the Test
// card. The lock duties still do nothing: in particular this does NOT run
// `sync` yet -- that call stages the wrapper into the plugins folder, and
// staging before the wrapper exists would be a reload for nothing.
Item {
  id: root

  // Injected by the host when the service is created (shell.qml:929-932).
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  // Where this plugin is checked out, taken from where this file was loaded --
  // the same reasoning as FacePanel.qml, and the same percent-decoding.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url).replace(/\/+$/, "")
  }

  // The card's own seam to the engine. The popup has one too; they are separate
  // objects in separate lifetimes, which is the whole point of this file.
  Ask {
    id: engine
    pluginDir: root.pluginDir
  }

  // One card at a time, and one session inside it.
  property var session: null
  property var card: null
  property string cardName: ""

  // `camera.rgb` for the preview, read once per card from the status helper --
  // a read, so no prompt and no camera is opened by asking (§2 rule 1).
  property string previewDevice: ""
  property var appearanceLabels: ["No glasses", "Everyday glasses", "Reading glasses"]

  // Closing a card ends the session inside it, in that order and never the
  // other way round.
  //
  // The session's Process belongs to `engine` below, not to the session item,
  // so destroying the item alone leaves an authorised root `enroll-session`
  // running with its stdin still open -- blocked in a read, invisible to
  // `state()`, and with nothing left in this file that can reach it to cancel
  // it. That is one password still buying captures with no card on screen
  // (plan-engine.md §12 risk 9), so the stdin is closed first.
  //
  // `closing` is not tidiness either: discard() on a session that has already
  // exited emits `finished`, whose handler calls this function again.
  property bool closing: false

  function closeCard() {
    if (root.closing) return
    root.closing = true
    var goingCard = root.card
    var goingSession = root.session
    root.card = null
    root.session = null
    root.cardName = ""
    if (goingCard) goingCard.destroy()
    if (goingSession) {
      if (goingSession.running) goingSession.discard()
      goingSession.destroy()
    }
    root.closing = false
  }

  // The card returns to the popup on the person it just recorded
  // (plan-gui.md §5.3: Done → `saved` → close, IPC open("person", name)).
  function openPerson(name) {
    openProcess.command = ["omarchy-shell", "graveklar.face", "open", "person", String(name)]
    openProcess.running = true
  }

  Process { id: openProcess }

  function startRecording(name, appearance, label, isNew) {
    root.closeCard()
    root.cardName = String(name)
    root.session = sessionComponent.createObject(root, {
      name: String(name),
      appearance: String(appearance || "No glasses"),
      label: String(label || name),
      isNew: !!isNew,
      ask: engine
    })
    if (!root.session) return "the session could not be created"
    root.session.finished.connect(function (saved) {
      var who = root.cardName
      root.closeCard()
      if (saved) root.openPerson(who)
    })
    // A card opening starts with nothing to report; from then on the indicator's
    // suppressed line is the card's, live, so a sudo that lands mid-countdown
    // says so on the surface the person is actually looking at.
    indicator.clearSuppressedNotice()
    root.card = cardComponent.createObject(root, {
      session: root.session,
      previewDevice: root.previewDevice,
      appearanceLabels: root.appearanceLabels,
      notice: Qt.binding(function () { return indicator.suppressedNotice })
    })
    if (!root.card) {
      root.closeCard()
      return "the card could not be created"
    }
    root.card.closed.connect(function () { root.closeCard() })
    return "ok"
  }

  // --- the Test card (plan-gui.md §5.2) ---------------------------------------
  //
  // One `omarchy-face-identity verify <name>` behind a card under the webcam.
  // It is a read of the world, not a change to it: nothing is unlocked, nothing
  // is written, and the only privilege involved is the daemon's own -- the
  // helper here runs as the user and is told apart from any other caller by
  // SO_PEERCRED at the far end (plan-engine.md §6.2).
  //
  // The verdict is an exit code and nothing else (§2.5). That is the whole
  // reason this can be a user-side helper: there is no output to trust.

  property var testCard: null
  property var testProcess: null
  property string testName: ""

  // The helper's own worst case is howdy's timeout plus the daemon's backstop;
  // twice that is a fault, and the answer to a fault is to stop looking rather
  // than leave a card on somebody's screen.
  readonly property int testSafetyMs: 20000
  readonly property int testDismissMs: 3200

  function startTest(name) {
    root.testName = String(name)
    // The label, from the same people.json the indicator already watches, so
    // the card says "Recognised Anna" rather than "Recognised anna".
    var shown = indicator.labelFor(root.testName)
    root.testCard = testComponent.createObject(root, {
      label: shown,
      phase: "checking",
      code: -1
    })
    if (!root.testCard) { root.testName = ""; return "the card could not be created" }
    root.testCard.stopped.connect(function () { root.closeTest() })
    root.testCard.closed.connect(function () { root.closeTest() })

    root.testProcess = engine.stream(engine.identityArgv(["verify", root.testName]),
                                     null, function (result) {
      root.testProcess = null
      if (!root.testCard) return
      testSafety.stop()
      root.testCard.code = result.code
      root.testCard.phase = "done"
      testDismiss.restart()
    })
    if (!root.testProcess) { root.closeTest(); return "the check could not be started" }
    testSafety.restart()
    return "ok"
  }

  // Closing the card stops the check, in that order and by the only means that
  // works: `verify` runs as the user, so it takes a signal -- and its death is
  // what makes the daemon let go of the camera (plan-merged.md §2.5).
  property bool closingTest: false

  function closeTest() {
    if (root.closingTest) return
    root.closingTest = true
    testSafety.stop()
    testDismiss.stop()
    var goingCard = root.testCard
    var goingProcess = root.testProcess
    root.testCard = null
    root.testProcess = null
    root.testName = ""
    if (goingProcess) engine.cancel(goingProcess)
    if (goingCard) goingCard.destroy()
    root.closingTest = false
  }

  Timer { id: testSafety; interval: root.testSafetyMs; onTriggered: root.closeTest() }
  Timer { id: testDismiss; interval: root.testDismissMs; onTriggered: root.closeTest() }

  // The preview node and the standard appearance labels both come from reads the
  // GUI already makes; asking for them when the card opens keeps this service
  // free of timers of its own.
  function refreshPreviewDevice(then) {
    engine.ask(engine.statusArgv(), "", function (result) {
      if (result.ok && result.parsed && result.parsed.camera)
        root.previewDevice = String(result.parsed.camera.rgb || "")
      if (then) then()
    })
  }

  IpcHandler {
    target: "graveklar.face.card"

    // Drive one enroll-session in a card under the webcam (G3).
    //
    // `isNew` is a string because Quickshell's IPC arguments are: the caller
    // sends "new" for a person who does not exist yet, and "" for one who does.
    function record(name: string, appearance: string, label: string, isNew: string): string {
      var who = String(name || "")
      if (who === "") return "record needs a name"
      // A card that is already open is never replaced. Any process running as
      // this account can send this call, and swapping the card out from under a
      // live session would leave that session's root process running with
      // nothing able to cancel it -- an authorisation for one person paying for
      // a recording of another (plan-engine.md §12 risk 9). The same name is
      // the card that is already on screen, so it answers ok.
      if (root.card) return root.cardName === who ? "ok" : "busy"
      // The preview device first, then the card: a card that opened before the
      // read answered would show "no preview on this laptop" for a second on a
      // laptop that has one.
      root.refreshPreviewDevice(function () {
        // The read is asynchronous, so a second `record` can have landed while
        // it was out. Whoever got a card up first keeps it.
        if (root.card) return
        root.startRecording(who, appearance, label, isNew === "new" || isNew === "true")
      })
      return "ok"
    }

    // "Test — does it recognise Anna now?" (plan-gui.md §5.2).
    function testMatch(name: string): string {
      var who = String(name || "")
      if (who === "") return "testMatch needs a name"
      // A recording card owns the same piece of screen and is mid-session; a
      // test would be a second card in one place and a second claim on the
      // camera, which the daemon would refuse as `camera_busy` anyway.
      if (root.card) return "busy"
      // The card that is already up for this person is the answer to asking
      // again; a different person replaces nothing while a check is running.
      if (root.testCard) return root.testName === who ? "ok" : "busy"
      return root.startTest(who)
    }

    // Close whatever card is on screen. For a pkexec'd session that means
    // closing its stdin, never a signal: it runs as root and the user cannot
    // signal it (plan-merged.md §2 rule 7).
    function cancel(): void {
      if (root.testCard) root.closeTest()
      if (root.session) root.session.requestClose()
      else if (root.card) root.closeCard()
    }

    // What this service is doing, as JSON. It is how a test observes a card
    // that has no window it can be asked about any other way.
    function state(): string {
      return JSON.stringify({
        loaded: true,
        omarchyPath: root.omarchyPath,
        duties: (root.card ? ["record"] : [])
          .concat(root.testCard ? ["test"] : [])
          .concat(indicator.visibleNow ? ["indicator"] : []),
        // What the indicator is saying, which is how a test asks a card that has
        // no window it could be questioned about any other way. It is also the
        // phase-5 gate's only handle on "the card names the program".
        indicator: {
          showing: indicator.visibleNow,
          state: indicator.authState,
          service: indicator.service,
          person: indicator.person,
          headline: indicator.headline,
          detail: indicator.detail,
          suppressedNotice: indicator.suppressedNotice
        },
        // The Test card, in the same shape and for the same reason: it has no
        // window a test could ask about any other way, and what it says is the
        // whole of what this phase adds to the GUI.
        test: root.testCard ? {
          name: root.testName,
          label: String(root.testCard.label),
          phase: String(root.testCard.phase),
          code: root.testCard.code,
          headline: String(root.testCard.headline)
        } : null,
        card: root.card ? {
          name: root.cardName,
          phase: root.session ? String(root.session.phase) : "",
          appearance: root.session ? String(root.session.appearance) : "",
          countdown: root.session ? root.session.countdown : 0,
          captures: root.session ? root.session.captures : 0,
          verdict: root.session ? String(root.session.verdict) : "",
          message: root.session ? String(root.session.message) : ""
        } : null
      })
    }
  }

  // The indicator (G5). It draws only while an authentication is actually in
  // flight, and it stands down while either card is up: the Test card is a card
  // in the same place saying more about the same check -- the daemon writes
  // `identity` states for it, and the indicator drawing them too would be the
  // same event reported twice, once badly (plan-merged.md §1 row 11).
  Indicator {
    id: indicator
    suppressed: root.card !== null || root.testCard !== null
  }

  Component { id: sessionComponent; RecordSession {} }
  Component { id: cardComponent;    RecordCard {} }
  Component { id: testComponent;    TestCard {} }

  Component.onCompleted: console.log("graveklar.face", "service loaded")
}
