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

  // The part of the screen that takes the pointer: all of it while the island is there, NONE
  // before it has started to drop and once it is gone (a mask of zero size, so the window does
  // not block clicks that nothing is dimming).
  readonly property Item input: absorber

  // Absorbs the pointer: no pass-through, and nothing closes the card.
  MouseArea {
    id: absorber
    objectName: "scrimInput"
    width: layer.presence > 0.01 ? layer.width : 0
    height: layer.presence > 0.01 ? layer.height : 0
    acceptedButtons: Qt.AllButtons
    hoverEnabled: true
    onWheel: function (wheel) { wheel.accepted = true }
  }
}
