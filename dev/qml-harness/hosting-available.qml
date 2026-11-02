import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "face" as Face

// Surface.qml's `available`, at creation and after its status read, for
// dev/e2-hosting.sh (vii). It prints `HARNESS available <bool>` twice: once as
// the shell finishes creating it (before the event loop has turned, so no status
// can have answered), once when the status read has landed or 5 s have passed. A stand-in host, as in hosting-panel.qml.
ShellRoot {
  id: shellRoot

  QtObject {
    id: fakeHost
    readonly property int contract: 1
    readonly property bool present: true
    readonly property bool accepted: true
    readonly property bool hidden: false
    readonly property color foreground: Commons.Color.foreground
    readonly property color secondary: Qt.darker(Commons.Color.foreground, 1.55)
    readonly property color accent: Commons.Color.accent
    readonly property color color: "#000000"
    readonly property real radius: 8
    readonly property string fontFamily: Style.font.family
    property bool panelOpen: false
    property string panelRoute: ""
    property string panelScreen: ""
    function radiusFor(size) { return Math.min(radius, size / 2) }
    function openPanel(route, screen) { return "declined:harness" }
    function closePanel() { return "unknown" }
  }

  Face.Surface { id: surface; surfaceHost: fakeHost }

  // Before the event loop has turned once: no status read can have answered.
  Component.onCompleted: console.log("HARNESS available", surface.available)

  Timer {
    id: poll
    interval: 200
    repeat: true
    running: true
    property int ticks: 0
    onTriggered: {
      ticks += 1
      if (surface.model.status === null && ticks < 25) return
      poll.stop()
      // A moment more, for the rows to settle into the binding.
      done.start()
    }
  }

  Timer {
    id: done
    interval: 300
    onTriggered: { console.log("HARNESS available", surface.available); Qt.exit(0) }
  }
}
