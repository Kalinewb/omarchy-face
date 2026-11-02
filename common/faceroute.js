.pragma library

// The routes a surface host opens Face's panel at (plan-face-enroll.md section 4.3).
//
//   setup  people  settings  remove
//   person:<name>
//
// The segment after the first is encodeURIComponent-ed, so a name containing ":"
// or "%" cannot move a field. There is no enrol route: a scan is the standalone card
// in every home (plan-face-enroll.md section 4, Phase 4's live finding). A route comes from outside this
// process (the host's IPC verb, another plugin's call), so the parser is
// strict: anything it does not recognise is null and the caller opens nothing.
//
// Pure: no QML types and no clock, so dev/e2-hosting.sh runs it under node.

var PLAIN = ["setup", "people", "settings", "remove"]
var MAX_LENGTH = 1024

function segment(value) {
  return encodeURIComponent(String(value === undefined || value === null ? "" : value))
}

function unsegment(text) {
  try { return decodeURIComponent(text) } catch (e) { return null }
}

// build("person", {name}) -> "person:Anna". An unknown view builds nothing.
function build(view, args) {
  var a = args || {}
  if (PLAIN.indexOf(view) >= 0) return view
  if (view === "person") return a.name ? "person:" + segment(a.name) : ""
  return ""
}

// parse(route) -> {view, name} or null.
function parse(route) {
  var text = String(route === undefined || route === null ? "" : route)
  if (text === "" || text.length > MAX_LENGTH) return null
  var parts = text.split(":")
  var view = parts[0]

  if (PLAIN.indexOf(view) >= 0) {
    if (parts.length !== 1) return null
    return { view: view, name: "" }
  }

  if (view === "person") {
    if (parts.length !== 2) return null
    var who = unsegment(parts[1])
    if (who === null || who === "") return null
    return { view: "person", name: who }
  }

  return null
}
