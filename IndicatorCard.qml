import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "common"

// What the indicator draws (Indicator.qml owns the window, the timers and the entrance): the notch's
// silhouette (Island.qml) with the face glyph, one short line under it, and a second, quieter one only
// when there is something to say (the command that asked for root, who is asking). It is the same card
// as the dot scan's and the Test card's: white on true black, the same type sizes, the same glyph
// (common/FaceGlyph.qml), the accent only for a check and the urgent colour only for a refusal.
//
// No window here, so a test can draw it (dev/g5-indicator-offscreen.sh) without a compositor.
Island {
  id: card

  // "start" | "matched" | "failed", as the state file says it
  property string authState: "start"
  property string headline: ""
  property string detail: ""
  property bool reduced: false

  // How far the bar has grown (Indicator.qml's heightP / widthP; the seed fractions and the shape
  // proportions are its too, passed in so there is one place for them)
  property real heightP: 1
  property real widthP: 1
  property real seedHeightFraction: 0.2
  property real seedWidthFraction: 0.4
  property real bottomRadiusFraction: 0.2
  property real filletFull: 10

  // The card's palette: white on its black surface and the kit's accent and urgent (cf. RecordCard.qml)
  readonly property color fg: "white"
  readonly property color secondary: Qt.darker("white", 1.55)
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property bool failed: card.authState === "failed"

  // A little wider than tall: 300 wide read as a banner and a square as cramped (post-ship revision).
  // The content's width comes from a token and never from the height, because a wrapped Text's height
  // depends on its width.
  readonly property real contentWidth: Style.space(144)
  readonly property real minContentHeight: Style.space(116)
  readonly property real fullWidth: Math.min(parent ? parent.width - Style.space(40) : 0, contentWidth + Style.space(28))
  readonly property real fullHeight: Math.max(content.implicitHeight, minContentHeight) + Style.space(28)

  // Neither is clamped at 1: the spring's overshoot past the settled size is meant to show. Clamped at
  // zero size only, for the tail of the exit.
  barWidth: Math.max(0, fullWidth * (seedWidthFraction + (1 - seedWidthFraction) * widthP))
  barHeight: Math.max(0, fullHeight * (seedHeightFraction + (1 - seedHeightFraction) * heightP))
  bottomRadius: bottomRadiusFraction * barHeight
  filletRadius: filletFull * barHeight / fullHeight
  color: "#000000"

  // Sized for the bar's settled dimensions so its own text never reflows mid-animation, and shown only
  // once the bar is mostly grown (the bar itself never fades).
  Column {
    id: content
    anchors.centerIn: parent
    width: card.contentWidth
    spacing: Style.space(8)

    readonly property real settleP:
      Math.max(0, Math.min(1, (Math.min(card.heightP, card.widthP) - 0.7) / 0.3))
    opacity: settleP

    FaceGlyph {
      objectName: "indicatorGlyph"
      anchors.horizontalCenter: parent.horizontalCenter
      size: Style.space(56)
      look: card.authState === "matched" ? "success" : card.failed ? "failure" : "scanning"
      fg: card.fg
      secondary: card.secondary
      accent: card.accent
      urgent: card.urgent
      reduced: card.reduced
    }

    // The line: what is happening or what happened, in the same weight as the dot scan's line
    Text {
      objectName: "indicatorLine"
      textFormat: Text.PlainText
      width: parent.width
      text: card.headline
      color: card.failed ? card.urgent : card.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.weight: Font.DemiBold
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      Accessible.role: Accessible.StaticText
      Accessible.name: text
    }

    // Only when there is something to say. Two lines before eliding: "sudo · pacman, from foot" does
    // not fit one line of a card this size, and the program's name is the part worth keeping whole.
    Text {
      objectName: "indicatorDetail"
      textFormat: Text.PlainText
      width: parent.width
      visible: card.detail !== ""
      text: card.detail
      color: card.secondary
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
      Accessible.role: Accessible.StaticText
      Accessible.name: text
    }
  }
}
