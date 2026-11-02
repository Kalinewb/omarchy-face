import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// What Face shows, in either of its homes: the hero, the one view that is
// current and the hint under it.
//
// FacePanel.qml puts this inside the stock bar's popup and Surface.qml inside
// the notch's panel; neither draws any of it. That is the point of the split --
// the six views are written once, so the two homes cannot
// drift (plan-face-enroll.md section 4). The home owns the window, the button
// and the container animation; this owns the content and the keys.
//
// It reads everything through `model` (FaceModel.qml): colours, the view stack,
// the status document and the engine seam. The views keep the name `panel` for
// it, as they always had.
Item {
  id: root

  property var model: null

  // What the home hands the keyboard to.
  readonly property Item focusItem: keyCatcher
  // The content's own height, for a home that sizes itself to it.
  readonly property real contentHeight: column.implicitHeight

  implicitWidth: Style.space(320)
  implicitHeight: column.implicitHeight

  signal tabRequested(int direction)

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent

    // Esc pops one view, and closes the popup only from the root view
    // (plan-gui.md §2.2).
    onCloseRequested: if (root.model) root.model.back()
    onTabRequested: function (direction) { root.tabRequested(direction) }
    onReturnRequested: {
      if (root.model && root.model.view === "test" && body.item && body.item.activate)
        body.item.activate()
    }

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      // A right-side gutter, always reserved rather than only appearing
      // when the scrollbar shows: `PanelHero`'s trailing control (the Back
      // button) anchors flush to its own right edge, which is this
      // column's right edge, which is exactly where the vertical
      // scrollbar's overlay track sits -- so a visible, taller view used
      // to render its Back button underneath the scrollbar (post-ship
      // revision, found via live use).
      Column {
        id: column
        width: flick.width - Style.space(10)
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: root.model ? root.model.viewTitle() : ""
          meta: root.model ? root.model.chrome().meta : ""
          foreground: root.model ? root.model.foreground : Commons.Color.foreground
          fontFamily: root.model ? root.model.fontFamily : Style.font.family

          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: "\u{f0643}"
              color: root.model.foreground
              font.family: root.model.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          trailingControl: Component {
            PanelActionButton {
              visible: root.model.viewStack.length > 1
              iconText: "\u{f004d}"
              tooltipText: "Back"
              foreground: root.model.foreground
              fontFamily: root.model.fontFamily
              onClicked: root.model.back()
            }
          }
        }

        // One view at a time. A Loader rather than six visible bindings, so
        // a view that is not on screen holds no timers and no file watches.
        Loader {
          id: body
          width: parent.width
          sourceComponent: !root.model ? setupComponent
                         : root.model.view === "people" ? peopleComponent
                         : root.model.view === "person" ? personComponent
                         : root.model.view === "settings" ? settingsComponent
                         : root.model.view === "remove" ? removeComponent
                         : root.model.view === "test" ? testComponent
                         : setupComponent
          onLoaded: if (item && "panel" in item) item.panel = root.model
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          topPadding: Style.space(2)
          text: root.model ? root.model.chrome().hint : ""
          color: root.model ? root.model.dim : Commons.Color.muted
          font.family: root.model ? root.model.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }
    }
  }

  Component { id: setupComponent;    SetupView {} }
  Component { id: peopleComponent;   PeopleView {} }
  Component { id: personComponent;   PersonView {} }
  Component { id: settingsComponent; SettingsView {} }
  Component { id: removeComponent;   RemoveView {} }
  Component { id: testComponent;     TestResultView {} }
}
