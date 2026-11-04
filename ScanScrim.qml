import QtQuick
import Quickshell
import Quickshell.Wayland

// One screen's dimming while the scan island is up (Service.qml makes one per screen, before
// the card, so it is mapped under it on the same Overlay layer). Full screen, no keyboard (the
// card has it, exclusively), and every click on it is absorbed (ScrimLayer.qml).
PanelWindow {
  id: scrim

  // The island's drop, 0 to 1 (RecordCard.presence).
  property real presence: 0

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omarchy-face-scrim"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  ScrimLayer {
    anchors.fill: parent
    presence: scrim.presence
  }
}
