import QtQuick

// The indicator's shape: a bar hanging from the top edge of the screen and
// fused to it, the way a Dynamic Island is fused to the notch it grows out of.
//
// Three items, and the split between them is the whole point:
//
//   · the bar -- a plain Rectangle. Top edge flush with the screen edge, top
//     corners square (radius 0), bottom corners rounded with an ordinary
//     convex radius. Nothing is carved out of it and nothing is added to it.
//
//   · two fillets, one beside each top corner, drawn OUTSIDE the bar. Each is
//     what is left of an r×r square sitting in the open angle between the
//     bar's side and the screen edge once a quarter-disc is taken out of it.
//     That disc's centre is out in the open -- r from the side, r from the
//     edge -- so its arc is tangent to both lines, and the background curves
//     into the bar's side without a kink. They are painted the bar's colour so
//     they read as the edge flowing into the bar, but they are separate items:
//     the bar's own rectangle stays exactly a rectangle.
//
// What this deliberately is not (both were tried, and both read as a thing
// placed under the edge rather than grown out of it):
//
//   · a positive radius on the bar's TOP corners -- a pill floating just
//     below the edge;
//   · arcs cut out of the bar's own body at the top corners -- a notch bitten
//     into the bar, with the arc centres at the corners themselves.
//
// The centres and radii are exposed as readonly properties so the geometry
// can be checked as numbers (dev/g5c-island-offscreen.sh does) rather than by
// squinting at a screenshot.
Item {
  id: root

  // The bar's own rectangle.
  property real barWidth: 0
  property real barHeight: 0
  // Requested radii; `bottomR` and `fillet` below are what actually fits.
  property real bottomRadius: 0
  property real filletRadius: 0
  property color color: "#000000"

  // Children declared inside an Island land inside the bar, clipped to it.
  default property alias contents: bar.data

  // The convex radius of the bottom two corners: no more than half the width
  // (or the two corners would overlap) and no more than the height.
  readonly property real bottomR: Math.max(0, Math.min(bottomRadius, barWidth / 2, barHeight))

  // The fillet radius: no more than the straight part of the bar's side (its
  // height minus the bottom radius), or the arc would run into the convex
  // corner below it instead of landing tangent on a straight edge.
  readonly property real fillet: Math.max(0, Math.min(filletRadius, barHeight - bottomR))

  // The fillets widen the footprint by one radius each side and the bar sits
  // in the middle, so centring the Island centres the bar.
  implicitWidth: barWidth + 2 * fillet
  implicitHeight: barHeight
  width: implicitWidth
  height: implicitHeight

  // Where the bar's rectangle starts, in this item's coordinates.
  readonly property real barX: fillet

  // Arc centres, in the BAR's coordinates: origin at the bar's top-left
  // corner, x to the right, y down. The fillet centres lie outside the bar,
  // in the open angle between its side and the screen edge -- the only place
  // a circle tangent to both of those lines can be centred. The bottom
  // centres are the ordinary convex ones, one radius in from each edge.
  readonly property point leftFilletCentre: Qt.point(-fillet, fillet)
  readonly property point rightFilletCentre: Qt.point(barWidth + fillet, fillet)
  readonly property point bottomLeftCentre: Qt.point(bottomR, barHeight - bottomR)
  readonly property point bottomRightCentre: Qt.point(barWidth - bottomR, barHeight - bottomR)

  // Each fillet is painted in a square one pixel wider than its radius, with
  // that extra column tucked under the bar (the bar is declared after the
  // fillets, so it paints on top). The visible fillet is exactly the square
  // minus the quarter-disc; the hidden column only stops the two
  // antialiased edges that would otherwise share a boundary from showing a
  // hairline seam when the Island lands on a half pixel.
  readonly property real seamOverlap: 1

  function paintFillet(ctx, side) {
    var r = root.fillet
    ctx.reset()
    ctx.clearRect(0, 0, r + root.seamOverlap, r)
    if (r <= 0) return
    ctx.beginPath()
    if (side === "left") {
      // Local frame: the bar's side is x = r (the square's right edge), the
      // screen edge is y = 0, the arc's centre is the bottom-left corner
      // (0, r). Path: the bar's top corner, down its side to the tangent
      // point, then the arc back up to where it meets the screen edge.
      ctx.moveTo(r + root.seamOverlap, 0)
      ctx.lineTo(r + root.seamOverlap, r)
      ctx.lineTo(r, r)
      ctx.arc(0, r, r, 0, -Math.PI / 2, true)
    } else {
      // Mirror image: the bar's side is x = seamOverlap (the square's left
      // edge, after the hidden column), the arc's centre is the bottom-right
      // corner (seamOverlap + r, r).
      var o = root.seamOverlap
      ctx.moveTo(0, 0)
      ctx.lineTo(0, r)
      ctx.lineTo(o, r)
      ctx.arc(o + r, r, r, Math.PI, 3 * Math.PI / 2, false)
    }
    ctx.closePath()
    ctx.fillStyle = root.color
    ctx.fill()
  }

  // Both fillets paint on the GUI thread, in the same frame as the bindings
  // above them: `Immediate` is the default, and it is spelled out because
  // the fused look depends on it -- a threaded canvas can lag the bar by a
  // frame while the bar's width is animating, and a fillet one frame behind
  // the side it is meant to flow into is a visible notch. Their positions
  // and sizes are plain bindings on the bar's width and height, so they do
  // not have an animation of their own to fall behind on either.
  Canvas {
    id: leftFillet
    x: 0
    y: 0
    width: root.fillet + root.seamOverlap
    // Never a zero-sized canvas: hidden instead, while the bar is retracting.
    height: Math.max(1, root.fillet)
    visible: root.fillet > 0
    renderStrategy: Canvas.Immediate
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: root.paintFillet(getContext("2d"), "left")
  }

  Canvas {
    id: rightFillet
    x: root.barX + root.barWidth - root.seamOverlap
    y: 0
    width: root.fillet + root.seamOverlap
    // Never a zero-sized canvas: hidden instead, while the bar is retracting.
    height: Math.max(1, root.fillet)
    visible: root.fillet > 0
    renderStrategy: Canvas.Immediate
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: root.paintFillet(getContext("2d"), "right")
  }

  onColorChanged: { leftFillet.requestPaint(); rightFillet.requestPaint() }

  // The bar. Declared last so it paints over the fillets' hidden columns.
  Rectangle {
    id: bar
    x: root.barX
    y: 0
    width: root.barWidth
    height: root.barHeight
    color: root.color
    border.width: 0
    topLeftRadius: 0
    topRightRadius: 0
    bottomLeftRadius: root.bottomR
    bottomRightRadius: root.bottomR
    clip: true
  }
}
