import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Guided face enrolment.
//
// The camera that authenticates is the IR sensor; the camera shown here is the
// ordinary RGB one beside it. They are separate V4L2 devices and stream happily
// at the same time, so the preview can keep running while the IR sensor works.
// Showing IR would be worse anyway -- a flat grey mask that tells the user
// nothing about whether they are framed.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // overview -> framing -> capturing -> checking -> verdict
  property string phase: "overview"
  property var posture: null
  property string previewPath: ""
  property string userName: Quickshell.env("USER")
  property string chosenLabel: "Everyday glasses"
  property string message: ""
  property bool lastOk: false
  property int replacedCount: 0
  property real lastCertainty: -1
  property real threshold: -1
  property var models: []

  // Lower certainty is a better match and it must come in under the threshold.
  // Scraping in just under it is how you get a model that works at this desk,
  // in this light, once -- so it is reported as weak rather than celebrated.
  readonly property real margin: (lastCertainty >= 0 && threshold > 0) ? (threshold - lastCertainty) : -1
  readonly property bool weak: margin >= 0 && margin < 0.5

  readonly property var labelChoices: ["No glasses", "Everyday glasses", "Reading glasses"]

  // Each row is one fact with a verdict attached. "unknown" is its own tone on
  // purpose -- reporting something as fine when it could not be determined is
  // the one failure mode a security overview must not have.
  readonly property var postureRows: {
    var p = root.posture
    if (!p) {
      if (!root.helpersMissing) return [{ name: "Reading state...", value: "", tone: "unknown" }]
      return [
        { name: "Not installed yet", value: "run install.sh", tone: "bad" },
        { name: "", value: "~/.config/omarchy/plugins/graveklar.face/install.sh", tone: "unknown" },
      ]
    }

    var rows = []
    var face = p.face || {}

    if (!face.hardware) {
      rows.push({ name: "Face unlock", value: "no infrared camera", tone: "unknown" })
    } else if (face.disabled) {
      rows.push({ name: "Face unlock", value: "disabled", tone: "unknown" })
    } else if (face.sudo || face.polkit) {
      var where = []
      if (face.sudo) where.push("sudo")
      if (face.polkit) where.push("polkit")
      var count = (face.models === null || face.models === undefined) ? "?" : face.models
      var noun = (count === 1) ? " model" : " models"
      rows.push({ name: "Face unlock", value: where.join(" + ") + " · " + count + noun, tone: "good" })
    } else {
      rows.push({ name: "Face unlock", value: "not configured", tone: "unknown" })
    }

    var fp = p.fingerprint || {}
    rows.push({
      name: "Fingerprint",
      value: !fp.hardware ? "no reader" : (fp.configured ? "enrolled" : "reader present, not enrolled"),
      tone: !fp.hardware ? "unknown" : (fp.configured ? "good" : "unknown"),
      // Omarchy already owns fingerprint setup. Re-implementing it here would
      // be a second thing to keep correct about somebody's authentication.
      run: fp.hardware && !fp.configured ? "omarchy-setup-security-fingerprint" : "",
    })

    rows.push({
      name: "Security key",
      value: (p.fido2 && p.fido2.installed) ? "pam-u2f installed" : "not set up",
      tone: (p.fido2 && p.fido2.installed) ? "good" : "unknown",
      run: (p.fido2 && p.fido2.installed) ? "" : "omarchy-setup-security-fido2",
    })

    var ssh = p.sshd || {}
    rows.push({
      name: "Remote login",
      value: ssh.enabled ? (ssh.running ? "sshd enabled and running" : "sshd enabled") : "sshd off",
      tone: ssh.enabled ? "bad" : "good",
      run: ssh.enabled ? "omarchy-remove-security-sshd" : "omarchy-setup-security-sshd",
    })

    var fails = (p.faillock && p.faillock.failures) ? p.faillock.failures : 0
    rows.push({
      name: "Failed logins",
      value: fails === 0 ? "none recorded" : (fails + " recent"),
      tone: fails === 0 ? "good" : "bad",
      // No terminal for this one: it is a single privileged call, not a setup
      // flow, and it is the row most likely to be clicked in a hurry by
      // somebody whose password has just stopped working.
      privileged: fails > 0 ? "reset-faillock" : "",
    })

    var idle = p.idle || {}
    rows.push({
      name: "Lock when idle",
      value: idle.lock ? root.humanDuration(idle.lock) : "never",
      tone: idle.lock ? "good" : "bad",
      cycle: true,
    })

    rows.push({
      name: "Passwordless sudo",
      value: (p.sudo && p.sudo.passwordless) ? "enabled" : "off",
      tone: (p.sudo && p.sudo.passwordless) ? "bad" : "good",
      run: "omarchy-sudo-passwordless",
    })

    return rows
  }

  function humanDuration(seconds) {
    if (seconds < 60) return seconds + "s"
    if (seconds % 60 === 0) return (seconds / 60) + " min"
    return Math.round(seconds / 60) + " min"
  }

  // The indicator draws in the same place and would cover this panel, so it is
  // told to stand down while setup is on screen. A file rather than a shared
  // QML singleton: the service and the panel are separate component instances
  // with no direct handle on each other, and the service is already polling.
  readonly property string busyFlag: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-face-setup-open"

  Process { id: flagProc }

  function setBusy(on) {
    flagProc.command = on ? ["touch", root.busyFlag] : ["rm", "-f", root.busyFlag]
    flagProc.running = true
  }

  function open(payloadJson) {
    phase = "overview"
    probeProc.running = true
    message = ""
    lastCertainty = -1
    setBusy(true)
    window.visible = true
    modelsFile.reload()
  }

  function close() {
    camera.stop()
    setBusy(false)
    window.visible = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide("graveklar.face")
    else window.visible = false
  }

  // True when there is nothing to enrol INTO yet: no engine installed, or the
  // PAM stacks were never wired. Enrolling in that state produces a model that
  // authenticates nothing, after a failure whose message is about cameras.
  readonly property bool needsSetup: {
    var face = root.posture && root.posture.face
    if (!face) return false
    return !face.installed || !(face.sudo || face.polkit)
  }

  // Cold start belongs in a terminal: it builds a package, and a progress bar
  // that cannot be scrolled or read is worse than no window at all.
  // Idle lock is a user-level setting in shell.json, so it needs no privilege
  // at all -- and a row that cycles through sensible values is far likelier to
  // get used than one that sends you to a text editor.
  readonly property var idleChoices: [60, 300, 600, 1800]

  function cycleIdleLock() {
    var current = (root.posture && root.posture.idle && root.posture.idle.lock) || 0
    var next = root.idleChoices[0]
    for (var i = 0; i < root.idleChoices.length; i++) {
      if (root.idleChoices[i] > current) {
        next = root.idleChoices[i]
        break
      }
    }
    idleProc.command = ["omarchy-face-set-idle-lock", String(next)]
    idleProc.running = true
  }

  Process {
    id: idleProc
    onExited: probeProc.running = true
  }

  function runPrivileged(action) {
    privilegedProc.command = ["pkexec", "/usr/local/bin/omarchy-face-admin",
                              action, root.userName]
    privilegedProc.running = true
  }

  Process {
    id: privilegedProc
    onExited: probeProc.running = true
  }

  // Setup flows go to a terminal on purpose: they install packages, ask
  // questions and print things worth reading. A modal with a spinner over the
  // top of that would be hiding the useful part.
  function runInTerminal(command) {
    terminalProc.command = ["omarchy-launch-floating-terminal-with-presentation", command]
    terminalProc.running = true
    root.requestClose()
  }

  Process { id: terminalProc }

  function activateRow(entry) {
    if (!entry) return
    if (entry.cycle) { root.cycleIdleLock(); return }
    if (entry.privileged) { root.runPrivileged(entry.privileged); return }
    if (entry.run) root.runInTerminal(entry.run)
  }

  function runFirstTimeSetup() {
    setupProc.running = true
    root.requestClose()
  }

  Process {
    id: setupProc
    command: ["omarchy-launch-floating-terminal-with-presentation",
              "omarchy-setup-security-face"]
  }

  function enterFaceFlow() {
    phase = "framing"
    message = ""
    lastCertainty = -1
    // The camera is only opened once the user has actually asked to enrol.
    // Opening it to render an overview would put the webcam light on for
    // someone who came to read a status page.
    previewProc.running = true
  }

  function leaveFaceFlow() {
    camera.stop()
    phase = "overview"
    probeProc.running = true
  }

  function beginCapture() {
    if (phase !== "framing" && phase !== "verdict") return

    // Authorise FIRST. Prompting after the countdown tells the user to hold
    // still, then shows them a password box, and opens the camera once they
    // have looked away to type it.
    phase = "capturing"
    message = "Authorising..."
    countdown.value = 3
    // One call does the lot: the prompt comes first, then the helper waits out
    // the same three seconds this counts down, then captures and verifies.
    // Two calls would need a kept authorisation to bridge them, and that
    // window is long enough for anything running as this user to enrol its own
    // face.
    enrollProc.command = ["pkexec", "/usr/local/bin/omarchy-face-admin",
                          "enroll", root.userName, root.chosenLabel, "3"]
    enrollProc.running = true
    countdown.restart()
  }

  function forgetModel(id, label) {
    root.message = "Removing \"" + label + "\"..."
    forgetProc.command = ["pkexec", "/usr/local/bin/omarchy-face-admin",
                          "forget", root.userName, String(id)]
    forgetProc.running = true
  }

  function parseJson(raw, fallback) {
    try {
      return JSON.parse(String(raw || "").trim())
    } catch (e) {
      return fallback
    }
  }

  Process {
    id: previewProc
    command: ["omarchy-hw-ir-camera", "--preview"]
    stdout: StdioCollector { id: previewOut; waitForEnd: true }
    onExited: {
      root.previewPath = String(previewOut.text || "").trim()
      root.bindCamera()
    }
  }

  // Read, not escalated to. Opening this panel should not demand a password
  // just to render a list of labels; only changing something should.
  FileView {
    id: modelsFile
    path: "/var/lib/omarchy-face/models.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var parsed = root.parseJson(text(), null)
      root.models = (parsed && parsed.models) ? parsed.models : []
    }
    onLoadFailed: root.models = []
  }

  Process {
    id: enrollProc
    stdout: StdioCollector { id: enrollOut; waitForEnd: true }
    onExited: function(code) {
      var parsed = root.parseJson(enrollOut.text, null)
      if (parsed && parsed.ok) {
        root.replacedCount = parsed.replaced || 0
        root.phase = "verdict"
        root.lastOk = !!parsed.verified
        root.lastCertainty = (parsed.certainty === null || parsed.certainty === undefined)
          ? -1 : Number(parsed.certainty)
        root.threshold = (parsed.threshold === null || parsed.threshold === undefined)
          ? -1 : Number(parsed.threshold)

        if (root.lastOk && root.weak)
          root.message = "It recognised you, but only just. Try again in different light, or without moving as much."
        else if (root.lastOk)
          root.message = root.replacedCount > 0
            ? "Recognised you comfortably. Replaced the previous \"" + root.chosenLabel + "\" model."
            : "Recognised you comfortably."
        else
          root.message = "Recorded, but it did not recognise you afterwards. Worth trying again."

        refreshProc.running = true
      } else {
        root.phase = "verdict"
        root.lastOk = false
        root.lastCertainty = -1
        root.message = (parsed && parsed.error)
          ? String(parsed.error).slice(0, 140)
          : "Enrolment did not complete."
      }
    }
  }

  Process {
    id: forgetProc
    stdout: StdioCollector { id: forgetOut; waitForEnd: true }
    onExited: {
      var parsed = root.parseJson(forgetOut.text, null)
      root.message = (parsed && parsed.ok) ? "Removed." : "Could not remove that model."
      // howdy renumbers what follows a removed model, so the list is re-read
      // rather than patched: every id after the removed one has moved.
      refreshProc.running = true
    }
  }

  Process {
    id: refreshProc
    command: ["pkexec", "/usr/local/bin/omarchy-face-admin", "list", Quickshell.env("USER")]
    onExited: modelsFile.reload()
  }

  // True when the QML is here but the privileged half is not -- which is
  // exactly what `omarchy plugin add` produces, since it clones a repository
  // and installs nothing into /usr/local/bin. Saying so beats a panel that
  // renders and then does nothing when touched.
  property bool helpersMissing: false

  Process {
    id: probeProc
    command: ["omarchy-security-probe"]
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: function(code) {
      root.posture = root.parseJson(probeOut.text, null)
      root.helpersMissing = (root.posture === null)
    }
  }

  MediaDevices { id: mediaDevices }

  function bindCamera() {
    var inputs = mediaDevices.videoInputs
    for (var i = 0; i < inputs.length; i++) {
      if (String(inputs[i].id).indexOf(root.previewPath) !== -1) {
        camera.cameraDevice = inputs[i]
        camera.start()
        return
      }
    }
  }

  CaptureSession {
    id: session
    camera: Camera { id: camera }
    videoOutput: output
  }

  Timer {
    id: countdown
    property int value: 3
    interval: 800
    repeat: true
    onTriggered: {
      value -= 1
      if (value <= 0) {
        stop()
        root.runEnroll()
      }
    }
  }

  PanelWindow {
    id: window
    visible: false
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"

    WlrLayershell.namespace: "omarchy-face-setup"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: Color.polkit.scrim
      MouseArea { anchors.fill: parent; onClicked: root.requestClose() }
    }

    Rectangle {
      id: card
      // Near the top, under the webcam: the user has to look at the lens, and
      // a card in the middle of the screen aims their eyes at the wrong place.
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: 44
      width: 520
      height: contentColumn.implicitHeight + 48
      radius: 24
      color: Qt.rgba(Color.polkit.background.r, Color.polkit.background.g, Color.polkit.background.b, 1)
      border.width: 1
      border.color: Qt.rgba(Color.polkit.border.r, Color.polkit.border.g, Color.polkit.border.b, 0.35)

      Column {
        id: contentColumn
        anchors.centerIn: parent
        width: parent.width - 48
        spacing: 16

        // ---- overview -------------------------------------------------
        Column {
          width: parent.width
          spacing: 10
          visible: root.phase === "overview"

          Text {
            text: "Device security"
            color: Color.polkit.text
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
          }

          Repeater {
            model: root.postureRows

            Item {
              id: row
              property var entry: modelData
              readonly property bool actionable: !!(entry.run || entry.privileged || entry.cycle)
              width: parent ? parent.width : 0
              height: 34

              Rectangle {
                anchors.fill: parent
                anchors.leftMargin: -8
                anchors.rightMargin: -8
                radius: 8
                visible: row.actionable && rowArea.containsMouse
                color: Qt.rgba(Color.polkit.text.r, Color.polkit.text.g, Color.polkit.text.b, 0.07)
              }

              MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                enabled: row.actionable
                cursorShape: row.actionable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.activateRow(row.entry)
              }

              Rectangle {
                id: dot
                anchors.verticalCenter: parent.verticalCenter
                width: 9
                height: 9
                radius: 4.5
                color: row.entry.tone === "good" ? Color.polkit.accent
                     : row.entry.tone === "bad" ? Color.polkit.textError
                     : Qt.rgba(Color.polkit.text.r, Color.polkit.text.g, Color.polkit.text.b, 0.3)
              }

              Text {
                anchors.left: dot.right
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: row.entry.name
                color: Color.polkit.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: row.actionable && rowArea.containsMouse
                  ? (row.entry.cycle ? "click to change"
                     : row.entry.privileged ? "click to reset"
                     : "click to configure")
                  : row.entry.value
                color: Qt.rgba(Color.polkit.text.r, Color.polkit.text.g, Color.polkit.text.b, 0.65)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        Item {
          width: parent.width
          height: 300
          visible: root.phase !== "overview"

          Rectangle {
            anchors.fill: parent
            radius: 16
            color: "black"
            clip: true

            VideoOutput {
              id: output
              anchors.fill: parent
              fillMode: VideoOutput.PreserveAspectCrop
              // Mirrored, because an unmirrored self-view makes people correct
              // their position the wrong way.
              transform: Scale { origin.x: output.width / 2; xScale: -1 }
            }

            // Framing guide. Deliberately not a hard crop -- it suggests where
            // to sit rather than rejecting anything outside it.
            Rectangle {
              anchors.centerIn: parent
              width: 168
              height: 210
              radius: width / 2
              color: "transparent"
              border.width: 3
              border.color: root.phase === "capturing"
                ? Color.polkit.accent
                : Qt.rgba(1, 1, 1, 0.55)

              Behavior on border.color { ColorAnimation { duration: 200 } }
            }

            Text {
              anchors.centerIn: parent
              visible: root.phase === "capturing" && countdown.value > 0
              text: countdown.value
              color: "white"
              font.pixelSize: 72
              font.family: Style.font.family
              style: Text.Outline
              styleColor: Qt.rgba(0, 0, 0, 0.6)
            }
          }
        }

        // Which face is being recorded. Glasses change an IR image enough that
        // one model per state is the difference between this working and not.
        Row {
          spacing: 8
          visible: root.phase === "framing" || root.phase === "verdict"

          Repeater {
            model: root.labelChoices

            // The delegate takes modelData as the Repeater injects it, rather
            // than redeclaring it `required` and then reaching for it through
            // `parent` from the children. That combination fails to construct
            // at all -- the chips simply never appear, and the only sign is one
            // "Cannot create delegate" line in the shell's log.
            Rectangle {
              id: chip
              property string choice: modelData
              readonly property bool active: root.chosenLabel === chip.choice

              height: 30
              width: labelText.implicitWidth + 22
              radius: 15
              color: chip.active
                ? Color.polkit.accent
                : Qt.rgba(Color.polkit.text.r, Color.polkit.text.g, Color.polkit.text.b, 0.09)

              Text {
                id: labelText
                anchors.centerIn: parent
                text: chip.choice
                color: chip.active ? Color.polkit.background : Color.polkit.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                anchors.fill: parent
                onClicked: root.chosenLabel = chip.choice
              }
            }
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.phase === "verdict" && !root.lastOk
            ? Color.polkit.textError
            : Color.polkit.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          visible: text !== ""
          text: {
            if (root.phase === "overview") return ""
            if (root.phase === "framing" && !root.message)
              return "Sit where you normally do, fill the oval, and look at the camera."
            return root.message
          }
        }

        Text {
          width: parent.width
          visible: root.phase === "verdict" && root.lastCertainty >= 0
          wrapMode: Text.WordWrap
          color: Qt.rgba(Color.polkit.text.r, Color.polkit.text.g, Color.polkit.text.b, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          text: "Match certainty " + root.lastCertainty.toFixed(3)
              + " against a threshold of " + root.threshold.toFixed(1)
              + (root.weak ? " — not much room." : " — comfortable.")
        }

        // Enrolled models, each removable. A face model is a way into the
        // account, so seeing them and taking one away belongs on the same
        // screen that adds them -- otherwise the only honest instruction is
        // "edit some JSON as root", which nobody does, and the list grows
        // forever.
        Column {
          width: parent.width
          spacing: 4
          visible: root.phase !== "overview"

          Text {
            visible: root.models.length === 0
            text: "Nothing enrolled yet."
            color: Qt.rgba(Color.polkit.text.r, Color.polkit.text.g, Color.polkit.text.b, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.models

            Item {
              id: modelRow
              property var entry: modelData
              width: parent ? parent.width : 0
              height: 26

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: modelRow.entry.label
                color: Qt.rgba(Color.polkit.text.r, Color.polkit.text.g, Color.polkit.text.b, 0.75)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 24
                height: 20
                radius: 6
                color: forgetArea.containsMouse
                  ? Qt.rgba(Color.polkit.textError.r, Color.polkit.textError.g, Color.polkit.textError.b, 0.18)
                  : "transparent"

                Text {
                  anchors.centerIn: parent
                  text: "\u2715"
                  color: forgetArea.containsMouse
                    ? Color.polkit.textError
                    : Qt.rgba(Color.polkit.text.r, Color.polkit.text.g, Color.polkit.text.b, 0.45)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: forgetArea
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: root.phase !== "capturing" && root.phase !== "checking"
                  onClicked: root.forgetModel(modelRow.entry.id, modelRow.entry.label)
                }
              }
            }
          }
        }

        Row {
          spacing: 10

          // Overview: the way in to the only thing this panel can change.
          Rectangle {
            width: 190
            height: 38
            radius: 10
            visible: root.phase === "overview"
            color: (root.posture && root.posture.face && root.posture.face.hardware)
              ? Color.polkit.accent
              : Qt.rgba(Color.polkit.text.r, Color.polkit.text.g, Color.polkit.text.b, 0.09)
            Text {
              anchors.centerIn: parent
              text: root.helpersMissing ? "Run install.sh first"
                  : root.needsSetup ? "Set up face unlock"
                  : (root.posture && root.posture.face && root.posture.face.models > 0)
                    ? "Manage face models" : "Record your face"
              color: (root.posture && root.posture.face && root.posture.face.hardware)
                ? Color.polkit.background : Color.polkit.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              anchors.fill: parent
              enabled: !root.helpersMissing
                && root.posture && root.posture.face && root.posture.face.hardware
              onClicked: root.needsSetup ? root.runFirstTimeSetup() : root.enterFaceFlow()
            }
          }

          Rectangle {
            width: 150
            height: 38
            radius: 10
            visible: root.phase === "framing" || root.phase === "verdict"
            color: Color.polkit.accent
            Text {
              anchors.centerIn: parent
              text: root.phase === "verdict" ? "Record another" : "Record my face"
              color: Color.polkit.background
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea { anchors.fill: parent; onClicked: root.beginCapture() }
          }

          Rectangle {
            width: 90
            height: 38
            radius: 10
            color: Qt.rgba(Color.polkit.text.r, Color.polkit.text.g, Color.polkit.text.b, 0.09)
            Text {
              anchors.centerIn: parent
              text: root.phase === "overview" ? "Done" : "Back"
              color: Color.polkit.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              anchors.fill: parent
              onClicked: root.phase === "overview" ? root.requestClose() : root.leaveFaceFlow()
            }
          }
        }
      }
    }

    Keys.onEscapePressed: root.phase === "overview" ? root.requestClose() : root.leaveFaceFlow()
    Keys.onReturnPressed: if (root.phase !== "overview") root.beginCapture()
  }
}
