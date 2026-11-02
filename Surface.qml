import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "common/faceroute.js" as Route

// What Face gives a surface host (today: kalinewb.notch). Contract 1.
//
// One panel serves every Face route -- setup, people, person:<name>, settings,
// remove and enrol:... -- and it is the stock popup's own views (FaceViews.qml)
// on the host's colours, radius and surface. Face stays fully usable without a
// host: nothing here is needed by the popup, and the widget opens the popup
// itself whenever the host does not say `opened` (FacePanel.qml).
//
// It exists once, however many monitors there are (SURFACE-HOSTING section 2),
// so everything with a cost is here and not in the panel, which is created once
// per screen: the one FaceModel, and the one enrolment session.
//
// No IpcHandler (the widget owns `kalinewb.face`, the service
// `kalinewb.face.card`), no window, and no write under
// ~/.config/omarchy/plugins: any of them would reload the plugins, this file
// with them.
Item {
  id: surface

  // Set by the host. Until it does, there is no host.
  property var surfaceHost: null

  // Honest, not optimistic: false until a status read has answered and the
  // engine row says Face is installed. A first-run install writes the plugins
  // folder (FacePanel.qml), which would destroy an integration in the middle of
  // the flow, so those flows stay in Face's own popup; Face is fully usable
  // without the notch.
  property bool available: faceModel.status !== null && faceModel.rows.length > 0
                           && faceModel.rowState("engine") === "ok"

  // For the panel, the suites and anyone asking what this integration knows.
  readonly property var model: faceModel

  // The host reads `available` when it refreshes (a scan, a load, a settings
  // change), not continuously, and the first status read answers after the first
  // refresh has already declined Face. So the host is asked to look again, once,
  // when the answer turns true -- the documented `rescanIntegrations` verb
  // (SURFACE-HOSTING section 9). It re-evaluates every candidate and touches no
  // file that did not change.
  onAvailableChanged: {
    if (surface.available && surface.surfaceHost !== null)
      Quickshell.execDetached(["omarchy-shell", "notch", "rescanIntegrations"])
  }

  property Component panel: Component {
    Item {
      id: hosted

      // Set by the host once, when the panel is created for a screen.
      property var surfaceHost: null
      property string surfaceScreen: ""
      // Bound by the host: a later openPanel at another route changes it. The
      // route itself is applied from open(), which the host calls on every open.
      property string route: "people"
      property real maxWidth: 400
      property real maxHeight: 400
      signal closeRequested()

      // This copy of the panel is the one on screen: the host keeps one per
      // screen and shows one of them (S3 of the round-3 notes).
      readonly property bool mine: !!hosted.surfaceHost && hosted.surfaceHost.panelOpen
                                   && hosted.surfaceHost.panelScreen === hosted.surfaceScreen

      function open(next) {
        surface.applyRoute(next)
        Qt.callLater(function () { views.focusItem.forceActiveFocus() })
      }

      // The host tells the panel it closed before it takes the surface back;
      // anything running on this panel's behalf stops here.
      function close() { surface.panelClosed() }

      implicitWidth: Math.min(hosted.maxWidth, Style.space(320))
      implicitHeight: Math.min(hosted.maxHeight, views.contentHeight)

      focus: true
      Keys.onEscapePressed: faceModel.back()

      FaceViews {
        id: views
        anchors.fill: parent
        model: faceModel
        focus: true
        // The camera is allowed only here: this panel is open, on its screen,
        // and showing the enrol view (RecordView also asks for the view itself).
        previewLive: hosted.mine
      }

      Connections {
        target: faceModel
        function onCloseRequested() { if (hosted.mine) hosted.closeRequested() }
      }
    }
  }

  FaceModel {
    id: faceModel
    hosted: true
    surfaceHost: surface.surfaceHost
    opened: !!surface.surfaceHost && surface.surfaceHost.panelOpen
  }

  // A route the host opened the panel at.
  function applyRoute(route) {
    var word = faceModel.applyRoute(String(route || "") === "" ? faceModel.barTarget : route)
    if (word !== "ok") console.warn("kalinewb.face", "panel route not applied:", word)
  }

  // --- the one enrolment session -------------------------------------------------
  //
  // Created when the enrol view is on screen with a request behind it, and ended
  // by anything else: the view popping, a route to another view, the panel
  // closing, this file being unloaded (the user switching the integration off).
  // Ending it means EOF to the root session -- discard, nothing written -- and
  // never a commit (RecordSession.discard).

  property var session: null
  property string sessionKey: ""
  property bool ending: false

  function keyOf(request) {
    return request ? [request.name, request.appearance, request.label, request.isNew].join("\u0001") : ""
  }

  // Read from the model, not from a binding on it: this runs inside the model's
  // own change signals, where a binding that depends on the same property may
  // not have been told yet.
  function syncSession() {
    var request = faceModel.enrol
    if (!faceModel.opened || faceModel.view !== "enrol" || request === null) { surface.endSession(); return }
    var key = surface.keyOf(request)
    if (surface.session && surface.sessionKey === key) return
    surface.endSession()
    var made = sessionComponent.createObject(surface, {
      name: request.name,
      appearance: request.appearance,
      label: request.label,
      isNew: request.isNew,
      ask: faceModel.ask
    })
    if (!made) return
    surface.session = made
    surface.sessionKey = key
    faceModel.enrolSession = made
    made.finished.connect(function (saved) { surface.sessionFinished(made, saved) })
  }

  function endSession() {
    if (surface.ending) return
    surface.ending = true
    var going = surface.session
    surface.session = null
    surface.sessionKey = ""
    faceModel.enrolSession = null
    if (going) {
      if (going.running) going.discard()
      going.destroy()
    }
    surface.ending = false
  }

  // A session that ended by itself: saved, discarded, or expired. Saved goes to
  // the person it recorded (after the read the popup's handoff does, so the
  // count shown is the new one); anything else goes back one step.
  function sessionFinished(which, saved) {
    if (which !== surface.session) return
    var who = faceModel.enrol ? faceModel.enrol.name : ""
    surface.endSession()
    if (saved && who !== "") faceModel.openAt("person", who)
    else faceModel.navBack()
  }

  // The panel closed. A session is never kept for a panel nobody is looking at,
  // and the view is not left on a recording that no longer exists.
  function panelClosed() {
    surface.endSession()
    if (faceModel.view === "enrol") faceModel.navBack()
  }

  Connections {
    target: faceModel
    function onEnrolChanged() { surface.syncSession() }
    function onViewChanged() { surface.syncSession() }
    function onOpenedChanged() { surface.syncSession() }
  }

  Component { id: sessionComponent; RecordSession {} }

  // --- "enrol started" (plan-face-enroll.md section 4.6) --------------------------
  //
  // The Face service, outside the shell, asked the host to open the enrol route.
  // The host's answer is a forgeable file, so `opening` proves nothing; this is
  // what does: this file, in the shell itself, says `open` only while the enrol
  // view is actually on screen, every second, and `closed` when it leaves. The
  // service reads it and opens the card if it does not appear (Service.qml). The
  // same file is the busy flag across the two homes.
  readonly property bool shown: !!surface.surfaceHost && surface.surfaceHost.panelOpen
                                && faceModel.view === "enrol" && faceModel.enrol !== null
  // OMARCHY_FACE_DEV_RUNTIME stands in for $XDG_RUNTIME_DIR in tests (Service.qml).
  readonly property string runtimeDir: Quickshell.env("OMARCHY_FACE_DEV_RUNTIME")
                                       || Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string flagDir: runtimeDir !== "" ? runtimeDir + "/kalinewb.face" : ""
  property string flagQueued: ""

  function flagText(open) {
    return JSON.stringify({ state: open ? "open" : "closed",
                            name: open && faceModel.enrol ? faceModel.enrol.name : "",
                            at: Date.now() })
  }

  // FileView will not create the folder, so make it first; the write then goes
  // through FileView's atomic rename.
  function writeFlag(open) {
    if (surface.flagDir === "") return
    surface.flagQueued = surface.flagText(open)
    makeFlagDir.running = true
  }

  onShownChanged: surface.writeFlag(surface.shown)

  Timer {
    interval: 1000
    repeat: true
    running: surface.shown
    onTriggered: surface.writeFlag(true)
  }

  Process {
    id: makeFlagDir
    command: ["mkdir", "-p", surface.flagDir]
    onExited: function (code) {
      if (code === 0 && surface.flagQueued !== "") flagFile.setText(surface.flagQueued)
      surface.flagQueued = ""
    }
  }

  FileView {
    id: flagFile
    path: surface.flagDir !== "" ? surface.flagDir + "/enrol.json" : ""
    atomicWrites: true
    // Only ever written here; the read Qt tries first fails until the first one.
    printErrors: false
  }

  // The last word, written synchronously: the integration being switched off or
  // the shell reloading must not leave `open` behind for the service to trust.
  FileView {
    id: lastFile
    path: surface.flagDir !== "" ? surface.flagDir + "/enrol.json" : ""
    atomicWrites: true
    printErrors: false
    blockWrites: true
  }

  Component.onDestruction: {
    surface.endSession()
    if (surface.flagDir !== "") lastFile.setText(surface.flagText(false))
  }
}
