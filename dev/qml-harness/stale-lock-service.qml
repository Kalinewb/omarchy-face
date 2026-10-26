import QtQuick

// A stand-in for Omarchy's lock screen that goes stale after an unlock the way
// the real one does under Quickshell 0.3.2, with the five public names the
// wrapper depends on (E3).
//
// What it reproduces. The stock `locked` is `lockRequested || sessionLock.locked
// || sessionLock.secure` (Service.qml:38), and `sessionLock` is Quickshell's
// WlSessionLock, whose two properties are C++ getters. QML caches a binding's
// value and reads a C++ property again only when that property's notify signal
// fires: `lockStateChanged` for `locked`, `secureStateChanged` for `secure`.
// Quickshell 0.3.2's unlock fires `secureStateChanged` while `locked` still
// reads true, and never fires `lockStateChanged` at all (session_lock.cpp:
// 173-184). So `locked` reads false and the stock binding never finds out.
//
// A QML property always announces a change, so this cannot be done with plain
// properties. `sessionLock` below keeps the two apart instead: `locked` and
// `secure` are what the C++ getters return, always current; `seenLocked` and
// `seenSecure` are what a binding on them has read, moved only by the two
// notify signals. The stock binding reads the seen pair, which is exactly what
// the QML engine does with the real one.
//
// `quickshellFixed` plays a Quickshell that sends the missing signal, which is
// the healthy state the wrapper must leave alone. Nothing here takes a session
// lock, draws or authenticates.
Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool authenticatingPassword: false
  readonly property bool locked: lockRequested || sessionLock.seenLocked || sessionLock.seenSecure

  property bool quickshellFixed: false
  property string lastEvent: "init"
  property int lockRequests: 0
  property int unlockCount: 0
  readonly property int lockNotifies: sessionLock.lockNotifies

  function logEvent(event) { lastEvent = event }

  function beginLock() {
    lockRequests += 1
    lockRequested = true
    logEvent("lock-requested")
    sessionLock.lock()
    return true
  }

  // The stock one, minus the PAM reset, timers and wake (Service.qml:152-164).
  function finishUnlock() {
    if (!root.locked && !lockRequested) return
    unlockCount += 1
    lockRequested = false
    sessionLock.unlock()
    logEvent("unlocked")
  }

  // A password accepted: the stock PamContext calls finishUnlock() itself
  // (Service.qml:336), and the wrapper never hears of it but by lockRequested.
  function passwordUnlock() { finishUnlock() }

  // The `lock` IPC handler, word for word where it matters (Service.qml:518-522).
  function ipcLock() {
    if (!root.locked && !root.beginLock()) return "failed"
    return "ok"
  }

  // The fields of `omarchy-shell lock status` the bug report quotes.
  function status() {
    return JSON.stringify({ locked: root.locked, requested: root.lockRequested,
                            sessionLocked: sessionLock.locked, secure: sessionLock.secure })
  }

  QtObject {
    id: sessionLock

    property bool locked: false
    property bool secure: false
    property bool seenLocked: false
    property bool seenSecure: false
    property int lockNotifies: 0

    signal lockStateChanged()
    signal secureStateChanged()

    // Either notify makes the stock binding read both getters again.
    onLockStateChanged: {
      lockNotifies += 1
      seenLocked = locked
      seenSecure = secure
      root.logEvent("session-locked=" + locked)
    }
    onSecureStateChanged: {
      seenLocked = locked
      seenSecure = secure
      root.logEvent("secure=" + secure)
    }

    function lock() {
      locked = true
      lockStateChanged()
      secure = true
      secureStateChanged()
    }

    // QSWaylandSessionLock::unlock() emits `unlocked` before the manager drops
    // its lock, so `secureStateChanged` lands while isLocked() is still true;
    // then the lock is gone and `if (isLocked()) emit lockStateChanged()` is
    // asked too late to be true.
    function unlock() {
      if (!locked) return
      secure = false
      secureStateChanged()
      locked = false
      if (root.quickshellFixed) lockStateChanged()
    }
  }
}
