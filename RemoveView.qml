import QtQuick
import qs.Commons
import qs.Ui

// Remove Face Unlock from this machine.
//
// The list is the engine's unprivileged dry run of `purge` -- the `removal`
// object of plan-merged.md §2.2, not a prompting verb -- so this view can show
// exactly what would go without asking for a password to find out.
//
// The Remove button itself is G7 (plan-merged.md §4 phase 8). Its last step is
// the one detached command that deletes the plugin folders, which is also the
// write that closes this popup, so it is built last and deliberately.
Column {
  id: view

  property var panel: null

  readonly property color foreground: panel ? panel.foreground : Color.foreground
  readonly property color dim: panel ? panel.dim : Color.muted
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property var removal: panel && panel.status && panel.status.removal ? panel.status.removal : null

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(6)

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: !view.removal
    text: "Nothing to remove: the engine reports no installed half."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
  }

  Repeater {
    model: {
      var r = view.removal
      if (!r) return []
      var out = []
      if (Array.isArray(r.people) && r.people.length > 0) out.push(r.people.length + " people, with their appearances")
      if (Array.isArray(r.pam) && r.pam.length > 0) out.push("PAM lines in " + r.pam.join(", "))
      if (r.lockWrapper) out.push("the lock screen wrapper")
      if (r.helpers) out.push(r.helpers + " helpers in /usr/local/bin")
      if (r.daemon) out.push("the verification daemon and its socket")
      if (r.policy) out.push("the polkit policy")
      if (Array.isArray(r.packages) && r.packages.length > 0) out.push("packages: " + r.packages.join(", "))
      return out
    }

    Text {
      required property var modelData
      textFormat: Text.PlainText
      width: view.width
      text: "· " + modelData
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }
  }
}
