import QtQuick

// A stand-in for Omarchy's lock screen, with the five public names the wrapper
// depends on (E3) and nothing else.
//
// It exists because the wake rule cannot be tested against the real one without
// locking the session this is running on. What the real stock lock is used for
// instead is the contract check -- dev/g6-lock-offscreen.sh loads the REAL
// /usr/share/omarchy/shell/plugins/lock/Service.qml through the shipped wrapper
// and asserts the composition holds. This file is what the wake, generation and
// stale-result cases are driven through, and it is deliberately dumb: it takes
// no session lock, draws nothing and authenticates nobody.
Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool authenticatingPassword: false
  readonly property bool locked: lockRequested

  // How the harness sees that the wrapper opened the lock, and how many times.
  property int unlockCount: 0

  function finishUnlock() {
    if (!lockRequested) return
    unlockCount += 1
    lockRequested = false
  }

  // What the real one does when the user types their password (Service.qml:148),
  // and what `beginLock()` does afterwards (:135) -- the two halves of the race
  // the lock-generation counter closes. `passwordUnlock` is `finishUnlock`
  // without the tally, so a test can tell an unlock the WRAPPER caused from one
  // the person caused.
  function beginLock() { lockRequested = true }
  function passwordUnlock() { lockRequested = false }
}
