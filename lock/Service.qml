import QtQuick
import Quickshell
import Quickshell.Hyprland
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
//   · ONE face check per Enter on an empty password field, while locked
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

  // --- the on-screen line (post-ship revision) -------------------------------
  //
  // Every no used to be silent, and that was the single biggest thing wrong
  // with this feature: a check that ran and declined, a check still running,
  // and a check that never started are pixel-identical to somebody standing at
  // a dark screen. Months were lost to that here.
  //
  // What is written is Omarchy's OWN `failureMessage`, which its LockView
  // already renders in the password field's placeholder. Nothing is drawn by
  // this file, no surface is created, and no layer rule is asked for: the
  // alternative was Hyprland's `above_lock`, which would let ANY process
  // running as this account paint over the locked screen, and that is a
  // grotesque price for a status line.
  //
  // It is not a setting. It was one for about an hour, and a switch for "tell
  // me what the feature you switched on is doing" is a switch nobody should
  // have to find: face unlock on the lock screen IS this, and the silent
  // version was the bug. One switch, and it says what it does.
  //
  // `failureMessage` is deliberately NOT in contractProperties. If Omarchy
  // renames it, the line stops and the face check carries on -- the reverse
  // would switch face unlock off over a cosmetic property.
  readonly property bool messageSupported:
    stock.item !== null && ("failureMessage" in stock.item)

  // Never over a password being checked, and never when the switch is off.
  function showLine(text) {
    if (!root.messageSupported || !root.lockedNow) return
    if (stock.item.authenticatingPassword === true) return
    stock.item.failureMessage = text
  }

  // Only ever clears this file's own line. A real "Authentication failed" from
  // the password stack is not ours to wipe.
  function clearLine(mine) {
    if (!root.messageSupported || !stock.item) return
    if (String(stock.item.failureMessage) === mine) stock.item.failureMessage = ""
  }

  readonly property string lineChecking: "Looking for your face…"
  // Both say what to do next, because since Enter starts a check there is
  // something to do next other than typing. Short on purpose: LockView elides
  // the placeholder, and the room it leaves is 339 px of 18 px italic, or 295 px
  // with a fingerprint reader enrolled. The line this replaced -- "Face not
  // recognised — use your password." -- measured 360 px and never once fitted.
  // dev/g6-lock-offscreen.sh measures every line against the real font.
  readonly property string lineNo: "Not recognised — Enter to retry"
  // The same no, said differently inside `resumeWindowMs` of a resume. A
  // camera that has not finished waking up delivers black or no frames, and
  // the engine's answer to that is the same exit 1 as a stranger's face (the
  // client has two exit codes on purpose, omarchy-face-lock-verify:11-17).
  // So this does not claim to know it was the camera -- it says it may be.
  readonly property string lineNoResumed: "Camera waking? Enter to retry"

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
  // The Enter binding is registered with `<evalCommand> <lua>`, and the event
  // it raises is matched by name. Both are properties so the offscreen suite
  // can log the Lua instead of binding a real key, and listen for an event name
  // no running wrapper on this machine is listening for.
  property var evalCommand: ["hyprctl", "eval"]
  property string enterEvent: "omarchy-face-enter"

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
    // A lock already up by the time the composition is known to fit -- the stock
    // lock recovering a stranded one at shell start -- never saw the transition
    // that arms Enter.
    if (root.lockedNow) root.armEnter()
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
        // A resume belongs to the lock it happened in. Omarchy locks before it
        // suspends, so the resume of THIS lock is always seen after this line;
        // one left over from the last lock would put "Camera waking?" on a
        // lock taken by hand a few seconds after unlocking.
        root.resumedAt = 0
        root.log("lock " + root.lockGeneration + " begins; face waits for a wake or Enter")
        if (root.compat === "ok") root.armEnter()
        return
      }
      // Before the in-flight check below, and whatever its outcome: Enter goes
      // back to being just Enter the moment there is no lock to open.
      root.disarmEnter()
      if (root.attemptBusy && verifyProcess.running) {
        // The lock ended while a check was still in flight, which is almost
        // always the password winning the race. Its ANSWER is already void --
        // the generation check in attemptFinished sees to that -- but the
        // process is not, and it holds the infrared camera for the rest of
        // howdy's five seconds, now inside an unlocked session where something
        // else may want the sensor. Signalled rather than abandoned, for the
        // reason attemptSafety gives: the death is what makes the daemon let
        // go (post-ship revision).
        root.attemptCancelled = true
        root.log("the lock ended while a check was running: stopping it")
        verifyProcess.signal(15)
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

  // Whether any monitor was dark in the last sample. A wake can only follow a
  // blank, so this is what decides how hard to look -- see the poll below.
  property bool screenDark: false

  Timer {
    id: monitorPoll
    // How fast to look, which is not one number (post-ship revision).
    //
    // While the screen is lit there is nothing to catch: no wake can happen
    // until it has gone dark first, and a second is plenty for noticing that.
    // Once it IS dark the next thing to happen is the wake this whole feature
    // hangs on, and by then the poll is the slowest link in the chain -- the
    // engine needs about two seconds after it, and a person types a password
    // they know by heart in about three. A second of polling latency on top of
    // that loses the race, the face result lands after the password has been
    // accepted, and the wrapper throws it away as stale. Which is precisely
    // what kept happening.
    //
    // 250 ms while dark costs four `hyprctl` calls a second on a machine that
    // is locked and idle, and only for as long as it stays dark. It buys back
    // most of a second at the one moment that decides the outcome.
    interval: root.screenDark ? 250 : 1000
    repeat: true
    running: root.lockedNow
    // The first sample is taken at once rather than a second later, so the
    // baseline is "the screen as it was when the lock began" -- lit, for a lock
    // by hand -- and the blank that follows is seen as a change from it.
    triggeredOnStart: true
    onTriggered: {
      root.noteTick(Date.now())
      if (!monitorProcess.running) monitorProcess.running = true
    }
    onRunningChanged: if (!running) root.lastTickAt = 0
  }

  // --- a resume from sleep ----------------------------------------------------
  //
  // Omarchy locks before it suspends, so a suspend happens inside a lock and
  // inside this poll -- and a timer frozen by a suspend fires late. The stock
  // lock reads a resume off exactly this (its idleBlankTimer, Service.qml:418-
  // 427); so does this file, and for one purpose only: the no that follows a
  // resume gets `lineNoResumed` instead of `lineNo`. Nothing is delayed, and no
  // check is skipped or started because of it.
  property double lastTickAt: 0
  property double resumedAt: 0
  readonly property int resumeGapMs: 3000
  readonly property int resumeWindowMs: 15000

  function noteTick(now) {
    if (root.lastTickAt > 0 && now - root.lastTickAt > monitorPoll.interval + root.resumeGapMs) {
      root.resumedAt = now
      root.log("resumed from sleep (" + Math.round((now - root.lastTickAt) / 1000) + " s gap)")
    }
    root.lastTickAt = now
  }

  function recentlyResumed() {
    return root.resumedAt > 0 && Date.now() - root.resumedAt < root.resumeWindowMs
  }

  // --- Enter on an empty password field ------------------------------------
  //
  // The second way to ask, and the one a person can always reach: a wake needs
  // the screen to have gone dark first, and a key pressed on a lit lock screen
  // starts nothing (README, "The lock screen does not react to your face").
  //
  // WHY A HYPRLAND BINDING. This file cannot see the key. The password field
  // lives in the stock LockView, inside a WlSessionLockSurface that Quickshell
  // instantiates from a Component and exposes nowhere (plan-merged.md §1 row
  // 14), and an Enter on an empty field is dropped in LockView's own onAccepted
  // before the stock service hears of it (LockView.qml:171-175). So while a
  // lock is up, Hyprland is asked for one binding on Return and one on KP_Enter:
  //
  //   locked          it fires with a session lock holding the keyboard
  //   non_consuming   the key still reaches the password field -- a typed
  //                   password is submitted exactly as it was without Face
  //   hl.dsp.event    it runs no process: Hyprland writes `custom>>NAME` to its
  //                   event socket, which Quickshell.Hyprland already reads
  //
  // It is registered when a lock begins and removed when the lock ends, so an
  // unlocked session has no binding on Enter at all. It does not live in the
  // user's bindings.lua, so nothing of the user's is edited, and a config reload
  // (which drops runtime bindings) is answered by registering it again.
  //
  // WHAT THIS DOES NOT CHANGE. Any process running as this account can raise
  // the same event with `hyprctl dispatch`, exactly as it can already produce a
  // wake with `hyprctl dispatch dpms` -- both start one camera check, bounded by
  // the daemon's rate limit, and neither can make a face match. The README says
  // so. There is still no IpcHandler: nothing here opens a lock on anyone's say.
  //
  // WHICH ENTER. The binding fires for every Enter, including the one that
  // submits a typed password, and the event and the key arrive by different
  // paths in no promised order. So nothing is decided on the event itself:
  // `enterSettleMs` later, an Enter that submitted a password shows as either
  // `authenticatingPassword` or a change to the stock's `enteredPassword`
  // (onAccepted clears it, LockView.qml:173). An Enter on an empty field changes
  // neither, and only that one starts a check.

  property double passwordChangedAt: 0
  readonly property int enterSettleMs: 200
  property int enterCount: 0
  property bool enterArmed: false

  readonly property string armLua:
    'local old = _G.omarchy_face_enter_binds ' +
    'if old then for _, b in ipairs(old) do pcall(function() b:unbind() end) end end ' +
    'local t = {} ' +
    'for _, key in ipairs({"Return", "KP_Enter"}) do ' +
    'table.insert(t, hl.bind(key, hl.dsp.event("' + root.enterEvent + '"), ' +
    '{ locked = true, non_consuming = true })) end ' +
    '_G.omarchy_face_enter_binds = t'

  readonly property string disarmLua:
    'local old = _G.omarchy_face_enter_binds ' +
    'if old then for _, b in ipairs(old) do pcall(function() b:unbind() end) end end ' +
    '_G.omarchy_face_enter_binds = nil'

  // The event name is pasted into Lua above, so it may only ever be a plain word.
  readonly property bool enterEventValid: /^[a-z0-9-]{1,64}$/.test(root.enterEvent)

  function armEnter() {
    if (!root.enterEventValid) {
      console.warn("graveklar.face-lock", "refusing an Enter event name that is not a plain word")
      return
    }
    root.enterArmed = true
    root.runEval(root.armLua, "armed Enter for face")
  }

  // Also run once at start: a shell that died inside a lock left its binding
  // behind, and a stray binding would raise an event nobody acts on for every
  // Enter in the unlocked session.
  function disarmEnter() {
    root.enterArmed = false
    root.runEval(root.disarmLua, "")
  }

  // Serialised like the status writer: an arm and a disarm a moment apart must
  // land in that order, and the last one asked for is the one that must win.
  property var pendingEval: null

  function runEval(lua, success) {
    var job = { command: root.evalCommand.concat([lua]), success: success }
    if (evalProcess.running) { root.pendingEval = job; return }
    root.startEval(job)
  }

  function startEval(job) {
    evalProcess.success = job.success
    evalProcess.command = job.command
    evalSafety.restart()
    evalProcess.running = true
  }

  // `hyprctl eval` answers in milliseconds. One that does not -- a compositor
  // wedged mid-reload -- would hold every later arm and disarm in pendingEval
  // for good, so it is stopped, and its exit drains the queue as any other does.
  Timer {
    id: evalSafety
    interval: 5000
    onTriggered: if (evalProcess.running) {
      console.warn("graveklar.face-lock", "hyprctl eval did not answer; stopping it")
      evalProcess.signal(15)
    }
  }

  Process {
    id: evalProcess
    property string success: ""
    stdout: StdioCollector { id: evalOut; waitForEnd: true }
    onExited: function (code, status) {
      evalSafety.stop()
      var said = String(evalOut.text || "").trim()
      if (code !== 0)
        console.warn("graveklar.face-lock", "hyprctl eval failed (exit " + code + "):", said,
                     "- Enter will not start a face check on this lock")
      else if (evalProcess.success !== "")
        root.log(evalProcess.success)
      if (root.pendingEval !== null) {
        var job = root.pendingEval
        root.pendingEval = null
        root.startEval(job)
      }
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event) root.hyprlandEvent(String(event.name), String(event.data))
    }
  }

  // A config reload drops every runtime binding (measured: `hyprctl reload`
  // takes a registered binding's count from 1 to 0 and emits `configreloaded`),
  // and on a lock screen reloads are not rare: monitor daemons such as
  // hyprmoncfgd reload Hyprland's config when the display wakes -- which is
  // every blank and wake of every lock. So the binding is registered again, or
  // Enter would work only in the five seconds before a lock first blanks.
  //
  // An earlier revision did NOT re-register, so that `hyprctl reload` from a
  // TTY would get a swallowed Enter back if a Hyprland ever stopped honouring
  // `non_consuming` under a lock. That trade was wrong for the same reason, and
  // the way back is now the README's one-line `hyprctl eval` unbind instead.
  // A function rather than inline, so the offscreen suite can deliver a reload
  // without reloading the compositor it runs in.
  function hyprlandEvent(name, data) {
    if (name === "custom" && data === root.enterEvent) root.enterPressed()
    else if (name === "configreloaded" && root.enterArmed && root.lockedNow) {
      root.log("Hyprland reloaded its config: arming Enter again")
      root.armEnter()
    }
  }

  // `enteredPassword` is optional, like `failureMessage`: if Omarchy renames it,
  // `authenticatingPassword` still catches every password that is being
  // checked, and only a password rejected in under `enterSettleMs` is missed --
  // which costs one camera check, never an unlock.
  Connections {
    target: stock.item
    ignoreUnknownSignals: true
    function onEnteredPasswordChanged() { root.passwordChangedAt = Date.now() }
  }

  function enterPressed() {
    if (!root.lockedNow) return
    root.enterCount = root.enterCount + 1
    enterSettle.restart()
  }

  Timer {
    id: enterSettle
    interval: root.enterSettleMs
    onTriggered: root.enterSettled()
  }

  function enterSettled() {
    if (!root.lockedNow) return
    var sinceTyping = Date.now() - root.passwordChangedAt
    if (stock.item.authenticatingPassword === true || sinceTyping < root.enterSettleMs + 300) {
      root.log("Enter submitted a password: no face check")
      return
    }
    root.startAttempt("Enter")
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

    // Recorded before the baseline is consulted, so the very first sample of a
    // lock already sets the poll's rate rather than leaving it a tick behind.
    var dark = false
    for (var key in now) if (!now[key].dpms || now[key].disabled) dark = true
    root.screenDark = dark

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
    root.startAttempt("the screen woke")
  }

  // --- one attempt per wake or Enter ---------------------------------------

  property bool attemptBusy: false
  property string attemptName: ""
  // Set when THIS file stopped the check, so its exit can be told apart from an
  // answer. Without it a cancelled check exits 143 and reads as "the face said
  // no", which is a different thing entirely and would be the only record left.
  property bool attemptCancelled: false

  // Longer than anything downstream: the client's own receive timeout is 20 s
  // and the daemon's engine runs under `timeout -k 2 8`. This only ever fires
  // when the check did not come back at all, and what it protects is the rest
  // of this lock -- an attempt that never ends would leave `attemptBusy` set
  // and no later wake would be tried.
  readonly property int attemptSafetyMs: 30000

  // `why` is what the journal says started it: "the screen woke" or "Enter".
  // An Enter that wakes a dark screen is both, and whichever lands first is the
  // one check; the other meets `attemptBusy`.
  function startAttempt(why) {
    // A second key press during a check is ignored: no queued request, so no
    // `camera_busy` from the daemon and no slot spent out of the shared rate
    // budget (plan-engine.md §6.2).
    if (root.attemptBusy) {
      root.log(why + " while a check was running: ignored")
      return
    }
    if (!root.lockedNow) return

    root.attemptBusy = true
    root.attemptGeneration = root.lockGeneration
    root.attemptCount = root.attemptCount + 1
    root.attemptName = ""
    root.attemptCancelled = false
    root.lastOutcome = "checking"
    root.log(why + ": one face check, in lock generation " + root.lockGeneration)
    root.showLine(root.lineChecking)
    // Armed BEFORE the process starts, because a command that cannot be executed
    // at all fails synchronously inside the next line -- and the handler for that
    // stops this timer, which it cannot do if the timer has not been armed yet.
    attemptSafety.restart()
    verifyProcess.running = true
  }

  Process {
    id: verifyProcess
    command: root.verifyCommand
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.attemptName = String(text || "").trim()
    }
    onExited: function (code, status) { root.attemptFinished(code) }

    // A command that cannot be executed AT ALL -- Face removed with the clone
    // left behind, the one state `omarchy plugin remove` without Remove Face
    // produces -- never emits `exited`: Quickshell puts `running` straight back
    // to false and logs. Without this the check would be recorded as still in
    // flight, and no later wake in this lock would be tried until the safety
    // timer gave up on it. For an ordinary exit this runs second and finds
    // nothing to do, because `exited` is emitted before `running` changes.
    onRunningChanged: if (!running && root.attemptBusy) root.attemptFinished(-1)
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

  // Whichever of the two signals above arrives first is the one that answers, and
  // the second finds nothing left to do.
  function attemptFinished(code) {
    if (!root.attemptBusy) return
    attemptSafety.stop()
    root.attemptBusy = false
    var who = root.attemptName
    root.attemptName = ""

    // Stopped by the lock ending, not answered. Counted and said with the stale
    // results, because that is exactly what it is: a check for a lock that is
    // over. It must NOT fall through to the branch below -- a cancelled check
    // exits 143, which would be recorded as the face saying no, and "Face did
    // not recognise you" is a lie about a check that never finished.
    //
    // The generation guard further down still stands and is still exercised:
    // signalling a process is a request, and one already on its way to exiting
    // 0 can beat it.
    if (root.attemptCancelled) {
      root.attemptCancelled = false
      root.lastOutcome = "stale"
      root.staleCount = root.staleCount + 1
      // The same sentence the generation guard below says, because from a
      // reader's side it is the same event: a result for a lock that is over,
      // dropped. WHY this one was dropped is already in the journal, logged at
      // the moment it was stopped.
      root.say("stale face result ignored")
      root.clearLine(root.lineChecking)
      return
    }

    if (code !== 0) {
      // Every no is silent. The password field is already on screen and works;
      // a face that did not match, a camera that was busy, a rate limit and a
      // closed lid are all the same thing from here -- this lock stays locked.
      root.lastOutcome = "no"
      root.log("the face check said no (exit " + code + ")")
      // Replaces this file's own "looking" line, so the two never stack. Left
      // on screen: Omarchy clears it the moment a key is typed into the
      // password field, which is exactly when it stops being true.
      root.clearLine(root.lineChecking)
      root.showLine(root.recentlyResumed() ? root.lineNoResumed : root.lineNo)
      return
    }

    // The two questions that decide whether a yes still applies: is this still
    // a lock, and is it still THE lock this check was started for.
    if (!root.lockedNow || root.attemptGeneration !== root.lockGeneration) {
      root.lastOutcome = "stale"
      root.staleCount = root.staleCount + 1
      root.say("stale face result ignored")
      root.clearLine(root.lineChecking)
      return
    }

    root.lastOutcome = "unlocked"
    root.clearLine(root.lineChecking)
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

  Component.onCompleted: {
    root.log("loaded; Omarchy's lock screen is at " + root.stockUrl)
    root.disarmEnter()
  }
}
