import QtQuick
import Quickshell
import Quickshell.Io
import "face" as Face

// Phase 6's GUI half, in a real QML runtime: the Test card and the indicator's
// `identity` states.
//
// Run by dev/g5b-test-card-offscreen.sh. It loads the REAL Service.qml -- which
// owns the card -- calls the same `testMatch(name)` the popup calls over IPC,
// and prints what the service says about itself through the same `state()` a
// live test reads with `omarchy-shell graveklar.face.card state`.
//
// **This one really does put a card on the screen for a second.** The card is a
// layer-shell window; there is no way to instantiate the shipped file without
// one. It takes no keyboard focus and its input region is the card itself, so
// nothing else on the machine notices -- which is itself part of what is being
// checked here.
ShellRoot {
  id: rootObj

  readonly property string caseName: Quickshell.env("FACE_HARNESS_CASE") || "verdict"
  readonly property string person: Quickshell.env("FACE_HARNESS_PERSON") || "anna"

  function log(key, value) { console.log("HARNESS " + key, value) }

  property var handler: null
  property var service: null

  function findHandler() {
    if (rootObj.handler) return rootObj.handler
    var objects = serviceLoader.item.data
    for (var i = 0; i < objects.length; i++)
      if (objects[i] && objects[i].target === "graveklar.face.card") rootObj.handler = objects[i]
    return rootObj.handler
  }

  function report(tag) {
    var document = rootObj.findHandler().state()
    rootObj.log(tag, document)
  }

  Item {
    width: 400
    height: 800

    Loader {
      id: serviceLoader
      active: true
      sourceComponent: Component { Face.Service { omarchyPath: "/usr/share/omarchy" } }
    }

    // Everything is on a clock rather than on signals, because what this suite
    // asks about is a card's behaviour over time: it is up while the helper
    // runs, it says one sentence when the helper answers, and it takes itself
    // away afterwards.
    Timer {
      interval: 700
      running: true
      onTriggered: {
        var answer = rootObj.findHandler().testMatch(rootObj.person)
        rootObj.log("call", answer)
        if (rootObj.caseName === "busy") {
          // A second test for somebody else while the first is up is refused,
          // and the first card is the one that stays.
          rootObj.log("second", rootObj.findHandler().testMatch("mia"))
          rootObj.log("again", rootObj.findHandler().testMatch(rootObj.person))
        }
        checking.start()
      }
    }

    // While the helper is still running: the card is up, it says "Look at the
    // camera", and the indicator has stood down behind it.
    Timer {
      id: checking
      interval: 600
      onTriggered: {
        rootObj.report("checking")
        if (rootObj.caseName === "cancel") {
          // What the Stop button does, through the same IPC verb the popup's
          // Esc would use.
          rootObj.findHandler().cancel()
          cancelled.start()
          return
        }
        answered.start()
      }
    }

    Timer {
      id: answered
      interval: 2000
      onTriggered: {
        rootObj.report("done")
        gone.start()
      }
    }

    Timer {
      id: cancelled
      interval: 600
      onTriggered: {
        rootObj.report("cancelled")
        Qt.exit(0)
      }
    }

    // And then it takes itself away without being asked.
    Timer {
      id: gone
      interval: 3400
      onTriggered: {
        rootObj.report("gone")
        Qt.exit(0)
      }
    }

    Timer {
      interval: 30000
      running: true
      onTriggered: { rootObj.log("timeout", true); Qt.exit(1) }
    }
  }
}
