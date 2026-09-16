import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Remove Face ID from this machine.
//
// The list is the engine's unprivileged dry run of `purge` -- the `removal`
// object of plan-merged.md §2.2, not a prompting verb -- so this view can show
// exactly what would go without asking for a password to find out.
//
// The order is fixed (plan-engine.md §10.2, plan-gui.md §7.1) and every step of
// it is here for a reason:
//
//   1. `omarchy-face-lock disable` -- config only, so this popup survives it.
//      The lock service has to be Omarchy's own BEFORE the helpers its wrapper
//      calls are deleted.
//   2. `pkexec omarchy-face-admin purge` -- the whole system half, one prompt.
//      Exit 3 is an engine build in progress, and purge waits for it rather
//      than deleting /var/lib from under it. A non-empty `incomplete` stops
//      here: the plugin is never removed while its system half is still on the
//      machine, because the plugin is the only way back to this view.
//   3. The result, on screen, with nothing after it that writes the plugins
//      folder. That is the whole reason the third step is separate.
//   4. On close: ONE detached command that deletes both plugin folders. It is
//      detached because its first `rm -rf` is a plugins-folder write, and the
//      reload that follows destroys this popup and SIGKILLs every `Process` it
//      owns -- which, run the ordinary way, would be this very command.
Column {
  id: view

  property var panel: null

  readonly property color foreground: panel ? panel.foreground : Color.foreground
  readonly property color dim: panel ? panel.dim : Color.muted
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property var removal: panel && panel.status && panel.status.removal ? panel.status.removal : null
  readonly property var lockState: panel && panel.lockState ? panel.lockState : ({})
  readonly property bool lockEnabled: view.lockState.enabled === true

  // The folder both plugins live in, derived from this plugin's own directory
  // rather than assembled from $HOME: a checkout installed anywhere else must
  // delete itself, not somebody's guess at where it should have been.
  readonly property string pluginsDir: {
    var dir = panel ? String(panel.pluginDir || "") : ""
    var cut = dir.lastIndexOf("/")
    return cut > 0 ? dir.substring(0, cut) : ""
  }

  // idle · disabling · purging · incomplete · done · stopped
  property string phase: "idle"
  property string note: ""
  property var incomplete: []
  property bool keepPackages: false

  // The final step is owed: `purge` has finished and the two plugin folders are
  // all that is left. It runs when this popup closes, and exactly once.
  property bool armed: false
  property bool finalRan: false

  readonly property bool busy: view.phase === "disabling" || view.phase === "purging"

  // Nothing of the system half is left to remove. Either Face was never set up,
  // or a purge finished and the shell restarted before the final step ran --
  // which is the one way the plugin folders can outlive the system half without
  // anybody choosing it. Both want the same button, and it is not `purge`.
  readonly property bool nothingLeft: {
    var r = view.removal
    if (!r) return true
    if (Array.isArray(r.people) && r.people.length > 0) return false
    if (Array.isArray(r.pam) && r.pam.length > 0) return false
    if (Array.isArray(r.packages) && r.packages.length > 0) return false
    return !r.lockWrapper && !r.daemon && !r.policy && !(Number(r.helpers) > 0)
  }

  // The button's word for what it is about to do. A property rather than an
  // expression on the button, so what it says is a thing a test can read.
  readonly property string actionLabel: view.phase === "idle"
    ? (view.nothingLeft ? "Remove the plugin" : "Remove Face ID")
    : "Try again"

  // What would go, in the engine's own words. One line per kind of thing, and
  // no line at all for a kind this machine does not have.
  readonly property var lines: {
    var r = view.removal
    if (!r) return []
    var out = []
    if (Array.isArray(r.people) && r.people.length > 0) {
      var faces = 0
      for (var i = 0; i < r.people.length; i++) faces += Number(r.people[i].appearances || 0)
      out.push((r.people.length === 1 ? "1 person" : r.people.length + " people")
               + " and " + (faces === 1 ? "their recorded face" : faces + " recorded faces"))
    }
    if (Array.isArray(r.pam) && r.pam.length > 0) out.push("Face's lines in " + r.pam.join(", "))
    if (r.lockWrapper) out.push("the lock screen wrapper")
    if (Number(r.helpers) > 0) out.push(r.helpers + " helpers in /usr/local/bin")
    if (r.daemon) out.push("the verification daemon and its socket")
    if (r.policy) out.push("the password dialog's policy file")
    if (Array.isArray(r.packages) && r.packages.length > 0) {
      out.push(view.keepPackages
               ? "kept: " + r.packages.join(", ")
               : "the face engine: " + r.packages.join(", "))
    }
    return out
  }

  // --- the flow ---------------------------------------------------------------

  function lockOutcomeText(result) {
    var code = result.parsed && result.parsed.error ? String(result.parsed.error) : result.outcome
    if (code === "locked")
      return "Nothing is changed behind a lock screen — unlock the session and try again."
    if (code === "missing")
      return "Face's own bin/omarchy-face-lock is missing from this plugin."
    return "Face's lock screen could not be switched off (" + code + "), so nothing was removed. "
           + "Turn Lock screen off in Settings first."
  }

  function purgeOutcomeText(result) {
    if (result.outcome === "owner_declined") return "Not authorised — nothing was removed."
    if (result.outcome === "busy") return "Wait for the engine build to finish, then try again."
    if (result.outcome === "missing") return "Face's system files are not installed."
    var code = result.parsed && result.parsed.error ? String(result.parsed.error) : result.outcome
    if (code === "install_running") return "Wait for the engine build to finish, then try again."
    if (code === "not_owner") return "Face is set up for another account on this machine."
    return "That did not work: " + code + "."
  }

  function start() {
    if (!panel || view.busy) return
    view.note = ""
    view.incomplete = []
    view.phase = "disabling"
    // Step 1. It edits `shell.json` only, so this window is still here
    // afterwards to run step 2 (plan-merged.md §1 row 15).
    panel.ask.ask(panel.ask.lockArgv(["disable"]), "", function (result) {
      if (!result.ok) {
        var code = result.parsed && result.parsed.error ? String(result.parsed.error) : result.outcome
        // A clone that was never staged, or a shell that has nothing to
        // disable, is not a reason to refuse a removal: there is no lock
        // wrapper in the way. A clone that IS on the lock screen and will not
        // come off is, because the next step deletes what it calls.
        var harmless = !view.lockEnabled
                       && (code === "not_staged" || code === "disable_failed"
                           || code === "missing_omarchy" || code === "no_template"
                           || code === "missing")
        if (!harmless) {
          view.phase = "stopped"
          view.note = view.lockOutcomeText(result)
          return
        }
      }
      view.purge()
    })
  }

  function purge() {
    view.phase = "purging"
    var argv = view.keepPackages ? ["purge", "--keep-packages"] : ["purge"]
    panel.ask.ask(panel.ask.adminArgv(argv), "", function (result) {
      // This callback may arrive with the popup closed: `purge` runs as root and
      // cannot be signalled by the user, so closing the window neither stops it
      // nor loses it (plan-merged.md §1 row 16). It finishes, and the status
      // read on the next open is what shows the result.
      if (!result.ok) {
        view.phase = "stopped"
        view.note = view.purgeOutcomeText(result)
        panel.refresh()
        return
      }
      var left = result.parsed && Array.isArray(result.parsed.incomplete) ? result.parsed.incomplete : []
      view.incomplete = left
      if (left.length > 0) {
        // Stop. The plugin is the only way back to this view, and removing it
        // while part of the system half is still installed would leave a
        // machine with no way to finish the job (plan-gui.md §7.1 step 2).
        view.phase = "incomplete"
        view.note = ""
        panel.refresh()
        return
      }
      view.phase = "done"
      view.note = ""
      view.armed = true
      panel.refresh()
    })
  }

  // Step 4. One command, detached, and the only thing in this plugin besides
  // `omarchy-face-lock stage` that writes ~/.config/omarchy/plugins.
  //
  // `--yes` is not optional: `omarchy plugin remove` has no tty here, and
  // without it `confirm` *fails* rather than prompting
  // (omarchy-plugin-remove:18-30).
  //
  // The last `rm -rf` clears every dot entry Face leaves in that folder: the
  // `.graveklar.face.bak.<ts>` copy `plugin remove` makes of a plugin that is
  // not a git checkout (:105-115), and the `.graveklar.face-lock.old.*` /
  // `.graveklar.face-lock.XXXXXX` staging directories a `stage` interrupted
  // half way can leave behind. plan-engine.md §10.2 names only the first;
  // §10.3's checklist asserts `.graveklar.face*` is empty, which is the wider
  // glob, so this is the wider glob. Dot entries map to no plugin id
  // (PluginRegistry.qml:735), so none of this causes a second reload.
  //
  // The first line takes Face's two Omarchy hooks out (bin/omarchy-face-health),
  // before the plugin they call is gone. It is only tidiness, and it is ordered
  // first because it is the one line that writes nothing under the plugins
  // folder: a hook left behind by a step that did not run deletes itself the
  // first time it finds no plugin to call. The paths are arguments, never text
  // in the script, and they are the plugins folder's sibling `hooks` -- the same
  // derivation as everything else here, which is what keeps a harness running
  // this command against a throwaway folder away from this account's own hooks.
  readonly property string finalScript:
    'rm -f -- "$3" "$4"\n' +
    'rm -rf "$1"\n' +
    'omarchy plugin remove --yes graveklar.face\n' +
    'rm -rf "$2"/.graveklar.face*\n'

  // <config>/omarchy/hooks, beside <config>/omarchy/plugins.
  readonly property string hooksDir: {
    var cut = view.pluginsDir.lastIndexOf("/")
    return cut > 0 ? view.pluginsDir.substring(0, cut) + "/hooks" : ""
  }

  function finalArgv() {
    return ["setsid", "-f", "bash", "-c", view.finalScript, "_",
            view.pluginsDir + "/graveklar.face-lock", view.pluginsDir,
            view.hooksDir + "/post-update.d/graveklar-face.hook",
            view.hooksDir + "/post-boot.d/graveklar-face.hook"]
  }

  function runFinal() {
    if (view.finalRan || !view.armed || view.pluginsDir === "") return
    view.finalRan = true
    console.log("graveklar.face", "removal: final step, detached:", JSON.stringify(view.finalArgv()))
    Quickshell.execDetached(view.finalArgv())
  }

  // "On close" is the whole point: everything the user has to read is on screen
  // before this runs, and what this does is close the window.
  Connections {
    target: view.panel
    enabled: view.panel !== null
    function onOpenedChanged() { if (view.panel && !view.panel.opened) view.runFinal() }
  }

  // And on the way out of the view, which is the other way a person leaves a
  // finished removal: Esc from here pops back to Settings rather than closing
  // the popup, and the view stack's Loader takes this item with it. Without
  // this, the step the result promised would simply not happen -- the system
  // half gone, the plugin still on the bar, and nothing on screen to say so.
  //
  // Only with the popup OPEN, which is the whole of the difference between
  // "they read the result and left this page" and "this item went away with the
  // window". The second one includes the shell shutting down with a purge that
  // finished behind a closed popup -- and that case must NOT delete the plugin:
  // nobody has seen a result, and the view that opens next is what offers the
  // step that is left (plan-merged.md §4 phase 8, clause 2).
  Component.onDestruction: if (view.panel && view.panel.opened) view.runFinal()

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(6)

  // --- what would go ----------------------------------------------------------

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.phase === "idle" && !view.nothingLeft
    text: "This takes Face off this machine:"
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Repeater {
    model: view.phase === "idle" ? view.lines : []

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

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.phase === "idle" && view.nothingLeft
    text: view.removal
          ? "Face's system files are already gone; only this plugin is left."
          : "Face is not set up on this machine, so there is nothing to take off it."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
  }

  // The engine is the only thing here that costs half an hour to put back, so
  // it is the only thing offered a reprieve. Unticked: scope says removal
  // removes everything unless asked otherwise.
  Toggle {
    width: parent.width
    visible: view.phase === "idle" && !view.nothingLeft
             && view.removal && Array.isArray(view.removal.packages)
             && view.removal.packages.length > 0
    label: "Keep the face engine installed"
    description: "Leaves howdy and dlib on the machine, so setting Face up again does not "
                 + "rebuild them. Everything else goes either way."
    checked: view.keepPackages
    enabled: !view.busy
    foreground: view.foreground
    fontFamily: view.fontFamily
    onClicked: view.keepPackages = !view.keepPackages
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.phase === "idle"
    topPadding: Style.space(2)
    text: "Your password is asked for once. The last step closes this window and takes Face's "
          + "button off the bar; everything you need to read is on screen before it."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // --- the buttons ------------------------------------------------------------

  Row {
    width: parent.width
    spacing: Style.space(8)
    visible: view.phase === "idle" || view.phase === "incomplete" || view.phase === "stopped"

    Button {
      text: view.actionLabel
      bordered: true
      enabled: !view.busy
      foreground: view.foreground
      fontFamily: view.fontFamily
      fontSize: Style.font.caption
      onClicked: {
        // With the system half already gone there is nothing to prompt for:
        // what is left is the two plugin folders, and that is step 4 on its own.
        if (view.phase === "idle" && view.nothingLeft) {
          view.armed = true
          view.panel.close()
          return
        }
        view.start()
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.busy
    text: view.phase === "disabling"
          ? "Taking face off the lock screen…"
          : "Removing Face's system files…"
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // --- the result -------------------------------------------------------------
  //
  // On screen BEFORE anything writes the plugins folder. That ordering is the
  // phase-8 gate's first clause, and it is why step 4 is a separate step at all.

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.phase === "done"
    text: "Removed. Your password is what unlocks sudo again. The bar button disappears when "
          + "you close this."
    color: view.foreground
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.phase === "done" && view.keepPackages
    text: "The face engine is still installed."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Button {
    visible: view.phase === "done"
    text: "Close"
    bordered: true
    foreground: view.foreground
    fontFamily: view.fontFamily
    fontSize: Style.font.caption
    onClicked: if (view.panel) view.panel.close()
  }

  // A non-empty `incomplete` is the one outcome that must not end in the plugin
  // being deleted: whatever is listed here needs this view again.
  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.phase === "incomplete"
    text: "Face's system files are partly still here, so the plugin has been left in place — "
          + "it is the only way back to this page. Still on the machine:"
    color: Color.urgent
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Repeater {
    model: view.phase === "incomplete" ? view.incomplete : []

    Text {
      required property var modelData
      textFormat: Text.PlainText
      width: view.width
      text: "· " + String(modelData)
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.note !== ""
    topPadding: Style.space(2)
    text: view.note
    color: Color.urgent
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
