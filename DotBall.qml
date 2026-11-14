import QtQuick
import qs.Commons as Commons
import "common/dotscan.js" as Dot

// The dot scan's ball and its outer ring (3.2.0, moved out of DotStage in 3.3.0 so the same ball can be on the
// card's little demo and on the real screen). A pure Item of no size: it draws what it is told and decides
// nothing, and it is drawn centred on its own x and y.
//
//   waiting    the ring breathes (in and out, slowly): "now"
//   capturing  the ring closes in over about a second after Space, never further than the frames the helper
//              has gathered allow (Dot.closing), and only `landed` takes it to closed
//   landed     closed on the ball, the ball in the accent, for a beat
//   a failed press re-opens the ring, in the urgent colour, with the reason on the card
//   under reduced motion there is no clock and no breath: the ring goes as far as the frames have, in steps
//
// `unit` scales it: 1 on the card's little demo, Dot.SCREEN_UNIT on the screen.
Item {
  id: ball

  // waiting | capturing | landed | done
  property string ballState: "waiting"
  property int good: 0
  property int need: 3
  property bool failed: false
  property real unit: 1
  property var colors: null
  property bool reducedMotion: false
  // The idle demo drives the ring frame by frame: no clock, no easing, no breath of its own.
  property bool demo: false
  property real demoClose: -1
  property real demoTime: 0

  width: 0
  height: 0

  readonly property color foreground: colors ? colors.foreground : Commons.Color.foreground
  readonly property color accent: colors ? colors.accent : Commons.Color.accent
  readonly property color urgent: colors && colors.urgent !== undefined ? colors.urgent : Commons.Color.urgent

  // Milliseconds since Space, while a press runs
  property real elapsed: 0
  NumberAnimation on elapsed {
    from: 0
    to: 8000
    duration: 8000
    running: ball.ballState === "capturing" && !ball.demo && !ball.reducedMotion
  }
  onBallStateChanged: if (ball.ballState !== "capturing") ball.elapsed = 0

  readonly property real closeTarget: {
    if (demo) return demoClose < 0 ? 0 : demoClose
    if (ballState === "landed" || ballState === "done") return 1
    if (ballState !== "capturing") return 0
    return reducedMotion ? Dot.clamp(0.3 + 0.7 * good / Math.max(1, need), 0, 1) * (good > 0 ? 1 : 0.3)
                         : Dot.closing(elapsed, good, need)
  }
  property real close: closeTarget
  Behavior on close {
    enabled: !ball.reducedMotion && !ball.demo
    NumberAnimation { duration: ball.ballState === "capturing" ? 140 : 280; easing.type: Easing.OutCubic }
  }

  property real pulse: 0
  SequentialAnimation on pulse {
    loops: Animation.Infinite
    running: ball.ballState === "waiting" && !ball.reducedMotion && !ball.demo && ball.visible
    NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
    NumberAnimation { to: 0; duration: 900; easing.type: Easing.InOutSine }
  }
  readonly property real shownPulse: demo ? 0.5 + 0.5 * Math.sin(demoTime * 3.5) : pulse

  readonly property bool open: ballState === "waiting"

  Rectangle {
    id: ring
    objectName: "ballRing"
    readonly property real r: Dot.ringRadius(ball.close, ball.reducedMotion ? 0.5 : ball.shownPulse, ball.unit)
    width: 2 * r
    height: 2 * r
    radius: r
    x: -r
    y: -r
    color: "transparent"
    border.width: 2
    border.color: ball.ballState === "capturing" || ball.ballState === "landed" ? ball.accent
                  : (ball.failed && ball.open ? ball.urgent : ball.foreground)
    opacity: ball.open ? (ball.reducedMotion ? 0.7 : 0.45 + 0.4 * ball.shownPulse) : 0.95
    antialiasing: true
  }

  Rectangle {
    id: core
    objectName: "core"
    width: 2 * Dot.BALL * ball.unit
    height: 2 * Dot.BALL * ball.unit
    radius: Dot.BALL * ball.unit
    x: -Dot.BALL * ball.unit
    y: -Dot.BALL * ball.unit
    color: ball.ballState === "landed" ? ball.accent : ball.foreground
    antialiasing: true
    Behavior on color { ColorAnimation { duration: ball.reducedMotion ? 0 : 120 } }
  }
}
