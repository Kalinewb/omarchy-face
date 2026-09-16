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

  // The layer-shell namespace of the card's window. Service.qml hands this
  // to Hyprland in a layer rule that switches the compositor's own
  // map/unmap animation off for it (see there for why), so it lives here,
  // once, where the window is made.
  readonly property string layerNamespace: "omarchy-face-indicator"

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
  // heightP and widthP live on root, not inside the PanelWindow, because the
  // window is destroyed and recreated (see the Variants comment below) --
  // an animation driving a property on an Item that is about to be torn
  // down cannot be trusted to finish. Reused as-is by whichever window
  // exists at the time; there is only ever at most one.
  property bool windowUp: false
  property bool exiting: false

  // How far the bar has grown, 0 = the seed it starts from, 1 = its settled
  // size -- one for its height and one for its width, because they do not
  // move together (post-ship revision). The bar grows OUT OF the top edge:
  // its top edge is anchored at y = 0 and is never anywhere else, at any
  // frame including the first; its position, opacity and scale are never
  // animated; these two numbers are the only things that change. Height
  // leads; width follows 50 ms behind and both land together. The fillets
  // beside the bar are bindings on its height and width (Island.qml), so
  // they are there from the first frame, scale with the bar, and move in
  // the same frame it does -- there is no separate animation for them to
  // fall behind on.
  property real heightP: 0
  property real widthP: 0

  // The seed: what is on screen at progress 0, as fractions of the settled
  // size. Not zero, so that the first frame already has a bar with fillets
  // on it rather than nothing; not large, so that the growth reads as growth.
  // heightGone / widthGone are the progress values at which the bar's size
  // reaches zero -- the exit animates to those, so the bar retracts INTO the
  // edge rather than shrinking to the seed and then vanishing.
  readonly property real seedHeightFraction: 0.2
  readonly property real seedWidthFraction: 0.4
  readonly property real heightGone: -seedHeightFraction / (1 - seedHeightFraction)
  readonly property real widthGone: -seedWidthFraction / (1 - seedWidthFraction)

  // The shape, as proportions of the bar's own height so it is the same
  // shape at every size: bottom corners at a fifth of the height -- a
  // rounded rectangle, not a capsule, which is what half the height would
  // be -- and fillets that reach `filletFull` px when the bar is settled,
  // just enough to soften the join to the screen edge.
  readonly property real bottomRadiusFraction: 0.2
  readonly property real filletFull: 10

  readonly property int heightDuration: 350
  readonly property int widthDelay: 50
  readonly property int widthDuration: 300

  // The easing is a damped spring, not an ease-out: the step response of a
  // second-order system with damping ratio `springDamping`, which overshoots
  // once by exp(-πζ/√(1-ζ²)) -- 3.8 % at ζ = 0.72 -- and settles. It is
  // sampled into a cubic Bézier spline (eight Hermite segments, C¹, with the
  // derivative taken from the same closed form) because that is the one
  // shape of custom curve NumberAnimation accepts, and because a curve on
  // the animation itself -- rather than a formula applied to a linear timer
  // -- is what lets a restart mid-exit grow back out from wherever the bar
  // currently is, and lets the plain exit below run without replaying the
  // overshoot backwards. `springPeakAt` is where in the duration the
  // overshoot peaks (0.6 → 210 ms into the height's 350 ms); by the end the
  // envelope is under half a percent and the residual is taken out linearly
  // so the curve ends on exactly 1.
  readonly property real springDamping: 0.72
  readonly property real springPeakAt: 0.6
  readonly property real springOvershoot:
    Math.exp(-Math.PI * springDamping / Math.sqrt(1 - springDamping * springDamping))
  readonly property var springCurve: buildSpringCurve(springDamping, springPeakAt, 8)

  function buildSpringCurve(zeta, peakAt, segments) {
    var b = Math.PI / peakAt                    // damped angular frequency
    var w = b / Math.sqrt(1 - zeta * zeta)      // undamped
    var a = zeta * w                            // decay rate
    var k = a / b
    function raw(t) { return 1 - Math.exp(-a * t) * (Math.cos(b * t) + k * Math.sin(b * t)) }
    function rawSlope(t) { return Math.exp(-a * t) * (w * w / b) * Math.sin(b * t) }
    var tail = raw(1) - 1
    function x(t) { return raw(t) - t * tail }
    function m(t) { return rawSlope(t) - tail }
    var points = []
    var h = 1 / segments
    for (var i = 0; i < segments; i++) {
      var t0 = i * h, t1 = (i + 1) * h
      points.push(t0 + h / 3, x(t0) + m(t0) * h / 3,
                  t1 - h / 3, x(t1) - m(t1) * h / 3,
                  t1, x(t1))
    }
    points[points.length - 2] = 1
    points[points.length - 1] = 1
    return points
  }

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

  // No `from:` on either entrance: a restart mid-exit (a fresh request
  // landing while the last one is still shrinking away) grows back out from
  // wherever the bar currently is instead of popping to the seed first.
  ParallelAnimation {
    id: enterAnim
    NumberAnimation {
      target: root
      property: "heightP"
      to: 1
      duration: root.heightDuration
      easing.type: Easing.BezierSpline
      easing.bezierCurve: root.springCurve
    }
    SequentialAnimation {
      PauseAnimation { duration: root.widthDelay }
      NumberAnimation {
        target: root
        property: "widthP"
        to: 1
        duration: root.widthDuration
        easing.type: Easing.BezierSpline
        easing.bezierCurve: root.springCurve
      }
    }
  }

  // A plain ease back into the edge, both dimensions together, all the way
  // to zero size -- the fillets are proportional to the height, so they go
  // with it, and the last frame before the window is destroyed is empty.
  ParallelAnimation {
    id: exitAnim
    NumberAnimation { target: root; property: "heightP"; to: root.heightGone; duration: 200; easing.type: Easing.InOutCubic }
    NumberAnimation { target: root; property: "widthP"; to: root.widthGone; duration: 200; easing.type: Easing.InOutCubic }
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

      WlrLayershell.namespace: root.layerNamespace
      WlrLayershell.layer: WlrLayer.Overlay
      // Never take focus: the password prompt underneath may be mid-typing, and
      // an indicator that swallows keystrokes is worse than no indicator.
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      // Empty input region: clicks pass through to whatever is behind.
      mask: Region {}

      Island {
        id: card
        // Flush against the true physical top edge (post-ship revision,
        // found via live use -- a 44px gap from the true edge read as
        // floating below the bar rather than attached to the screen).
        // Horizontally centered under the lens, same as before: looking at
        // the card still points the face at the camera. Fixed anchor point,
        // entirely unchanged by the animation below -- only the bar's own
        // size and roundedness move, growing outward from the middle while
        // staying attached to the top edge.
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 0

        // The bar's size at rest -- what it grows toward and shrinks from.
        // A little wider than tall (post-ship revision, by live use: 300
        // wide read as a banner, a square read as cramped, and this is one
        // step up from the square). The width comes from a token; the height
        // from the content, but never less than the square's was, so
        // widening the bar did not also shorten it. The content's width is
        // derived from the width token and never from the height, because a
        // wrapped Text's height depends on its width and the other way
        // round would be a loop.
        readonly property real contentWidth: Style.space(144)
        readonly property real minContentHeight: Style.space(116)
        readonly property real fullWidth: Math.min(parent.width - Style.space(40), contentWidth + Style.space(28))
        readonly property real fullHeight: Math.max(content.implicitHeight, minContentHeight) + Style.space(28)
        // Height and width each follow their own progress (root's heightP /
        // widthP), from the seed fractions up. Neither is clamped at 1: the
        // spring's overshoot past the settled size is meant to show. Clamped
        // at zero size only, for the tail of the exit.
        barWidth: Math.max(0, fullWidth * (root.seedWidthFraction
                    + (1 - root.seedWidthFraction) * root.widthP))
        barHeight: Math.max(0, fullHeight * (root.seedHeightFraction
                    + (1 - root.seedHeightFraction) * root.heightP))

        // The shape itself is Island.qml's: a plain rectangle, flush and
        // square-cornered at the top, rounded on the bottom two corners
        // only, with the two concave fillets that fuse it to the screen
        // edge drawn beside it rather than cut from it. Both radii are
        // proportions of the bar's CURRENT height, so the bar is the same
        // shape at every frame -- the first frame's seed is a small rounded
        // rectangle with small fillets, the settled bar a large one with
        // 10 px fillets, and there is no frame where the corners have
        // become a capsule or the fillets have gone missing. True black, no
        // border: a visible outline reads as an ordinary dialog, not a
        // black surface merging into the edge (post-ship revision, found
        // via live use; reference: an iPhone's Dynamic Island where it
        // meets the top bezel).
        bottomRadius: root.bottomRadiusFraction * barHeight
        filletRadius: root.filletFull * barHeight / fullHeight
        color: "#000000"

        // The content below lands inside the bar (Island's default property)
        // and is clipped to it. It is sized for the bar's full, settled
        // dimensions so its own text layout never reflows mid-animation,
        // and only fades in once the bar is mostly grown.
        Column {
          id: content
          anchors.centerIn: parent
          // A fixed width, not the bar's currently-animated one -- so text
          // wrapping never reflows mid-grow. Only visible (see opacity below)
          // once the bar is most of the way there, and clipped by the bar
          // itself before then regardless.
          width: card.contentWidth
          spacing: Style.space(8)

          // Fades in only once the bar is mostly at full size in both
          // dimensions, so text is never seen cramped or half-clipped inside
          // a still-small bar -- same formula on the way out, so it is gone
          // before the bar shrinks small enough for it to look wrong. This is
          // the text inside the bar, not the bar: the bar itself is solid at
          // every frame, and nothing about it fades or scales.
          readonly property real settleP:
            Math.max(0, Math.min(1, (Math.min(root.heightP, root.widthP) - 0.7) / 0.3))
          opacity: settleP

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
            // Two lines before eliding: "sudo · pacman, from foot" does not
            // fit one line of a square this size, and the program's name is
            // the part worth keeping whole.
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
