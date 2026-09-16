import QtQuick
import Quickshell
import Quickshell.Io
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

  // The stand-in `hyprctl eval`: nothing is bound, and every call is written to
  // eval.log as `arm` or `disarm` so the suite can read the order back. Set on
  // every case, including the three that compose with the REAL lock screen --
  // the wrapper disarms at start, and a real `hyprctl eval` from a test would
  // take the binding out from under a wrapper this session is running.
  readonly property var evalStandIn: ["bash", "-c",
    'case $1 in *hl.bind*) w=arm ;; *) w=disarm ;; esac; ' +
    '[[ $w == disarm ]] || grep -q "hl.dsp.event(\\"$FACE_HARNESS_EVENT\\")" <<<"$1" || w="$w-wrong-event"; ' +
    'printf "%s\\n" "$w" >>"$FACE_HARNESS_STATUS/eval.log"', "--"]

  // Unique per run, so a real event raised below reaches this wrapper and no
  // other: the wrapper the session is running listens for `omarchy-face-enter`.
  readonly property string enterEvent: Quickshell.env("FACE_HARNESS_EVENT") || "omarchy-face-enter-harness"

  FaceLock.Service {
    id: wrapper
    omarchyPath: rootObj.omarchyPath
    statusDir: rootObj.statusDir
    monitorCommand: rootObj.monitors(rootObj.dpmsOn, rootObj.monitorOff)
    verifyCommand: rootObj.verify(rootObj.verifySeconds, rootObj.verifyName, rootObj.verifyCode)
    evalCommand: rootObj.evalStandIn
    enterEvent: rootObj.enterEvent
  }

  // Enter, by the path a real key takes after Hyprland: a `custom>>` event on
  // the compositor's socket, read by Quickshell.Hyprland. Raised with a real
  // `hl.dispatch(hl.dsp.event(...))` when there is a compositor to raise it, so
  // the event name, the Connections target and the event parsing are all under
  // test. Without one the wrapper is called directly, and the report says so.
  readonly property bool realEvents: (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "") !== ""
                                     && Quickshell.env("FACE_HARNESS_DIRECT_ENTER") !== "1"
  Process {
    id: dispatcher
    command: ["hyprctl", "eval", 'hl.dispatch(hl.dsp.event("' + rootObj.enterEvent + '"))']
  }
  function pressEnter() {
    if (rootObj.realEvents) {
      // Two presses inside one Process lifetime would be one event; say so.
      if (dispatcher.running) console.warn("HARNESS-WARN a second Enter while the first was still dispatching")
      dispatcher.running = true
    } else {
      wrapper.enterPressed()
    }
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
    console.log("HARNESS enters", wrapper.enterCount)
    console.log("HARNESS enterPath", rootObj.realEvents ? "hyprland" : "direct")
    console.log("HARNESS line", item && "failureMessage" in item ? item.failureMessage : "")
    console.log("HARNESS lineNo", wrapper.lineNo)
    console.log("HARNESS lineNoResumed", wrapper.lineNoResumed)
    console.log("HARNESS resumed", wrapper.resumedAt > 0)
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

      // F6 test 6: Face removed with the clone left behind. There is no
      // omarchy-face-lock-verify to run, so the check cannot even start -- and
      // the lock screen has to go on being Omarchy's, with the password field
      // working and face simply silent.
      case "wake-missing":
        // Assigned on the wrapper, which drops the binding above: there is no
        // helper at all, which is what `omarchy plugin remove` without Remove
        // Face leaves behind.
        wrapper.verifyCommand = ["/nonexistent/omarchy-face-lock-verify"]
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

      // Enter on the empty field of a LIT lock screen: nothing woke, and one
      // check runs anyway. This is the case the wake rule could never reach.
      case "enter-lit":
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 800,  run: function () { rootObj.pressEnter() } },
          { after: 2500, run: function () {} },
          done
        ])
        break

      // Enter with no lock up is just Enter. (With the shipped wrapper there is
      // no binding at all outside a lock; this is the wrapper's own guard.)
      case "enter-unlocked":
        rootObj.play([
          { after: 500,  run: function () { rootObj.pressEnter() } },
          { after: 1500, run: function () {} },
          done
        ])
        break

      // Enter submitting a typed password: no face check alongside it.
      case "enter-password":
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 500,  run: function () { rootObj.stock().typePassword("hunter2") } },
          { after: 500,  run: function () { rootObj.stock().submitTyped(1500); rootObj.pressEnter() } },
          { after: 2500, run: function () {} },
          done
        ])
        break

      // The same, with PAM saying no before the wrapper looks: the only thing
      // left to tell the two Enters apart is that the typed text changed.
      case "enter-fast-reject":
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 500,  run: function () { rootObj.stock().typePassword("hunter2") } },
          { after: 500,  run: function () { rootObj.stock().submitTyped(0); rootObj.pressEnter() } },
          { after: 1500, run: function () {} },
          done
        ])
        break

      // Enter twice while the first check runs: one check.
      case "enter-busy":
        rootObj.verifySeconds = 3
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 800,  run: function () { rootObj.pressEnter() } },
          { after: 1000, run: function () { rootObj.pressEnter() } },
          { after: 4500, run: function () {} },
          done
        ])
        break

      // Enter on a dark screen is a wake AND an Enter. One check.
      case "enter-wake":
        rootObj.verifySeconds = 2
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 1200, run: function () { rootObj.dpmsOn = false } },
          { after: 1500, run: function () { rootObj.dpmsOn = true; rootObj.pressEnter() } },
          { after: 4000, run: function () {} },
          done
        ])
        break

      // A no says what to do next.
      case "enter-no":
        rootObj.verifyCode = 1
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 800,  run: function () { rootObj.pressEnter() } },
          { after: 2000, run: function () {} },
          done
        ])
        break

      // A no just after a resume says the camera may still be waking. The
      // resume is a poll tick that arrives long after the one before it, which
      // is what a timer frozen by a suspend looks like from inside.
      case "enter-no-resumed":
        rootObj.verifyCode = 1
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 1500, run: function () { wrapper.lastTickAt = Date.now() - 20000 } },
          { after: 1500, run: function () { rootObj.pressEnter() } },
          { after: 2000, run: function () {} },
          done
        ])
        break

      // A resume belongs to its own lock: resume, unlock by password, lock
      // again by hand, and a no there is an ordinary no.
      case "enter-no-resume-last-lock":
        rootObj.verifyCode = 1
        rootObj.play([
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 1500, run: function () { wrapper.lastTickAt = Date.now() - 20000 } },
          { after: 1500, run: function () { rootObj.stock().passwordUnlock() } },
          { after: 300,  run: function () { rootObj.stock().beginLock() } },
          { after: 800,  run: function () { rootObj.pressEnter() } },
          { after: 2000, run: function () {} },
          done
        ])
        break

      // The binding exists only while a lock does.
      case "enter-arming":
        rootObj.play([
          { after: 800,  run: function () { rootObj.stock().beginLock() } },
          { after: 800,  run: function () { rootObj.stock().passwordUnlock() } },
          { after: 800,  run: function () { rootObj.stock().beginLock() } },
          { after: 800,  run: function () { rootObj.stock().passwordUnlock() } },
          { after: 800,  run: function () {} },
          done
        ])
        break

      default:
        console.log("HARNESS case unknown")
        Qt.exit(2)
    }
  }
}
