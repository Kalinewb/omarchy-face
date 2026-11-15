.pragma library

// The dot scan's arithmetic, without a pixel in it (3.2.0). DotStage.qml draws what
// these return; dev/e3-enrol-view.sh asks them through the real card.
//
// A ball on the card visits five stations, in this order: the centre, then left, top,
// right, bottom. The person looks (or turns) towards it and presses Space; each press is
// one capture, and the ball stays until that pose was taken. The ball has an outer ring
// that breathes while it waits and closes in over about a second after Space, while the
// helper collects frames; it only finishes closing when the helper says enough good frames
// were gathered, and it opens again with a plain reason when they were not.

var POSES = ["centre", "left", "top", "right", "bottom"]

// Where each station is, as a fraction of the stage's half width and half height from its
// middle (x to the right, y down). The screen's sides, which the mirrored preview makes the
// person's own.
var STATION = {
  centre: { x: 0, y: 0 },
  left: { x: -1, y: 0 },
  top: { x: 0, y: -1 },
  right: { x: 1, y: 0 },
  bottom: { x: 0, y: 1 }
}

// The pose the helper wants next, given the ones it holds; "" when all five are.
function nextPose(held) {
  for (var i = 0; i < POSES.length; i++)
    if (!has(held, POSES[i])) return POSES[i]
  return ""
}

function has(list, value) {
  if (!list || list.length === undefined) return false
  for (var i = 0; i < list.length; i++) if (list[i] === value) return true
  return false
}

function clamp(x, lo, hi) { return Math.max(lo, Math.min(hi, x)) }

// How many poses are held, the centre included, out of five.
function count(held) {
  var n = 0
  for (var i = 0; i < POSES.length; i++) if (has(held, POSES[i])) n++
  return n
}

// May a scan be saved with what is held? The helper's own floor (DOT_FLOOR): the centre,
// left and right. The card shows Save only then, and Done once all five are held.
function canSave(held) {
  return has(held, "centre") && has(held, "left") && has(held, "right")
}

// The ring: it closes in over RING_MS from the press and never past what the helper has
// gathered. `good` of `need` frames give it up to 0.3 + 0.7 of the way, so it moves from the
// first moment and cannot finish early; only `landed` (the helper's word) takes it to 1.
var RING_MS = 1000
function closing(elapsedMs, good, need) {
  var frames = need > 0 ? clamp(good / need, 0, 1) : 0
  return clamp(Math.min(elapsedMs / RING_MS, 0.3 + 0.7 * frames), 0, 1)
}

// --- the stations on the SCREEN (3.2.1) ------------------------------------------------------
//
// The ball does not stay on the card. It goes to the real screen: the middle of the output for the
// centre (where a person looks when they unlock), and the left, top, right and bottom EDGES of the output the
// card is on, so the head physically turns towards the sides of the screen. A pure function of the output's
// size, never of the card's: `w` and `h` are the output's width and height in px. SCREEN_MARGIN keeps the
// ball's centre that far from the physical edge, so the ball and its breathing ring (about 34 px at
// SCREEN_UNIT) are whole and not under a bar.
var SCREEN_MARGIN = 64
var SCREEN_UNIT = 1.4
function screenStation(pose, w, h) {
  var cx = w / 2, cy = h / 2, m = SCREEN_MARGIN
  if (pose === "left") return { x: m, y: cy }
  if (pose === "right") return { x: w - m, y: cy }
  if (pose === "top") return { x: cx, y: m }
  if (pose === "bottom") return { x: cx, y: h - m }
  return { x: cx, y: cy }
}

// The ring's radius in pixels: wide at rest (breathing between REST and REST + BREATH), then in
// to just outside the ball as it closes.
var BALL = 8
var REST = 20
var BREATH = 4
function ringRadius(close, pulse, unit) {
  var u = unit === undefined ? 1 : unit
  var open = (REST + BREATH * clamp(pulse, 0, 1)) * u
  return open - (open - (BALL + 3) * u) * clamp(close, 0, 1)
}

// What the line says for the pose the ball is on.
var PROMPT = {
  centre: "Look at the ball",
  left: "Turn to the ball on the left",
  top: "Look up at the ball",
  right: "Turn to the ball on the right",
  bottom: "Look down at the ball"
}

