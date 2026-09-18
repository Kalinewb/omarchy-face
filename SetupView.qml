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
// buttons: purge-legacy, the first install, and the system-file update. Phase 3
// adds `engine`, which is the one row that is not a single state: it carries the
// build job's step list, its elapsed time and a tail of its log. Phase 5 wires
// `sudo`'s two repairs and phase 7 the lock screen's three. A row whose verb is
// not built yet renders its state and no button: a Fix that cannot fix anything
// is worse than no Fix at all.
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

  // --- what this view is for, right now (post-ship revision, plan-gui.md §4) --
  //
  // Setup was a permanent checklist: nine rows, each with its own state, on
  // screen for ever on a machine where every one of them said `ok`. Two things
  // came out of using it. A list that always asks for attention stops being
  // read, so the day one row DOES need something it is a row in a list nobody
  // looks at any more. And the install was two buttons -- system files, then the
  // engine -- for something that was never two decisions: the first install
  // starts the build itself (plan-engine.md §5.1), so pressing the first one and
  // watching a build begin looked like something had happened that nobody asked
  // for.
  //
  // So the view has three presentations, and picks by what is true:
  //
  //   firstRun  nothing is installed (or the engine is still to build): ONE
  //             action, with the whole sequence named before it is pressed, and
  //             the build's own step list underneath it
  //   calm      everything Setup covers is `ok` and nothing is happening: one
  //             line saying so, and where a face is accepted
  //   detail    anything else, and anything at all on request: the checklist,
  //             exactly as it always was
  //
  // Nothing is hidden that is asking for something. `asking` below is the rule,
  // and it is deliberately wider than `panel.setupNeeded`: that one answers the
  // bar button's question ("is this machine set up"), and a `lock` row with a
  // repair on it is not that, but it is still somebody having to do something.
  // `!!` rather than a ternary: a host that does not carry these at all -- the
  // offscreen gates put a stand-in panel in front of this view -- must fall back
  // to the checklist, not to an unassignable undefined.
  readonly property bool setupNeeded: !!(panel && panel.setupNeeded)
  readonly property bool attention: !!(panel && panel.attention)

  // A row that wants a decision. `sudo` is excluded: it is a switch whose home
  // is Settings, its position is named in the calm summary below, and a machine
  // whose owner has deliberately left it off must not be nagged by Setup for
  // ever because of it. `install-job` never renders as a row at all.
  readonly property bool asking: {
    for (var i = 0; i < view.rows.length; i++) {
      var r = view.rows[i]
      if (!r || r.id === "install-job" || r.id === "sudo") continue
      if (String(r.state) === "broken") return true
      if (String(r.state) !== "ok" && !!r.fixable) return true
    }
    return false
  }

  // Something is happening, or the last click has something to say.
  readonly property bool working: view.busyRow !== "" || view.buildShown || view.noteText !== ""

  readonly property bool calm: !!panel && !!panel.status && view.rows.length > 0
                               && !view.setupNeeded && !view.attention
                               && !view.asking && !view.working

  // The row the one-button path is about: the first install, or -- once that has
  // landed -- the engine build it chains into.
  readonly property var primaryRow: {
    if (!panel || !panel.status || view.legacyBlocking) return null
    // With no infrared camera the engine hides every other row (plan-gui.md §4
    // row 2); there is nothing to install for, and the camera row says so.
    var camera = panel.row("camera")
    if (!camera || String(camera.state) !== "ok") return null
    var system = panel.row("system")
    if (system && String(system.fix) === "install-first") return system
    if (!system || String(system.state) !== "ok") return null
    var engine = panel.row("engine")
    if (engine && String(engine.state) !== "ok") return engine
    return null
  }

  readonly property bool firstRun: view.primaryRow !== null

  // Bindings inside an invisible item still evaluate, so the block below reads
  // the primary row through these rather than dereferencing a null.
  readonly property string primaryFix: view.primaryRow ? String(view.primaryRow.fix || "") : ""
  readonly property string primaryId: view.primaryRow ? String(view.primaryRow.id || "") : ""

  // The label on the one button. While a build runs there is none: the row is
  // already showing the build, and `install-engine` would answer exit 3.
  readonly property string primaryLabel: {
    if (!view.primaryRow) return ""
    if (view.busyRow === String(view.primaryRow.id)) return "Working…"
    if (view.buildRunning) return ""
    if (String(view.primaryRow.fix || "") === "install-first") return "Copy the install command"
    return view.fixLabel(view.primaryRow)
  }

  // The checklist is shown when it has something to say, and on request. Asked
  // for by the person rather than pushed at them is the whole difference
  // between a disclosure and a nag.
  property bool detailsShown: false
  readonly property bool collapsible: view.calm || view.firstRun
  readonly property bool rowsShown: !view.collapsible || view.detailsShown

  // A machine that was calm and has stopped being calm must not still be hiding
  // its rows behind a disclosure somebody opened and closed a week ago.
  onCollapsibleChanged: if (!view.collapsible) view.detailsShown = false

  // --- the calm summary -------------------------------------------------------

  readonly property var store: panel && panel.people ? panel.people : ({})
  readonly property int sudoFaces: store && typeof store.sudo_faces === "number" ? store.sudo_faces : 0
  readonly property var config: panel && panel.config ? panel.config : ({})

  readonly property int peopleCount: view.store && Array.isArray(view.store.people)
                                     ? view.store.people.length : -1

  readonly property string calmDetail: {
    var line = "Camera, system files and engine are in place"
    // The count from the store, because the `people` row's own detail is a
    // fragment ("1 on this machine") that reads as one when it is appended to a
    // sentence. The row's wording is still the fallback: it is the engine's
    // answer, and a store that has not been read yet has none of its own.
    if (view.peopleCount >= 0)
      return line + " · " + (view.peopleCount === 1 ? "1 person recorded"
                                                    : view.peopleCount + " people recorded") + "."
    var people = panel ? panel.row("people") : null
    var known = people ? String(people.detail || "") : ""
    return line + (known !== "" ? " · " + known : "") + "."
  }

  // Where a face is accepted, said in the calm state because it is the one thing
  // the rows above no longer say and the only thing left that could surprise
  // somebody: a machine that is set up and accepts a face nowhere is a normal
  // machine, not a broken one, and this is where that is admitted.
  readonly property string calmWhere: {
    var sudo = view.config.sudo === true && view.sudoFaces > 0
    var lock = view.config.lock === true
    if (!sudo && !lock) return "No face is accepted anywhere yet — Settings is where that is turned on."
    var parts = []
    if (sudo) parts.push(view.sudoFaces === 1 ? "1 face can approve sudo"
                                              : view.sudoFaces + " faces can approve sudo")
    if (lock) parts.push("a face unlocks the lock screen")
    return parts.join(" · ") + "."
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  function fixLabel(row) {
    if (!row || !row.fixable) return ""
    if (row.fix === "purge-legacy") return "Remove the old install"
    // Not "Install Face's system files": that is what the verb does, not what
    // the person is asking for, and it read as the first of two optional steps
    // when it is in fact the whole install -- it starts the engine build itself
    // (post-ship revision).
    if (row.fix === "install-first") return "Copy the install command"
    if (row.fix === "install-system") return "Copy the update command"
    if (row.fix === "install-engine") {
      // While a build runs there is no button at all. `install-engine` would
      // exit 3, and the row is already showing the build that is happening.
      if (view.buildRunning) return ""
      // One verb, two buttons: after a failure the honest word is the one the
      // user is about to do, not the one they did before it failed.
      return view.buildState === "failed" ? "Try again" : "Build the face engine"
    }
    // The sudo row's own switch lives in Settings; here it is a repair, and the
    // words say which way it goes rather than "Fix" (plan-gui.md §4 row 6).
    if (row.fix === "sudo-on") return "Turn on Face for sudo"
    if (row.fix === "sudo-off") return "Turn off Face for sudo"
    // The three lock-screen repairs (plan-gui.md §4 row 8). Two of them write
    // the plugins folder and say so before the click, in the row itself.
    if (row.fix === "lock-stage") return "Finish lock screen setup"
    if (row.fix === "lock-enable") return "Put face back on the lock screen"
    if (row.fix === "lock-sync") return "Finish the update"
    return ""
  }

  // --- the engine build (plan-gui.md §4 row 4) ------------------------------
  //
  // Everything below reads the job's own files. Nothing here owns the build, so
  // closing the popup, or restarting the shell, loses nothing: the row comes
  // back where the build has got to, because that is where it reads it from.

  readonly property var build: panel ? panel.installDoc : ({})
  readonly property string buildState: build && build.state ? String(build.state) : "idle"
  readonly property string buildStep: build && build.step ? String(build.step) : ""
  readonly property string buildError: build && build.error ? String(build.error) : ""
  readonly property var buildSteps: build && Array.isArray(build.steps) && build.steps.length > 0
                                    ? build.steps
                                    : ["deps", "fetch", "build", "install", "configure", "done"]
  readonly property var buildNotes: build && Array.isArray(build.notes) ? build.notes : []
  readonly property bool buildRunning: buildState === "running"
  readonly property bool buildShown: buildRunning || buildState === "failed"

  // A clock of its own: elapsed time has to move while nothing else changes,
  // and install.json is only rewritten when a step does.
  property int tick: 0
  readonly property int nowSeconds: { view.tick; return Math.floor(Date.now() / 1000) }

  property string logTail: ""
  property bool logExpanded: false
  property bool logBusy: false

  // Seconds as a person reads them. Never a percentage: the plan is explicit
  // that a build reports elapsed time per step, because nothing here can know
  // how long a compile has left (plan-engine.md §5.2).
  function elapsedText(seconds) {
    if (!(seconds > 0)) return ""
    var s = Math.floor(seconds)
    if (s < 60) return s + "s"
    var m = Math.floor(s / 60)
    if (m < 60) return m + "m " + ("0" + (s % 60)).slice(-2) + "s"
    return Math.floor(m / 60) + "h " + ("0" + (m % 60)).slice(-2) + "m"
  }

  function stepIndex(name) {
    for (var i = 0; i < view.buildSteps.length; i++)
      if (String(view.buildSteps[i]) === String(name)) return i
    return -1
  }

  // ✓ done · → running · · not started yet. A step list that only ever grows
  // forwards, which is what the fixed `steps` array is for.
  function stepMark(index) {
    var current = view.stepIndex(view.buildStep)
    if (view.buildState === "done") return "✓"
    if (current < 0) return index === 0 && view.buildRunning ? "→" : "·"
    if (index < current) return "✓"
    if (index > current) return "·"
    return view.buildState === "failed" ? "✗" : "→"
  }

  function readLog() {
    if (!panel || view.logBusy) return
    view.logBusy = true
    panel.ask.ask(panel.ask.installLogArgv(), "", function (result) {
      view.logBusy = false
      // The helper exits 0 with an empty log before the first line is written;
      // that is not a failure, it is a build that has not said anything yet.
      view.logTail = result.ok ? String(result.stdout || "") : ""
    })
  }

  // A failure is the one state where the tail is worth reading without asking
  // for it, so it opens itself (plan-gui.md §4 row 4).
  onBuildStateChanged: {
    if (view.buildState === "failed") { view.logExpanded = true; view.readLog() }
    if (view.buildState === "idle" || view.buildState === "done") view.logTail = ""
  }

  Timer {
    interval: 1000
    repeat: true
    running: view.buildShown
    onTriggered: {
      view.tick = view.tick + 1
      // The log is re-read every two seconds, and only while somebody is
      // looking at it: it is a subprocess per read.
      if (view.logExpanded && (view.tick % 2) === 0) view.readLog()
    }
  }

  // What went wrong, in the words the user has to act on. `owner_declined` is
  // its own case because nothing happened at all -- the dialog was dismissed,
  // and the row is exactly as it was.
  function outcomeText(result, row) {
    if (result.outcome === "owner_declined") return "Not authorised — nothing changed."
    // Exit 3 is "the store or the install job is held" (plan-merged.md §2 rule
    // 3). On the engine row there is only one thing it can be, and saying which
    // is the difference between "try again" and "it is already happening".
    if (result.outcome === "busy" && row && row.id === "engine")
      return "The engine is already building."
    if (result.outcome === "busy") return "Face is busy with something else — try again in a moment."
    if (result.outcome === "missing") return "Face's helpers are not installed."
    var code = result.parsed && result.parsed.error ? String(result.parsed.error) : "it did not say why"
    if (code === "version_mismatch")
      return "The installed system files do not match this plugin version — reinstall the plugin."
    if (code === "snapshot_modified" || code === "snapshot_incomplete" || code === "snapshot_unsafe")
      return "This plugin's system files are not the released ones, so nothing was installed — reinstall the plugin."
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
    if (code === "install_running") return "The engine is already building."
    // The sudo row's repair, in the words of plan-merged.md §2.3.
    if (code === "no_sudo_faces") return "Give someone Sudo first."
    if (code === "helper_unsafe")
      return "Face's own helpers in /usr/local/bin are not owned by root, or can be written by " +
             "somebody else — sudo will not be pointed at them."
    if (code === "pam_edit_failed")
      return "/etc/pam.d/sudo is not the shape Face wrote, so it was left exactly as it is."
    if (code === "start_failed")
      return "The engine build could not be started — systemd would not take the job."
    // The lock screen's own refusals (plan-merged.md §2.5).
    if (code === "locked")
      return "Nothing is changed behind a lock screen — unlock the session and try again."
    if (code === "not_staged") return "The lock screen files are not in place — use Finish lock screen setup."
    if (code === "no_template") return "This plugin is missing its lock screen files — reinstall it."
    if (code === "validate_failed") return "Face's lock screen files did not pass Omarchy's plugin check."
    if (code === "other_lock") {
      var other = result.parsed && result.parsed.id ? String(result.parsed.id) : "another plugin"
      return "Another lock screen plugin (" + other + ") is in use."
    }
    if (code === "enable_failed")
      return "Face's lock screen did not start, so Omarchy's is back — nothing changed."
    return "It did not work: " + code + "."
  }

  // Why a build stopped, in the same voice. The engine's codes are words, not
  // sentences, because the sentence belongs to whichever surface shows them.
  function buildErrorText(code) {
    if (code === "cuda_flag_missing")
      return "dlib's build file no longer has the switch that turns CUDA off, and Face will not " +
             "pull in a graphics toolkit behind your back. This needs a look at the package."
    if (code === "cuda_in_package")
      return "The dlib that was built still wants CUDA, so it was not installed."
    // The pin is the point: a new revision of these packages is a change to
    // what runs as root here, so it waits for a version of Face that has read
    // it rather than being picked up silently.
    if (code === "pkgbuild_changed")
      return "howdy or dlib has been updated in the Arch User Repository since this version of " +
             "Face was built against it. Face only builds the revisions it was tested with, so " +
             "this needs a newer Face."
    if (code === "systemd_unreachable")
      return "systemd did not answer, and Face will not start a build it could not stop."
    if (code === "pacman_locked")
      return "Another package manager is running. Let it finish and try again."
    if (code === "deps_failed") return "The packages the build needs could not be installed."
    if (code === "fetch_failed") return "The build files could not be downloaded."
    if (code === "dlib_build_failed" || code === "howdy_build_failed")
      return "The build did not finish. The log below says where it stopped."
    if (code === "build_user_failed")
      return "The build could not run as its own user. The log below says why."
    if (code === "dlib_install_failed" || code === "howdy_install_failed")
      return "The built packages could not be installed."
    if (code === "no_ir_camera") return "The infrared camera could not be found."
    if (code === "howdy_config_missing" || code === "config_key_missing")
      return "The engine was installed but could not be configured for this camera."
    if (code === "interrupted") return "The build was stopped before it finished."
    if (code === "start_failed") return "The build could not be started."
    return "The build stopped: " + code + "."
  }

  function runFix(row) {
    if (!panel || view.busyRow !== "") return
    var argv = null
    if (row.fix === "purge-legacy") {
      argv = panel.ask.adminArgv(["purge-legacy"])
    } else if (row.fix === "install-engine") {
      argv = panel.ask.adminArgv(["install-engine"])
    } else if (row.fix === "sudo-on" || row.fix === "sudo-off") {
      argv = panel.ask.adminArgv([String(row.fix)])
    } else if (row.fix === "lock-stage") {
      argv = panel.ask.lockArgv(["stage"])
    } else if (row.fix === "lock-enable") {
      argv = panel.ask.lockArgv(["enable"])
    } else if (row.fix === "lock-sync") {
      argv = panel.ask.lockArgv(["sync"])
    } else if (row.fix === "install-first" || row.fix === "install-system") {
      // Not an install: the system half is installed from a terminal, with the
      // command this copies. The panel never runs it -- it has no root of its
      // own to run it with until that command has run once (Ask.qml).
      view.noteRow = row.id
      view.noteText = "Copying the command…"
      // Only say it is on the clipboard once wl-copy says so. Claiming it
      // before the call returns means a missing wl-copy still reads "copied",
      // and the next thing the owner does is paste whatever was there before
      // into a root shell.
      panel.ask.ask(panel.ask.installCopyArgv(), panel.ask.installCommand, function (result) {
        if (view.noteRow !== row.id) return
        view.noteText = result && result.ok
          ? "Command copied. Paste it into a terminal, then come back here."
          : "The command could not be copied — wl-copy did not run. It is in Face's README, under \"Installing or updating the system files\"."
      })
      return
    }
    if (!argv) return

    view.busyRow = row.id
    view.noteRow = row.id
    view.noteText = "Working…"
    panel.ask.ask(argv, "", function (result) {
      view.busyRow = ""
      view.noteRow = row.id
      view.noteText = result.ok ? "" : view.outcomeText(result, row)
      // A started build answers immediately and then takes half an hour, so the
      // row has to switch to the step list without waiting for the next status
      // read (up to 30 s away).
      if (result.ok && (row.fix === "install-engine" || row.fix === "install-first")) {
        view.logTail = ""
        panel.reloadWatched()
      }
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
        return "Face ID cannot read its own status: the plugin's bin/omarchy-face-status is missing."
      if (view.panel.statusOutcome === "ok") return "The engine answered, but sent no rows."
      return "Face ID could not read its own status (" + view.panel.statusOutcome + ")."
    }
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
  }

  // --- calm: everything Setup covers is in place ------------------------------
  //
  // One row's worth of shape -- the good dot, a line, a detail -- standing for
  // nine rows that all say `ok`. It is not a summary the view invents: every
  // part of it is read from the same status document the rows are, and the
  // moment any of them stops being `ok` this block goes and they come back.

  Column {
    width: parent.width
    visible: view.calm && !view.detailsShown
    spacing: Style.space(2)

    Row {
      width: parent.width
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: "●"
        color: view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width - Style.space(22)
        text: "Face ID is set up."
        color: view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      leftPadding: Style.space(22)
      text: view.calmDetail
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      leftPadding: Style.space(22)
      text: view.calmWhere
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // --- firstRun: the one action that installs Face ----------------------------

  Column {
    width: parent.width
    visible: view.firstRun && !view.detailsShown
    spacing: Style.space(6)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: view.primaryFix === "install-first"
            ? "Face ID is not installed on this machine yet."
            : "Face's system files are in place. The engine is what is left."
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }

    // The whole sequence, before the click rather than discovered during it.
    // "and then starts building" is the sentence whose absence made a build look
    // like something that happened by itself.
    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: view.primaryFix === "install-first"
      text: "One command, copied by the button below and run in a terminal, installs Face's "
            + "helpers, its service and its polkit "
            + "policy, and then starts building the face engine — howdy and dlib from the Arch "
            + "User Repository, at the two revisions this version of Face was tested against, "
            + "installed with pacman. The build takes several minutes, needs nothing from you "
            + "once it starts, and this view shows how it is going."
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: view.primaryFix === "install-engine" && !view.buildShown
      text: "Face builds its engine — howdy and dlib — from the Arch User Repository, at the two "
            + "revisions this version of Face was tested against, and installs them with pacman. "
            + "It takes several minutes and runs without a graphics toolkit."
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // The one dialog Face cannot put its own message on (plan-gui.md §4 row 3),
    // said here for the same reason it was said in the row: a generic "run
    // /bin/bash as the super user" that arrives unexplained is exactly the
    // prompt people are told never to approve.
    Text {
      textFormat: Text.StyledText
      width: parent.width
      visible: view.primaryFix === "install-first"
      text: "This panel does not install anything as root. The button copies a command for you "
            + "to run: it checks the installer against a checksum <b>fetched from this release</b> "
            + "before running it, so nothing a program could have changed in your plugin folder "
            + "is ever run as root. The command itself comes from this panel — if you have reason "
            + "to doubt this machine, compare it with the one in Face's README on GitHub."
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // The build, where it has always been -- under the action it belongs to,
    // with its step list, its clock and its log. It is the reason the engine is
    // still allowed a step of its own: a compile that takes minutes has to be
    // able to say where it has got to (plan-gui.md §4 row 4).
    Loader {
      width: parent.width
      active: view.buildShown
      visible: active
      sourceComponent: buildComponent
    }

    Button {
      visible: view.primaryLabel !== ""
      text: view.primaryLabel
      bordered: true
      enabled: view.busyRow === ""
      foreground: view.foreground
      fontFamily: view.fontFamily
      onClicked: view.runFix(view.primaryRow)
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: view.noteText !== "" && view.noteRow === view.primaryId
      text: view.noteText
      color: Color.urgent
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // The disclosure. Only where something is actually folded away: in the states
  // that show every row there is nothing behind it, and a control that opens
  // nothing is a control that lies.
  Text {
    textFormat: Text.PlainText
    visible: view.collapsible
    topPadding: Style.space(2)
    text: view.detailsShown ? "▾ Hide details" : "▸ Show details"
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: view.detailsShown = !view.detailsShown
    }
  }

  Repeater {
    model: view.rows

    Column {
      id: rowItem
      required property var modelData

      // `legacy` is a row about something that is not there on a healthy
      // machine, so it renders only when it has something to report
      // (plan-gui.md §4 row 1). `install-job` never renders as a row of its own:
      // the GUI shows it inside `engine` (plan-merged.md §1 row 3), and two
      // lines saying the same thing about one build is one line too many. The
      // engine still sends it, and the bar widget still lights on it being
      // broken (plan-gui.md §3).
      readonly property bool hidden: (modelData.id === "legacy" && modelData.state === "ok")
                                     || modelData.id === "install-job"
      // Below an unresolved `legacy`, every other row is dimmed: they were
      // computed on a machine that still has the old install on it.
      readonly property bool stale: view.legacyBlocking && modelData.id !== "legacy"
      readonly property string fixText: view.fixLabel(modelData)

      // `rowsShown` is the post-ship collapse: the checklist renders when it has
      // something to ask for and when somebody asks to see it, and not on a
      // machine where all nine rows say `ok`. An invisible child is out of the
      // Column's layout entirely, so a hidden checklist costs no space.
      //
      // A property rather than the expression alone, because `visible` is the
      // EFFECTIVE one -- an item in a harness with no window is never visible,
      // whatever it decided -- and the gate has to be able to ask what this row
      // decided (dev/g8-post-ship.sh).
      readonly property bool rendered: !hidden && view.rowsShown

      visible: rendered
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
        text: "Installed from a terminal with the command this row copies, which checks the " +
              "installer against a checksum <b>fetched from this release</b> before running it " +
              "as root. The install then starts the engine build by itself."
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      // What the build actually is, said before it is asked for rather than
      // discovered in the log. It compiles two packages off the Arch User
      // Repository and installs them as root, which is a thing to know about a
      // button, and it takes long enough that "nothing is happening" is the
      // wrong conclusion to leave available.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: !rowItem.stale && rowItem.modelData.id === "engine"
                 && (rowItem.fixText !== "" || view.buildRunning)
        wrapMode: Text.WordWrap
        leftPadding: Style.space(22)
        text: "Face builds its engine — howdy and dlib — from the Arch User Repository, at the two " +
              "revisions this version of Face was tested against, and installs them with pacman. " +
              "It takes several minutes and runs without a graphics toolkit."
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      // The two lock-screen fixes that write ~/.config/omarchy/plugins, and
      // therefore close this popup (E13). Said BEFORE the click, in the row, so
      // the window disappearing is something the person chose rather than
      // something that happened to them.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: !rowItem.stale && rowItem.modelData.fix === "lock-stage"
        wrapMode: Text.WordWrap
        leftPadding: Style.space(22)
        text: "This puts Face's lock screen files in place. Face will close and reopen — "
              + "open it again from the bar. Your lock screen is not changed by it; "
              + "switching face on there is a separate step, in Settings."
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: !rowItem.stale && rowItem.modelData.fix === "lock-sync"
        wrapMode: Text.WordWrap
        leftPadding: Style.space(22)
        text: "The shell will restart to pick this up; you stay logged in and nothing else "
              + "closes. Face will close and reopen — open it again from the bar."
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      // The build, folded into the row it belongs to. A Loader, so eight rows
      // that are not the engine carry none of it.
      Loader {
        width: parent.width
        active: rowItem.modelData.id === "engine" && view.buildShown && !rowItem.stale
        visible: active
        sourceComponent: buildComponent
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

  // The engine build, as the Setup view shows it (plan-gui.md §4 row 4): the
  // fixed step list with a mark and the elapsed time, whatever the job left in
  // `notes`, the reason if it failed, and a collapsed tail of the build log.
  //
  // Not a progress bar. Nothing in a compile can say how much is left, and a bar
  // that creeps to 90% and stops there for twenty minutes is a worse answer than
  // the truth, which is a step name and a clock.
  Component {
    id: buildComponent

    Column {
      width: parent ? parent.width : 0
      leftPadding: Style.space(22)
      topPadding: Style.space(2)
      bottomPadding: Style.space(4)
      spacing: Style.space(3)

      Text {
        textFormat: Text.PlainText
        width: parent.width - Style.space(22)
        visible: view.buildRunning
        // Total elapsed, from when the owner asked -- install.json's `startedAt`
        // is written by the verb that started the job, not by the job.
        text: {
          var started = Number(view.build.startedAt || 0)
          var total = started > 0 ? view.nowSeconds - started : 0
          return "Building — " + (view.elapsedText(total) || "just started")
        }
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: view.buildSteps

        Text {
          required property var modelData
          required property int index

          textFormat: Text.PlainText
          width: parent.width - Style.space(22)
          // The step that is happening carries a clock of its own, from the
          // last time the job wrote a line. The finished ones carry nothing:
          // install.json keeps one `updatedAt`, so a per-step time for them
          // would be invented rather than measured.
          text: {
            var mark = view.stepMark(index)
            var line = mark + "  " + String(modelData)
            if (mark !== "→") return line
            var updated = Number(view.build.updatedAt || 0)
            var seconds = updated > 0 ? view.nowSeconds - updated : 0
            var elapsed = view.elapsedText(seconds)
            return elapsed === "" ? line : line + "   " + elapsed
          }
          color: view.stepMark(index) === "·" ? view.dim
               : view.stepMark(index) === "✗" ? Color.urgent
               : view.foreground
          opacity: view.stepMark(index) === "·" ? 0.6 : 1
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // Anything the job decided was worth saying out loud -- a kept package, a
      // polkit drop-in it had to take back out.
      Repeater {
        model: view.buildNotes

        Text {
          required property var modelData
          textFormat: Text.PlainText
          width: parent.width - Style.space(22)
          text: "· " + String(modelData)
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width - Style.space(22)
        visible: view.buildState === "failed"
        topPadding: Style.space(2)
        text: view.buildErrorText(view.buildError)
        color: Color.urgent
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // The log is a build's output: thousands of lines of compiler noise, and
      // exactly what somebody needs when it stops. Collapsed while it is going
      // well, open on a failure (plan-gui.md §4 row 4).
      Text {
        textFormat: Text.PlainText
        topPadding: Style.space(2)
        text: view.logExpanded ? "▾ Build log" : "▸ Build log"
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            view.logExpanded = !view.logExpanded
            if (view.logExpanded) view.readLog()
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width - Style.space(22)
        visible: view.logExpanded
        text: view.logTail.trim() === "" ? "(nothing in the log yet)" : view.logTail.trim()
        color: view.dim
        // The bar's family is already the monospace one the shell resolves
        // (`Style.fontFamily` defaults to "monospace"), so the tail lines up
        // without this view naming a font of its own.
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        // No wrapping: a wrapped build log is unreadable, and the panel already
        // flicks sideways for nothing else.
        elide: Text.ElideRight
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
