import QtQuick
import Quickshell
import Quickshell.Io

// Ask the notch to stand down while a Face card is up, and to come back as it
// was. The card (the scan island, the Test card) is drawn on the Overlay layer
// over the top centre of the screen, which is exactly where the notch is, so
// until now a notch that was open, or showing a notification, sat behind it.
//
//   quiet.on("record")    the notch closes and hides; it remembers what it was showing
//   quiet.off("record")   it comes back to that, page and history included
//
// The contract is the notch's (`omarchy-shell notch quiet <on|off> <owner>`,
// its SURFACE-HOSTING.md section 14) and every part of it is optional here:
//
//   · A notch without the verb, another bar, or no notch at all: the call fails
//     and nobody is told. Nothing in Face waits for the answer, so a missing
//     notch is not an error and not a delay.
//   · The notch holds the request as a lease (35 s) and will not stay hidden
//     past it, so a card that dies, or this service being restarted, cannot
//     strand the notch. While a card is up this renews the lease every
//     `renewMs`; the notch caps the total hold on its side.
//   · It only ever asks the notch to hide ITSELF. No card, and no line the
//     indicator draws for a `sudo` or the lock screen, depends on the answer
//     (Indicator.qml). A hidden notch is never a reason to draw less.
//
// One request is in flight at a time, in the order they were made: an `off`
// that overtook the `on` before it would leave the notch hidden until the lease
// ran out.
QtObject {
  id: quiet

  // The plugin's id; the owner the notch sees is `<plugin>:<reason>`.
  property string plugin: "kalinewb.face"
  // The verb. Development (OMARCHY_FACE_DEV_BIN) never reaches a real notch:
  // Service.qml leaves this off unless a test names a stand-in.
  property bool enabled: true
  property var verb: ["omarchy-shell", "notch", "quiet"]
  // Under the notch's 35 s lease, with a missed beat to spare.
  property int renewMs: 15000
  // A call that has not answered by now is not coming back.
  property int callTimeoutMs: 4000

  // reason -> true, replaced whole so bindings re-evaluate.
  property var held: ({})
  readonly property bool any: Object.keys(held).length > 0

  property var queue: []

  function owner(reason) { return quiet.plugin + ":" + String(reason) }

  function on(reason) {
    var name = String(reason)
    var next = JSON.parse(JSON.stringify(held))
    next[name] = true
    held = next
    quiet.send("on", name)
  }

  // Safe to call for a reason that was never asked for: nothing is sent.
  function off(reason) {
    var name = String(reason)
    if (held[name] !== true) return
    var next = JSON.parse(JSON.stringify(held))
    delete next[name]
    held = next
    quiet.send("off", name)
  }

  // The service is going away: let go of everything now, detached, because the
  // queue and its Process go with it.
  function releaseAll() {
    var reasons = Object.keys(held)
    held = ({})
    queue = []
    if (!enabled) return
    for (var i = 0; i < reasons.length; i++)
      Quickshell.execDetached(quiet.verb.concat(["off", quiet.owner(reasons[i])]))
  }

  function send(word, reason) {
    if (!enabled) return
    var next = queue.concat([[word, quiet.owner(reason)]])
    // A stuck verb must not grow without bound; the oldest is the least useful.
    queue = next.length > 16 ? next.slice(next.length - 16) : next
    quiet.pump()
  }

  function pump() {
    if (quiet.runner.running || queue.length === 0) return
    var job = queue[0]
    queue = queue.slice(1)
    quiet.runner.command = quiet.verb.concat(job)
    quiet.runner.running = true
    quiet.watchdog.restart()
  }

  readonly property var runner: Process {
    onRunningChanged: if (!running) { quiet.watchdog.stop(); quiet.pump() }
  }

  readonly property var watchdog: Timer {
    interval: quiet.callTimeoutMs
    onTriggered: if (quiet.runner.running) quiet.runner.running = false
  }

  // The lease, kept alive for as long as a card is.
  readonly property var renew: Timer {
    interval: quiet.renewMs
    repeat: true
    running: quiet.any
    onTriggered: { for (var reason in quiet.held) quiet.send("on", reason) }
  }
}
