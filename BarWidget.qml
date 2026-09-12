import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A bar button, and the only thing that makes this plugin reachable at all
// straight after `omarchy plugin add`.
//
// The menu entries are written by install.sh, which adding a plugin does not
// run -- so pointing a new user at "Setup > Security" first is circular: the
// entry they are told to open is created by the step they have not taken. A bar
// widget is Omarchy's own answer to that, and `omarchy plugin add` even asks
// which section to put it in.
BarWidget {
  id: root
  moduleName: "graveklar.face"

  // null until the first probe answers; false specifically means the
  // privileged half is missing, which is the state a fresh add leaves behind.
  property var posture: null
  property bool probed: false

  readonly property bool installed: posture !== null
  readonly property bool configured: installed && posture.face
    && (posture.face.sudo || posture.face.polkit)
  readonly property bool disabled: installed && posture.face && posture.face.disabled

  readonly property string state: !probed ? "unknown"
    : !installed ? "missing"
    : disabled ? "off"
    : configured ? "on"
    : "idle"

  implicitWidth: vertical ? barSize : icon.implicitWidth + Style.space(10)
  implicitHeight: vertical ? icon.implicitHeight + Style.space(10) : barSize

  Process {
    id: probe
    // See Panel.qml: a Process whose command is missing never exits, so the
    // widget would sit in its initial state rather than reporting one.
    command: ["bash", "-c",
              "command -v omarchy-security-probe >/dev/null 2>&1 && exec omarchy-security-probe; exit 127"]
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: {
      try {
        root.posture = JSON.parse(String(probeOut.text || "").trim())
      } catch (e) {
        root.posture = null
      }
      root.probed = true
    }
  }

  // Cheap, and nothing here changes quickly. The one thing worth noticing
  // promptly -- a model being enrolled -- happens in the panel this opens,
  // which re-probes on close.
  Timer {
    interval: 30000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: probe.running = true
  }

  Process {
    id: summon
    command: ["omarchy-shell", "shell", "summon", "graveklar.face", "{}"]
    onExited: probe.running = true
  }

  Text {
    id: icon
    anchors.centerIn: parent
    text: ""
    font.family: Style.font.family
    font.pixelSize: Style.font.icon
    // Muted when there is nothing set up, so the bar does not claim a
    // protection that is not there.
    color: root.state === "on" ? Color.bar.text
         : Qt.rgba(Color.bar.text.r, Color.bar.text.g, Color.bar.text.b, 0.45)
    opacity: root.state === "off" ? 0.5 : 1.0
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: summon.running = true
  }
}
