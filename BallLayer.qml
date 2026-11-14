import QtQuick
import "common/dotscan.js" as Dot

// The dot scan's ball on the real screen (3.2.1): one output's worth of surface, no window (ScanBall.qml is
// the window), so a test can draw it at any size. It fills the output it is on, and everything in it is a
// function of that output's width and height (Dot.screenStation): the middle for the centre, and the left,
// top, right and bottom edges, SCREEN_MARGIN in from the physical edge. The card's size and place have no part in it.
//
// It draws what the session says and decides nothing: `shown` is the dot scan being on its ball, `pose` the
// station the ball is on, `held` the stations taken (filled in the accent: the progress, so no counter is
// needed), and the ball with its ring (DotBall.qml). The ball moves between stations over about half a
// second; with reduced motion it jumps. It takes no input and no keyboard: the card has both.
Item {
  id: bl

  property bool shown: false
  // waiting | capturing | landed | done
  property string ballState: "waiting"
  property string pose: "centre"
  property var held: []
  property int good: 0
  property int need: 3
  property bool failed: false
  // foreground, secondary, accent, urgent (colours)
  property var colors: null
  property bool reducedMotion: false

  readonly property real unit: Dot.SCREEN_UNIT
  readonly property var target: Dot.screenStation(pose, width, height)
  readonly property alias ball: ballItem

  opacity: shown ? 1 : 0
  visible: opacity > 0.001
  Behavior on opacity { enabled: !bl.reducedMotion; NumberAnimation { duration: 220 } }

  // The five stations, faint, and filled once taken
  Repeater {
    model: Dot.POSES

    Rectangle {
      required property string modelData
      readonly property var at: Dot.screenStation(modelData, bl.width, bl.height)
      readonly property bool taken: Dot.has(bl.held, modelData)
      readonly property bool here: bl.pose === modelData && bl.ballState !== "done"
      objectName: "screenStation-" + modelData
      width: 12
      height: 12
      radius: 6
      x: at.x - width / 2
      y: at.y - height / 2
      color: taken ? (bl.colors ? bl.colors.accent : "transparent") : "transparent"
      border.width: taken ? 0 : 2
      border.color: bl.colors ? bl.colors.secondary : "transparent"
      opacity: here && !taken ? 0 : (taken ? 0.95 : 0.55)
      antialiasing: true
      Behavior on color { ColorAnimation { duration: bl.reducedMotion ? 0 : 160 } }
    }
  }

  DotBall {
    id: ballItem
    objectName: "screenBall"
    x: bl.target.x
    y: bl.target.y
    unit: bl.unit
    ballState: bl.ballState
    good: bl.good
    need: bl.need
    failed: bl.failed
    colors: bl.colors
    reducedMotion: bl.reducedMotion
    opacity: bl.ballState === "done" ? 0 : 1
    Behavior on x { enabled: !bl.reducedMotion; NumberAnimation { duration: 560; easing.type: Easing.InOutCubic } }
    Behavior on y { enabled: !bl.reducedMotion; NumberAnimation { duration: 560; easing.type: Easing.InOutCubic } }
    Behavior on opacity { enabled: !bl.reducedMotion; NumberAnimation { duration: 200 } }
  }
}
