import QtQuick
import QtQuick.Window
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "face" as Face
import "face/common/enrolring.js" as Ring
import "face/common/dotscan.js" as Dot2

// The enrol view, offscreen, for dev/e3-enrol-view.sh (plan-face-enroll.md
// section 7.4, Phase 4). The REAL EnrolView.qml, EnrolRing.qml and
// RecordSession.qml, against the running Omarchy's qs.Commons and qs.Ui, driven
// by a FAKE root session that enforces table V: it answers `sweep`, `finish`,
// `abort` and `done` the way the real parent does, counts every verb the table
// refuses, and is fed the engine's events by the scripts below. Nothing is
// asked of a camera: the preview the circle would hold is a counting stand-in,
// so "no camera in idle" is a count of zero and not a promise.
//
//   E3_CASE   dot | dot-esc | dot-fail | dot-ring | dot-reduced | dot-demo | dot-skew |
//             advanced | esc | fail | skew | plain | reduced | fence | mode | strip
//             (the ring's cases run the session in Advanced, whatever the mode file says)
//   E3_STATE_HOME  the state home the mode file lives under (mode, with
//                  OMARCHY_FACE_DEV_BIN set, as RemoveView's rule says)
//   E3_STORED  templates the appearance already holds (rule R)
//   E3_MODE_ACT  mode: what to do once the view is up (none | click | start)
//   E3_OUT     strip: the directory the PNGs go to
//   E3_ACCENT  the accent the harness theme uses (default: the theme's own)
//
// It prints `HARNESS key value` lines.
ShellRoot {
  id: shellRoot

  readonly property string caseName: Quickshell.env("E3_CASE") || "simple"
  readonly property int stored: Number(Quickshell.env("E3_STORED") || "0")
  readonly property string outDir: Quickshell.env("E3_OUT") || "/tmp"
  readonly property string accentEnv: Quickshell.env("E3_ACCENT") || ""
  readonly property bool reducedCase: caseName === "reduced" || caseName === "island-reduced" || caseName === "demo-reduced" || caseName === "scrim-reduced" || caseName === "dot-reduced"
  // The island cases draw the whole card body (ScanIsland.qml), no window around it.
  readonly property bool islandCase: caseName === "strip" || caseName === "island" || caseName === "island-reduced" || caseName === "scrim" || caseName === "scrim-reduced"

  function log(key, value) { console.log("HARNESS " + key, value) }

  // Advanced draws the ring and Simple the dot scan; the cases about the ring run in Advanced.
  readonly property var ringCases: ["advanced", "esc", "fail", "reduced", "hairline", "demo", "demo-reduced", "demo-hidden", "fence"]
  readonly property string startMode: ringCases.indexOf(caseName) >= 0 ? "advanced" : "simple"

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
  property var verbs: ["capture", "sweep", "dot", "abort", "finish"]
  // The poses the fake root holds (the dot scan), as the real parent's `dotted` event lists them
  property var fakeHeld: []

  function emit(event) { if (fakeProc && fakeProc.eventCb) fakeProc.eventCb(event) }

  function sameBins(list, want) {
    if (!list || list.length !== want.length) return false
    var a = list.slice().sort(function (x, y) { return x - y })
    for (var i = 0; i < want.length; i++) if (a[i] !== want[i]) return false
    return true
  }

  function respond(c) {
    var s = shellRoot.fakeState
    if (c.cmd === "create") return
    if (c.cmd === "sweep") {
      // Simple is the dot scan now: the helper refuses a Simple sweep
      var advanced = c.mode === "advanced" && c.lap === 1 && sameBins(c.targets, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
      if (!((s === "ready" || s === "swept") && advanced)) {
        violations++
        emit({event: "capture_failed", code: "bad_sweep"})
        return
      }
      fakeState = "running"
      emit({event: "sweeping", mode: c.mode, lap: 1,
            targets: c.targets.slice().sort(function (x, y) { return x - y }), quota: 2})
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
    if (c.cmd === "finish") return          // ignored unless a lap runs; the script answers it
    if (c.cmd === "abort") {
      if (s === "running") { fakeState = "ready"; emit({event: "aborted"}) }
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
        mode: shellRoot.startMode
        stored: shellRoot.stored
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
  // Both cards (the ring's and the dot scan's) are in the view, and only one is shown: the item of that
  // name that is on screen wins, else the first there is.
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
  function ring() { return find(view, "ring") }
  function demoItem() { return find(view, "demo") }
  function named(name) { return find(view, name) }
  function tick(i) { return find(ring(), "tick" + i) }

  function r1(x) { return String(Math.round(x * 100) / 100) }
  // What a bin's five ticks are going to look like: "len/opacity" for each.
  function binLook(k) {
    var out = []
    for (var j = 0; j < 5; j++) {
      var t = tick(5 * k + j).parent
      out.push(r1(t.targetLen) + "/" + r1(t.targetOpacity))
    }
    return out.join(" ")
  }
  function binKinds(k) {
    var out = []
    for (var j = 0; j < 5; j++) out.push(tick(5 * k + j).parent.lk.kind)
    return out.join(",")
  }
  function shown(k, j) { // what is actually on screen now
    var r = tick(5 * k + j)
    return {len: r.height, op: r.parent.opacity, color: r.color}
  }
  function linkState(name) { var l = named(name); return l ? (l.visible ? "1" : "0") : "-" }
  function choiceName() { return view.dot ? "modeChoice" : "modeChoiceAdv" }
  function links() {
    return ["cancelLink", "startLink", "doneLink", "againLink", choiceName()]
      .map(function (n) { return n.replace("Link", "").replace("Choice", "").replace("Adv", "") + "=" + linkState(n) }).join(" ")
  }
  function line() { return named("line").text }
  function dotInfo() {
    var d = named("headDot")
    var c = ring().full / 2
    return {x: d.x + 3 - c, y: d.y + 3 - c, op: d.opacity, shown: d.visible}
  }
  function sentCmds() { return sent.map(function (c) { return c.cmd }).join(",") }

  function feed(ev) {
    if (ev.event === "swept") fakeState = "swept"
    if (ev.event === "dotted") { fakeState = "swept"; fakeHeld = ev.poses.slice() }
    if (ev.event === "capture_failed" && ["not_enough", "sweep_stalled"].indexOf(ev.code) < 0)
      fakeState = fakeHeld.length > 0 ? "swept" : "ready"
    emit(ev)
  }
  function ready(withVerbs) {
    var e = {event: "ready", person: null}
    if (withVerbs) e.verbs = shellRoot.verbs
    feed(e)
  }
  function zeros() { return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] }
  function bins(over) { var b = zeros(); for (var k in over) b[Number(k)] = over[k]; return b }
  function track(o) {
    var e = {event: "track", state: "searching", u: 0, v: 0, target: "centre", centre: 0, bins: zeros(),
             skipped: [], canFinish: false}
    for (var k in o) e[k] = o[k]
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

  // The palette's contrast over #000: rest, current, done and the centre arc.
  function rgb(c) { return {r: c.r, g: c.g, b: c.b} }
  function contrastOf(c, opacity) { return Ring.contrast(Ring.over(rgb(Qt.color(c)), opacity * Qt.color(c).a), {r: 0, g: 0, b: 0}) }

  function build() {
    var c = caseName
    if (c === "dot") buildDot()
    else if (c === "dot-esc") buildDotEsc()
    else if (c === "dot-fail") buildDotFail()
    else if (c === "dot-ring") buildDotRing()
    else if (c === "dot-cap") buildDotCap()
    else if (c === "dot-reduced") buildDotReduced()
    else if (c === "dot-demo") buildDotDemo()
    else if (c === "dot-skew") buildDotSkew()
    else if (c === "advanced") buildAdvanced()
    else if (c === "esc") buildEsc()
    else if (c === "fail") buildFail()
    else if (c === "skew") buildSkew()
    else if (c === "plain") buildPlain()
    else if (c === "reduced") buildReduced()
    else if (c === "hairline") buildHairline()
    else if (c === "demo") buildDemo()
    else if (c === "demo-reduced") buildDemoReduced()
    else if (c === "demo-hidden") buildDemoHidden()
    else if (c === "fence") buildFence()
    else if (c === "mode") buildMode()
    else if (c === "strip") buildStrip()
    else if (c === "island" || c === "island-reduced") buildIsland()
    else if (c === "scrim" || c === "scrim-reduced") buildScrim()
  }

  // ---- the dot scan (Simple) -------------------------------------------------------------------------
  function stageItem() { return named("stage") }
  function ballItem() { return named("ball") }
  function ringItem() { return named("ring") }
  // Where the ball is on the stage, from the stage's middle, and the ring's radius
  function ballInfo() {
    var st = stageItem(), b = ballItem()
    return {x: Math.round(b.x - st.stageW / 2), y: Math.round(b.y - st.stageH / 2), r: r1(ring2().r), close: r1(st.close),
            state: st.shownState, pose: st.pose, op: r1(b.opacity)}
  }
  function ring2() { return find(ballItem(), "ballRing") }
  function dotLinks() {
    return ["cancelLink", "startLink", "saveLink", "doneLink", "againLink", "modeChoice"]
      .map(function (n) { return n.replace("Link", "").replace("Choice", "") + "=" + linkState(n) }).join(" ")
  }
  function keyInfo() {
    var h = named("spaceHint"), k = named("spaceKey")
    return (h.visible ? "shown" : "hidden") + " opacity " + r1(h.opacity) + " enabled " + k.enabled + " text " + named("spaceHintText").text
  }
  function marks() {
    return ["centre", "left", "top", "right", "bottom"].map(function (p) {
      var m = named("station-" + p)
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
      var st = Dot2.STATION[session.dotPose]
      return session.dotPose === "" || (Math.abs(b.x - st.x * stageItem().reachX) < 2 && Math.abs(b.y - st.y * stageItem().reachY) < 2)
    } }, 20)
  }

  function buildDot() {
    var T = {}
    at(function () {
      log("idle-phase", session.phase + " " + session.dotFlow)
      log("idle-mode", view.mode + " dot=" + view.dot + " legacy=" + view.legacy)
      log("idle-card", named("dotCard").visible + " ring-column " + (ring() !== null && ring().visible))
      log("idle-line", line())
      log("idle-glyph", named("glyph").visible + " demo " + (demoItem() !== null && demoItem().visible) + " caption '" + named("caption").text + "'")
      log("idle-cameras", cameras + " previewOn " + view.previewOn + " previewLoader " + (named("previewLoader").item === null ? "empty" : "full"))
      log("idle-links", dotLinks())
      log("idle-key", keyInfo())
      log("idle-modes", named("mode-simple").selected + "/" + named("mode-advanced").selected + " " + named("mode-simple").text + "," + named("mode-advanced").text)
      log("idle-marks", marks())
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
      log("mode-after-start", session.modeFixed)
      session.setMode("advanced")
      log("mode-inert-after-start", session.mode)
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
      log("breath", "min " + r1(lo) + " max " + r1(hi) + " within " + (lo >= 19.9 && hi <= 24.1) + " moves " + (hi - lo > 1))
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
    at(function () { return function () { return Math.abs(ballInfo().x + 120) < 2 } }, 20)
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
    at(function () { return function () { return Math.abs(ballInfo().y + 96) < 2 && Math.abs(ballInfo().x) < 2 } }, 20)
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
    at(function () { return function () { return Math.abs(ballInfo().x) < 2 && Math.abs(ballInfo().y) < 2 } }, 20)
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
      log("reduced-ring", "r " + r1(ring2().r) + " pulse running " + stageItem().pulse)
      session.start()
    }, 200)
    at(function () { ready(true) })
    at(function () {
      var a = ring2().r
      log("reduced-waiting", ballInfo().state + " r " + r1(a))
    }, 300)
    at(function () { log("reduced-static", "r " + r1(ring2().r) + " pulse " + stageItem().pulse) }, 500)
    at(function () { pressSpace() }, 50)
    at(function () { feed({event: "dot", pose: "centre", good: 1, need: 3}) }, 100)
    at(function () { log("reduced-1of3", JSON.stringify(ballInfo())); feed({event: "dot", pose: "centre", good: 3, need: 3}); dotted("centre", ["centre"]) }, 100)
    at(function () { return function () { return session.dotState === "waiting" } }, 20)
    at(function () { log("reduced-moved", JSON.stringify(ballInfo()) + " easing " + (ballItem().x === stageItem().stageW / 2 + stageItem().targetX)) }, 5)
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
        var f = demoItem().frame, i = ballInfo()
        if (f.pose === "left" && f.close >= 0.95 && i.close >= 0.9) seen.leftClosed = true
        if (f.pose === "left" && i.x < -100) seen.leftBall = true
        if (f.pose === "top" && i.y < -80) seen.topBall = true
        if (f.pose === "right" && i.x > 100) seen.rightBall = true
        if (f.pose === "bottom" && i.y > 80) seen.bottomBall = true
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

  // ---- a 3.1.x helper (no `dot`): Simple falls back to the single capture ---------------------------------------
  function buildDotSkew() {
    at(function () { log("skew-idle", session.phase + " dot=" + view.dot + " legacy=" + view.legacy); session.start() }, 250)
    at(function () { shellRoot.verbs = ["capture", "sweep", "abort", "finish"]; ready(true) })
    at(function () {
      log("skew-phase", session.phase + " legacy " + session.legacy + " dotFlow " + session.dotFlow + " sweepFlow " + session.sweepFlow)
      log("skew-view", "legacy " + view.legacy + " dot " + view.dot)
      log("skew-sent", sentCmds())
      log("skew-note", session.legacyNote)
    }, 400)
  }

  // ---- Advanced -----------------------------------------------------------------------------------------
  function buildAdvanced() {
    at(function () {
      session.setMode("advanced")
      log("adv-mode", view.mode + " " + session.mode)
      log("adv-idle-modes", named("mode-simple").selected + "/" + named("mode-advanced").selected)
      log("adv-idle-rest", binKinds(0) + " | " + binKinds(5) + " | " + binKinds(11))
      log("adv-idle-descr", ring().description)
      session.start()
    }, 200)
    at(function () { ready(true) })
    at(function () {
      log("adv-sent", JSON.stringify(sent.slice(-1)))
      track({state: "hold", centre: 1, target: null})
    })
    at(function () {
      log("adv-phase", session.phase)
      log("adv-line", line())
      log("adv-no-current", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].map(function (k) { return binKinds(k) }).filter(function (v, i, a) { return a.indexOf(v) === i }).join(" | "))
      log("adv-links", links())
      track({state: "hold", centre: 1, target: 5, bins: bins({5: 0.2}), u: 0.9, v: 1.2})
    })
    at(function () {
      log("adv-hold-line", line())
      log("adv-current", binKinds(5) + " | " + binLook(5))
      // Any order: 2 first at 40 percent, then 5 full, 11 full.
      track({state: "hold", centre: 1, target: 2, bins: bins({5: 1, 2: 0.4}), u: 1.2, v: -0.7})
    })
    at(function () {
      log("adv-any-order", binKinds(5) + " | " + binKinds(2) + " | " + binLook(2))
      log("adv-descr", ring().description)
      log("adv-target-items", countTargets())
      track({state: "hold", centre: 1, target: 11, bins: bins({5: 1, 2: 0.4, 11: 1, 0: 1, 1: 1, 3: 1}), canFinish: true})
    })
    at(function () {
      log("adv-done-shown", links())
      log("adv-descr-5", ring().description)
      named("doneLink").clicked()
    })
    at(function () {
      log("adv-finish-sent", sent[sent.length - 1].cmd)
      // The engine answers with swept; Done is then `done`, and Another distance /
      // Try it do not exist yet (Phase 5).
      feed({event: "swept", mode: "advanced", lap: 1, filled: [0, 1, 2, 3, 5, 11], skipped: [], centreHeld: true, kept: 7})
    })
    at(function () {
      log("adv-swept-line", line())
      log("adv-swept-links", links())
      named("doneLink").clicked()
    })
    at(function () {
      log("adv-done-sent", sent[sent.length - 1].cmd)
      log("adv-violations", violations)
      log("adv-capture-never", sentCmds().indexOf("capture") < 0)
    })
  }

  function countTargets() {
    var n = 0
    for (var k = 0; k < 12; k++) if (find(ring(), "target" + k)) n++
    return n + 1 // and the ring itself
  }

  // ---- Esc from every phase -----------------------------------------------------------------------------
  function buildEsc() {
    at(function () { shellRoot.eofs = 0; session.requestClose() }, 200)
    at(function () { log("esc-idle", eofs + " " + finishedCount + " " + finishedSaved) })
    // authorising
    at(function () {
      shellRoot.finishedCount = 0
      sessionLoader.active = false
      sessionLoader.active = true
    }, 100)
    at(function () { session.start() })
    at(function () { eofs = 0; session.requestClose() }, 150)
    at(function () { log("esc-authorising", eofs + " " + session.phase + " " + finishedCount + " " + cameras) }, 200)
    // centre
    at(function () { shellRoot.finishedCount = 0; sessionLoader.active = false; sessionLoader.active = true }, 100)
    at(function () { session.start() })
    at(function () { ready(true) })
    at(function () { eofs = 0; log("esc-centre-phase", session.phase); session.requestClose() }, 150)
    at(function () { log("esc-centre", eofs + " " + finishedCount + " " + cameras + " " + line()) }, 200)
    // lap1
    at(function () { shellRoot.finishedCount = 0; sessionLoader.active = false; sessionLoader.active = true }, 100)
    at(function () { session.start() })
    at(function () { ready(true) })
    at(function () { track({state: "hold", centre: 1, target: 9, bins: bins({9: 0.3})}) })
    at(function () { eofs = 0; log("esc-lap1-phase", session.phase); session.requestClose() }, 150)
    at(function () { log("esc-lap1", eofs + " " + finishedCount + " " + finishedSaved + " " + cameras) }, 200)
    // swept: Esc discards, it does not save
    at(function () { shellRoot.finishedCount = 0; sessionLoader.active = false; sessionLoader.active = true }, 100)
    at(function () { session.start() })
    at(function () { ready(true) })
    at(function () { track({state: "hold", centre: 1, target: 9}); feed({event: "swept", mode: "simple", lap: 1, filled: [0, 3, 6, 9], skipped: [], centreHeld: true, kept: 5}) })
    at(function () { eofs = 0; log("esc-swept-phase", session.phase + " " + session.scanState); session.requestClose() }, 150)
    at(function () { log("esc-swept", eofs + " " + finishedCount + " " + finishedSaved + " " + cameras + " sent=" + sentCmds().split(",").pop()) }, 200)
    // verdict
    at(function () { shellRoot.finishedCount = 0; sessionLoader.active = false; sessionLoader.active = true }, 100)
    at(function () { session.start() })
    at(function () { ready(true) })
    at(function () { feed({event: "capture_failed", code: "too_few"}) })
    at(function () { eofs = 0; log("esc-verdict-phase", session.phase + " " + cameras); session.requestClose() }, 150)
    at(function () { log("esc-verdict", eofs + " " + finishedCount + " " + finishedSaved) }, 200)
    // the "Nothing was saved" line stays on the view until the session finishes
    at(function () { shellRoot.finishedCount = 0; sessionLoader.active = false; sessionLoader.active = true }, 100)
    at(function () { session.start() })
    at(function () { ready(true) })
    at(function () { session.discard() }, 5)
    at(function () { log("esc-line-discarding", line()) }, 5)
    at(function () { log("esc-done", violations) }, 150)
  }

  // ---- failures -------------------------------------------------------------------------------------------
  function buildFail() {
    var codes = ["too_few", "lap_timeout", "bad_sweep", "changed"]
    at(function () { session.start() }, 100)
    at(function () { ready(true) })
    at(function () { track({state: "hold", centre: 1, target: 9, bins: bins({9: 0.5})}) })
    codes.forEach(function (code) {
      at(function () {
        shellRoot.maxShake = 0
        shakeWatch.start()
        feed({event: "capture_failed", code: code})
      }, 360)
      at(function () {
        shakeWatch.stop()
        log("fail-" + code, session.phase + " | " + line() + " | " + links() + " | shake " + (maxShake > 0) + " | ring " + binLook(9).split(" ")[0] + " | cameras " + cameras + " | " + session.scanState)
        // Try again: lap 1 again on the same session, same mode, no second password.
        named("againLink").clicked()
      })
      at(function () {
        log("retry-" + code, session.phase + " | " + JSON.stringify(sent[sent.length - 1]) + " | cameras " + cameras)
        track({state: "hold", centre: 1, target: 9, bins: bins({9: 0.5})})
      })
    })
    at(function () {
      // `other` is a word, not a failure: no shake, the line says what to do
      shellRoot.maxShake = 0; shakeWatch.start()
      track({state: "other", centre: 1, target: 9, bins: bins({9: 0.5})})
    }, 300)
    at(function () {
      shakeWatch.stop()
      log("other-line", line() + " | shake " + (maxShake > 0) + " | phase " + session.phase)
      feed({event: "capture_failed", code: "not_enough"})
    })
    at(function () {
      log("not-enough", session.phase + " | " + named("note").text + " | " + session.scanState)
      feed({event: "capture_failed", code: "sweep_stalled"})
    })
    at(function () {
      log("stalled", session.phase + " | " + named("note").text)
      // polkit refused: the session ends before ready
      session.requestClose()
    }, 200)
    at(function () {
      sessionLoader.active = false
      sessionLoader.active = true
    }, 100)
    at(function () { session.start() })
    at(function () {
      maxShake = 0; shakeWatch.start()
      var p = fakeProc; fakeProc = null
      p.exitCb({outcome: "owner_declined", code: 126})
    }, 300)
    at(function () {
      shakeWatch.stop()
      log("declined", session.phase + " | " + line() + " | " + named("note").text + " | shake " + (maxShake > 0) + " | previewOn " + view.previewOn + " | cameras " + cameras + " | " + links())
      log("fail-violations", violations)
    })
  }
  property real maxShake: 0
  Timer {
    id: shakeWatch
    interval: 10
    repeat: true
    onTriggered: if (view && Math.abs(view.shakeX) > shellRoot.maxShake) shellRoot.maxShake = Math.abs(view.shakeX)
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
    at(function () { log("plain-after-ready", session.phase + " " + sentCmds() + " sweepFlow=" + session.sweepFlow) }, 300)
  }

  // ---- reduced motion, hairline, animations stopped ------------------------------------------------------------
  function buildReduced() {
    at(function () { session.start() }, 200)
    at(function () { ready(true) })
    at(function () { track({state: "hold", centre: 1, target: 9, bins: bins({9: 0.6}), u: -1.5, v: 0}) })
    at(function () {
      var kinds = binKinds(9)
      var sh = [0, 1, 2, 3, 4].map(function (j) { var s = shown(9, j); return r1(s.len) + "/" + r1(s.op) }).join(" ")
      log("reduced-shown", sh)
      log("reduced-kinds", kinds)
      log("reduced-dot", JSON.stringify(dotInfo()))
      log("reduced-line", line())
      log("reduced-hairline", ring().hairlineRunning)
    }, 400)
    at(function () { track({state: "hold", centre: 1, target: 9, bins: bins({9: 0.6}), u: -1.5, v: 0}) }, 250)
    at(function () { log("reduced-hairline-after-frames", ring().hairlineRunning) })
    at(function () { track({state: "hold", centre: 1, target: 9, bins: bins({9: 0.6}), u: -1.5, v: 0}); shellRoot.violations += 0 })
    at(function () {
      log("reduced-demo", demoItem().running + " " + demoItem().visible + " t " + demoItem().t + " glyph " + named("glyph").visible)
    })
  }

  // ---- the ring's idle demo (Advanced; Simple's is "dot-demo"): plays only in idle, stops on Start ----
  function buildDemo() {
    var captions = [], seen = {}
    function note() {
      var c = named("caption").text
      if (c !== "" && captions[captions.length - 1] !== c) captions.push(c)
    }
    at(function () {
      log("demo-state", demoItem().running + " " + demoItem().visible + " cameras " + cameras + " glyph " + named("glyph").visible)
      log("demo-line", line())
    }, 300)
    var t0 = 0
    at(function () {
      t0 = Date.now()
      var top = 0, monotone = true, last = -1
      return function () {
        note()
        var b = ring().bins, n = 0
        for (var i = 0; i < 12; i++) if (b[i] >= 0.999) n++
        if (n < last && captions.indexOf("The circle is complete.") < 0) monotone = false
        last = n
        top = Math.max(top, n)
        seen.top = top; seen.monotone = monotone
        return captions.indexOf("The circle is complete.") >= 0
      }
    }, 100)
    at(function () {
      log("adv-captions", captions.join(" | "))
      log("adv-seen", JSON.stringify(seen))
      log("adv-mode", view.mode)
      shellRoot.tAtStart = 0
      session.start()
    }, 150)
    at(function () { shellRoot.tAtStart = demoItem().t }, 300)
    at(function () {
      log("start-stopped", demoItem().running + " " + demoItem().visible + " " + (demoItem().t === shellRoot.tAtStart) + " caption '" + named("caption").text + "'")
      log("start-ring", JSON.stringify(ring().bins.slice(0, 4)) + " target " + ring().target + " cameras " + cameras)
    }, 500)
    at(function () { log("start-still", demoItem().t === shellRoot.tAtStart) }, 10)
  }

  // Reduced motion: no demo at all, the glyph and one caption line.
  function buildDemoReduced() {
    at(function () { }, 1500)
    at(function () {
      log("running", demoItem().running + " " + demoItem().visible)
      log("t", demoItem().t)
      log("glyph", named("glyph").visible)
      log("caption", named("caption").text)
      log("ring", binLook(9) + " | " + ring().arc)
    }, 300)
  }

  // The card is not on screen (the host hides it): nothing runs.
  function buildDemoHidden() {
    at(function () { shellRoot.live = false }, 600)
    at(function () { shellRoot.tAtStart = demoItem().t }, 500)
    at(function () { log("hidden", demoItem().running + " " + (demoItem().t === shellRoot.tAtStart)) }, 10)
    at(function () { shellRoot.live = true }, 400)
    at(function () { log("shown", demoItem().running) }, 10)
  }

  // ---- the hairline: only an accepted frame arms it --------------------------------------------------
  function buildHairline() {
    at(function () { session.start() }, 100)
    at(function () { ready(true) })
    at(function () { log("hair-before", ring().hairlineRunning) }, 150)
    ;["dark", "blurry", "other", "searching", "multiple", "edge"].forEach(function (w) {
      at(function () { track({state: w, centre: 0.2, target: "centre"}) }, 120)
      at(function () { log("hair-" + w, ring().hairlineRunning) }, 10)
    })
    at(function () { track({state: "hold", centre: 0.3, target: "centre"}) }, 120)
    at(function () { log("hair-hold", ring().hairlineRunning) }, 10)
    // a second accepted frame while it runs does not restart it; after it ends the next one re-arms
    at(function () { track({state: "hold", centre: 0.4, target: "centre"}) }, 1000)
    at(function () { log("hair-rested", ring().hairlineRunning) }, 10)
    at(function () { track({state: "hold", centre: 0.5, target: "centre"}) }, 120)
    at(function () { log("hair-rearmed", ring().hairlineRunning) }, 1000)
    at(function () { log("hair-done", ring().hairlineRunning) }, 10)
  }

  // ---- the preview fence (6a.1) -------------------------------------------------------------------------------------
  function buildFence() {
    at(function () { }, 1700)
    at(function () { log("fence-idle", cameras + " " + view.previewOn + " " + session.previewWanted + " " + demoItem().running + " " + (demoItem().t > 0.5)) }, 300)
    at(function () { session.start() })
    at(function () { log("fence-authorising", cameras + " " + view.previewOn + " " + session.phase) }, 150)
    at(function () { ready(true) })
    at(function () { track({state: "hold", centre: 1, target: 9}) })
    at(function () { log("fence-lap1", cameras + " " + view.previewOn + " " + session.phase) }, 150)
    // the host stops showing the view: the camera goes within 200 ms
    at(function () { shellRoot.live = false }, 200)
    at(function () { log("fence-host-hidden", cameras + " " + view.previewOn) })
    at(function () { shellRoot.live = true }, 200)
    at(function () { log("fence-host-shown", cameras + " " + view.previewOn) })
    at(function () { feed({event: "capture_failed", code: "too_few"}) }, 200)
    at(function () { log("fence-verdict", cameras + " " + view.previewOn + " " + session.phase) })
    at(function () { named("againLink").clicked() }, 100)
    at(function () { log("fence-retry", cameras + " " + view.previewOn + " " + session.phase) }, 150)
    at(function () { feed({event: "capture_failed", code: "bad_sweep"}) })
    at(function () { named("againLink").clicked() }, 60)
    at(function () { track({state: "hold", centre: 1, target: 9}); feed({event: "swept", mode: "simple", lap: 1, filled: [0, 3, 6, 9], skipped: [], centreHeld: true, kept: 5}) }, 60)
    at(function () { log("fence-swept", cameras + " " + session.phase) }, 150)
    at(function () { session.done() })
    at(function () { log("fence-closing", cameras + " " + session.phase + " " + view.previewOn) }, 200)
    // polkit refused / a destroyed view leaves no camera
    at(function () { sessionLoader.active = false; sessionLoader.active = true }, 150)
    at(function () { session.start() }, 100)
    at(function () { log("fence-second-auth", cameras) }, 100)
    at(function () { sessionLoader.active = false }, 100)
    at(function () { log("fence-destroyed", cameras) }, 300)
  }

  // ---- the mode and its file ---------------------------------------------------------------------------------------------
  function buildMode() {
    var act = Quickshell.env("E3_MODE_ACT") || "none"
    var t0 = Date.now()
    at(function () {
      log("mode-first", view.mode + " phase " + session.phase + " after " + (Date.now() - t0) + "ms")
      log("mode-allowed", session.simpleAllowed + " " + session.activeMode + " link " + linkState(choiceName()) + " " + named("mode-advanced").text)
    }, 1800)
    at(function () {
      log("mode-settled", view.mode)
      if (act === "click") {
        // the other mode's button, as a person would press it
        named(view.mode === "simple" ? "mode-advanced" : "mode-simple").clicked()
        log("mode-clicked", view.mode)
      } else if (act === "start") {
        session.start()
      }
    }, 100)
    at(function () {
      if (act === "start") {
        log("mode-start-phase", session.phase + " " + linkState(choiceName()))
        session.setMode("advanced")
        log("mode-after-start-click", session.mode)
      }
      // The view is not hung: Start still works.
      if (act === "none") session.start()
    }, 300)
    at(function () { log("mode-start-works", session.phase) }, 1200)
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
    var m = Quickshell.env("E3_MODE_ACT") === "advanced" ? "advanced" : "simple"
    at(function () { if (m === "advanced") session.setMode("advanced") }, 600)
    // The idle demo, caught at a few of its steps (the demo is time-driven, so each
    // is waited for rather than timed).
    var stops = m === "simple"
      ? [["d1-centre", function () { return demoItem().frame.pose === "centre" && demoItem().frame.close > 0.6 }],
         ["d2-left", function () { return demoItem().frame.pose === "left" && demoItem().frame.close > 0.6 }],
         ["d3-top", function () { return demoItem().frame.pose === "top" && demoItem().frame.close > 0.6 }],
         ["d4-right", function () { return demoItem().frame.pose === "right" && demoItem().frame.close > 0.6 }],
         ["d5-bottom", function () { return demoItem().frame.pose === "bottom" && demoItem().frame.close > 0.6 }]]
      : [["d1-quarter", function () { return ring().bins[2] > 0.9 && ring().bins[3] < 0.2 }],
         ["d2-half", function () { return ring().bins[5] > 0.9 && ring().bins[6] < 0.2 }],
         ["d3-threequarters", function () { return ring().bins[8] > 0.9 && ring().bins[9] < 0.2 }],
         ["d4-complete", function () { return demoItem().caption === "The circle is complete." }]]
    stops.forEach(function (stop) {
      at(function () { return stop[1] }, 20)
      at(function () { shoot(m + "-" + stop[0]) }, 120)
    })
    at(function () { return function () { return demoItem().caption !== "" } }, 100)
    at(function () { shoot(m + "-1-idle") }, 250)
    at(function () { session.start() })
    at(function () { ready(true) })
    if (m === "simple") {
      at(function () { }, 700)
      at(function () { shoot(m + "-2-centre") }, 400)
      at(function () { pressSpace() }, 300)
      at(function () { feed({event: "dot", pose: "centre", good: 2, need: 3}) }, 500)
      at(function () { shoot(m + "-3-closing") }, 300)
      at(function () { feed({event: "dot", pose: "centre", good: 3, need: 3}); dotted("centre", ["centre"]) }, 100)
      at(function () { return function () { return session.dotState === "waiting" && Math.abs(ballInfo().x + 120) < 2 } }, 20)
      at(function () { shoot(m + "-4-left") }, 300)
      at(function () { pressSpace() }, 100)
      at(function () { feed({event: "capture_failed", code: "no_face"}) }, 300)
      at(function () { shoot(m + "-5-nofacefound") }, 300)
      at(function () { feed({event: "dotted", pose: "right", poses: ["centre", "left", "top", "right"], kept: 4}) }, 100)
      at(function () { return function () { return session.dotState === "waiting" && Math.abs(ballInfo().y - 96) < 2 } }, 20)
      at(function () { shoot(m + "-6-save") }, 300)
      at(function () { feed({event: "dotted", pose: "bottom", poses: ["centre", "left", "top", "right", "bottom"], kept: 5}) }, 100)
      at(function () { return function () { return session.dotState === "done" } }, 20)
      at(function () { shoot(m + "-7-done") }, 600)
    } else {
      at(function () { track({state: "hold", centre: 0.5, u: 0.1, v: 0}) }, 250)
      at(function () { shoot(m + "-2-centre") }, 400)
      at(function () { track({state: "hold", centre: 1, target: 3, bins: bins({3: 0.4}), u: 1.4, v: 0}) }, 700)
      at(function () { shoot(m + "-3-right40") }, 400)
      at(function () { track({state: "hold", centre: 1, target: 8, bins: bins({3: 1, 4: 1, 5: 1, 8: 0.5}), u: -1.2, v: 0.8}) }, 800)
      at(function () { shoot(m + "-4-some") }, 400)
      at(function () { track({state: "hold", centre: 1, target: 11, bins: bins({0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1, 7: 0.6, 8: 1, 9: 1, 10: 1, 11: 1}), canFinish: true, u: -0.7, v: -1.2}) }, 900)
      at(function () { shoot(m + "-5-nearly") }, 400)
      at(function () { track({state: "hold", centre: 1, target: null, bins: bins({0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1, 7: 1, 8: 1, 9: 1, 10: 1, 11: 1}), canFinish: true}); feed({event: "swept", mode: "advanced", lap: 1, filled: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], skipped: [], centreHeld: true, kept: 13}) }, 900)
      at(function () { shoot(m + "-6-swept") }, 600)
    }
    at(function () { }, 500)
  }
}
