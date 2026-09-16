import QtQuick
import Quickshell
import Quickshell.Io
import "face" as Face

// The island's geometry, read off the REAL Indicator.qml with the real
// qs.Commons Style behind it. Run by dev/g5c-island-offscreen.sh.
//
// This loads the shipped indicator, feeds it a `start` state.json the same way
// g5 does, lets the entrance animation finish, and then prints every number
// the shape is made of: the bar's rectangle, its two radii, and the four arc
// centres -- in the bar's own coordinates and in screen coordinates. It draws
// the card for about a second and a half on the built-in screen to do it,
// because the numbers worth checking are the ones the shipped file computes,
// not ones this harness could work out for itself.
ShellRoot {
  id: rootObj

  function log(key, value) { console.log("HARNESS " + key, value) }
  function pt(p) { return p.x.toFixed(3) + "," + p.y.toFixed(3) }

  Item {
    width: 400
    height: 800
    Face.Indicator { id: indicator }
  }

  // The card is inside a PanelWindow made by the indicator's Variants. Walk
  // there: the Variants is one of the indicator's child objects, its
  // instances are the windows, and the Island is a child of the window's
  // content item -- recognisable by having a barWidth.
  function findCard() {
    var objects = indicator.data
    for (var i = 0; i < objects.length; i++) {
      var candidate = objects[i]
      if (!candidate || candidate.instances === undefined) continue
      var instances = candidate.instances
      for (var j = 0; j < instances.length; j++) {
        var window = instances[j]
        var kids = window && window.contentItem ? window.contentItem.children : []
        for (var k = 0; k < kids.length; k++)
          if (kids[k] && kids[k].barWidth !== undefined) return kids[k]
      }
    }
    return null
  }

  // --- the first frames, on the real screen ----------------------------------
  //
  // The numbers above say where the bar is inside its own window. They cannot
  // say what the compositor does with the window: Hyprland animates a layer
  // surface as it maps unless a layer rule tells it not to (Service.qml sets
  // one), and a pop-in or slide of the whole window would put the bar
  // anywhere but the edge for its first frames while every number in QML
  // still read y = 0. So, when the script asks for it, the moment the window
  // comes up this grabs a strip of the real screen around where the bar will
  // be -- at once, then 30, 60, 150 and 400 ms later -- and the script compares
  // each grab with one taken before the card existed.
  readonly property string captureDir: Quickshell.env("FACE_HARNESS_CAPTURE_DIR") || ""
  readonly property string captureGeometry: Quickshell.env("FACE_HARNESS_CAPTURE_GEOMETRY") || ""
  property double windowUpAt: 0
  property int capturesRunning: 0

  component Capture: Process {
    property int index: 0
    command: ["grim", "-s", "1", "-g", rootObj.captureGeometry,
              rootObj.captureDir + "/capture-" + index + ".png"]
    onRunningChanged: {
      if (running) {
        rootObj.capturesRunning++
        rootObj.log("capture" + index + "At", Date.now() - rootObj.windowUpAt)
      } else {
        rootObj.capturesRunning--
      }
    }
    onExited: function(code) { if (code !== 0) rootObj.log("capture" + index + "Failed", code) }
  }
  Capture { id: capture0; index: 0 }
  Capture { id: capture1; index: 1 }
  Capture { id: capture2; index: 2 }
  Capture { id: capture3; index: 3 }
  Capture { id: capture4; index: 4 }
  Timer { id: captureTimer1; interval: 30; onTriggered: capture1.running = true }
  Timer { id: captureTimer2; interval: 60; onTriggered: capture2.running = true }
  Timer { id: captureTimer3; interval: 150; onTriggered: capture3.running = true }
  Timer { id: captureTimer4; interval: 400; onTriggered: capture4.running = true }

  Connections {
    target: indicator
    function onWindowUpChanged() {
      if (!indicator.windowUp || rootObj.captureDir === "" || rootObj.captureGeometry === "") return
      rootObj.windowUpAt = Date.now()
      capture0.running = true
      captureTimer1.start()
      captureTimer2.start()
      captureTimer3.start()
      captureTimer4.start()
    }
  }

  // Leave only once every grab has been written.
  function finish(code) {
    if (rootObj.capturesRunning > 0) { finishTimer.code = code; finishTimer.start(); return }
    Qt.exit(code)
  }
  Timer { id: finishTimer; property int code: 0; interval: 50; onTriggered: rootObj.finish(code) }

  // The first frame. Polled as fast as a timer can go from before the state
  // file is even read, so the first time the card exists at all is what gets
  // recorded: where its top edge is, how big it is, and whether the fillets
  // are already on it. Anything this sees is at most one poll after the
  // window came up, well inside the first frame's growth.
  property bool seenFirst: false
  Timer {
    interval: 1
    repeat: true
    running: !rootObj.seenFirst
    onTriggered: {
      var card = rootObj.findCard()
      if (!card) return
      rootObj.seenFirst = true
      rootObj.log("firstY", card.y)
      rootObj.log("firstHeightP", card.parent ? indicator.heightP.toFixed(4) : "")
      rootObj.log("firstWidthP", indicator.widthP.toFixed(4))
      rootObj.log("firstBarWidth", card.barWidth.toFixed(3))
      rootObj.log("firstBarHeight", card.barHeight.toFixed(3))
      rootObj.log("firstBottomRadius", card.bottomR.toFixed(3))
      rootObj.log("firstFilletRadius", card.fillet.toFixed(3))
    }
  }

  // The state file is polled every 200 ms and the entrance takes 350 ms, so
  // by 1600 ms the bar has been at rest for about a second.
  Timer {
    interval: 1600
    running: true
    onTriggered: {
      rootObj.log("showing", indicator.visibleNow)
      rootObj.log("seenFirst", rootObj.seenFirst)
      rootObj.log("seedHeightFraction", indicator.seedHeightFraction)
      rootObj.log("seedWidthFraction", indicator.seedWidthFraction)
      rootObj.log("heightGone", indicator.heightGone.toFixed(4))
      rootObj.log("widthGone", indicator.widthGone.toFixed(4))
      rootObj.log("bottomRadiusFraction", indicator.bottomRadiusFraction)
      rootObj.log("filletFull", indicator.filletFull)
      rootObj.log("heightP", indicator.heightP)
      rootObj.log("widthP", indicator.widthP)
      rootObj.log("heightDuration", indicator.heightDuration)
      rootObj.log("widthDelay", indicator.widthDelay)
      rootObj.log("widthDuration", indicator.widthDuration)
      rootObj.log("springDamping", indicator.springDamping)
      rootObj.log("springOvershoot", indicator.springOvershoot.toFixed(4))
      rootObj.log("springPeakAt", indicator.springPeakAt)
      rootObj.log("springCurve", JSON.stringify(indicator.springCurve.map(function(v) { return Number(v.toFixed(4)) })))
      var card = rootObj.findCard()
      rootObj.log("cardFound", card !== null)
      if (!card) { rootObj.finish(1); return }

      var screen = card.parent
      rootObj.log("screen", screen.width + "x" + screen.height)
      // The window fills the screen, so the card's position in its content
      // item is its position on the screen.
      var barScreenX = card.x + card.barX
      var barScreenY = card.y
      rootObj.log("islandX", card.x)
      rootObj.log("islandWidth", card.width)
      rootObj.log("barX", barScreenX)
      rootObj.log("barY", barScreenY)
      rootObj.log("barWidth", card.barWidth)
      rootObj.log("barHeight", card.barHeight)
      rootObj.log("topLeftRadius", 0)
      rootObj.log("topRightRadius", 0)
      rootObj.log("bottomRadiusRequested", card.bottomRadius)
      rootObj.log("bottomRadius", card.bottomR)
      rootObj.log("filletRadiusRequested", card.filletRadius)
      rootObj.log("filletRadius", card.fillet)
      // Centres, in the bar's coordinates (origin at the bar's top-left)…
      rootObj.log("leftFilletCentreBar", rootObj.pt(card.leftFilletCentre))
      rootObj.log("rightFilletCentreBar", rootObj.pt(card.rightFilletCentre))
      rootObj.log("bottomLeftCentreBar", rootObj.pt(card.bottomLeftCentre))
      rootObj.log("bottomRightCentreBar", rootObj.pt(card.bottomRightCentre))
      // …and on the screen.
      function onScreen(p) { return Qt.point(barScreenX + p.x, barScreenY + p.y) }
      rootObj.log("leftFilletCentreScreen", rootObj.pt(onScreen(card.leftFilletCentre)))
      rootObj.log("rightFilletCentreScreen", rootObj.pt(onScreen(card.rightFilletCentre)))
      rootObj.log("bottomLeftCentreScreen", rootObj.pt(onScreen(card.bottomLeftCentre)))
      rootObj.log("bottomRightCentreScreen", rootObj.pt(onScreen(card.bottomRightCentre)))
      rootObj.finish(0)
    }
  }

  Timer {
    interval: 15000
    running: true
    onTriggered: { rootObj.log("timeout", true); Qt.exit(1) }
  }
}
