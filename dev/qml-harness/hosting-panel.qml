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
//                       test     Test pressed in the hosted panel (see below)
//                       record   Scan pressed in the hosted panel: it must ask
//                                the Face service for its card and close the
//                                panel, and show no recording of its own
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

  // --- the test result, in place (plan-gui.md 5.2) ---------------------------------
  //
  //   FACE_HARNESS_CASE=test  the hosted panel on person:anna; Test pressed
  //                           (PersonView.test()); the verdict read; Esc. Three
  //                           PNGs: <out>-a (before), -b (the result), -c (after
  //                           Esc), and what each state contains.
  property var testPanel: null
  property int closes: 0
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

  // --- Scan, in the hosted panel: the standalone card, and the panel closes -------------------
  //
  //   FACE_HARNESS_CASE=record  People (route people) or Person (route person:anna):
  //                             the Scan button's own function is called. The panel
  //                             must not show a recording (no enrol view, no
  //                             session), must close itself (closeRequested), and
  //                             the call that reaches the shell is the service's
  //                             `kalinewb.face.card record` (logged by the stub).
  Timer {
    id: recordTimer
    interval: 1800
    onTriggered: {
      recordTimer.stop()
      var panel = shellRoot.testPanel
      var model = shellRoot.surface.model
      var pv = shellRoot.findItem(panel, function (i) { return typeof i.record === "function" && i.note !== undefined })
      shellRoot.log("button", pv ? "found" : "none")
      shellRoot.log("before", model.view + " closes " + shellRoot.closes)
      if (shellRoot.route === "people") pv.record("anna", "No glasses", "Anna", false)
      else pv.record("No glasses")
      shellRoot.log("after", model.view + " closes " + shellRoot.closes + " stack " + model.viewStack.length)
      Qt.callLater(function () { recordExit.start() })
    }
  }
  Timer { id: recordExit; interval: 900; onTriggered: Qt.exit(0) }

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
    active: shellRoot.caseName === "hosted" || shellRoot.caseName === "test" || shellRoot.caseName === "record"
    sourceComponent: Component { Face.Surface { surfaceHost: fakeHost } }
  }
  readonly property var surface: surfaceLoader.item

  Window {
    id: hostedWindow
    visible: shellRoot.caseName === "hosted" || shellRoot.caseName === "test" || shellRoot.caseName === "record"
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
      fakeHost.panelScreen = "T-1"
      fakeHost.panelRoute = shellRoot.route
      fakeHost.panelOpen = true
      var panel = shellRoot.surface.panel.createObject(hostedWindow.contentItem, {
        surfaceHost: fakeHost, surfaceScreen: "T-1", maxWidth: shellRoot.wantW, maxHeight: shellRoot.wantH
      })
      panel.open(shellRoot.route)
      shellRoot.log("available", shellRoot.surface.available)
      var fv = shellRoot.findItem(panel, function (i) { return i.focusItem !== undefined && i.model !== undefined && i.contentHeight !== undefined })
      if (fv) shellRoot.log("insets", "left " + Math.round(fv.x) + " top " + Math.round(fv.y)
                            + " right " + Math.round(panel.width - fv.x - fv.width)
                            + " bottom " + Math.round(panel.implicitHeight - fv.y - fv.height)
                            + " implicit " + Math.round(panel.implicitWidth) + "x" + Math.round(panel.implicitHeight))
      if (shellRoot.caseName === "test") { shellRoot.testPanel = panel; testTimer.start(); return }
      if (shellRoot.caseName === "record") { shellRoot.testPanel = panel; panel.closeRequested.connect(function () { shellRoot.closes += 1 }); recordTimer.start(); return }
      settle.start()
    }
  }
}
