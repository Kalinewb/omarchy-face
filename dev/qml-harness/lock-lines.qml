import QtQuick
import Quickshell
import qs.Commons

// The wrapper's lines, measured in the font Omarchy's LockView draws them in.
//
// Run by dev/g6-lock-offscreen.sh. LockView elides the placeholder
// (LockView.qml:186-197), so a line that does not fit loses its end -- which,
// for a line that ends in an instruction, is the part that matters. The room is
// what LockView gives the TextInput it fills: the field's width less the border
// and 18 px on each side, less the fingerprint glyph's reserve on each side when
// a reader is enrolled (LockView.qml:21-29, 132-139). Both are reported, and the
// suite holds the lines to the narrower.
ShellRoot {
  id: rootObj

  readonly property int fieldWidth: 381
  readonly property int border: 3
  readonly property int fieldFontSize: Math.round(Style.font.heading * 1.125)

  TextMetrics { id: glyph; font.family: Style.font.family; font.pixelSize: Math.round(rootObj.fieldFontSize * 1.1); text: "󰈷" }
  TextMetrics { id: line; font.family: Style.font.family; font.pixelSize: rootObj.fieldFontSize; font.italic: true }

  function room(fingerprint) {
    var reserve = fingerprint ? Math.round(glyph.advanceWidth + 12) : 0
    return rootObj.fieldWidth - 2 * (rootObj.border + 18 + reserve)
  }

  // Measured a tick after start rather than in onCompleted: Qt.exit() from
  // inside Component.onCompleted is ignored, and the run hangs to its timeout.
  Timer { running: true; interval: 50; onTriggered: rootObj.measure() }

  function measure() {
    var lines = (Quickshell.env("FACE_HARNESS_LINES") || "").split("|")
    console.log("HARNESS room", rootObj.room(false))
    console.log("HARNESS roomFingerprint", rootObj.room(true))
    for (var i = 0; i < lines.length; i++) {
      line.text = lines[i]
      console.log("HARNESS width" + i, Math.ceil(line.advanceWidth))
    }
    Qt.exit(0)
  }
}
