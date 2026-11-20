import QtQuick
import QtQuick.Window
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "face" as Face

// One way back, and the zone nothing collides with, for dev/h3-one-back.sh.
//
// The REAL Surface.qml's panel on a stand-in host, once per view, saying for each:
//   · how many "Back" buttons of the panel's own are showing,
//   · the hint line under the content,
//   · every control that takes a press and overlaps the notch's way-back zone (the strip at the top
//     centre of the panel, `backZoneWidth` by `backZoneHeight`, SURFACE-HOSTING.md section 15), found the
//     way the notch's own `backZone` verb finds them.
//
//   FACE_HARNESS_HOST   strip   a notch with a back strip: features panelBack and backZone, a 180 x 32 zone
//                       plain   a host that says nothing about either (an older notch, another host)
ShellRoot {
  id: shellRoot

  readonly property string hostKind: Quickshell.env("FACE_HARNESS_HOST") || "strip"
  function log(key, value) { console.log("HARNESS " + key, value) }

  QtObject {
    id: fakeHost
    readonly property int contract: 1
    readonly property var features: shellRoot.hostKind === "strip" ? ["panel", "panelBack", "backZone"] : ["panel"]
    readonly property string pluginId: "kalinewb.face"
    readonly property bool present: true
    readonly property bool accepted: true
    readonly property bool hidden: false
    readonly property color foreground: Commons.Color.foreground
    readonly property color secondary: Qt.darker(Commons.Color.foreground, 1.55)
    readonly property color accent: Commons.Color.accent
    readonly property color color: "#000000"
    readonly property real radius: Style.cornerRadius
    readonly property string fontFamily: Style.font.family
    readonly property real restHeight: 32
    readonly property real backZoneWidth: shellRoot.hostKind === "strip" ? 180 : 0
    readonly property real backZoneHeight: shellRoot.hostKind === "strip" ? 32 : 0
    property bool panelOpen: false
    property string panelRoute: ""
    property string panelScreen: ""
    function radiusFor(size) { return Math.max(0, Math.min(radius, size / 2)) }
    function openPanel(route, screen) { return "declined:harness" }
    function closePanel() { return "unknown" }
  }

  Loader {
    id: surfaceLoader
    sourceComponent: Component { Face.Surface { surfaceHost: fakeHost } }
  }
  readonly property var surface: surfaceLoader.item

  Window { id: win; visible: true; width: 360; height: 900; color: "black" }

  property var panel: null

  // The same reading of "takes a press" as Bar.qml's backZoneReport.
  function typeOf(item) { return String(item).replace(/[_(].*$/, "") }
  function presses(item) {
    // A scrolling container takes a drag, not a press: what it holds is judged on its own.
    if (item.flickableDirection !== undefined) return false
    if (item.acceptedButtons !== undefined && item.acceptedButtons !== 0 && item.enabled) return true
    if (item.cursorPosition !== undefined && item.enabled) return true
    if (item.activeFocusOnTab === true && item.enabled) return true
    var bag = item.data || []
    for (var i = 0; i < bag.length; i++)
      if (bag[i] && bag[i].gesturePolicy !== undefined && bag[i].enabled !== false) return true
    return false
  }
  function hitsIn(page, zone) {
    var found = []
    function walk(item, depth) {
      if (!item || depth > 40 || !item.visible || item.opacity === 0) return
      var at = item.mapToItem(page, 0, 0)
      var overlaps = item.width > 0 && item.height > 0
        && at.x < zone.x + zone.width && at.x + item.width > zone.x
        && at.y < zone.y + zone.height && at.y + item.height > zone.y
      var backdrop = item.width >= page.width * 0.9 && item.height >= page.height * 0.9
      if (overlaps && !backdrop && presses(item)) found.push(typeOf(item).replace("QQuick", "") + "@" + Math.round(at.x) + "," + Math.round(at.y))
      var kids = item.children || []
      for (var k = 0; k < kids.length; k++) walk(kids[k], depth + 1)
    }
    walk(page, 0)
    return found
  }
  // Text whose painted glyphs (by alignment) fall in the zone: the contract is no control AND no text there.
  function textsIn(page, zone) {
    var found = []
    function walk(item, depth) {
      if (!item || depth > 40 || !item.visible || item.opacity === 0) return
      if (typeof item.text === "string" && item.text.length > 0 && item.contentWidth !== undefined && item.width > 0) {
        var at = item.mapToItem(page, 0, 0)
        var cw = Math.min(Number(item.contentWidth), item.width)
        var align = item.effectiveHorizontalAlignment
        var off = align === Qt.AlignRight ? item.width - cw : align === Qt.AlignHCenter ? (item.width - cw) / 2 : 0
        if (at.x + off < zone.x + zone.width && at.x + off + cw > zone.x && at.y < zone.y + zone.height && at.y + item.height > zone.y)
          found.push(item.text.slice(0, 16) + "@" + Math.round(at.x + off) + "," + Math.round(at.y))
      }
      var kids = item.children || []
      for (var k = 0; k < kids.length; k++) walk(kids[k], depth + 1)
    }
    walk(page, 0)
    return found
  }
  function collect(page, pred) {
    var found = []
    function walk(item) {
      if (!item) return
      if (pred(item)) found.push(item)
      var kids = item.children || []
      for (var k = 0; k < kids.length; k++) walk(kids[k])
    }
    walk(page)
    return found
  }

  function describe(tag) {
    var page = shellRoot.panel
    var back = shellRoot.collect(page, function (i) { return i.tooltipText === "Back" && i.visible })
    var hints = shellRoot.collect(page, function (i) { return i.visible && typeof i.text === "string" && /^esc /.test(i.text) })
    // The zone the host says, centred on the panel, at its top edge; with none, the one a strip would have.
    var zw = fakeHost.backZoneWidth > 0 ? fakeHost.backZoneWidth : 180
    var zh = fakeHost.backZoneHeight > 0 ? fakeHost.backZoneHeight : 32
    var zone = { x: (page.width - zw) / 2, y: 0, width: zw, height: zh }
    var hits = shellRoot.hitsIn(page, zone)
    var texts = shellRoot.textsIn(page, zone)
    // Where the first thing below the strip starts, for the reader.
    shellRoot.log(tag, "back=" + back.length + " hint='" + hints.map(function (h) { return h.text }).join("|") + "' hits=[" + hits.join(" ") + "] texts=[" + texts.join(" ") + "]"
                  + " view=" + shellRoot.surface.model.view)
  }

  property var steps: ["setup", "people", "person:anna", "settings", "remove", "test"]
  property int at: 0
  Timer {
    id: ready
    interval: 250
    repeat: true
    running: true
    property int ticks: 0
    onTriggered: {
      ticks += 1
      if (ticks > 80) { shellRoot.log("timeout", true); Qt.exit(1); return }
      if (!shellRoot.surface || !shellRoot.surface.available || shellRoot.surface.model.people === null) return
      running = false
      fakeHost.panelScreen = "T-1"
      fakeHost.panelOpen = true
      shellRoot.panel = shellRoot.surface.panel.createObject(win.contentItem, {
        surfaceHost: fakeHost, surfaceScreen: "T-1", maxWidth: 348, maxHeight: 700
      })
      shellRoot.log("zone", fakeHost.backZoneWidth + "x" + fakeHost.backZoneHeight + " features=" + fakeHost.features.join(","))
      step.start()
    }
  }
  Timer {
    id: step
    interval: 900
    repeat: true
    onTriggered: {
      if (shellRoot.at > 0) shellRoot.describe(shellRoot.steps[shellRoot.at - 1])
      if (shellRoot.at >= shellRoot.steps.length) { Qt.exit(0); return }
      var v = shellRoot.steps[shellRoot.at]
      shellRoot.at += 1
      // The check runs against the dev stub and answers at once; the view is read before it is over.
      if (v === "test") shellRoot.log("showTest", shellRoot.surface.model.showTest("anna", "Anna"))
      else shellRoot.panel.open(v)
    }
  }
  Timer { interval: 40000; running: true; onTriggered: { shellRoot.log("timeout", true); Qt.exit(1) } }
}
