import QtQuick
import Quickshell
import Quickshell.Io

// Every call the GUI makes to the engine goes through here: one place that
// knows where the helpers live, how they are launched, and what their exit
// codes mean (plan-merged.md §2 rules 3 and 7, plan-gui.md §2.1).
//
// Two shapes, because the engine has two:
//
//   ask(argv, stdin, cb)              one JSON document on stdout, then exit
//   stream(argv, onEvent, onExit)     JSON lines both ways, stdin left open
//
// Nothing in this file decides anything. It classifies an exit code and hands
// back what the helper printed; the views do the deciding. That keeps the
// contract readable against §2 rather than scattered through the panel.
Item {
  id: root

  // Where this plugin is checked out. The unprivileged helpers ship inside it
  // (plan-engine.md §8.1), so the panel has to know its own directory.
  property string pluginDir: ""

  // Development only (plan-gui.md §2.1, §8): point at a directory of stubs and
  // every helper path below comes from it, with pkexec dropped -- a stub cannot
  // write root-owned state, so there is nothing for an owner prompt to protect.
  readonly property string devBin: Quickshell.env("OMARCHY_FACE_DEV_BIN") || ""
  readonly property bool dev: devBin !== ""

  readonly property string pluginBin: dev ? devBin : pluginDir + "/bin"
  readonly property string systemBin: dev ? devBin : "/usr/local/bin"

  // The fixed helper paths of plan-gui.md §2.1, as functions rather than
  // strings so a caller cannot accidentally join argv into one shell word.
  function statusArgv() {
    return [pluginBin + "/omarchy-face-status", "--json"]
  }

  function lockArgv(args) {
    return [pluginBin + "/omarchy-face-lock"].concat(args || [])
  }

  function identityArgv(args) {
    return [systemBin + "/omarchy-face-identity"].concat(args || [])
  }

  // Every store change, permission change, install, wiring and purge
  // (plan-merged.md §2 rule 2). pkexec draws the owner prompt before exec, so
  // the prompt is always the first thing that happens.
  function adminArgv(args) {
    var helper = systemBin + "/omarchy-face-admin"
    return (dev ? [helper] : ["pkexec", helper]).concat(args || [])
  }

  // The first install, and the only call that does not go through our own
  // polkit action -- the helper it would be annotated on does not exist yet
  // (plan-engine.md §5.1).
  //
  // The script's TEXT is passed inline rather than its path, so what polkit
  // authorised is exactly what runs: a `pkexec /bin/bash <path>` would have
  // authorised a path whose contents can change between the dialog and the
  // exec. The dialog says "run /bin/bash as the super user", with no message of
  // Face's own; Setup warns about that wording before the click
  // (plan-gui.md §4 row 3).
  //
  // In development there is nothing to install and nothing that may run as
  // root, so this becomes the stub's install-system.
  function firstInstallArgv(scriptText, targetDir, account) {
    if (dev) return [devBin + "/omarchy-face-admin", "install-system"]
    return ["pkexec", "/bin/bash", "-c", String(scriptText),
            "omarchy-face-install", String(targetDir), String(account)]
  }

  // --- launching ----------------------------------------------------------

  // `bash -c 'exec "$@"'` (Profiles' house form, plan-gui.md §0): argv stays an
  // array, the helper replaces bash so a signal reaches the helper and not a
  // wrapper, and bash still reports 126/127 itself when exec fails -- which is
  // how a missing helper produces an answer instead of a panel that waits.
  function launchArgv(argv) {
    return ["bash", "-c", "exec \"$@\"", "--"].concat(argv)
  }

  // Whether this argv draws polkit's owner dialog. It decides two things: what
  // 126/127 mean (below), and whether the call can be cancelled with a signal
  // at all (cancel(), §2 rule 7).
  function isPrompting(argv) {
    return !!argv && argv.length > 0 && String(argv[0]) === "pkexec"
  }

  // What an exit code means (plan-merged.md §2 rule 3):
  //
  //   0        ok        stdout is one JSON document, or prose (parsed null)
  //   1        error     {"error":code,…} on stdout
  //   3        busy      the store flock or the install job is held
  //   126/127  pkexec    the dialog was dismissed or nothing authorised it
  //            otherwise the helper cannot be run -- "missing", so the GUI can
  //            say "not installed" instead of "Checking…" forever
  //            (plan-gui.md §2.3's gate). pkexec is the only caller for which
  //            §2 assigns these codes a meaning, so this split is by argv[0].
  //
  // Collapsing 126 (the file is there but not executable) and 127 (there is no
  // such file) into one outcome is deliberate: every view renders both the same
  // way, because in both cases the helper cannot run and the fix is to install
  // the system half. The distinction is not lost -- the caller's warning logs
  // the raw code, so the journal reads `missing 126` or `missing 127` -- and a
  // 126 on an installed machine is the `system` row's business (a helper that
  // is not root:root 0755 is `broken` there, plan-engine.md §10.1), not a
  // second outcome string for every switch in the GUI to carry.
  function classify(argv, code) {
    if (code === 0) return "ok"
    if (code === 3) return "busy"
    if (code === 126 || code === 127) return isPrompting(argv) ? "owner_declined" : "missing"
    return "error"
  }

  // ask(argv, stdinText, cb) -> cb({outcome, ok, parsed, code, stdout})
  function ask(argv, stdinText, cb) {
    var job = { argv: argv || [], stdin: String(stdinText || ""), cb: cb || null }
    for (var i = 0; i < root.pool.length; i++) {
      if (!root.pool[i].busy) { root.startAsk(root.pool[i], job); return }
    }
    // Four at once is more than the GUI ever needs; a fifth waits rather than
    // letting a stuck helper spawn processes without bound.
    root.queue = root.queue.concat([job])
  }

  property var queue: []

  function startAsk(proc, job) {
    proc.busy = true
    proc.job = job
    proc.collected = ""
    proc.pending = job.stdin
    proc.stdinEnabled = true
    proc.command = root.launchArgv(job.argv)
    proc.running = true
  }

  function askFinished(proc, code) {
    var job = proc.job
    var out = String(proc.collected || "")
    proc.busy = false
    proc.job = null

    var parsed = null
    if (out.trim() !== "") {
      try { parsed = JSON.parse(out) } catch (e) { parsed = null }
    }
    var outcome = root.classify(job ? job.argv : [], code)
    // A failure always arrives with an `error` key, because that is what every
    // caller switches on. But the helper may have printed a perfectly good
    // document without one (§2.3's `{ok,incomplete:[]}` shapes, or an error
    // document carrying context beside the code), so fill the gap rather than
    // replacing the payload -- discarding it would throw away the only thing
    // that says *what* was incomplete.
    if (outcome !== "ok") {
      if (!parsed || typeof parsed !== "object") parsed = {}
      if (parsed.error === undefined) parsed.error = outcome
      if (parsed.code === undefined) parsed.code = code
    }

    // The slot is handed on before the callback runs: a callback that throws
    // must not strand whatever was queued behind it.
    if (root.queue.length > 0) {
      var next = root.queue[0]
      root.queue = root.queue.slice(1)
      root.startAsk(proc, next)
    }
    if (job && job.cb) job.cb({ outcome: outcome, ok: outcome === "ok", parsed: parsed, code: code, stdout: out })
  }

  // stream(argv, onEvent, onExit) -> the running process.
  //
  // stdin is left open: the caller writes command lines with send() and ends
  // the session with closeStdin(). To stop one, call cancel(proc) rather than
  // signalling it directly -- that is the function that knows a pkexec'd verb
  // runs as root and can only be cancelled by closing its stdin (§2 rule 7).
  function stream(argv, onEvent, onExit) {
    var proc = streamComponent.createObject(root, {
      command: root.launchArgv(argv),
      eventCb: onEvent || null,
      exitCb: onExit || null,
      argvCopy: argv
    })
    if (!proc) {
      console.warn("graveklar.face", "could not create a stream process for", JSON.stringify(argv))
      if (onExit) onExit({ outcome: "error", code: -1 })
      return null
    }
    root.live = root.live.concat([proc])
    proc.running = true
    return proc
  }

  // cancel(proc): stop a running stream, by the only means that works for it.
  //
  // plan-merged.md §2 rule 7 splits these two cases and the split is load
  // bearing, not stylistic:
  //
  //   user-side helper (omarchy-face-identity, -lock, -status)
  //       SIGTERM. `bash -c 'exec "$@"'` means the signal reaches the helper
  //       itself rather than a wrapper, and a killed `verify` frees the camera
  //       within 300 ms (§2.5) -- which is what Profiles' TERM-cancel test in
  //       phase 6 exercises.
  //
  //   pkexec'd admin verb
  //       NOT a signal. It runs as root; the user cannot signal it, and trying
  //       is not a no-op but a silent failure that leaves the GUI believing it
  //       cancelled something still running. Closing stdin is the only cancel,
  //       and for enroll-session it is also the documented one: EOF before
  //       `done` discards the session and writes nothing (§2.4).
  function cancel(proc) {
    if (!proc) return
    if (root.isPrompting(proc.argvCopy)) proc.closeStdin()
    else proc.signal(15)
  }

  // Live streams are held here as well as parented: a Process built at call
  // time and referenced only by the caller is garbage while it still runs.
  property var live: []

  function streamFinished(proc, code) {
    var next = []
    for (var i = 0; i < root.live.length; i++) if (root.live[i] !== proc) next.push(root.live[i])
    root.live = next
    if (proc.exitCb) proc.exitCb({ outcome: root.classify(proc.argvCopy, code), code: code })
    proc.destroy()
  }

  AskProcess { id: ask0 }
  AskProcess { id: ask1 }
  AskProcess { id: ask2 }
  AskProcess { id: ask3 }
  readonly property var pool: [ask0, ask1, ask2, ask3]

  // One slot of ask()'s pool. Reused rather than created per call, for the same
  // reason stream() keeps its references: a Process is not garbage until it has
  // stopped running.
  component AskProcess: Process {
    id: proc
    property bool busy: false
    property var job: null
    property string collected: ""
    property string pending: ""

    running: false
    stdinEnabled: true
    // waitForEnd, so the whole document is there when onExited reads it.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: proc.collected = text
    }
    onStarted: {
      if (proc.pending !== "") proc.write(proc.pending)
      proc.pending = ""
      // Closing the stream is what makes a verb that reads stdin return.
      proc.stdinEnabled = false
    }
    onExited: function (code, status) { root.askFinished(proc, code) }
  }

  Component {
    id: streamComponent

    Process {
      id: sp
      property var eventCb: null
      property var exitCb: null
      property var argvCopy: []

      running: false
      stdinEnabled: true

      // One JSON object per line, in both directions (§2.4). A line that is not
      // JSON is a helper bug, not a session end: it is logged and skipped, so a
      // stray warning on stdout cannot abandon a recording session.
      stdout: SplitParser {
        splitMarker: "\n"
        onRead: function (line) {
          var text = String(line || "").trim()
          if (text === "") return
          var event = null
          try { event = JSON.parse(text) } catch (e) {
            console.warn("graveklar.face", "ignoring a non-JSON line from", sp.argvCopy[0], text)
            return
          }
          if (sp.eventCb) sp.eventCb(event)
        }
      }

      function send(obj) { sp.write(JSON.stringify(obj) + "\n") }
      function closeStdin() { sp.stdinEnabled = false }

      onExited: function (code, status) { root.streamFinished(sp, code) }
    }
  }
}
