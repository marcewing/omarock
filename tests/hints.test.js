const test = require("node:test")
const assert = require("node:assert/strict")
const Hints = require("../Hints.js")

// A monospace font, 1 unit a character.
const measure = text => text.length
const plain = text => text.replace(/ /g, " ")

const album = [
  Hints.hint("Enter", "play from here", "", true),
  Hints.hint("a", "add to queue"),
  Hints.hint("A", "add to playlist"),
  Hints.hint("i", "info", "Everything known about it"),
  Hints.hint("←", "back", "", true),
  Hints.hint("?", "keys", "", true)
]

test("join: a hint's spaces don't break, the dot stays with the hint before it", () => {
  const text = Hints.join(album.slice(0, 2))
  assert.equal(text, "Enter play from here · a add to queue")
  assert.equal(text.split(" ").length, 2)
})

test("fit: everything when it fits on the line", () => {
  assert.equal(plain(Hints.fit(album, 200, 1, measure)),
    "Enter play from here · a add to queue · A add to playlist · i info · ← back · ? keys")
})

test("fit: the last hints not marked keep go first, in order", () => {
  assert.equal(plain(Hints.fit(album, 60, 1, measure)), "Enter play from here · a add to queue · ← back · ? keys")
  assert.equal(plain(Hints.fit(album, 40, 1, measure)), "Enter play from here · ← back · ? keys")
})

test("fit: two lines take more, broken only between hints", () => {
  const text = Hints.fit(album, 45, 2, measure)
  assert.equal(plain(text), "Enter play from here · a add to queue · A add to playlist · i info · ← back · ? keys")
  assert.ok(Hints.fits(album, 45, 2, measure))
  assert.ok(!Hints.fits(album, 45, 1, measure))
})

test("fit: hints marked keep stay even when they don't fit (the Text elides them)", () => {
  assert.equal(plain(Hints.fit(album, 10, 1, measure)), "Enter play from here · ← back · ? keys")
})

test("fits: a hint wider than the line never fits", () => {
  assert.ok(!Hints.fits([Hints.hint("Enter", "play from here")], 10, 3, measure))
})

test("rows: the keys page's rows, the long text where there is one", () => {
  assert.deepEqual(Hints.rows(album.slice(2, 4)), [["A", "Add to playlist"], ["i", "Everything known about it"]])
})
