const test = require("node:test")
const assert = require("node:assert/strict")
const Wave = require("../Wave.js")

// The path's points (every number pair after a command letter but A's radii
// and flags), to check they stay in the box.
function points(path) {
  const out = []
  const parts = path.split(" ")
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i]
    const take = (k) => { for (let j = 0; j < k; j++) out.push([Number(parts[i + 1 + 2 * j]), Number(parts[i + 2 + 2 * j])]) }
    if (p === "M" || p === "L") take(1)
    else if (p === "Q") take(2)
    else if (p === "A") out.push([Number(parts[i + 6]), Number(parts[i + 7])])
  }
  return out
}

test("the outline stays inside the box, waves and all", () => {
  const path = Wave.outline(400, 30, 4, 1, 1.5, 14)
  assert.match(path, /^M /)
  assert.match(path, / Z$/)
  for (const [x, y] of points(path)) {
    assert.ok(x >= 0 && x <= 400, "x " + x)
    // A control point sits twice the amplitude out; the curve only reaches
    // half way to it, so the curve itself stays at stroke / 2 or more.
    assert.ok(y >= 0.5 - 1.5 && y <= 29.5 + 1.5, "y " + y)
  }
})

test("a whole number of waves on each edge, about the wavelength long", () => {
  const path = Wave.outline(400, 30, 4, 1, 1.5, 14)
  const curves = path.split(" ").filter((p) => p === "Q").length
  // 391 px of edge between the corners: 28 waves, 56 halves, top and bottom.
  assert.equal(curves, 2 * 56)
})

test("top and bottom move together", () => {
  const path = Wave.outline(100, 30, 0, 1, 1.5, 14)
  const q = path.split(" Q ").slice(1).map((s) => s.split(" ").slice(0, 2).map(Number))
  const halves = q.length / 2
  // The top's first half rises (y less than the line), and so does the
  // bottom's half under it, which is the bottom's last drawn.
  assert.ok(q[0][1] < 2)
  assert.ok(q[2 * halves - 1][1] < 30 - 2)
  assert.equal(q[0][0], q[2 * halves - 1][0])
})

test("square corners, and nothing for a box too small", () => {
  assert.doesNotMatch(Wave.outline(100, 30, 0, 1, 1.5, 14), / A /)
  assert.equal(Wave.outline(4, 30, 4, 1, 1.5, 14), "")
})
