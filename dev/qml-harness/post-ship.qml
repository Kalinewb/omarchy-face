import QtQuick
import Quickshell
import Quickshell.Io
import "face" as Face

// The four post-ship fixes, in a real QML runtime.
//
// Run by dev/g8-post-ship.sh. Every case loads the REAL files -- FacePanel.qml,
// SetupView.qml, RecordCard.qml, RecordSession.qml -- against the running
// Omarchy's qs.Commons and qs.Ui, and prints what they decided. Nothing here is
// a copy of the logic under test.
//
// The two timing cases are the ones that cannot be tested any other way. Both
// are about a window of a tenth of a second on somebody's screen:
//
//   refresh  a status read asked for while another is in flight is queued, not
//            dropped -- the bug that made a Settings toggle fall back to its old
//            position for up to thirty seconds
//   handoff  the popup returning from a recording card opens on a people.json
//            that has been re-read, not on the one from before the recording
ShellRoot {
  id: rootObj

  readonly property string caseName: Quickshell.env("FACE_HARNESS_CASE") || "setup"
  readonly property string statePath: Quickshell.env("OMARCHY_FACE_DEV_STATE") || ""

  function log(key, value) { console.log("HARNESS " + key, value) }
  function done() { Qt.callLater(function () { Qt.exit(0) }) }

  // The appearance count the panel's store is showing for the one test person.
  function appearanceCount() {
    var list = facePanel.people && Array.isArray(facePanel.people.people) ? facePanel.people.people : []
    if (list.length === 0) return -1
    return Array.isArray(list[0].appearances) ? list[0].appearances.length : -1
  }

  Item {
    width: 400
    height: 1200

    // The real panel: it carries the status document, the two watched files and
    // the open/refresh machinery all four cases are about.
    //
    // NOT `id: panel`: inside SetupView the name `panel` resolves to that
    // view's own `panel` property first, so `panel: panel` binds it to null and
    // every case quietly measures an empty view.
    Face.FacePanel {
      id: facePanel
      bar: null
    }

    // --- 1. the queued status read ------------------------------------------
    //
    // The stub reads its answer at exec time and then sleeps, so a read that
    // starts BEFORE the marker is written answers without it however long it
    // takes to come back. That is what makes "the second call is the one that
    // knows something" a fact of the timeline rather than a hope about it.

    Loader {
      active: rootObj.caseName === "refresh"
      sourceComponent: Component {
        Item {
          Timer {
            // Long enough for the panel's own first read (triggeredOnStart) to
            // have landed, so what follows is measured against a settled panel.
            interval: 1200
            running: true
            onTriggered: {
              rootObj.log("sudoBefore", facePanel.config.sudo === true)
              rootObj.log("busyBefore", facePanel.statusBusy)
              arm.running = true
            }
          }

          Process {
            id: arm
            // The next read will change the world behind its own back (see the
            // stub), so it is the read that cannot see the change it caused.
            command: ["bash", "-c", "touch $S/arm"]
            environment: ({S: rootObj.statePath})
            onExited: {
              facePanel.refresh()
              poke.start()
            }
          }

          Timer {
            id: poke
            // Well inside the stub's 600 ms: this is a verb that has just
            // changed something asking for a re-read while the poll's read is
            // still out -- the overlap that used to lose.
            interval: 50
            onTriggered: {
              rootObj.log("busyDuring", facePanel.statusBusy)
              for (var i = 0; i < 5; i++) facePanel.refresh()
              rootObj.log("queuedAfterFivePokes", facePanel.refreshQueued)
              settle.start()
            }
          }

          Timer {
            id: settle
            // Two stub reads at 600 ms, and nowhere near the 30 s poll: an
            // answer that arrived here arrived because it was queued.
            interval: 2500
            onTriggered: {
              rootObj.log("sudoAfter", facePanel.config.sudo === true)
              rootObj.log("queuedAtEnd", facePanel.refreshQueued)
              reads.running = true
            }
          }

          Process {
            id: reads
            command: ["bash", "-c", "tr '\n' '|' < $S/status.log"]
            environment: ({S: rootObj.statePath})
            stdout: StdioCollector {
              onStreamFinished: {
                rootObj.log("statusLog", String(text).trim())
                rootObj.done()
              }
            }
          }
        }
      }
    }

    // --- 2. the handoff back from a recording card ---------------------------

    Loader {
      active: rootObj.caseName === "handoff"
      sourceComponent: Component {
        Item {
          property int countAtCall: -99
          property int countAtOpen: -99
          property double calledAt: 0

          // The popup is CLOSED for the whole recording, which is why nothing
          // has re-read the store: the once-a-second reload only runs while it
          // is open, and the rename the commit made dropped the inotify watch.
          Connections {
            target: facePanel
            function onOpenedChanged() {
              if (!facePanel.opened) return
              countAtOpen = rootObj.appearanceCount()
              rootObj.log("countAtCall", countAtCall)
              rootObj.log("countAtOpen", countAtOpen)
              rootObj.log("openedAfterMs", Math.round(Date.now() - calledAt))
              rootObj.log("view", facePanel.view)
              rootObj.log("person", facePanel.personName)
              rootObj.done()
            }
          }

          Timer {
            interval: 1200
            running: true
            onTriggered: {
              rootObj.log("countBefore", rootObj.appearanceCount())
              commit.running = true
            }
          }

          Process {
            id: commit
            // What `enroll-session`'s `done` does to the store: a second
            // appearance, written by temp + rename.
            command: ["bash", "-c",
              "sed 's/APPEARANCES/[{\"label\":\"No glasses\",\"time\":1},{\"label\":\"Everyday glasses\",\"time\":2}]/' " +
              "$S/people.template > $S/p.new && mv $S/p.new $S/people.json"]
            environment: ({S: rootObj.statePath})
            onExited: {
              calledAt = Date.now()
              // Read before the call, not after it: after it, a panel that
              // opens synchronously has already run the handler that reports
              // this, and the number never gets written down.
              countAtCall = rootObj.appearanceCount()
              // The IPC handler's body, called the way the handler calls it.
              rootObj.log("openAt", facePanel.openAt("person", "testy"))
              rootObj.log("openedImmediately", facePanel.opened)
            }
          }

          Timer {
            interval: 6000
            running: true
            onTriggered: { rootObj.log("countAtOpen", "NEVER-OPENED"); Qt.exit(1) }
          }
        }
      }
    }

    // --- 3. the appearance picker -------------------------------------------

    Loader {
      id: pickerLoader
      active: rootObj.caseName === "picker"
      sourceComponent: Component {
        Item {
          property alias session: pickerSession
          property alias card: pickerCard

          Face.RecordSession {
            id: pickerSession
            name: "testy"
            appearance: "No glasses"
            label: "Testy"
          }

          Face.RecordCard {
            id: pickerCard
            visible: false
            session: pickerSession
            previewDevice: ""
            fontFamily: "monospace"
            // What this person already has on disk: two of the three.
            recordedAppearances: ["No glasses", "Everyday glasses"]
          }

          Timer {
            interval: 600
            running: true
            onTriggered: {
              var labels = pickerCard.appearanceLabels
              var marks = []
              var actions = []
              for (var i = 0; i < labels.length; i++) {
                marks.push(pickerCard.appearanceMark(labels[i]))
                pickerSession.appearance = labels[i]
                actions.push(pickerCard.actionText())
              }
              rootObj.log("marks", marks.join(""))
              rootObj.log("actions", actions.join("|"))

              // A capture taken in THIS session, for the one appearance that had
              // nothing on disk. Its mark changes, its word changes, and the two
              // that were already recorded do not move.
              pickerSession.capturedLabels = ["Reading glasses"]
              pickerSession.appearance = "Reading glasses"
              rootObj.log("markAfterCapture", pickerCard.appearanceMark("Reading glasses"))
              rootObj.log("actionAfterCapture", pickerCard.actionText())
              rootObj.log("noteAfterCapture", pickerCard.actionNote())

              pickerSession.appearance = "Everyday glasses"
              rootObj.log("noteForRecorded", pickerCard.actionNote())
              pickerSession.appearance = "No glasses"
              rootObj.log("marksAtEnd", [pickerCard.appearanceMark("No glasses"),
                                         pickerCard.appearanceMark("Everyday glasses"),
                                         pickerCard.appearanceMark("Reading glasses")].join(""))

              // A capture that FAILED for the appearance the picker is still on
              // is the one case where neither "Start" nor "Again" is the word.
              pickerSession.appearance = "Reading glasses"
              pickerSession.capturedLabels = []
              pickerSession.lastAttempt = "Reading glasses"
              pickerSession.verdict = "failed"
              pickerSession.phase = "verdict"
              rootObj.log("actionAfterFailure", pickerCard.actionText())
              rootObj.done()
            }
          }
        }
      }
    }

    // --- 3b. the People list's appearance counts -----------------------------
    //
    // The real PeopleView, in front of the real panel, reading a real store.
    // What it decides per person is what somebody would read.

    Loader {
      id: peopleLoader
      active: rootObj.caseName === "people"
      sourceComponent: Component {
        Face.PeopleView {
          width: 400
          panel: facePanel
        }
      }
    }

    Timer {
      interval: 1500
      running: rootObj.caseName === "people"
      onTriggered: {
        var list = peopleLoader.item
        var counts = []
        var labels = []
        for (var i = 0; i < list.children.length; i++) {
          var child = list.children[i]
          if (!child || child.appearanceCount === undefined) continue
          counts.push(child.appearanceCount)
          labels.push(String(child.displayLabel))
        }
        rootObj.log("counts", counts.join("|"))
        rootObj.log("labels", labels.join("|"))
        rootObj.log("storeCounts", (facePanel.people && facePanel.people.people
          ? facePanel.people.people.map(function (p) { return p.appearances.length })
          : []).join("|"))
        rootObj.done()
      }
    }

    // --- 4. the Setup view's three presentations -----------------------------
    //
    // The real view, in front of the real panel, reading whichever fixture the
    // script picked. What it decides is what somebody would see.

    Loader {
      id: setupLoader
      active: rootObj.caseName === "setup"
      sourceComponent: Component {
        Face.SetupView {
          width: 400
          panel: facePanel
        }
      }
    }

    Timer {
      interval: 1500
      running: rootObj.caseName === "setup"
      onTriggered: {
        var setup = setupLoader.item
        rootObj.log("rows", facePanel.rows.length)
        rootObj.log("barState", facePanel.barState)
        rootObj.log("calm", setup.calm)
        rootObj.log("firstRun", setup.firstRun)
        rootObj.log("asking", setup.asking)
        rootObj.log("rowsShown", setup.rowsShown)
        rootObj.log("collapsible", setup.collapsible)
        rootObj.log("primaryLabel", setup.primaryLabel)
        rootObj.log("calmDetail", setup.calmDetail)
        rootObj.log("calmWhere", setup.calmWhere)
        rootObj.log("buildShown", setup.buildShown)
        // The command as the QML engine itself builds it. dev/check-pins.sh can
        // only compare README.md against a script's model of QML string
        // escapes; this is the string the clipboard would actually receive.
        // Base64 so a multi-line value stays one field.
        rootObj.log("installCommandB64", Qt.btoa(facePanel.ask.installCommand))
        // The delegates, not the model: `rendered` is the expression the
        // delegate's own `visible` is bound to. An Item in a harness with no
        // window is never `visible`, whatever it decided.
        var shown = 0
        for (var i = 0; i < setup.children.length; i++) {
          var child = setup.children[i]
          if (child && child.rendered === true) shown++
        }
        rootObj.log("rowsVisible", shown)

        // And on request: the checklist comes back, whatever the presentation.
        setup.detailsShown = true
        var opened = 0
        for (var j = 0; j < setup.children.length; j++) {
          var item = setup.children[j]
          if (item && item.rendered === true) opened++
        }
        rootObj.log("rowsVisibleWithDetails", opened)
        rootObj.done()
      }
    }
  }
}
