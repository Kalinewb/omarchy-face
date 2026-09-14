import QtQuick
import Quickshell
import Quickshell.Io

// The lock-screen wrapper: Omarchy's OWN lock screen, with a face check added
// beside it (plan-engine.md §9, plan-merged.md §3).
//
// THERE IS NO OMARCHY CODE IN THIS FILE, and there must never be. The whole
// lock screen -- the session lock, the password field, the fingerprint flow,
// the `lock` IPC handler, the blanking -- is the file this Loader points at,
// loaded from wherever Omarchy is installed, at runtime. When Omarchy updates
// its lock screen, the next shell start runs the new code and nothing here is
// rebuilt, re-patched or re-synced (E1). What this file adds is:
//
//   · a poll of the monitors while the stock lock says it is locked
//   · ONE face check per wake, and never on locking
//   · finishUnlock() when that check says yes, and the lock is still the lock
//     the check was started for
//   · a line in $XDG_RUNTIME_DIR/omarchy-face/lock-status.json saying whether
//     the composition still fits
//
// What it does NOT do, and each of these is a decision:
//
//   · it runs no PAM stack of its own. The old, deleted version of this plugin
//     had an /etc/pam.d/omarchy-lock-face, and this plan rejects it: a third
//     PamContext here would run as the user anyway (E10), so it could not read
//     the models, and it would put a second authenticator on the lock screen.
//     The face check is `omarchy-face-lock-verify`, a socket client that asks a
//     root daemon (plan-engine.md §6). Its exit code is the whole answer.
//   · it registers no IpcHandler. Any process running as this account can call
//     an IPC target; the one object in this session that can open a lock screen
//     is not going to offer a way in.
//   · it draws nothing. Nothing can draw over a session-lock surface anyway
//     (plan-merged.md §1 row 14), so face on the lock screen is silent and is
//     made predictable by acting on a wake instead.
//
// WHY A WAKE, AND NEVER ON LOCKING (plan-merged.md §3). A person who locks by
// hand is still sitting in front of the camera. Arming face on `lockRequested`
// would match them within a second and the lock would undo itself every time.
// Fingerprint does not have this problem because it needs a touch; a face is
// given off without asking. So: the stock lock blanks the display 5 s after
// locking (`idleBlankTimer`, Service.qml:414-432) and every input calls
// `runWake()` (:167-170), which turns it back on -- and that transition, read
// off `hyprctl -j monitors`, is what arms one check (E7).
Item {
  id: root

  // Injected by the host when the service is created (shell.qml:925-932).
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  // Omarchy's lock screen, wherever this machine keeps it. An absolute URL, so
  // the loaded file resolves its own same-directory types (LockView.qml) and
  // its own `qs.*` imports out of the running shell (E1).
  readonly property string stockUrl: omarchyPath !== ""
    ? "file://" + omarchyPath + "/shell/plugins/lock/Service.qml"
    : ""

  // loading | ok | incompatible | failed (plan-merged.md §1 row 12). `n/a` and
  // `otherLock` are the status helper's answers about enablement, never this
  // file's: it only exists when it is loaded.
  property string compat: "loading"
  property var missing: []

  // The five public names this wrapper depends on (E3). Four properties and one
  // function; if Omarchy renames any of them, face turns itself off here and
  // the stock lock screen goes on working exactly as Omarchy ships it.
  readonly property var contractProperties: ["lockRequested", "pendingSessionLock",
                                             "locked", "authenticatingPassword"]

  // The loaded stock instance, for a test harness to reach. Nothing outside
  // this process can: there is no IPC handler and the service has no visual
  // parent (shell.qml:921-924, authentication services are kept out of the
  // object graph).
  readonly property var stockItem: stock.item

  // The two commands, as properties rather than literals, so dev/g6-lock-*.sh
  // can drive the wake logic without a compositor and without a camera. The
  // defaults are what ships and what runs.
  property var monitorCommand: ["hyprctl", "-j", "monitors"]
  property var verifyCommand: ["/usr/local/bin/omarchy-face-lock-verify"]

  // Not readonly, for the same reason the two commands above are properties:
  // the offscreen suite points it at a temporary directory so a test run never
  // writes the status this machine's Setup view is reading.
  property string statusDir: {
    var dir = Quickshell.env("XDG_RUNTIME_DIR") || ""
    return dir === "" ? "" : dir + "/omarchy-face"
  }

  function log(message) { console.log("graveklar.face-lock", message) }

  // The journal line for a lock that face opened. It is advisory and forgeable
  // by anything running as this account -- `logger` is unprivileged -- which is
  // exactly why the README says lock-screen attribution is weaker than sudo's
  // (plan-merged.md §5 risk 5). Detached, so nothing here waits on it and no
  // Process lifetime has to be managed for a one-line write.
  // Wrapped, and that is not defensive habit: `say()` is called on the line
  // BEFORE `finishUnlock()`, so anything it threw would stop a lock opening for
  // a face that was recognised -- a journal line taking the feature down with it.
  function say(message) {
    log(message)
    try {
      Quickshell.execDetached(["logger", "-t", "omarchy-face", String(message)])
    } catch (error) {
      console.warn("graveklar.face-lock", "could not write a journal line:", error)
    }
  }

  // --- the composition ------------------------------------------------------

  Loader {
    id: stock
    active: root.stockUrl !== ""
    source: root.stockUrl

    onLoaded: {
      // Handed on AFTER creation on purpose, guarded by `in`: neither name is
      // read by the stock lock while it is being constructed, and a future
      // stock that dropped one would be an `incompatible` below rather than a
      // Loader that refused to build it at all.
      if (item) {
        if ("omarchyPath" in item) item.omarchyPath = root.omarchyPath
        if ("shell" in item) item.shell = root.shell
      }
      root.checkContract()
    }

    onStatusChanged: if (status === Loader.Error) root.loadFailed()
  }

  function checkContract() {
    var item = stock.item
    if (!item) { root.loadFailed(); return }
    var gone = []
    for (var i = 0; i < root.contractProperties.length; i++)
      if (!(root.contractProperties[i] in item)) gone.push(root.contractProperties[i])
    if (typeof item.finishUnlock !== "function") gone.push("finishUnlock()")
    root.missing = gone
    root.compat = gone.length > 0 ? "incompatible" : "ok"
    if (gone.length > 0)
      console.warn("graveklar.face-lock", "Omarchy's lock screen changed; face is off on it. Missing:",
                   gone.join(", "))
    else
      root.log("composed with Omarchy's lock screen at " + root.stockUrl)
    root.writeStatus()
  }

  // A Loader error is the lock path having moved, or the stock file itself
  // being broken. Either way there is no stock instance in here, so the `lock`
  // IPC handler -- which lives inside that file (E3) -- does not exist either:
  // to everything outside, this is "nothing answers", and the Face service's
  // health check disables the clone and brings Omarchy's own lock back
  // (plan-engine.md §9.3a).
  function loadFailed() {
    root.missing = ["Omarchy's lock screen could not be loaded from " + root.stockUrl]
    root.compat = "failed"
    console.warn("graveklar.face-lock", "could not load", root.stockUrl,
                 "- Omarchy's own lock screen is what should be running here")
    root.writeStatus()
  }

  // --- the lock generation (plan-engine.md §9.2) ----------------------------
  //
  // An attempt takes up to ~6 s from the wake (1 s of poll plus howdy's 5 s).
  // Inside that window the user can type their password, unlock, and lock again
  // by hand or by idle. Without a generation counter the STALE attempt then
  // returns 0, sees `lockRequested` true, and opens a lock nobody's face was
  // ever checked against. So every false → true transition takes a new
  // generation, an attempt records the generation it was started in, and its
  // exit is honoured only while the two still match.

  property int lockGeneration: 0
  property int attemptGeneration: -1

  // Observability for the offscreen suite, and for reading the journal after a
  // live test. Nothing decides on these.
  property int wakeCount: 0
  property int attemptCount: 0
  property int staleCount: 0
  property string lastOutcome: ""

  readonly property bool lockedNow: root.compat === "ok" && stock.item !== null
                                    && stock.item.lockRequested === true

  Connections {
    target: stock.item
    // A stock whose property was renamed is `incompatible` already; this keeps
    // the connection from being a second, louder way of saying so.
    ignoreUnknownSignals: true
    function onLockRequestedChanged() {
      if (!stock.item) return
      if (stock.item.lockRequested) {
        root.lockGeneration = root.lockGeneration + 1
        root.log("lock " + root.lockGeneration + " begins; face waits for the screen to wake")
      }
    }
  }

  // --- the wake poll (E7) ---------------------------------------------------
  //
  // One `hyprctl -j monitors` a second, and only while the stock lock says it
  // is locked, so an unlocked session pays nothing. A monitor's `dpmsStatus`
  // going false → true is the display coming back on; `disabled` going
  // true → false is the same thing in clamshell mode, where Omarchy toggles the
  // internal monitor rather than DPMS.

  property var monitorBaseline: null
  property int baselineGeneration: -1

  Timer {
    id: monitorPoll
    interval: 1000
    repeat: true
    running: root.lockedNow
    // The first sample is taken at once rather than a second later, so the
    // baseline is "the screen as it was when the lock began" -- lit, for a lock
    // by hand -- and the blank that follows is seen as a change from it.
    triggeredOnStart: true
    onTriggered: if (!monitorProcess.running) monitorProcess.running = true
  }

  Process {
    id: monitorProcess
    command: root.monitorCommand
    stdout: StdioCollector { id: monitorOut; waitForEnd: true }
    onExited: function (code, status) {
      // A compositor that did not answer is not a wake. Nothing is remembered
      // from it either: the baseline stays what it was, so a wake that happens
      // across a failed poll is still seen by the next one.
      if (code !== 0) return
      root.sample(String(monitorOut.text || ""))
    }
  }

  function sample(text) {
    if (!root.lockedNow) return

    var monitors = null
    try { monitors = JSON.parse(text) } catch (e) { return }
    if (!Array.isArray(monitors)) return

    var now = ({})
    for (var i = 0; i < monitors.length; i++) {
      var monitor = monitors[i]
      if (!monitor || !monitor.name) continue
      now[String(monitor.name)] = { dpms: monitor.dpmsStatus === true,
                                    disabled: monitor.disabled === true }
    }

    // A baseline belongs to one lock. Checked here rather than cleared in the
    // transition handler, because the poll's first tick and that handler both
    // run off the same property change and their order is not this file's to
    // assume.
    var previous = root.baselineGeneration === root.lockGeneration ? root.monitorBaseline : null
    root.monitorBaseline = now
    root.baselineGeneration = root.lockGeneration
    if (!previous) return

    var woke = false
    for (var name in now) {
      var was = previous[name]
      // A monitor plugged in while the session is locked has nothing to have
      // woken from, and is deliberately not a wake: nobody pressed anything.
      if (!was) continue
      if (!was.dpms && now[name].dpms) woke = true
      if (was.disabled && !now[name].disabled) woke = true
    }
    if (!woke) return

    root.wakeCount = root.wakeCount + 1
    root.startAttempt()
  }

  // --- one attempt per wake -------------------------------------------------

  property bool attemptBusy: false
  property string attemptName: ""

  // Longer than anything downstream: the client's own receive timeout is 20 s
  // and the daemon's engine runs under `timeout -k 2 8`. This only ever fires
  // when the check did not come back at all, and what it protects is the rest
  // of this lock -- an attempt that never ends would leave `attemptBusy` set
  // and no later wake would be tried.
  readonly property int attemptSafetyMs: 30000

  function startAttempt() {
    // A second key press during a check is ignored: no queued request, so no
    // `camera_busy` from the daemon and no slot spent out of the shared rate
    // budget (plan-engine.md §6.2).
    if (root.attemptBusy) {
      root.log("the screen woke again while a check was running: ignored")
      return
    }
    if (!root.lockedNow) return

    root.attemptBusy = true
    root.attemptGeneration = root.lockGeneration
    root.attemptCount = root.attemptCount + 1
    root.attemptName = ""
    root.lastOutcome = "checking"
    root.log("the screen woke: one face check, in lock generation " + root.lockGeneration)
    verifyProcess.running = true
    attemptSafety.restart()
  }

  Process {
    id: verifyProcess
    command: root.verifyCommand
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.attemptName = String(text || "").trim()
    }
    onExited: function (code, status) { root.attemptFinished(code) }
  }

  Timer {
    id: attemptSafety
    interval: root.attemptSafetyMs
    onTriggered: {
      if (!verifyProcess.running) { root.attemptBusy = false; return }
      console.warn("graveklar.face-lock", "the face check did not answer; stopping it")
      // Signalled, not abandoned: the check runs as this account, and its death
      // is what makes the daemon let go of the camera. `attemptBusy` is cleared
      // by the exit that follows, never here -- a second check started while
      // the first still held the sensor would only meet `camera_busy`.
      verifyProcess.signal(15)
    }
  }

  function attemptFinished(code) {
    attemptSafety.stop()
    root.attemptBusy = false
    var who = root.attemptName
    root.attemptName = ""

    if (code !== 0) {
      // Every no is silent. The password field is already on screen and works;
      // a face that did not match, a camera that was busy, a rate limit and a
      // closed lid are all the same thing from here -- this lock stays locked.
      root.lastOutcome = "no"
      root.log("the face check said no (exit " + code + ")")
      return
    }

    // The two questions that decide whether a yes still applies: is this still
    // a lock, and is it still THE lock this check was started for.
    if (!root.lockedNow || root.attemptGeneration !== root.lockGeneration) {
      root.lastOutcome = "stale"
      root.staleCount = root.staleCount + 1
      root.say("stale face result ignored")
      return
    }

    root.lastOutcome = "unlocked"
    root.say("unlocked by face: " + (who !== "" ? who : "unattributed"))
    stock.item.finishUnlock()
  }

  // --- lock-status.json (plan-merged.md §2.6) -------------------------------
  //
  // The only thing this wrapper writes. The Face service watches it and raises
  // one notification per new reason; this file never notifies (plan-merged.md
  // §1 row 13). Nothing ever deletes it: it is read as valid only when its `at`
  // is newer than the running shell's start time, which is what stops a wrapper
  // that never compiled from leaving a stale `ok` behind.

  property string pendingStatus: ""

  function writeStatus() {
    if (root.statusDir === "") return
    var doc = JSON.stringify({ compat: root.compat, missing: root.missing, at: Date.now() })
    if (statusWriter.running) { root.pendingStatus = doc; return }
    root.pendingStatus = ""
    statusWriter.command = ["bash", "-c", root.writeScript, "--", root.statusDir, doc]
    statusWriter.running = true
  }

  // Same-directory temp plus rename, so a reader never sees half a document.
  // $XDG_RUNTIME_DIR is this account's own 0700 directory, which is why there
  // is no mode to set here.
  readonly property string writeScript:
    'dir=$1; doc=$2; mkdir -p "$dir" || exit 1; tmp=$dir/.lock-status.json.$$; ' +
    'printf %s "$doc" >"$tmp" && mv -f "$tmp" "$dir/lock-status.json" || { rm -f "$tmp"; exit 1; }'

  Process {
    id: statusWriter
    onExited: function (code, status) {
      if (code !== 0) console.warn("graveklar.face-lock", "could not write lock-status.json")
      if (root.pendingStatus !== "") {
        var doc = root.pendingStatus
        root.pendingStatus = ""
        statusWriter.command = ["bash", "-c", root.writeScript, "--", root.statusDir, doc]
        statusWriter.running = true
      }
    }
  }

  Component.onCompleted: root.log("loaded; Omarchy's lock screen is at " + root.stockUrl)
}
