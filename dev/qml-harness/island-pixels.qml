import QtQuick
import QtQuick.Window
import "face" as Face

// Island.qml on its own, rendered offscreen to a PNG so the shape can be
// checked pixel by pixel. Run by dev/g5c-island-offscreen.sh under
// QT_QPA_PLATFORM=offscreen with `qml6`:
//
//   qml6 island-pixels.qml -- w=300 h=116 r=14 fillet=14 out=/path/island.png
//
// The island sits `margin` px in from the left of a transparent window and
// flush with its top, which stands in for the screen edge. Every number it
// was built from, and the resulting centres in image coordinates, is printed
// as `GEOM key value` so the script can sample exactly the right pixels.
Window {
  id: win
  visible: true
  color: "transparent"

  readonly property var args: {
    var all = Qt.application.arguments
    var parsed = {}
    var start = all.indexOf("--")
    for (var i = start < 0 ? 0 : start + 1; i < all.length; i++) {
      var eq = String(all[i]).indexOf("=")
      if (eq > 0) parsed[String(all[i]).slice(0, eq)] = String(all[i]).slice(eq + 1)
    }
    return parsed
  }
  function num(key, fallback) { var n = Number(args[key]); return isFinite(n) && args[key] !== undefined ? n : fallback }

  readonly property real margin: 10
  readonly property string out: args.out || "/tmp/island.png"

  width: Math.ceil(island.width + 2 * margin)
  height: Math.ceil(island.height + margin)

  Item {
    id: scene
    anchors.fill: parent

    Face.Island {
      id: island
      x: win.margin
      y: 0
      barWidth: win.num("w", 300)
      barHeight: win.num("h", 116)
      bottomRadius: win.num("r", 14)
      filletRadius: win.num("fillet", 14)
    }
  }

  function log(key, value) { console.log("GEOM " + key, value) }
  function pt(p) { return p.x.toFixed(3) + "," + p.y.toFixed(3) }

  // Canvas paints asynchronously; half a second is plenty for two of them.
  Timer {
    interval: 500
    running: true
    onTriggered: {
      var barX = island.x + island.barX
      win.log("imageWidth", win.width)
      win.log("imageHeight", win.height)
      win.log("barX", barX)
      win.log("barY", island.y)
      win.log("barWidth", island.barWidth)
      win.log("barHeight", island.barHeight)
      win.log("bottomRadius", island.bottomR)
      win.log("filletRadius", island.fillet)
      function onImage(p) { return Qt.point(barX + p.x, island.y + p.y) }
      win.log("leftFilletCentre", win.pt(onImage(island.leftFilletCentre)))
      win.log("rightFilletCentre", win.pt(onImage(island.rightFilletCentre)))
      win.log("bottomLeftCentre", win.pt(onImage(island.bottomLeftCentre)))
      win.log("bottomRightCentre", win.pt(onImage(island.bottomRightCentre)))
      scene.grabToImage(function(result) {
        win.log("saved", result.saveToFile(win.out))
        Qt.exit(0)
      })
    }
  }

  Timer {
    interval: 10000
    running: true
    onTriggered: { win.log("timeout", true); Qt.exit(1) }
  }
}
