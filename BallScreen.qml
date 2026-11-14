import QtQuick
import Quickshell
import qs.Commons as Commons

// What ScanBall.qml's window holds, with no window around it so a test can draw it at any output size: the
// BallLayer, bound to the session. Everything here is the session's and the output's: nothing of the card's.
Item {
  id: screen

  property var session: null
  // The card's drop, 0 to 1 (RecordCard.presence): the ball is there only while the card is.
  property real presence: 1
  // No animation at all: the card's own setting (OMARCHY_REDUCED_MOTION or NOTCH_REDUCED_MOTION by default)
  property bool reducedMotion: Quickshell.env("OMARCHY_REDUCED_MOTION") === "1" || Quickshell.env("NOTCH_REDUCED_MOTION") === "1"

  QtObject {
    id: colors
    readonly property color foreground: "#ffffff"
    readonly property color secondary: Qt.darker("#ffffff", 1.55)
    readonly property color accent: Commons.Color.accent
    readonly property color urgent: Commons.Color.urgent
  }

  readonly property alias balls: ballLayer

  BallLayer {
    id: ballLayer
    anchors.fill: parent
    shown: !!screen.session && screen.session.dotOnBall && screen.presence > 0.5
    ballState: screen.session ? screen.session.dotBallState : "waiting"
    pose: screen.session ? screen.session.dotBallPose : "centre"
    held: screen.session ? screen.session.dotHeld : []
    good: screen.session ? screen.session.dotGood : 0
    need: screen.session ? screen.session.dotNeed : 3
    failed: !!screen.session && screen.session.dotWhy !== ""
    colors: colors
    reducedMotion: screen.reducedMotion
  }
}
