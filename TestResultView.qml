import QtQuick
import qs.Commons
import qs.Ui
import "common"
import "common/testverdict.js" as Verdict

// "Does it recognise Anna now?" as a view of its own, in the notch's panel
// (plan-gui.md section 5.2). In the stock bar's popup the check is a small card
// under the webcam (TestCard.qml, a window of the Face service); inside the
// notch there is no window to put a card in, and a card drawn over the panel
// lands on the rows beneath it. So the same check, with the same words
// (common/testverdict.js), replaces the content in place: the person view is
// not drawn while this is up, Close or Esc goes back to it.
//
// This view is the notch's own panel, so it does not ask the notch to stand down
// the way the Test card and the scan island do (common/NotchQuiet.qml): hiding the
// notch would hide this. Nothing is drawn over the notch here.
//
// It runs `omarchy-face-identity verify <name>` as the user, so the only cancel
// is a signal, which is also what frees the camera (Ask.cancel). Leaving the
// view, by any route, stops the check.
Item {
  id: view

  // The model (FaceModel.qml), under the name every view gives it.
  property var panel: null

  readonly property var request: panel ? panel.testRequest : null
  readonly property string who: request ? String(request.label || request.name) : "them"

  // "checking" while the helper runs, "done" once it has answered.
  property string phase: "checking"
  property int code: -1
  property var proc: null

  readonly property string headline: Verdict.headline(view.phase, view.code, view.who)
  readonly property string subline: Verdict.subline(view.phase)
  readonly property bool good: view.phase === "done" && view.code === 0
  readonly property bool bad: view.phase === "done" && view.code === 1

  // Longer than the helper's own receive timeout (20 s), so it only fires when
  // the helper did not come back at all (Service.qml's testSafetyMs).
  readonly property int safetyMs: 25000

  implicitHeight: column.implicitHeight + Style.space(24)

  function start() {
    // Read from the model, not from `request`: this runs inside the change signal
    // that hands the model over, before that binding has been told.
    if (!view.panel || !view.panel.testRequest || view.proc) return
    view.phase = "checking"
    view.code = -1
    view.proc = view.panel.ask.stream(view.panel.ask.identityArgv(["verify", String(view.panel.testRequest.name)]),
                                      null, function (result) {
      view.proc = null
      safety.stop()
      // Not `off` here: the daemon has already written the identity state, and the indicator
      // draws its own "Recognised ..." card for 1.6 s after it. Letting go now put that card on
      // the Overlay layer over this panel, a second verdict on top of this one. The service
      // keeps the indicator's identity card away until this view stops (stop() below).
      view.code = result && result.code !== undefined ? result.code : -1
      view.phase = "done"
    })
    if (!view.proc) { view.code = -1; view.phase = "done"; return }
    safety.restart()
    view.tellService("on")
  }

  // The Face service hides the indicator's identity card while this view is up (Service.qml, inPlaceTest):
  // it would be a second card on top of this one. "on" when the check starts, "off" when the view stops, not
  // when the check answers: the verdict stays on screen until Close. Best effort; the service lets go by itself
  // if "off" is lost.
  property bool told: false
  function tellService(word) {
    if (!view.panel || !view.panel.ask || typeof view.panel.ask.cardArgv !== "function") return
    if (word === "off" && !view.told) return
    view.told = word === "on"
    view.panel.ask.ask(view.panel.ask.cardArgv(["testInPlace", word]), "", function () {})
  }

  // Stop (or Close, or leaving): the check ends by a signal and the camera with it.
  function stop() {
    safety.stop()
    view.tellService("off")
    var going = view.proc
    view.proc = null
    if (going) {
      going.exitCb = null
      view.panel.ask.cancel(going)
    }
  }

  function close() {
    view.stop()
    if (view.panel) view.panel.back()
  }

  // Return closes it, as it dismisses the card.
  function activate() { view.close() }

  Timer { id: safety; interval: view.safetyMs; onTriggered: view.close() }

  // The Loader hands the model over after the view exists, so the check starts
  // when there is something to check, not when the item is made.
  onPanelChanged: view.start()
  Component.onCompleted: view.start()
  Component.onDestruction: view.stop()

  Column {
    id: column
    anchors.centerIn: parent
    width: parent.width
    spacing: Style.space(8)

    FaceGlyph {
      objectName: "testGlyph"
      anchors.horizontalCenter: parent.horizontalCenter
      size: Style.space(56)
      look: view.phase !== "done" ? "scanning" : view.good ? "success" : view.bad ? "failure" : "idle"
      fg: view.panel.foreground
      secondary: view.panel.dim
      accent: view.panel.accent
      urgent: view.panel.urgent
      reduced: view.panel.reducedMotion === true
    }

    Text {
      objectName: "testHeadline"
      textFormat: Text.PlainText
      width: parent.width
      text: view.headline
      color: view.bad ? view.panel.urgent : view.panel.foreground
      font.family: view.panel.fontFamily
      font.pixelSize: Style.font.body
      font.weight: Font.DemiBold
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      Accessible.role: Accessible.StaticText
      Accessible.name: text
    }

    Text {
      objectName: "testSubline"
      textFormat: Text.PlainText
      width: parent.width
      text: view.subline
      color: view.panel.dim
      font.family: view.panel.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    Button {
      objectName: "testClose"
      anchors.horizontalCenter: parent.horizontalCenter
      text: view.phase === "done" ? "Close" : "Stop"
      bordered: view.phase === "done"
      focusable: true
      foreground: view.panel.foreground
      fontFamily: view.panel.fontFamily
      onClicked: view.close()
    }
  }
}
