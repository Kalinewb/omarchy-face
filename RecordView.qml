import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// What the recording card shows, without the card: the title, the preview in its
// oval, the line saying what is happening, the appearance picker and the
// buttons. It is the single-capture enrol view (plan-gui.md §5.3) and it is the
// same item in both homes of Face's UI -- RecordCard.qml wraps it in its window
// under the stock bar, and FaceViews.qml shows it in place inside the notch --
// so the two cannot drift apart. Phase 4 of plan-face-enroll.md replaces what
// is inside with the ring; the seam (a session, a palette, a fence for the
// camera) stays.
//
// Every decision about the session is in RecordSession.qml; this file is what
// that state machine looks like.
Item {
  id: view

  // The session this view draws. Created by the owner (the Face service for the
  // card, the notch integration for the panel) so the view can be shown on a
  // session that is already running, and on none yet.
  property var session: null
  property string fontFamily: Style.font.family
  // The RGB preview node from `omarchy-face-status` (`camera.rgb`), or "" when
  // this laptop has none (plan-merged.md §1 row 18).
  property string previewDevice: ""
  // Whether this view is on screen right now. The preview camera is opened only
  // while it is: the card is on screen from the moment it exists, the notch's
  // panel only while it is open, on its own screen, showing this view
  // (plan-face-enroll.md 6a.1). A hosted panel is not destroyed when the notch
  // closes, so destruction cannot be the fence.
  property bool previewOn: false
  // The three standard labels, so the picker offers the same words as the
  // person view.
  property var appearanceLabels: ["No glasses", "Everyday glasses", "Reading glasses"]

  // The palette: the card's (white on its black scrim) by default, the host's
  // inside a host.
  property color foreground: "white"
  property color dim: Qt.rgba(1, 1, 1, 0.6)
  property color urgent: "#ff6b6b"
  property color accent: Commons.Color.accent
  // Anything with radiusFor(size); null means the theme's.
  property var radiusSource: null

  function radiusFor(size) {
    return radiusSource ? radiusSource.radiusFor(size) : Style.cornerRadius
  }

  // Which of them this person already has a recording for, from people.json
  // (the owner reads it; see Service.qml). Without it the picker offers three
  // identical-looking options and the button says the same word whichever is
  // chosen, so somebody recording a second appearance cannot tell whether they
  // are adding one or replacing the one they already took -- which is what
  // happened in use (post-ship revision, plan-gui.md §5.3).
  property var recordedAppearances: []

  // Something asked for root while this was up. The indicator stands down for
  // the card (it would be two cards in one place), so its line arrives here
  // instead: a person staring into the lens for a countdown must not be the one
  // person who never hears that a sudo happened (Indicator.qml).
  property string notice: ""

  // Esc, Cancel and Close: the owner decides what closing means.
  signal closeRequested()

  readonly property string phase: session ? session.phase : "framing"

  // Return: Start before anything is running, Done on a verdict.
  function activate() {
    if (!view.session) return
    if (view.phase === "framing") view.session.start()
    else if (view.phase === "verdict") view.session.done()
  }


  // A store keeps ONE recording per appearance: `enroll-session`'s `done` drops
  // every appearance with the label it is about to write before appending the
  // new one (omarchy-face-admin). So recording an appearance a second time
  // replaces that appearance, and never adds a fourth to the three.
  // `length` and an index, not Array.isArray() and indexOf(): this list arrives
  // through a QML property binding, and a list that has been through a QVariant
  // answers false to Array.isArray() while its length is perfectly good. That
  // exact guard is what made the People view say "0 appearances" about
  // everybody (PeopleView.qml), and it will not be repeated here.
  function isRecorded(label) {
    var list = view.recordedAppearances
    if (!list || list.length === undefined) return false
    for (var i = 0; i < list.length; i++)
      if (String(list[i]) === String(label)) return true
    return false
  }

  function isCapturedNow(label) {
    return !!view.session && view.session.hasCaptured(String(label))
  }

  // ✓ saved · ● taken in this session, not written yet · · nothing yet. The same
  // three marks the build's step list uses, for the same reason: a colour alone
  // is a theme's business, and these have to survive a monochrome one.
  function appearanceMark(label) {
    if (view.isCapturedNow(label)) return "●"
    if (view.isRecorded(label)) return "✓"
    return "·"
  }

  // What pressing the button will do TO THE APPEARANCE THE PICKER IS ON. It is
  // not a description of the session: "Again" after a capture of "No glasses"
  // is a lie the moment the picker is moved to an appearance that has never
  // been recorded.
  function actionText() {
    var label = view.session ? String(view.session.appearance) : ""
    if (view.session && view.phase === "verdict" && view.session.verdict === "failed"
        && label === String(view.session.lastAttempt))
      return "Try again"
    if (view.isCapturedNow(label)) return "Again"
    if (view.isRecorded(label)) return "Record again"
    return "Start"
  }

  // The sentence under the picker. Every branch names the appearance, because
  // the whole confusion this answers was about WHICH one a button applied to.
  function actionNote() {
    var label = view.session ? String(view.session.appearance) : ""
    if (label === "") return ""
    if (view.isCapturedNow(label))
      return label + " was taken just now — recording it again replaces what you took, "
             + "and nothing is written until you finish."
    if (view.isRecorded(label))
      return label + " is already recorded — recording it again replaces it. "
             + "A person keeps one recording per appearance."
    return label + " is not recorded yet."
  }

  implicitHeight: content.implicitHeight

  Column {
    id: content
    width: view.width
    spacing: Style.space(10)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: (view.session ? view.session.who() : "") +
            (view.session && view.session.appearance !== ""
             ? " — " + view.session.appearance : "")
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.subtitle
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
    }

    // --- the preview -----------------------------------------------------
    //
    // The RGB camera, mirrored, with an oval guide over it. It is a preview
    // and nothing else: the IR sensor is what records, and it is opened only
    // on `capture`. QtMultimedia is loaded through a Loader so a machine
    // whose Qt has no multimedia module falls back to the plain oval rather
    // than failing to load this file at all.

    Item {
      width: parent.width
      height: Style.space(200)

      Rectangle {
        anchors.fill: parent
        radius: view.radiusFor(height)
        color: Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.05)
        clip: true

        Loader {
          id: preview
          anchors.fill: parent
          active: view.previewDevice !== "" && view.previewOn
          source: "RecordPreview.qml"
          onLoaded: if (item) item.device = view.previewDevice
        }
      }

      // The oval guide, drawn over whatever the preview managed.
      Rectangle {
        anchors.centerIn: parent
        width: parent.height * 0.62
        height: parent.height * 0.82
        radius: width
        color: "transparent"
        border.width: 2
        border.color: view.phase === "capturing" ? view.accent : Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.45)
      }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        width: parent.width - Style.space(24)
        visible: view.previewDevice === "" || preview.status === Loader.Error
        text: "No preview on this laptop — centre your face under the camera"
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
      }

      // The countdown, over the oval, big enough to read from where a face
      // has to be.
      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: view.phase === "countdown"
        text: view.session ? String(view.session.countdown) : ""
        color: view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.display * 2
      }
    }

    // --- what is happening ------------------------------------------------

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: {
        if (!view.session) return ""
        if (view.phase === "authorising") return "Waiting for authorisation…"
        if (view.phase === "countdown") return "Look at the camera"
        if (view.phase === "capturing") return "Hold still"
        if (view.phase === "verdict") return view.session.verdictText()
        if (view.phase === "closing") return "Saving…"
        return "Look at the camera and press Start."
      }
      color: view.phase === "verdict" && view.session && view.session.verdict === "failed"
             ? view.urgent : view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: view.session && view.session.message !== ""
      text: view.session ? view.session.message : ""
      color: view.urgent
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    // --- the appearance picker -------------------------------------------
    //
    // Only while nothing is running or between captures: changing which
    // appearance is being recorded mid-capture would mislabel the encoding
    // that is already on its way back.

    Flow {
      width: parent.width
      spacing: Style.space(6)
      visible: view.phase === "framing" || view.phase === "verdict"

      Repeater {
        model: view.appearanceLabels

        Button {
          required property var modelData
          // The mark is in the label rather than beside it: this kit's
          // Button draws one string, and a second Text next to it would not
          // move with the button it belongs to.
          text: view.appearanceMark(String(modelData)) + "  " + String(modelData)
          selected: view.session && view.session.appearance === String(modelData)
          foreground: view.isRecorded(String(modelData)) || view.isCapturedNow(String(modelData))
                      ? view.foreground : view.dim
          fontFamily: view.fontFamily
          onClicked: if (view.session) view.session.appearance = String(modelData)
        }
      }
    }

    // What the marks mean, and what the button below is about to do. Two
    // short lines rather than a tooltip: the person reading them is looking
    // into a camera lens from arm's length.
    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: view.phase === "framing" || view.phase === "verdict"
      text: "✓ recorded   ●  taken just now   ·  not recorded"
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: (view.phase === "framing" || view.phase === "verdict") && text !== ""
      text: view.actionNote()
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    // --- the buttons ------------------------------------------------------

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(10)

      Button {
        visible: view.phase === "framing"
        // "Start" for an appearance with nothing behind it, "Record again"
        // for one that already has a recording this would replace.
        text: view.actionText()
        bordered: true
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.session.start()
      }

      Button {
        // Another capture in the SAME session, so it draws no second
        // password prompt (plan-merged.md §1 row 4). The word depends on
        // where the picker is: "Again" only re-takes something this session
        // already has.
        visible: view.phase === "verdict"
        text: view.actionText()
        bordered: view.session && view.session.verdict !== "good"
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.session.again()
      }

      Button {
        visible: view.phase === "verdict" && view.session && view.session.captures > 0
        text: "Done"
        bordered: view.session && view.session.verdict === "good"
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.session.done()
      }

      Button {
        visible: view.phase === "framing" || view.phase === "verdict" || view.phase === "authorising"
        text: view.session && view.session.captures > 0 ? "Close" : "Cancel"
        foreground: view.dim
        fontFamily: view.fontFamily
        onClicked: view.closeRequested()
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: view.session && view.session.captures > 0
            ? "Closing keeps what you recorded." : "esc closes · nothing is saved until you finish"
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
    }

    // Not an error and not part of the session: something else asked for
    // root while this was open, and this is the only surface that can say so.
    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: view.notice !== ""
      text: view.notice
      color: view.accent
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }
  }
}
