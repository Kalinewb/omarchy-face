import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "common"
import "common/faceroute.js" as Route

// Face ID's state and the questions views ask of it: the status document, the
// two watched files, the view stack and the engine seam. No window, no button
// and no IPC -- the two homes of the views put those around it.
//
// It exists once per home:
//
//   * FacePanel.qml (the stock bar's popup, `hosted: false`) -- polls every
//     30 s whether or not the popup is open, because the bar button needs an
//     answer either way;
//   * Surface.qml (the notch's panel, `hosted: true`) -- reads once when it is
//     created (that read is what `available` rests on), then polls only while
//     the panel is open, since the widget's own model keeps the 30 s probe.
//
// What must NOT happen here: a write under ~/.config/omarchy/plugins. Any write
// there reloads every plugin bar widget (plan-engine.md E13), which destroys
// the popup and everything it was driving, and a notch integration with it.
// Exactly three flows in the finished plugin write that folder, each as its
// last step and each announced first (plan-gui.md §1); none of them is here.
Item {
  id: root

  // The home this model lives in. `hosted` is true only inside a surface host's
  // panel: colours then come from `surfaceHost`, and a request to record a face
  // pushes the enrol view in place instead of asking the service for a card.
  property bool hosted: false
  property var bar: null
  property var surfaceHost: null

  // Whether the home is showing the views: the popup's own `opened`, or the
  // host's `panelOpen`. The home binds it.
  property bool opened: false

  // The home closes itself on this; a view's `panel.close()` is this signal.
  signal closeRequested()
  // The home opens itself on this, once `openAt`'s read has answered. A hosted
  // home is opened by the host, so nothing connects to it there.
  signal openRequested()

  function close() { root.closeRequested() }

  // --- the palette a view draws with ----------------------------------------
  //
  // Hosted, every colour comes from the host and none from the theme: a panel
  // drawn inside the notch uses the notch's colours and radius (SURFACE-HOSTING
  // section 4). The host has no "urgent" colour -- in the notch accent equals
  // foreground -- so an error is told apart by its words and glyph, never by
  // hue alone.

  readonly property bool inHost: hosted && surfaceHost !== null
  readonly property color foreground: inHost ? surfaceHost.foreground
                                    : (bar ? bar.foreground : Commons.Color.foreground)
  readonly property color accent: inHost ? surfaceHost.accent : Commons.Color.accent
  readonly property color urgent: inHost ? surfaceHost.accent : Commons.Color.urgent
  readonly property color dim: inHost ? surfaceHost.secondary : Qt.darker(foreground, 1.55)
  // The enrol view's names for the same roles (plan-face-enroll.md section 3).
  readonly property color secondary: dim
  readonly property bool reducedMotion: Quickshell.env("OMARCHY_REDUCED_MOTION") === "1"
                                        || Quickshell.env("NOTCH_REDUCED_MOTION") === "1"
  readonly property string fontFamily: inHost ? surfaceHost.fontFamily
                                     : (bar ? bar.fontFamily : Style.font.family)

  // The radius of a rounded thing `size` tall: the host's own (never more than
  // half of `size`) inside a host, the theme's elsewhere, as the views always
  // used.
  function radiusFor(size) {
    return inHost ? surfaceHost.radiusFor(size) : Style.cornerRadius
  }

  // This plugin's own directory, taken from where this file was loaded rather
  // than assembled from $HOME: the shell strips __sourceDir from third-party
  // manifests, and a hardcoded path is wrong the moment the plugin is checked
  // out anywhere else.
  // A URL is percent-encoded; a path is not. Without the decode, a checkout
  // under "~/Work/omarchy face" or a directory containing "#" hands the helper
  // argv a path with "%20" in it, which resolves to nothing at all -- and the
  // failure reads as "helper missing", the one diagnosis that sends you looking
  // in the wrong place.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url).replace(/\/+$/, "")
  }

  // --- state (plan-gui.md §2.3) -------------------------------------------

  // The whole engine → GUI read, exactly as §2.2 defines it. null until the
  // first answer; statusOutcome says why when it stays null.
  property var status: null
  property string statusOutcome: ""
  property bool statusBusy: false
  // One follow-up read, remembered rather than dropped (see refresh()).
  property bool refreshQueued: false

  readonly property var rows: status && Array.isArray(status.rows) ? status.rows : []
  readonly property var config: status && status.config ? status.config : ({})
  readonly property var lockState: status && status.lock ? status.lock : ({})

  // A row by id, so a view can ask for "engine" without walking the array.
  function row(id) {
    for (var i = 0; i < rows.length; i++) if (rows[i] && rows[i].id === id) return rows[i]
    return null
  }

  function rowState(id) {
    var r = row(id)
    return r ? String(r.state || "unknown") : ""
  }

  // Read on open, after every write, and on a timer. `omarchy-face-status`
  // never prompts, never opens the camera and never needs root (§2 rule 1), so
  // polling it costs a subprocess and nothing else.
  //
  // A call that arrives while a read is in flight is QUEUED, not dropped. It was
  // dropped until this was found in use: the 30 s poll and the follow-up read a
  // verb makes when it lands overlap often enough, and the one that lost is
  // always the one that knew something -- the verb's. A switch in Settings shows
  // `config.sudo` again the moment its `pendingSudo` clears, so a dropped
  // follow-up meant a toggle that visibly fell back to the old value and stayed
  // there until the next tick, up to thirty seconds later. At most one is
  // remembered: the point is the freshest answer, and a queue of reads for a
  // document that is re-read every second of the day is a subprocess storm, not
  // a fix (post-ship revision, plan-gui.md §2.3).
  function refresh() {
    if (root.statusBusy) { root.refreshQueued = true; return }
    root.statusBusy = true
    root.refreshQueued = false
    engine.ask(engine.statusArgv(), "", function (result) {
      root.statusBusy = false
      root.statusOutcome = result.outcome
      if (result.outcome === "ok" && result.parsed && typeof result.parsed === "object") {
        root.status = result.parsed
      } else {
        // Keep the last good document rather than blanking the views: a status
        // helper that fails once should not empty a popup someone is reading.
        if (result.outcome === "missing") root.status = null
        console.warn("kalinewb.face", "status read failed:", result.outcome, result.code)
      }
      // Somebody asked while this one was out, and what they knew has not been
      // read yet. Ask again -- including after a failure, which is exactly when
      // the queued caller's answer is the one worth having.
      if (root.refreshQueued) { root.refreshQueued = false; root.refresh() }
    })
  }

  // --- the bar button's state (plan-gui.md §3) ----------------------------
  //
  // Five states, and only the last two are at full strength: the glyph is bright
  // when a face could actually authenticate someone, or when something is
  // broken. A button that looked "on" while nothing was set up would be the one
  // lie on the surface that is always visible.

  // The rows that mean "this machine is not set up yet" (plan-merged.md §1
  // row 3). `sudo`, `polkit-1` and `lock` are deliberately not among them:
  // they are settings and failures, not steps.
  readonly property var setupRowIds: ["legacy", "camera", "system", "engine", "people"]

  readonly property bool setupNeeded: {
    for (var i = 0; i < setupRowIds.length; i++) {
      var r = row(setupRowIds[i])
      if (!r || String(r.state) !== "ok") return true
    }
    return false
  }

  readonly property var brokenRow: {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i] && String(rows[i].state) === "broken") return rows[i]
    }
    return null
  }

  readonly property string lockCompat: lockState && lockState.compat ? String(lockState.compat) : ""
  readonly property bool installFailed: String(installDoc.state || "") === "failed"
  readonly property bool lockAttention: lockCompat === "incompatible" || lockCompat === "failed"
  readonly property bool attention: brokenRow !== null || lockAttention || installFailed

  readonly property int sudoFaces: people && typeof people.sudo_faces === "number" ? people.sudo_faces : 0

  readonly property string barState: {
    if (status === null) return "unknown"
    if (attention) return "attention"
    if (setupNeeded) return "setup"
    if (!config.sudo) return "off"
    return sudoFaces > 0 ? "on" : "off"
  }

  // Where a click goes. Face's own failures open Setup; a lock screen that
  // stopped working opens Settings, which is where its switch and its reason
  // both live (plan-gui.md §3, §6.1).
  readonly property string barTarget: {
    if (barState === "attention") return brokenRow === null && lockAttention ? "settings" : "setup"
    if (barState === "off" || barState === "on") return "people"
    return "setup"
  }

  readonly property string barTooltip: {
    if (barState === "unknown")
      return statusOutcome === "missing" ? "Face ID — not installed" : "Face ID — checking"
    if (barState === "attention") {
      if (brokenRow) return "Face ID — " + String(brokenRow.detail || brokenRow.label || "something is wrong")
      if (installFailed) return "Face ID — the engine build failed"
      return "Face ID — face is off on the lock screen"
    }
    if (barState === "setup") return "Face ID — set up"
    if (barState === "off") return "Face ID — off"
    // Both halves for the lock screen: the setting, and the wrapper actually
    // being the lock screen. Either alone is a face tried nowhere.
    return "Face ID — sudo · " + sudoFaces + (sudoFaces === 1 ? " face" : " faces")
           + (config.lock && lockState.enabled === true ? " · lock screen" : "")
  }

  // --- view stack (plan-gui.md §2.2) --------------------------------------

  // Profiles' stack: every view is reached from somewhere, and "back" means the
  // place it was opened from. Esc pops; Esc on the root view closes.
  property var viewStack: ["setup"]
  readonly property string view: viewStack[viewStack.length - 1]

  // Which person the person view is showing. Empty outside it.
  property string personName: ""

  function pushView(v) { viewStack = viewStack.concat([v]) }
  function popView() { if (viewStack.length > 1) viewStack = viewStack.slice(0, -1) }
  function resetView(v) { viewStack = [v] }

  // Every view but Setup opens ON TOP of Setup, never alone -- so the header's
  // Back button (`visible: viewStack.length > 1`, below) always has somewhere
  // to go, and Setup's People / Settings / Remove row is always one click
  // away. Real gap found via live use: a fully set-up machine's bar click
  // opened straight to People with `viewStack == ["people"]` -- no back
  // button, no click path to Settings or Remove, only Esc, which closes the
  // whole popup (post-ship revision).
  function openWithBase(v) {
    root.viewStack = (v === "setup" || v === "") ? ["setup"] : ["setup", v]
  }

  function openPerson(name) {
    root.personName = String(name || "")
    root.pushView("person")
  }

  // --- the handoff back from a recording card (plan-gui.md §5.3) ------------
  //
  // `open(view, name)` is not an ordinary navigation: it is the announcement
  // that an `enroll-session` has just committed, and it arrives at the one
  // moment the watched documents are known to be out of date. people.json was
  // rewritten milliseconds ago, by temp + rename, which drops the inotify watch
  // on the inode this FileView is holding -- so nothing has told it yet.
  //
  // A reload is asynchronous: measured on this machine it lands about 110-145 ms
  // after it is asked for. Opening first and reloading after therefore paints
  // the first frames of the view -- the ones somebody is watching appear -- from
  // the store as it was BEFORE the recording: an appearance count short by the
  // appearance they just took, or a person who does not exist yet. So the read
  // is started first and the view is shown on its answer.
  //
  // The guard timer is the other half: a popup that never opened because a file
  // read stalled would be a worse failure than a stale count (post-ship
  // revision).
  property var pendingOpen: null
  readonly property int pendingOpenMs: 400

  function openAt(viewName, name) {
    var v = String(viewName || "")
    var who = String(name || "")
    if (v !== "" && root.viewChrome[v] === undefined) return "unknown view: " + v
    // The enrol view needs a person, an appearance and a label, which a view
    // name and one string cannot carry: it is reached through showEnrol().
    if (v === "enrol" || v === "test") return "unknown view: " + v
    if (v === "person" && who === "") {
      // A person view with no person is a page that can only say "No such
      // person: ". Open the popup where it was and say why, rather than
      // rendering that.
      root.openRequested()
      return "person needs a name"
    }
    root.pendingOpen = { view: v, name: who }
    root.reloadWatched()
    root.refresh()
    pendingOpenGuard.restart()
    return "ok"
  }

  // --- the handoff back from the Face service (Service.qml, switchLock) ------
  //
  // A view that needs the lock screen wrapper switched hands that one write to
  // the service, because the write may rebuild the bar this popup lives in.
  // The service answers here when it is done: `resume(view, word)` opens the
  // popup on that view, and the word is left on `resumeWord` for the view to
  // take. It is a word and not a sentence, so the view that asked is the one
  // that says what it means -- whether it is the same instance that has been
  // waiting all along (a bar that survived the write) or a brand new one (a bar
  // that did not).
  property string resumeWord: ""

  function resumeAt(viewName, word) {
    root.resumeWord = String(word || "")
    return root.openAt(viewName, "")
  }

  // The view that takes the word clears it, so it is acted on once.
  function takeResumeWord(prefix) {
    var word = root.resumeWord
    if (word === "" || word.indexOf(prefix) !== 0) return ""
    root.resumeWord = ""
    return word
  }

  function finishPendingOpen() {
    if (!root.pendingOpen) return
    var target = root.pendingOpen
    root.pendingOpen = null
    pendingOpenGuard.stop()
    if (target.view === "person") {
      root.resetView("setup")
      root.openPerson(target.name)
    } else if (target.view !== "") {
      root.openWithBase(target.view)
    }
    root.openRequested()
  }

  Timer {
    id: pendingOpenGuard
    interval: root.pendingOpenMs
    onTriggered: root.finishPendingOpen()
  }

  function navBack() {
    if (root.view === "person") root.personName = ""
    root.popView()
  }

  // Where each view says it is. A table rather than a ternary chain, so a view
  // that is not built yet still answers a lookup.
  readonly property var viewChrome: ({
    "setup":    { title: "Face ID",      meta: "What still needs doing",
                  hint: "esc closes" },
    "people":   { title: "People",       meta: "Who this machine knows",
                  hint: "esc goes back" },
    "person":   { title: "",             meta: "Appearances and permissions",
                  hint: "esc goes back" },
    "settings": { title: "Settings",     meta: "Where a face is accepted",
                  hint: "esc goes back" },
    "remove":   { title: "Remove Face",  meta: "What would be taken off this machine",
                  hint: "esc goes back" },
    // Pushed in place by showEnrol(); only the hosted home ever shows it (the
    // stock bar's popup hands a recording to the service's card instead).
    "enrol":    { title: "",             meta: "Look at the camera",
                  hint: "esc closes · nothing is saved until you finish" },
    // Pushed in place by showTest(), hosted only: the stock popup has the
    // service's card for it.
    "test":     { title: "",             meta: "Does it recognise them now?",
                  hint: "esc stops the check and goes back" }
  })

  function chrome() {
    var c = root.viewChrome[root.view]
    if (!c) return { title: "Face ID", meta: "", hint: "" }
    // "What still needs doing" is a lie on a machine where nothing does, and
    // Setup is the view the popup opens on for the rest of its life. The rows
    // are still there to read; only the line above them changes.
    if (root.view === "setup" && root.status !== null && !root.setupNeeded && !root.attention)
      return { title: c.title, meta: "Everything Face needs is in place", hint: c.hint }
    return c
  }

  function viewTitle() {
    if (root.view === "enrol" && root.enrol) return String(root.enrol.label || root.enrol.name)
    if (root.view === "test" && root.testRequest) return String(root.testRequest.label || root.testRequest.name)
    return root.view === "person" && root.personName !== "" ? root.personName : root.chrome().title
  }

  // --- the engine seam ----------------------------------------------------

  Ask {
    id: engine
    pluginDir: root.pluginDir
  }

  // Views reach the engine through the panel, so a view never has to know
  // whether it is talking to the real helpers or to dev/bin stubs.
  readonly property var ask: engine

  // --- watched files (plan-merged.md §2.6) --------------------------------

  // Both are written by same-directory temp + rename, which drops an inotify
  // watch on the old inode -- hence the reload timer beside watchChanges.
  // Overridable as a set for development: the stubs cannot write root-owned
  // paths, so a fixture directory stands in for them (dev/README.md).
  readonly property string stateDir: Quickshell.env("OMARCHY_FACE_DEV_STATE") || ""
  readonly property string peoplePath: (stateDir !== "" ? stateDir : "/var/lib/omarchy-face") + "/people.json"
  readonly property string installPath: (stateDir !== "" ? stateDir : "/run/omarchy-face") + "/install.json"

  property var people: null
  property var install: null

  // What the Setup view's `engine` row renders (plan-gui.md §4 row 4). The
  // watched file first, because it is re-read every second while the popup is
  // open and the status document only every thirty -- a build's step list would
  // otherwise crawl half a minute behind the build.
  //
  // This is also the whole of what survives the popup closing or the shell
  // restarting mid-build: the job is a transient root unit writing
  // /run/omarchy-face/install.json, so a GUI that comes back reads the same
  // build where it got to rather than losing it or starting a second one.
  readonly property var installDoc: install ? install
                                  : (status && status.install ? status.install : ({}))

  // The raw text each parsed object came from. `reload()` re-emits `loaded`
  // whether or not the bytes changed, so without this the once-a-second reload
  // below hands every view a NEW object identity every second: a Repeater sees
  // a different model each tick and destroys and recreates every delegate.
  // Harmless for the Text rows here; once phase 4 puts a label field and an
  // appearance picker in these lists, it would swallow focus and typed text
  // once a second. So: keep the bytes, and only reassign when they differ.
  property string peopleRaw: ""
  property string installRaw: ""

  FileView {
    id: peopleFile
    path: root.peoplePath
    watchChanges: true
    // Absent is the normal state before Setup has run, and the reload timer
    // below asks again every second: left on, that is two journal warnings a
    // second for a file that is *supposed* not to exist yet.
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var raw = String(text())
      if (raw !== root.peopleRaw) {
        root.peopleRaw = raw
        try { root.people = JSON.parse(raw) } catch (e) {
          console.warn("kalinewb.face", "ignoring bad people.json", root.peoplePath, e)
        }
      }
      // A view waiting for this read is shown now, and only now: this is the
      // answer it was waiting for, whether or not the bytes turned out to have
      // changed. `loaded` is re-emitted by every reload, which is what makes
      // that true (hence peopleRaw above).
      if (root.pendingOpen) root.finishPendingOpen()
    }
    // Absent is the normal state before Setup has run; it is not a warning.
    onLoadFailed: {
      root.peopleRaw = ""
      root.people = null
      if (root.pendingOpen) root.finishPendingOpen()
    }
  }

  FileView {
    id: installFile
    path: root.installPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var raw = String(text())
      if (raw === root.installRaw) return
      root.installRaw = raw
      try { root.install = JSON.parse(raw) } catch (e) {
        console.warn("kalinewb.face", "ignoring bad install.json", root.installPath, e)
      }
    }
    onLoadFailed: { root.installRaw = ""; root.install = null }
  }

  // The two watched files, now. Used by the once-a-second timer and by a view
  // that has just made one of them change: a fix that starts a build should show
  // the build, not the second of nothing that precedes the next tick.
  function reloadWatched() {
    peopleFile.reload()
    installFile.reload()
  }

  Timer {
    // While the popup is open the two watched files are re-read every second,
    // because an atomic rename leaves watchChanges pointing at an inode nobody
    // writes to again.
    interval: 1000
    repeat: true
    running: root.opened
    onTriggered: root.reloadWatched()
  }

  Timer {
    // One cadence for both states: §2.3 asks for 30 s while open and a 30 s
    // probe while closed, and the bar button needs an answer either way. The
    // hosted home has no button to feed: the widget's own model keeps the
    // probe, and this one reads only while its panel is open (and once at
    // creation, below, because `available` rests on that first answer).
    interval: 30000
    repeat: true
    running: !root.hosted || root.opened
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: if (root.hosted) root.refresh()

  onOpenedChanged: if (opened) {
    root.refresh()
    root.reloadWatched()
    console.log("kalinewb.face", root.hosted ? "panel opened on view" : "popup opened on view", root.view)
  } else {
    console.log("kalinewb.face", root.hosted ? "panel closed" : "popup closed")
    // A word is for the view the popup reopens on. One nobody took by the time
    // the popup closes is about a switch that has already been read back
    // through the status document, and must not surface on some later visit.
    root.resumeWord = ""
  }

  // --- recording a face (the hosted home) -------------------------------------
  //
  // The stock bar's popup asks the Face service for a card (PeopleView.record,
  // PersonView.record). Inside a host there is no window to put a card in, so
  // the same call lands here instead and the views show the recording in place:
  // `enrol` holds who and which appearance, `enrolSession` is the session the
  // host's integration runs for it (Surface.qml creates and destroys it).
  property var enrol: null
  property var enrolSession: null

  // The RGB node the preview draws, from the status document. "" on a laptop
  // with none. A read: asking for it opens nothing.
  readonly property string previewDevice: status && status.camera && status.camera.rgb
                                          ? String(status.camera.rgb) : ""

  // Which appearances `name` already has a recording for, as the picker marks
  // them (the Face service reads the same file for the card).
  function appearancesFor(name) {
    var who = String(name || "")
    if (who === "") return []
    var list = root.people && Array.isArray(root.people.people) ? root.people.people : []
    for (var i = 0; i < list.length; i++) {
      if (!list[i] || String(list[i].name) !== who) continue
      var found = Array.isArray(list[i].appearances) ? list[i].appearances : []
      var labels = []
      for (var j = 0; j < found.length; j++)
        if (found[j] && found[j].label !== undefined) labels.push(String(found[j].label))
      return labels
    }
    return []
  }

  // How many templates `name`'s appearance `label` already holds (people.json
  // `templates`); 0 when there is none. Rule R: Simple may not shrink a set.
  function templatesFor(name, label) {
    var who = String(name || "")
    var list = root.people && Array.isArray(root.people.people) ? root.people.people : []
    for (var i = 0; i < list.length; i++) {
      if (!list[i] || String(list[i].name) !== who) continue
      var found = Array.isArray(list[i].appearances) ? list[i].appearances : []
      for (var j = 0; j < found.length; j++)
        if (found[j] && String(found[j].label) === String(label)) return Number(found[j].templates) || 1
    }
    return 0
  }

  // A line for the view the person lands on after a scan that saved nothing,
  // gone after 600 ms (plan-face-enroll.md section 3, Phases). One-shot.
  property string notice: ""
  function flash(text) {
    root.notice = String(text)
    flashTimer.restart()
  }
  Timer { id: flashTimer; interval: 600; onTriggered: root.notice = "" }

  // True when the request was taken. Outside a host it is not, and the caller
  // carries on with the service's card.
  function showEnrol(name, appearance, label, isNew) {
    if (!root.hosted || String(name || "") === "") return false
    root.enrol = { name: String(name), appearance: String(appearance || "No glasses"),
                   label: String(label || name), isNew: !!isNew }
    if (root.view !== "enrol") root.pushView("enrol")
    return true
  }

  // Test, in place (plan-gui.md section 5.2): the check and its answer are a view
  // of this home, not a window drawn over it. Hosted only, as showEnrol is; the
  // stock popup asks the service for its card.
  property var testRequest: null

  function showTest(name, label) {
    if (!root.hosted || String(name || "") === "") return false
    root.testRequest = { name: String(name), label: String(label || name) }
    if (root.view !== "test") root.pushView("test")
    return true
  }

  // Leaving the enrol view drops what it was for; whoever owns the session
  // (the host's integration) watches `view` and ends it.
  onViewChanged: {
    if (view !== "enrol") root.enrol = null
    if (view !== "test") root.testRequest = null
  }

  // Esc, in either home. The enrol view hands it to the session first, which
  // decides between discarding and finishing (RecordSession.requestClose);
  // every other view goes back one step and the root view closes.
  function back() {
    if (root.view === "enrol" && root.enrolSession) {
      root.enrolSession.requestClose()
      return
    }
    if (root.viewStack.length > 1) root.navBack()
    else root.closeRequested()
  }

  // A route a host opens the panel at (common/faceroute.js is the parser, this
  // is the effect). The word it answers is for logs and tests; a route it does
  // not understand opens nothing.
  function applyRoute(route) {
    var parsed = Route.parse(route)
    if (parsed === null) return "bad route: " + String(route)
    if (parsed.view === "enrol")
      return root.showEnrolAt(parsed) ? "ok" : "enrol needs a person"
    return root.openAt(parsed.view, parsed.name)
  }

  // An `enrol` route from outside: the base is Setup, so Back and Esc have a
  // place to go, exactly as openWithBase does for the other views.
  function showEnrolAt(parsed) {
    if (!root.hosted) return false
    // The host calls open() for a route more than once while it loads the
    // panel; the same request again must not tear down a session that is
    // already running for it.
    var now = root.enrol
    if (root.view === "enrol" && now && now.name === parsed.name && now.appearance === parsed.appearance
        && now.label === parsed.label && now.isNew === parsed.isNew) return true
    root.resetView("setup")
    return root.showEnrol(parsed.name, parsed.appearance, parsed.label, parsed.isNew)
  }

}
