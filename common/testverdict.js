.pragma library

// What a Test says (plan-gui.md section 5.2), in one place: the Face service's
// TestCard.qml (a window under the stock bar's popup) and TestResultView.qml
// (the same words in place, inside the notch's panel) read it, so the two homes
// cannot say different things about the same check.
//
// `code` is the helper's exit code (Profiles contract, plan-merged.md 2.5):
// 0 present, 1 not present, 2 bad or unknown name, 3 unavailable, 4 rate
// limited or camera busy; -1 means it could not be run at all.

function headline(phase, code, who) {
  if (phase !== "done") return "Look at the camera"
  if (code === 0) return "Recognised " + who
  if (code === 1) return "Did not recognise " + who
  if (code === 2) return who + " is not set up"
  if (code === 4) return "Checked too recently — try again in a moment"
  // 3, and anything else: the helper not having run at all (126/127 from the
  // launcher) or a code this version does not know. It is not an answer about a
  // person, so it never reads like one.
  return "Face ID cannot check right now"
}

// Said every time, because "Recognised Anna" alone invites the reading that
// something was unlocked. Nothing was.
function subline(phase) {
  return phase === "done" ? "Nothing was unlocked — this was only a test."
                          : "Checking who is in front of the camera."
}

function glyph(phase, code) {
  if (phase === "done" && code === 0) return "✓"
  if (phase === "done" && code === 1) return "✕"
  return "\u{f0643}"
}
