import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "face" as Face

// Face's views in both homes, rendered to a PNG, for dev/e2-hosting.sh (i).
//
//   FACE_HARNESS_CASE   stock    the stock bar's popup: the REAL FacePanel.qml
//                       hosted   the notch's panel: the REAL Surface.qml, its
//                                `panel` Component created the way the host
//                                creates it, on a stand-in host
//                       fence    the preview camera's fence (plan-face-enroll.md
//                                6a.1, round-3 notes S1 and S3): two copies of the
//                                hosted panel, one per screen, the enrol view
//                                pushed in process; prints what RecordView's
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
  readonly property real wantW: size.length === 2 && size[0] > 0 ? size[0] : 400
  readonly property real wantH: size.length === 2 && size[1] > 0 ? size[1] : 900

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

  // The `previewOn` of the RecordView inside `panel`, "none" when the panel is
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
        shellRoot.reportFence("reopened")         // true,false
        shellRoot.surface.model.navBack()
      } else {
        shellRoot.reportFence("left")             // none,none
        shellRoot.log("fence-session", shellRoot.surface.session === null)
        Qt.exit(0)
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
      if (shellRoot.caseName === "stock") shellRoot.grab(shellRoot.stockPanel.viewsItem, "stock")
      else shellRoot.grab(hostedWindow.contentItem.children[0], "hosted")
    }
  }

  Loader {
    id: stockLoader
    active: shellRoot.caseName === "stock"
    sourceComponent: Component { Face.FacePanel { bar: null } }
  }
  readonly property var stockPanel: stockLoader.item

  Loader {
    id: surfaceLoader
    active: shellRoot.caseName === "hosted" || shellRoot.caseName === "fence"
    sourceComponent: Component { Face.Surface { surfaceHost: fakeHost } }
  }
  readonly property var surface: surfaceLoader.item

  Window {
    id: hostedWindow
    visible: shellRoot.caseName === "hosted" || shellRoot.caseName === "fence"
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
      if (shellRoot.caseName === "stock") {
        var m = shellRoot.stockPanel
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
      settle.start()
    }
  }
}
