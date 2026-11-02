import QtQuick
import qs.Commons
import "common/spring.js" as Spring

// The enrol card's body: the scan as an island of its own, in the notch's
// silhouette, with no window around it. RecordCard.qml puts it in a layer-shell
// window of its own, on the Overlay layer above the real notch; it is never hosted
// in the notch (Start brings up polkit's password dialog, and a scan drawn inside
// the notch's panel died with the panel when the notch lost focus).
//
// The silhouette is the notch's (Island.qml, the same drawing the indicator uses):
// true #000000, the top edge flush with the screen edge, the two top corners
// square with a concave fillet beside each, and a convex radius on the bottom two,
// horizontally centred on the monitor it is drawn on. The two radii come from the
// owner (the notch's own `bottomRadius` and `filletRadius`, read from the user's
// shell.json by the Face service), so it is cut like the notch it sits over.
//
// It drops down from the top edge when it appears and retracts into it when it
// goes: height over 350 ms and width 50 ms later over 300 ms on a damped spring
// (the notch's own numbers), then 240 ms ease-out to leave, with no overshoot.
// With reduced motion (OMARCHY_REDUCED_MOTION=1 or NOTCH_REDUCED_MOTION=1, in
// `colors.reducedMotion`) there is no animation at all. Only the island's height
// and width ever move: its top edge is on the screen edge at every frame.
//
// Everything about the scan is EnrolView.qml's and RecordSession.qml's; this file
// is the shape around them.
Item {
  id: root

  property var session: null
  // foreground, secondary, accent, urgent, fontFamily, radiusFor, reducedMotion
  property var colors: null
  property string previewDevice: ""
  // The window is showing this: the camera may open once Start is pressed.
  property bool live: false
  property var appearanceLabels: ["No glasses", "Everyday glasses", "Reading glasses"]
  property var recordedAppearances: []
  property string notice: ""
  // The notch's silhouette (shell.json, notch.bottomRadius / filletRadius).
  property real bottomRadius: 10
  property real filletRadius: 10
  // The most width the screen allows the bar.
  property real maxWidth: 0

  readonly property alias enrolView: enrol
  // The island, for a window that wants an input region around exactly it.
  readonly property alias shape: island

  readonly property bool reduced: root.colors && root.colors.reducedMotion !== undefined
                                  ? !!root.colors.reducedMotion : false

  signal closeRequested()
  // The retract has finished: the owner may destroy the window.
  signal retracted()

  // The notch's side padding, on every side: the same margin the notch gives a
  // panel (Style.space(14)), around a 320 px column.
  readonly property real pad: Style.space(14)
  readonly property real columnWidth: Style.space(320)
  readonly property real fullWidth: {
    var w = root.columnWidth + 2 * root.pad
    return root.maxWidth > 0 ? Math.min(w, Math.max(0, root.maxWidth - 2 * island.fillet)) : w
  }
  readonly property real fullHeight: enrol.implicitHeight + 2 * root.pad

  // 0 to 1: how far the island has dropped. The animation drives these; with
  // reduced motion they are simply 1.
  property real heightP: 0
  property real widthP: 0
  property bool leaving: false

  readonly property var springCurve: Spring.curve(0.72, 0.6, 8)
  readonly property real seedWidthFraction: 0.35

  function activate() { enrol.activate() }
  function isRecorded(label) { return enrol.isRecorded(label) }
  function isCapturedNow(label) { return enrol.isCapturedNow(label) }
  function appearanceMark(label) { return enrol.appearanceMark(label) }
  function actionText() { return enrol.actionText() }
  function actionNote() { return enrol.actionNote() }

  function drop() {
    root.leaving = false
    if (root.reduced) { root.heightP = 1; root.widthP = 1; return }
    leaveAnim.stop()
    enterAnim.start()
  }

  // Retract into the top edge, then say so. Asked twice, it answers once.
  function retract() {
    if (root.leaving) return
    root.leaving = true
    enterAnim.stop()
    if (root.reduced) {
      root.heightP = 0
      root.widthP = 0
      Qt.callLater(function () { root.retracted() })
      return
    }
    leaveAnim.start()
  }

  Component.onCompleted: root.drop()

  ParallelAnimation {
    id: enterAnim
    NumberAnimation {
      target: root; property: "heightP"; to: 1; duration: 350
      easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve
    }
    SequentialAnimation {
      PauseAnimation { duration: 50 }
      NumberAnimation {
        target: root; property: "widthP"; to: 1; duration: 300
        easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve
      }
    }
  }

  SequentialAnimation {
    id: leaveAnim
    ParallelAnimation {
      NumberAnimation { target: root; property: "heightP"; to: 0; duration: 240; easing.type: Easing.OutCubic }
      NumberAnimation { target: root; property: "widthP"; to: 0; duration: 240; easing.type: Easing.OutCubic }
    }
    ScriptAction { script: root.retracted() }
  }

  Island {
    id: island
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: 0

    // The bar grows from a seed 35% as wide as it will be and no height, top edge
    // on the screen edge from the first frame.
    barWidth: Math.max(0, root.fullWidth * (root.seedWidthFraction
                + (1 - root.seedWidthFraction) * Math.max(0, root.widthP)))
    barHeight: Math.max(0, root.fullHeight * Math.max(0, root.heightP))
    bottomRadius: root.bottomRadius
    // Scales with the bar while it grows, so the fillets are never wider than
    // the straight part of its side.
    filletRadius: root.fullHeight > 0 ? root.filletRadius * Math.min(1, island.barHeight / root.fullHeight) : 0
    color: "#000000"

    EnrolView {
      id: enrol
      // Laid out at the settled size, never the animated one: a column that
      // re-wraps mid-grow changes the very height it is being measured for.
      x: root.pad
      y: root.pad
      width: root.columnWidth

      session: root.session
      colors: root.colors
      previewDevice: root.previewDevice
      live: root.live
      appearanceLabels: root.appearanceLabels
      recordedAppearances: root.recordedAppearances
      notice: root.notice
      onCloseRequested: root.closeRequested()

      // Only once the bar is mostly grown, so the ring and the links are never
      // seen half-clipped inside a bar still arriving. The bar itself never
      // fades; this is what is in it.
      opacity: root.reduced ? (root.heightP > 0.5 ? 1 : 0)
                            : Math.max(0, Math.min(1, (Math.min(root.heightP, root.widthP) - 0.7) / 0.3))
    }
  }
}
