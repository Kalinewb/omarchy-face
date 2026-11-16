import QtQuick
import QtQuick.Shapes
import qs.Commons

// Face's one face glyph (3.3.1): four rounded corner brackets round a minimal face (two eyes, a
// nose, a mouth), drawn from strokes, no font and no picture. Every place that says "a face is being
// looked at" uses it (the indicator, the Test card and its in-place view, the dot scan's circle), so
// the same thing looks the same everywhere.
//
//   idle       still, in the secondary colour: nothing is happening
//   scanning   the brackets breathe (opacity only) and one thin line moves down the face, both slow
//   success    the face goes and the brackets close into a check, drawn in the accent
//   failure    the glyph turns urgent and shakes once, side to side
//
// Reduced motion: no breathing, no line, no shake and no drawing of the check; each state is its
// still picture. The colours come from the host (`fg`, `secondary`, `accent`, `urgent`), never from
// the theme directly, so the glyph is right on the card's true black and in a themed panel alike.
Item {
  id: glyph

  // idle | scanning | success | failure (not `state`: Item has one)
  property string look: "idle"
  property color fg: "white"
  property color secondary: Qt.darker("white", 1.55)
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  property bool reduced: false
  property real size: Style.space(56)

  width: size
  height: size

  readonly property bool scanning: glyph.look === "scanning"
  readonly property bool success: glyph.look === "success"
  readonly property bool failure: glyph.look === "failure"
  readonly property real lineWidth: Math.max(2, glyph.size * 0.05)

  // What a screen reader is told; the state is the glyph's whole meaning.
  Accessible.role: Accessible.Graphic
  Accessible.name: glyph.success ? "Recognised" : glyph.failure ? "Not recognised"
                   : glyph.scanning ? "Looking for your face" : "Face"

  // The face and its brackets are in `stage`, which is what shakes.
  property real shakeX: 0
  property real breath: 1          // the brackets' opacity while scanning
  property real done: glyph.success ? 1 : 0
  Behavior on done { enabled: !glyph.reduced; NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

  readonly property color mainColor: glyph.failure ? glyph.urgent : (glyph.scanning ? glyph.fg : glyph.secondary)

  Item {
    id: stage
    anchors.fill: parent
    transform: Translate { x: glyph.shakeX }

    // The brackets: a rounded corner and an arm each way, at the four corners of the square
    Shape {
      id: brackets
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      opacity: (glyph.scanning ? glyph.breath : 1) * (1 - glyph.done)
      scale: 1 - 0.3 * glyph.done
      transformOrigin: Item.Center

      readonly property real m: glyph.size * 0.06         // margin to the edge
      readonly property real a: glyph.size * 0.26         // the arm
      readonly property real r: glyph.size * 0.15         // the corner
      readonly property real w: glyph.size

      ShapePath {
        strokeColor: glyph.mainColor
        strokeWidth: glyph.lineWidth
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        // top left
        startX: brackets.m; startY: brackets.m + brackets.a
        PathLine { x: brackets.m; y: brackets.m + brackets.r }
        PathArc { x: brackets.m + brackets.r; y: brackets.m; radiusX: brackets.r; radiusY: brackets.r; direction: PathArc.Clockwise }
        PathLine { x: brackets.m + brackets.a; y: brackets.m }
        // top right
        PathMove { x: brackets.w - brackets.m - brackets.a; y: brackets.m }
        PathLine { x: brackets.w - brackets.m - brackets.r; y: brackets.m }
        PathArc { x: brackets.w - brackets.m; y: brackets.m + brackets.r; radiusX: brackets.r; radiusY: brackets.r; direction: PathArc.Clockwise }
        PathLine { x: brackets.w - brackets.m; y: brackets.m + brackets.a }
        // bottom right
        PathMove { x: brackets.w - brackets.m; y: brackets.w - brackets.m - brackets.a }
        PathLine { x: brackets.w - brackets.m; y: brackets.w - brackets.m - brackets.r }
        PathArc { x: brackets.w - brackets.m - brackets.r; y: brackets.w - brackets.m; radiusX: brackets.r; radiusY: brackets.r; direction: PathArc.Clockwise }
        PathLine { x: brackets.w - brackets.m - brackets.a; y: brackets.w - brackets.m }
        // bottom left
        PathMove { x: brackets.m + brackets.a; y: brackets.w - brackets.m }
        PathLine { x: brackets.m + brackets.r; y: brackets.w - brackets.m }
        PathArc { x: brackets.m; y: brackets.w - brackets.m - brackets.r; radiusX: brackets.r; radiusY: brackets.r; direction: PathArc.Clockwise }
        PathLine { x: brackets.m; y: brackets.w - brackets.m - brackets.a }
      }
    }

    // The face: two eyes, a nose, a mouth
    Shape {
      id: face
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      opacity: (1 - glyph.done) * 0.95

      readonly property real s: glyph.size

      ShapePath {
        strokeColor: glyph.mainColor
        strokeWidth: glyph.lineWidth
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        // eyes
        startX: face.s * 0.36; startY: face.s * 0.37
        PathLine { x: face.s * 0.36; y: face.s * 0.45 }
        PathMove { x: face.s * 0.64; y: face.s * 0.37 }
        PathLine { x: face.s * 0.64; y: face.s * 0.45 }
        // nose
        PathMove { x: face.s * 0.50; y: face.s * 0.42 }
        PathLine { x: face.s * 0.50; y: face.s * 0.56 }
        PathQuad { x: face.s * 0.455; y: face.s * 0.585; controlX: face.s * 0.50; controlY: face.s * 0.585 }
        // mouth
        PathMove { x: face.s * 0.38; y: face.s * 0.68 }
        PathQuad { x: face.s * 0.62; y: face.s * 0.68; controlX: face.s * 0.50; controlY: face.s * 0.77 }
      }
    }

    // The scan line: thin, quiet, down the face and back, only while scanning
    Rectangle {
      id: sweep
      visible: glyph.scanning && !glyph.reduced
      x: glyph.size * 0.22
      width: glyph.size * 0.56
      height: Math.max(1.5, glyph.lineWidth * 0.5)
      radius: height / 2
      color: glyph.fg
      opacity: 0.35
      y: glyph.size * 0.26 + glyph.size * 0.48 * sweepPos.t
      QtObject { id: sweepPos; property real t: 0 }
    }

    // The check the brackets become
    Shape {
      id: check
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      visible: glyph.done > 0

      // drawn along its path: the short stroke first, then the long one
      readonly property real s: glyph.size
      readonly property real first: Math.min(1, glyph.done * 2.2)
      readonly property real second: Math.max(0, Math.min(1, (glyph.done - 0.3) / 0.7))

      ShapePath {
        strokeColor: glyph.accent
        strokeWidth: glyph.lineWidth * 1.3
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: check.s * 0.26; startY: check.s * 0.53
        PathLine { x: check.s * (0.26 + 0.14 * check.first); y: check.s * (0.53 + 0.14 * check.first) }
        PathLine { x: check.s * (0.40 + 0.34 * check.second); y: check.s * (0.67 - 0.31 * check.second) }
      }
    }
  }

  // The brackets breathe and a line moves, while scanning and motion is allowed
  SequentialAnimation {
    running: glyph.scanning && !glyph.reduced
    loops: Animation.Infinite
    NumberAnimation { target: glyph; property: "breath"; from: 1; to: 0.5; duration: 900; easing.type: Easing.InOutSine }
    NumberAnimation { target: glyph; property: "breath"; from: 0.5; to: 1; duration: 900; easing.type: Easing.InOutSine }
    onRunningChanged: if (!running) glyph.breath = 1
  }
  SequentialAnimation {
    running: glyph.scanning && !glyph.reduced
    loops: Animation.Infinite
    NumberAnimation { target: sweepPos; property: "t"; from: 0; to: 1; duration: 1100; easing.type: Easing.InOutSine }
    NumberAnimation { target: sweepPos; property: "t"; from: 1; to: 0; duration: 1100; easing.type: Easing.InOutSine }
  }

  // A failure shakes once: +6, -6, +3, 0 per cent of the size, 50 ms each (the old ring's shake)
  SequentialAnimation {
    id: shake
    NumberAnimation { target: glyph; property: "shakeX"; to: glyph.size * 0.06; duration: 50 }
    NumberAnimation { target: glyph; property: "shakeX"; to: -glyph.size * 0.06; duration: 50 }
    NumberAnimation { target: glyph; property: "shakeX"; to: glyph.size * 0.03; duration: 50 }
    NumberAnimation { target: glyph; property: "shakeX"; to: 0; duration: 50 }
  }
  onFailureChanged: if (glyph.failure && !glyph.reduced) shake.restart(); else if (!glyph.failure) glyph.shakeX = 0
  Component.onCompleted: if (glyph.failure && !glyph.reduced) shake.restart()
}