// How many presses of one session may end "That did not look like you" before the helper closes it
// (the helper's DOT_NOT_YOU_CAP, which is the one that decides; this is only to say so in words).
var NOT_YOU_CAP = 5

// What a press that did not work says, in plain words, by the helper's code.
var WHY = {
  no_face: "No face found",
  multiple_faces: "More than one face",
  too_dark: "Too dark",
  black_frames: "Too dark",
  not_you: "That did not look like you",
  too_far: "Come a little closer",
  too_close: "Move back a little",
  face_cut_off: "Keep your whole face in view",
  face_tilted: "Keep your head level",
  timeout: "That took too long",
  camera_busy: "The camera is in use",
  bad_sweep: "Something went wrong"
}

// `short` is the helper's whole percent by which a too small face has to look bigger (1 to 99), when it said one
function why(code, short) {
  if (code === "too_far" && Number(short) >= 1)
    return "Come a little closer (about " + Math.round(Number(short)) + "% bigger)"
  return WHY[code] !== undefined ? WHY[code] : "That did not work"
}

// --- the idle demo (no camera): what the scan will ask, played as a loop ----------------------
//
// A pure function of time. The head turns towards the ball; the ring
// breathes, then closes and the ball moves on. Poses are (yaw, pitch) in [-1, 1], yaw
// positive to the person's right (the screen's right in the mirrored preview), pitch
// positive up. `ball` is the ball's station in the stage's own fractions, `close` the ring
// (-1 while it breathes), `pressed` the moment Space is down, `held` the poses taken so far.

var DEMO_TRAVEL = 0.8     // s: the ball moves, and the head follows
var DEMO_WAIT = 0.7       // s: the ring breathes
var DEMO_CLOSE = 1.0      // s: Space, and the ring closes in
var DEMO_LAND = 0.4       // s: closed, then on
var DEMO_END = 1.8        // s: all set, then the loop starts over
var DEMO_POSE = { centre: [0, 0], left: [-1, 0], top: [0, 1], right: [1, 0], bottom: [0, -1] }
var DEMO_PROMPT = { centre: "Look at the ball", left: "Turn left", top: "Look up", right: "Turn right", bottom: "Look down" }

function smooth(x) { x = clamp(x, 0, 1); return x * x * (3 - 2 * x) }

function demoSeconds() {
  return POSES.length * (DEMO_TRAVEL + DEMO_WAIT + DEMO_CLOSE + DEMO_LAND) + DEMO_END
}

function demoFrame(time) {
  var total = demoSeconds()
  var t = ((Number(time) || 0) % total + total) % total
  var slot = DEMO_TRAVEL + DEMO_WAIT + DEMO_CLOSE + DEMO_LAND
  var out = { yaw: 0, pitch: 0, ball: { x: 0, y: 0 }, close: -1, pressed: false, held: [], pose: "centre",
              caption: "", total: total, done: false, t: t }
  var from = { x: 0, y: 0 }, fromHead = [0, 0]
  for (var s = 0; s < POSES.length; s++) {
    var pose = POSES[s]
    var at = t - s * slot
    var to = STATION[pose], toHead = DEMO_POSE[pose]
    if (at < slot) {
      var travel = s === 0 ? 1 : smooth(at / DEMO_TRAVEL)
      out.ball = { x: from.x + (to.x - from.x) * travel, y: from.y + (to.y - from.y) * travel }
      out.yaw = fromHead[0] + (toHead[0] - fromHead[0]) * travel
      out.pitch = fromHead[1] + (toHead[1] - fromHead[1]) * travel
      out.pose = pose
      out.caption = DEMO_PROMPT[pose]
      var closeAt = at - DEMO_TRAVEL - DEMO_WAIT
      if (closeAt >= 0) {
        out.close = clamp(closeAt / DEMO_CLOSE, 0, 1)
        out.pressed = closeAt < 0.18
      }
      return out
    }
    out.held.push(pose)
    from = to
    fromHead = toHead
  }
  // all five taken: the head comes back to the middle
  var back = smooth((t - POSES.length * slot) / 0.8)
  out.ball = { x: from.x * (1 - back), y: from.y * (1 - back) }
  out.yaw = fromHead[0] * (1 - back)
  out.pitch = fromHead[1] * (1 - back)
  out.pose = ""
  out.done = true
  out.caption = "All set."
  return out
}
