import QtQuick
import QtQuick.Shapes
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "common"
import "common/enrolring.js" as Ring

// The enrol screen (plan-face-enroll.md section 3): the ring around the live
// circle, the line, the links. RecordCard.qml puts it in its window under the
// camera, in every home: a scan is never drawn inside the notch (Start brings up
// polkit's password dialog, which takes the focus the notch needs to stay open;
// the Phase 4 live gate, doubt 11). It draws no window, no background and no
// container animation, and it takes its look from `colors` (foreground,
// secondary, accent, urgent, fontFamily, radiusFor, reducedMotion), the card's.
//
// Everything about the scan is RecordSession.qml's (the state machine) and the
// engine's (what is reached, filled, skipped); this file is what that looks like.
// A session that is not the scan, or one on a helper older than 3.1.0, gets the
// single-capture view it always had (RecordView.qml), drawn inside this one.
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
  readonly property string mode: view.session ? view.session.activeMode : "simple"

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

  // Return: Start, Done, or Try again, whichever the view is offering.
  function activate() {
    if (!view.session) return
    if (view.legacy) { if (legacyLoader.item) legacyLoader.item.activate(); return }
    var s = view.session
    if (view.phase === "idle") s.start()
    else if (s.scanState === "swept") s.done()
    else if (view.phase === "verdict") s.tryAgain()
    else if (s.scanState === "running" && s.canFinish) s.finish()
  }

  implicitHeight: view.legacy ? (legacyLoader.item ? legacyLoader.item.implicitHeight : 0) : col.implicitHeight

  // --- the line (section 3, Text and the outcome list) ----------------------------
  property bool skipNote: false

  readonly property var gateText: ({
    "over": "A little less",
    "edge": "Centre your face",
    "closer": "A little closer",
    "farther": "A little farther",
    "multiple": "Only you, please",
    "dark": "Too dark here",
    "other": "Face the circle and hold still."
  })

  function prompt(bin) {
    if (bin === 9) return "Turn your head to the left"
    if (bin === 3) return "Turn your head to the right"
    if (bin === 0) return "Tilt your head up"
    if (bin === 6) return "Tilt your head down"
    return "Move your head slowly to complete the circle."
  }

  function lineText() {
    var s = view.session
    if (!s) return ""
    if (s.discarding) return "Nothing was saved"
    var ph = s.phase
    if (ph === "idle") return "Fit your face in the circle."
    if (ph === "authorising") return "Waiting for authorisation…"
    if (ph === "closing") return "Saving…"
    if (ph === "verdict") return s.failText[s.failCode] !== undefined ? s.failText[s.failCode] : "That did not work"
    if (s.scanState === "swept") {
      if (s.activeMode === "advanced")
        return s.filled.length >= 12 ? "The circle is complete." : "All set."
      return s.kept >= 4 ? "All set." : "Enough to save. Start over for more."
    }
    if (view.gateText[s.trackState] !== undefined) return view.gateText[s.trackState]
    if (view.skipNote) return "We will skip that one"
    if (ph === "centre") return s.centre > 0 ? "Hold still" : "Look straight at the circle"
    var bin = s.target
    var held = typeof bin === "number" && Number(s.bins[bin]) > 0
    if (s.activeMode === "advanced") {
      if (Ring.filledCount(Ring.targetsFor("advanced"), s.bins) >= 12) return "The circle is complete."
      return held ? "Hold still" : "Move your head slowly to complete the circle."
    }
    if (typeof bin !== "number") return "Hold still"
    return held ? "Hold still" : view.prompt(bin)
  }

  readonly property string line: view.lineText()

  Connections {
    target: view.session
    function onSkippedChanged() {
      if (view.session && view.session.skipped.length > view.lastSkipped) {
        view.skipNote = true
        skipTimer.restart()
      }
      view.lastSkipped = view.session ? view.session.skipped.length : 0
    }
  }
  property int lastSkipped: 0
  Timer { id: skipTimer; interval: 2500; onTriggered: view.skipNote = false }

  // The circle shakes on the outcomes that shake (the outcome list): +6, -6, +3, 0.
  property real shakeX: 0
  SequentialAnimation {
    id: shake
    NumberAnimation { target: view; property: "shakeX"; to: 6; duration: 50 }
    NumberAnimation { target: view; property: "shakeX"; to: -6; duration: 50 }
    NumberAnimation { target: view; property: "shakeX"; to: 3; duration: 50 }
    NumberAnimation { target: view; property: "shakeX"; to: 0; duration: 50 }
  }
  Connections {
    target: view.session
    function onFailSerialChanged() { if (!view.reduced && !view.legacy) shake.restart() }
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

  // --- the scan ---------------------------------------------------------------------
  // The idle demo (EnrolDemo.qml) plays only while the card is idle, on screen and
  // motion is allowed; Start stops it, and with reduced motion there is the static
  // glyph and one caption line instead.
  readonly property bool demoOn: view.phase === "idle" && !view.legacy && !view.reduced && view.live
  readonly property string staticCaption: view.mode === "advanced" ? "Then turn slowly all the way round."
                                                                   : "Then turn left, right, up and down."

  Column {
    id: col
    visible: !view.legacy
    width: view.width
    spacing: Style.space(8)

    Item {
      width: parent.width
      height: Style.space(32)

      EnrolLink {
        id: cancelLink
        objectName: "cancelLink"
        anchors.left: parent.left
        text: "Cancel"
        quiet: true
        quietColor: view.secondary
        accentColor: view.accent
        fontFamily: view.fontFamily
        visible: view.phase !== "closing"
        // Esc and Cancel are one verb: the session decides.
        onClicked: view.closeRequested()
      }
    }

    Item {
      width: parent.width
      height: ring.implicitHeight
      transform: Translate { x: view.shakeX }

      EnrolRing {
        id: ring
        objectName: "ring"
        anchors.horizontalCenter: parent.horizontalCenter
        mode: view.mode
        targets: Ring.targetsFor(view.mode)
        target: view.demoOn ? demo.target : (view.session && ring.active ? view.session.target : null)
        centre: view.session ? view.session.centre : 0
        bins: view.demoOn ? demo.bins : (view.session ? view.session.bins : [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        demo: view.demoOn
        demoCentre: demo.centre
        skipped: view.session ? view.session.skipped : []
        canFinish: view.session ? view.session.canFinish : false
        u: view.session ? view.session.u : 0
        v: view.session ? view.session.v : 0
        phase: view.phase
        message: view.line
        colors: ({ foreground: view.fg, secondary: view.secondary, accent: view.accent })
        scanning: !!view.session && view.session.trackState === view.session.acceptedWord
        scans: view.session ? view.session.acceptedFrames : 0
        reducedMotion: view.reduced
        masked: previewLoader.active

        // The face glyph in its dotted ring, and nothing live: no camera object.
        Text {
          id: glyph
          objectName: "glyph"
          anchors.centerIn: parent
          visible: !previewLoader.active && !view.demoOn && !(view.session && view.session.scanState === "swept")
          textFormat: Text.PlainText
          text: "\u{f0643}"
          color: view.secondary
          opacity: 0.3
          font.family: view.fontFamily
          font.pixelSize: 80
        }

        // What the scan will ask, played while idle (no camera).
        EnrolDemo {
          id: demo
          objectName: "demo"
          anchors.fill: parent
          visible: view.demoOn
          mode: view.mode
          running: view.demoOn
          foreground: view.fg
          secondary: view.secondary
        }

        // The RGB preview, mirrored, in the circle. The Loader exists, and so
        // does the camera, only while `previewOn` and a device is named.
        Loader {
          id: previewLoader
          objectName: "previewLoader"
          anchors.centerIn: parent
          width: parent.width
          height: parent.height
          scale: 1 / Math.min(view.irCrop.w, view.irCrop.h)
          active: view.previewOn && view.previewDevice !== "" && !view.legacy
          sourceComponent: view.previewComponent
        }

        // Completion draws a check in 180 ms; there is no celebration.
        Item {
          id: checkBox
          objectName: "check"
          anchors.centerIn: parent
          width: 44
          height: 44
          // The check is drawn along its path in 180 ms (no celebration spring).
          property real drawn: view.session && view.session.scanState === "swept" ? 1 : 0
          Behavior on drawn { enabled: !view.reduced; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
          readonly property real first: Math.min(1, drawn * 43.1 / 14.1)
          readonly property real second: Math.max(0, Math.min(1, (drawn * 43.1 - 14.1) / 29))
          visible: drawn > 0
          Shape {
            width: 44; height: 44
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
              strokeColor: view.accent
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
    }

    Text {
      id: lineLabel
      objectName: "line"
      textFormat: Text.PlainText
      width: parent.width
      text: view.line
      color: view.fg
      font.family: view.fontFamily
      font.pixelSize: Style.font.body
      font.weight: Font.DemiBold
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
      Accessible.role: Accessible.StaticText
      Accessible.name: lineLabel.text
      opacity: 1
    }

    // One short caption under it while idle: the demo's step ("Turn your head to the
    // left"), or with reduced motion a single static line. Its height is always
    // reserved, so the island does not change size when Start removes it.
    Text {
      id: captionLabel
      objectName: "caption"
      textFormat: Text.PlainText
      width: parent.width
      height: Style.font.caption * 1.6
      text: view.demoOn ? demo.caption : (view.phase === "idle" && !view.legacy && view.reduced ? view.staticCaption : "")
      color: view.secondary
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
      Accessible.role: Accessible.StaticText
      Accessible.name: captionLabel.text
    }

    // The quiet second line: a reason (Not authorised), an engine hint that does
    // not end the lap (A few more positions first), the old helper's note.
    Text {
      id: noteLabel
      objectName: "note"
      textFormat: Text.PlainText
      width: parent.width
      readonly property string words: !view.session ? ""
          : view.session.message !== "" ? view.session.message
          : view.session.notice !== "" ? view.session.notice
          : view.session.legacy ? view.session.legacyNote : ""
      visible: words !== ""
      text: words
      color: view.secondary
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      Accessible.role: Accessible.StaticText
      Accessible.name: noteLabel.text
    }

    // --- links: text only, accent, in Tab order -----------------------------------
    Column {
      id: links
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(2)

      readonly property bool scanLive: !!view.session && view.session.sweepFlow
      readonly property string scanState: view.session ? view.session.scanState : "ready"

      EnrolLink {
        id: startLink
        objectName: "startLink"
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Start"
        accentColor: view.accent
        fontFamily: view.fontFamily
        visible: view.phase === "idle"
        onClicked: view.session.start()
      }

      EnrolLink {
        id: doneLink
        objectName: "doneLink"
        anchors.horizontalCenter: parent.horizontalCenter
        // Advanced while the lap runs once the engine says so (it sends `finish`);
        // in both modes on `swept` (it sends `done` and ends the session). The
        // Simple view never sends `finish`.
        text: "Done"
        accentColor: view.accent
        fontFamily: view.fontFamily
        visible: links.scanLive && ((links.scanState === "swept")
                 || (links.scanState === "running" && view.mode === "advanced" && view.session.canFinish))
        onClicked: links.scanState === "swept" ? view.session.done() : view.session.finish()
      }

      EnrolLink {
        id: againLink
        objectName: "againLink"
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Try again"
        accentColor: view.accent
        fontFamily: view.fontFamily
        visible: view.phase === "verdict" && links.scanState === "ready"
        onClicked: view.session.tryAgain()
      }

      EnrolLink {
        id: overLink
        objectName: "overLink"
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Start over"
        accentColor: view.accent
        fontFamily: view.fontFamily
        visible: links.scanLive && (view.phase === "centre" || view.phase === "lap1")
        onClicked: view.session.startOver()
      }

      // The mode: the quietest line, in `idle` only, naming the OTHER mode, so it
      // shows what pressing it does while the ring already shows which is on.
      EnrolLink {
        id: modeLink
        objectName: "modeLink"
        anchors.horizontalCenter: parent.horizontalCenter
        text: view.mode === "simple" ? "Advanced" : "Simple setup"
        quiet: true
        quietColor: view.secondary
        fontFamily: view.fontFamily
        fontSize: Style.font.caption
        visible: view.phase === "idle" && !!view.session && view.session.simpleAllowed
        onClicked: view.session.setMode(view.mode === "simple" ? "advanced" : "simple")
      }

      // One line, pulled by hover or keyboard focus (explanation is pulled).
      Text {
        id: modeHint
      objectName: "modeHint"
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        visible: modeLink.visible
        opacity: modeLink.hot || modeLink.activeFocus ? 1 : 0
        text: view.mode === "simple" ? "All twelve positions in any order"
                                     : "Five positions, one at a time, about 15 seconds"
        color: view.secondary
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        Behavior on opacity { NumberAnimation { duration: view.reduced ? 0 : 90 } }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: view.notice !== ""
      text: view.notice
      color: view.accent
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }
  }
}
