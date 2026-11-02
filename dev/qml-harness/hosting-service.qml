import QtQuick
import Quickshell
import Quickshell.Io
import "face" as Face

// The Face service on its own, for dev/e2-hosting.sh.
//
// The service is where `record` is routed (to the notch or to the card), so the
// routing cases (ii), (iv), (v) and the cross-home busy answers load the REAL
// Service.qml and call its IPC target the way `omarchy-shell kalinewb.face.card
// record ...` does. Nothing here is a copy of the logic under test: the harness
// only quits.
ShellRoot {
  Face.Service { omarchyPath: "/usr/share/omarchy" }

  IpcHandler {
    target: "harness"
    function quit(): string { Qt.quit(); return "ok" }
  }
}
