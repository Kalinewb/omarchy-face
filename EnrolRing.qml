import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import qs.Commons as Commons
import "common/enrolring.js" as Ring
import "common/spring.js" as Spring

// The enrol ring (plan-face-enroll.md section 3): a pure Item. It draws what it is
// told and decides nothing -- which target is current, how far each is filled and
// which were skipped all come from the engine through `track`.
//
//   60 ticks around a circle, 5 to each of 12 pose bins. A tick is in one of four
//   looks, so state is never colour alone and never motion alone:
//     inactive  Simple's eight bins that are not targets: 5 px, 0.2, never change
//     rest      a target that is neither current nor started: 8 px, secondary, 0.7
//     current   the target the engine names: 14 px, foreground, 1.0, static
//     done      a covered tick: 20 px, accent, 0.9 (the share of a target's five
//               ticks that is covered is its progress, so dwell fills smoothly)
//   The centre is the circle's own rim: a 2 px arc that sweeps to accent with
//   `centre`. A 6 px dot rides between the circle and the ticks at the angle the
//   head is turned to. A thin hairline sweeps the face once per accepted frame.
//
// Whatever sits in the circle (the preview, the idle glyph, the check) is given as
// children: `default property alias content`.
Item {
  id: ring

  // "simple" | "advanced"
  property string mode: "simple"
  // The bins the lap names (Simple [9,3,0,6], Advanced all twelve).
  property var targets: Ring.targetsFor(mode)
  // "centre", a bin, or null.
  property var target: "centre"
  property real centre: 0
  // Twelve fractions, 0 to 1; 0 for a bin that is not a target, 1 once filled.
  property var bins: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  property var skipped: []
  property bool canFinish: false
  property real u: 0
  property real v: 0
  // idle | authorising | centre | lap1 | lap2 | trial | verdict | closing
  property string phase: "idle"
  property string message: ""
  // foreground, secondary, accent (colours)
  property var colors: null
  // Whether the hairline may run (a frame was accepted; the view sets it).
  property bool scanning: false
  // Counts accepted frames; the hairline re-arms on a change of this alone.
  property int scans: 0
  property bool reducedMotion: false
  // The idle demo drives `bins`, `target` and the rim: no spring on the ticks (they
  // follow the demo's own easing frame by frame) and `demoCentre` is the rim's fill.
  property bool demo: false
  property real demoCentre: 0
  // Round the preview/mask: true while something live is in the circle.
  property bool masked: false

  default property alias content: circleItem.data
  readonly property alias circle: circleItem

  readonly property color foreground: colors ? colors.foreground : Commons.Color.foreground
  readonly property color secondary: colors ? (colors.secondary !== undefined ? colors.secondary : colors.dim)
                                              : Qt.darker(Commons.Color.foreground, 1.55)
  readonly property color accent: colors ? colors.accent : Commons.Color.accent

  // 232 = 2 x (95 + 20 + 1): the done tick's outer end, plus a pixel.
  readonly property real full: 232
  implicitWidth: full
  implicitHeight: full

  readonly property bool active: phase === "centre" || phase === "lap1" || phase === "lap2" || phase === "trial"
  readonly property bool idle: phase === "idle"
  readonly property bool centreHeld: phase === "lap1" || phase === "lap2" || phase === "trial"
  readonly property real arc: demo ? demoCentre : Ring.centreArc(phase, centre)
  readonly property var dotPose: Ring.dot(u, v, 90)

  // The controls spring of common/spring.js: zeta 0.85, peak at 0.55, 200 ms.
  readonly property var tickSpring: Spring.curve(0.85, 0.55, 8)
  readonly property var hairSpring: Spring.curve(0.85, 0.55, 8)

  function nameOf(bin) {
    if (mode === "simple") {
      if (bin === 9) return "Left"
      if (bin === 3) return "Right"
      if (bin === 0) return "Up"
      if (bin === 6) return "Down"
    }
    return "Position " + (30 * bin) + " degrees"
  }

  // Simple's words for each of its four targets (the screen's sides, which the
  // mirrored preview makes the person's own).
  function prompt(bin) {
    if (bin === 9) return "turn your head to the left"
    if (bin === 3) return "turn your head to the right"
    if (bin === 0) return "tilt your head up"
    if (bin === 6) return "tilt your head down"
    return "move your head to position " + (30 * bin) + " degrees"
  }

  function percent(bin) {
    return Math.round(100 * Math.max(0, Math.min(1, Number(bins[bin]) || 0)))
  }

  function targetIndex() {
    if (target === "centre") return 0
    for (var i = 0; i < targets.length; i++) if (targets[i] === target) return i + 1
    return -1
  }

  // What a screen reader is told when the current target changes. The ring is a
  // ProgressBar, one for the whole scan and one per target below.
  readonly property string description: {
    // The idle demo moves every frame; a reader is told once what it is, not each frame.
    if (demo) return "A demonstration of the scan, nothing is recording"
    var filled = Ring.filledCount(targets, bins)
    if (mode === "advanced") return filled + " of " + targets.length + " positions"
    var step = targetIndex()
    if (step < 0) return filled + " of " + targets.length + " positions"
    var what = step === 0 ? "look straight at the circle, " + Math.round(100 * centre) + " percent"
             : prompt(target) + ", " + percent(target) + " percent"
    return "Step " + (step + 1) + " of " + (targets.length + 1) + ", " + what
  }

  Accessible.role: Accessible.ProgressBar
  Accessible.name: "Face scan"
  Accessible.description: ring.description

  // --- the ticks ------------------------------------------------------------------

  Item {
    id: canvas
    width: ring.full
    height: ring.full
    anchors.centerIn: parent

    Repeater {
      model: Ring.TICKS

      Item {
        id: tick
        required property int index
        readonly property var lk: Ring.look(ring.mode, ring.targets, ring.target, ring.bins, tick.index)
        readonly property color baseColor: lk.role === "foreground" ? ring.foreground : ring.secondary
        readonly property color targetColor: Qt.tint(baseColor, Qt.alpha(ring.accent, lk.cover))
        // What the tick is going to look like; the animated values below follow it.
        readonly property real targetLen: lk.len
        readonly property real targetOpacity: lk.opacity
        property real len: targetLen
        property color tint: targetColor
        property real shown: targetOpacity
        // The idle entrance: ticks appear 10 ms apart, once.
        property real appear: 0

        x: canvas.width / 2
        y: canvas.height / 2
        width: 0
        height: 0
        // The hundredth of a degree: a tick at exactly 180 degrees is drawn twice
        // over by the scene graph (a darker bar at six o'clock), and 0.01 is not.
        rotation: Ring.tickAngle(tick.index) + 0.01
        transformOrigin: Item.TopLeft
        opacity: ring.reducedMotion ? shown : shown * appear

        Behavior on len {
          enabled: !ring.reducedMotion && !ring.demo
          SequentialAnimation {
            // 40 ms between a bin's ticks, at most 240 ms.
            PauseAnimation { duration: Math.min(240, 40 * (tick.index % Ring.TICKS_PER_BIN)) }
            NumberAnimation {
              duration: 200
              easing.type: Easing.BezierSpline
              easing.bezierCurve: ring.tickSpring
            }
          }
        }
        Behavior on tint { ColorAnimation { duration: 90; easing.type: Easing.OutCubic } }
        Behavior on shown { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

        SequentialAnimation on appear {
          running: !ring.reducedMotion
          PauseAnimation { duration: 10 * tick.index }
          NumberAnimation { to: 1; duration: 120; easing.type: Easing.OutCubic }
        }

        // The tick grows outwards from its inner end, 95 px from the centre.
        Rectangle {
          objectName: "tick" + tick.index
          x: -width / 2
          y: -95 - tick.len
          width: 5
          height: tick.len
          radius: width / 2
          color: tick.tint
          antialiasing: true
        }
      }
    }

    // --- the centre: the circle's own rim ---------------------------------------
    Shape {
      id: rim
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      // The unfilled rim: foreground while the centre is the target, else secondary.
      ShapePath {
        strokeColor: ring.target === "centre" && ring.active ? ring.foreground : ring.secondary
        strokeWidth: 2
        fillColor: "transparent"
        PathAngleArc {
          centerX: canvas.width / 2; centerY: canvas.height / 2
          radiusX: 81; radiusY: 81
          startAngle: -90; sweepAngle: 360
        }
      }
      // Swept clockwise from the top to accent by `centre`, closed when held.
      ShapePath {
        strokeColor: ring.accent
        strokeWidth: 2
        fillColor: "transparent"
        PathAngleArc {
          centerX: canvas.width / 2; centerY: canvas.height / 2
          radiusX: 81; radiusY: 81
          startAngle: -90; sweepAngle: 359.9 * ring.arc
        }
      }
      opacity: ring.idle ? 0.7 : 1.0
    }

    // --- the circle ------------------------------------------------------------
    Item {
      id: circleItem
      width: 160
      height: 160
      anchors.centerIn: parent
      objectName: "circle"
      layer.enabled: ring.masked
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: circleMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
      }
    }

    // The scan hairline: one 1.5 px elliptical outline, over the face, clipped to
    // the circle. It sweeps once per accepted frame and rests otherwise; it is
    // feedback, never ornament, so nothing loops.
    Item {
      id: hairBox
      width: 160
      height: 160
      anchors.centerIn: parent
      visible: hair.running
      layer.enabled: hair.running
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: circleMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
      }

      Shape {
        id: hairShape
        objectName: "hairline"
        property real sweep: -0.1
        width: 160
        height: 40
        y: -20 + (160 + 20) * sweep
        preferredRendererType: Shape.CurveRenderer
        opacity: 0.6
        ShapePath {
          strokeColor: ring.foreground
          strokeWidth: 1.5
          fillColor: "transparent"
          PathAngleArc {
            centerX: 80; centerY: 20
            radiusX: 70; radiusY: 8
            startAngle: 0; sweepAngle: 360
          }
        }
      }
    }

    Item {
      id: circleMask
      visible: false
      width: 160
      height: 160
      anchors.centerIn: parent
      layer.enabled: true
      layer.smooth: true
      Rectangle { anchors.fill: parent; radius: width / 2; color: ring.foreground }
    }

    // --- the head dot ----------------------------------------------------------
    // The dot is the head, the highlighted wedge is the goal; it is a shape, not
    // a colour. It jumps in reduced motion and eases otherwise.
    Rectangle {
      id: headDot
      objectName: "headDot"
      readonly property bool shownNow: ring.active && ring.phase !== "authorising"
      width: 6
      height: 6
      radius: 3
      color: ring.foreground
      x: canvas.width / 2 + ring.dotPose.x - width / 2
      y: canvas.height / 2 + ring.dotPose.y - height / 2
      opacity: shownNow ? ring.dotPose.opacity : 0
      visible: opacity > 0.001
      antialiasing: true

      Behavior on x { enabled: !ring.reducedMotion; NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
      Behavior on y { enabled: !ring.reducedMotion; NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
    }
  }

  // The hairline's sweep, armed by an accepted frame and by nothing else.
  SequentialAnimation {
    id: hair
    running: false
    ScriptAction { script: hairShape.sweep = -0.1 }
    NumberAnimation {
      target: hairShape; property: "sweep"; to: 1.1; duration: 700
      easing.type: Easing.BezierSpline; easing.bezierCurve: ring.hairSpring
    }
    NumberAnimation { target: hairShape; property: "opacity"; to: 0; duration: 90 }
    ScriptAction { script: hairShape.opacity = 0.6 }
  }

  onScansChanged: {
    if (ring.scanning && ring.active && !ring.reducedMotion && !hair.running) hair.restart()
  }

  readonly property bool hairlineRunning: hair.running

  // --- for a screen reader: one ProgressBar per target ------------------------------

  Repeater {
    model: ring.targets

    Item {
      required property var modelData
      readonly property int bin: modelData
      readonly property string a11yName: ring.nameOf(bin)
      readonly property string a11yDescription: ring.percent(bin) >= 100 ? "done" : ring.percent(bin) + " percent"
      objectName: "target" + bin
      width: 0
      height: 0
      Accessible.role: Accessible.ProgressBar
      Accessible.name: a11yName
      Accessible.description: a11yDescription
    }
  }
}
