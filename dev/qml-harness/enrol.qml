import QtQuick
import QtQuick.Window
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "face" as Face
import "face/common/dotscan.js" as Dot2

// The enrol view, offscreen, for dev/e3-enrol-view.sh (plan-face-enroll.md
// section 7.4, Phase 4). The REAL EnrolView.qml, DotCard.qml and RecordSession.qml,
// against the running Omarchy's qs.Commons and qs.Ui, driven by a FAKE root session
// that enforces table V: it answers `dot` and `done` the way the real parent does,
// refuses the verbs of the Advanced scan (3.3.0 removed it) and counts every verb the
// table refuses, and is fed the helper's events by the scripts below. Nothing is
// asked of a camera: the preview the circle would hold is a counting stand-in,
// so "no camera in idle" is a count of zero and not a promise.
//
//   E3_CASE   dot | dot-esc | dot-fail | dot-screen | dot-cap | dot-ring | dot-reduced | dot-demo |
//             dot-skew | dot-skew-326 | plain | fence | island | island-reduced | scrim | scrim-reduced | strip
//   E3_OUT_W, E3_OUT_H  the output the ball is drawn on (dot-screen)
//   E3_OUT     strip: the directory the PNGs go to
//   E3_ACCENT  the accent the harness theme uses (default: the theme's own)
//
// It prints `HARNESS key value` lines.
ShellRoot {
  id: shellRoot

  readonly property string caseName: Quickshell.env("E3_CASE") || "simple"
  // The output the ball is drawn on, for the cases that look at it
  readonly property int outW: Number(Quickshell.env("E3_OUT_W") || "1600")
  readonly property int outH: Number(Quickshell.env("E3_OUT_H") || "900")
  readonly property string outDir: Quickshell.env("E3_OUT") || "/tmp"
  readonly property string accentEnv: Quickshell.env("E3_ACCENT") || ""
  readonly property bool reducedCase: caseName === "island-reduced" || caseName === "scrim-reduced" || caseName === "dot-reduced"
  // The island cases draw the whole card body (ScanIsland.qml), no window around it.
  readonly property bool islandCase: caseName === "strip" || caseName === "island" || caseName === "island-reduced" || caseName === "scrim" || caseName === "scrim-reduced"

  function log(key, value) { console.log("HARNESS " + key, value) }

  // ---- the harness's own palette: the card's, -------------------------
  QtObject {
    id: harnessColors
    readonly property color foreground: "#ffffff"
    readonly property color secondary: Qt.darker("#ffffff", 1.55)
    readonly property color accent: shellRoot.accentEnv !== "" ? shellRoot.accentEnv : Commons.Color.accent
    readonly property color urgent: "#ff6b6b"
    readonly property string fontFamily: Style.font.family
    property bool reducedMotion: shellRoot.reducedCase
    function radiusFor(size) { return Style.cornerRadius }
  }

  // ---- a fake root session ------------------------------------------------------------
  property var sent: []
  property int violations: 0
  property int eofs: 0
  property string fakeState: "ready"
  property var fakeProc: null
  property var verbs: ["capture", "dot"]
  // The poses the fake root holds (the dot scan), as the real parent's `dotted` event lists them
  property var fakeHeld: []

  function emit(event) { if (fakeProc && fakeProc.eventCb) fakeProc.eventCb(event) }

  function respond(c) {
    var s = shellRoot.fakeState
    if (c.cmd === "create") return
    if (c.cmd === "sweep" || c.cmd === "trial" || c.cmd === "usual" || c.cmd === "finish" || c.cmd === "abort") {
      // 3.3.0: the Advanced scan's verbs are refused by the helper; this card never sends them
      violations++
      emit({event: "capture_failed", code: "bad_sweep"})
      return
    }
    if (c.cmd === "dot") {
      // The parent's own rules: legal in ready and swept, never while one runs; the centre first
      var poses = ["centre", "left", "top", "right", "bottom"]
      if (!((s === "ready" || s === "swept") && poses.indexOf(c.pose) >= 0
            && (c.pose === "centre" || shellRoot.fakeHeld.indexOf("centre") >= 0))) {
        violations++
        emit({event: "capture_failed", code: "bad_sweep"})
        return
      }
      if (c.pose === "centre") shellRoot.fakeHeld = []
      fakeState = "running"
      emit({event: "dotting", pose: c.pose, need: 3})
      return
    }
    if (c.cmd === "done") {
      var held = shellRoot.fakeHeld
      var floor = held.length === 0 || (held.indexOf("centre") >= 0 && held.indexOf("left") >= 0 && held.indexOf("right") >= 0)
      if (s !== "swept" || !floor) { violations++; emit({event: "capture_failed", code: "bad_sweep"}); return }
      emit({event: "saved", person: {name: "anna"}})
      var p = fakeProc
      fakeProc = null
      if (p && p.exitCb) p.exitCb({outcome: "ok", code: 0})
      return
    }
    if (c.cmd === "capture") return          // legacy: the script answers it
  }

  QtObject {
    id: fakeAsk
    function adminArgv(args) { return ["omarchy-face-admin"].concat(args) }
    function stream(argv, onEvent, onExit) {
      var proc = {
        eventCb: onEvent, exitCb: onExit, argv: argv,
        send: function (obj) { shellRoot.sent = shellRoot.sent.concat([obj]); shellRoot.respond(obj) }
      }
      shellRoot.fakeProc = proc
      shellRoot.fakeState = "ready"
      return proc
    }
    // EOF before `done`: a discard. The real session answers `discarded` and exits.
    function cancel(proc) {
      shellRoot.eofs += 1
      shellRoot.sent = shellRoot.sent.concat([{cmd: "EOF"}])
      eofTimer.restart()
    }
  }
  Timer {
    id: eofTimer
    interval: 20
    onTriggered: {
      shellRoot.emit({event: "discarded"})
      var p = shellRoot.fakeProc
      shellRoot.fakeProc = null
      if (p && p.exitCb) p.exitCb({outcome: "ok", code: 0})
    }
  }

  // ---- the camera stand-in: counts, never opens ---------------------------------------
  property int cameras: 0
  Component {
    id: stub
    Rectangle {
      color: "#334"
      Component.onCompleted: shellRoot.cameras += 1
      Component.onDestruction: shellRoot.cameras -= 1
    }
  }

  // ---- the session and the view ------------------------------------------------------------
  property var sessionOverride: null
  readonly property var session: sessionLoader.item
  property bool scanSession: caseName !== "plain"
  property int finishedCount: 0
  property bool finishedSaved: false

  Loader {
    id: sessionLoader
    active: true
    sourceComponent: Component {
      Face.RecordSession {
        name: "anna"
        appearance: "No glasses"
        label: "Anna"
        ask: fakeAsk
        scan: shellRoot.scanSession
        onFinished: function (saved) { shellRoot.finishedCount += 1; shellRoot.finishedSaved = saved }
      }
    }
  }

  property bool live: true
  Window {
    id: win
    visible: true
    width: 400
    height: 760
    // The strip draws on a grey "desktop" so the black silhouette reads.
    color: shellRoot.islandCase ? "#3a3a46" : "#000000"

    // The dimming behind the island (the cases "scrim" and "scrim-reduced"): ScrimLayer follows the island's drop.
    Face.ScrimLayer {
      id: scrimLayer
      anchors.fill: parent
      visible: shellRoot.caseName.indexOf("scrim") === 0
      presence: shellRoot.island ? shellRoot.island.presence : 0
    }

    // A scrim that has nothing to dim: it must take no input.
    Face.ScrimLayer {
      id: idleScrim
      anchors.fill: parent
      visible: false
      presence: 0
    }

    // The ball's surface: output-sized, far from the card and outside the window's own 400 px, as a real output is
    Face.BallScreen {
      id: ballScreen
      objectName: "ballScreen"
      x: 500
      y: 0
      width: shellRoot.outW
      height: shellRoot.outH
      session: shellRoot.session
      reducedMotion: shellRoot.reducedCase
    }

    // The geometry case: the same ball layer at five different output sizes (a laptop, a QHD and a small panel, a
    // portrait output, an ultrawide), nothing of the card in any of them
    Repeater {
      id: outputs
      model: shellRoot.caseName === "dot-screen" ? [[1920, 1080], [2560, 1440], [1366, 768], [1080, 1920], [3840, 1080]] : []
      Face.BallLayer {
        required property var modelData
        required property int index
        objectName: "output" + index
        x: 0
        y: 0
        width: modelData[0]
        height: modelData[1]
        shown: true
        reducedMotion: true
        colors: harnessColors
      }
    }

    Loader {
      id: viewLoader
      active: sessionLoader.item !== null
      width: shellRoot.islandCase ? 400 : 320
      height: shellRoot.islandCase ? 640 : 0
      x: shellRoot.islandCase ? 0 : 20
      y: shellRoot.islandCase ? 0 : 10
      sourceComponent: shellRoot.islandCase ? islandComponent : viewComponent
    }
  }

  Component {
    id: viewComponent
    Face.EnrolView {
      session: shellRoot.session
      colors: harnessColors
      previewDevice: "/dev/video-fake"
      previewComponent: stub
      live: shellRoot.live
      onCloseRequested: shellRoot.session.requestClose()
    }
  }

  // The card's body: the island in the notch's silhouette (8 and 8, this user's
  // shell.json), centred in a 400 px strip. No preview device: the offscreen scene
  // graph has no shader effects, so a layered (masked) circle paints nothing there.
  property int retractedCount: 0
  Component {
    id: islandComponent
    Face.ScanIsland {
      session: shellRoot.session
      colors: harnessColors
      previewDevice: ""
      live: shellRoot.live
      bottomRadius: 8
      filletRadius: 8
      onCloseRequested: shellRoot.session.requestClose()
      onRetracted: shellRoot.retractedCount += 1
    }
  }
  readonly property var island: shellRoot.islandCase ? viewLoader.item : null
  readonly property var view: viewLoader.item ? (viewLoader.item.enrolView || viewLoader.item) : null

  // ---- looking at the view -------------------------------------------------------------------
  // The item of that name that is on screen wins, else the first there is.
  function collect(item, name, out) {
    if (!item) return
    if (item.objectName === name) out.push(item)
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) collect(kids[i], name, out)
  }
  function find(item, name) {
    var all = []
    collect(item, name, all)
    for (var i = 0; i < all.length; i++) if (all[i].visible) return all[i]
    return all.length > 0 ? all[0] : null
  }
  function demoItem() { return find(view, "demo") }
  function named(name) { return find(view, name) }

  function r1(x) { return String(Math.round(x * 100) / 100) }
  function linkState(name) { var l = named(name); return l ? (l.visible ? "1" : "0") : "-" }
  function line() { return named("line").text }
  function sentCmds() { return sent.map(function (c) { return c.cmd }).join(",") }

  function feed(ev) {
    if (ev.event === "dotted") { fakeState = "swept"; fakeHeld = ev.poses.slice() }
    if (ev.event === "capture_failed")
      fakeState = fakeHeld.length > 0 ? "swept" : "ready"
    emit(ev)
  }
  function ready(withVerbs) {
    var e = {event: "ready", person: null}
    if (withVerbs) e.verbs = shellRoot.verbs
    feed(e)
  }
  // ---- the scripts ----------------------------------------------------------------------------------
  property var steps: []
  property int stepAt: 0
  function at(fn, wait) { steps.push({fn: fn, wait: wait === undefined ? 70 : wait}) }
  // A step may return a function: the runner then waits (up to 20 s) until it is true.
  property var waitCond: null
  property real waitDeadline: 0
  Timer {
    id: stepper
    interval: 70
    onTriggered: {
      if (shellRoot.waitCond) {
        var done = false
        try { done = shellRoot.waitCond() } catch (e) { done = true }
        if (!done && Date.now() < shellRoot.waitDeadline) { stepper.interval = 50; stepper.restart(); return }
        if (!done) shellRoot.log("wait-timeout", "step " + (shellRoot.stepAt - 1))
        shellRoot.waitCond = null
      }
      if (shellRoot.stepAt >= shellRoot.steps.length) { Qt.exit(0); return }
      var st = shellRoot.steps[shellRoot.stepAt++]
      var ret = null
      try { ret = st.fn() } catch (e) { shellRoot.log("exception", String(e) + " at step " + (shellRoot.stepAt - 1)) }
      if (typeof ret === "function") { shellRoot.waitCond = ret; shellRoot.waitDeadline = Date.now() + 20000 }
      stepper.interval = st.wait
      stepper.restart()
    }
  }
  Timer {
    interval: 110000
    running: true
    onTriggered: { shellRoot.log("timeout", "the script did not finish"); Qt.exit(2) }
  }

  Component.onCompleted: {
    shellRoot.build()
    stepper.start()
  }

  function build() {
    var c = caseName
    if (c === "dot") buildDot()
    else if (c === "dot-esc") buildDotEsc()
    else if (c === "dot-fail") buildDotFail()
    else if (c === "dot-ring") buildDotRing()
    else if (c === "dot-screen") buildDotScreen()
    else if (c === "dot-cap") buildDotCap()
    else if (c === "dot-reduced") buildDotReduced()
    else if (c === "dot-demo") buildDotDemo()
    else if (c === "dot-skew") buildDotSkew()
    else if (c === "dot-skew-326") buildDotSkew326()
    else if (c === "skew") buildSkew()
    else if (c === "plain") buildPlain()
    else if (c === "fence") buildFence()
    else if (c === "strip") buildStrip()
    else if (c === "island" || c === "island-reduced") buildIsland()
    else if (c === "scrim" || c === "scrim-reduced") buildScrim()
  }

  // ---- the dot scan (Simple) -------------------------------------------------------------------------
  // The card's stage (the camera's circle and the idle demo)...
  function stageItem() { return named("stage") }
  // ...and the ball on the SCREEN: BallScreen is the output-sized surface ScanBall.qml's window holds, here at a size
  // of the script's choosing (E3_OUT_W x E3_OUT_H, 1600 x 900 by default) and nowhere near the card.
  function ballItem() { return ballScreen.balls.ball }
  // Where the ball is on the output, in px from its top left, and what its ring is doing
  function ballInfo() {
    var b = ballItem()
    return {x: Math.round(b.x), y: Math.round(b.y), r: r1(ring2().r), close: r1(b.close),
            state: b.ballState, pose: ballScreen.balls.pose, op: r1(b.opacity)}
  }
  function atPose(p) {
    var t = Dot2.screenStation(p, shellRoot.outW, shellRoot.outH)
    var b = ballInfo()
    return Math.abs(b.x - t.x) < 2 && Math.abs(b.y - t.y) < 2
  }
  function ring2() { return find(ballItem(), "ballRing") }
  function dotLinks() {
    return ["cancelLink", "startLink", "saveLink", "doneLink", "againLink"]
      .map(function (n) { return n.replace("Link", "") + "=" + linkState(n) }).join(" ")
  }
  function keyInfo() {
    var h = named("spaceHint"), k = named("spaceKey")
    return (h.visible ? "shown" : "hidden") + " opacity " + r1(h.opacity) + " enabled " + k.enabled + " text " + named("spaceHintText").text
  }
  function marks() {
    return ["centre", "left", "top", "right", "bottom"].map(function (p) {
      var m = find(ballScreen.balls, "screenStation-" + p)
      return p + ":" + (m.taken ? "taken" : "open") + "/" + r1(m.opacity)
    }).join(" ")
  }
  function pressSpace() { view.capture() }
  function dotted(pose, held) {
    feed({event: "dotted", pose: pose, poses: held, kept: held.length})
  }
  function untilState(state) { return function () { return session.dotState === state } }
  function pressAndTake(pose, held) {
    at(function () { pressSpace() }, 80)
    at(function () { feed({event: "dot", pose: pose, good: 1, need: 3}) }, 60)
    at(function () { feed({event: "dot", pose: pose, good: 3, need: 3}); dotted(pose, held) }, 60)
    // the pose is applied when the ring has had its second; then a beat; then the ball moves on
    at(function () { return function () { return session.dotHeld.length === held.length && session.dotState !== "capturing" } }, 20)
    at(function () { return function () { return session.dotState === "waiting" || session.dotState === "done" } }, 20)
    at(function () { return function () {
      var b = ballInfo()
      return session.dotPose === "" || atPose(session.dotPose)
    } }, 20)
  }

  function buildDot() {
    var T = {}
    at(function () {
      log("idle-phase", session.phase + " " + session.dotFlow)
      log("idle-card", "legacy=" + view.legacy + " dotCard " + named("dotCard").visible)
      log("idle-line", line())
      log("idle-glyph", named("glyph").visible + " demo " + (demoItem() !== null && demoItem().visible) + " caption '" + named("caption").text + "'")
      log("idle-cameras", cameras + " previewOn " + view.previewOn + " previewLoader " + (named("previewLoader").item === null ? "empty" : "full"))
      log("idle-links", dotLinks())
      log("idle-key", keyInfo())
      log("idle-no-choice", (find(view, "mode-simple") === null) + " " + (find(view, "mode-advanced") === null) + " " + (find(view, "modeChoice") === null))
      log("idle-screen", "shown " + ballScreen.balls.shown + " opacity " + r1(ballScreen.balls.opacity) + " output " + shellRoot.outW + "x" + shellRoot.outH)
      log("idle-state", session.scanState + " sent " + sent.length)
      log("idle-descr", stageItem().Accessible.description)
    }, 900)
    at(function () { session.start() })
    at(function () {
      log("auth-phase", session.phase)
      log("auth-cameras", cameras + " " + view.previewOn)
      log("auth-line", line())
      log("auth-links", dotLinks())
      log("auth-key", keyInfo())
      // Space before the helper has said ready does nothing
      pressSpace()
      log("auth-space-sent", sent.length)
      ready(true)
    })
    at(function () {
      log("ready-phase", session.phase + " flow " + session.dotFlow + " " + session.dotState + " pose " + session.dotPose)
      log("ready-sent", JSON.stringify(sent))
      log("ready-line", line())
      log("ready-links", dotLinks())
      log("ready-key", keyInfo())
      log("ready-ball", JSON.stringify(ballInfo()))
      log("ready-cameras", cameras)
      log("ready-marks", marks())
      // the ring breathes: its radius changes while the ball waits
      T.radii = []
    }, 120)
    for (var b = 0; b < 8; b++) at(function () { T.radii.push(ring2().r) }, 250)
    at(function () {
      var lo = Math.min.apply(null, T.radii), hi = Math.max.apply(null, T.radii)
      log("breath", "min " + r1(lo) + " max " + r1(hi) + " within " + (lo >= 27.9 && hi <= 33.7) + " moves " + (hi - lo > 1))
      pressSpace()
    }, 10)
    at(function () {
      log("press-sent", JSON.stringify(sent.slice(-1)))
      log("press-state", session.dotState + " " + session.dotPose)
      log("press-line", line())
      log("press-key", keyInfo())
      // a second Space during the press does nothing (and so does a click on the key, which is off)
      pressSpace()
      named("spaceKey").clicked()
      log("press-twice", sent.length + " " + sentCmds())
      T.sentBefore = sent.length
    }, 80)
    // the ring closes in while frames come: one of three is not enough to close it
    at(function () { feed({event: "dot", pose: "centre", good: 1, need: 3}) }, 400)
    at(function () {
      log("closing-1of3", JSON.stringify(ballInfo()))
      log("closing-good", session.dotGood + " of " + session.dotNeed)
      feed({event: "dot", pose: "centre", good: 2, need: 3})
    }, 700)
    at(function () {
      var i = ballInfo()
      log("closing-2of3", i.close + " " + i.state + " held " + session.dotHeld.length + " line " + line())
      feed({event: "dot", pose: "centre", good: 3, need: 3})
    }, 300)
    // all three gathered but no `dotted` yet: the ring is held short of closed (the helper has not said)
    at(function () {
      var i = ballInfo()
      log("closing-3of3-undotted", i.close + " " + i.state + " pose " + session.dotPose)
      dotted("centre", ["centre"])
    }, 120)
    at(function () {
      log("landed", session.dotState + " held " + session.dotHeld.join(",") + " line " + line() + " " + JSON.stringify(ballInfo()))
      log("landed-links", dotLinks())
      log("landed-captures", session.captures + " " + session.capturedLabels.join(","))
      // Space in the beat does nothing
      pressSpace()
      log("landed-space", sent.length === T.sentBefore ? "ignored" : "sent")
    }, 100)
    at(function () { return function () { return session.dotState === "waiting" } }, 20)
    at(function () { return function () { return atPose("left") } }, 20)
    at(function () {
      log("left-ball", JSON.stringify(ballInfo()))
      log("left-line", line())
      log("left-marks", marks())
      log("left-key", keyInfo())
      pressSpace()
    }, 100)
    at(function () {
      log("left-sent", JSON.stringify(sent.slice(-1)))
      // somebody else: the helper says not_you, the ring opens again and the ball stays
      feed({event: "dot", pose: "left", good: 2, need: 3})
    }, 120)
    at(function () { feed({event: "capture_failed", code: "not_you"}) }, 400)
    at(function () { return function () { return ballInfo().close < 0.05 } }, 20)
    at(function () {
      log("fail-notyou", session.dotState + " | " + line() + " | " + JSON.stringify(ballInfo()) + " | " + keyInfo() + " | colour " + (named("line").color.toString() === harnessColors.urgent.toString() ? "urgent" : "normal"))
      log("fail-held", session.dotHeld.join(",") + " links " + dotLinks())
      pressSpace()
    }, 150)
    at(function () {
      log("retry-sent", JSON.stringify(sent.slice(-1)) + " line " + line())
      feed({event: "dot", pose: "left", good: 3, need: 3}); dotted("left", ["centre", "left"])
    }, 150)
    at(function () { return function () { return session.dotPose === "top" && session.dotState === "waiting" } }, 20)
    at(function () { return function () { return atPose("top") } }, 20)
    at(function () {
      log("top-ball", JSON.stringify(ballInfo()))
      log("top-line", line())
      log("top-marks", marks())
    }, 50)
    pressAndTake("top", ["centre", "left", "top"])
    at(function () {
      log("right-ball", JSON.stringify(ballInfo()))
      log("right-line", line())
      log("right-links-before", dotLinks())
    }, 50)
    pressAndTake("right", ["centre", "left", "top", "right"])
    at(function () {
      log("bottom-ball", JSON.stringify(ballInfo()))
      log("bottom-line", line())
      log("bottom-links", dotLinks())
      log("bottom-marks", marks())
      pressSpace()
    }, 100)
    at(function () { feed({event: "capture_failed", code: "too_dark"}) }, 200)
    at(function () {
      log("bottom-fail", line() + " | " + dotLinks() + " | " + keyInfo())
      // a Save before all five (the centre, left and right are held): it asks the helper to save, nothing else
      T.sentBefore = sent.length
    }, 150)
    pressAndTake("bottom", ["centre", "left", "top", "right", "bottom"])
    at(function () {
      log("done-state", session.dotState + " all " + session.dotAllHeld + " line " + line() + " | " + dotLinks())
      log("done-ball", JSON.stringify(ballInfo()) + " check " + named("check").visible + " " + r1(named("check").drawn))
      log("done-marks", marks())
      log("done-state-scan", session.scanState + " " + session.captures)
      log("done-key", keyInfo())
      log("done-descr", stageItem().Accessible.description)
    }, 300)
    at(function () { named("againLink").clicked() })
    at(function () {
      log("again", session.dotState + " held " + session.dotHeld.length + " pose " + session.dotPose + " line " + line() + " | " + dotLinks())
      log("again-sent", "no new message: " + (sentCmds().split(",").filter(function (c) { return c === "dot" }).length) + " dots in all")
      log("again-state", session.scanState + " " + session.captures)
    }, 150)
    at(function () { return function () { return atPose("centre") } }, 20)
    // a Return before all five does nothing; the retake: the centre again
    at(function () { view.activate(); log("again-return", sentCmds().split(",").pop()); pressSpace() }, 100)
    at(function () { log("retake-sent", JSON.stringify(sent.slice(-1))); feed({event: "dot", pose: "centre", good: 3, need: 3}); dotted("centre", ["centre"]) }, 100)
    at(function () { return function () { return session.dotState === "waiting" && session.dotHeld.length === 1 } }, 20)
    pressAndTake("left", ["centre", "left"])
    pressAndTake("top", ["centre", "left", "top"])
    pressAndTake("right", ["centre", "left", "top", "right"])
    at(function () {
      log("save-shown", dotLinks() + " scanState " + session.scanState)
      // Return does not save a partial scan; the Save link does
      view.activate()
      log("save-return", sentCmds().split(",").pop())
      named("saveLink").clicked()
    }, 100)
    at(function () {
      log("save-sent", sent[sent.length - 1].cmd)
      log("save-finished", finishedCount + " " + finishedSaved)
      log("violations", violations)
      log("capture-never", sentCmds().indexOf("capture") < 0)
      log("sweep-never", sentCmds().indexOf("sweep") < 0)
      log("finish-never", sentCmds().indexOf("finish") < 0)
    }, 200)
  }

  // ---- Esc and Cancel in every state of the dot scan ---------------------------------------------------
  function buildDotEsc() {
    function fresh() {
      at(function () { shellRoot.finishedCount = 0; sessionLoader.active = false; sessionLoader.active = true; shellRoot.fakeHeld = [] }, 120)
    }
    at(function () { shellRoot.eofs = 0; session.requestClose() }, 200)
    at(function () { log("esc-idle", eofs + " " + finishedCount + " " + finishedSaved) })
    fresh()
    at(function () { session.start() })
    at(function () { eofs = 0; session.requestClose() }, 150)
    at(function () { log("esc-authorising", eofs + " " + session.phase + " " + finishedCount + " " + cameras) }, 200)
    fresh()
    at(function () { session.start() })
    at(function () { ready(true) })
    at(function () { eofs = 0; log("esc-waiting-phase", session.phase + " " + session.dotState); session.requestClose() }, 150)
    at(function () { log("esc-waiting", eofs + " " + finishedCount + " " + finishedSaved + " " + cameras + " last " + sentCmds().split(",").pop()) }, 200)
    // a press running: Esc cancels it, the camera goes
    fresh()
    at(function () { session.start() })
    at(function () { ready(true) })
    at(function () { pressSpace() }, 100)
    at(function () { eofs = 0; log("esc-capturing-phase", session.dotState); session.requestClose() }, 150)
    at(function () { log("esc-capturing", eofs + " " + finishedCount + " " + finishedSaved + " " + cameras) }, 200)
    // Cancel with the centre, left and right held (a Save was on offer): nothing is saved
    fresh()
    at(function () { session.start() })
    at(function () { ready(true) })
    at(function () { feed({event: "dotted", pose: "right", poses: ["centre", "left", "right"], kept: 3}) }, 100)
    at(function () { return function () { return session.dotState === "waiting" && session.dotHeld.length === 3 } }, 20)
    at(function () { log("esc-save-offered", dotLinks()); eofs = 0; named("cancelLink").clicked() }, 100)
    at(function () { log("esc-save", eofs + " " + finishedCount + " " + finishedSaved + " sent " + sentCmds().split(",").pop()) }, 200)
    // all five held: Esc still discards (it never saves); Done is the way to keep it
    fresh()
    at(function () { session.start() })
    at(function () { ready(true) })
    at(function () { feed({event: "dotted", pose: "bottom", poses: ["centre", "left", "top", "right", "bottom"], kept: 5}) }, 100)
    at(function () { return function () { return session.dotState === "done" } }, 20)
    at(function () { eofs = 0; log("esc-done-phase", session.dotState + " " + dotLinks()); session.requestClose() }, 100)
    at(function () { log("esc-done", eofs + " " + finishedCount + " " + finishedSaved) }, 200)
    // the "Nothing was saved" line stays until the session finishes
    fresh()
    at(function () { session.start() })
    at(function () { ready(true) })
    at(function () { session.discard() }, 5)
    at(function () { log("esc-line-discarding", line()) }, 5)
    at(function () { log("esc-end", violations) }, 150)
  }

  // ---- why a press did not work: the helper's codes, in plain words ---------------------------------------
  function buildDotFail() {
    var codes = ["no_face", "too_dark", "multiple_faces", "not_you", "black_frames", "too_far", "too_close", "face_cut_off", "face_tilted", "timeout", "camera_busy", "bad_sweep"]
    at(function () { session.start() }, 150)
    at(function () { ready(true) })
    codes.forEach(function (code) {
      at(function () { pressSpace() }, 80)
      at(function () { feed({event: "capture_failed", code: code}) }, 100)
      at(function () {
        log("fail-" + code, session.dotState + " | " + line() + " | held " + session.dotHeld.length + " pose " + session.dotPose + " | " + keyInfo())
      }, 60)
    })
    // an unknown code still says something plain
    at(function () { pressSpace() }, 80)
    at(function () { feed({event: "capture_failed", code: "from_the_future"}) }, 100)
    at(function () { log("fail-unknown", line()) }, 60)
    // a too small face with the helper's percent says how much bigger; with a percent on any other code it is ignored
    at(function () { pressSpace() }, 80)
    at(function () { feed({event: "capture_failed", code: "too_far", short: 14}) }, 100)
    at(function () { log("fail-short", line() + " | short " + session.dotShort) }, 60)
    at(function () { pressSpace() }, 80)
    at(function () { feed({event: "capture_failed", code: "no_face", short: 14}) }, 100)
    at(function () { log("fail-short-ignored", line() + " | short " + session.dotShort) }, 60)
    // a failed press leaves the held poses as they were, and the next press is for the same pose
    at(function () { pressSpace() }, 80)
    at(function () { feed({event: "dotted", pose: "centre", poses: ["centre"], kept: 1}) }, 80)
    at(function () { return function () { return session.dotState === "waiting" && session.dotHeld.length === 1 } }, 20)
    at(function () { pressSpace() }, 100)
    at(function () { feed({event: "capture_failed", code: "no_face"}) }, 100)
    at(function () { pressSpace() }, 100)
    at(function () {
      log("fail-same-pose", sent.slice(-2).map(function (c) { return c.pose }).join(",") + " held " + session.dotHeld.join(","))
      // a refusal that is not about a press (a Save before the floor) is not a failed press
      feed({event: "dotted", pose: "left", poses: ["centre", "left"], kept: 2})
    }, 100)
    at(function () { return function () { return session.dotState === "waiting" && session.dotHeld.length === 2 } }, 20)
    at(function () {
      var before = session.dotWhy
      feed({event: "capture_failed", code: "bad_sweep"})
      log("fail-not-a-press", before + "|" + session.dotWhy + " state " + session.dotState + " line " + line())
      log("fail-violations", violations)
    }, 100)
  }

  // ---- the ball goes to the screen's own edges, whatever the output and whatever the card ----------------------------
  function buildDotScreen() {
    var poses = ["centre", "left", "top", "right", "bottom"]
    at(function () { }, 400)
    poses.forEach(function (pose) {
      at(function () {
        for (var i = 0; i < outputs.count; i++) outputs.itemAt(i).pose = pose
      }, 60)
      at(function () {
        for (var i = 0; i < outputs.count; i++) {
          var o = outputs.itemAt(i)
          var b = o.ball
          log("out" + i + "-" + pose, o.width + "x" + o.height + " " + Math.round(b.x) + "," + Math.round(b.y))
        }
        // the ball on the session's own surface (the harness's output size), and the card's size, which has nothing to do with it
        log("screen-" + pose, shellRoot.outW + "x" + shellRoot.outH + " " + Math.round(ballScreen.balls.target.x) + "," + Math.round(ballScreen.balls.target.y))
      }, 20)
    })
    at(function () {
      // the whole ball (its ring at its widest) is inside the output at every station of every output
      var worst = 1e9
      for (var i = 0; i < outputs.count; i++) {
        var o = outputs.itemAt(i)
        var ring = (Dot2.REST + Dot2.BREATH) * Dot2.SCREEN_UNIT
        for (var k = 0; k < poses.length; k++) {
          var t = Dot2.screenStation(poses[k], o.width, o.height)
          worst = Math.min(worst, t.x - ring, o.width - t.x - ring, t.y - ring, o.height - t.y - ring)
        }
      }
      log("clearance", "least gap between the widest ring and the physical edge over all outputs: " + Math.round(worst) + " px")
      log("card", "the card's column is " + (named("dotCard") ? Math.round(named("dotCard").width) : -1) + " px wide whatever the output")
      log("sizes", "the margin is " + Dot2.SCREEN_MARGIN + " and the unit " + Dot2.SCREEN_UNIT)
    }, 20)
  }

  // ---- the helper closes a session after DOT_NOT_YOU_CAP presses that did not look like you ------------------------
  function buildDotCap() {
    at(function () { session.start() }, 150)
    at(function () { ready(true) })
    for (var i = 1; i <= 4; i++) {
      at(function () { pressSpace() }, 80)
      at(function () { feed({event: "capture_failed", code: "not_you"}) }, 80)
    }
    at(function () {
      log("cap-4", "notyou " + session.dotNotYou + " capped " + session.dotCapped + " phase " + session.phase + " message '" + session.message + "' line " + line())
      pressSpace()
    }, 80)
    at(function () { feed({event: "capture_failed", code: "not_you"}) }, 80)
    at(function () {
      log("cap-5", "notyou " + session.dotNotYou + " capped " + session.dotCapped + " phase " + session.phase + " message '" + session.message + "'")
      // the helper closes the session: `discarded`, then the process ends
      emit({event: "discarded"})
      var p = fakeProc; fakeProc = null
      if (p && p.exitCb) p.exitCb({outcome: "ok", code: 0})
    }, 150)
    at(function () {
      log("cap-after", "phase " + session.phase + " finished " + finishedCount + " | note '" + named("note").text + "' | " + dotLinks() + " | cameras " + cameras)
      // and the scan can start over: a new session counts from zero
      session.start()
    }, 150)
    at(function () { ready(true) }, 100)
    at(function () { log("cap-restart", "notyou " + session.dotNotYou + " capped " + session.dotCapped + " phase " + session.phase + " " + session.dotState + " message '" + session.message + "'") }, 100)
  }

  // ---- the ring completes only with enough good frames -------------------------------------------------------
  function buildDotRing() {
    var T = {}
    at(function () { session.start() }, 150)
    at(function () { ready(true) })
    at(function () { pressSpace() }, 100)
    // two of three, for two seconds: the ring is held short of closed, no matter how long it waits
    at(function () { feed({event: "dot", pose: "centre", good: 1, need: 3}) }, 100)
    at(function () { feed({event: "dot", pose: "centre", good: 2, need: 3}) }, 400)
    at(function () { T.samples = [] }, 600)
    for (var i = 0; i < 6; i++) at(function () { T.samples.push(ballInfo().close) }, 400)
    at(function () {
      var top = Math.max.apply(null, T.samples)
      log("held-short", "max close " + r1(top) + " state " + session.dotState + " good " + session.dotGood + " held " + session.dotHeld.length + " ring " + r1(ring2().r))
      log("held-short-below", top < 1 && top <= 0.3 + 0.7 * 2 / 3 + 0.01)
      // it is the helper's `dotted` that closes it: arriving after the second, it applies at once
      feed({event: "dot", pose: "centre", good: 3, need: 3})
      dotted("centre", ["centre"])
    }, 100)
    at(function () {
      log("closed", ballInfo().close + " " + session.dotState + " held " + session.dotHeld.join(",") + " ring " + r1(ring2().r))
    }, 400)
    // a `dotted` that arrives early (a quick camera) still waits for the ring's second
    at(function () { return function () { return session.dotState === "waiting" } }, 20)
    at(function () { T.t0 = Date.now(); pressSpace() }, 100)
    at(function () { feed({event: "dot", pose: "left", good: 3, need: 3}); dotted("left", ["centre", "left"]) }, 60)
    at(function () {
      log("early-dotted", "held " + session.dotHeld.length + " state " + session.dotState)
      return function () { return session.dotHeld.length === 2 }
    }, 20)
    at(function () {
      var waited = Date.now() - T.t0
      log("early-waited", waited >= 950 ? "a second" : "too soon " + waited)
    }, 10)
    // a press that fails opens the ring again, from wherever it had got to
    at(function () { return function () { return session.dotState === "waiting" } }, 20)
    at(function () { pressSpace() }, 100)
    at(function () { feed({event: "dot", pose: "top", good: 1, need: 3}) }, 500)
    at(function () { T.mid = ballInfo().close; feed({event: "capture_failed", code: "no_face"}) }, 100)
    at(function () { return function () { return ballInfo().close < 0.02 } }, 20)
    at(function () { log("reopened", "mid " + (T.mid > 0.1 ? "closing" : "open") + " then " + ballInfo().close + " ring " + r1(ring2().r) + " state " + session.dotState) }, 50)
  }

  // ---- reduced motion: nothing depends on a running animation --------------------------------------------------
  function buildDotReduced() {
    at(function () { }, 900)
    at(function () {
      log("reduced-idle", "demo " + (demoItem() === null ? "none" : "present") + " glyph " + named("glyph").visible + " caption '" + named("caption").text + "'")
      log("reduced-ring", "r " + r1(ring2().r) + " pulse running " + ballItem().pulse)
      session.start()
    }, 200)
    at(function () { ready(true) })
    at(function () {
      var a = ring2().r
      log("reduced-waiting", ballInfo().state + " r " + r1(a))
    }, 300)
    at(function () { log("reduced-static", "r " + r1(ring2().r) + " pulse " + ballItem().pulse) }, 500)
    at(function () { pressSpace() }, 50)
    at(function () { feed({event: "dot", pose: "centre", good: 1, need: 3}) }, 100)
    at(function () { log("reduced-1of3", JSON.stringify(ballInfo())); feed({event: "dot", pose: "centre", good: 3, need: 3}); dotted("centre", ["centre"]) }, 100)
    at(function () { return function () { return session.dotState === "waiting" } }, 20)
    at(function () { log("reduced-moved", JSON.stringify(ballInfo()) + " easing " + (ballItem().x === ballScreen.balls.target.x)) }, 5)
    at(function () { pressSpace(); feed({event: "capture_failed", code: "too_dark"}) }, 100)
    at(function () { log("reduced-failed", "close " + ballInfo().close + " line " + line()) }, 5)
  }

  // ---- the idle demo: the ball, the ring and the head, no camera ------------------------------------------------------
  function buildDotDemo() {
    var captions = [], seen = {}
    function note() {
      var c = named("caption").text
      if (c !== "" && captions[captions.length - 1] !== c) captions.push(c)
    }
    at(function () {
      log("demo-state", demoItem().running + " " + demoItem().visible + " cameras " + cameras + " glyph " + named("glyph").visible)
      log("demo-line", line())
    }, 400)
    var t0 = 0
    at(function () {
      t0 = Date.now()
      return function () {
        note()
        // the card's little demo ball (named "ball" inside the stage), from the circle's middle
        var f = demoItem().frame, db = named("ball"), st = stageItem()
        var i = {x: db.x - st.stageW / 2, y: db.y - st.circleY, close: db.close}
        if (f.pose === "left" && f.close >= 0.95 && i.close >= 0.9) seen.leftClosed = true
        if (f.pose === "left" && i.x < -90) seen.leftBall = true
        if (f.pose === "top" && i.y < -60) seen.topBall = true
        if (f.pose === "right" && i.x > 90) seen.rightBall = true
        if (f.pose === "bottom" && i.y > 60) seen.bottomBall = true
        if (f.pose === "left" && f.yaw < -0.9) seen.leftYaw = true
        if (f.pose === "right" && f.yaw > 0.9) seen.rightYaw = true
        if (f.pose === "top" && f.pitch > 0.9) seen.upPitch = true
        if (f.pose === "bottom" && f.pitch < -0.9) seen.downPitch = true
        if (f.held.length === 4 && f.pose === "bottom" && f.close < 0) seen.fourTaken = true
        if (f.pressed) seen.keyPressed = true
        if (f.done && named("check").visible) seen.check = true
        return captions.indexOf("All set.") >= 0
      }
    }, 100)
    at(function () {
      log("demo-captions", captions.join(" | "))
      log("demo-seen", JSON.stringify(seen))
      log("demo-seconds", Math.round((Date.now() - t0) / 1000))
      shellRoot.tAtStart = 0
      session.start()
    }, 200)
    at(function () { shellRoot.tAtStart = demoItem() ? demoItem().t : -1 }, 300)
    at(function () {
      log("start-stopped", (demoItem() === null ? "gone" : demoItem().running + " " + demoItem().visible) + " cameras " + cameras)
    }, 400)
  }

  // ---- a helper that does not list `dot` (before 3.2.0): the single capture, with a plain note -----------------------
  function buildDotSkew() {
    at(function () { log("skew-idle", session.phase + " legacy=" + view.legacy); session.start() }, 250)
    at(function () { shellRoot.verbs = ["capture", "sweep", "abort", "finish"]; ready(true) })
    at(function () {
      log("skew-phase", session.phase + " legacy " + session.legacy + " dotFlow " + session.dotFlow + " scanFlow " + session.scanFlow)
      log("skew-view", "legacy " + view.legacy)
      log("skew-sent", sentCmds())
      log("skew-note", session.legacyNote)
    }, 400)
  }

  // ---- a 3.2.x helper (it lists `sweep` too): the 3.3.0 card takes the dot scan and never sends a sweep ------------------
  function buildDotSkew326() {
    at(function () { session.start() }, 250)
    at(function () { shellRoot.verbs = ["capture", "sweep", "dot", "abort", "finish"]; ready(true) })
    at(function () {
      log("skew326-phase", session.phase + " legacy " + session.legacy + " dotFlow " + session.dotFlow)
      log("skew326-view", "legacy " + view.legacy + " pose " + session.dotPose)
    }, 300)
    pressAndTake("centre", ["centre"])
    at(function () { log("skew326-sent", sentCmds() + " violations " + violations) }, 100)
  }

  // ---- version skew ------------------------------------------------------------------------------------------
  function buildSkew() {
    at(function () { log("skew-idle", session.phase + " " + view.legacy); session.start() }, 200)
    at(function () { ready(false) })
    at(function () {
      log("skew-phase", session.phase + " " + session.legacy)
            log("skew-legacy-view", view.legacy)
      log("skew-sent", sentCmds())
      log("skew-picker", view.actionText())
      log("skew-cameras", cameras)
    }, 3500)
    at(function () {
      log("skew-capture-after-countdown", sentCmds() + " | " + session.phase)
      log("skew-no-sweep", sentCmds().indexOf("sweep") < 0)
      emit({event: "capturing"})
      emit({event: "captured", appearance: "No glasses", weak: false})
    })
    at(function () {
      log("skew-verdict", session.phase + " " + session.verdict + " cameras " + cameras)
      log("skew-note-text", session.legacyNote)
    })
  }

  // A session that is not the scan at all: what g3/g8 drive.
  function buildPlain() {
    at(function () {
      log("plain-phase", session.phase + " scan=" + session.scan + " legacy=" + view.legacy)
      log("plain-cameras", cameras + " (previewWanted " + session.previewWanted + ")")
      session.start()
    }, 200)
    at(function () { ready(true) })
    at(function () { log("plain-after-ready", session.phase + " " + sentCmds() + " scanFlow=" + session.scanFlow) }, 300)
  }

  // ---- the preview fence (6a.1) -------------------------------------------------------------------------------------
  function buildFence() {
    at(function () { }, 1700)
    at(function () { log("fence-idle", cameras + " " + view.previewOn + " " + session.previewWanted + " " + demoItem().running + " " + (demoItem().t > 0.5)) }, 300)
    at(function () { session.start() })
    at(function () { log("fence-authorising", cameras + " " + view.previewOn + " " + session.phase) }, 150)
    at(function () { ready(true) })
    at(function () { log("fence-dot", cameras + " " + view.previewOn + " " + session.phase) }, 150)
    // the host stops showing the view: the camera goes within 200 ms
    at(function () { shellRoot.live = false }, 200)
    at(function () { log("fence-host-hidden", cameras + " " + view.previewOn) })
    at(function () { shellRoot.live = true }, 200)
    at(function () { log("fence-host-shown", cameras + " " + view.previewOn) })
    // a press that did not work leaves the ball and the camera where they were: the next press is one Space away
    at(function () { pressSpace() }, 100)
    at(function () { feed({event: "capture_failed", code: "no_face"}) }, 200)
    at(function () { log("fence-failed-press", cameras + " " + view.previewOn + " " + session.phase + " " + session.dotState) })
    pressAndTake("centre", ["centre"])
    pressAndTake("left", ["centre", "left"])
    pressAndTake("top", ["centre", "left", "top"])
    pressAndTake("right", ["centre", "left", "top", "right"])
    pressAndTake("bottom", ["centre", "left", "top", "right", "bottom"])
    at(function () { log("fence-held", cameras + " " + session.phase + " " + session.scanState) }, 150)
    at(function () { session.done() })
    at(function () { log("fence-closing", cameras + " " + session.phase + " " + view.previewOn) }, 200)
    // polkit refused / a destroyed view leaves no camera
    at(function () { sessionLoader.active = false; sessionLoader.active = true }, 150)
    at(function () { session.start() }, 100)
    at(function () { log("fence-second-auth", cameras) }, 100)
    at(function () { sessionLoader.active = false }, 100)
    at(function () { log("fence-destroyed", cameras) }, 300)
  }

  // ---- the dimming behind the island -------------------------------------------------------------
  function buildScrim() {
    var worst = 0, peak = 0, samples = 0
    function look() {
      var shown = find(scrimLayer, "scrim").opacity
      worst = Math.max(worst, Math.abs(shown - 0.55 * Math.max(0, Math.min(1, island.heightP))))
      peak = Math.max(peak, shown)
      samples++
    }
    at(function () { look(); log("first", r1(find(scrimLayer, "scrim").opacity) + " reduced " + island.reduced) }, 5)
    for (var i = 0; i < 16; i++) at(function () { look() }, 40)
    at(function () {
      log("follows", "within " + (worst < 0.0001 ? "0.0001" : r1(worst)) + " of 0.55 x the drop over " + samples + " samples")
      log("peak", r1(peak) + " settled " + r1(find(scrimLayer, "scrim").opacity))
      var input = find(scrimLayer, "scrimInput")
      log("input", (input.acceptedButtons === Qt.AllButtons) + " " + input.hoverEnabled + " covers " + (input.width === scrimLayer.width && input.height === scrimLayer.height))
      log("colour", String(find(scrimLayer, "scrim").color))
      shellRoot.retractedCount = 0
      island.retract()
      log("retract-first", r1(find(scrimLayer, "scrim").opacity))
    }, 10)
    for (var w = 0; w < 40; w++)
      at(function () {
        if (shellRoot.retractedCount > 0 && shellRoot.t1 === 0) {
          log("retracted", r1(find(scrimLayer, "scrim").opacity) + " " + r1(island.presence))
          log("input-after", find(scrimLayer, "scrimInput").width + "x" + find(scrimLayer, "scrimInput").height)
          log("input-idle", find(idleScrim, "scrimInput").width + "x" + find(idleScrim, "scrimInput").height)
          shellRoot.t1 = 1
        }
      }, 100)
  }

  // ---- the island: the notch's silhouette, the drop and the retract --------------------
  function buildIsland() {
    var heights = [], widths = [], tops = []
    var t0 = 0
    at(function () {
      t0 = Date.now()
      var sh = island.shape
      log("first", "reduced " + island.reduced)
    }, 5)
    for (var i = 0; i < 16; i++) {
      at(function () {
        heights.push(island.heightP); widths.push(island.widthP); tops.push(island.shape.y)
      }, 40)
    }
    at(function () {
      var peak = 0
      for (var k = 0; k < heights.length; k++) peak = Math.max(peak, heights[k])
      log("drop-peak", r1(peak))
      log("drop-end", r1(island.heightP) + " " + r1(island.widthP))
      log("drop-monotone-early", heights[0] < heights[1])
      log("drop-top", tops.filter(function (y) { return y !== 0 }).length === 0 ? "flush" : "moved " + tops.join(","))
      log("drop-ms", Date.now() - t0)
    }, 10)
    at(function () {
      var sh = island.shape
      log("bar", r1(sh.barWidth) + "x" + r1(sh.barHeight))
      log("radii", r1(sh.bottomR) + " " + r1(sh.fillet))
      log("colour", String(sh.color))
      log("flush", sh.y + " " + (sh.mapToItem(null, 0, 0).y))
      log("centred", r1(sh.x + sh.width / 2) + " of " + r1(island.width / 2))
      log("fits", sh.barHeight >= island.enrolView.implicitHeight + 2 * island.pad - 0.5)
      log("width", r1(island.fullWidth) + " " + r1(sh.barWidth))
      log("inner", island.enrolView.x + " " + island.enrolView.y + " " + island.enrolView.opacity)
    }, 10)
    at(function () { shellRoot.t1 = Date.now(); shellRoot.retractedCount = 0; island.retract() }, 5)
    at(function () { log("retract-early", shellRoot.retractedCount + " " + r1(island.heightP)) }, 100)
    // Wait for the answer, up to 4 s: the offscreen scene graph paces animation frames slowly.
    for (var w = 0; w < 40; w++)
      at(function () {
        if (shellRoot.retractedCount > 0 && shellRoot.t1 > 0) {
          log("retract-late", shellRoot.retractedCount + " " + r1(island.heightP) + " " + r1(island.widthP))
          shellRoot.t1 = 0
        }
      }, 100)
    at(function () { island.retract(); log("retract-twice", shellRoot.retractedCount) }, 100)
    at(function () { log("retract-twice-late", shellRoot.retractedCount); island.drop() }, 400)
    at(function () { log("again", r1(island.heightP)) }, 700)
    // The card's keys reach the session through the island: Space is one press, Return is Start and Done
    at(function () { session.start() }, 100)
    at(function () { ready(true) }, 100)
    at(function () { island.capture() }, 150)
    at(function () { log("island-space", JSON.stringify(sent.slice(-1))); island.capture() }, 100)
    at(function () { log("island-space-twice", sentCmds()) }, 50)
  }
  property real t1: 0
  property real tAtStart: 0

  // ---- the PNG strip ------------------------------------------------------------------------------------------------------------
  property int frameNo: 0
  function shoot(name) {
    var item = viewLoader.item
    item.grabToImage(function (result) {
      result.saveToFile(shellRoot.outDir + "/" + name + ".png")
    })
  }
  function buildStrip() {
    // The idle demo, caught at a few of its steps (the demo is time-driven, so each
    // is waited for rather than timed).
    var stops = [["d1-centre", function () { return demoItem().frame.pose === "centre" && demoItem().frame.close > 0.6 }],
                 ["d2-left", function () { return demoItem().frame.pose === "left" && demoItem().frame.close > 0.6 }],
                 ["d3-top", function () { return demoItem().frame.pose === "top" && demoItem().frame.close > 0.6 }],
                 ["d4-right", function () { return demoItem().frame.pose === "right" && demoItem().frame.close > 0.6 }],
                 ["d5-bottom", function () { return demoItem().frame.pose === "bottom" && demoItem().frame.close > 0.6 }]]
    var m = "simple"
    at(function () { }, 600)
    stops.forEach(function (stop) {
      at(function () { return stop[1] }, 20)
      at(function () { shoot(m + "-" + stop[0]) }, 120)
    })
    at(function () { return function () { return demoItem().caption !== "" } }, 100)
    at(function () { shoot(m + "-1-idle") }, 250)
    at(function () { session.start() })
    at(function () { ready(true) })
    at(function () { }, 700)
    at(function () { shoot(m + "-2-centre") }, 400)
    at(function () { pressSpace() }, 300)
    at(function () { feed({event: "dot", pose: "centre", good: 2, need: 3}) }, 500)
    at(function () { shoot(m + "-3-closing") }, 300)
    at(function () { feed({event: "dot", pose: "centre", good: 3, need: 3}); dotted("centre", ["centre"]) }, 100)
    at(function () { return function () { return session.dotState === "waiting" && atPose("left") } }, 20)
    at(function () { shoot(m + "-4-left") }, 300)
    at(function () { pressSpace() }, 100)
    at(function () { feed({event: "capture_failed", code: "no_face"}) }, 300)
    at(function () { shoot(m + "-5-nofacefound") }, 300)
    at(function () { feed({event: "dotted", pose: "right", poses: ["centre", "left", "top", "right"], kept: 4}) }, 100)
    at(function () { return function () { return session.dotState === "waiting" && atPose("bottom") } }, 20)
    at(function () { shoot(m + "-6-save") }, 300)
    at(function () { feed({event: "dotted", pose: "bottom", poses: ["centre", "left", "top", "right", "bottom"], kept: 5}) }, 100)
    at(function () { return function () { return session.dotState === "done" } }, 20)
    at(function () { shoot(m + "-7-done") }, 600)
    at(function () { }, 500)
  }
}
