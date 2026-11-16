import QtQuick
import QtQuick.Window
import Quickshell
import "face" as Face
import "face/common" as FaceCommon

// The indicator card and the face glyph, drawn offscreen, for dev/g5-indicator-offscreen.sh and for looking at.
//
//   FACE_FRAMES_STATE    start | matched | failed | idle        (what the indicator's authState is)
//   FACE_FRAMES_SERVICE  sudo | identity
//   FACE_FRAMES_REDUCED  1 for reduced motion
//   FACE_FRAMES_OUT      a directory: writes <state>[-reduced]-<n>.png at the times below, then prints the glyph's
//                        numbers (HARNESS key value)
//
// No window of the compositor's: a Window on the offscreen platform, a grey "desktop" so the black card reads.
ShellRoot {
  id: rootObj

  readonly property string stateName: Quickshell.env("FACE_FRAMES_STATE") || "start"
  readonly property string service: Quickshell.env("FACE_FRAMES_SERVICE") || "sudo"
  readonly property bool reduced: Quickshell.env("FACE_FRAMES_REDUCED") === "1"
  readonly property string outDir: Quickshell.env("FACE_FRAMES_OUT") || ""
  function log(key, value) { console.log("HARNESS " + key, value) }

  readonly property string headline: stateName === "matched"
      ? (service === "identity" ? "Recognised Anna" : "Approved · Anna")
      : stateName === "failed" ? (service === "identity" ? "Not recognised" : "Not recognised — use your password")
      : "Look at the camera"
  readonly property string detail: service === "identity" ? "Asked by Profiles" : "sudo · pacman, from foot"

  Window {
    id: win
    visible: true
    width: 360
    height: 260
    color: "#3a3a46"

    Item {
      id: stage
      anchors.fill: parent
      Face.IndicatorCard {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        authState: rootObj.stateName
        headline: rootObj.headline
        detail: rootObj.detail
        reduced: rootObj.reduced
      }
    }
  }

  property int shot: 0
  function snap() {
    var n = shot++
    stage.grabToImage(function (result) {
      if (rootObj.outDir !== "")
        result.saveToFile(rootObj.outDir + "/" + rootObj.service + "-" + rootObj.stateName
                          + (rootObj.reduced ? "-reduced" : "") + "-" + n + ".png")
    })
  }

  function glyph() { return find(card, "indicatorGlyph") }
  function find(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var f = find(kids[i], name); if (f) return f }
    return null
  }

  // frames: settled, then 0.45 s on (a mid-pulse / the end of the check's drawing / past the shake)
  Timer { interval: 700; running: true; onTriggered: { rootObj.snap(); rootObj.log("look", rootObj.glyph().look); rootObj.log("shown", card.barHeight > 0 && card.opacity > 0) } }
  Timer { interval: 1150; running: true; onTriggered: { rootObj.snap(); rootObj.log("breath", Math.round(rootObj.glyph().breath * 100) / 100) } }
  Timer { interval: 1700; running: true
    onTriggered: {
      var g = rootObj.glyph()
      rootObj.log("end", "done " + Math.round(g.done * 100) / 100 + " shakeX " + Math.round(g.shakeX * 10) / 10 + " reduced " + g.reduced)
      Qt.exit(0)
    }
  }
}
