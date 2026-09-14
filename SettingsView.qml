import QtQuick
import qs.Commons
import qs.Ui

// Settings: the two places a face is accepted, and the way to Remove.
//
// The sudo switch is G5 and it is the one control in this plugin that changes
// /etc/pam.d/sudo. Turning it on points sudo's auth stack at Face's two helpers;
// turning it off takes the block back out. Both go through
// `pkexec omarchy-face-admin sudo-on|sudo-off` (plan-merged.md §2 rule 2), so
// the owner's password is asked for every time -- a face can never grant itself
// Sudo, because Face is never in the polkit stack.
//
// The lock screen half is still read-only; its switch is G6 (phase 7).
Column {
  id: view

  property var panel: null

  readonly property color foreground: panel ? panel.foreground : Color.foreground
  readonly property color dim: panel ? panel.dim : Color.muted
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property var config: panel ? panel.config : ({})
  readonly property var lockState: panel ? panel.lockState : ({})
  readonly property var store: panel && panel.people ? panel.people : ({})

  readonly property int sudoFaces: store && typeof store.sudo_faces === "number" ? store.sudo_faces : 0
  readonly property int lockFaces: store && typeof store.lock_faces === "number" ? store.lock_faces : 0

  // What the status document says about the wiring, which is not the same
  // question as what the config says: `broken` is the two disagreeing, and the
  // switch must not pretend that is an ordinary "on" or "off".
  readonly property string sudoRowState: panel ? panel.rowState("sudo") : ""
  readonly property string sudoDetail: {
    var row = panel ? panel.row("sudo") : null
    return row ? String(row.detail || "") : ""
  }

  // The value the switch shows while the owner's password is being asked for.
  // Cleared when the verb answers, so a declined prompt snaps it back.
  property var pendingSudo: null
  property string busy: ""
  property string note: ""

  readonly property bool sudoOn: view.pendingSudo !== null ? view.pendingSudo : view.config.sudo === true

  function outcomeText(result) {
    if (result.outcome === "owner_declined") return "Not authorised."
    if (result.outcome === "missing") return "Face's system files are not installed."
    if (result.outcome === "busy") return "Face is busy — try again in a moment."
    var code = result.parsed && result.parsed.error ? String(result.parsed.error) : result.outcome
    if (code === "no_sudo_faces") return "Give someone Sudo first."
    if (code === "helper_unsafe")
      return "Face's own helpers in /usr/local/bin are not owned by root, or can be written by " +
             "somebody else — sudo will not be pointed at them."
    if (code === "pam_edit_failed")
      return "/etc/pam.d/sudo is not the shape Face wrote, so it was left exactly as it is."
    if (code === "config_write_failed")
      return "Face could not write its own configuration, so nothing was changed."
    if (code === "store_corrupt") return "Face's people store is damaged and nothing was changed."
    if (code === "not_installed") return "Face is not set up on this machine yet."
    // `sudo-on` derives the set PAM will read before it writes a line, so a
    // machine with no engine fails here rather than half way.
    if (code === "engine_missing") return "The face engine is not built yet — see Setup."
    if (code === "python_missing") return "Face's engine needs python3, which is not installed."
    return "That did not work: " + code + "."
  }

  function setSudo(value) {
    if (!panel || view.busy !== "") return
    view.pendingSudo = value
    view.busy = "sudo"
    view.note = ""
    panel.ask.ask(panel.ask.adminArgv([value ? "sudo-on" : "sudo-off"]), "", function (result) {
      view.busy = ""
      view.pendingSudo = null
      view.note = result.ok ? "" : view.outcomeText(result)
      // The switch shows `config.sudo` again the moment this lands, so the
      // status document is what it snaps back to -- not a value this view kept.
      panel.reloadWatched()
      panel.refresh()
    })
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  // --- sudo -------------------------------------------------------------------
  //
  // Fixed copy, not a tooltip: what this switch does is the one thing on this
  // page that has to be read before it is used (plan-merged.md §5 risk 1).

  Toggle {
    width: parent.width
    label: "Face for sudo"
    description: view.sudoFaces === 0
      ? "Nobody's face is tried while this is off."
      : "Nobody's face is tried while this is off. With it on, "
        + (view.sudoFaces === 1 ? "1 recorded face" : view.sudoFaces + " recorded faces")
        + " can approve sudo — that is root on this machine, as "
        + String(view.config.account || "this account") + "."
    checked: view.sudoOn
    // Turning it OFF is never blocked: `sudo-off` is always allowed, and a
    // switch that cannot be moved back is not a switch.
    enabled: view.busy === "" && (view.sudoOn || view.sudoFaces > 0)
    foreground: view.foreground
    fontFamily: view.fontFamily
    onClicked: view.setSudo(!view.sudoOn)
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.sudoFaces === 0 && !view.sudoOn
    leftPadding: Style.space(6)
    text: "Give someone Sudo first — open People and turn Sudo on for them."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // The sudo row going `broken` means the config and /etc/pam.d/sudo disagree.
  // It is shown here, where the switch is, because this page is where somebody
  // would come to put it right -- and turning the switch off is what does that.
  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.sudoRowState === "broken"
    leftPadding: Style.space(6)
    text: "Face's sudo setting and /etc/pam.d/sudo do not agree: " + view.sudoDetail
          + ". Turning this off puts sudo back to passwords only."
    color: Color.urgent
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.busy === "sudo"
    leftPadding: Style.space(6)
    text: "Working…"
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
  }

  // --- lock screen ------------------------------------------------------------

  Text {
    textFormat: Text.PlainText
    width: parent.width
    // The compat states are the engine's vocabulary (plan-merged.md §1 row 12);
    // their user-facing copy lands with the toggle that can change them.
    text: "Lock screen: " + (view.config.lock === true ? "on" : "off")
          + (view.lockFaces > 0 ? " · " + view.lockFaces + " face(s)" : "")
          + (view.lockState.compat ? " · " + view.lockState.compat : "")
          + (view.lockState.otherLock ? " · another lock plugin: " + view.lockState.otherLock : "")
    color: view.foreground
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: "The lock screen switch arrives with the lock-screen phase. Until then this line only reports what the engine already says."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
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
