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

  // The input region is the layer's absorber: the whole screen while the island is up, nothing
  // before it drops and after it is gone, so this window never blocks a click it does not dim.
  mask: Region { item: layer.input }

  ScrimLayer {
    id: layer
    anchors.fill: parent
    presence: scrim.presence
  }
}
