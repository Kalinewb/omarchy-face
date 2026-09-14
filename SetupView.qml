import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Setup: one row per thing that has to be true before a face can approve
// anything. The ids, their order and their meanings are the engine's
// (plan-engine.md §10.1, plan-merged.md §1 row 3) -- this view renders what
// `omarchy-face-status` sends and invents nothing.
//
// Phase 2 makes `legacy`, `camera` and `system` real, which means their Fix
// buttons: purge-legacy, the first install, and the system-file update. The
// other rows render their state and no button, because the verbs behind them
// answer not_implemented until their own phase -- a Fix that cannot fix
// anything is worse than no Fix at all.
Column {
  id: view

  property var panel: null

  readonly property color foreground: panel ? panel.foreground : Color.foreground
  readonly property color dim: panel ? panel.dim : Color.muted
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property var rows: panel ? panel.rows : []

  // The row a Fix is running for, and the last thing a Fix said. One message at
  // a time, next to the row it belongs to: a list of stale outcomes from
  // earlier clicks is not something anybody reads.
  property string busyRow: ""
  property string noteRow: ""
  property string noteText: ""

  // `legacy` gates the rest: nothing below it can be trusted while the old
  // install is still on the machine (plan-gui.md §4 row 1).
  readonly property bool legacyBlocking: {
    var row = panel ? panel.row("legacy") : null
    return !!row && String(row.state) !== "ok"
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  // The installer is read from disk rather than embedded here, and it is passed
  // to pkexec as text (plan-engine.md §5.1). preload, because the read has to
  // have happened by the time somebody clicks.
  FileView {
    id: installScript
    path: panel ? panel.pluginDir + "/system/install.sh" : ""
    preload: true
    // Blocking, because the one caller reads it inside a click handler: an
    // installer that is "not there yet" for the first few hundred milliseconds
    // after the view opens would fail in exactly the way that reads as a
    // missing file.
    blockLoading: true
    printErrors: false
  }

  function fixLabel(row) {
    if (!row || !row.fixable) return ""
    if (row.fix === "purge-legacy") return "Remove the old install"
    if (row.fix === "install-first") return "Install Face's system files"
    if (row.fix === "install-system") return "Update Face system files"
    return ""
  }

  // What went wrong, in the words the user has to act on. `owner_declined` is
  // its own case because nothing happened at all -- the dialog was dismissed,
  // and the row is exactly as it was.
  function outcomeText(result) {
    if (result.outcome === "owner_declined") return "Not authorised — nothing changed."
    if (result.outcome === "busy") return "Face is busy with something else — try again in a moment."
    if (result.outcome === "missing") return "Face's helpers are not installed."
    var code = result.parsed && result.parsed.error ? String(result.parsed.error) : "it did not say why"
    if (code === "version_mismatch")
      return "The installed system files do not match this plugin version — reinstall the plugin."
    if (code === "not_owner") return "Face is set up for another account on this machine."
    // Face's own prompt authenticates whoever is asking, not an administrator,
    // so an account that cannot already become root must not be able to install
    // the helpers that sudo will run as root (plan-engine.md §8.2).
    if (code === "not_admin")
      return "Face can only be set up for an account that can already administer this machine."
    if (code === "install_dir_unsafe")
      return "/usr/local/bin is not owned by root, or is writable by others — Face will not install helpers there."
    if (code === "plugin_not_owned" || code === "plugin_missing" || code === "plugin_unsafe")
      return "Face could not read its own system files from the plugin folder."
    return "It did not work: " + code + "."
  }

  function runFix(row) {
    if (!panel || view.busyRow !== "") return
    var argv = null
    if (row.fix === "purge-legacy") {
      argv = panel.ask.adminArgv(["purge-legacy"])
    } else if (row.fix === "install-system") {
      argv = panel.ask.adminArgv(["install-system"])
    } else if (row.fix === "install-first") {
      var script = String(installScript.text() || "")
      if (script.trim() === "") {
        view.noteRow = row.id
        view.noteText = "The installer is missing from this plugin (system/install.sh)."
        return
      }
      argv = panel.ask.firstInstallArgv(script, panel.pluginDir,
                                        Quickshell.env("USER") || "")
    }
    if (!argv) return

    view.busyRow = row.id
    view.noteRow = row.id
    view.noteText = "Working…"
    panel.ask.ask(argv, "", function (result) {
      view.busyRow = ""
      view.noteRow = row.id
      view.noteText = result.ok ? "" : view.outcomeText(result)
      // Every fix changes something the status document reports, so the row is
      // re-read rather than assumed to have moved.
      panel.refresh()
    })
  }

  // Three things the popup can be showing, and they must never be confused:
  // an answer, no answer yet, and "there is nothing installed to answer".
  // A permanent "Checking…" is the failure plan-gui.md §2.3 names explicitly.
  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.rows.length === 0
    wrapMode: Text.WordWrap
    text: {
      if (!view.panel) return ""
      if (view.panel.statusOutcome === "") return "Checking…"
      if (view.panel.statusOutcome === "missing")
        return "Face Unlock cannot read its own status: the plugin's bin/omarchy-face-status is missing."
      if (view.panel.statusOutcome === "ok") return "The engine answered, but sent no rows."
      return "Face Unlock could not read its own status (" + view.panel.statusOutcome + ")."
    }
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
  }

  Repeater {
    model: view.rows

    Column {
      id: rowItem
      required property var modelData

      // `legacy` is a row about something that is not there on a healthy
      // machine, so it renders only when it has something to report
      // (plan-gui.md §4 row 1).
      readonly property bool hidden: modelData.id === "legacy" && modelData.state === "ok"
      // Below an unresolved `legacy`, every other row is dimmed: they were
      // computed on a machine that still has the old install on it.
      readonly property bool stale: view.legacyBlocking && modelData.id !== "legacy"
      readonly property string fixText: view.fixLabel(modelData)

      visible: !hidden
      width: view.width
      spacing: Style.space(4)
      topPadding: hidden ? 0 : Style.space(4)
      bottomPadding: hidden ? 0 : Style.space(4)

      Row {
        width: parent.width
        spacing: Style.space(10)

        // Tone, not decoration: `unknown` is never rendered as healthy
        // (plan-merged.md §2 rule 6), so it gets the dim dot, not the good one.
        Text {
          textFormat: Text.PlainText
          text: "●"
          color: rowItem.modelData.state === "ok" ? view.foreground
                 : rowItem.modelData.state === "unknown" ? view.dim
                 : Color.urgent
          opacity: rowItem.stale ? 0.45 : 1
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          width: parent.width - Style.space(22)
          spacing: 0
          opacity: rowItem.stale ? 0.45 : 1

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: String(rowItem.modelData.label || rowItem.modelData.id || "")
            color: view.foreground
            font.family: view.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            // The detail is the engine's sentence. Where it has none, the state
            // word is still better than an empty line: it says which of the
            // four states this row is in.
            text: {
              if (rowItem.stale) return "after the old install is removed"
              var detail = String(rowItem.modelData.detail || "")
              if (detail !== "") return detail
              return rowItem.modelData.state === "unknown" ? "could not be determined"
                                                           : String(rowItem.modelData.state || "")
            }
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }

      // The one dialog Face cannot put its own message on (plan-gui.md §4
      // row 3). It is shown BEFORE the click, not after: a generic "run
      // /bin/bash as the super user" that arrives unexplained is exactly the
      // prompt people are told never to approve.
      Text {
        textFormat: Text.StyledText
        width: parent.width
        visible: !rowItem.stale && rowItem.modelData.id === "system"
                 && rowItem.modelData.fix === "install-first"
        wrapMode: Text.WordWrap
        leftPadding: Style.space(22)
        text: "Your password dialog will say it wants to run <b>/bin/bash</b> as the super user. " +
              "That is this installer: Face's own helpers cannot ask with their own message until " +
              "they exist. It is the only time you will see that dialog."
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        leftPadding: Style.space(22)
        spacing: Style.space(8)
        visible: rowItem.fixText !== "" && !rowItem.stale

        Button {
          text: view.busyRow === rowItem.modelData.id ? "Working…" : rowItem.fixText
          bordered: true
          enabled: view.busyRow === ""
          foreground: view.foreground
          fontFamily: view.fontFamily
          fontSize: Style.font.caption
          onClicked: view.runFix(rowItem.modelData)
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        leftPadding: Style.space(22)
        visible: view.noteRow === rowItem.modelData.id && view.noteText !== ""
        text: view.noteText
        color: Color.urgent
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  // The shortcuts into the other views. They are here from phase 1 because the
  // view stack is what phase 1 delivers, and a stack with no way into it cannot
  // be tested.
  PanelSeparator {
    width: parent.width
    visible: view.rows.length > 0
    foreground: view.foreground
  }

  Row {
    width: parent.width
    spacing: Style.space(8)

    Repeater {
      model: [
        { view: "people",   label: "People" },
        { view: "settings", label: "Settings" },
        { view: "remove",   label: "Remove" }
      ]

      Button {
        required property var modelData
        text: modelData.label
        bordered: true
        foreground: view.foreground
        fontFamily: view.fontFamily
        fontSize: Style.font.caption
        onClicked: if (view.panel) view.panel.pushView(modelData.view)
      }
    }
  }
}
