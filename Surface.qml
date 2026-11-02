import QtQuick
import Quickshell
import qs.Commons

// What Face gives a surface host (today: kalinewb.notch). Contract 1.
//
// One panel serves every Face route -- setup, people, person:<name>, settings
// and remove -- and it is the stock popup's own views (FaceViews.qml) on the
// host's colours, radius and surface. A scan is not one of them: Start brings up
// polkit's password dialog, the notch loses focus to it and collapses, and the
// scan dies with it (the Phase 4 live gate, plan-face-enroll.md doubt 11). So the
// Scan buttons hand the recording to the Face service's standalone card
// (RecordCard.qml, a window of its own) and close this panel.
//
// Face stays fully usable without a host: nothing here is needed by the popup, and the widget opens the popup
// itself whenever the host does not say `opened` (FacePanel.qml).
//
// It exists once, however many monitors there are (SURFACE-HOSTING section 2),
// so everything with a cost is here and not in the panel, which is created once
// per screen: the one FaceModel.
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
      // a check running in the Test view stops here.
      function close() { surface.panelClosed() }

      // What the notch gives a panel is its own size and nothing else: its slot
      // for an integration (ExpandedHost) is exactly implicitWidth x implicitHeight,
      // with no margin, and `maxWidth` is already net of the notch's side padding.
      // The old path (hostedPanels) put the stock panel's content in a slot with a
      // margin of `notchSidePadding` (Style.space(14), Bar.qml) on every side, and
      // the stock popup pads its content by Style.spacing.popupPadding (also 14),
      // so the panel adds it itself, on every side, inside its implicit size:
      // content against the edge and a header glyph under the notch's rounded
      // corner are what it looks like without. The content is Style.space(320)
      // wide, as before.
      readonly property real inset: Style.space(14)
      implicitWidth: Math.min(hosted.maxWidth, Style.space(320) + 2 * hosted.inset)
      implicitHeight: Math.min(hosted.maxHeight, views.contentHeight + 2 * hosted.inset)

      focus: true
      Keys.onEscapePressed: faceModel.back()

      FaceViews {
        id: views
        anchors.fill: parent
        anchors.margins: hosted.inset
        model: faceModel
        focus: true
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

  // The panel closed. The view is not left on a check that no longer runs.
  function panelClosed() {
    if (faceModel.view === "test") faceModel.navBack()
  }
}
