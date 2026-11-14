import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Simple or Advanced, as two choices side by side with the one in use filled: it shows which is
// on and that the other can be chosen (3.2.0; the 3.1.x link named only the OTHER mode, quietly).
// It is offered while the card is idle and nowhere else, so what it shows is what Start will do.
// Hover or keyboard focus says in one line what each one is; a click leaves no outline behind
// (the choice is made, not held), and Tab still shows where the keyboard is.
Row {
  id: choice

  // "simple" | "advanced"
  property string mode: "simple"
  property color accentColor: Commons.Color.accent
  property color quietColor: Qt.darker(Commons.Color.foreground, 1.55)
  property color foregroundColor: Commons.Color.foreground
  property string fontFamily: Style.font.family

  signal chosen(string word)

  spacing: Style.space(6)

  Repeater {
    model: [
      { word: "simple", label: "Simple", hint: "Five quick pictures" },
      { word: "advanced", label: "Advanced", hint: "Turn slowly all the way round, about 15 seconds" }
    ]

    Button {
      id: option
      required property var modelData
      objectName: "mode-" + modelData.word
      text: modelData.label
      tooltipText: modelData.hint
      selected: choice.mode === modelData.word
      bordered: true
      focusable: true
      foreground: selected ? choice.foregroundColor : choice.quietColor
      accent: choice.accentColor
      fontFamily: choice.fontFamily
      fontSize: Style.font.bodySmall
      verticalPadding: Style.space(6)
      horizontalPadding: Style.space(14)
      implicitHeight: Math.max(Style.space(32), fontSize * 1.4 + verticalPadding * 2)

      Accessible.role: Accessible.RadioButton
      Accessible.name: modelData.label
      Accessible.description: modelData.hint
      Accessible.checked: selected
      Accessible.focusable: true
      Accessible.onPressAction: option.clicked()

      onClicked: choice.chosen(modelData.word)

      // The outline belongs to the keyboard: after a click, focus goes back to the card.
      Connections {
        target: option
        function onClicked() { Qt.callLater(function () { option.focus = false }) }
      }
    }
  }
}
