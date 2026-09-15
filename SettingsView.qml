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
// The lock screen switch is G6. It changes no file that PAM or the compositor
// reads: it turns one setting on in Face's own config and moves the wrapper
// plugin in and out of `shell.json`. Omarchy's lock screen is Omarchy's either
// way -- the wrapper loads it rather than replacing it -- so the worst this
// switch can do is leave the lock screen exactly as Omarchy ships it.
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

  // `requested` is the value the switch was moved TO, not the value the config
  // has now: the status document is re-read asynchronously, so at the moment
  // this runs `config.sudo` is still whatever it was before the verb. The
  // difference matters for one code -- a refused PAM edit after `sudo-off`
  // leaves the feature off and the lines in place, which is a different sentence
  // from a refused `sudo-on`, which changed nothing at all.
  function outcomeText(result, requested) {
    if (result.outcome === "owner_declined") return "Not authorised."
    if (result.outcome === "missing") return "Face's system files are not installed."
    if (result.outcome === "busy") return "Face is busy — try again in a moment."
    var code = result.parsed && result.parsed.error ? String(result.parsed.error) : result.outcome
    if (code === "no_sudo_faces") return "Give someone Sudo first."
    if (code === "helper_unsafe")
      return "Face's own helpers in /usr/local/bin are not owned by root, or can be written by " +
             "somebody else — sudo will not be pointed at them."
    // After a sudo-off, this means the setting was written and the lines were
    // not: the feature is off either way, which is what the message has to say
    // first. (sudo-on's own pam_edit_failed changed nothing at all.)
    if (code === "pam_edit_failed")
      return requested
        ? "/etc/pam.d/sudo is not the shape Face wrote, so it was left exactly as it is."
        : "Face for sudo is off and no face will be tried — but its lines are still in "
          + "/etc/pam.d/sudo, because they are not the ones Face wrote and it will not delete "
          + "somebody else's."
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
      view.note = result.ok ? "" : view.outcomeText(result, value)
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

  // The sudo row going `broken` means /etc/pam.d/sudo is not what Face wrote.
  // It is shown here, where the switch is, because this page is where somebody
  // would come to put it right.
  //
  // Two states, and they are not equally bad -- the engine's detail already says
  // which, so this only adds what to do about it. With the switch OFF, both
  // helpers read the setting before anything else and hand straight back to the
  // password prompt, so the leftover lines do nothing; with it ON, they may well
  // run. Saying "turning this off fixes it" in both cases would be a promise
  // this switch cannot keep in the first one.
  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.sudoRowState === "broken"
    leftPadding: Style.space(6)
    text: view.sudoDetail + (view.sudoOn
          ? " Turning this off stops any face being tried, whether or not the lines can be removed."
          : " Nothing is tried while this is off. Removing the lines needs somebody who can edit "
            + "/etc/pam.d/sudo as root — Face will not touch a block it did not write.")
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
  //
  // Two calls, in this order, and neither direction needs a second password to
  // roll back (plan-engine.md §9.4):
  //
  //   on   omarchy-face-lock enable   (no prompt; it waits up to 10 s for the
  //                                    new lock service to answer)
  //        then admin lock-on         (prompt). Declined -> `disable`, and the
  //                                    switch snaps back with nothing changed.
  //   off  admin lock-off             (prompt), then `disable`.
  //
  // **Neither call writes ~/.config/omarchy/plugins.** `enable` and `disable`
  // edit `shell.json`, which is outside that folder, and the shell swaps the
  // live lock service with no restart and no reload (E12, E13) -- which is why
  // this switch can be moved with the popup still open. The wrapper folder was
  // put in place once, by the Face service at a shell start, and stays there
  // whether the feature is on or off.

  property var pendingLock: null

  readonly property bool lockOn: view.pendingLock !== null ? view.pendingLock : view.config.lock === true

  readonly property string lockCompat: view.lockState && view.lockState.compat
                                       ? String(view.lockState.compat) : ""
  readonly property string lockOther: view.lockState && view.lockState.otherLock
                                      ? String(view.lockState.otherLock) : ""
  readonly property var lockMissing: view.lockState && Array.isArray(view.lockState.missing)
                                     ? view.lockState.missing : []

  // What the engine's five compat words mean to somebody reading this page
  // (plan-merged.md §1 row 12). `otherLock` is not one of them: it is a reason
  // `n/a` happened, and it replaces the `n/a` line rather than appearing beside
  // it.
  readonly property string lockStatusText: {
    if (view.lockOther !== "")
      return "Another lock screen plugin (" + view.lockOther + ") is in use."
    if (view.lockCompat === "ok") return "Active · follows Omarchy's lock screen."
    if (view.lockCompat === "loading") return "Starting."
    if (view.lockCompat === "incompatible")
      return "Face is off on the lock screen: Omarchy's lock changed"
             + (view.lockMissing.length > 0 ? " (missing: " + view.lockMissing.join(", ") + ")" : "")
             + ". Password and fingerprint work as normal."
    if (view.lockCompat === "failed")
      return "Omarchy's own lock screen is back"
             + (view.lockMissing.length > 0 ? ": " + view.lockMissing.join(", ") : "") + "."
    return "Lock screen face unlock is off."
  }

  function lockOutcomeText(result) {
    if (result.outcome === "owner_declined") return "Not authorised — nothing changed."
    if (result.outcome === "missing") return "Face's system files are not installed."
    if (result.outcome === "busy") return "Face is busy — try again in a moment."
    var code = result.parsed && result.parsed.error ? String(result.parsed.error) : result.outcome
    if (code === "other_lock") {
      var id = result.parsed && result.parsed.id ? String(result.parsed.id) : "another plugin"
      return "Another lock screen plugin (" + id + ") is in use."
    }
    if (code === "enable_failed")
      return "Face's lock screen did not start, so Omarchy's is back — nothing changed."
    if (code === "validate_failed") return "Could not switch the lock screen — nothing changed."
    if (code === "not_staged") return "Lock screen setup is not finished — see Setup."
    if (code === "no_template") return "This plugin is missing its lock screen files — reinstall it."
    if (code === "locked") return "The session is locked — nothing is changed behind a lock screen."
    if (code === "config_write_failed")
      return "Face could not write its own configuration, so nothing was changed."
    if (code === "store_corrupt") return "Face's people store is damaged and nothing was changed."
    if (code === "not_installed") return "Face is not set up on this machine yet."
    return "That did not work: " + code + "."
  }

  function setLock(value) {
    if (!panel || view.busy !== "") return
    view.pendingLock = value
    view.busy = "lock"
    view.note = ""
    if (value) view.lockTurnOn()
    else view.lockTurnOff()
  }

  function lockFinish(message) {
    view.busy = ""
    view.pendingLock = null
    view.note = message || ""
    panel.reloadWatched()
    panel.refresh()
  }

  function lockTurnOn() {
    // The clone first, because it is the reversible half: if the owner then
    // declines the prompt, `disable` puts it back with no password of its own.
    panel.ask.ask(panel.ask.lockArgv(["enable"]), "", function (enabled) {
      if (!enabled.ok) { view.lockFinish(view.lockOutcomeText(enabled)); return }
      panel.ask.ask(panel.ask.adminArgv(["lock-on"]), "", function (result) {
        if (result.ok) { view.lockFinish(""); return }
        // The rollback. It is run for EVERY failure of `lock-on`, not only for a
        // declined prompt: the clone being the lock screen while the daemon
        // still answers `disabled` is a state nobody asked for, and leaving it
        // behind would be the switch reporting a failure it did not finish
        // undoing.
        var message = view.lockOutcomeText(result)
        panel.ask.ask(panel.ask.lockArgv(["disable"]), "", function (rolled) {
          view.lockFinish(rolled.ok
            ? message
            : message + " Face's lock screen could not be switched back off either — open Setup.")
        })
      })
    })
  }

  function lockTurnOff() {
    // The setting first: it is what the daemon reads before it will look at a
    // camera at all, so this call -- not the one below -- is what turns face
    // off. A declined prompt therefore changes nothing and the clone stays as
    // it was.
    panel.ask.ask(panel.ask.adminArgv(["lock-off"]), "", function (result) {
      if (!result.ok) { view.lockFinish(view.lockOutcomeText(result)); return }
      panel.ask.ask(panel.ask.lockArgv(["disable"]), "", function (disabled) {
        view.lockFinish(disabled.ok
          ? ""
          : "No face will be tried on the lock screen, but Omarchy's own lock screen "
            + "could not be put back until the next restart.")
      })
    })
  }

  Toggle {
    width: parent.width
    label: "Lock screen"
    description: "Unlock by looking, for people with Lock screen. Face is tried when you wake "
                 + "the screen — lock, walk away, come back, touch a key and look at the camera."
    checked: view.lockOn
    enabled: view.busy === ""
    foreground: view.foreground
    fontFamily: view.fontFamily
    onClicked: view.setLock(!view.lockOn)
  }

  // The count, and the one thing worth saying in the accent colour: the feature
  // can be on with nobody behind it, because `lock-on` deliberately does not
  // refuse that (the daemon fails safe on an empty set) -- so the page has to
  // say it rather than the switch refusing to move.
  Text {
    textFormat: Text.PlainText
    width: parent.width
    leftPadding: Style.space(6)
    text: view.lockFaces === 0
      ? "Nobody has Lock screen yet — set it on a person."
      : (view.lockFaces === 1 ? "1 person can unlock the lock screen"
                              : view.lockFaces + " people can unlock the lock screen")
        + " · " + view.lockStatusText
    color: view.lockFaces === 0 ? Color.accent : view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.lockFaces === 0
    leftPadding: Style.space(6)
    text: view.lockStatusText
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.busy === "lock"
    leftPadding: Style.space(6)
    text: "Working…"
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
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

  // --- removal ----------------------------------------------------------------
  //
  // The way out of Face, where plan-gui.md §7.1 puts it. It is a page, not a
  // switch: what it would take off the machine is read from the engine's own
  // dry run first, and nothing happens on this click.

  PanelSeparator {
    width: parent.width
    foreground: view.foreground
  }

  Button {
    text: "Remove Face Unlock from this machine"
    bordered: true
    enabled: view.busy === ""
    foreground: view.foreground
    fontFamily: view.fontFamily
    fontSize: Style.font.caption
    onClicked: if (view.panel) view.panel.pushView("remove")
  }
}
