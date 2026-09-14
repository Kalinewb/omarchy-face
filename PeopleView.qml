import QtQuick
import qs.Commons
import qs.Ui

// People: who this machine knows, and what each of them may do.
//
// Phase 1 lists what `people.json` already says (plan-merged.md §2.6) so the
// view stack can be walked with real data. The chips, the appearance counts,
// "Add a person" and the sudo-faces footer are G3 (plan-merged.md §4 phase 4),
// because none of them can be true before the store exists.
Column {
  id: view

  property var panel: null

  readonly property color foreground: panel ? panel.foreground : Color.foreground
  readonly property color dim: panel ? panel.dim : Color.muted
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property var people: panel && panel.people && Array.isArray(panel.people.people)
    ? panel.people.people : []

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.people.length === 0
    wrapMode: Text.WordWrap
    text: "Nobody is recorded yet.\n\nRecording a face needs the engine, the people store and the owner prompt — they arrive together in a later phase."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
  }

  Repeater {
    model: view.people

    Item {
      required property var modelData
      width: view.width
      implicitHeight: label.implicitHeight + Style.space(10)

      Text {
        id: label
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        // "You" is only how the GUI renders owner: true (plan-merged.md §5.9).
        text: (modelData.owner ? "You" : String(modelData.label || modelData.name || ""))
        color: view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      TapHandler {
        onTapped: if (view.panel) view.panel.openPerson(String(modelData.name || ""))
      }
    }
  }
}
