.pragma library

// The name a person gets, derived from the label they were given
// (plan-gui.md §5.4, plan-merged.md §1 row 5).
//
// Why the GUI derives it at all: `name` is the key the Profiles contract is
// built on (`omarchy-face-identity verify <name>`), it is immutable, and it has
// to be shown under the label field *while somebody types* -- "Name used by
// Profiles: ase" -- so the person adding a face can see what they are about to
// be called for good. The engine validates it against `nameRule` and refuses a
// taken one (`invalid_name`, `exists`); this is the thing that makes those two
// backstops rather than errors people actually hit.
//
// The order of the steps is the whole rule, and it is not negotiable:
//
//   1. fold the letters where dropping the accent would be wrong. NFKD turns
//      "Å" into A + a combining ring, which decomposes to "a" -- fine. It does
//      nothing at all for "ø", "æ" or "ß", which have no decomposition, so
//      "Bjørn" would come out "bjrn" and "Straße" as "strae". Norwegian names
//      are the first thing this plugin will meet.
//   2. NFKD and drop the marks, which handles every other accent generically.
//   3. lower case, runs of anything else to "-", trim.
//   4. a name must start with a letter (nameRule), so "2 Kids" becomes
//      "p-2-kids" rather than being refused.
//   5. 24 characters, and a numeric suffix if that name is taken -- still
//      within 24, because the rule is on the finished name.

var FOLD = {
  "æ": "ae", "Æ": "ae",
  "ø": "o",  "Ø": "o",
  "å": "a",  "Å": "a",
  "ä": "a",  "Ä": "a",
  "ö": "o",  "Ö": "o",
  "ü": "u",  "Ü": "u",
  "ß": "ss",
  "đ": "d",  "Đ": "d",
  "ł": "l",  "Ł": "l",
  "þ": "th", "Þ": "th",
  "ð": "d",  "Ð": "d"
}

var MAX = 24

function fold(text) {
  var out = ""
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i)
    out += FOLD[ch] !== undefined ? FOLD[ch] : ch
  }
  return out
}

// The slug, before any collision is considered.
function slug(label) {
  var text = fold(String(label === undefined || label === null ? "" : label))
  // NFKD splits an accented letter into its base and a combining mark; the
  // range below is those marks. QML's JS engine has normalize(), but a runtime
  // without it should degrade to "the accent survives and is replaced by -",
  // not to an exception.
  if (typeof text.normalize === "function") text = text.normalize("NFKD")
  text = text.replace(/[̀-ͯ]/g, "")
  text = text.toLowerCase()
  text = text.replace(/[^a-z0-9]+/g, "-")
  text = text.replace(/^-+/, "").replace(/-+$/, "")
  if (text === "") return "person"
  if (!/^[a-z]/.test(text)) text = "p-" + text
  return trimDashes(text.substring(0, MAX))
}

// A cut in the middle of a word leaves the "-" that followed it, and
// "a-very-long-name-indeed-" is both ugly and one character of nothing. The
// trim happens after every cut, not only after the first.
function trimDashes(text) {
  return text.replace(/-+$/, "")
}

// `taken` is the names already in the store (people.json), in any order.
function derive(label, taken) {
  var base = slug(label)
  var used = {}
  if (taken) {
    for (var i = 0; i < taken.length; i++) {
      var name = taken[i]
      // people.json's own records, or a plain list of names: both are useful
      // callers, and guessing wrong here would silently stop the collision
      // suffix from happening at all.
      if (name && typeof name === "object") name = name.name
      if (name) used[String(name)] = true
    }
  }
  if (!used[base]) return base
  for (var suffix = 2; suffix < 1000; suffix++) {
    var tail = "-" + suffix
    var candidate = trimDashes(base.substring(0, MAX - tail.length)) + tail
    if (!used[candidate]) return candidate
  }
  return trimDashes(base.substring(0, MAX - 4)) + "-999"
}

// Both rules are published in people.json, so the GUI validates against what
// the engine actually enforces rather than against a copy of it. These are the
// defaults for the moment before the first read answers.
var NAME_RULE = "^[a-z][a-z0-9-]{0,23}$"
var LABEL_RULE = "^[^\\x00-\\x1f\\x7f]{1,32}$"

function labelOk(label, rule) {
  var text = String(label === undefined || label === null ? "" : label)
  try {
    return new RegExp(rule || LABEL_RULE).test(text)
  } catch (error) {
    return new RegExp(LABEL_RULE).test(text)
  }
}

function nameOk(name, rule) {
  try {
    return new RegExp(rule || NAME_RULE).test(String(name || ""))
  } catch (error) {
    return new RegExp(NAME_RULE).test(String(name || ""))
  }
}
