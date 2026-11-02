import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "face" as Face

// Face's views in both homes, rendered to a PNG, for dev/e2-hosting.sh (i).
//
//   FACE_HARNESS_CASE   stock    the stock popup's wiring without its window: a
//                                hosted:false FaceModel and FaceViews, as
//                                FacePanel.qml builds them, at the given size
//                                (runs headless)
//                       popup    the stock bar's popup: the REAL FacePanel.qml
//                                (its KeyboardPanel is a layer-shell window, so
//                                this needs a compositor: E2_NESTED=1)
//                       hosted   the notch's panel: the REAL Surface.qml, its
//                                `panel` Component created the way the host
//                                creates it, on a stand-in host
//                       fence    the preview camera's fence (plan-face-enroll.md
//                                6a.1, round-3 notes S1 and S3): two copies of the
//                                hosted panel, one per screen, the enrol view
//                                pushed in process; prints what EnrolView's
//                                `previewOn` is in each as the host's state
//                                changes. Nothing opens a camera: the fixture has
//                                no RGB node, so the Loader that would is never
//                                active, and only the fence's input is read.
//   FACE_HARNESS_ROUTE  setup | people | person:anna
//   FACE_HARNESS_HOST   identity (default) | realistic | other
//                       identity    a host whose palette is the theme's own,
//                                   with accent set to the theme's urgent, so
//                                   the one place the hosted rules change a
//                                   colour (urgent -> the host's accent) draws
//                                   the same pixels and nothing else can differ
//                       realistic   the notch's own rule: accent = the theme's
//                                   accent (the notch's accent equals its
//                                   foreground)
//                       other       an unrelated palette, to show the panel
//                                   follows its host and not the theme
//   FACE_HARNESS_OUT    the PNG to write
//
// It prints `HARNESS key value` lines: the size of what was grabbed and whether
// the grab worked. The stand-in host answers only what a host answers.
ShellRoot {
  id: shellRoot

  readonly property string caseName: Quickshell.env("FACE_HARNESS_CASE") || "stock"
  readonly property string route: Quickshell.env("FACE_HARNESS_ROUTE") || "people"
  readonly property string hostKind: Quickshell.env("FACE_HARNESS_HOST") || "identity"
  readonly property string out: Quickshell.env("FACE_HARNESS_OUT") || "/tmp/face-views.png"
  // "WxH": the size to give the hosted panel, so it can be compared with the
  // stock popup's content at the size that popup chose.
  readonly property var size: (Quickshell.env("FACE_HARNESS_SIZE") || "").split("x").map(Number)
  readonly property real wantW: size.length === 2 && size[0] > 0 ? size[0] : 348
  readonly property real wantH: size.length === 2 && size[1] > 0 ? size[1] : 588

  function log(key, value) { console.log("HARNESS " + key, value) }

  QtObject {
    id: fakeHost
    readonly property int contract: 1
    readonly property var features: ["panel"]
    readonly property string pluginId: "kalinewb.face"
    readonly property bool present: true
    readonly property bool accepted: true
    readonly property bool hidden: false
    readonly property color foreground: shellRoot.hostKind === "other" ? "#ffd166" : Commons.Color.foreground
    readonly property color secondary: shellRoot.hostKind === "other" ? "#9a7b2f" : Qt.darker(Commons.Color.foreground, 1.55)
    readonly property color accent: shellRoot.hostKind === "identity" ? Commons.Color.urgent
                                  : shellRoot.hostKind === "other" ? "#06d6a0" : Commons.Color.accent
    readonly property color color: "#000000"
    readonly property real radius: shellRoot.hostKind === "other" ? 0 : Style.cornerRadius
    readonly property string fontFamily: Style.font.family
    property bool panelOpen: false
    property string panelRoute: ""
    property string panelScreen: ""
    function radiusFor(size) { return Math.max(0, Math.min(radius, size / 2)) }
    function openPanel(route, screen) { return "declined:harness" }
    function closePanel() { return "unknown" }
  }

  property var grabbed: null

  // The `previewOn` of the EnrolView inside `panel`, "none" when the panel is
  // not showing one.
  function previewOnIn(panel) {
    function walk(item) {
      if (item.previewOn !== undefined && item.previewDevice !== undefined) return item
      for (var i = 0; i < item.children.length; i++) {
        var found = walk(item.children[i])
        if (found) return found
      }
      return null
    }
    var view = walk(panel)
    return view ? String(view.previewOn) : "none"
  }

  function liveIn(panel) {
    function walk(item) {
      if (item.previewOn !== undefined && item.previewDevice !== undefined) return item
      for (var i = 0; i < item.children.length; i++) {
        var found = walk(item.children[i])
        if (found) return found
      }
      return null
    }
    var view = walk(panel)
    return view ? String(view.live) : "none"
  }

  property var fenceA: null
  property var fenceB: null
  property int fenceStep: 0

  function reportFence(label) {
    shellRoot.log("fence-" + label, previewOnIn(fenceA) + "," + previewOnIn(fenceB))
  }

  Timer {
    id: fenceTimer
    interval: 400
    repeat: true
    onTriggered: {
      var step = shellRoot.fenceStep++
      if (step === 0) {
        // The Surface pushes the enrol view in process, as PeopleView/PersonView
        // do through the model (S1) -- no route, no panelRoute.
        fakeHost.panelScreen = "T-1"
        fakeHost.panelRoute = "people"
        fakeHost.panelOpen = true
        shellRoot.surface.model.showEnrol("anna", "No glasses", "Anna", false)
      } else if (step === 1) {
        shellRoot.log("fence-view", shellRoot.surface.model.view)
        // Start is what turns the camera on, and the harness presses no Start:
        // before it, previewOn is false on both screens even though one is live.
        shellRoot.reportFence("idle")             // false,false
        shellRoot.log("fence-live", liveIn(fenceA) + "," + liveIn(fenceB))   // true,false
        shellRoot.surface.session.phase = "authorising"
        shellRoot.reportFence("screen1")          // true,false
        fakeHost.panelScreen = "T-2"
      } else if (step === 2) {
        shellRoot.reportFence("screen2")          // false,true
        fakeHost.panelOpen = false
      } else if (step === 3) {
        shellRoot.reportFence("closed")           // false,false
        fakeHost.panelScreen = "T-1"
        fakeHost.panelOpen = true
      } else if (step === 4) {
        shellRoot.reportFence("reopened")         // false,false: a fresh session, no Start yet
        shellRoot.log("fence-reopened-live", liveIn(fenceA) + "," + liveIn(fenceB))   // true,false
        shellRoot.surface.model.navBack()
      } else {
        shellRoot.reportFence("left")             // none,none
        shellRoot.log("fence-session", shellRoot.surface.session === null)
        Qt.exit(0)
      }
    }
  }

  // --- the test result, in place (plan-gui.md 5.2) ---------------------------------
  //
  //   FACE_HARNESS_CASE=test  the hosted panel on person:anna; Test pressed
  //                           (PersonView.test()); the verdict read; Esc. Three
  //                           PNGs: <out>-a (before), -b (the result), -c (after
  //                           Esc), and what each state contains.
  property var testPanel: null
  property int testStep: 0
  function findItem(root, wants) {
    if (wants(root)) return root
    for (var i = 0; i < root.children.length; i++) {
      var found = findItem(root.children[i], wants)
      if (found) return found
    }
    return null
  }
  function pngName(tag) { return shellRoot.out.replace(/\.png$/, "") + "-" + tag + ".png" }
  function grabTo(item, tag, next) {
    item.grabToImage(function (result) {
      shellRoot.log("saved-" + tag, result.saveToFile(shellRoot.pngName(tag)))
      shellRoot.log("size-" + tag, Math.round(item.width) + "x" + Math.round(item.height))
      next()
    })
  }
  function personViewIn(panel) { return findItem(panel, function (i) { return typeof i.test === "function" && i.name !== undefined }) }
  Timer {
    id: testTimer
    interval: 1800
    onTriggered: {
      testTimer.interval = 1500
      var panel = shellRoot.testPanel
      var model = shellRoot.surface.model
      if (shellRoot.testStep === 0) {
        shellRoot.testStep = 1
        testTimer.stop()
        shellRoot.log("before-view", model.view + " person-view " + (shellRoot.personViewIn(panel) !== null))
        shellRoot.grabTo(panel, "a", function () {
          var pv = shellRoot.personViewIn(panel)
          pv.test()
          shellRoot.log("test-view", model.view + " stack " + model.viewStack.length)
          testTimer.start()
        })
      } else if (shellRoot.testStep === 1) {
        shellRoot.testStep = 2
        testTimer.stop()
        var head = shellRoot.findItem(panel, function (i) { return i.objectName === "testHeadline" })
        var sub = shellRoot.findItem(panel, function (i) { return i.objectName === "testSubline" })
        shellRoot.log("headline", head ? head.text : "none")
        shellRoot.log("subline", sub ? sub.text : "none")
        shellRoot.log("during-person-view", shellRoot.personViewIn(panel) !== null)
        shellRoot.log("during-size", Math.round(panel.width) + "x" + Math.round(panel.height) + " implicit " + Math.round(panel.implicitWidth) + "x" + Math.round(panel.implicitHeight))
        shellRoot.grabTo(panel, "b", function () {
          // Esc: the panel's own key handling, which is the model's back().
          model.back()
          testTimer.start()
        })
      } else {
        testTimer.stop()
        shellRoot.log("after-view", model.view + " person-view " + (shellRoot.personViewIn(panel) !== null) + " test-request " + (model.testRequest === null))
        shellRoot.grabTo(panel, "c", function () { Qt.exit(0) })
      }
    }
  }

  function grab(item, label) {
    item.grabToImage(function (result) {
      shellRoot.log("size", Math.round(item.width) + "x" + Math.round(item.height))
      shellRoot.log("saved", result.saveToFile(shellRoot.out))
      Qt.exit(0)
    })
  }

  // Wait for the status read and people.json, then give the views a second to
  // settle (their own transitions), then draw.
  Timer {
    id: settle
    interval: 1800
    onTriggered: {
      if (shellRoot.caseName === "stock") shellRoot.grab(stockFrame, "stock")
      else if (shellRoot.caseName === "popup") shellRoot.grab(shellRoot.stockPanel.viewsItem, "popup")
      else shellRoot.grab(hostedWindow.contentItem.children[0], "hosted")
    }
  }

  // By name, so that a headless run never compiles FacePanel.qml (its window
  // type has no backend without a compositor).
  Loader {
    id: stockLoader
    source: shellRoot.caseName === "popup" ? "face/FacePanel.qml" : ""
    onLoaded: item.bar = null
  }
  readonly property var stockPanel: stockLoader.item

  // The popup's wiring, minus the window: the model FacePanel makes, and the
  // views it puts in its KeyboardPanel.
  Window {
    id: stockWindow
    visible: shellRoot.caseName === "stock"
    width: 340
    height: 900
    color: "black"
    Face.FaceModel { id: stockModel; hosted: false; bar: null; opened: true }
    // The content as the stock popup lays it out, in the margin that every home
    // gives it: KeyboardPanel pads its content by Style.spacing.popupPadding, and
    // the notch's old hostedPanels slot by notchSidePadding, both Style.space(14).
    // The hosted panel (Surface.qml) must add the same margin itself, because an
    // integration's slot in the notch has none, so the frame is what it is
    // compared with: 14 px on every side, nothing behind it.
    Item {
      id: stockFrame
      readonly property real pad: Style.space(14)
      width: shellRoot.wantW
      height: Math.min(stockViews.contentHeight + 2 * pad, shellRoot.wantH)
      Face.FaceViews {
        id: stockViews
        x: stockFrame.pad
        y: stockFrame.pad
        model: stockModel
        width: stockFrame.width - 2 * stockFrame.pad
        height: stockFrame.height - 2 * stockFrame.pad
      }
    }
  }

  Loader {
    id: surfaceLoader
    active: shellRoot.caseName === "hosted" || shellRoot.caseName === "fence" || shellRoot.caseName === "test"
    sourceComponent: Component { Face.Surface { surfaceHost: fakeHost } }
  }
  readonly property var surface: surfaceLoader.item

  Window {
    id: hostedWindow
    visible: shellRoot.caseName === "hosted" || shellRoot.caseName === "fence" || shellRoot.caseName === "test"
    width: 340
    height: 900
    color: "black"
  }

  Timer {
    interval: 250
    repeat: true
    running: true
    property int ticks: 0
    onTriggered: {
      ticks += 1
      if (ticks > 80) { shellRoot.log("timeout", "no status/people in 20 s"); Qt.exit(1); return }
      if (shellRoot.caseName === "stock" || shellRoot.caseName === "popup") {
        var m = shellRoot.caseName === "stock" ? stockModel : shellRoot.stockPanel
        if (!m || m.status === null || m.people === null) return
        running = false
        var parts = shellRoot.route.split(":")
        m.openAt(parts[0], parts.length > 1 ? parts[1] : "")
        settle.start()
        return
      }
      if (!shellRoot.surface || !shellRoot.surface.available || shellRoot.surface.model.people === null) return
      running = false
      if (shellRoot.caseName === "fence") {
        shellRoot.fenceA = shellRoot.surface.panel.createObject(hostedWindow.contentItem, {
          surfaceHost: fakeHost, surfaceScreen: "T-1", maxWidth: 400, maxHeight: 900 })
        shellRoot.fenceB = shellRoot.surface.panel.createObject(hostedWindow.contentItem, {
          surfaceHost: fakeHost, surfaceScreen: "T-2", maxWidth: 400, maxHeight: 900 })
        fenceTimer.start()
        return
      }
      fakeHost.panelScreen = "T-1"
      fakeHost.panelRoute = shellRoot.route
      fakeHost.panelOpen = true
      var panel = shellRoot.surface.panel.createObject(hostedWindow.contentItem, {
        surfaceHost: fakeHost, surfaceScreen: "T-1", maxWidth: shellRoot.wantW, maxHeight: shellRoot.wantH
      })
      panel.open(shellRoot.route)
      shellRoot.log("available", shellRoot.surface.available)
      var fv = shellRoot.findItem(panel, function (i) { return i.previewLive !== undefined && i.model !== undefined })
      if (fv) shellRoot.log("insets", "left " + Math.round(fv.x) + " top " + Math.round(fv.y)
                            + " right " + Math.round(panel.width - fv.x - fv.width)
                            + " bottom " + Math.round(panel.implicitHeight - fv.y - fv.height)
                            + " implicit " + Math.round(panel.implicitWidth) + "x" + Math.round(panel.implicitHeight))
      if (shellRoot.caseName === "test") { shellRoot.testPanel = panel; testTimer.start(); return }
      settle.start()
    }
  }
}
