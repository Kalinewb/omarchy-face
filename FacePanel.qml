import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "common"

// Face Unlock: the bar button and the popup behind it.
//
// This file owns the shell of the GUI -- the button, the view stack, the status
// document every view reads, and nothing else. Each view is its own file, and
// every call to the engine goes through common/Ask.qml, so the contract
// (plan-merged.md §2) is read in one place rather than re-stated per view.
//
// What must NOT happen here: a write under ~/.config/omarchy/plugins. Any write
// there reloads every plugin bar widget (plan-engine.md E13), which destroys
// this popup and everything it was driving. Exactly three flows in the finished
// plugin write that folder, each as its last step and each announced first
// (plan-gui.md §1); none of them is a routine action, and none of them is here.
Panel {
  id: root
  moduleName: "graveklar.face"
  ipcTarget: "graveklar.face"
  // The base class would install its own handler on that target; this file adds
  // open(view, name) and state(), so it registers the target itself.
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // This plugin's own directory, taken from where this file was loaded rather
  // than assembled from $HOME: the shell strips __sourceDir from third-party
  // manifests, and a hardcoded path is wrong the moment the plugin is checked
  // out anywhere else.
  // A URL is percent-encoded; a path is not. Without the decode, a checkout
  // under "~/Work/omarchy face" or a directory containing "#" hands the helper
  // argv a path with "%20" in it, which resolves to nothing at all -- and the
  // failure reads as "helper missing", the one diagnosis that sends you looking
  // in the wrong place.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url).replace(/\/+$/, "")
  }

  // --- state (plan-gui.md §2.3) -------------------------------------------

  // The whole engine → GUI read, exactly as §2.2 defines it. null until the
  // first answer; statusOutcome says why when it stays null.
  property var status: null
  property string statusOutcome: ""
  property bool statusBusy: false

  readonly property var rows: status && Array.isArray(status.rows) ? status.rows : []
  readonly property var config: status && status.config ? status.config : ({})
  readonly property var lockState: status && status.lock ? status.lock : ({})

  // A row by id, so a view can ask for "engine" without walking the array.
  function row(id) {
    for (var i = 0; i < rows.length; i++) if (rows[i] && rows[i].id === id) return rows[i]
    return null
  }

  function rowState(id) {
    var r = row(id)
    return r ? String(r.state || "unknown") : ""
  }

  // Read on open, after every write, and on a timer. `omarchy-face-status`
  // never prompts, never opens the camera and never needs root (§2 rule 1), so
  // polling it costs a subprocess and nothing else.
  function refresh() {
    if (root.statusBusy) return
    root.statusBusy = true
    engine.ask(engine.statusArgv(), "", function (result) {
      root.statusBusy = false
      root.statusOutcome = result.outcome
      if (result.outcome === "ok" && result.parsed && typeof result.parsed === "object") {
        root.status = result.parsed
        return
      }
      // Keep the last good document rather than blanking the views: a status
      // helper that fails once should not empty a popup someone is reading.
      if (result.outcome === "missing") root.status = null
      console.warn("graveklar.face", "status read failed:", result.outcome, result.code)
    })
  }

  // --- view stack (plan-gui.md §2.2) --------------------------------------

  // Profiles' stack: every view is reached from somewhere, and "back" means the
  // place it was opened from. Esc pops; Esc on the root view closes.
  property var viewStack: ["setup"]
  readonly property string view: viewStack[viewStack.length - 1]

  // Which person the person view is showing. Empty outside it.
  property string personName: ""

  function pushView(v) { viewStack = viewStack.concat([v]) }
  function popView() { if (viewStack.length > 1) viewStack = viewStack.slice(0, -1) }
  function resetView(v) { viewStack = [v] }

  function openPerson(name) {
    root.personName = String(name || "")
    root.pushView("person")
  }

  function navBack() {
    if (root.view === "person") root.personName = ""
    root.popView()
  }

  // Where each view says it is. A table rather than a ternary chain, so a view
  // that is not built yet still answers a lookup.
  readonly property var viewChrome: ({
    "setup":    { title: "Face Unlock",  meta: "What still needs doing",
                  hint: "esc closes" },
    "people":   { title: "People",       meta: "Who this machine knows",
                  hint: "esc closes · back returns to setup" },
    "person":   { title: "",             meta: "Appearances and permissions",
                  hint: "esc goes back" },
    "settings": { title: "Settings",     meta: "Where a face is accepted",
                  hint: "esc goes back" },
    "remove":   { title: "Remove Face",  meta: "What would be taken off this machine",
                  hint: "esc goes back" }
  })

  function chrome() {
    var c = root.viewChrome[root.view]
    return c ? c : { title: "Face Unlock", meta: "", hint: "" }
  }

  function viewTitle() {
    return root.view === "person" && root.personName !== "" ? root.personName : root.chrome().title
  }

  // --- the engine seam ----------------------------------------------------

  Ask {
    id: engine
    pluginDir: root.pluginDir
  }

  // Views reach the engine through the panel, so a view never has to know
  // whether it is talking to the real helpers or to dev/bin stubs.
  readonly property var ask: engine

  // --- watched files (plan-merged.md §2.6) --------------------------------

  // Both are written by same-directory temp + rename, which drops an inotify
  // watch on the old inode -- hence the reload timer beside watchChanges.
  // Overridable as a set for development: the stubs cannot write root-owned
  // paths, so a fixture directory stands in for them (dev/README.md).
  readonly property string stateDir: Quickshell.env("OMARCHY_FACE_DEV_STATE") || ""
  readonly property string peoplePath: (stateDir !== "" ? stateDir : "/var/lib/omarchy-face") + "/people.json"
  readonly property string installPath: (stateDir !== "" ? stateDir : "/run/omarchy-face") + "/install.json"

  property var people: null
  property var install: null

  // The raw text each parsed object came from. `reload()` re-emits `loaded`
  // whether or not the bytes changed, so without this the once-a-second reload
  // below hands every view a NEW object identity every second: a Repeater sees
  // a different model each tick and destroys and recreates every delegate.
  // Harmless for the Text rows here; once phase 4 puts a label field and an
  // appearance picker in these lists, it would swallow focus and typed text
  // once a second. So: keep the bytes, and only reassign when they differ.
  property string peopleRaw: ""
  property string installRaw: ""

  FileView {
    id: peopleFile
    path: root.peoplePath
    watchChanges: true
    // Absent is the normal state before Setup has run, and the reload timer
    // below asks again every second: left on, that is two journal warnings a
    // second for a file that is *supposed* not to exist yet.
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var raw = String(text())
      if (raw === root.peopleRaw) return
      root.peopleRaw = raw
      try { root.people = JSON.parse(raw) } catch (e) {
        console.warn("graveklar.face", "ignoring bad people.json", root.peoplePath, e)
      }
    }
    // Absent is the normal state before Setup has run; it is not a warning.
    onLoadFailed: { root.peopleRaw = ""; root.people = null }
  }

  FileView {
    id: installFile
    path: root.installPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var raw = String(text())
      if (raw === root.installRaw) return
      root.installRaw = raw
      try { root.install = JSON.parse(raw) } catch (e) {
        console.warn("graveklar.face", "ignoring bad install.json", root.installPath, e)
      }
    }
    onLoadFailed: { root.installRaw = ""; root.install = null }
  }

  Timer {
    // While the popup is open the two watched files are re-read every second,
    // because an atomic rename leaves watchChanges pointing at an inode nobody
    // writes to again.
    interval: 1000
    repeat: true
    running: root.opened
    onTriggered: { peopleFile.reload(); installFile.reload() }
  }

  Timer {
    // One cadence for both states: §2.3 asks for 30 s while open and a 30 s
    // probe while closed, and the bar button needs an answer either way.
    interval: 30000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: if (opened) {
    root.refresh()
    peopleFile.reload()
    installFile.reload()
    console.log("graveklar.face", "popup opened on view", root.view)
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  } else {
    console.log("graveklar.face", "popup closed")
  }

  IpcHandler {
    target: root.ipcTarget

    function show(): void { root.open() }
    function hide(): void { root.close() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }

    // open(view, name): how the recording card comes back to the popup when a
    // session commits (plan-gui.md §1).
    //
    // BOTH arguments must be passed. Quickshell enforces arity strictly, so
    // `omarchy-shell graveklar.face open people` is an error, not a call with a
    // defaulted second argument; the form is `open people ""`. Empty strings are
    // accepted *values* -- an empty view means "just open, wherever you were" --
    // which is what a keybind or a menu entry sends.
    function open(view: string, name: string): string {
      var v = String(view || "")
      var who = String(name || "")
      if (v !== "" && root.viewChrome[v] === undefined) return "unknown view: " + v
      if (v === "person") {
        // A person view with no person is a page that can only say "No such
        // person: ". Open the popup where it was and say why, rather than
        // rendering that.
        if (who === "") { root.open(); return "person needs a name" }
        root.resetView("setup")
        root.openPerson(who)
      } else if (v !== "") {
        root.resetView(v)
      }
      root.open()
      return "ok"
    }

    // What the popup is doing, as JSON. This is how the phase-1 gate observes
    // whether a plugins-folder write closed the popup (plan-merged.md §4);
    // there is no other way to ask a destroyed window whether it is still there.
    function state(): string {
      return JSON.stringify({
        open: root.opened,
        view: root.view,
        stack: root.viewStack,
        statusOutcome: root.statusOutcome,
        rows: root.rows.length,
        dev: engine.dev
      })
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md-face (a front-facing face; nf-md-face_recognition renders as a card in the installed Nerd Font). The bar button carries no state yet: which of the
    // five states of plan-gui.md §3 it is in needs the rows that phase 2 makes
    // real, and a button that claimed "on" from stub data would be a lie on the
    // one surface that is always visible.
    text: "\u{f0643}"
    tooltipText: root.statusOutcome === "" ? "Face Unlock — checking"
                 : root.statusOutcome === "missing" ? "Face Unlock — not installed"
                 : "Face Unlock"
    onPressed: function (buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // Esc pops one view, and closes the popup only from the root view
      // (plan-gui.md §2.2).
      onCloseRequested: {
        if (root.viewStack.length > 1) root.navBack()
        else root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.viewTitle()
            meta: root.chrome().meta
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "\u{f0643}"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              PanelActionButton {
                visible: root.viewStack.length > 1
                iconText: "\u{f004d}"
                tooltipText: "Back"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.navBack()
              }
            }
          }

          // One view at a time. A Loader rather than five visible bindings, so
          // a view that is not on screen holds no timers and no file watches.
          Loader {
            width: parent.width
            sourceComponent: root.view === "people" ? peopleComponent
                           : root.view === "person" ? personComponent
                           : root.view === "settings" ? settingsComponent
                           : root.view === "remove" ? removeComponent
                           : setupComponent
            onLoaded: if (item && "panel" in item) item.panel = root
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            topPadding: Style.space(2)
            text: root.chrome().hint
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  Component { id: setupComponent;    SetupView {} }
  Component { id: peopleComponent;   PeopleView {} }
  Component { id: personComponent;   PersonView {} }
  Component { id: settingsComponent; SettingsView {} }
  Component { id: removeComponent;   RemoveView {} }
}
