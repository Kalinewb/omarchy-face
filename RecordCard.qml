import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "common/spring.js" as Spring

// The recording card (plan-gui.md §5.3): a scrim on the built-in screen with a
// card at the top, under the webcam, so the person is looking at the camera
// while they read it.
//
// It belongs to the Face service and not to the popup, for two reasons that are
// both structural: it needs exclusive keyboard focus (a popup's key catcher
// cannot give it that), and it has to outlive the popup, which any write under
// ~/.config/omarchy/plugins destroys (plan-engine.md E13).
//
// This file is the window around the enrol view. What is inside it -- the ring,
// the line, the links, and on an old helper the single capture's picker and
// buttons -- is EnrolView.qml, which the notch shows in place when it is the
// host; every decision about the session is in RecordSession.qml.
PanelWindow {
  id: card

  // The session this card draws. Created by the caller so the card can be
  // opened on a session that is already running.
  required property var session
  property string fontFamily: Style.font.family
  // The RGB preview node from `omarchy-face-status` (`camera.rgb`), or "" when
  // this laptop has none (plan-merged.md §1 row 18).
  property string previewDevice: ""
  // The three standard labels, so the picker offers the same words as the
  // person view.
  property var appearanceLabels: ["No glasses", "Everyday glasses", "Reading glasses"]

  // What the picker shows and says is the view's; these are the card's way of
  // being asked, which is how Service.qml's state() and the offscreen suites
  // question a card that has no window they could read.
  property alias recordedAppearances: view.recordedAppearances
  function isRecorded(label) { return view.isRecorded(label) }
  function isCapturedNow(label) { return view.isCapturedNow(label) }
  function appearanceMark(label) { return view.appearanceMark(label) }
  function actionText() { return view.actionText() }
  function actionNote() { return view.actionNote() }

  // Something asked for root while this card was up. The indicator stands down
  // for this card (it would be two cards in one place), so its line arrives here
  // instead: a person staring into the lens for a countdown must not be the one
  // person who never hears that a sudo happened (Indicator.qml).
  property alias notice: view.notice

  // Not `closed`: every Quickshell window already has a `closed` signal, and
  // declaring a second one is an invalid override -- Qt warns about it today
  // and is on its way to refusing it.
  signal dismissed()

  // The card's palette: white on its black scrim, the theme's accent.
  QtObject {
    id: cardColors
    readonly property color foreground: "white"
    readonly property color secondary: Qt.darker("white", 1.55)
    readonly property color accent: Commons.Color.accent
    readonly property color urgent: Commons.Color.urgent
    readonly property string fontFamily: card.fontFamily
    readonly property bool reducedMotion: Quickshell.env("OMARCHY_REDUCED_MOTION") === "1"
                                          || Quickshell.env("NOTCH_REDUCED_MOTION") === "1"
    function radiusFor(size) { return Style.cornerRadius }
  }

  readonly property string phase: session ? session.phase : "framing"

  function requestClose() {
    if (!session) { card.dismissed(); return }
    // Esc during `capturing` is ignored with "Almost done"; before any capture
    // it discards; after one it is Done (plan-gui.md §5.3).
    session.requestClose()
  }

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omarchy-face-record"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  Component.onCompleted: {
    Qt.callLater(function () { keys.forceActiveFocus() })
    enterAnim.start()
  }

  // Grown out of the top edge, on the indicator's curve (common/spring.js):
  // height over 350 ms, width from 50 ms over 300 ms, both landing together.
  // The window's position, opacity and scale are never animated -- only the
  // bar's own height and width, so its top edge is on the screen's top edge
  // at every frame including the first (post-ship revision).
  property real heightP: 0
  property real widthP: 0
  readonly property var springCurve: Spring.curve(0.72, 0.6, 8)

  ParallelAnimation {
    id: enterAnim
    NumberAnimation {
      target: card; property: "heightP"; to: 1; duration: 350
      easing.type: Easing.BezierSpline; easing.bezierCurve: card.springCurve
    }
    SequentialAnimation {
      PauseAnimation { duration: 50 }
      NumberAnimation {
        target: card; property: "widthP"; to: 1; duration: 300
        easing.type: Easing.BezierSpline; easing.bezierCurve: card.springCurve
      }
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.78)

    // Clicking the scrim is the same as Esc: it is the only other way out, and
    // it must not be a way to abandon a session that is mid-capture.
    MouseArea {
      anchors.fill: parent
      onClicked: card.requestClose()
    }
  }

  FocusScope {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.onEscapePressed: card.requestClose()
    Keys.onReturnPressed: view.activate()

    // The card, top-centre, roughly under the built-in camera.
    // The card is its own surface: a click on it must not reach the scrim.
    // A sibling of the card rather than a child of it, because Island's
    // children live inside the bar and so would not cover the two fillets at
    // its top corners -- and a click on one of those would fall through to the
    // scrim and discard the session. Declared before the card, so everything
    // inside it still takes its own clicks first.
    MouseArea {
      x: panel.x
      y: panel.y
      width: panel.width
      height: panel.height
      onClicked: {}
    }

    // The card, fused to the top edge under the built-in camera. The same
    // shape as the indicator and the Test card (Island.qml): flush top, square
    // top corners, an ordinary convex radius on the bottom two, and the two
    // concave background fillets that carry the sides into the screen edge.
    // This was a rounded panel floating 44px below the edge until the
    // indicator stopped being one, and three cards in the same piece of screen
    // looking like three programs is what that left behind (post-ship
    // revision, found via live use).
    Island {
      id: panel
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: 0

      readonly property real fullWidth: Math.min(card.width - Style.space(40), Style.space(420))
      readonly property real fullHeight: view.implicitHeight + Style.space(28)
      // Fixed, never the bar's animated width: the preview, the picker and
      // three wrapping Texts all measure against this, and a column that
      // re-wraps mid-grow changes the very height it is being measured for.
      readonly property real contentWidth: fullWidth - Style.space(28)

      // The seed the bar grows from, as fractions of the settled size. Not
      // zero, so the first frame is already a bar with its fillets on it.
      readonly property real seedWidthFraction: 0.4
      readonly property real seedHeightFraction: 0.2
      barWidth: Math.max(0, fullWidth * (seedWidthFraction
                  + (1 - seedWidthFraction) * card.widthP))
      barHeight: Math.max(0, fullHeight * (seedHeightFraction
                  + (1 - seedHeightFraction) * card.heightP))

      // Absolute, not the indicator's fifth-of-the-height: this card is far
      // taller than it is wide, and a fifth of its height would be a capsule.
      // 25 is what the indicator's rule settles at, so the two read as the
      // same material.
      bottomRadius: Style.space(25)
      filletRadius: Style.space(10) * barHeight / fullHeight
      color: "#000000"

      EnrolView {
        id: view
        anchors.centerIn: parent
        width: panel.contentWidth

        session: card.session
        colors: cardColors
        previewDevice: card.previewDevice
        // The card is on screen from the moment it exists; the camera still
        // waits for Start (the session says `previewWanted`).
        live: card.visible
        appearanceLabels: card.appearanceLabels
        onCloseRequested: card.requestClose()

        // Only once the bar is mostly grown, so the ring and the links are
        // never seen half-clipped inside a bar still arriving. The bar itself
        // never fades; this is what is in it.
        opacity: Math.max(0, Math.min(1, (Math.min(card.heightP, card.widthP) - 0.7) / 0.3))
      }
    }
  }
}
