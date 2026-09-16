import QtQuick
import Quickshell
import Quickshell.Io
import "face" as Face
import "face/common" as FaceCommon
import "face/common/names.js" as Names

// The phase-4 views and the recording session, offscreen.
//
// Run by dev/g3-people-offscreen.sh. It loads the REAL PeopleView.qml,
// PersonView.qml and RecordSession.qml against the running Omarchy's qs.Commons
// and qs.Ui, with a fake panel in front of them, and prints what they decided.
//
// The recording cases are the interesting ones, because the phase-4 gate is
// about timing and cancellation rather than about pixels:
//
//   record-slow  a session whose `ready` is ten seconds late (the stand-in for
//                a slow polkit dialog) still gets a full 3-2-1 afterwards
//   record-esc   Esc before any capture closes stdin -- it does not signal --
//                and the session ends `discarded`
//
// It draws nothing, so it cannot say the views look right; it says every
// binding in them evaluates and agrees with the contract.
ShellRoot {
  id: rootObj

  readonly property string caseName: Quickshell.env("FACE_HARNESS_CASE") || "people"
  readonly property string statePath: Quickshell.env("OMARCHY_FACE_DEV_STATE") || ""

  // The recording timeline, measured here rather than inside the session: the
  // session's job is to be right, not to time itself.
  property double startedAt: 0
  property double readyAt: 0
  property double captureAt: 0
  property var counts: []

  function log(key, value) { console.log("HARNESS " + key, value) }

  FaceCommon.Ask {
    id: askObj
    pluginDir: Quickshell.env("FACE_HARNESS_PLUGIN") || ""
  }

  FileView {
    id: peopleFile
    path: rootObj.statePath + "/people.json"
    preload: true
    blockLoading: true
    printErrors: false
  }

  QtObject {
    id: fakePanel

    property color foreground: "white"
    property color dim: "grey"
    property string fontFamily: "monospace"
    property string pluginDir: askObj.pluginDir
    property string statusOutcome: "ok"
    property var ask: askObj
    property string personName: Quickshell.env("FACE_HARNESS_PERSON") || "anna"
    property var config: ({
      account: "graveklar",
      // Both machine-wide switches are env-driven, because the caption under
      // each per-person switch is what says the machine-wide one is off.
      // sudo defaults ON, which is what every case before this one assumed.
      sudo: Quickshell.env("FACE_HARNESS_SUDO") !== "0",
      lock: Quickshell.env("FACE_HARNESS_LOCK") === "1"
    })

    property var people: {
      try { return JSON.parse(peopleFile.text()) } catch (error) { return null }
    }

    property var rows: [
      {id: "engine", label: "Face engine",
       state: Quickshell.env("FACE_HARNESS_NO_ENGINE") === "1" ? "needs_action" : "ok",
       detail: "", fixable: false, fix: ""},
      {id: "people", label: "People", state: "ok", detail: "", fixable: false, fix: ""}
    ]

    function row(id) {
      for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return rows[i]
      return null
    }
    function rowState(id) { var found = row(id); return found ? String(found.state) : "" }
    function refresh() {}
    function reloadWatched() {}
    function close() { rootObj.log("popupClosed", true) }
    function openPerson(name) { rootObj.log("openedPerson", name) }
    function navBack() { rootObj.log("navBack", true) }
  }

  Item {
    width: 400
    height: 1200

    Loader {
      id: peopleLoader
      active: rootObj.caseName === "people"
      sourceComponent: Component { Face.PeopleView { width: 400; panel: fakePanel } }
    }

    Loader {
      id: personLoader
      active: rootObj.caseName.indexOf("person") === 0
      sourceComponent: Component { Face.PersonView { width: 400; panel: fakePanel } }
    }

    // The card and the service, instantiated but never shown: a layer-shell
    // window on somebody's screen is not something a test should open, and what
    // this case is for is the other half -- that both files compile and their
    // bindings evaluate, which the view cases cannot say.
    Loader {
      id: cardLoader
      active: rootObj.caseName === "card"
      sourceComponent: Component {
        Face.RecordCard {
          visible: false
          session: sessionLoader.item
          previewDevice: ""
          fontFamily: "monospace"
        }
      }
    }

    Loader {
      id: serviceLoader
      active: rootObj.caseName === "card"
      sourceComponent: Component { Face.Service { omarchyPath: "/usr/share/omarchy" } }
    }

    Loader {
      id: sessionLoader
      active: rootObj.caseName.indexOf("record") === 0 || rootObj.caseName === "card"
      sourceComponent: Component {
        Face.RecordSession {
          id: sessionItem
          ask: askObj
          name: "anna"
          label: "Anna"
          appearance: "Everyday glasses"
          isNew: false

          onPhaseChanged: {
            var now = Date.now()
            rootObj.log("phaseAt", phase + " " + Math.round(now - rootObj.startedAt))
            // `countdown` is the first phase after `ready`: the session enters
            // it from the event itself, so this is when authorisation landed.
            if (phase === "countdown" && rootObj.readyAt === 0) rootObj.readyAt = now
            if (phase === "capturing" && rootObj.captureAt === 0) rootObj.captureAt = now
            if (phase === "countdown" && rootObj.caseName === "record-esc")
              sessionItem.requestClose()
            // The session object destroyed while its process is still running,
            // which is what closing a card used to do (the Process belongs to
            // Ask, not to the session). Nothing is left to cancel it, so the
            // session itself has to close its stdin on the way out
            // (plan-engine.md §12 risk 9).
            if (phase === "countdown" && rootObj.caseName === "record-orphan") {
              sessionLoader.active = false
              orphanTimer.start()
            }
            if (phase === "verdict" && rootObj.caseName === "record-slow") sessionItem.done()
            // A session-fatal error leaves the card up in `framing` with its
            // reason on it, so nothing finishes: the run ends here instead.
            if (phase === "framing" && message !== "") {
              rootObj.log("case", rootObj.caseName)
              rootObj.log("captures", captures)
              rootObj.log("saved", false)
              rootObj.log("message", message)
              Qt.exit(0)
            }
          }

          onCountdownChanged: if (countdown > 0) rootObj.counts.push(countdown)

          onFinished: function (saved) {
            rootObj.log("case", rootObj.caseName)
            rootObj.log("readyDelayMs", Math.round(rootObj.readyAt - rootObj.startedAt))
            rootObj.log("countdownValues", rootObj.counts.join(","))
            rootObj.log("countdownMs",
                        rootObj.captureAt > 0 ? Math.round(rootObj.captureAt - rootObj.readyAt) : -1)
            rootObj.log("captures", sessionItem.captures)
            rootObj.log("saved", saved)
            rootObj.log("message", sessionItem.message)
            Qt.exit(0)
          }
        }
      }
    }

    Timer {
      interval: 300
      running: true
      onTriggered: {
        if (rootObj.caseName === "names") {
          // The gate's three cases, and the ones behind them
          // (plan-gui.md §5.4, plan-merged.md §4 phase 4).
          var taken = ["anna", "graveklar", "mia"]
          rootObj.log("ase", Names.derive("Åse", taken))
          rootObj.log("twoKids", Names.derive("2 Kids", taken))
          rootObj.log("annaAgain", Names.derive("Anna", taken))
          rootObj.log("annaThird", Names.derive("Anna", taken.concat(["anna-2"])))
          rootObj.log("bjorn", Names.derive("Bjørn", taken))
          rootObj.log("strasse", Names.derive("Straße", taken))
          rootObj.log("jose", Names.derive("José", taken))
          rootObj.log("long", Names.derive("A very long name indeed for one person", taken))
          rootObj.log("longCollision", Names.derive("A very long name indeed for one person",
                      ["a-very-long-name-indeed"]))
          rootObj.log("symbols", Names.derive("***", taken))
          rootObj.log("trailing", Names.derive("  Anna-Marie!  ", taken))
          rootObj.log("fromRecords", Names.derive("Anna", [{name: "anna"}]))
          rootObj.log("labelOkPlain", Names.labelOk("Anna", ""))
          rootObj.log("labelOkNewline", Names.labelOk("An\nna", ""))
          rootObj.log("labelOkEmpty", Names.labelOk("", ""))
          rootObj.log("labelOkLong", Names.labelOk("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", ""))
          Qt.exit(0)
          return
        }

        if (rootObj.caseName === "people") {
          var view = peopleLoader.item
          rootObj.log("people", view.people.length)
          rootObj.log("sudoFaces", view.sudoFaces)
          rootObj.log("warning", view.warning)
          rootObj.log("engineReady", view.engineReady)
          view.newLabel = "Åse"
          rootObj.log("derivedFromAse", view.derivedName)
          view.newLabel = "Anna"
          rootObj.log("derivedFromAnna", view.derivedName)
          view.newLabel = "2 Kids"
          rootObj.log("derivedFromDigits", view.derivedName)
          rootObj.log("labelValid", view.labelValid)
          view.newLabel = ""
          rootObj.log("emptyLabelValid", view.labelValid)
          rootObj.log("height", view.implicitHeight)
          Qt.exit(0)
          return
        }

        if (rootObj.caseName.indexOf("person") === 0) {
          var person = personLoader.item
          rootObj.log("name", person.name)
          rootObj.log("found", person.person !== null)
          rootObj.log("owner", person.owner)
          rootObj.log("appearances", person.appearances.length)
          rootObj.log("full", person.full)
          rootObj.log("shown", person.shown)
          rootObj.log("possessive", person.possessive)
          rootObj.log("removeVisible", person.removeVisible)
          rootObj.log("sudoOn", person.permissionValue("sudo"))
          rootObj.log("lockOn", person.permissionValue("lock"))
          rootObj.log("lockCaption", person.lockFeature)
          rootObj.log("sudoCaption", person.sudoFeature)
          rootObj.log("height", person.implicitHeight)
          Qt.exit(0)
          return
        }

        if (rootObj.caseName === "card") {
          rootObj.log("cardCreated", cardLoader.item !== null)
          rootObj.log("cardPhase", cardLoader.item.phase)
          rootObj.log("cardWho", cardLoader.item.session.who())
          rootObj.log("serviceCreated", serviceLoader.item !== null)
          rootObj.log("serviceState", serviceLoader.item.state !== undefined)
          Qt.exit(0)
          return
        }

        rootObj.startedAt = Date.now()
        sessionLoader.item.start()
      }
    }

    // The destroyed session's own exit, which nothing else can report: its
    // callbacks went with it, so `finished` never arrives. What the run is
    // after is in the stand-in's transcript -- `discarded`, not `killed`.
    Timer {
      id: orphanTimer
      interval: 1500
      onTriggered: {
        rootObj.log("case", rootObj.caseName)
        rootObj.log("sessionGone", sessionLoader.item === null)
        Qt.exit(0)
      }
    }

    // Nothing here should take this long; a hung session must not hang the run.
    Timer {
      interval: 60000
      running: true
      onTriggered: { rootObj.log("timeout", true); Qt.exit(1) }
    }
  }
}
