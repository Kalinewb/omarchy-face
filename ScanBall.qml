import QtQuick
import Quickshell
import Quickshell.Wayland

// The dot scan's ball, on the output the scan card is on (3.2.1). Service.qml makes ONE, for that output
// only (the dimming scrims elsewhere stay as they are), after the card, so it is mapped above it on the
// same Overlay layer: the ball may pass over the card's top edge when it goes to the top of the screen.
//
// A full-output window with NO keyboard and NO input: its input region is empty, so a click goes to
// what is under it (the dimming scrim absorbs it), and Space and Esc stay on the card, which holds the
// keyboard exclusively. What is drawn is BallLayer.qml, which needs only the output's size.
PanelWindow {
  id: win

  required property var session
  // The card's drop, 0 to 1 (RecordCard.presence): the ball is there only while the card is.
  property real presence: 0

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omarchy-face-ball"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // An empty input region: nothing in this window takes a click
  mask: Region { item: noInput }
  Item { id: noInput; width: 0; height: 0 }

  // mapped after the card (which maps 80 ms in), so it is stacked above it
  property bool mapped: false
  Timer { running: true; interval: 220; onTriggered: win.mapped = true }
  visible: win.mapped

  BallScreen {
    anchors.fill: parent
    session: win.session
    presence: win.presence
  }
}
