import QtQuick

// The dimming behind the scan island: true black at 55% when the island has fully dropped,
// fading in with it and out as it retracts, because `presence` IS the island's drop (0 to 1;
// under reduced motion it jumps, so the dimming does too, with no fade of its own). It takes
// every click and does nothing with it, so what is behind it cannot be pressed: Cancel and Esc
// on the island are the ways out. No window here (ScanScrim.qml is the window, one per
// screen), so a test can draw it.
Item {
  id: layer

  property real presence: 0
  readonly property real dim: 0.55
  readonly property real shown: dim * Math.max(0, Math.min(1, presence))

  Rectangle {
    objectName: "scrim"
    anchors.fill: parent
    color: "#000000"
    opacity: layer.shown
  }

  // Absorbs the pointer: no pass-through, and nothing closes the card.
  MouseArea {
    objectName: "scrimInput"
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    hoverEnabled: true
    onWheel: function (wheel) { wheel.accepted = true }
  }
}
