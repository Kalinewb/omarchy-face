import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons

// Watches the state file omarchy-face-verify publishes and draws what is
// happening. Nothing here participates in authentication -- PAM has already
// decided by the time a state lands -- so this is free to be late, wrong, or
// absent without any effect on whether the user gets in.
Item {
  id: root

  // start -> the engine is looking. matched / failed -> it finished.
  // skipped -> the gate declined to try, and there is nothing to show.
  property string authState: "idle"
  property double lastAt: 0
  property bool showing: false

  // Anything older than this on load is a leftover from a previous session,
  // not a live event. Without it, restarting the shell pops a spinner for an
  // authentication that finished hours ago.
  readonly property int staleAfterMs: 10000

  readonly property color accent: Color.polkit.accent
  readonly property color surface: Color.polkit.background
  readonly property color outline: Color.polkit.border
  readonly property color label: Color.polkit.text
  readonly property color failure: Color.polkit.textError

  function handle(payload) {
    if (!payload) return

    var event
    try {
      event = JSON.parse(payload)
    } catch (e) {
      return
    }

    if (!event || !event.state) return
    if (!event.at || event.at === lastAt) return
    if (Date.now() - event.at > staleAfterMs) {
      lastAt = event.at
      return
    }

    lastAt = event.at
    root.authState = event.state

    // Setup has its own, richer feedback in the same screen position. Two
    // cards fighting over that spot is worse than none.
    if (setupOpen.loaded) {
      showing = false
      return
    }

    if (event.state === "start") {
      dismissTimer.stop()
      safetyTimer.restart()
      showing = true
    } else if (event.state === "matched") {
      safetyTimer.stop()
      showing = true
      dismissTimer.interval = 1600
      dismissTimer.restart()
    } else if (event.state === "failed") {
      safetyTimer.stop()
      showing = true
      dismissTimer.interval = 1800
      dismissTimer.restart()
    } else {
      // skipped, or anything unrecognised: say nothing.
      safetyTimer.stop()
      showing = false
    }
  }

  // Existence is the whole signal; contents are irrelevant.
  FileView {
    id: setupOpen
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-face-setup-open"
    watchChanges: true
    printErrors: false
    property bool loaded: false
    onLoaded: loaded = true
    onLoadFailed: loaded = false
    onFileChanged: reload()
  }

  FileView {
    id: stateFile
    path: "/run/omarchy-face/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.handle(text())
  }

  // The notifier writes by atomic rename, which replaces the inode and can
  // silently drop a watch. A slow poll costs one small read and guarantees the
  // spinner still arrives before the camera does -- opening the IR device alone
  // takes about 840ms.
  Timer {
    interval: 200
    repeat: true
    running: true
    onTriggered: {
      stateFile.reload()
      setupOpen.reload()
    }
  }

  // A verifier that dies without writing a terminal state would otherwise leave
  // this on screen indefinitely. The engine gives up at 8s and the camera takes
  // about 1s to open, so anything past ~12s is a fault, and the right response
  // to a fault is to get out of the user's way.
  Timer {
    id: safetyTimer
    interval: 12000
    onTriggered: root.showing = false
  }

  Timer {
    id: dismissTimer
    onTriggered: root.showing = false
  }

  // The camera is above the built-in panel, so that is the only screen where
  // showing this helps. On an external monitor it would aim the user's gaze
  // away from the lens. Falls back to every screen if no internal panel is
  // recognised, which is better than showing nothing at all.
  readonly property var targetScreens: {
    var builtin = []
    for (var i = 0; i < Quickshell.screens.length; i++) {
      var candidate = Quickshell.screens[i]
      if (/^(eDP|LVDS|DSI)/i.test(candidate.name || "")) builtin.push(candidate)
    }
    return builtin.length > 0 ? builtin : Quickshell.screens
  }

  Variants {
    model: root.targetScreens

    PanelWindow {
      id: window
      required property var modelData
      screen: modelData

      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      visible: root.showing

      WlrLayershell.namespace: "omarchy-face-indicator"
      WlrLayershell.layer: WlrLayer.Overlay
      // Never take focus: the password prompt underneath may be mid-typing,
      // and an indicator that swallows keystrokes is worse than no indicator.
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      // Empty input region: clicks pass straight through to whatever is behind.
      mask: Region {}

      Item {
        id: card
        // Directly below the webcam rather than in the middle of the display:
        // looking at the prompt then points the face at the lens, which is the
        // one thing the user has to get right.
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 52
        width: 260
        height: 220
        opacity: root.showing ? 1 : 0
        scale: root.showing ? 1 : 0.92

        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }

        Rectangle {
          anchors.fill: parent
          radius: 22
          // Forced opaque. The polkit surface token is semi-transparent on
          // purpose -- Hyprland blurs that dialog via a layer rule matched on
          // its namespace -- but this overlay has no blur rule behind it, so
          // the alpha simply let whatever was underneath read through the text.
          color: Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1)
          border.width: 1
          border.color: Qt.rgba(root.outline.r, root.outline.g, root.outline.b, 0.35)
        }

        Item {
          id: ring
          width: 104
          height: 104
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          anchors.topMargin: 34

          readonly property color tint: root.authState === "failed" ? root.failure : root.accent
          readonly property bool searching: root.authState === "start"

          SequentialAnimation {
            id: pop
            NumberAnimation { target: ring; property: "scale"; to: 1.14; duration: 170; easing.type: Easing.OutCubic }
            NumberAnimation { target: ring; property: "scale"; to: 1.0; duration: 260; easing.type: Easing.OutBack }
          }

          Connections {
            target: root
            function onAuthStateChanged() {
              if (root.authState === "matched" || root.authState === "failed") pop.restart()
            }
          }

          // The track sits still; only the sweep rotates. Rotating a painted
          // item is far cheaper than repainting a Canvas every frame.
          Canvas {
            id: track
            anchors.fill: parent
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              ctx.beginPath()
              ctx.arc(width / 2, height / 2, width / 2 - 4, 0, Math.PI * 2)
              ctx.lineWidth = 6
              ctx.strokeStyle = Qt.rgba(ring.tint.r, ring.tint.g, ring.tint.b, 0.18)
              ctx.stroke()
            }
          }

          Canvas {
            id: sweep
            anchors.fill: parent
            // A full ring once it has an answer, a partial arc while hunting.
            property real extent: ring.searching ? Math.PI * 0.55 : Math.PI * 2
            Behavior on extent { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
            onExtentChanged: requestPaint()
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              ctx.beginPath()
              ctx.arc(width / 2, height / 2, width / 2 - 4, -Math.PI / 2, -Math.PI / 2 + extent)
              ctx.lineWidth = 6
              ctx.lineCap = "round"
              ctx.strokeStyle = ring.tint
              ctx.stroke()
            }

            RotationAnimation on rotation {
              from: 0
              to: 360
              duration: 1100
              loops: Animation.Infinite
              running: ring.searching && root.showing
            }
          }

          Text {
            anchors.centerIn: parent
            text: root.authState === "matched" ? "✓" : (root.authState === "failed" ? "✕" : "")
            color: ring.tint
            font.pixelSize: 40
            font.family: Style.font.family
            opacity: root.authState === "matched" || root.authState === "failed" ? 1 : 0
            scale: opacity
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
            Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutBack } }
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: ring.bottom
          anchors.topMargin: 22
          horizontalAlignment: Text.AlignHCenter
          width: parent.width - 32
          wrapMode: Text.WordWrap
          color: root.authState === "failed" ? root.failure : root.label
          font.pixelSize: Style.font.body
          font.family: Style.font.family
          text: root.authState === "matched" ? "Unlocked"
              : root.authState === "failed" ? "Not recognised"
              : "Look at the camera"
        }
      }
    }
  }
}
