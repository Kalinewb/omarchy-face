import QtQuick
import Quickshell
import "face" as Face
import "face/common" as FaceCommon

// An offscreen Setup view, with a fake panel in front of it.
//
// Run by dev/g2-engine-row-offscreen.sh. The live shell cannot always be
// restarted -- a locked session must not be -- and a view that only ever runs
// inside it is a view whose bindings are checked by looking at them. This loads
// the REAL SetupView.qml against the real qs.Commons and qs.Ui, drives it
// through an install.json shape, and prints what it decided.
//
// What it does not do is draw: there is no window, so this says the bindings
// evaluate and agree with the contract, not that the result looks right.
ShellRoot {
  id: rootObj

  readonly property string caseName: Quickshell.env("FACE_HARNESS_CASE") || "running"
  readonly property int nowSeconds: Math.floor(Date.now() / 1000)

  FaceCommon.Ask {
    id: askObj
    pluginDir: Quickshell.env("FACE_HARNESS_PLUGIN") || ""
  }

  QtObject {
    id: fakePanel

    property color foreground: "white"
    property color dim: "grey"
    property string fontFamily: "monospace"
    property string pluginDir: askObj.pluginDir
    property string statusOutcome: "ok"
    property var ask: askObj

    readonly property bool failed: rootObj.caseName === "failed"
    readonly property bool idle: rootObj.caseName === "idle"

    // What the panel carries besides the rows. Setup reads all of it since the
    // post-ship revision that collapses the checklist (SetupView.qml): a
    // stand-in that answered for less than the real panel would be testing a
    // view nobody runs.
    property var status: ({ok: true})
    property var config: ({account: "graveklar", sudo: true, lock: false})
    property var people: ({sudo_faces: 1})
    readonly property bool setupNeeded: true
    readonly property bool attention: fakePanel.failed

    property var rows: [
      {id: "legacy", label: "Old install", state: "ok", detail: "", fixable: false, fix: ""},
      {id: "camera", label: "Infrared camera", state: "ok", detail: "ok", fixable: false, fix: ""},
      {id: "system", label: "Face's system files", state: "ok", detail: "installed", fixable: false, fix: ""},
      {id: "engine", label: "Face engine",
       state: idle ? "needs_action" : failed ? "broken" : "unknown",
       detail: "", fixable: true, fix: "install-engine"},
      {id: "install-job", label: "Engine build", state: "ok", detail: "", fixable: false, fix: ""},
      {id: "people", label: "People", state: "needs_action", detail: "record your face first", fixable: false, fix: ""}
    ]

    property var installDoc: ({
      state: idle ? "idle" : failed ? "failed" : "running",
      step: idle ? "" : "build",
      steps: ["deps", "fetch", "build", "install", "configure", "done"],
      startedAt: idle ? 0 : rootObj.nowSeconds - 185,
      updatedAt: idle ? 0 : rootObj.nowSeconds - 42,
      error: failed ? "dlib_build_failed" : "",
      notes: idle ? [] : ["howdy 2.6.1-3 was already installed"]
    })

    function row(id) {
      for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return rows[i]
      return null
    }
    function refresh() {}
    function reloadWatched() {}
    function pushView(v) {}
  }

  Item {
    width: 400
    height: 900

    Face.SetupView {
      id: setup
      width: 400
      panel: fakePanel
    }

    Timer {
      // Long enough for the log tail's subprocess to answer.
      interval: 1500
      running: true
      onTriggered: {
        var tail = setup.logTail.split("\n").filter(function (l) { return l !== "" })
        console.log("HARNESS case", rootObj.caseName)
        console.log("HARNESS buildState", setup.buildState)
        console.log("HARNESS buildShown", setup.buildShown)
        console.log("HARNESS marks", [0, 1, 2, 3, 4, 5].map(function (i) { return setup.stepMark(i) }).join(""))
        console.log("HARNESS elapsed", setup.elapsedText(185) + "|" + setup.elapsedText(42) + "|" + setup.elapsedText(7265) + "|" + setup.elapsedText(0))
        console.log("HARNESS fixLabel", setup.fixLabel(fakePanel.row("engine")))
        console.log("HARNESS logExpanded", setup.logExpanded)
        console.log("HARNESS tailLines", tail.length)
        console.log("HARNESS tailLast", tail.length > 0 ? tail[tail.length - 1] : "")
        // The delegates, not the model: `install-job` is folded into the
        // engine row by the delegate's own `hidden`, and that is the thing
        // worth checking.
        var shown = 0
        for (var i = 0; i < setup.children.length; i++) {
          var child = setup.children[i]
          if (child && child.hidden !== undefined && !child.hidden) shown++
        }
        console.log("HARNESS rowsRendered", shown)
        console.log("HARNESS height", setup.implicitHeight)
        Qt.exit(0)
      }
    }
  }
}
