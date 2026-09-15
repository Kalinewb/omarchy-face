import QtQuick
import qs.Commons
import qs.Ui
import "common/names.js" as Names

// People: who this machine knows, and what each of them may do
// (plan-gui.md §5.1).
//
// Everything here comes from `people.json` (plan-merged.md §2.6), which the
// panel watches. The view invents nothing: not the appearance counts, not
// `sudo_faces`, and not the warning line -- that string is the engine's, printed
// verbatim, because the thresholds behind it are the engine's measurement and
// not something a QML file should be guessing at.
Column {
  id: view

  property var panel: null

  readonly property color foreground: panel ? panel.foreground : Color.foreground
  readonly property color dim: panel ? panel.dim : Color.muted
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family

  readonly property var store: panel && panel.people ? panel.people : ({})
  readonly property var people: store && Array.isArray(store.people) ? store.people : []
  readonly property int sudoFaces: store && typeof store.sudo_faces === "number" ? store.sudo_faces : 0
  readonly property string warning: store && store.warning ? String(store.warning) : ""
  readonly property string labelRule: store && store.labelRule ? String(store.labelRule) : Names.LABEL_RULE
  readonly property var config: panel ? panel.config : ({})
  readonly property bool lockFeature: !!config.lock

  // The engine has to be there before anybody can be recorded: the session runs
  // howdy's own capture. Setup says what is missing; this view only has to stop
  // offering a button that cannot work.
  readonly property bool engineReady: panel ? panel.rowState("engine") === "ok" : false

  // --- adding somebody (plan-gui.md §5.1) ---------------------------------
  //
  // There are no empty people (plan-merged.md §1 row 5): the form takes a label,
  // derives the name live, and hands both to one `enroll-session`. The person
  // exists only once that session's first appearance commits.

  property bool adding: false
  property string newLabel: ""
  property string note: ""

  readonly property var takenNames: {
    var names = []
    for (var i = 0; i < people.length; i++) if (people[i]) names.push(String(people[i].name))
    return names
  }
  readonly property string derivedName: Names.derive(view.newLabel, view.takenNames)
  readonly property bool labelValid: Names.labelOk(view.newLabel, view.labelRule)

  // The first appearance's own label. The three standard ones are offered in the
  // person view; the first is always the plain one.
  readonly property string firstAppearance: "No glasses"

  function startAdding() {
    view.note = ""
    view.newLabel = ""
    view.adding = true
    // Prefill with the account name for the very first person, who is the owner
    // (plan-merged.md §5.9: the label is the GUI's to prefill, "You" is only
    // how it is rendered afterwards).
    if (view.people.length === 0) view.newLabel = String(view.config.account || "")
  }

  // Hand the session to the Face service, which owns the recording card: it is
  // keepLoaded, so the card survives a plugins-folder reload, and it needs
  // exclusive keyboard focus, which a popup cannot give it (plan-gui.md §1).
  // The popup closes, because the card is what the person is looking at now.
  function record(name, appearance, label, isNew) {
    if (!panel) return
    view.note = ""
    panel.ask.ask(panel.ask.cardArgv(["record", String(name), String(appearance),
                                      String(label), isNew ? "new" : ""]), "",
      function (result) {
        if (!result.ok) {
          view.note = "The recording card could not be opened."
          console.warn("graveklar.face", "card record failed:", result.outcome, result.stdout)
        }
      })
    panel.close()
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(6)

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.people.length === 0 && !view.adding
    wrapMode: Text.WordWrap
    text: view.engineReady
          ? "Nobody is recorded yet. Add yourself first — the first person recorded is the owner of this machine's Face, and the only one who can change anything."
          : "Nobody is recorded yet. The face engine has to be built before a face can be recorded — Setup has the button."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
  }

  Repeater {
    model: view.people

    Rectangle {
      id: personRow
      required property var modelData

      // NOT `Array.isArray(modelData.appearances)`.
      //
      // A Repeater hands its delegate `modelData` through a QVariant, and a
      // nested array comes out the other side as an object whose `length` is
      // right and for which **Array.isArray() is false**. So that guard threw
      // away every appearance of every person, and this list said "0
      // appearances" against a store that was perfectly good -- for the owner
      // who had just recorded a second one, most visibly of all.
      //
      // Found after shipping, by looking at the preview screenshot. It is not a
      // staleness bug and no amount of re-reading people.json would have fixed
      // it: the row was rendering the right document wrongly. `length` is what
      // survives the round trip, so `length` is what this reads.
      readonly property int appearanceCount: {
        var list = modelData.appearances
        return list && list.length !== undefined ? list.length : 0
      }
      readonly property string displayLabel: modelData.owner
        ? "You" : String(modelData.label || modelData.name || "")

      width: view.width
      implicitHeight: rowContent.implicitHeight + Style.space(10)
      radius: Style.cornerRadius
      color: hover.hovered ? Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.06)
                           : "transparent"

      HoverHandler { id: hover }
      TapHandler {
        onTapped: if (view.panel) view.panel.openPerson(String(personRow.modelData.name || ""))
      }

      Row {
        id: rowContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          // nf-md-account
          text: "\u{f0004}"
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.icon
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          width: parent.width - Style.space(28) - chips.implicitWidth
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: personRow.displayLabel
            color: view.foreground
            font.family: view.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: personRow.appearanceCount === 1 ? "1 appearance"
                                                  : personRow.appearanceCount + " appearances"
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Row {
          id: chips
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          // A chip for a permission that is on. The Lock chip renders dim with
          // its own caption while the feature is off in Settings, because the
          // permission is real either way -- it just has nothing to act on yet
          // (plan-gui.md §5.1).
          Repeater {
            model: [
              {on: !!personRow.modelData.sudo, text: "Sudo", faded: false},
              {on: !!personRow.modelData.lock, text: view.lockFeature ? "Lock" : "Lock · off in Settings",
               faded: !view.lockFeature}
            ]

            Rectangle {
              required property var modelData
              visible: modelData.on
              implicitWidth: chipText.implicitWidth + Style.space(12)
              implicitHeight: chipText.implicitHeight + Style.space(4)
              radius: Style.cornerRadius
              color: "transparent"
              border.width: 1
              border.color: modelData.faded ? view.dim : view.foreground
              opacity: modelData.faded ? 0.6 : 1

              Text {
                id: chipText
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: modelData.text
                color: modelData.faded ? view.dim : view.foreground
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }

  PanelSeparator { width: parent.width; visible: view.people.length > 0 }

  // --- add a person --------------------------------------------------------

  Button {
    visible: !view.adding
    enabled: view.engineReady
    text: view.people.length === 0 ? "Add yourself" : "Add a person"
    iconText: "\u{f0415}"
    foreground: view.foreground
    fontFamily: view.fontFamily
    onClicked: view.startAdding()
  }

  Column {
    visible: view.adding
    width: parent.width
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "What should this person be called?"
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }

    TextField {
      id: labelField
      width: parent.width
      text: view.newLabel
      placeholderText: "Anna"
      foreground: view.foreground
      onTextChanged: view.newLabel = text
      onAccepted: if (view.labelValid) view.record(view.derivedName, view.firstAppearance, view.newLabel, true)
      // The field is why this form is inline rather than a dialog, and why the
      // panel only reassigns `people` when its bytes change: a model identity
      // that changed once a second would take the focus and the typed text with
      // it every tick.
      onVisibleChanged: if (visible) Qt.callLater(function () { labelField.forceActiveFocus() })
    }

    // The name, live, under the field. It is what Profiles will be bound to and
    // it can never be changed afterwards, so it is shown before the recording
    // rather than explained after it (plan-gui.md §5.4).
    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: view.labelValid ? "Name used by Profiles: " + view.derivedName
                            : "A name can be up to 32 characters, on one line."
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Row {
      spacing: Style.space(8)

      Button {
        text: "Record first appearance"
        enabled: view.labelValid
        bordered: true
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.record(view.derivedName, view.firstAppearance, view.newLabel, true)
      }

      Button {
        text: "Cancel"
        foreground: view.dim
        fontFamily: view.fontFamily
        onClicked: { view.adding = false; view.newLabel = "" }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.note !== ""
    text: view.note
    color: Color.urgent
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // --- the footer ----------------------------------------------------------

  Text {
    textFormat: Text.PlainText
    width: parent.width
    topPadding: Style.space(4)
    visible: view.people.length > 0
    text: "Sudo matches against " + view.sudoFaces + (view.sudoFaces === 1 ? " face" : " faces")
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.warning !== ""
    text: view.warning
    color: Color.urgent
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
