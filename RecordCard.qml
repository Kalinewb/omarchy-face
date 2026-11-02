import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// The recording card (plan-gui.md §5.3): the scan as an island of its own, in the
// notch's silhouette, dropped from the top edge under the camera on the Overlay
// layer, above whatever the real notch is showing, so the person is looking at the
// camera while they read it.
//
// It belongs to the Face service and not to the popup, for two reasons that are
// both structural: it needs exclusive keyboard focus (a popup's key catcher
// cannot give it that), and it has to outlive the popup, which any write under
// ~/.config/omarchy/plugins destroys (plan-engine.md E13).
//
// This file is the window; the shape, the drop and the retract are ScanIsland.qml,
// and what is inside that -- the ring, the line, the links, and on an old helper
// the single capture's picker and buttons -- is EnrolView.qml. This window is
// where every scan lives, whichever home asked for it: Start brings up polkit's
// password dialog, and a scan drawn inside the notch's panel died with the panel
// when the notch lost focus to it (Phase 4's live gate). A window of its own is
// not the notch's, so the dialog cannot collapse it: it has no focus-loss handling
// and closes only on Esc, Cancel, Done or the session ending, retracting into the
// top edge. Every decision about the session is in RecordSession.qml.
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
  // The notch's own silhouette, from the user's shell.json (Service.qml).
  property real bottomRadius: 10
  property real filletRadius: 10

  // What the picker shows and says is the view's; these are the card's way of
  // being asked, which is how Service.qml's state() and the offscreen suites
  // question a card that has no window they could read.
  property alias recordedAppearances: island.recordedAppearances
  function isRecorded(label) { return island.isRecorded(label) }
  function isCapturedNow(label) { return island.isCapturedNow(label) }
  function appearanceMark(label) { return island.appearanceMark(label) }
  function actionText() { return island.actionText() }
  function actionNote() { return island.actionNote() }

  // Something asked for root while this card was up. The indicator stands down
  // for this card (it would be two cards in one place), so its line arrives here
  // instead: a person staring into the lens for a countdown must not be the one
  // person who never hears that a sudo happened (Indicator.qml).
  property alias notice: island.notice

  // Not `closed`: every Quickshell window already has a `closed` signal, and
  // declaring a second one is an invalid override -- Qt warns about it today
  // and is on its way to refusing it.
  signal dismissed()
  // The island has retracted into the top edge: the window may be destroyed.
  signal retracted()

  // Leave: retract into the top edge, then `retracted`.
  function retract() { island.retract() }

  // The card's palette: white on its black surface, the theme's accent.
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

  // A strip along the top edge, as wide as the monitor it opens on (the
  // compositor puts a window with no screen of its own on the focused one), so the
  // island is centred on that monitor as the notch is. The strip is fixed and tall
  // enough for the settled island: only the island inside it ever changes size,
  // because resizing a layer surface makes the compositor stretch its old buffer
  // for a few frames. Clicks anywhere outside the island go to whatever is there.
  anchors { top: true; left: true; right: true }
  implicitHeight: Style.space(700)
  color: "transparent"
  mask: Region { item: island.shape }
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omarchy-face-record"
  WlrLayershell.layer: WlrLayer.Overlay
  // Exclusive, as the card has always had: what lets Return and Esc work the
  // moment it appears, and what polkit's dialog has always had to share the
  // screen with. Nothing here reacts to the focus moving away.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  Component.onCompleted: Qt.callLater(function () { keys.forceActiveFocus() })

  FocusScope {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.onEscapePressed: card.requestClose()
    Keys.onReturnPressed: island.activate()

    ScanIsland {
      id: island
      anchors.fill: parent

      session: card.session
      colors: cardColors
      previewDevice: card.previewDevice
      // The card is on screen from the moment it exists; the camera still
      // waits for Start (the session says `previewWanted`).
      live: card.visible
      appearanceLabels: card.appearanceLabels
      bottomRadius: card.bottomRadius
      filletRadius: card.filletRadius
      maxWidth: card.width
      onCloseRequested: card.requestClose()
      onRetracted: card.retracted()
    }
  }
}
