.pragma library

// The entrance curve every card under the camera grows on (post-ship revision).
//
// It is the step response of a damped second-order system: the thing a spring
// actually does, which is to overshoot once by a known amount and settle, and
// not the wobble `Easing.OutElastic` draws. `damping` is the damping ratio ζ,
// and the overshoot follows from it alone:
//
//     overshoot = exp(-πζ / √(1-ζ²))        ζ = 0.72 → 3.8 %
//
// NumberAnimation cannot be handed a formula, only a cubic Bézier spline, so
// the closed form is sampled into one: `segments` Hermite pieces, C¹ because
// each piece takes its end slopes from the same closed form rather than from
// a difference. Eight pieces hold it to about 0.002 of the true curve, which
// is a fifth of a pixel on a 100 px card.
//
// A curve on the animation, rather than a formula applied to a linear timer,
// is what lets a restart mid-flight pick up from wherever the card currently
// is, and lets an exit run without playing the overshoot backwards.
//
// `peakAt` is where in the duration the overshoot peaks, as a fraction: 0.6 of
// a 350 ms grow is 210 ms in. By t = 1 the envelope is under half a percent,
// and that residual is removed linearly so the curve ends on exactly 1.
function curve(damping, peakAt, segments) {
  var b = Math.PI / peakAt                    // damped angular frequency
  var w = b / Math.sqrt(1 - damping * damping)  // undamped
  var a = damping * w                         // decay rate
  var k = a / b

  function raw(t) { return 1 - Math.exp(-a * t) * (Math.cos(b * t) + k * Math.sin(b * t)) }
  function rawSlope(t) { return Math.exp(-a * t) * (w * w / b) * Math.sin(b * t) }

  var tail = raw(1) - 1
  function x(t) { return raw(t) - t * tail }
  function m(t) { return rawSlope(t) - tail }

  var points = []
  var h = 1 / segments
  for (var i = 0; i < segments; i++) {
    var t0 = i * h, t1 = (i + 1) * h
    points.push(t0 + h / 3, x(t0) + m(t0) * h / 3,
                t1 - h / 3, x(t1) - m(t1) * h / 3,
                t1, x(t1))
  }
  // The spline must land exactly on (1, 1); the sampled value is within 1e-9
  // of it already, but a Bézier that ends at 0.999999 leaves a card a
  // subpixel short for ever.
  points[points.length - 2] = 1
  points[points.length - 1] = 1
  return points
}

// What `curve` will overshoot by, for a caller that wants to say so.
function overshoot(damping) {
  return Math.exp(-Math.PI * damping / Math.sqrt(1 - damping * damping))
}
