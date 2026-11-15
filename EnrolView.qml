import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The enrol screen (plan-face-enroll.md section 3): the dot scan's card (DotCard.qml), or on a
// helper older than 3.2.0 the single capture (RecordView.qml). RecordCard.qml puts it in its window
// under the camera, in every home: a scan is never drawn inside the notch (Start brings up
// polkit's password dialog, which takes the focus the notch needs to stay open; the Phase 4 live
// gate, doubt 11). It draws no window, no background and no container animation, and it takes its
// look from `colors` (foreground, secondary, accent, urgent, fontFamily, radiusFor,
// reducedMotion), the card's.
//
// Everything about the scan is RecordSession.qml's (the state machine) and the helper's (what is
// taken, whether a face is good); this file is what that looks like.
//
// This is the only file that names the RGB camera (RecordPreview.qml). The camera
// exists only while `previewOn`: the card is showing this view AND the person has
// pressed Start AND no verdict has come (plan-face-enroll.md 6a.1). In `idle`
// there is no camera object at all.
Item {
  id: view

  property var session: null
  // foreground, secondary (or dim), accent, urgent, fontFamily, radiusFor(size),
  // reducedMotion -- the card's (RecordCard.qml).
  property var colors: null
  // The RGB preview node from `omarchy-face-status` (`camera.rgb`), or "".
  property string previewDevice: ""
  // The card is showing this view right now (its window is visible).
  property bool live: false
  property var appearanceLabels: ["No glasses", "Everyday glasses", "Reading glasses"]
  property var recordedAppearances: []
  // Something asked for root while this was up (Indicator.qml), as RecordView.
  property string notice: ""

  signal closeRequested()

  // The fence. The camera may open only while this is true.
  readonly property bool previewOn: view.live && !!view.session && view.session.previewWanted

  // The measured crop of the RGB view that the IR sensor also sees (x, y, w, h,
  // normalised), until Phase 0 measures it: centred, with a 10% margin.
  property var irCrop: ({ x: 0.05, y: 0.05, w: 0.9, h: 0.9 })

  readonly property bool legacy: !view.session || !view.session.scan || view.session.legacy
  readonly property string phase: view.session ? view.session.phase : "idle"

  // --- the card's colours -------------------------------------------------------
  readonly property color fg: view.colors ? view.colors.foreground : Commons.Color.foreground
  readonly property color secondary: view.colors
      ? (view.colors.secondary !== undefined ? view.colors.secondary : view.colors.dim)
      : Qt.darker(Commons.Color.foreground, 1.55)
  readonly property color accent: view.colors ? view.colors.accent : Commons.Color.accent
  readonly property color urgent: view.colors && view.colors.urgent !== undefined ? view.colors.urgent : Commons.Color.urgent
  readonly property string fontFamily: view.colors && view.colors.fontFamily !== undefined
      ? view.colors.fontFamily : Style.font.family
  readonly property bool reduced: view.colors && view.colors.reducedMotion !== undefined
      ? !!view.colors.reducedMotion
      : (Quickshell.env("OMARCHY_REDUCED_MOTION") === "1" || Quickshell.env("NOTCH_REDUCED_MOTION") === "1")

  function radiusFor(size) {
    return view.colors && view.colors.radiusFor ? view.colors.radiusFor(size) : Style.cornerRadius
  }

  // --- what the single capture view needs, passed through ---------------------------
  function isRecorded(label) { return legacyLoader.item ? legacyLoader.item.isRecorded(label) : false }
  function isCapturedNow(label) { return legacyLoader.item ? legacyLoader.item.isCapturedNow(label) : false }
  function appearanceMark(label) { return legacyLoader.item ? legacyLoader.item.appearanceMark(label) : "" }
  function actionText() { return legacyLoader.item ? legacyLoader.item.actionText() : "" }
  function actionNote() { return legacyLoader.item ? legacyLoader.item.actionNote() : "" }

  implicitHeight: view.legacy ? (legacyLoader.item ? legacyLoader.item.implicitHeight : 0) : dotCard.implicitHeight

  // Space: one press of the dot scan, when the card is showing it.
  function capture() { if (!view.legacy) dotCard.capture() }

  // Return: Start, Save or Done, whichever the view is offering.
  function activate() {
    if (!view.session) return
    if (view.legacy) { if (legacyLoader.item) legacyLoader.item.activate(); return }
    dotCard.activate()
  }

  // --- the preview, shared with the single capture view --------------------------------
  // What goes in the circle while `previewOn`. A property so that a test can put a
  // counting stand-in there and count how many cameras there would have been:
  // nothing in a test may open the real one.
  property Component previewComponent: defaultPreview
  Component {
    id: defaultPreview
    Loader {
      source: "RecordPreview.qml"
      onLoaded: if (item) item.device = view.previewDevice
    }
  }

  // --- the single capture view (old helper, or a session that is not the scan) -------
  Loader {
    id: legacyLoader
    anchors.fill: parent
    active: view.legacy
    visible: view.legacy
    sourceComponent: Component {
      RecordView {
        session: view.session
        fontFamily: view.fontFamily
        hasPreview: view.previewDevice !== ""
        previewComponent: view.previewComponent
        previewOn: view.previewOn
        appearanceLabels: view.appearanceLabels
        recordedAppearances: view.recordedAppearances
        notice: view.notice
        foreground: view.fg
        dim: view.secondary
        urgent: view.urgent
        accent: view.accent
        radiusSource: view.colors
        onCloseRequested: view.closeRequested()
      }
    }
  }

  // --- the dot scan -----------------------------------------------------------------------
  DotCard {
    id: dotCard
    objectName: "dotCard"
    visible: !view.legacy
    width: view.width
    session: view.session
    fg: view.fg
    secondary: view.secondary
    accent: view.accent
    urgent: view.urgent
    fontFamily: view.fontFamily
    reduced: view.reduced
    live: view.live
    notice: view.notice
    previewShown: previewLoader.active && !view.legacy
    onCloseRequested: view.closeRequested()
  }

  // The RGB preview, mirrored, in the stage's circle. The Loader exists, and so does the camera,
  // only while `previewOn` and a device is named.
  Loader {
    id: previewLoader
    objectName: "previewLoader"
    parent: dotCard.circle
    anchors.centerIn: parent
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0
    scale: 1 / Math.min(view.irCrop.w, view.irCrop.h)
    active: view.previewOn && view.previewDevice !== "" && !view.legacy
    sourceComponent: view.previewComponent
  }
}
