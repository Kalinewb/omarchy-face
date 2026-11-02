import QtQuick
import Quickshell
import Quickshell.Io
import "face" as Face

// NotchRoute.qml on its own, for dev/e2-hosting.sh (ii), (iv) and (v). It runs
// without a compositor: the router opens nothing, it only answers `record` and
// says `cardRequested` when the answer is "the card". This is the REAL
// NotchRoute.qml reading the real heartbeat and enrol.json files the test
// writes; the service wraps it (Service.qml) and turns `cardRequested` into the
// card window, which dev/g3-people-offscreen.sh covers.
ShellRoot {
  id: shellRoot

  property var cards: []

  Face.NotchRoute {
    id: router
    onCardRequested: function (name, appearance, label, isNew) {
      shellRoot.cards = shellRoot.cards.concat([{ name: name, appearance: appearance, label: label, isNew: isNew }])
    }
  }

  IpcHandler {
    target: "harness"
    function record(name: string, appearance: string, label: string, isNew: string): string {
      return router.record(name, appearance, label, isNew === "new")
    }
    function state(): string {
      return JSON.stringify({ pending: router.notchPending ? router.notchPending.name : "", cards: shellRoot.cards })
    }
    function clear(): string { shellRoot.cards = []; router.notchPending = null; return "ok" }
    function quit(): string { Qt.quit(); return "ok" }
  }
}
