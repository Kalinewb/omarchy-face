import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import qs.Commons as Commons
import "common/dotscan.js" as Dot

// The dot scan's stage (3.2.0): a pure Item. It draws what it is told and decides nothing:
// which pose the ball is on, which are taken, whether a press is running and how many frames the
// helper has gathered all come from RecordSession through DotCard.
//
//   The ball is a dot with an outer ring. It sits on the pose it is waiting for, and the ring
//   breathes (in and out, slowly) so it reads as "now". After Space the ring closes in over about
//   a second, never further than the frames the helper has gathered allow; when they are enough it
//   closes on the ball and the ball moves on, and when they are not it opens again.
//   The five stations are faint marks at the centre, left, top, right and bottom; a pose that is
//   taken is a filled mark in the accent, so the stage is also the progress and nothing else needs
//   to say "2 of 5".
//   The camera's circle is in the middle; whatever sits in it (the preview, the glyph, the idle
//   demo's head) is given as children: `default property alias content`.
Item {
  id: stage

  // idle | waiting | capturing | landed | done
  property string ballState: "idle"
  // The station the ball is on: "centre", "left", "top", "right", "bottom" or "".
  property string pose: "centre"
  property var held: []
  property int good: 0
  property int need: 3
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

  // The stage is as wide as the card's column. Its middle is the camera's circle; the four stations
  // are `reach` px from it, and the breathing ring's widest radius still fits inside.
  readonly property real stageW: 320
  readonly property real stageH: 244
  readonly property real reachX: 120
  readonly property real reachY: 96
  implicitWidth: stageW
  implicitHeight: stageH

  // What is drawn: the demo's frame while it plays, else the session's.
  readonly property bool demoOn: demo && demoFrame !== null
  readonly property string shownState: demoOn ? (demoFrame.done ? "done" : (demoFrame.close >= 0 ? "capturing" : "waiting")) : ballState
  readonly property var shownHeld: demoOn ? demoFrame.held : held
  readonly property real targetX: demoOn ? demoFrame.ball.x * reachX
                                         : (Dot.STATION[pose] !== undefined ? Dot.STATION[pose].x * reachX : 0)
  readonly property real targetY: demoOn ? demoFrame.ball.y * reachY
                                         : (Dot.STATION[pose] !== undefined ? Dot.STATION[pose].y * reachY : 0)

  // Milliseconds since Space, while a press runs; the ring closes with it (at most as fast as the
  // frames come in, Dot.closing).
  property real elapsed: 0
  NumberAnimation on elapsed {
    id: clock
    from: 0
    to: 8000
    duration: 8000
    running: stage.ballState === "capturing" && !stage.demo && !stage.reducedMotion
  }
  onBallStateChanged: if (stage.ballState !== "capturing") stage.elapsed = 0

  // With reduced motion there is no clock: the ring goes as far as the frames have, in steps.
  readonly property real closeTarget: {
    if (demoOn) return demoFrame.close < 0 ? 0 : demoFrame.close
    if (ballState === "landed" || ballState === "done") return 1
    if (ballState !== "capturing") return 0
    return reducedMotion ? Dot.clamp(0.3 + 0.7 * good / Math.max(1, need), 0, 1) * (good > 0 ? 1 : 0.3)
                         : Dot.closing(elapsed, good, need)
  }
  property real close: closeTarget
  Behavior on close {
    enabled: !stage.reducedMotion && !stage.demoOn
    NumberAnimation { duration: stage.shownState === "capturing" ? 140 : 280; easing.type: Easing.OutCubic }
  }

  // The breath: 0 to 1 and back, only while the ball waits and motion is allowed.
  property real pulse: 0
  SequentialAnimation on pulse {
    loops: Animation.Infinite
    running: stage.shownState === "waiting" && !stage.reducedMotion && !stage.demoOn && stage.visible
    NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
    NumberAnimation { to: 0; duration: 900; easing.type: Easing.InOutSine }
  }
  // In the demo the breath follows the demo's own time so it needs no clock of its own.
  readonly property real shownPulse: demoOn ? 0.5 + 0.5 * Math.sin(demoFrame.t * 3.5) : pulse

  Accessible.role: Accessible.ProgressBar
  Accessible.name: "Face scan"
  Accessible.description: {
    if (demoOn) return "A demonstration of the scan, nothing is recording"
    var n = Dot.count(held)
    if (n >= Dot.POSES.length) return "All five pictures taken"
    return n + " of " + Dot.POSES.length + " pictures taken. " + (Dot.PROMPT[pose] || "")
  }

  // --- the five stations -------------------------------------------------------------------
  Repeater {
    model: Dot.POSES

    Rectangle {
      required property string modelData
      readonly property bool taken: Dot.has(stage.shownHeld, modelData)
      readonly property bool here: !stage.demoOn ? stage.pose === modelData && stage.shownState !== "done"
                                                : stage.demoFrame.pose === modelData
      objectName: "station-" + modelData
      width: 8
      height: 8
      radius: 4
      x: stage.stageW / 2 + Dot.STATION[modelData].x * stage.reachX - width / 2
      y: stage.stageH / 2 + Dot.STATION[modelData].y * stage.reachY - height / 2
      color: taken ? stage.accent : "transparent"
      border.width: taken ? 0 : 1.5
      border.color: stage.secondary
      // The ball covers the station it is on; a taken one stays lit.
      opacity: here && !taken ? 0 : (taken ? 0.95 : 0.55)
      antialiasing: true
      Behavior on color { ColorAnimation { duration: stage.reducedMotion ? 0 : 160 } }
    }
  }

  // --- the circle: the camera --------------------------------------------------------------
  Item {
    id: circleItem
    objectName: "circle"
    width: 124
    height: 124
    anchors.centerIn: parent
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
    anchors.centerIn: parent
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
    width: 124
    height: 124
    anchors.centerIn: parent
    layer.enabled: true
    layer.smooth: true
    Rectangle { anchors.fill: parent; radius: width / 2; color: stage.foreground }
  }

  // --- the ball ---------------------------------------------------------------------------
  Item {
    id: ball
    objectName: "ball"
    width: 0
    height: 0
    x: stage.stageW / 2 + stage.targetX
    y: stage.stageH / 2 + stage.targetY
    opacity: stage.shownState === "done" ? 0 : 1
    Behavior on x { enabled: !stage.reducedMotion && !stage.demoOn; NumberAnimation { duration: 460; easing.type: Easing.InOutCubic } }
    Behavior on y { enabled: !stage.reducedMotion && !stage.demoOn; NumberAnimation { duration: 460; easing.type: Easing.InOutCubic } }
    Behavior on opacity { enabled: !stage.reducedMotion; NumberAnimation { duration: 200 } }

    // The outer ring: breathing while the ball waits, closing in while a press runs.
    Rectangle {
      id: ring
      objectName: "ballRing"
      readonly property real r: Dot.ringRadius(stage.close, stage.reducedMotion ? 0.5 : stage.shownPulse)
      width: 2 * r
      height: 2 * r
      radius: r
      x: -r
      y: -r
      color: "transparent"
      border.width: 2
      border.color: stage.shownState === "capturing" || stage.shownState === "landed" ? stage.accent : stage.foreground
      opacity: stage.shownState === "waiting" ? (stage.reducedMotion ? 0.7 : 0.45 + 0.4 * stage.shownPulse) : 0.95
      antialiasing: true
    }

    // The ball itself.
    Rectangle {
      id: core
      objectName: "core"
      width: 2 * Dot.BALL
      height: 2 * Dot.BALL
      radius: Dot.BALL
      x: -Dot.BALL
      y: -Dot.BALL
      color: stage.shownState === "landed" ? stage.accent : stage.foreground
      antialiasing: true
      Behavior on color { ColorAnimation { duration: stage.reducedMotion ? 0 : 120 } }
    }
  }

  // Completion draws a check in 180 ms; there is no celebration.
  Item {
    id: checkBox
    objectName: "check"
    anchors.centerIn: parent
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
