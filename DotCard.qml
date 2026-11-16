import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "common"
import "common/dotscan.js" as Dot

// The dot scan's card (3.2.0), the scan's face since 3.3.0 removed the Advanced one: the camera's circle, the line, the Space key, the links. The ball
// is not on this card (3.2.1): it is on the real screen, in BallLayer.qml, so the person turns towards the screen's edges.
// It decides nothing. RecordSession.qml holds what the scan is doing (which pose the ball waits
// for, whether a press is running, how many frames the helper has gathered, why the last one did
// not work) and the helper decides whether a face is good; this file is what that looks like.
// EnrolView.qml puts it in the card and puts the camera's picture in `circle` (it is the only file
// that names the RGB camera).
//
// Every row has a fixed height, shown or not, so the island does not change size from one state
// to the next. What is on it, and why, is in the plan's audit-dot-scan.md.
Item {
  id: card

  property var session: null
  // foreground, secondary, accent, urgent (colours), the card's reduced-motion flag
  property color fg: Commons.Color.foreground
  property color secondary: Qt.darker(Commons.Color.foreground, 1.55)
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family
  property bool reduced: false
  // The card is on screen, so the idle demo may play
  property bool live: false
  property string notice: ""

  signal closeRequested()

  // The camera's picture goes in the circle (EnrolView puts it there); the glyph is what it holds
  // until there is one.
  readonly property alias circle: stage.circle
  property bool previewShown: false
  readonly property alias stage: stage

  readonly property string phase: card.session ? card.session.phase : "idle"
  readonly property string dotState: card.session ? card.session.dotState : "waiting"
  readonly property bool idle: card.phase === "idle"
  readonly property bool playing: card.phase === "dot"
  readonly property bool waiting: card.playing && card.dotState === "waiting"
  readonly property bool finished: card.playing && !!card.session && card.session.dotAllHeld && card.dotState === "done"
  // Save, before all five: the centre, left and right are held and the ball waits for the rest
  readonly property bool canSave: card.playing && !!card.session && card.session.dotCanSave && !card.finished
                                  && card.dotState === "waiting"
  readonly property bool demoOn: card.idle && !card.reduced && card.live

  implicitHeight: col.implicitHeight

  // --- what the line says ---------------------------------------------------------------------
  function lineText() {
    var s = card.session
    if (!s) return ""
    if (s.discarding) return "Nothing was saved"
    if (card.phase === "idle") return "Look at the ball, then press Space."
    if (card.phase === "authorising") return "Waiting for authorisation…"
    if (card.phase === "closing") return "Saving…"
    if (!card.playing) return ""
    if (card.dotState === "capturing") return "Hold still"
    if (card.finished || (card.dotState === "landed" && s.dotAllHeld)) return "All set."
    if (card.dotState === "landed") return "Got it"
    if (s.dotWhy !== "") return Dot.why(s.dotWhy, s.dotShort)
    return Dot.PROMPT[s.dotPose] !== undefined ? Dot.PROMPT[s.dotPose] : ""
  }
  readonly property string line: card.lineText()
  // A press that did not work is said in the urgent colour as well as in words
  readonly property bool failed: card.waiting && !!card.session && card.session.dotWhy !== ""

  function activate() {
    if (!card.session) return
    if (card.idle) card.session.start()
    else if (card.finished) card.session.done()
  }

  function capture() { if (card.session) card.session.capture() }

  Column {
    id: col
    width: card.width
    spacing: Style.space(6)

    // Cancel: always there, until the card is closing.
    Item {
      width: parent.width
      height: Style.space(32)

      EnrolLink {
        id: cancelLink
        objectName: "cancelLink"
        anchors.left: parent.left
        text: "Cancel"
        quiet: true
        quietColor: card.secondary
        accentColor: card.accent
        fontFamily: card.fontFamily
        visible: card.phase !== "closing"
        // Esc and Cancel are one verb: the session decides.
        onClicked: card.closeRequested()
      }
    }

    DotStage {
      id: stage
      objectName: "stage"
      anchors.horizontalCenter: parent.horizontalCenter
      ballState: card.playing ? card.dotState : "idle"
      summary: !card.playing || !card.session ? "The camera"
               : (card.session.dotAllHeld ? "All five pictures taken"
                  : Dot.count(card.session.dotHeld) + " of " + Dot.POSES.length + " pictures taken. "
                    + "Look at the ball on the screen: " + (Dot.PROMPT[card.session.dotPose] || ""))
      colors: ({ foreground: card.fg, secondary: card.secondary, accent: card.accent })
      reducedMotion: card.reduced
      masked: card.previewShown
      demo: card.demoOn
      demoFrame: demoLoader.item ? demoLoader.item.frame : null
    }

    // The line: what to do now, or why the last try did not work.
    Text {
      id: lineLabel
      objectName: "line"
      textFormat: Text.PlainText
      width: parent.width
      height: Style.font.body * 1.7
      text: card.line
      color: card.failed ? card.urgent : card.fg
      font.family: card.fontFamily
      font.pixelSize: Style.font.body
      font.weight: Font.DemiBold
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
      Accessible.role: Accessible.StaticText
      Accessible.name: lineLabel.text
    }

    // One slot under the line. Idle: the demo's step. While the ball waits: the Space key, shown as a
    // key and pressable, so it can be found without being told and used without a keyboard.
    Item {
      id: hintSlot
      width: parent.width
      height: Style.space(32)

      Text {
        id: captionLabel
        objectName: "caption"
        textFormat: Text.PlainText
        anchors.fill: parent
        text: card.demoOn ? (demoLoader.item ? demoLoader.item.caption : "")
                          : (card.idle && card.reduced ? "The ball moves left, up, right and down." : "")
        visible: card.idle
        color: card.secondary
        font.family: card.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        Accessible.role: Accessible.StaticText
        Accessible.name: captionLabel.text
      }

      Row {
        id: spaceHint
        objectName: "spaceHint"
        anchors.centerIn: parent
        spacing: Style.space(8)
        visible: card.playing
        opacity: card.waiting ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: card.reduced ? 0 : 120 } }

        Button {
          id: spaceKey
          objectName: "spaceKey"
          anchors.verticalCenter: parent.verticalCenter
          text: "Space"
          bordered: true
          focusable: true
          enabled: card.waiting
          foreground: card.fg
          accent: card.accent
          fontFamily: card.fontFamily
          fontSize: Style.font.bodySmall
          verticalPadding: Style.space(5)
          horizontalPadding: Style.space(16)
          implicitHeight: Math.max(Style.space(28), fontSize * 1.4 + verticalPadding * 2)
          Accessible.role: Accessible.Button
          Accessible.name: "Space: take the picture"
          Accessible.focusable: true
          Accessible.onPressAction: spaceKey.clicked()
          onClicked: card.capture()
          Connections {
            target: spaceKey
            function onClicked() { Qt.callLater(function () { spaceKey.focus = false }) }
          }
        }

        Text {
          objectName: "spaceHintText"
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: card.failed ? "to try again" : "to take the picture"
          color: card.secondary
          font.family: card.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    // The quiet second line: a reason that is not about the picture (Not authorised).
    Text {
      id: noteLabel
      objectName: "note"
      textFormat: Text.PlainText
      width: parent.width
      height: Style.font.caption * 1.6
      readonly property string words: !card.session ? "" : card.session.message
      text: words
      color: card.secondary
      font.family: card.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
      Accessible.role: Accessible.StaticText
      Accessible.name: noteLabel.text
    }

    // The one thing to do besides the key: Start, Save (before all five) or Done (after).
    Item {
      width: parent.width
      height: Style.space(32)

      EnrolLink {
        id: startLink
        objectName: "startLink"
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Start"
        accentColor: card.accent
        fontFamily: card.fontFamily
        visible: card.idle
        onClicked: card.session.start()
      }

      EnrolLink {
        id: saveLink
        objectName: "saveLink"
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Save"
        accentColor: card.accent
        fontFamily: card.fontFamily
        visible: card.canSave
        onClicked: card.session.done()
      }

      EnrolLink {
        id: doneLink
        objectName: "doneLink"
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Done"
        accentColor: card.accent
        fontFamily: card.fontFamily
        visible: card.finished
        onClicked: card.session.done()
      }
    }

    // Under it: "Scan again" once all five are held.
    Item {
      width: parent.width
      height: Style.space(32)

      EnrolLink {
        id: againLink
        objectName: "againLink"
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Scan again"
        quiet: true
        quietColor: card.secondary
        fontFamily: card.fontFamily
        fontSize: Style.font.caption
        visible: card.finished
        onClicked: card.session.startOver()
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: card.notice !== ""
      text: card.notice
      color: card.accent
      font.family: card.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }
  }

  // The face glyph (common/FaceGlyph.qml, the one the indicator and the Test card draw): what the circle
  // holds when nothing is live and no demo plays (reduced motion)
  FaceGlyph {
    id: glyph
    objectName: "glyph"
    parent: stage.circle
    anchors.centerIn: parent
    visible: !card.previewShown && !card.demoOn && !card.finished
    size: 64
    look: "idle"
    fg: card.fg
    secondary: card.secondary
    accent: card.accent
    urgent: card.urgent
    reduced: card.reduced
    opacity: 0.55
  }

  // The idle demo plays in the stage's circle only while the card is idle, on screen, with motion
  // allowed; Start stops it. Created only then (nothing costs anything while it is not running).
  Loader {
    id: demoLoader
    parent: stage.circle
    anchors.fill: parent
    active: card.demoOn
    sourceComponent: Component {
      EnrolDemo {
        objectName: "demo"
        running: card.demoOn
        headScale: 0.7
        foreground: card.fg
        secondary: card.secondary
      }
    }
  }
}
