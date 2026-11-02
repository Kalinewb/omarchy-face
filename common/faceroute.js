.pragma library

// The routes a surface host opens Face's panel at (plan-face-enroll.md section 4.3).
//
//   setup  people  settings  remove
//   person:<name>
//   enrol:<name>:<appearance>:<label>:<new|old>
//
// Every segment after the first is encodeURIComponent-ed, so a name or a label
// containing ":" or "%" cannot move a field. A route comes from outside this
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

// build("person", {name}) -> "person:Anna"; build("enrol", {...}) -> the five
// segments. An unknown view builds nothing.
function build(view, args) {
  var a = args || {}
  if (PLAIN.indexOf(view) >= 0) return view
  if (view === "person") return a.name ? "person:" + segment(a.name) : ""
  if (view === "enrol") {
    if (!a.name) return ""
    return ["enrol", segment(a.name), segment(a.appearance), segment(a.label),
            a.isNew ? "new" : "old"].join(":")
  }
  return ""
}

// parse(route) -> {view, name, appearance, label, isNew} or null.
function parse(route) {
  var text = String(route === undefined || route === null ? "" : route)
  if (text === "" || text.length > MAX_LENGTH) return null
  var parts = text.split(":")
  var view = parts[0]

  if (PLAIN.indexOf(view) >= 0) {
    if (parts.length !== 1) return null
    return { view: view, name: "", appearance: "", label: "", isNew: false }
  }

  if (view === "person") {
    if (parts.length !== 2) return null
    var who = unsegment(parts[1])
    if (who === null || who === "") return null
    return { view: "person", name: who, appearance: "", label: "", isNew: false }
  }

  if (view === "enrol") {
    if (parts.length !== 5) return null
    var name = unsegment(parts[1])
    var appearance = unsegment(parts[2])
    var label = unsegment(parts[3])
    if (name === null || name === "" || appearance === null || label === null) return null
    if (parts[4] !== "new" && parts[4] !== "old") return null
    return { view: "enrol", name: name, appearance: appearance, label: label,
             isNew: parts[4] === "new" }
  }

  return null
}
