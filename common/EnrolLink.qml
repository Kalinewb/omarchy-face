import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A text link of the enrol view: the kit's Button with no fill, in `accent`
// (interactive only), a hit target of at least 32 px, in Tab order with the
// kit's focus border, and a button to a screen reader. Return and Space press it.
Button {
  id: link

  property bool quiet: false
  property color accentColor: Commons.Color.accent
  property color quietColor: Qt.darker(Commons.Color.foreground, 1.55)

  focusable: true
  foreground: quiet ? quietColor : accentColor
  fontSize: Style.font.body
  verticalPadding: Style.space(7)
  horizontalPadding: Style.space(14)
  implicitHeight: Math.max(Style.space(32), contentHeight)
  readonly property real contentHeight: fontSize * 1.4 + verticalPadding * 2

  Accessible.role: Accessible.Button
  Accessible.name: link.text
  Accessible.focusable: true
  Accessible.onPressAction: link.clicked()
}
