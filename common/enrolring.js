.pragma library

// The enrol ring's arithmetic, without a pixel in it (plan-face-enroll.md
// section 3). EnrolRing.qml draws what these return; dev/e3-enrol-view.sh and
// node can ask them directly.
//
// 60 ticks = 12 pose bins x 5. Bin k is the wedge centred 30k degrees clockwise
// from the top, so right, down, left and up are bins 3, 6, 9 and 0 (the same map
// SWEEP_PY's `locate` uses; `ring_angle` below is its twin).

var TICKS_PER_BIN = 5
var BINS = 12
var TICKS = TICKS_PER_BIN * BINS

// Simple's four targets, in the order the engine takes them: left, right, up,
// down. Advanced names all twelve. The view never chooses a subset: root refuses
// one (`valid_sweep`).
var SIMPLE_TARGETS = [9, 3, 0, 6]

// `R_MIN` of SWEEP_PY: inside it the head is at the centre, and the dot is absent.
var R_MIN = 1.0
var R_DOT_FROM = 0.5

// The three looks a tick can have before it is covered, in pixels and opacity.
var REST_LEN = 8
var CURRENT_LEN = 14
var INACTIVE_LEN = 5
var DONE_LEN = 20
var REST_OPACITY = 0.7
var INACTIVE_OPACITY = 0.2
var DONE_OPACITY = 0.9

function range(n) {
  var out = []
  for (var i = 0; i < n; i++) out.push(i)
  return out
}

function targetsFor(mode) {
  return mode === "advanced" ? range(BINS) : SIMPLE_TARGETS.slice()
}

function has(list, value) {
  if (!list || list.length === undefined) return false
  for (var i = 0; i < list.length; i++) if (list[i] === value) return true
  return false
}

function clamp(x, lo, hi) { return Math.max(lo, Math.min(hi, x)) }

// Degrees clockwise from the top, 0 up to 360: the engine's `ring_angle`.
function ringAngle(u, v) {
  var a = Math.atan2(u, -v) * 180 / Math.PI
  return a < 0 ? a + 360 : a
}

// The head dot at `radius` px from the centre: where it sits (x right, y down
// from the centre) and how visible it is. Its opacity ramps from 0 at r 0.5 to 1
// at R_MIN, so near the middle it is absent rather than jumpy.
function dot(u, v, radius) {
  var r = Math.sqrt(u * u + v * v)
  var a = ringAngle(u, v) * Math.PI / 180
  return {
    angle: ringAngle(u, v),
    r: r,
    x: radius * Math.sin(a),
    y: -radius * Math.cos(a),
    opacity: clamp((r - R_DOT_FROM) / (R_MIN - R_DOT_FROM), 0, 1)
  }
}

// A tick's angle, clockwise from the top: bin k owns ticks 5k..5k+4, laid
// symmetrically about 30k degrees.
function tickAngle(index) {
  var k = Math.floor(index / TICKS_PER_BIN)
  var j = index % TICKS_PER_BIN
  return 30 * k - 15 + 6 * (j + 0.5)
}

// How much of tick `j` of a bin whose progress is `p` is covered: floor(5p)
// ticks are whole, the next interpolates, so dwell progress is smooth.
function cover(p, j) {
  return clamp(TICKS_PER_BIN * clamp(Number(p) || 0, 0, 1) - j, 0, 1)
}

// The look of tick `index`. Three base looks, then `cover` moves it towards the
// done look:
//   inactive  Simple's eight bins that are not targets: 5 px, 0.2, never changed
//   rest      a target that is not current: 8 px, secondary, 0.7
//   current   the target the engine names (Advanced: the unfilled wedge the
//             head is in): 14 px, foreground, 1.0, static
// `role` is which palette colour the base is, `cover` how far it has moved to
// `accent`. The length, opacity and colour of the covered look are the same for
// every tick, so nothing leans on colour alone.
function look(mode, targets, target, bins, index) {
  var k = Math.floor(index / TICKS_PER_BIN)
  var j = index % TICKS_PER_BIN
  var isTarget = has(targets, k)
  var p = bins && bins.length > k ? Number(bins[k]) || 0 : 0
  var c = isTarget ? cover(p, j) : 0
  var base
  if (!isTarget) base = { role: "secondary", len: INACTIVE_LEN, opacity: INACTIVE_OPACITY, kind: "inactive" }
  else if (target === k) base = { role: "foreground", len: CURRENT_LEN, opacity: 1.0, kind: "current" }
  else base = { role: "secondary", len: REST_LEN, opacity: REST_OPACITY, kind: "rest" }
  return {
    kind: c > 0 ? "done" : base.kind,
    baseKind: base.kind,
    role: base.role,
    cover: c,
    len: base.len + (DONE_LEN - base.len) * c,
    opacity: base.opacity + (DONE_OPACITY - base.opacity) * c
  }
}

// The fraction of the centre arc that is drawn, clockwise from the top: it sweeps
// with `centre` while the centre is the current target and is closed once held.
function centreArc(phase, centre) {
  if (phase === "lap1" || phase === "lap2" || phase === "trial") return 1
  if (phase === "centre") return clamp(Number(centre) || 0, 0, 1)
  return 0
}

// Counts: how many targets are filled (progress 1) and the step the person is on.
function filledCount(targets, bins) {
  var n = 0
  for (var i = 0; i < targets.length; i++)
    if (bins && Number(bins[targets[i]]) >= 0.999) n++
  return n
}

// WCAG relative luminance and contrast of `rgb` ({r,g,b} 0..1) at `opacity` over
// `back` (default pure black). The offscreen suite fails any state-carrying tick
// under 3:1, and a done look within 1.5:1 of the rest look.
function lin(c) { return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4) }
function luminance(c) { return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b) }
function over(rgb, opacity, back) {
  var b = back || { r: 0, g: 0, b: 0 }
  return { r: rgb.r * opacity + b.r * (1 - opacity), g: rgb.g * opacity + b.g * (1 - opacity),
           b: rgb.b * opacity + b.b * (1 - opacity) }
}
function contrast(a, b) {
  var la = luminance(a), lb = luminance(b)
  var hi = Math.max(la, lb), lo = Math.min(la, lb)
  return (hi + 0.05) / (lo + 0.05)
}
