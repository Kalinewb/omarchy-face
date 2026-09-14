import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

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

  Component.onCompleted: Qt.callLater(function () { keys.forceActiveFocus() })

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
    Rectangle {
      id: panel
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(44)
      width: Math.min(parent.width - Style.space(40), Style.space(420))
      implicitHeight: content.implicitHeight + Style.space(28)
      radius: Style.cornerRadius
      color: Qt.rgba(0, 0, 0, 0.55)
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.18)

      // The card is its own surface: a click on it must not reach the scrim.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: content
        anchors.centerIn: parent
        width: parent.width - Style.space(28)
        spacing: Style.space(10)

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
              text: String(modelData)
              selected: card.session && card.session.appearance === String(modelData)
              foreground: card.onScrim
              fontFamily: card.fontFamily
              onClicked: if (card.session) card.session.appearance = String(modelData)
            }
          }
        }

        // --- the buttons ------------------------------------------------------

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(10)

          Button {
            visible: card.phase === "framing"
            text: "Start"
            bordered: true
            foreground: card.onScrim
            fontFamily: card.fontFamily
            onClicked: card.session.start()
          }

          Button {
            // Again is another capture in the SAME session, so it draws no
            // second password prompt (plan-merged.md §1 row 4).
            visible: card.phase === "verdict"
            text: "Again"
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
      }
    }
  }
}
