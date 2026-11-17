import QtQuick
import Quickshell
import Quickshell.Io
import "face" as Face

// The Face service asking the notch to step aside while a card is up, in a real QML runtime.
//
// Run by dev/h2-notch-quiet.sh. It loads the REAL Service.qml and drives the same IPC verbs the popup
// calls (`testMatch`, `record`, `cancel`); what the notch would have been told is read from a log
// the suite's stand-in for `omarchy-shell notch quiet` writes (OMARCHY_FACE_DEV_QUIET_CMD).
//
// **It briefly puts a real card on the screen**, as g5b-test-card-offscreen.sh does: a layer-shell
// window cannot be avoided. The Test card takes no focus; the recording card does, for a second.
//
// Cases (FACE_HARNESS_CASE):
//   test       a Test that runs 2 s, answers, and is dismissed by the service
//   stop       a Test, stopped by the person after 0.8 s
//   record     a recording card, cancelled with Esc after 1.2 s
//   renew      a long Test (3 s) with the lease renewed every 1 s
//   idle       nothing asked for; only a `sudo` in flight, which the indicator draws
//   teardown   a Test, then the service is destroyed with the card still up
ShellRoot {
  id: rootObj

  readonly property string caseName: Quickshell.env("FACE_HARNESS_CASE") || "test"
  readonly property string person: Quickshell.env("FACE_HARNESS_PERSON") || "anna"

  function log(key, value) { console.log("HARNESS " + key, value) }

  property var handler: null

  function findHandler() {
    if (rootObj.handler) return rootObj.handler
    var objects = serviceLoader.item.data
    for (var i = 0; i < objects.length; i++)
      if (objects[i] && objects[i].target === "kalinewb.face.card") rootObj.handler = objects[i]
    return rootObj.handler
  }

  Item {
    width: 400
    height: 800

    Loader {
      id: serviceLoader
      active: true
      sourceComponent: Component { Face.Service { omarchyPath: "/usr/share/omarchy" } }
    }


    Timer {
      interval: 700
      running: true
      onTriggered: {
        var c = rootObj.caseName
        if (c === "idle") { idleEnd.start(); return }
        if (c === "record") {
          rootObj.log("call", rootObj.findHandler().record(rootObj.person, "No glasses", "Anna", ""))
          recordCancel.start()
          return
        }
        rootObj.log("call", rootObj.findHandler().testMatch(rootObj.person))
        if (c === "stop") stopIt.start()
        else if (c === "teardown") teardown.start()
        else end.start()
      }
    }

    Timer { id: stopIt; interval: 800; onTriggered: { rootObj.findHandler().cancel(); end.interval = 600; end.start() } }
    Timer { id: recordCancel; interval: 1200
      onTriggered: { rootObj.log("state", rootObj.findHandler().state()); rootObj.findHandler().cancel(); end.interval = 2500; end.start() } }
    Timer { id: teardown; interval: 900
      onTriggered: { rootObj.log("teardown", true); serviceLoader.active = false; end.interval = 800; end.start() } }
    Timer { id: idleEnd; interval: 1500; onTriggered: { rootObj.log("state", rootObj.findHandler().state()); Qt.exit(0) } }
    // Long enough for the Test to answer, be shown for 3.2 s and be dismissed by the service.
    Timer { id: end; interval: rootObj.caseName === "renew" ? 6500 : 5800
      onTriggered: { rootObj.log("ended", Date.now()); Qt.exit(0) } }

    Timer { interval: 30000; running: true; onTriggered: { rootObj.log("timeout", true); Qt.exit(1) } }
  }
}
