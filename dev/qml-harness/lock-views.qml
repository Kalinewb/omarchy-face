import QtQuick
import Quickshell
import Quickshell.Io
import "face" as Face
import "face/common" as FaceCommon

// Phase 7's GUI half, offscreen: the Settings lock switch and the Setup `lock`
// row.
//
// Run by dev/g6-lock-offscreen.sh. It loads the REAL SettingsView.qml and
// SetupView.qml against the running Omarchy's qs.Commons and qs.Ui, with a fake
// panel carrying exactly the `status.lock` shapes the engine sends, and reads
// back what they decided -- the copy for each compat word, and the ORDER of the
// verbs a toggle runs, which is the whole of the rollback rule.
ShellRoot {
  id: rootObj

  readonly property string caseName: Quickshell.env("FACE_HARNESS_CASE") || "settings-off"
  readonly property string statePath: Quickshell.env("OMARCHY_FACE_DEV_STATE") || ""

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

  // The `status.lock` object, per case (plan-merged.md §2.2).
  readonly property var lockStates: ({
    "settings-off":          { compat: "n/a",          missing: [],                     otherLock: "" },
    "settings-loading":      { compat: "loading",      missing: [],                     otherLock: "" },
    "settings-ok":           { compat: "ok",           missing: [],                     otherLock: "" },
    "settings-incompatible": { compat: "incompatible", missing: ["pendingSessionLock"], otherLock: "" },
    "settings-failed":       { compat: "failed",       missing: ["no lock service answered"], otherLock: "" },
    "settings-otherlock":    { compat: "n/a",          missing: [],                     otherLock: "io.github.sirjul1337.lock-explorer" }
  })

  QtObject {
    id: fakePanel

    property color foreground: "white"
    property color dim: "grey"
    property string fontFamily: "monospace"
    property string pluginDir: askObj.pluginDir
    property string statusOutcome: "ok"
    property var ask: askObj
    property var installDoc: ({ state: "idle", steps: [], startedAt: 0, updatedAt: 0 })

    property var config: ({
      account: "graveklar",
      sudo: false,
      lock: Quickshell.env("FACE_HARNESS_LOCK") === "1"
    })

    property var lockState: rootObj.lockStates[rootObj.caseName]
      || ({ compat: Quickshell.env("FACE_HARNESS_COMPAT") || "n/a", missing: [], otherLock: "" })

    property var people: {
      try { return JSON.parse(peopleFile.text()) } catch (error) { return null }
    }

    // The `lock` row exactly as bin/omarchy-face-status builds it, for each of
    // the states the Setup view has a button for.
    property var rows: {
      var row = null
      if (rootObj.caseName === "setup-notstaged")
        row = { id: "lock", label: "Lock screen", state: "needs_action",
                detail: "the lock screen wrapper is not in place yet",
                fixable: true, fix: "lock-stage" }
      else if (rootObj.caseName === "setup-stale")
        row = { id: "lock", label: "Lock screen", state: "needs_action",
                detail: "an update to Face's lock screen is waiting for a restart",
                fixable: true, fix: "lock-sync" }
      else if (rootObj.caseName === "setup-notenabled")
        row = { id: "lock", label: "Lock screen", state: "needs_action",
                detail: "face is set up for the lock screen but is not switched on there",
                fixable: true, fix: "lock-enable" }
      else if (rootObj.caseName === "setup-failed")
        row = { id: "lock", label: "Lock screen", state: "broken",
                detail: "Omarchy's own lock screen is back: no lock service answered",
                fixable: false, fix: "" }
      else
        row = { id: "lock", label: "Lock screen", state: "ok",
                detail: "face follows Omarchy's lock screen", fixable: false, fix: "" }
      return [
        { id: "legacy", label: "Old install", state: "ok", detail: "", fixable: false, fix: "" },
        { id: "camera", label: "Infrared camera", state: "ok", detail: "ok", fixable: false, fix: "" },
        row
      ]
    }

    function row(id) {
      for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return rows[i]
      return null
    }
    function rowState(id) { var found = row(id); return found ? String(found.state) : "" }
    function refresh() {}
    function reloadWatched() {}
    function pushView(v) {}
  }

  Item {
    width: 400
    height: 900

    Loader {
      id: settingsLoader
      active: rootObj.caseName.indexOf("settings") === 0
      sourceComponent: Component { Face.SettingsView { width: 400; panel: fakePanel } }
    }

    Loader {
      id: setupLoader
      active: rootObj.caseName.indexOf("setup") === 0
      sourceComponent: Component { Face.SetupView { width: 400; panel: fakePanel } }
    }

    // The REAL Face service, for the two lock duties that have no view at all:
    // the 30 s health check and the one notification. Both are read back off the
    // service's own properties, which is what its IPC `state()` publishes.
    Loader {
      id: serviceLoader
      active: rootObj.caseName.indexOf("service") === 0
      sourceComponent: Component { Face.Service { omarchyPath: "/usr/share/omarchy" } }
    }

    Timer {
      // Longer than the service's own 30 s deadline, because that deadline is
      // the thing under test: the registry reports no load error for services,
      // so a timeout is the only signal there is (plan-engine.md §9.3).
      interval: rootObj.caseName === "service-recover" ? 35000 : 8000
      running: rootObj.caseName.indexOf("service") === 0
      onTriggered: {
        var service = serviceLoader.item
        rootObj.log("phase", service.lockPhase)
        rootObj.log("notified", service.lockNotifiedKey)
        Qt.exit(0)
      }
    }

    Timer {
      interval: 700
      running: rootObj.caseName.indexOf("service") !== 0
      onTriggered: {
        if (rootObj.caseName.indexOf("setup") === 0) {
          var setup = setupLoader.item
          var row = fakePanel.row("lock")
          rootObj.log("rowState", row.state)
          rootObj.log("fixLabel", setup.fixLabel(row))
          if (row.fixable) {
            setup.runFix(row)
            settleTimer.start()
            return
          }
          rootObj.log("note", setup.noteText)
          Qt.exit(0)
          return
        }

        var settings = settingsLoader.item
        rootObj.log("lockOn", settings.lockOn)
        rootObj.log("lockFaces", settings.lockFaces)
        rootObj.log("statusText", settings.lockStatusText)
        if (rootObj.caseName.indexOf("settings-toggle") === 0) {
          settings.setLock(!settings.lockOn)
          rootObj.log("pendingWhileAsking", settings.pendingLock)
          settleTimer.start()
          return
        }
        rootObj.log("note", settings.note)
        Qt.exit(0)
      }
    }

    Timer {
      id: settleTimer
      // Long enough for two helpers in sequence, and for the rollback that
      // follows a declined prompt -- which is a third.
      interval: 2500
      onTriggered: {
        if (rootObj.caseName.indexOf("setup") === 0) {
          rootObj.log("note", setupLoader.item.noteText)
          Qt.exit(0)
          return
        }
        var settings = settingsLoader.item
        rootObj.log("pendingAfter", settings.pendingLock === null)
        rootObj.log("note", settings.note)
        Qt.exit(0)
      }
    }

    Timer {
      interval: 60000
      running: true
      onTriggered: { rootObj.log("timeout", true); Qt.exit(1) }
    }
  }
}
