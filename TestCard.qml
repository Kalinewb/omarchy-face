import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "common/spring.js" as Spring

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

  // Something that matters more is using this piece of screen: a `sudo` asking
  // for root, drawn by the indicator. This card is about a test nobody's
  // security depends on, so it gets out of the way rather than drawing over the
  // one card a person needs to be able to read (Indicator.qml). The check
  // carries on underneath; only the window goes.
  property bool standDown: false

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
    if (card.code === 3) return "Face ID cannot check right now"
    // Anything else is the helper not having run at all -- 126/127 from the
    // launcher, or a code this version does not know. It is not an answer about
    // a person, so it never reads like one.
    return "Face ID cannot check right now"
  }

  readonly property bool good: card.phase === "done" && card.code === 0
  readonly property bool bad: card.phase === "done" && card.code === 1

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  visible: !card.standDown
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omarchy-face-test"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  // Only the card takes clicks; everything else on the screen is untouched.
  mask: Region { item: panel }

  // Grown, not appeared -- the same entrance the indicator uses, on the same
  // curve from common/spring.js. Height first over 350 ms, width from 50 ms
  // over 300 ms, so both land together. Nothing here animates the window's
  // position, opacity or scale: the bar's top edge is on the screen's top
  // edge at every frame including the first, and only its height and width
  // move (post-ship revision).
  property real heightP: 0
  property real widthP: 0
  readonly property var springCurve: Spring.curve(0.72, 0.6, 8)

  Component.onCompleted: enterAnim.start()

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

  // The same shape as the indicator, for the reason the palette was already
  // the same: this card appears in the same place, for the same kind of
  // moment, and the two should not look like different programs. That was
  // written when both were floating rounded panels 44px below the edge; the
  // indicator became a bar fused to the top edge and this did not follow it
  // (post-ship revision, found via live use). Island.qml draws it: flush top,
  // square top corners, an ordinary convex radius on the bottom two, and the
  // two concave background fillets that fuse the sides to the screen edge.
  Island {
    id: panel
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: 0

    readonly property real fullWidth: Math.min(parent.width - Style.space(40), Style.space(300))
    readonly property real fullHeight: content.implicitHeight + Style.space(28)
    // Fixed, never the bar's animated width: a Text that re-wraps mid-grow
    // reflows the whole column and changes the height it is being measured
    // for. The indicator solves it the same way and says so.
    readonly property real contentWidth: fullWidth - Style.space(28)

    // The seed the bar grows from, as fractions of the settled size. Not
    // zero, so the first frame is already a bar with fillets on it rather
    // than nothing.
    readonly property real seedWidthFraction: 0.4
    readonly property real seedHeightFraction: 0.2
    barWidth: Math.max(0, fullWidth * (seedWidthFraction
                + (1 - seedWidthFraction) * card.widthP))
    barHeight: Math.max(0, fullHeight * (seedHeightFraction
                + (1 - seedHeightFraction) * card.heightP))

    // An absolute radius rather than the indicator's fifth-of-the-height:
    // that rule was chosen for a card about as tall as it is wide, and this
    // one is neither. 25 is what the indicator's rule settles at, so the two
    // read as the same material. Island clamps it while the bar is still
    // shorter than the radius, which rounds the bottom fully at the start of
    // the grow and straightens it out as the bar arrives.
    bottomRadius: Style.space(25)
    filletRadius: Style.space(10) * barHeight / fullHeight
    color: "#000000"

    Column {
      id: content
      anchors.centerIn: parent
      width: panel.contentWidth
      spacing: Style.space(8)

      // Only once the bar is mostly there, so nothing is read half-clipped
      // inside a bar still growing around it. The bar itself never fades:
      // this is the text, not the card.
      opacity: Math.max(0, Math.min(1, (Math.min(card.heightP, card.widthP) - 0.7) / 0.3))

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
