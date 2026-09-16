import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
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
// Every decision about the session is in RecordSession.qml; this file is what
// that state machine looks like.
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

  // Which of them this person already has a recording for, from people.json
  // (the service reads it; see Service.qml). Without it the picker offers three
  // identical-looking options and the button says the same word whichever is
  // chosen, so somebody recording a second appearance cannot tell whether they
  // are adding one or replacing the one they already took -- which is what
  // happened in use (post-ship revision, plan-gui.md §5.3).
  property var recordedAppearances: []

  // A store keeps ONE recording per appearance: `enroll-session`'s `done` drops
  // every appearance with the label it is about to write before appending the
  // new one (omarchy-face-admin). So recording an appearance a second time
  // replaces that appearance, and never adds a fourth to the three.
  // `length` and an index, not Array.isArray() and indexOf(): this list arrives
  // through a QML property binding, and a list that has been through a QVariant
  // answers false to Array.isArray() while its length is perfectly good. That
  // exact guard is what made the People view say "0 appearances" about
  // everybody (PeopleView.qml), and it will not be repeated here.
  function isRecorded(label) {
    var list = card.recordedAppearances
    if (!list || list.length === undefined) return false
    for (var i = 0; i < list.length; i++)
      if (String(list[i]) === String(label)) return true
    return false
  }

  function isCapturedNow(label) {
    return !!card.session && card.session.hasCaptured(String(label))
  }

  // ✓ saved · ● taken in this session, not written yet · · nothing yet. The same
  // three marks the build's step list uses, for the same reason: a colour alone
  // is a theme's business, and these have to survive a monochrome one.
  function appearanceMark(label) {
    if (card.isCapturedNow(label)) return "●"
    if (card.isRecorded(label)) return "✓"
    return "·"
  }

  // What pressing the button will do TO THE APPEARANCE THE PICKER IS ON. It is
  // not a description of the session: "Again" after a capture of "No glasses"
  // is a lie the moment the picker is moved to an appearance that has never
  // been recorded.
  function actionText() {
    var label = card.session ? String(card.session.appearance) : ""
    if (card.session && card.phase === "verdict" && card.session.verdict === "failed"
        && label === String(card.session.lastAttempt))
      return "Try again"
    if (card.isCapturedNow(label)) return "Again"
    if (card.isRecorded(label)) return "Record again"
    return "Start"
  }

  // The sentence under the picker. Every branch names the appearance, because
  // the whole confusion this answers was about WHICH one a button applied to.
  function actionNote() {
    var label = card.session ? String(card.session.appearance) : ""
    if (label === "") return ""
    if (card.isCapturedNow(label))
      return label + " was taken just now — recording it again replaces what you took, "
             + "and nothing is written until you finish."
    if (card.isRecorded(label))
      return label + " is already recorded — recording it again replaces it. "
             + "A person keeps one recording per appearance."
    return label + " is not recorded yet."
  }

  // Something asked for root while this card was up. The indicator stands down
  // for this card (it would be two cards in one place), so its line arrives here
  // instead: a person staring into the lens for a countdown must not be the one
  // person who never hears that a sudo happened (Indicator.qml).
  property string notice: ""

  signal closed()

  readonly property color onScrim: "white"
  readonly property color onScrimDim: Qt.rgba(1, 1, 1, 0.6)
  readonly property color onScrimUrgent: "#ff6b6b"

  readonly property string phase: session ? session.phase : "framing"

  function requestClose() {
    if (!session) { card.closed(); return }
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
    Keys.onReturnPressed: {
      if (card.phase === "framing") card.session.start()
      else if (card.phase === "verdict") card.session.done()
    }

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
      readonly property real fullHeight: content.implicitHeight + Style.space(28)
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

      Column {
        id: content
        anchors.centerIn: parent
        width: panel.contentWidth
        spacing: Style.space(10)

        // Only once the bar is mostly grown, so the preview and the picker are
        // never seen half-clipped inside a bar still arriving. The bar itself
        // never fades; this is what is in it.
        opacity: Math.max(0, Math.min(1, (Math.min(card.heightP, card.widthP) - 0.7) / 0.3))

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: (card.session ? card.session.who() : "") +
                (card.session && card.session.appearance !== ""
                 ? " — " + card.session.appearance : "")
          color: card.onScrim
          font.family: card.fontFamily
          font.pixelSize: Style.font.subtitle
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }

        // --- the preview -----------------------------------------------------
        //
        // The RGB camera, mirrored, with an oval guide over it. It is a preview
        // and nothing else: the IR sensor is what records, and it is opened only
        // on `capture`. QtMultimedia is loaded through a Loader so a machine
        // whose Qt has no multimedia module falls back to the plain oval rather
        // than failing to load this file at all.

        Item {
          width: parent.width
          height: Style.space(200)

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: Qt.rgba(1, 1, 1, 0.05)
            clip: true

            Loader {
              id: preview
              anchors.fill: parent
              active: card.previewDevice !== ""
              source: "RecordPreview.qml"
              onLoaded: if (item) item.device = card.previewDevice
            }
          }

          // The oval guide, drawn over whatever the preview managed.
          Rectangle {
            anchors.centerIn: parent
            width: parent.height * 0.62
            height: parent.height * 0.82
            radius: width
            color: "transparent"
            border.width: 2
            border.color: card.phase === "capturing" ? Color.accent : Qt.rgba(1, 1, 1, 0.45)
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            visible: card.previewDevice === "" || preview.status === Loader.Error
            text: "No preview on this laptop — centre your face under the camera"
            color: card.onScrimDim
            font.family: card.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          // The countdown, over the oval, big enough to read from where a face
          // has to be.
          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: card.phase === "countdown"
            text: card.session ? String(card.session.countdown) : ""
            color: card.onScrim
            font.family: card.fontFamily
            font.pixelSize: Style.font.display * 2
          }
        }

        // --- what is happening ------------------------------------------------

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: {
            if (!card.session) return ""
            if (card.phase === "authorising") return "Waiting for authorisation…"
            if (card.phase === "countdown") return "Look at the camera"
            if (card.phase === "capturing") return "Hold still"
            if (card.phase === "verdict") return card.session.verdictText()
            if (card.phase === "closing") return "Saving…"
            return "Look at the camera and press Start."
          }
          color: card.phase === "verdict" && card.session && card.session.verdict === "failed"
                 ? card.onScrimUrgent : card.onScrim
          font.family: card.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: card.session && card.session.message !== ""
          text: card.session ? card.session.message : ""
          color: card.onScrimUrgent
          font.family: card.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }

        // --- the appearance picker -------------------------------------------
        //
        // Only while nothing is running or between captures: changing which
        // appearance is being recorded mid-capture would mislabel the encoding
        // that is already on its way back.

        Flow {
          width: parent.width
          spacing: Style.space(6)
          visible: card.phase === "framing" || card.phase === "verdict"

          Repeater {
            model: card.appearanceLabels

            Button {
              required property var modelData
              // The mark is in the label rather than beside it: this kit's
              // Button draws one string, and a second Text next to it would not
              // move with the button it belongs to.
              text: card.appearanceMark(String(modelData)) + "  " + String(modelData)
              selected: card.session && card.session.appearance === String(modelData)
              foreground: card.isRecorded(String(modelData)) || card.isCapturedNow(String(modelData))
                          ? card.onScrim : card.onScrimDim
              fontFamily: card.fontFamily
              onClicked: if (card.session) card.session.appearance = String(modelData)
            }
          }
        }

        // What the marks mean, and what the button below is about to do. Two
        // short lines rather than a tooltip: the person reading them is looking
        // into a camera lens from arm's length.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: card.phase === "framing" || card.phase === "verdict"
          text: "✓ recorded   ●  taken just now   ·  not recorded"
          color: card.onScrimDim
          font.family: card.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: (card.phase === "framing" || card.phase === "verdict") && text !== ""
          text: card.actionNote()
          color: card.onScrimDim
          font.family: card.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }

        // --- the buttons ------------------------------------------------------

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(10)

          Button {
            visible: card.phase === "framing"
            // "Start" for an appearance with nothing behind it, "Record again"
            // for one that already has a recording this would replace.
            text: card.actionText()
            bordered: true
            foreground: card.onScrim
            fontFamily: card.fontFamily
            onClicked: card.session.start()
          }

          Button {
            // Another capture in the SAME session, so it draws no second
            // password prompt (plan-merged.md §1 row 4). The word depends on
            // where the picker is: "Again" only re-takes something this session
            // already has.
            visible: card.phase === "verdict"
            text: card.actionText()
            bordered: card.session && card.session.verdict !== "good"
            foreground: card.onScrim
            fontFamily: card.fontFamily
            onClicked: card.session.again()
          }

          Button {
            visible: card.phase === "verdict" && card.session && card.session.captures > 0
            text: "Done"
            bordered: card.session && card.session.verdict === "good"
            foreground: card.onScrim
            fontFamily: card.fontFamily
            onClicked: card.session.done()
          }

          Button {
            visible: card.phase === "framing" || card.phase === "verdict" || card.phase === "authorising"
            text: card.session && card.session.captures > 0 ? "Close" : "Cancel"
            foreground: card.onScrimDim
            fontFamily: card.fontFamily
            onClicked: card.requestClose()
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: card.session && card.session.captures > 0
                ? "Closing keeps what you recorded." : "esc closes · nothing is saved until you finish"
          color: card.onScrimDim
          font.family: card.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }

        // Not an error and not part of the session: something else asked for
        // root while this was open, and this is the only surface that can say so.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: card.notice !== ""
          text: card.notice
          color: Color.accent
          font.family: card.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
