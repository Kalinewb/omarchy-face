import QtQuick
import Quickshell
import "face" as Face
import "face/common" as FaceCommon

// The Remove view, offscreen, against a throwaway plugins folder.
//
// Run by dev/g7-remove-offscreen.sh. It loads the REAL RemoveView.qml against
// the running Omarchy's qs.Commons and qs.Ui with a fake panel in front of it,
// and the fake panel's `refresh()` is a real call to the read half -- so the
// `removal` object the view renders comes from `omarchy-face-status`, not from a
// literal in here.
//
// Two things make this more than a bindings check:
//
//   * the fake panel has a real `opened`, so "on close" is exercised rather
//     than described. Closing it is what runs the final detached command;
//   * FACE_HARNESS_PLUGIN points at a COPY of the plugin inside a throwaway
//     plugins folder, with a stand-in `omarchy` in front of the real one. So
//     the final step really does delete a plugin folder, really does call
//     `plugin remove --yes`, and really does clear the backup it leaves --
//     without touching the plugin this session is running.
ShellRoot {
  id: rootObj

  readonly property string caseName: Quickshell.env("FACE_HARNESS_CASE") || "list"
  readonly property bool lockEnabled: Quickshell.env("FACE_HARNESS_LOCK_ENABLED") === "1"

  function log(key, value) { console.log("HARNESS " + key, value) }

  // A question about the filesystem, asked the way the GUI asks everything:
  // through common/Ask.qml. It is here so the gate's first clause -- the result
  // is on screen BEFORE the plugins folder is written -- can be checked at the
  // moment the result appears, rather than inferred afterwards.
  function probe(path, key, then) {
    askObj.ask(["bash", "-c", '[[ -e "$1" ]] && echo present || echo gone', "_", path], "",
               function (result) {
                 rootObj.log(key, String(result.stdout || "").trim())
                 if (then) then()
               })
  }

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
    property string statusOutcome: ""
    property var ask: askObj
    property bool opened: true

    property var status: null
    readonly property var rows: status && Array.isArray(status.rows) ? status.rows : []
    readonly property var config: status && status.config ? status.config : ({})
    // `enabled` decides whether a lock screen that will not switch off stops the
    // removal, so the harness drives it rather than the fixture.
    readonly property var lockState: {
      var base = status && status.lock ? status.lock : ({})
      return {enabled: rootObj.lockEnabled, compat: base.compat || "n/a",
              missing: base.missing || [], otherLock: base.otherLock || ""}
    }

    function row(id) {
      for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return rows[i]
      return null
    }
    function rowState(id) { var found = row(id); return found ? String(found.state) : "" }
    function reloadWatched() {}
    function pushView(name) { rootObj.log("pushed", name) }
    function close() { fakePanel.opened = false }

    // The read half, for real. Every `refresh()` the view asks for is a run of
    // the status helper, which is what makes "reopening shows removal empty" a
    // statement about the engine's answer and not about a fixture swap.
    function refresh() {
      askObj.ask(askObj.statusArgv(), "", function (result) {
        fakePanel.statusOutcome = result.outcome
        if (result.ok && result.parsed && typeof result.parsed === "object")
          fakePanel.status = result.parsed
      })
    }
  }

  Item {
    width: 400
    height: 1200

    Component.onCompleted: fakePanel.refresh()

    Face.RemoveView {
      id: removeView
      width: 400
      panel: fakePanel

      onPhaseChanged: rootObj.phaseSeen(removeView.phase)
    }

    // The status document first: every case reads `removal`, and a view driven
    // before the first answer would be a view with nothing in it.
    Timer {
      interval: 400
      running: true
      onTriggered: {
        if (!fakePanel.status) { rootObj.log("statusOutcome", fakePanel.statusOutcome); Qt.exit(1) }
        rootObj.run()
      }
    }

    Timer {
      interval: 60000
      running: true
      onTriggered: { rootObj.log("timeout", true); Qt.exit(1) }
    }
  }

  // --- the cases --------------------------------------------------------------

  property bool closedDuringPurge: false

  function report() {
    log("case", caseName)
    log("phase", removeView.phase)
    log("armed", removeView.armed)
    log("finalRan", removeView.finalRan)
    log("note", removeView.note)
    log("incomplete", removeView.incomplete.join("|"))
    log("lines", removeView.lines.length)
    log("nothingLeft", removeView.nothingLeft)
    log("actionLabel", removeView.actionLabel)
    log("pluginsDir", removeView.pluginsDir)
    log("finalArgv", JSON.stringify(removeView.finalArgv()))
  }

  function run() {
    if (caseName === "list" || caseName === "reopen") {
      log("linesText", removeView.lines.join(" / "))
      removeView.keepPackages = true
      log("linesKept", removeView.lines.join(" / "))
      removeView.keepPackages = false
      report()
      Qt.exit(0)
      return
    }
    if (caseName === "remove-keep") removeView.keepPackages = true
    removeView.start()
  }

  function phaseSeen(phase) {
    log("phaseAt", phase)

    // Closing the popup in the middle of `purge`. Nothing cancels it: the real
    // verb runs as root and cannot be signalled by the user at all, and the GUI
    // must not try (plan-merged.md §1 row 16).
    if (phase === "purging" && caseName === "remove-close") {
      closeTimer.start()
      return
    }

    if (phase === "done") {
      // The gate's first clause, at the only moment it can be asked: the result
      // is on screen, and the plugins folder has not been touched.
      probe(removeView.pluginsDir + "/graveklar.face-lock", "cloneAtResult", function () {
        // The two values that make the ordering a fact rather than a hope: the
        // step is owed, and it has not run.
        rootObj.log("armedAtResult", removeView.armed)
        rootObj.log("finalRanAtResult", removeView.finalRan)
        if (rootObj.caseName === "remove-keep" || rootObj.caseName === "remove-close") {
          // Leave the folders alone: these two cases are about what happens
          // before the final step, and the shell script checks them afterwards.
          rootObj.report()
          Qt.exit(0)
          return
        }
        // And now the close, which is what runs it.
        fakePanel.close()
        finalTimer.start()
      })
      return
    }

    if (phase === "stopped" || phase === "incomplete") {
      // A stopped or incomplete removal must survive a close without deleting
      // anything: `armed` was never set, so there is nothing to run.
      fakePanel.close()
      stoppedTimer.start()
    }
  }

  Timer {
    id: closeTimer
    interval: 300
    onTriggered: {
      rootObj.closedDuringPurge = true
      fakePanel.close()
      rootObj.log("closedDuringPurge", true)
    }
  }

  Timer {
    id: finalTimer
    // Long enough for a detached command with a stand-in `omarchy` in it.
    interval: 2500
    onTriggered: {
      rootObj.probe(removeView.pluginsDir + "/graveklar.face-lock", "cloneAfterClose", function () {
        rootObj.probe(removeView.pluginsDir + "/graveklar.face", "sourceAfterClose", function () {
          rootObj.report()
          Qt.exit(0)
        })
      })
    }
  }

  Timer {
    id: stoppedTimer
    interval: 1200
    onTriggered: {
      rootObj.probe(removeView.pluginsDir + "/graveklar.face-lock", "cloneAfterClose", function () {
        rootObj.probe(removeView.pluginsDir + "/graveklar.face", "sourceAfterClose", function () {
          rootObj.report()
          Qt.exit(0)
        })
      })
    }
  }
}
