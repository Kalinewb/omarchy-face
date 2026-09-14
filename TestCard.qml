import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The Test card (plan-gui.md §5.2): "does it recognise Anna now?" -- a small
// card under the webcam while `omarchy-face-identity verify <name>` runs, and
// then one sentence about what came back.
//
// It belongs to the Face service for the same reason the recording card does:
// it has to sit under the built-in camera, and the popup that started it is a
// bar popup that any write under ~/.config/omarchy/plugins destroys.
//
// Three deliberate differences from RecordCard.qml, all the same decision --
// **a test must not take over the machine**:
//
//   · no scrim. Nothing is being recorded and nothing is being authorised; the
//     person is checking a setting, and the popup they were reading stays
//     readable behind this.
//   · no keyboard focus (`None`). Taking exclusive focus would close the popup
//     underneath and swallow whatever was being typed elsewhere for the eight
//     seconds a check can take. Stop is a button, not an Esc key.
//   · the input region is the card itself, so every click outside it goes where
//     it would have gone.
//
// Everything it decides is in Service.qml; this file is what that looks like.
PanelWindow {
  id: card

  // Who is being looked for, in the words the person reads (the label, never
  // the slug).
  property string label: ""
  // "checking" while the helper runs, "done" once it has answered.
  property string phase: "checking"
  // The helper's exit code, as the Profiles contract defines it (§2.5):
  // 0 present · 1 not present · 2 bad or unknown name · 3 unavailable ·
  // 4 rate limited or camera busy. -1 means it could not be run at all.
  property int code: -1
  property string fontFamily: Style.font.family

  // Stop looking. The helper runs as the user, so this is a SIGTERM -- and that
  // is the same cancellation Profiles uses, which frees the camera within
  // 300 ms (plan-merged.md §2.5, common/Ask.qml's cancel()).
  signal stopped()
  signal closed()

  readonly property string who: card.label !== "" ? card.label : "them"

  // The copy of plan-gui.md §5.2, verbatim, as a property so a test can ask for
  // it without a screen.
  readonly property string headline: {
    if (card.phase !== "done") return "Look at the camera"
    if (card.code === 0) return "Recognised " + card.who
    if (card.code === 1) return "Did not recognise " + card.who
    if (card.code === 2) return card.who + " is not set up"
    if (card.code === 4) return "Checked too recently — try again in a moment"
    if (card.code === 3) return "Face Unlock cannot check right now"
    // Anything else is the helper not having run at all -- 126/127 from the
    // launcher, or a code this version does not know. It is not an answer about
    // a person, so it never reads like one.
    return "Face Unlock cannot check right now"
  }

  readonly property bool good: card.phase === "done" && card.code === 0
  readonly property bool bad: card.phase === "done" && card.code === 1

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omarchy-face-test"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  // Only the card takes clicks; everything else on the screen is untouched.
  mask: Region { item: panel }

  Rectangle {
    id: panel
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    // The same 44 as the indicator: under the lens, so reading the card points
    // the face at the camera.
    anchors.topMargin: Style.space(44)
    width: Math.min(parent.width - Style.space(40), Style.space(300))
    implicitHeight: content.implicitHeight + Style.space(28)
    height: implicitHeight
    radius: Style.cornerRadius
    // The indicator's palette: this card appears in the same place, for the
    // same kind of moment, and the two should not look like different programs.
    color: Qt.rgba(Color.polkit.background.r, Color.polkit.background.g,
                   Color.polkit.background.b, 1)
    border.width: 1
    border.color: Qt.rgba(Color.polkit.border.r, Color.polkit.border.g,
                          Color.polkit.border.b, 0.35)

    Column {
      id: content
      anchors.centerIn: parent
      width: parent.width - Style.space(28)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: card.good ? "✓" : card.bad ? "✕" : "\u{f0643}"
        color: card.bad ? Color.polkit.textError : Color.polkit.accent
        font.family: card.fontFamily
        font.pixelSize: Style.font.display * 1.4
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: card.headline
        color: card.bad ? Color.polkit.textError : Color.polkit.text
        font.family: card.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }

      // Said every time, because a test that says "Recognised Anna" and nothing
      // else invites the reading that something was unlocked. Nothing was.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: card.phase === "done"
              ? "Nothing was unlocked — this was only a test."
              : "Checking who is in front of the camera."
        color: Color.muted
        font.family: card.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(10)

        Button {
          visible: card.phase !== "done"
          text: "Stop"
          foreground: Color.polkit.text
          fontFamily: card.fontFamily
          onClicked: card.stopped()
        }

        Button {
          visible: card.phase === "done"
          text: "Close"
          bordered: true
          foreground: Color.polkit.text
          fontFamily: card.fontFamily
          onClicked: card.closed()
        }
      }
    }
  }
}
