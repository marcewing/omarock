// The search box's wavy outline while Time Machine is on (WavyOutline.qml):
// an SVG path for a rounded box whose top and bottom edges are waves. Pure,
// so node can test it (tests/wave.test.js).

// The outline of a width × height box, inside it: the stroke's middle runs
// `stroke` / 2 in from the edges, and the waves rise and fall `amplitude`
// either side of the top and bottom lines. Each edge has a whole number of
// waves, about `wavelength` long, so the corners join them where they cross
// the line. Top and bottom move together, like a ribbon.
function outline(width, height, radius, stroke, amplitude, wavelength) {
  var b = stroke / 2
  var top = b + amplitude
  var bottom = height - b - amplitude
  var left = b
  var right = width - b
  var r = Math.max(0, Math.min(radius, (bottom - top) / 2, (right - left) / 2))
  var run = right - left - 2 * r
  if (run <= 0 || bottom <= top) return ""
  var halves = Math.max(2, 2 * Math.round(run / wavelength))
  var half = run / halves
  function n(v) { return Math.round(v * 100) / 100 }
  function corner(x, y) { return r > 0 ? " A " + n(r) + " " + n(r) + " 0 0 1 " + n(x) + " " + n(y) : " L " + n(x) + " " + n(y) }
  var path = "M " + n(left + r) + " " + n(top)
  for (var i = 0; i < halves; i++) {
    var x = left + r + i * half
    path += " Q " + n(x + half / 2) + " " + n(top + (i % 2 === 0 ? -2 : 2) * amplitude) + " " + n(x + half) + " " + n(top)
  }
  path += corner(right, top + r) + " L " + n(right) + " " + n(bottom - r) + corner(right - r, bottom)
  // Right to left, each half as the top's above it.
  for (var j = halves - 1; j >= 0; j--) {
    var to = left + r + j * half
    path += " Q " + n(to + half / 2) + " " + n(bottom + (j % 2 === 0 ? -2 : 2) * amplitude) + " " + n(to) + " " + n(bottom)
  }
  path += corner(left, bottom - r) + " L " + n(left) + " " + n(top + r) + corner(left + r, top) + " Z"
  return path
}

if (typeof module !== "undefined") {
  module.exports = {
    outline: outline
  }
}
