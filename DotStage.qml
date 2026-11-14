import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import qs.Commons as Commons
import "common/dotscan.js" as Dot

// The dot scan card's stage (3.2.0; since 3.2.1 only the camera's circle and, while the card is idle, the
// little demo): a pure Item. It draws what it is told and decides nothing.
//
//   The circle is the camera: the live picture while a scan runs (a face has to be in it and at about the
//   right size), a face glyph before. Whatever sits in it is given as children: `default property alias content`.
//   The BALL is not here. While a scan runs it is on the screen itself (BallLayer.qml in ScanBall.qml's
//   window, on the output the card is on), so the person turns their head to the real edges of the screen
//   and not to the corners of a small card. What this stage keeps of the ball is the idle demo: the same
//   ball and ring (DotBall.qml) at a small scale round the circle, with the head turning to it, so Space and
//   the ring are understood before Start is pressed. The completion check is drawn in the circle.
Item {
  id: stage

  // idle | waiting | capturing | landed | done
  property string ballState: "idle"
  // foreground, secondary, accent (colours)
  property var colors: null
  property bool reducedMotion: false
  // The idle demo drives the ball, the ring and the marks frame by frame: no easing of its own.
  property bool demo: false
  property var demoFrame: null
  // Round the preview/mask: true while something live is in the circle.
  property bool masked: false

  default property alias content: circleItem.data
  readonly property alias circle: circleItem

  readonly property color foreground: colors ? colors.foreground : Commons.Color.foreground
  readonly property color secondary: colors ? (colors.secondary !== undefined ? colors.secondary : colors.dim)
                                              : Qt.darker(Commons.Color.foreground, 1.55)
  readonly property color accent: colors ? colors.accent : Commons.Color.accent

  // The stage is as wide as the card's column. The circle's middle is `circleY` from its top, low enough that the
  // ball on the screen's top edge (it may pass over the card's top) clears the circle.
  readonly property real stageW: 320
  readonly property real stageH: 210
  readonly property real circleY: 108
  // The demo's stations round the circle, as fractions of these
  readonly property real reachX: 112
  readonly property real reachY: 80
  readonly property real demoUnit: 0.7
  implicitWidth: stageW
  implicitHeight: stageH

  readonly property bool demoOn: demo && demoFrame !== null
  readonly property string shownState: demoOn ? (demoFrame.done ? "done" : (demoFrame.close >= 0 ? "capturing" : "waiting")) : ballState
  readonly property var shownHeld: demoOn ? demoFrame.held : []

  Accessible.role: Accessible.ProgressBar
  Accessible.name: "Face scan"
  // What a screen reader is told while a scan runs (DotCard: how many pictures are taken, and what to look at)
  property string summary: "The camera"
  Accessible.description: demoOn ? "A demonstration of the scan, nothing is recording" : stage.summary

  // --- the demo's five stations, and its ball ---------------------------------------------------
  Repeater {
    model: stage.demoOn ? Dot.POSES : []

    Rectangle {
      required property string modelData
      readonly property bool taken: Dot.has(stage.shownHeld, modelData)
      readonly property bool here: stage.demoFrame.pose === modelData
      objectName: "station-" + modelData
      width: 8
      height: 8
      radius: 4
      x: stage.stageW / 2 + Dot.STATION[modelData].x * stage.reachX - width / 2
      y: stage.circleY + Dot.STATION[modelData].y * stage.reachY - height / 2
      color: taken ? stage.accent : "transparent"
      border.width: taken ? 0 : 1.5
      border.color: stage.secondary
      opacity: here && !taken ? 0 : (taken ? 0.95 : 0.55)
      antialiasing: true
    }
  }

  // --- the circle: the camera --------------------------------------------------------------
  Item {
    id: circleItem
    objectName: "circle"
    width: 124
    height: 124
    x: (stage.stageW - width) / 2
    y: stage.circleY - height / 2
    layer.enabled: stage.masked
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: circleMask
      maskThresholdMin: 0.5
      maskSpreadAtMin: 1.0
    }
  }

  // A faint rim, so the circle reads as a lens whether or not anything is in it
  Rectangle {
    x: circleItem.x
    y: circleItem.y
    width: 124
    height: 124
    radius: 62
    color: "transparent"
    border.width: 2
    border.color: stage.secondary
    opacity: 0.55
    antialiasing: true
  }

  Item {
    id: circleMask
    visible: false
    x: circleItem.x
    y: circleItem.y
    width: 124
    height: 124
    layer.enabled: true
    layer.smooth: true
    Rectangle { anchors.fill: parent; radius: width / 2; color: stage.foreground }
  }

  // The demo's ball, small, over the circle's neighbourhood
  DotBall {
    id: demoBall
    objectName: "ball"
    visible: stage.demoOn
    x: stage.demoOn ? stage.stageW / 2 + stage.demoFrame.ball.x * stage.reachX : 0
    y: stage.demoOn ? stage.circleY + stage.demoFrame.ball.y * stage.reachY : 0
    unit: stage.demoUnit
    demo: true
    demoClose: stage.demoOn ? stage.demoFrame.close : -1
    demoTime: stage.demoOn ? stage.demoFrame.t : 0
    ballState: stage.shownState
    colors: stage.colors
    reducedMotion: stage.reducedMotion
    opacity: stage.shownState === "done" ? 0 : 1
  }

  // Completion draws a check in 180 ms; there is no celebration.
  Item {
    id: checkBox
    objectName: "check"
    x: (stage.stageW - width) / 2
    y: stage.circleY - height / 2
    width: 44
    height: 44
    property real drawn: stage.shownState === "done" ? 1 : 0
    Behavior on drawn { enabled: !stage.reducedMotion; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    readonly property real first: Math.min(1, drawn * 43.1 / 14.1)
    readonly property real second: Math.max(0, Math.min(1, (drawn * 43.1 - 14.1) / 29))
    visible: drawn > 0
    Shape {
      width: 44; height: 44
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        strokeColor: stage.accent
        strokeWidth: 3
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 8; startY: 23
        PathLine { x: 8 + 10 * checkBox.first; y: 23 + 10 * checkBox.first }
        PathLine { x: 18 + 19 * checkBox.second; y: 33 - 22 * checkBox.second }
      }
    }
  }
}
