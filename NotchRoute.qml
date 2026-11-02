import QtQuick
import Quickshell
import Quickshell.Io
import "common/faceroute.js" as Route

// Where `record` goes: the notch's panel, or the card (plan-face-enroll.md
// sections 4.5 and 4.6).
//
// It lives apart from Service.qml so it can be run without the service's
// windows (dev/e2-hosting.sh runs it headless): it opens nothing itself. It
// answers `record` and, when the answer is "the card", says so with
// `cardRequested`, which the service turns into the card.
Item {
  id: root

  // Asked for the card: the notch is not there, will not take it, or did not
  // show it within two seconds.
  signal cardRequested(string name, string appearance, string label, bool isNew)

  //
  // `record` goes to the notch's panel when a notch is there to take it
  // (plan-face-enroll.md sections 4.5 and 4.6). Everything this service learns
  // about the notch comes from two files that any process running as this
  // account can write, so none of it is trusted with anything but a choice
  // between two UIs: a forged heartbeat costs a request that shows nothing, and
  // after two seconds with no `open` in enrol.json the card opens regardless.
  // No camera is opened and no password is asked here in either case -- both
  // belong to the Start button of the view that is on screen.
  //
  // Both files are read when asked, never watched: the folders may not exist yet
  // when this starts, and a watch on a folder that is not there never wakes up.
  // Setting the path again is what makes a blocking FileView read afresh.
  // OMARCHY_FACE_DEV_RUNTIME stands in for $XDG_RUNTIME_DIR in tests, as
  // OMARCHY_FACE_DEV_STATE does for the state files.
  readonly property string runtimeDir: Quickshell.env("OMARCHY_FACE_DEV_RUNTIME")
                                       || Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string hostPath: runtimeDir !== "" ? runtimeDir + "/kalinewb.notch/platform.json" : ""
  readonly property string enrolFlagPath: runtimeDir !== "" ? runtimeDir + "/kalinewb.face/enrol.json" : ""

  FileView { id: hostFile; blockLoading: true; printErrors: false }
  FileView { id: enrolFlagFile; blockLoading: true; printErrors: false }

  function readJson(file, path) {
    if (path === "") return null
    try {
      file.path = ""
      file.path = path
      var parsed = JSON.parse(file.text() || "{}")
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null
    } catch (e) {
      return null
    }
  }

  // The notch's heartbeat, or null: it is absent when the file is missing, says
  // it is not there, has gone quiet, speaks an older contract than this was
  // written for, or does not list Face among the integrations it accepted.
  function hostSnapshot() {
    var state = root.readJson(hostFile, root.hostPath)
    if (state === null) return null
    if (state.present !== true) return null
    if (!(Number(state.contract) >= 1)) return null
    if (!state.accepted || state.accepted["kalinewb.face"] === undefined) return null
    var stale = Number(state.staleAfterMs || 6000)
    return (Date.now() - Number(state.beatAt || 0)) < stale ? state : null
  }

  // enrol.json as the Surface writes it, when it says a session is on screen
  // and has said so within the last 3 s (it rewrites every second).
  readonly property int enrolFlagFreshMs: 3000

  function enrolFlagLive() {
    var flag = root.readJson(enrolFlagFile, root.enrolFlagPath)
    if (flag === null || flag.state !== "open") return null
    var age = Date.now() - Number(flag.at || 0)
    return age >= 0 && age < root.enrolFlagFreshMs ? flag : null
  }

  // The request that has been sent to the notch and not yet seen on screen.
  property var notchPending: null
  property int notchPolls: 0
  readonly property int notchPollMs: 200
  readonly property int notchPollLimit: 10

  function askNotch(who, appearance, label, isNew) {
    root.notchPending = { name: who, appearance: String(appearance || "No glasses"),
                          label: String(label || who), isNew: isNew }
    root.notchPolls = 0
    var route = Route.build("enrol", { name: who, appearance: root.notchPending.appearance,
                                        label: root.notchPending.label, isNew: isNew })
    notchProcess.command = ["omarchy-shell", "notch", "panel", "kalinewb.face", route]
    notchProcess.running = true
    notchConfirm.restart()
    return "opening"
  }

  // The panel was asked for; its answer is the word the host prints. Only
  // `opened` is worth waiting on -- and not even that proves anything, so the
  // confirmation below is the end of it either way.
  Process {
    id: notchProcess
    stdout: StdioCollector {
      onStreamFinished: {
        var word = String(text).trim()
        if (root.notchPending && word.indexOf("declined") === 0) root.notchFallback()
      }
    }
    onExited: function (code) { if (code !== 0 && root.notchPending) root.notchFallback() }
  }

  // Every 200 ms for 2 s: has the Surface said `open` for this name? If so the
  // notch has it. If not, the card opens, and does not wait for anything else.
  Timer {
    id: notchConfirm
    interval: root.notchPollMs
    repeat: true
    onTriggered: {
      if (!root.notchPending) { notchConfirm.stop(); return }
      var live = root.enrolFlagLive()
      if (live && String(live.name) === root.notchPending.name) {
        root.notchPending = null
        notchConfirm.stop()
        return
      }
      root.notchPolls += 1
      if (root.notchPolls >= root.notchPollLimit) root.notchFallback()
    }
  }

  function notchFallback() {
    var wanted = root.notchPending
    root.notchPending = null
    notchConfirm.stop()
    if (!wanted) return
    root.cardRequested(wanted.name, wanted.appearance, wanted.label, wanted.isNew)
  }

  // The whole of `record` after the same-card guard, which is the service's:
  // `busy` and `ok` while a request is waiting or a session is on screen in the
  // notch, `opening` when the notch was asked, `ok` when the card was.
  function record(who, appearance, label, isNew) {
    // The same rule as for a card, for a session in the notch in either of its
    // two stages: asked for and not yet confirmed, or on screen and saying so
    // (enrol.json). One session exists across both homes.
    if (root.notchPending) return root.notchPending.name === who ? "ok" : "busy"
    var live = root.enrolFlagLive()
    if (live) return String(live.name) === who ? "ok" : "busy"
    // The notch, if it is there, accepts Face's integration and is showing its
    // bar: the recording goes in its panel. Anything else -- no file, a stale
    // one, no notch, another bar, a hidden bar -- is the card, because a hidden
    // bar opens the card on purpose: the user pressed Scan.
    var snapshot = root.hostSnapshot()
    if (snapshot !== null && snapshot.hidden !== true)
      return root.askNotch(who, appearance, label, isNew)
    root.cardRequested(who, String(appearance || "No glasses"), String(label || who), isNew)
    return "ok"
  }
}
