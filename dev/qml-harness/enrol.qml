import QtQuick
import QtQuick.Window
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "face" as Face
import "face/common/enrolring.js" as Ring

// The enrol view, offscreen, for dev/e3-enrol-view.sh (plan-face-enroll.md
// section 7.4, Phase 4). The REAL EnrolView.qml, EnrolRing.qml and
// RecordSession.qml, against the running Omarchy's qs.Commons and qs.Ui, driven
// by a FAKE root session that enforces table V: it answers `sweep`, `finish`,
// `abort` and `done` the way the real parent does, counts every verb the table
// refuses, and is fed the engine's events by the scripts below. Nothing is
// asked of a camera: the preview the circle would hold is a counting stand-in,
// so "no camera in idle" is a count of zero and not a promise.
//
//   E3_CASE   simple | advanced | esc | fail | skew | plain | reduced | fence |
//             mode | strip
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
  readonly property bool reducedCase: caseName === "reduced"

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
  property var verbs: ["capture", "sweep", "abort", "finish"]

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
      var simple = c.mode === "simple" && c.lap === 1 && sameBins(c.targets, [0, 3, 6, 9])
                   && c.targets.join(",") === "9,3,0,6"
      var advanced = c.mode === "advanced" && c.lap === 1 && sameBins(c.targets, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
      if (!((s === "ready" || s === "swept") && (simple || advanced))) {
        violations++
        emit({event: "capture_failed", code: "bad_sweep"})
        return
      }
      fakeState = "running"
      emit({event: "sweeping", mode: c.mode, lap: 1,
            targets: c.targets.slice().sort(function (x, y) { return x - y }), quota: 2})
      return
    }
    if (c.cmd === "finish") return          // ignored unless a lap runs; the script answers it
    if (c.cmd === "abort") {
      if (s === "running") { fakeState = "ready"; emit({event: "aborted"}) }
      return
    }
    if (c.cmd === "done") {
      if (s !== "swept") { violations++; emit({event: "capture_failed", code: "bad_sweep"}); return }
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
        stored: shellRoot.stored
        onFinished: function (saved) { shellRoot.finishedCount += 1; shellRoot.finishedSaved = saved }
      }
    }
  }

  property bool live: true
  Window {
    id: win
    visible: true
    width: 360
    height: 760
    color: "#000000"

    Loader {
      id: viewLoader
      active: sessionLoader.item !== null
      width: 320
      x: 20
      y: 10
      sourceComponent: Component {
        Face.EnrolView {
          session: shellRoot.session
          colors: harnessColors
          // The strip draws the ring without a preview: the offscreen scene graph has no
          // shader effects, so a layered (masked) circle paints nothing there.
          previewDevice: shellRoot.caseName === "strip" ? "" : "/dev/video-fake"
          previewComponent: stub
          live: shellRoot.live
          onCloseRequested: shellRoot.session.requestClose()
        }
      }
    }
  }
  readonly property var view: viewLoader.item

  // ---- looking at the view -------------------------------------------------------------------
  function find(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = find(kids[i], name)
      if (found) return found
    }
    return null
  }
  function ring() { return find(view, "ring") }
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
  function links() {
    return ["cancelLink", "startLink", "doneLink", "againLink", "overLink", "modeLink"]
      .map(function (n) { return n.replace("Link", "") + "=" + linkState(n) }).join(" ")
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
    if (ev.event === "capture_failed" && ["not_enough", "sweep_stalled"].indexOf(ev.code) < 0) fakeState = "ready"
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
  Timer {
    id: stepper
    interval: 70
    onTriggered: {
      if (shellRoot.stepAt >= shellRoot.steps.length) { Qt.exit(0); return }
      var st = shellRoot.steps[shellRoot.stepAt++]
      try { st.fn() } catch (e) { shellRoot.log("exception", String(e) + " at step " + (shellRoot.stepAt - 1)) }
      stepper.interval = st.wait
      stepper.restart()
    }
  }
  Timer {
    interval: 90000
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
    if (c === "simple") buildSimple()
    else if (c === "advanced") buildAdvanced()
    else if (c === "esc") buildEsc()
    else if (c === "fail") buildFail()
    else if (c === "skew") buildSkew()
    else if (c === "plain") buildPlain()
    else if (c === "reduced") buildReduced()
    else if (c === "hairline") buildHairline()
    else if (c === "fence") buildFence()
    else if (c === "mode") buildMode()
    else if (c === "strip") buildStrip()
  }

  // ---- Simple ----------------------------------------------------------------------------------------
  function buildSimple() {
    at(function () {
      log("idle-phase", session.phase)
      log("idle-mode", view.mode)
      log("idle-ticks", Ring.TICKS + " " + (tick(0) !== null) + " " + (tick(59) !== null) + " " + (tick(60) === null))
      log("idle-targets", [9, 3, 0, 6].map(function (k) { return binKinds(k) }).join(" | "))
      log("idle-target-look", binLook(9))
      log("idle-inactive", [1, 2, 4, 5, 7, 8, 10, 11].map(function (k) { return binLook(k) }).filter(function (v, i, a) { return a.indexOf(v) === i }).join(" | "))
      log("idle-glyph", named("glyph").visible)
      log("idle-cameras", cameras + " " + view.previewOn + " " + (named("previewLoader").item === null))
      log("idle-line", line())
      log("idle-links", links())
      log("idle-modelink", named("modeLink").text)
      log("idle-descr", ring().description)
      log("idle-state", session.scanState + " " + sent.length)
    }, 700)
    at(function () { session.start() })
    at(function () {
      log("auth-phase", session.phase)
      log("auth-cameras", cameras + " " + view.previewOn)
      log("auth-line", line())
      log("auth-links", links())
      log("mode-after-start", session.modeFixed)
      session.setMode("advanced")
      log("mode-inert-after-start", session.mode)
      ready(true)
    })
    at(function () {
      log("centre-sent", JSON.stringify(sent))
      log("centre-phase", session.phase + " " + session.scanState)
      log("centre-line", line())
      log("centre-cameras", cameras)
      track({state: "searching", centre: 0})
    })
    at(function () { log("centre0-line", line()); track({state: "hold", centre: 0.5, u: 0.1, v: 0.1}) })
    at(function () {
      log("centre50-line", line())
      log("centre50-arc", ring().arc)
      log("centre50-dot", JSON.stringify(dotInfo()))
      log("centre50-links", links())
      track({state: "hold", centre: 1.0, target: 9, u: 0, v: 0})
    })
    at(function () {
      log("lap1-phase", session.phase)
      log("lap1-arc", ring().arc)
      log("lap1-line", line())
      log("lap1-cur", binLook(9) + " | " + binKinds(9))
      log("lap1-rest", binLook(3) + " | " + binLook(0) + " | " + binLook(6))
      log("lap1-inactive", binLook(1) + " | " + binLook(5))
      log("lap1-links", links())
      log("lap1-descr", ring().description)
      track({state: "hold", target: 9, centre: 1, bins: bins({9: 0.4}), u: -1.5, v: 0})
    })
    at(function () {
      log("p40-line", line())
      log("p40-kinds", binKinds(9))
      log("p40-look", binLook(9))
      log("p40-descr", ring().description)
      log("p40-dot", JSON.stringify(dotInfo()))
      // Dot at the engine's ring angle: u -1.5 is the left, 270 degrees.
      track({state: "hold", target: 9, centre: 1, bins: bins({9: 0.55}), u: -1.5, v: 0})
    })
    at(function () {
      log("p55-look", binLook(9))
      // 9 fills: the next arc and its line change in the same frame.
      track({state: "hold", target: 3, centre: 1, bins: bins({9: 1}), u: 0.1, v: 0.1})
    })
    at(function () {
      log("next-line", line())
      log("next-9", binLook(9) + " | " + binKinds(9))
      log("next-3", binLook(3) + " | " + binKinds(3))
      log("next-descr", ring().description)
      log("next-dot-absent", JSON.stringify(dotInfo()))
      track({state: "over", target: 3, centre: 1, bins: bins({9: 1}), u: 3.0, v: 0.2})
    })
    at(function () {
      log("over-line", line())
      track({state: "edge", target: 3, centre: 1, bins: bins({9: 1}), u: 1, v: 0})
    })
    at(function () {
      log("edge-line", line())
      track({state: "hold", target: 3, centre: 1, bins: bins({9: 1, 3: 0.4}), u: 1.4, v: 0})
    })
    at(function () {
      log("three-descr", ring().description)
      log("three-line", line())
      track({state: "hold", target: 0, centre: 1, bins: bins({9: 1, 3: 1}), u: 0, v: -1.4})
    })
    at(function () {
      track({state: "hold", target: 6, centre: 1, bins: bins({9: 1, 3: 1}), skipped: [0], u: 0, v: 1.4})
    })
    at(function () {
      log("skip-line", line())
      log("skip-rest", binLook(0) + " | " + binKinds(0))
      // Every bin full in a track does NOT show Done in Simple; it arrives with swept.
      track({state: "hold", target: 6, centre: 1, bins: bins({9: 1, 3: 1, 0: 1, 6: 1}), canFinish: true, u: 0, v: 1.4})
    })
    at(function () {
      log("allfull-links", links())
      feed({event: "swept", mode: "simple", lap: 1, filled: [0, 3, 6, 9], skipped: [], centreHeld: true, kept: 5})
    })
    at(function () {
      log("swept-line", line())
      log("swept-links", links())
      log("swept-state", session.scanState + " " + session.captures)
      log("swept-filled", [9, 3, 0, 6].map(function (k) { return binLook(k).split(" ")[0] }).join(" "))
      log("swept-check", named("check").visible + " " + named("check").width + " " + named("check").drawn + " " + named("check").x + "," + named("check").y)
      // Start over after the lap ended: lap 1 at once, same mode.
      view.session.startOver()
    })
    at(function () {
      log("again-sent", JSON.stringify(sent.slice(-1)))
      log("again-ring", binLook(9) + " | " + session.phase)
      log("again-violations", violations)
      track({state: "hold", centre: 1, target: 9})
    })
    at(function () {
      // Start over while a lap runs: abort, wait for aborted, then lap 1.
      var before = sent.length
      session.startOver()
      log("over-while-running", sent.slice(before).map(function (c) { return c.cmd + (c.mode ? ":" + c.mode : "") }).join(","))
    })
    at(function () {
      log("over-after-aborted", sent.slice(-2).map(function (c) { return c.cmd + (c.mode ? ":" + c.mode : "") }).join(","))
      track({state: "hold", centre: 1, target: 9})
      feed({event: "swept", mode: "simple", lap: 1, filled: [0, 3, 9], skipped: [6], centreHeld: true, kept: 3})
    })
    at(function () {
      log("kept3-line", line())
      log("kept3-skipped-rest", binLook(6))
      // Done on swept sends done, which ends the session.
      view.activate()
    })
    at(function () {
      log("done-sent", sent[sent.length - 1].cmd)
      log("done-finished", finishedCount + " " + finishedSaved)
      log("violations", violations)
      log("capture-never", sentCmds().indexOf("capture") < 0)
      log("finish-never-simple", sentCmds().indexOf("finish") < 0)
      // The look's contrast over #000 (section 3), for this palette and two more:
      // a theme whose accent equals its foreground and a coloured one.
      var pals = {theme: harnessColors.accent, mono: harnessColors.foreground, coloured: "#34c759"}
      for (var name in pals) {
        var acc = pals[name]
        log("contrast-" + name, [
          r1(contrastOf(harnessColors.secondary, Ring.REST_OPACITY)),
          r1(contrastOf(harnessColors.foreground, 1.0)),
          r1(contrastOf(acc, Ring.DONE_OPACITY)),
          r1(contrastOf(harnessColors.secondary, 0.7)),
          r1(Ring.contrast(Ring.over(rgb(Qt.color(acc)), Ring.DONE_OPACITY), Ring.over(rgb(harnessColors.secondary), Ring.REST_OPACITY)))
        ].join(" "))
      }
    })
  }

  // ---- Advanced -----------------------------------------------------------------------------------------
  function buildAdvanced() {
    at(function () {
      session.setMode("advanced")
      log("adv-mode", view.mode + " " + session.mode)
      log("adv-idle-modelink", named("modeLink").text)
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
    at(function () { log("reduced-glyph-rot", named("glyph").rotation) })
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
    at(function () { log("glyph-tilts-once", named("glyph").rotation + " " + view.tilted) }, 10)
  }

  // ---- the preview fence (6a.1) -------------------------------------------------------------------------------------
  function buildFence() {
    at(function () { }, 1700)
    at(function () { log("fence-idle", cameras + " " + view.previewOn + " " + session.previewWanted + " tilt " + (Math.abs(named("glyph").rotation) > 3)) }, 300)
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
      log("mode-allowed", session.simpleAllowed + " " + session.activeMode + " link " + linkState("modeLink") + " " + named("modeLink").text)
    }, 1800)
    at(function () {
      log("mode-settled", view.mode)
      if (act === "click") {
        named("modeLink").clicked()
        log("mode-clicked", view.mode)
      } else if (act === "start") {
        session.start()
      }
    }, 100)
    at(function () {
      if (act === "start") {
        log("mode-start-phase", session.phase + " " + linkState("modeLink"))
        session.setMode("advanced")
        log("mode-after-start-click", session.mode)
      }
      // The view is not hung: Start still works.
      if (act === "none") session.start()
    }, 300)
    at(function () { log("mode-start-works", session.phase) }, 1200)
  }

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
    at(function () { if (m === "advanced") session.setMode("advanced") }, 3500)
    at(function () { shoot(m + "-1-idle") }, 250)
    at(function () { session.start() })
    at(function () { ready(true) })
    at(function () { track({state: "hold", centre: 0.5, u: 0.1, v: 0}) }, 250)
    at(function () { shoot(m + "-2-centre") }, 400)
    if (m === "simple") {
      at(function () { track({state: "hold", centre: 1, target: 9, bins: bins({9: 0.3}), u: -1.4, v: 0.2}) }, 700)
      at(function () { shoot(m + "-3-left30") }, 400)
      at(function () { track({state: "hold", centre: 1, target: 9, bins: bins({9: 0.8}), u: -1.5, v: 0.1}) }, 700)
      at(function () { shoot(m + "-4-left80") }, 400)
      at(function () { track({state: "hold", centre: 1, target: 3, bins: bins({9: 1, 3: 0.5}), u: 1.5, v: 0}) }, 800)
      at(function () { shoot(m + "-5-right50") }, 400)
      at(function () { track({state: "hold", centre: 1, target: 6, bins: bins({9: 1, 3: 1, 0: 1, 6: 0.4}), u: 0, v: 1.3}) }, 900)
      at(function () { shoot(m + "-6-down40") }, 400)
      at(function () { track({state: "hold", centre: 1, target: 6, bins: bins({9: 1, 3: 1, 0: 1, 6: 1}), u: 0, v: 1.3}); feed({event: "swept", mode: "simple", lap: 1, filled: [0, 3, 6, 9], skipped: [], centreHeld: true, kept: 5}) }, 900)
      at(function () { shoot(m + "-7-swept") }, 600)
    } else {
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
