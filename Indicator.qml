import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The indicator (plan-gui.md §6.2): a card under the webcam saying that a face
// is being checked, and for whom.
//
// It participates in nothing. PAM has already decided, or is deciding on the
// exit status of a root helper this file cannot reach, by the time a state
// lands here -- so this is free to be late, wrong or absent without any effect
// on whether anybody gets in. What it is for is the other direction: a sudo
// prompt that appears while you are reading something else is a request you did
// not make, and a card that names `pacman, from foot` is how you notice.
//
// Kept from the old GUI (plan-gui.md §0), because all three were right:
//
//   · a 10 s stale filter, so a shell that restarts does not pop a spinner for
//     an authentication that finished hours ago;
//   · a 200 ms poll beside the file watch, because the state file is written by
//     atomic rename and a rename replaces the inode the watch is on;
//   · a 12 s safety timer, because a verifier killed between `start` and its
//     answer would otherwise leave this on screen for ever. The engine gives up
//     at 8 s and the IR camera takes about a second to open, so anything past
//     ~12 s is a fault, and the answer to a fault is to get out of the way.
//
// Fixed from the old GUI: the card is pinned to the built-in screen, and it
// really does name the requester -- the old README claimed it and the old code
// never did it.
//
// Also new: the card grows in and shrinks out rather than just appearing and
// disappearing (see the entrance/exit block below `targetScreens`). Purely a
// visual change -- everything above about staleness, polling, the safety
// timer and suppression decides the exact same things at the exact same
// moments it always did.
Item {
  id: root

  // The recording card owns the same piece of screen and says more than this
  // does, so this stands down entirely while one is up (§6.2). A recording
  // session is a person looking into the lens on purpose, with a root process
  // authorised and waiting; there is no useful second card to draw beside it.
  property bool suppressed: false

  // The Test card is different, and the difference is a security one rather
  // than a layout one. It suppresses **only identity checks** -- the ones it is
  // itself the cause of, where drawing both would be the same event reported
  // twice. A `sudo` that arrives while a test is on screen is NOT suppressed:
  //
  //   any process running as this account can raise a Test card over IPC, and a
  //   blanket suppression would hand it a window of its own choosing in which
  //   `sudo -n` draws nothing on screen. That is not a new capability -- face
  //   for sudo is a passive factor and the README says so -- but it is exactly
  //   the mitigation phase 5 added, switched off by the attacker.
  //
  // So sudo wins the screen, and the Test card is the one that gets out of the
  // way (Service.qml binds its `standDown` to this card being up).
  property bool suppressedIdentity: false

  readonly property bool suppressedNow: root.suppressed
    || (root.suppressedIdentity && root.service === "identity")

  // …but it does not stay quiet about it. Any process running as this account can
  // open a recording card over IPC, and a person looking into the lens for a
  // countdown is a person not reading anything else -- so a `sudo` that lands
  // during one would have been the one authentication nothing on screen mentioned.
  // The card is handed this line instead (Service.qml), which is the same
  // information in the one place the person is already looking.
  property string suppressedNotice: ""
  function clearSuppressedNotice() { root.suppressedNotice = "" }

  // Development only, and the same variable the panel uses: the state file and
  // people.json both move to a fixture directory, because nothing unprivileged
  // can write the real ones.
  readonly property string stateDir: Quickshell.env("OMARCHY_FACE_DEV_STATE") || ""
  readonly property string statePath: (stateDir !== "" ? stateDir : "/run/omarchy-face") + "/state.json"
  readonly property string peoplePath: (stateDir !== "" ? stateDir : "/var/lib/omarchy-face") + "/people.json"

  readonly property int staleAfterMs: 10000
  readonly property int safetyMs: 12000

  // What the engine last said, once it has passed the stale filter.
  property string authState: "idle"
  property string service: ""
  property string person: ""
  property string requesterCommand: ""
  property string requesterFrom: ""
  property double lastAt: 0
  property bool showing: false

  // --- the copy (plan-gui.md §6.2) --------------------------------------------
  //
  // These are properties rather than expressions buried in the tree, because
  // they are what the phase-5 gate asks: "the indicator card renders with that
  // name given a simulated state.json" is a question about this string.

  readonly property var people: {
    try { return JSON.parse(peopleText) } catch (e) { return null }
  }
  property string peopleText: ""

  function labelFor(name) {
    var who = String(name || "")
    if (who === "") return ""
    var list = root.people && Array.isArray(root.people.people) ? root.people.people : []
    for (var i = 0; i < list.length; i++)
      if (list[i] && String(list[i].name) === who) return String(list[i].label || who)
    return who
  }

  // The appearance labels this person already has a recording for. It lives
  // here because this file is the one in the service that reads people.json --
  // every 200 ms, and across the plugins-folder reloads that destroy the popup
  // (Service.qml) -- and the recording card, which is the service's too, has to
  // be able to say which appearances are already done (post-ship revision).
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

  readonly property string headline: {
    if (root.authState === "matched")
      return root.service === "identity"
        ? "Recognised " + (root.labelFor(root.person) || "you")
        : "Approved" + (root.person !== "" ? " · " + root.labelFor(root.person) : "")
    if (root.authState === "failed") return "Not recognised — use your password"
    return "Look at the camera"
  }

  // "sudo · pacman, from foot", with either part dropped when the engine did not
  // have it. `sudo -v` carries no command at all, and then the line is just the
  // service -- which is still worth saying, because it is what distinguishes a
  // sudo prompt from Profiles asking who you are.
  readonly property string detail: {
    if (root.service === "identity") return "Profiles is checking who you are"
    if (root.service !== "sudo") return ""
    var line = "sudo"
    if (root.requesterCommand !== "") line += " · " + root.requesterCommand
    if (root.requesterFrom !== "")
      line += (root.requesterCommand !== "" ? ", from " : " · from ") + root.requesterFrom
    return line
  }

  // Never for `lock`: nothing can draw over a session-lock surface, and a card
  // that exists but cannot be seen is a card that lies in a screenshot
  // (plan-merged.md §1 row 11).
  readonly property bool serviceShown: root.service === "sudo" || root.service === "identity"

  function handle(payload) {
    var event = null
    try { event = JSON.parse(String(payload || "")) } catch (e) { return }
    if (!event || !event.state) return
    var at = Number(event.at || 0)
    if (!(at > 0) || at === root.lastAt) return
    // Older than the filter: record that it was seen, so it is not re-examined
    // every poll, and show nothing.
    if (Date.now() - at > root.staleAfterMs) { root.lastAt = at; return }
    root.lastAt = at

    root.authState = String(event.state)
    root.service = String(event.service || "")
    root.person = String(event.person || "")
    var requester = event.requester && typeof event.requester === "object" ? event.requester : {}
    root.requesterCommand = String(requester.command || "")
    root.requesterFrom = String(requester.from || "")

    if (!root.serviceShown) { safety.stop(); dismiss.stop(); root.showing = false; return }

    // Suppressed, but not silent (see suppressedNotice above). Only for the
    // states that mean something happened; `skipped` is nothing to report.
    if (root.suppressedNow && root.authState !== "skipped") {
      root.suppressedNotice = (root.service === "sudo" ? "sudo" : "A face check")
        + (root.requesterCommand !== "" ? " · " + root.requesterCommand : "")
        + " asked while this was open"
    }

    if (root.authState === "start") {
      dismiss.stop()
      safety.restart()
      root.showing = true
    } else if (root.authState === "matched" || root.authState === "failed") {
      safety.stop()
      root.showing = true
      dismiss.interval = root.authState === "matched" ? 1600 : 1800
      dismiss.restart()
    } else {
      // `skipped`, or anything this version does not know: say nothing.
      safety.stop()
      dismiss.stop()
      root.showing = false
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.handle(text())
  }

  FileView {
    id: peopleFile
    path: root.peoplePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var raw = String(text())
      if (raw !== root.peopleText) root.peopleText = raw
    }
    onLoadFailed: root.peopleText = ""
  }

  Timer {
    interval: 200
    repeat: true
    running: true
    onTriggered: { stateFile.reload(); peopleFile.reload() }
  }

  Timer { id: safety; interval: root.safetyMs; onTriggered: root.showing = false }
  Timer { id: dismiss; onTriggered: root.showing = false }

  // The camera is above the built-in panel, so that is the only screen where
  // showing this helps: on an external monitor it would aim the person's gaze
  // away from the lens. Falls back to every screen when no internal panel is
  // recognised, which is better than showing nothing at all.
  readonly property var targetScreens: {
    var builtin = []
    for (var i = 0; i < Quickshell.screens.length; i++) {
      var candidate = Quickshell.screens[i]
      if (/^(eDP|LVDS|DSI)/i.test(candidate.name || "")) builtin.push(candidate)
    }
    return builtin.length > 0 ? builtin : Quickshell.screens
  }

  // What the state file and the suppression flags together say should be on
  // screen -- but not the same thing as the window's own lifetime, below.
  readonly property bool visibleNow: root.showing && !root.suppressedNow

  // --- entrance/exit -----------------------------------------------------
  //
  // visibleNow flips the instant handle() or a suppression change says so --
  // the same timing this card has always had (10 s stale filter, 12 s safety
  // timer, suppression, all untouched above). windowUp is what actually
  // drives the Variants model below, and it lags visibleNow turning false by
  // exactly as long as the exit animation takes: destroying the layer-shell
  // surface the instant visibleNow goes false would give beginExit() nothing
  // to animate, the same surface-lifecycle-races-animation lesson as the
  // notifications popup, applied here before it became a second bug rather
  // than after.
  //
  // cardProgress lives on root, not inside the PanelWindow, because the
  // window is destroyed and recreated (see the Variants comment below) --
  // an animation driving a property on an Item that is about to be torn
  // down cannot be trusted to finish. Reused as-is by whichever window
  // exists at the time; there is only ever at most one.
  property bool windowUp: false
  property bool exiting: false
  property real cardProgress: 0

  onVisibleNowChanged: {
    if (root.visibleNow) {
      exitAnim.stop()
      root.exiting = false
      root.windowUp = true
      enterAnim.restart()
    } else {
      root.beginExit()
    }
  }

  function beginExit() {
    if (!root.windowUp || root.exiting) return
    root.exiting = true
    exitAnim.restart()
  }

  // A fast, slightly springy grow -- not a bouncy elastic wobble -- then a
  // plain ease back down on the way out. No `from:` on the entrance: a
  // restart mid-exit (a fresh request landing while the last one is still
  // shrinking away) grows back out from wherever it currently is instead of
  // popping to zero first.
  NumberAnimation {
    id: enterAnim
    target: root
    property: "cardProgress"
    to: 1
    duration: 380
    easing.type: Easing.OutBack
    easing.overshoot: 1.3
  }

  NumberAnimation {
    id: exitAnim
    target: root
    property: "cardProgress"
    to: 0
    duration: 200
    easing.type: Easing.InOutCubic
    onFinished: { root.windowUp = false; root.exiting = false }
  }

  Variants {
    // No window at all while nothing is happening: this service is keepLoaded
    // and lives for the whole session, and a permanent layer-shell surface with
    // an empty input region is still a surface every compositor has to composite.
    model: root.windowUp ? root.targetScreens : []

    PanelWindow {
      id: window
      required property var modelData
      screen: modelData

      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"

      WlrLayershell.namespace: "omarchy-face-indicator"
      WlrLayershell.layer: WlrLayer.Overlay
      // Never take focus: the password prompt underneath may be mid-typing, and
      // an indicator that swallows keystrokes is worse than no indicator.
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      // Empty input region: clicks pass through to whatever is behind.
      mask: Region {}

      Rectangle {
        id: card
        // Under the lens rather than in the middle of the display: looking at
        // the card then points the face at the camera, which is the one thing
        // the person has to get right. Fixed position, entirely unchanged by
        // the animation below -- only the card's own size and roundedness
        // move, growing down and outward from this same anchored point.
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Style.space(44)

        // The card's size at rest -- what it grows toward and shrinks from.
        readonly property real fullWidth: Math.min(parent.width - Style.space(40), Style.space(300))
        readonly property real fullHeight: content.implicitHeight + Style.space(28)
        // 0 = a small round nub, 1 = fully grown. Not flush against any
        // screen edge the way the notification popup's shape is -- this card
        // sits a deliberate 44px below the true top edge so it never covers
        // the webcam, so there is no edge here for it to read as "merging
        // into"; a plain grow-from-a-point-under-the-lens is what fits.
        readonly property real sizeP: Math.max(0, Math.min(1, root.cardProgress))
        readonly property real minNub: Math.min(28, fullWidth, fullHeight)
        width: minNub + (fullWidth - minNub) * sizeP
        height: minNub + (fullHeight - minNub) * sizeP
        // Pill-shaped while small, relaxing into the theme's real corner
        // radius as it fills out -- the same shape language as the
        // notification popup's entrance, independently implemented here.
        readonly property real capsuleR: Math.min(width, height) / 2
        radius: capsuleR + (Style.cornerRadius - capsuleR) * Math.pow(sizeP, 2.2)
        // content below is sized for the card's full, settled dimensions
        // (so its own text layout never reflows mid-animation) and only
        // fades in once the card is mostly grown -- clip keeps that content
        // from visibly overflowing the still-growing card in between.
        clip: true
        // The polkit palette, because this card is that dialog's sibling: it
        // appears at the same moment, for the same authentication, and the two
        // should not look like they came from different programs.
        //
        // Forced opaque. The polkit surface is semi-transparent on purpose --
        // Hyprland blurs it through a layer rule matched on its namespace -- but
        // there is no blur rule behind this namespace, so an alpha here would
        // simply let whatever is underneath read through the text.
        color: Qt.rgba(Color.polkit.background.r, Color.polkit.background.g,
                       Color.polkit.background.b, 1)
        border.width: 1
        border.color: Qt.rgba(Color.polkit.border.r, Color.polkit.border.g,
                              Color.polkit.border.b, 0.35)

        Column {
          id: content
          anchors.centerIn: parent
          // Fixed to the card's settled width, not its currently-animated
          // one -- so text wrapping never reflows mid-grow. Only visible
          // (see opacity below) once the card is most of the way there, and
          // clipped by the card itself before then regardless.
          width: card.fullWidth - Style.space(28)
          spacing: Style.space(8)

          // Pops and fades in only once the card is mostly at full size, so
          // nothing looks cramped or clipped inside a still-small shape --
          // same formula on the way out, so content is already gone before
          // the card shrinks small enough for it to look wrong.
          readonly property real settleP: Math.max(0, Math.min(1, (card.sizeP - 0.7) / 0.3))
          opacity: settleP
          scale: 0.94 + 0.06 * settleP

          // The face glyph while it is looking, then an answer. Two plain
          // characters rather than two more Nerd Font codepoints: this card is
          // read at a glance from arm's length, and ✓ / ✕ are in every font.
          Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.authState === "matched" ? "✓"
                : root.authState === "failed" ? "✕"
                : "\u{f0643}"
            color: root.authState === "failed" ? Color.polkit.textError : Color.polkit.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.display * 1.4
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.headline
            color: root.authState === "failed" ? Color.polkit.textError : Color.polkit.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.detail !== ""
            text: root.detail
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
