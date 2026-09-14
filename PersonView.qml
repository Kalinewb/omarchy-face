import QtQuick
import qs.Commons
import qs.Ui

// One person: their appearances, their permissions, Test and Remove.
//
// Phase 1 shows only what identifies them, including the immutable name the
// Profiles contract is keyed on (plan-merged.md §1 row 6). Editing the label,
// recording and removing appearances, the permission toggles, Test and Remove
// are G4 (plan-merged.md §4 phase 4) -- every one of them is a store change
// behind the owner prompt, and there is no store yet.
Column {
  id: view

  property var panel: null

  readonly property color foreground: panel ? panel.foreground : Color.foreground
  readonly property color dim: panel ? panel.dim : Color.muted
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property string name: panel ? panel.personName : ""

  readonly property var person: {
    var list = panel && panel.people && Array.isArray(panel.people.people) ? panel.people.people : []
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].name === view.name) return list[i]
    return null
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(6)

  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: view.person ? "Name used by Profiles: " + view.name + " — cannot change"
                      : "No such person: " + view.name
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.person !== null
    text: "Appearances, permissions, Test and Remove arrive with the people store."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
  }
}
