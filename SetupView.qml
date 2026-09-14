import QtQuick
import qs.Commons
import qs.Ui

// Setup: one row per thing that has to be true before a face can approve
// anything. The ids, their order and their meanings are the engine's
// (plan-engine.md §10.1, plan-merged.md §1 row 3) -- this view renders what
// `omarchy-face-status` sends and invents nothing.
//
// Phase 1 renders the rows and their tone only. The per-row copy, the Fix
// buttons, the build progress and the log tail arrive with the engine that
// makes them true (G2/G3, plan-merged.md §4).
Column {
  id: view

  property var panel: null

  readonly property color foreground: panel ? panel.foreground : Color.foreground
  readonly property color dim: panel ? panel.dim : Color.muted
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property var rows: panel ? panel.rows : []

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  // Three things the popup can be showing, and they must never be confused:
  // an answer, no answer yet, and "there is nothing installed to answer".
  // A permanent "Checking…" is the failure plan-gui.md §2.3 names explicitly.
  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: view.rows.length === 0
    wrapMode: Text.WordWrap
    text: {
      if (!view.panel) return ""
      if (view.panel.statusOutcome === "") return "Checking…"
      if (view.panel.statusOutcome === "missing")
        return "Face Unlock is not installed on this machine yet.\n\nNothing has been set up, no PAM stack has been touched, and there is nothing to remove. The installer arrives with the next phase of this plugin."
      if (view.panel.statusOutcome === "ok") return "The engine answered, but sent no rows."
      return "Face Unlock could not read its own status (" + view.panel.statusOutcome + ")."
    }
    color: view.dim
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
  }

  Repeater {
    model: view.rows

    Item {
      required property var modelData
      width: view.width
      implicitHeight: rowContent.implicitHeight + Style.space(10)

      Row {
        id: rowContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        spacing: Style.space(10)

        // Tone, not decoration: `unknown` is never rendered as healthy
        // (plan-merged.md §2 rule 6), so it gets the dim dot, not the good one.
        Text {
          textFormat: Text.PlainText
          text: "●"
          color: modelData.state === "ok" ? view.foreground
                 : modelData.state === "unknown" ? view.dim
                 : Color.urgent
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          width: rowContent.width - rowContent.spacing * 2 - 2 * Style.space(6) - Style.space(12)
          spacing: 0

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: String(modelData.label || modelData.id || "")
            color: view.foreground
            font.family: view.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            // The detail is the engine's sentence. Where it has none, the state
            // word is still better than an empty line: it says which of the
            // four states this row is in.
            text: String(modelData.detail || "") !== "" ? String(modelData.detail)
                  : (modelData.state === "unknown" ? "could not be determined" : String(modelData.state || ""))
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // The shortcuts into the other views. They are here from phase 1 because the
  // view stack is what phase 1 delivers, and a stack with no way into it cannot
  // be tested.
  PanelSeparator {
    width: parent.width
    visible: view.rows.length > 0
    foreground: view.foreground
  }

  Row {
    width: parent.width
    spacing: Style.space(8)

    Repeater {
      model: [
        { view: "people",   label: "People" },
        { view: "settings", label: "Settings" },
        { view: "remove",   label: "Remove" }
      ]

      Button {
        required property var modelData
        text: modelData.label
        bordered: true
        foreground: view.foreground
        fontFamily: view.fontFamily
        fontSize: Style.font.caption
        onClicked: if (view.panel) view.panel.pushView(modelData.view)
      }
    }
  }
}
