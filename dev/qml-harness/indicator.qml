import QtQuick
import Quickshell
import Quickshell.Io
import "face" as Face
import "face/common" as FaceCommon

// Phase 5's GUI half, offscreen: the indicator and the Settings sudo switch.
//
// Run by dev/g5-indicator-offscreen.sh. It loads the REAL Indicator.qml and
// SettingsView.qml against the running Omarchy's qs.Commons and qs.Ui, points
// them at a fixture directory standing in for /run/omarchy-face and
// /var/lib/omarchy-face, and prints what they decided.
//
// The indicator draws no window here: its `Variants` model is empty until it
// has something to show, and the cases that DO show something read the card's
// text off the properties rather than off a screen. That is deliberate -- what
// the phase-5 gate asks of the GUI is "the card names the requesting program",
// which is a question about a string, and a test that opened an overlay on
// somebody's display to answer it would be a worse test.
ShellRoot {
  id: rootObj

  readonly property string caseName: Quickshell.env("FACE_HARNESS_CASE") || "sudo-start"
  readonly property string statePath: Quickshell.env("OMARCHY_FACE_DEV_STATE") || ""

  function log(key, value) { console.log("HARNESS " + key, value) }

  function report(indicator) {
    rootObj.log("showing", indicator.visibleNow)
    rootObj.log("authState", indicator.authState)
    rootObj.log("service", indicator.service)
    rootObj.log("person", indicator.person)
    rootObj.log("headline", indicator.headline)
    rootObj.log("detail", indicator.detail)
    rootObj.log("suppressedNotice", indicator.suppressedNotice)
  }

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
    property var ask: askObj
    property var config: ({
      account: "graveklar",
      sudo: Quickshell.env("FACE_HARNESS_SUDO") === "1",
      lock: false
    })
    property var lockState: ({compat: "n/a", missing: [], otherLock: ""})

    property var people: {
      try { return JSON.parse(peopleFile.text()) } catch (error) { return null }
    }

    property var rows: [
      {id: "sudo", label: "Face for sudo",
       state: Quickshell.env("FACE_HARNESS_SUDO_ROW") || "needs_action",
       detail: Quickshell.env("FACE_HARNESS_SUDO_DETAIL") || "off",
       fixable: false, fix: ""}
    ]

    function row(id) {
      for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return rows[i]
      return null
    }
    function rowState(id) { var found = row(id); return found ? String(found.state) : "" }
    function refresh() { rootObj.log("refreshed", true) }
    function reloadWatched() {}
  }

  Item {
    width: 400
    height: 800

    Loader {
      id: indicatorLoader
      active: rootObj.caseName.indexOf("settings") !== 0
      sourceComponent: Component {
        Face.Indicator {
          suppressed: Quickshell.env("FACE_HARNESS_SUPPRESSED") === "1"
        }
      }
    }

    Loader {
      id: settingsLoader
      active: rootObj.caseName.indexOf("settings") === 0
      sourceComponent: Component { Face.SettingsView { width: 400; panel: fakePanel } }
    }

    // The service, with the indicator inside it, so the IPC `state()` the gate
    // reads is the one the shipped file builds and not one this harness made.
    Loader {
      id: serviceLoader
      active: rootObj.caseName === "service"
      sourceComponent: Component { Face.Service { omarchyPath: "/usr/share/omarchy" } }
    }

    // The indicator polls every 200 ms, so a state file written before this
    // starts is picked up well inside a second. 900 ms leaves room for a slow
    // first FileView load without making the suite wait.
    Timer {
      interval: 900
      running: true
      onTriggered: {
        if (rootObj.caseName === "service") {
          // The service's IPC `state()` -- the same function
          // `omarchy-shell graveklar.face.card state` calls on the live shell --
          // reached here by finding the handler among the service's own objects,
          // because an offscreen runtime has no shell to route a call through.
          // So the document the live test reads is the document asserted here.
          var handler = null
          var objects = serviceLoader.item.data
          for (var i = 0; i < objects.length; i++)
            if (objects[i] && objects[i].target === "graveklar.face.card") handler = objects[i]
          rootObj.log("handlerFound", handler !== null)
          if (handler) rootObj.log("serviceState", handler.state())
          Qt.exit(0)
          return
        }

        if (rootObj.caseName.indexOf("settings") === 0) {
          var settings = settingsLoader.item
          rootObj.log("sudoOn", settings.sudoOn)
          rootObj.log("sudoFaces", settings.sudoFaces)
          rootObj.log("lockFaces", settings.lockFaces)
          rootObj.log("rowState", settings.sudoRowState)
          if (rootObj.caseName === "settings-toggle") {
            // What the switch does, not what it looks like: one admin verb,
            // and the value it shows while the prompt is up.
            settings.setSudo(!settings.sudoOn)
            rootObj.log("pendingWhileAsking", settings.pendingSudo)
            settleTimer.start()
            return
          }
          rootObj.log("note", settings.note)
          Qt.exit(0)
          return
        }

        rootObj.report(indicatorLoader.item)
        if (rootObj.caseName === "sudo-safety") {
          // The 12 s safety timer: a verifier that dies between `start` and its
          // answer must not leave this on screen for the rest of the session.
          safetyTimer.start()
          return
        }
        Qt.exit(0)
      }
    }

    Timer {
      id: settleTimer
      interval: 1200
      onTriggered: {
        var settings = settingsLoader.item
        rootObj.log("pendingAfter", settings.pendingSudo === null)
        rootObj.log("note", settings.note)
        Qt.exit(0)
      }
    }

    Timer {
      id: safetyTimer
      interval: 13000
      onTriggered: {
        rootObj.log("showingAfterSafety", indicatorLoader.item.visibleNow)
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
