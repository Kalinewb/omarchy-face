import QtQuick
import Quickshell
import "face/lock" as FaceLock

// The lock wrapper, offscreen, in a real Quickshell runtime.
//
// Run by dev/g6-lock-offscreen.sh. It loads the SHIPPED lock/Service.qml and
// drives it two ways:
//
//   · against the REAL /usr/share/omarchy/shell/plugins/lock/Service.qml, to
//     prove the composition holds against the lock screen this machine is
//     actually running (E1's first real run), and against a scratch copy with a
//     public name taken out, to prove it notices
//   · against dev/qml-harness/fake-lock-service.qml, to drive the wake rule,
//     the in-flight guard and the lock-generation counter -- none of which can
//     be exercised against the real one without locking this session
//
// Nothing here locks anything. The real stock instance is created with
// `sessionLock.locked` false, so it holds no surface; the harness never calls
// `beginLock()` on it, and the shell script refuses to start if the compositor
// is holding a lock (which is the only state in which the stock lock's own
// stranded-lock recovery would act).
ShellRoot {
  id: rootObj

  readonly property string caseName: Quickshell.env("FACE_HARNESS_CASE") || "compose"
  readonly property string omarchyPath: Quickshell.env("FACE_HARNESS_OMARCHY") || ""
  readonly property string statusDir: Quickshell.env("FACE_HARNESS_STATUS") || ""

  // What the stand-in `hyprctl -j monitors` prints. Bound, so moving either
  // flag rewrites the command the next poll runs.
  property bool dpmsOn: true
  property bool monitorOff: false

  function monitors(dpms, off) {
    return ["printf", "%s", JSON.stringify([{ name: "eDP-1", dpmsStatus: dpms, disabled: off }])]
  }

  // The stand-in `omarchy-face-lock-verify`: a name on stdout and an exit code,
  // after a wait long enough to have a second wake land inside it.
  property real verifySeconds: 0.3
  property string verifyName: "anna"
  property int verifyCode: 0

  function verify(seconds, name, code) {
    return ["bash", "-c", 'sleep "$1"; printf "%s\\n" "$2"; exit "$3"', "--",
            String(seconds), String(name), String(code)]
  }

  FaceLock.Service {
    id: wrapper
    omarchyPath: rootObj.omarchyPath
    statusDir: rootObj.statusDir
    monitorCommand: rootObj.monitors(rootObj.dpmsOn, rootObj.monitorOff)
    verifyCommand: rootObj.verify(rootObj.verifySeconds, rootObj.verifyName, rootObj.verifyCode)
  }

  // --- the script -----------------------------------------------------------

  property var steps: []
  property int stepIndex: 0

  Timer { id: runner; repeat: false; onTriggered: rootObj.runStep() }

  function play(list) {
    rootObj.steps = list
    rootObj.stepIndex = 0
    runner.interval = list[0].after
    runner.restart()
  }

  function runStep() {
    rootObj.steps[rootObj.stepIndex].run()
    rootObj.stepIndex += 1
    if (rootObj.stepIndex >= rootObj.steps.length) return
    runner.interval = rootObj.steps[rootObj.stepIndex].after
    runner.restart()
  }

  function stock() { return wrapper.stockItem }

  function contractNames() {
    var item = wrapper.stockItem
    if (!item) return ""
    var found = []
    var names = ["lockRequested", "pendingSessionLock", "locked", "authenticatingPassword"]
    for (var i = 0; i < names.length; i++) if (names[i] in item) found.push(names[i])
    if (typeof item.finishUnlock === "function") found.push("finishUnlock()")
    return found.join(",")
  }

  function report() {
    var item = wrapper.stockItem
    console.log("HARNESS case", rootObj.caseName)
    console.log("HARNESS compat", wrapper.compat)
    console.log("HARNESS missing", (wrapper.missing || []).join(","))
    console.log("HARNESS stockLoaded", item !== null && item !== undefined)
    console.log("HARNESS names", rootObj.contractNames())
    console.log("HARNESS wakes", wrapper.wakeCount)
    console.log("HARNESS attempts", wrapper.attemptCount)
    console.log("HARNESS stale", wrapper.staleCount)
    console.log("HARNESS generation", wrapper.lockGeneration)
    console.log("HARNESS outcome", wrapper.lastOutcome)
    console.log("HARNESS unlocks", item && "unlockCount" in item ? item.unlockCount : -1)
    console.log("HARNESS locked", item && "lockRequested" in item ? item.lockRequested : false)
    Qt.exit(0)
  }

  Component.onCompleted: {
    var done = { after: 0, run: function () { rootObj.report() } }

    switch (rootObj.caseName) {

      // The three contract cases. Nothing is locked and nothing is driven: the
      // question is only whether the composition fits.
      case "compose":
      case "incompatible":
      case "failed":
        rootObj.play([{ after: 1500, run: function () {} }, done])
        break

      // GATE: lock by hand and sit still. The screen never blanked, so nothing
      // woke, so face never looked -- which is the whole rule (plan-merged.md
      // §3). This is also "press a key within 5 s": a key press while the
      // display is already lit produces no transition at all.
      case "wake-quiet":
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 3500, run: function () {} },
          done
        ])
        break

      // GATE: lock, wait for the blank, press a key -> one check, and it opens.
      case "wake-blank":
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 1800, run: function () { rootObj.dpmsOn = false } },
          { after: 2000, run: function () { rootObj.dpmsOn = true } },
          { after: 3500, run: function () {} },
          done
        ])
        break

      // GATE: two key presses while a check is running -> ONE check. A queued
      // second one would cost a `camera_busy` and a slot of the daemon's shared
      // rate budget.
      case "wake-busy":
        rootObj.verifySeconds = 3
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 1200, run: function () { rootObj.dpmsOn = false } },
          { after: 1500, run: function () { rootObj.dpmsOn = true } },
          { after: 1200, run: function () { rootObj.dpmsOn = false } },
          { after: 1000, run: function () { rootObj.dpmsOn = true } },
          { after: 5000, run: function () {} },
          done
        ])
        break

      // GATE: the stale attempt. A check is in flight; the user types their
      // password, the lock ends, and a new one begins inside the same six
      // seconds. The check comes back with a yes -- for a lock that is over.
      case "wake-stale":
        rootObj.verifySeconds = 3
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 1200, run: function () { rootObj.dpmsOn = false } },
          { after: 1500, run: function () { rootObj.dpmsOn = true } },
          { after: 1500, run: function () { rootObj.stock().passwordUnlock() } },
          { after: 500,  run: function () { rootObj.stock().beginLock() } },
          { after: 4000, run: function () {} },
          done
        ])
        break

      // A face that is not on the list. Every no is the same no, and the lock
      // stays locked.
      case "wake-no":
        rootObj.verifyCode = 1
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 1200, run: function () { rootObj.dpmsOn = false } },
          { after: 1500, run: function () { rootObj.dpmsOn = true } },
          { after: 3000, run: function () {} },
          done
        ])
        break

      // Clamshell: Omarchy toggles the internal monitor's `disabled` flag
      // rather than DPMS, so that transition is a wake too (E7).
      case "wake-clamshell":
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 1200, run: function () { rootObj.monitorOff = true } },
          { after: 1500, run: function () { rootObj.monitorOff = false } },
          { after: 3000, run: function () {} },
          done
        ])
        break

      default:
        console.log("HARNESS case unknown")
        Qt.exit(2)
    }
  }
}
