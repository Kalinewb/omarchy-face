import QtQuick
import qs.Commons
import qs.Ui
import "common/names.js" as Names

// One person: their appearances, their permissions, and Remove
// (plan-gui.md §5.2).
//
// Every control here is a store change, and every store change is one
// `pkexec omarchy-face-admin` away (plan-merged.md §2 rule 2) -- so each one is
// pending until the verb answers and snaps back when the owner declines. The
// name is shown but never editable: it is the key Profiles binds to, and a
// rename would silently retarget somebody else's binding (§1 row 6).
//
// Test ("does it recognise Anna now?") is the one control here that changes
// nothing: it runs `omarchy-face-identity verify <name>` -- the same call
// Profiles makes -- in a card under the webcam, and reports the exit code. It
// opens no door and needs no password.
Column {
  id: view

  property var panel: null

  readonly property color foreground: panel ? panel.foreground : Color.foreground
  readonly property color dim: panel ? panel.dim : Color.muted
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property string name: panel ? panel.personName : ""

  readonly property var store: panel && panel.people ? panel.people : ({})
  readonly property var people: store && Array.isArray(store.people) ? store.people : []
  readonly property string labelRule: store && store.labelRule ? String(store.labelRule) : Names.LABEL_RULE
  readonly property int maxAppearances: store && typeof store.maxAppearances === "number"
                                        ? store.maxAppearances : 3
  readonly property var standardLabels: store && Array.isArray(store.appearanceLabels)
    ? store.appearanceLabels : ["No glasses", "Everyday glasses", "Reading glasses"]

  readonly property var person: {
    for (var i = 0; i < view.people.length; i++)
      if (view.people[i] && view.people[i].name === view.name) return view.people[i]
    return null
  }

  readonly property var appearances: person && Array.isArray(person.appearances) ? person.appearances : []
  readonly property bool owner: !!(person && person.owner)
  readonly property string label: person ? String(person.label || person.name) : ""
  readonly property string shown: view.owner ? "You" : view.label
  // The name in the copy: "Her face…" reads wrong for a person called "2 Kids",
  // so it is always the label, and "Your" for the owner.
  readonly property string possessive: view.owner ? "Your" : view.label + "'s"
  readonly property var config: panel ? panel.config : ({})
  readonly property bool lockFeature: !!config.lock
  readonly property bool full: view.appearances.length >= view.maxAppearances
  // The owner has no Remove row at all (plan-gui.md §5.2). A property rather
  // than a `visible:` expression buried in the tree, so the gate can ask.
  readonly property bool removeVisible: view.person !== null && !view.owner

  // One thing at a time, and one message: a list of stale outcomes from earlier
  // clicks is not something anybody reads.
  property string busy: ""
  property string note: ""
  property bool editing: false
  property string draftLabel: ""
  property bool confirmingRemove: false
  property bool addingCustom: false
  property string customLabel: ""

  // A permission that is waiting for the owner's password. The switch shows the
  // pending value, and snaps back if the prompt is declined.
  property var pending: ({})

  function permissionValue(which) {
    if (view.pending[which] !== undefined) return view.pending[which]
    return !!(view.person && view.person[which])
  }

  function admin(args, stdinText, done) {
    if (!panel) return
    panel.ask.ask(panel.ask.adminArgv(args), stdinText || "", function (result) {
      view.busy = ""
      if (done) done(result)
      panel.reloadWatched()
      panel.refresh()
    })
  }

  // What went wrong, in the words of §2.3's error codes.
  function outcomeText(result) {
    if (result.outcome === "owner_declined") return "Not authorised."
    if (result.outcome === "missing") return "Face's system files are not installed."
    if (result.outcome === "busy") return "Face is busy — try again in a moment."
    var code = result.parsed && result.parsed.error ? String(result.parsed.error) : result.outcome
    if (code === "is_owner") return "The owner cannot be removed."
    if (code === "no_appearances") return "Record an appearance first."
    if (code === "invalid_label") return "That name is too long, or has a line break in it."
    if (code === "store_corrupt") return "Face's people store is damaged and was not changed."
    if (code === "no_person") return "That person is not in the store any more."
    return "That did not work: " + code + "."
  }

  function setPermission(which, value) {
    if (view.busy !== "") return
    var next = {}
    for (var key in view.pending) next[key] = view.pending[key]
    next[which] = value
    view.pending = next
    view.busy = which
    view.note = ""
    view.admin(["set-permission", view.name, which, value ? "on" : "off"], "", function (result) {
      var cleared = {}
      for (var key in view.pending) if (key !== which) cleared[key] = view.pending[key]
      view.pending = cleared
      if (!result.ok) { view.note = view.outcomeText(result); return }
      // Removing the last Sudo face unwires sudo in the same call, and the
      // person deserves to be told rather than finding out at a prompt
      // (plan-merged.md §2.3).
      if (result.parsed && result.parsed.unwired === "sudo")
        view.note = "Nobody has Sudo now, so sudo asks for passwords only."
      // The same call, when the PAM edit itself was refused. The setting is off
      // either way -- the engine writes that first, precisely so this case is not
      // a machine still asking the camera -- so what is left is lines that do
      // nothing, and somebody with a root editor is who removes them.
      else if (result.parsed && result.parsed.unwired === "failed")
        view.note = "Nobody has Sudo now and no face is tried, but Face's lines are still in " +
                    "/etc/pam.d/sudo: they are not the ones Face wrote, so it left them alone."
    })
  }

  function saveLabel() {
    if (!Names.labelOk(view.draftLabel, view.labelRule)) return
    view.busy = "label"
    view.note = ""
    view.admin(["set-label", view.name], JSON.stringify({label: view.draftLabel}), function (result) {
      if (result.ok) view.editing = false
      else view.note = view.outcomeText(result)
    })
  }

  function removeAppearance(appearanceLabel) {
    if (view.busy !== "") return
    view.busy = "appearance:" + appearanceLabel
    view.note = ""
    view.admin(["remove-appearance", view.name],
               JSON.stringify({appearance: appearanceLabel}), function (result) {
      if (!result.ok) { view.note = view.outcomeText(result); return }
      if (result.parsed && result.parsed.unwired === "sudo")
        view.note = "Nobody has Sudo now, so sudo asks for passwords only."
      // The same call, when the PAM edit itself was refused. The setting is off
      // either way -- the engine writes that first, precisely so this case is not
      // a machine still asking the camera -- so what is left is lines that do
      // nothing, and somebody with a root editor is who removes them.
      else if (result.parsed && result.parsed.unwired === "failed")
        view.note = "Nobody has Sudo now and no face is tried, but Face's lines are still in " +
                    "/etc/pam.d/sudo: they are not the ones Face wrote, so it left them alone."
    })
  }

  function removePerson() {
    view.busy = "remove"
    view.note = ""
    view.admin(["remove-person", view.name], "", function (result) {
      if (!result.ok) { view.note = view.outcomeText(result); return }
      view.confirmingRemove = false
      if (view.panel) view.panel.navBack()
    })
  }

  // Recording is one `enroll-session`, run by the card in the Face service; the
  // popup closes because the card is what the person is looking at now. Adding
  // or re-recording an appearance on a Sudo person asks for the owner's password
  // like the toggle does -- the session's own prompt covers it (§5.2).
  function record(appearanceLabel) {
    if (!panel) return
    panel.ask.ask(panel.ask.cardArgv(["record", view.name, String(appearanceLabel),
                                      view.label, ""]), "", function (result) {
      if (!result.ok) view.note = "The recording card could not be opened."
    })
    panel.close()
  }

  // Test: one IPC call to the service, which owns the card (plan-gui.md §5.2).
  // The popup stays open behind it -- the card takes no keyboard focus and its
  // input region is the card itself, so this is the one card that does not cost
  // the person the view they were reading.
  //
  // `busy` comes back when a recording card is already up, or a test of
  // somebody else is running; there is nothing to retry and nothing to undo, so
  // it is said plainly and the button stays live.
  function test() {
    if (!panel) return
    view.note = ""
    panel.ask.ask(panel.ask.cardArgv(["testMatch", view.name]), "", function (result) {
      if (!result.ok) { view.note = "The test card could not be opened."; return }
      if (String(result.stdout || "").trim() === "busy")
        view.note = "Face is showing another card — close it and try again."
    })
  }

  function dateText(seconds) {
    if (!(seconds > 0)) return ""
    return Qt.formatDate(new Date(seconds * 1000), "d MMM")
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(6)

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.person === null
    text: "No such person: " + view.name
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
  }

  // --- the label ------------------------------------------------------------

  Row {
    width: parent.width
    visible: view.person !== null && !view.editing
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      width: parent.width - editButton.implicitWidth - Style.space(8)
      text: view.shown + (view.owner && view.label !== "" ? " · " + view.label : "")
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.subtitle
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
    }

    Button {
      id: editButton
      text: "Edit"
      foreground: view.foreground
      fontFamily: view.fontFamily
      onClicked: { view.draftLabel = view.label; view.editing = true }
    }
  }

  Column {
    width: parent.width
    visible: view.editing
    spacing: Style.space(4)

    TextField {
      id: labelField
      width: parent.width
      text: view.draftLabel
      foreground: view.foreground
      onTextChanged: view.draftLabel = text
      onAccepted: view.saveLabel()
      onVisibleChanged: if (visible) Qt.callLater(function () { labelField.forceActiveFocus() })
    }

    Row {
      spacing: Style.space(8)

      Button {
        text: "Save"
        bordered: true
        enabled: Names.labelOk(view.draftLabel, view.labelRule) && view.busy === ""
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.saveLabel()
      }

      Button {
        text: "Cancel"
        foreground: view.dim
        fontFamily: view.fontFamily
        onClicked: view.editing = false
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.person !== null
    text: "Name used by Profiles: " + view.name + " — cannot change"
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // --- appearances ----------------------------------------------------------

  PanelSectionHeader {
    width: parent.width
    visible: view.person !== null
    text: "Appearances"
    foreground: view.foreground
    fontFamily: view.fontFamily
  }

  Repeater {
    model: view.appearances

    Row {
      required property var modelData
      width: view.width
      spacing: Style.space(8)

      Column {
        width: parent.width - reRecord.implicitWidth - removeAppearance.implicitWidth - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: String(modelData.label || "")
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "recorded " + view.dateText(Number(modelData.time || 0))
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Button {
        id: reRecord
        text: "Re-record"
        foreground: view.foreground
        fontFamily: view.fontFamily
        anchors.verticalCenter: parent.verticalCenter
        onClicked: view.record(String(modelData.label || ""))
      }

      Button {
        id: removeAppearance
        iconText: "\u{f0156}"
        tooltipText: "Remove this appearance"
        foreground: view.foreground
        fontFamily: view.fontFamily
        enabled: view.busy === ""
        anchors.verticalCenter: parent.verticalCenter
        onClicked: view.removeAppearance(String(modelData.label || ""))
      }
    }
  }

  // The standard labels as `+` rows until they are used, and *Other…* for a
  // custom one. At three the rows go and a caption says why (plan-gui.md §5.2).
  Flow {
    width: parent.width
    visible: view.person !== null && !view.full
    spacing: Style.space(6)

    Repeater {
      model: view.standardLabels

      Button {
        required property var modelData
        visible: {
          for (var i = 0; i < view.appearances.length; i++)
            if (String(view.appearances[i].label) === String(modelData)) return false
          return true
        }
        text: "+ " + modelData
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.record(String(modelData))
      }
    }

    Button {
      text: "+ Other…"
      foreground: view.foreground
      fontFamily: view.fontFamily
      onClicked: { view.addingCustom = true; view.customLabel = "" }
    }
  }

  Row {
    width: parent.width
    visible: view.addingCustom && !view.full
    spacing: Style.space(8)

    TextField {
      id: customField
      width: parent.width - customRecord.implicitWidth - Style.space(8)
      text: view.customLabel
      placeholderText: "Sunglasses"
      foreground: view.foreground
      onTextChanged: view.customLabel = text
      onAccepted: if (Names.labelOk(view.customLabel, view.labelRule)) view.record(view.customLabel)
      onVisibleChanged: if (visible) Qt.callLater(function () { customField.forceActiveFocus() })
    }

    Button {
      id: customRecord
      text: "Record"
      bordered: true
      enabled: Names.labelOk(view.customLabel, view.labelRule)
      foreground: view.foreground
      fontFamily: view.fontFamily
      anchors.verticalCenter: parent.verticalCenter
      onClicked: view.record(view.customLabel)
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.person !== null && view.full
    text: "Three is the most."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.person !== null && view.appearances.length === 0
    text: "Nothing recorded yet."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
  }

  // --- permissions ----------------------------------------------------------

  PanelSectionHeader {
    width: parent.width
    visible: view.person !== null
    text: "Permissions"
    foreground: view.foreground
    fontFamily: view.fontFamily
  }

  // Fixed copy, not tooltips: what Sudo means is the one thing on this screen
  // that has to be read before it is switched on (plan-gui.md §5.2, risk 1).
  Toggle {
    width: parent.width
    visible: view.person !== null
    label: "Sudo"
    description: view.possessive + " face can approve sudo — that is root on this machine, as "
                 + String(view.config.account || "this account") + "."
    checked: view.permissionValue("sudo")
    enabled: view.busy === "" && (view.appearances.length > 0 || view.permissionValue("sudo"))
    foreground: view.foreground
    fontFamily: view.fontFamily
    onClicked: view.setPermission("sudo", !view.permissionValue("sudo"))
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.person !== null && view.appearances.length === 0
    leftPadding: Style.space(6)
    text: "Record an appearance first."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
  }

  // Shown on every person at all times; the second caption only while the
  // feature is off (plan-gui.md §5.2).
  Toggle {
    width: parent.width
    visible: view.person !== null
    label: "Lock screen"
    description: view.possessive + " face can unlock this session, into whatever profile is open."
    checked: view.permissionValue("lock")
    enabled: view.busy === "" && (view.appearances.length > 0 || view.permissionValue("lock"))
    foreground: view.foreground
    fontFamily: view.fontFamily
    onClicked: view.setPermission("lock", !view.permissionValue("lock"))
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.person !== null && !view.lockFeature
    leftPadding: Style.space(6)
    text: "Lock screen face unlock is off — turn it on in Settings."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // --- test -----------------------------------------------------------------
  //
  // Between the permissions and Remove, where plan-gui.md §5.2 puts it: it is
  // the answer to "did that recording actually work", asked right under the
  // switches that decide what a working one is allowed to do.

  Column {
    width: parent.width
    visible: view.person !== null
    spacing: Style.space(2)
    topPadding: Style.space(6)

    Button {
      id: testButton
      text: "Test — does it recognise " + view.shown + " now?"
      // With nothing recorded there is nothing to compare against, and the
      // helper would answer 2 ("not set up") after a round trip to the daemon.
      enabled: view.appearances.length > 0
      foreground: view.foreground
      fontFamily: view.fontFamily
      onClicked: view.test()
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "Looks at the camera and says who it sees. Nothing is unlocked."
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // --- remove ---------------------------------------------------------------
  //
  // The owner has no Remove row at all (plan-gui.md §5.2). The engine refuses it
  // too (`is_owner`), because this control is not the only way in: the same verb
  // is one pkexec away from any process running as the owner.

  Column {
    width: parent.width
    visible: view.removeVisible
    spacing: Style.space(4)
    topPadding: Style.space(6)

    Button {
      id: removeButton
      visible: !view.confirmingRemove
      text: "Remove " + view.label
      foreground: Color.urgent
      fontFamily: view.fontFamily
      onClicked: view.confirmingRemove = true
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: view.confirmingRemove
      text: "Remove " + view.label + "? This takes "
            + (view.appearances.length === 1 ? "1 appearance" : view.appearances.length + " appearances")
            + "; profiles bound to " + view.name + " fall back to their password."
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Row {
      visible: view.confirmingRemove
      spacing: Style.space(8)

      Button {
        text: "Remove"
        bordered: true
        enabled: view.busy === ""
        foreground: Color.urgent
        fontFamily: view.fontFamily
        onClicked: view.removePerson()
      }

      Button {
        text: "Keep"
        foreground: view.dim
        fontFamily: view.fontFamily
        onClicked: view.confirmingRemove = false
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.note !== ""
    topPadding: Style.space(4)
    text: view.note
    color: Color.urgent
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
