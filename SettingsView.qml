import QtQuick
import qs.Commons
import qs.Ui

// Settings: the two places a face is accepted, and the way to Remove.
//
// Phase 1 reports what the engine says about both, read-only. The switches are
// G5 (sudo) and G6 (lock screen): turning sudo on edits /etc/pam.d/sudo and
// turning the lock screen on swaps the live lock service, and neither is wired
// before its own phase gate has been met (plan-merged.md §4).
Column {
  id: view

  property var panel: null

  readonly property color foreground: panel ? panel.foreground : Color.foreground
  readonly property color dim: panel ? panel.dim : Color.muted
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property var config: panel ? panel.config : ({})
  readonly property var lockState: panel ? panel.lockState : ({})

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: "Face for sudo: " + (view.config.sudo === true ? "on" : "off")
    color: view.foreground
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    // The compat states are the engine's vocabulary (plan-merged.md §1 row 12);
    // their user-facing copy lands with the toggle that can change them.
    text: "Lock screen: " + (view.config.lock === true ? "on" : "off")
          + (view.lockState.compat ? " · " + view.lockState.compat : "")
          + (view.lockState.otherLock ? " · another lock plugin: " + view.lockState.otherLock : "")
    color: view.foreground
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: "Both switches arrive with the PAM and lock-screen phases. Until then this page only reports what the engine already says."
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
