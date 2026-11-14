import QtQuick
import "common/enrolring.js" as Ring
import "common/dotscan.js" as Dot

// What the scan will ask, shown while nothing is running (the camera is off until
// Start): a calm head silhouette in the circle that holds still at the centre, then
// turns left, right, up and down in Simple's order while the matching arcs of the
// ring fill (Advanced: one slow turn all the way round). A loop of a few seconds,
// drawn from rectangles in the theme's own roles, no pictures, no camera.
//
// It costs nothing unless it is running: the one animation below is `running` only
// while `running` is true (the card is idle, on screen, with motion allowed), and
// every number it shows is a pure function of the time that animation advances
// (common/enrolring.js demoFrame). It stops the moment Start is pressed.
Item {
  id: demo

  property string mode: "simple"
  property bool running: false
  property color foreground: "white"
  property color secondary: "grey"
  // The moment in the loop, in seconds.
  property real t: 0

  // Simple's frame is the dot scan's (common/dotscan.js: the ball, the ring, the head turning to it);
  // Advanced's is the ring's.
  readonly property bool dot: demo.mode !== "advanced"
  readonly property var frame: demo.dot ? Dot.demoFrame(demo.t) : Ring.demoFrame(demo.mode, demo.t)
  readonly property var bins: demo.dot ? [] : frame.bins
  readonly property var target: demo.dot ? null : frame.target
  readonly property real centre: demo.dot ? 0 : frame.centre
  readonly property string caption: frame.caption
  readonly property real seconds: demo.dot ? Dot.demoSeconds() : Ring.demoSeconds(demo.mode)
  // The head is drawn for the ring's 160 px circle; the dot scan's is smaller
  property real headScale: 1

  NumberAnimation on t {
    id: clock
    from: 0
    to: demo.seconds
    duration: demo.seconds * 1000
    loops: Animation.Infinite
    running: demo.running
  }

  onModeChanged: { demo.t = 0; if (clock.running) clock.restart() }

  // The head: an outline, two eyes, a nose and a mouth. A turn slides the features
  // across the face and narrows it a little; a nod slides them up or down.
  Item {
    id: head
    anchors.centerIn: parent
    readonly property real yaw: demo.frame.yaw
    readonly property real pitch: demo.frame.pitch
    width: 84
    height: 104
    scale: demo.headScale

    Rectangle {
      id: skull
      width: parent.width * (1 - 0.16 * Math.abs(head.yaw))
      height: parent.height
      radius: width / 2
      x: (parent.width - width) / 2 + head.yaw * 9
      y: -head.pitch * 8
      color: "transparent"
      border.width: 2
      border.color: demo.secondary
      opacity: 0.7
    }
    Repeater {
      model: [-1, 1]
      Rectangle {
        required property int modelData
        width: 8; height: 8; radius: 4
        color: demo.secondary
        opacity: 0.9
        x: head.width / 2 - width / 2 + modelData * 17 * (1 - 0.1 * Math.abs(head.yaw)) + head.yaw * 15
        y: head.height * 0.36 - head.pitch * 14
      }
    }
    Rectangle {
      width: 3; height: 16; radius: 1.5
      color: demo.foreground
      opacity: 0.7
      x: head.width / 2 - width / 2 + head.yaw * 26
      y: head.height * 0.48 - head.pitch * 16
    }
    Rectangle {
      width: 20; height: 3; radius: 1.5
      color: demo.secondary
      opacity: 0.9
      x: head.width / 2 - width / 2 + head.yaw * 16
      y: head.height * 0.76 - head.pitch * 11
    }
  }
}
