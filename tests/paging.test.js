const test = require("node:test")
const assert = require("node:assert/strict")
const Paging = require("../Paging.js")

// Rows 20 high, 2 apart, the first two of no height (a level's buttons).
const boxes = Array.from({ length: 30 }, (_, index) =>
  ({ index, y: index < 2 ? 0 : (index - 2) * 22, height: index < 2 ? 0 : 20 }))

test("shown: the rows wholly in view, not the ones cut off or of no height", () => {
  assert.deepEqual(Paging.shown(boxes, 0, 110), { first: 2, last: 6 })
  assert.deepEqual(Paging.shown(boxes, 30, 140), { first: 4, last: 7 })
  assert.equal(Paging.shown(boxes, 5, 15), null)
  assert.equal(Paging.shown([], 0, 100), null)
})

test("page down: to the last row in view, then a page on", () => {
  const rows = { first: 2, last: 6 }
  assert.equal(Paging.page(3, 30, rows, 1), 6)
  assert.equal(Paging.page(0, 30, rows, 1), 6)
  assert.equal(Paging.page(6, 30, rows, 1), 10)
  assert.equal(Paging.page(28, 30, { first: 24, last: 28 }, 1), 29)
  assert.equal(Paging.page(29, 30, { first: 25, last: 29 }, 1), 29)
})

test("page up: to the first row in view, then a page back, to the buttons", () => {
  assert.equal(Paging.page(8, 30, { first: 4, last: 8 }, -1), 4)
  assert.equal(Paging.page(4, 30, { first: 4, last: 8 }, -1), 0)
  assert.equal(Paging.page(12, 30, { first: 12, last: 16 }, -1), 8)
})

test("page: a cursor out of view comes into it; nothing in view is ten rows", () => {
  assert.equal(Paging.page(20, 30, { first: 2, last: 6 }, -1), 2)
  assert.equal(Paging.page(20, 30, { first: 2, last: 6 }, 1), 24)
  assert.equal(Paging.page(5, 30, null, 1), 15)
  assert.equal(Paging.page(5, 30, null, -1), 0)
  assert.equal(Paging.page(0, 0, null, 1), -1)
  assert.equal(Paging.page(0, 1, { first: 0, last: 0 }, 1), 0)
})
