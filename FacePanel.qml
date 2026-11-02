import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "common"
import "common/faceroute.js" as Route

// Face ID: the bar button and the popup behind it.
//
// This file is the stock bar's home for Face and nothing more: the button, the
// popup window around the views, and the IPC target. What the popup shows is
// FaceViews.qml and what it knows is FaceModel.qml; the notch's panel
// (Surface.qml) uses the same two, so this file does not draw or decide any of
// it. Every call to the engine still goes through common/Ask.qml, so the
// contract (plan-merged.md §2) is read in one place.
//
// Under the notch the button's press opens the notch's panel instead and this
// popup stays shut, per event: only an answer of `opened` or `closed` means the
// notch took the press (SURFACE-HOSTING section 6, rule 1).
//
// What must NOT happen here: a write under ~/.config/omarchy/plugins. Any write
// there reloads every plugin bar widget (plan-engine.md E13), which destroys
// this popup and everything it was driving. Exactly three flows in the finished
// plugin write that folder, each as its last step and each announced first
// (plan-gui.md §1); none of them is a routine action, and none of them is here.
Panel {
  id: root
  moduleName: "kalinewb.face"
  ipcTarget: "kalinewb.face"
  // The base class would install its own handler on that target; this file adds
  // open(view, name) and state(), so it registers the target itself.
  manageIpc: false

  // Set by the notch when this widget is one of its own and it accepts Face's
  // integration; under any other bar neither is ever set.
  property var surfaceHost: null
  property string surfaceScreen: ""

  FaceModel {
    id: faceModel
    hosted: false
    bar: root.bar
    opened: root.opened
    onCloseRequested: root.close()
    onOpenRequested: root.open()
  }

  // The model, under the names the views and the suites have always used for
  // the panel. The views are handed the model itself (FaceViews); this is for
  // whoever holds the popup (dev/qml-harness/post-ship.qml, state() below).
  readonly property bool hosted: false
  readonly property color foreground: faceModel.foreground
  readonly property color accent: faceModel.accent
  readonly property color urgent: faceModel.urgent
  readonly property color dim: faceModel.dim
  readonly property string fontFamily: faceModel.fontFamily
  function radiusFor(size) { return faceModel.radiusFor(size) }
  readonly property string pluginDir: faceModel.pluginDir
  readonly property var ask: faceModel.ask
  readonly property var status: faceModel.status
  readonly property string statusOutcome: faceModel.statusOutcome
  readonly property bool statusBusy: faceModel.statusBusy
  readonly property bool refreshQueued: faceModel.refreshQueued
  readonly property var rows: faceModel.rows
  readonly property var config: faceModel.config
  readonly property var lockState: faceModel.lockState
  readonly property var people: faceModel.people
  readonly property var installDoc: faceModel.installDoc
  readonly property bool setupNeeded: faceModel.setupNeeded
  readonly property bool attention: faceModel.attention
  readonly property string barState: faceModel.barState
  readonly property string barTarget: faceModel.barTarget
  readonly property string barTooltip: faceModel.barTooltip
  readonly property var viewStack: faceModel.viewStack
  readonly property string view: faceModel.view
  readonly property string personName: faceModel.personName
  readonly property string resumeWord: faceModel.resumeWord
  readonly property var pendingOpen: faceModel.pendingOpen
  function row(id) { return faceModel.row(id) }
  function rowState(id) { return faceModel.rowState(id) }
  function refresh() { faceModel.refresh() }
  function reloadWatched() { faceModel.reloadWatched() }
  function pushView(v) { faceModel.pushView(v) }
  function openWithBase(v) { faceModel.openWithBase(v) }
  function openPerson(name) { faceModel.openPerson(name) }
  function openAt(viewName, name) { return faceModel.openAt(viewName, name) }
  function resumeAt(viewName, word) { return faceModel.resumeAt(viewName, word) }
  function takeResumeWord(prefix) { return faceModel.takeResumeWord(prefix) }
  function navBack() { faceModel.navBack() }

  // --- the press, and the IPC's open(), under the notch -------------------------

  // The route a (view, name) pair names, or "" for none (an unknown view, a
  // person with no name, and `enrol`, which only the views themselves reach).
  // An empty view is "just open, wherever the button points".
  function routeFor(viewName, name) {
    var v = String(viewName || "")
    if (v === "") return root.barTarget
    if (v === "enrol") return ""
    return Route.build(v, { name: String(name || "") })
  }

  // Ask the notch to show `route`. True when it took the event: `opened`, or
  // `closed` (the press was the notch's own toggle of the panel it was already
  // showing). Anything else -- no host, hidden, declined, another bar -- is the
  // popup's to open.
  function hostTook(route) {
    if (!root.surfaceHost || route === "") return false
    var answer = String(root.surfaceHost.openPanel(route, root.surfaceScreen))
    return answer === "opened" || answer === "closed"
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
    // `omarchy-shell kalinewb.face open people` is an error, not a call with a
    // defaulted second argument; the form is `open people ""`. Empty strings are
    // accepted *values* -- an empty view means "just open, wherever you were" --
    // which is what a keybind or a menu entry sends.
    function open(view: string, name: string): string {
      // The body is openAt() above, because what this call has to do -- read
      // before it shows -- is the panel's business and not the IPC surface's,
      // and because a gate cannot call an IpcHandler method from inside the
      // same process.
      //
      // Under the notch the same call is a route (common/faceroute.js), and the
      // panel there reads before it shows by the same rule. Asking for the route
      // the notch is already showing is not a toggle: it is already there.
      var route = root.surfaceHost ? root.routeFor(view, name) : ""
      if (route !== "") {
        if (root.surfaceHost.panelOpen && root.surfaceHost.panelRoute === route) return "ok"
        if (root.hostTook(route)) return "ok"
      }
      return root.openAt(view, name)
    }

    // resume(view, word): how the Face service comes back to the popup after a
    // lock screen switch it ran on the popup's behalf (resumeAt, above). Both
    // arguments, for the same arity reason as open().
    function resume(view: string, word: string): string {
      return root.resumeAt(view, word)
    }

    // What the popup is doing, as JSON. This is how the phase-1 gate observes
    // whether a plugins-folder write closed the popup (plan-merged.md §4);
    // there is no other way to ask a destroyed window whether it is still there.
    function state(): string {
      var build = root.installDoc || {}
      return JSON.stringify({
        open: root.opened,
        view: root.view,
        stack: root.viewStack,
        statusOutcome: root.statusOutcome,
        rows: root.rows.length,
        barState: root.barState,
        barTarget: root.barTarget,
        barTooltip: root.barTooltip,
        // The build the `engine` row is showing. It is here for the same reason
        // the rest is: phase 3's gate is "closing the popup or restarting the
        // shell mid-build loses nothing", and a shell that has just restarted
        // cannot be asked what it is rendering any other way.
        // The two things the panel can be waiting for, neither of which is
        // visible from outside this process any other way: a status read queued
        // behind one in flight, and a view held back until people.json has been
        // re-read (both post-ship revisions, above).
        reads: {
          statusBusy: root.statusBusy,
          refreshQueued: root.refreshQueued,
          pendingOpen: root.pendingOpen ? String(root.pendingOpen.view) : "",
          // A word from the Face service no view has taken yet (resumeAt).
          resumeWord: root.resumeWord
        },
        install: {
          state: String(build.state || "idle"),
          step: String(build.step || ""),
          startedAt: Number(build.startedAt || 0),
          updatedAt: Number(build.updatedAt || 0)
        },
        dev: root.ask.dev
      })
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md-face (a front-facing face; nf-md-face_recognition renders as a card
    // in the installed Nerd Font).
    text: "\u{f0643}"
    tooltipText: root.barTooltip
    // Full strength only for `on` and `attention`; everything else is dimmed
    // (plan-gui.md §3). `active` paints the glyph in the bar's urgent colour,
    // which is the accent this kit has.
    dimmed: root.barState !== "on" && root.barState !== "attention"
    active: root.barState === "attention"
    onPressed: function (buttonCode) {
      // Under the notch the press opens (or toggles) its panel at the route the
      // button points at, and this popup stays shut for that event. Whatever
      // else the notch answers, and under any other bar, the popup is ours.
      if (!root.opened && root.hostTook(root.barTarget)) return
      // Opening from the bar starts where the button said it would. Closing
      // leaves the stack alone, so reopening returns to the same place.
      if (!root.opened && root.viewStack.length === 1 && root.view !== root.barTarget)
        root.openWithBase(root.barTarget)
      root.toggle()
    }

    // The accent dot of the `attention` state. A colour change alone is a
    // theme's business; a dot is still there when the theme is monochrome.
    Rectangle {
      visible: root.barState === "attention"
      width: Style.space(4)
      height: width
      radius: width / 2
      color: root.accent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(3)
      anchors.topMargin: Style.space(3)
    }
  }


  onOpenedChanged: if (opened) Qt.callLater(function () { views.focusItem.forceActiveFocus() })

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: views.focusItem
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(views.contentHeight, Style.space(560))

    FaceViews {
      id: views
      anchors.fill: parent
      model: faceModel
      // The popup never shows the enrol view (a recording is the service's
      // card here), so the camera has no business with this home.
      previewLive: false
      onTabRequested: function (direction) { root.switchPanel(direction) }
    }
  }
}
