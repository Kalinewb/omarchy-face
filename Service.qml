import QtQuick
import Quickshell
import Quickshell.Io

// The Face service: everything that has to outlive the popup.
//
// The popup is a bar widget, and every write under ~/.config/omarchy/plugins
// destroys and rebuilds every bar widget (plan-engine.md E13). This service is
// keepLoaded, so it survives that, and it is therefore where the plan puts the
// four duties that cannot be interrupted by a reload (plan-gui.md §1, §6):
//
//   · the sudo/identity indicator, which draws under the webcam (G5, G6)
//   · the recording card, which needs exclusive focus and would close a popup
//     anyway (G3)
//   · the lock-screen duties: `omarchy-face-lock sync` at shell start, the
//     30 s wrapper health check, and the single notification per new reason
//     (G6, plan-merged.md §1 row 13 and §3)
//
// Phase 1 builds none of them. It is deliberately inert: no processes, no file
// watches, no writes. In particular it does NOT run `sync` yet -- that call
// stages the wrapper into the plugins folder, and staging before the wrapper
// exists would be a reload for nothing.
Item {
  id: root

  // Injected by the host when the service is created (shell.qml:929-932).
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  // The popup registers `graveklar.face`; this is the service's own target.
  //
  // plan-gui.md §1 lists record(), testMatch(), cancel() and open() as one
  // handler. They cannot be one: a Quickshell IPC target is registered by a
  // single object, the popup is the thing open() has to act on, and a bar
  // widget is instantiated once per bar -- so the popup cannot own a target the
  // service must keep answering across reloads. The split is therefore:
  //
  //   graveklar.face        the popup: show/hide/toggle/open(view, name)
  //   graveklar.face.card   this service: record/testMatch/cancel
  //
  // and the two call each other with `omarchy-shell <target> <method> …`, which
  // is one Process either way. Recording still returns to the popup exactly as
  // §1 describes it, through `open("person", name)`.
  IpcHandler {
    target: "graveklar.face.card"

    // Drive one enroll-session in a card under the webcam (G3).
    function record(name: string, appearance: string, label: string, isNew: string): string {
      return "not built yet: the recording card arrives with the people store"
    }

    // "Test — does it recognise Anna now?" (G4/G6).
    function testMatch(name: string): string {
      return "not built yet: Test arrives with omarchy-face-identity"
    }

    // Close whatever card is on screen. For a pkexec'd session that means
    // closing its stdin, never a signal: it runs as root and the user cannot
    // signal it (plan-merged.md §2 rule 7).
    function cancel(): void {}

    // What this service is doing, as JSON. Phase 1 has nothing to report but
    // that it loaded, which is the one thing worth being able to ask.
    function state(): string {
      return JSON.stringify({ loaded: true, omarchyPath: root.omarchyPath, duties: [] })
    }
  }

  Component.onCompleted: console.log("graveklar.face", "service loaded")
}
