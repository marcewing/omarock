const test = require("node:test")
const assert = require("node:assert/strict")
const Editing = require("../Editing.js")

const Ctrl = 0x04000000, Shift = 0x02000000, Alt = 0x08000000, Meta = 0x10000000
const deadAcute = 0x01001251, deadGrave = 0x01001250, deadDiaeresis = 0x01001257, deadCedilla = 0x0100125b

// What an edit leaves: text with range's start..end taken out.
function edit(action, text, cursor, selectionStart = cursor, selectionEnd = cursor) {
  const r = Editing.range(action, text, cursor, selectionStart, selectionEnd)
  return r ? text.slice(0, r.start) + text.slice(r.end) : text
}

test("typed: printable text, not chords or control keys", () => {
  assert.equal(Editing.typed("a", 0), "a")
  assert.equal(Editing.typed("A", Shift), "A")
  assert.equal(Editing.typed(" ", 0), " ")
  assert.equal(Editing.typed("é", 0), "é")
  assert.equal(Editing.typed("😀", 0), "😀")
  assert.equal(Editing.typed("v", Ctrl), "")
  assert.equal(Editing.typed("\x16", Ctrl), "")
  assert.equal(Editing.typed("V", Ctrl | Shift), "")
  assert.equal(Editing.typed("t", Alt), "")
  assert.equal(Editing.typed("v", Meta), "")
  for (const key of ["\t", "\r", "\n", "\x1b", "\b", "\x7f", "\x85", ""]) assert.equal(Editing.typed(key, 0), "")
})

test("Backspace and Delete: a selection, else a character (a surrogate pair whole, marks with their letter)", () => {
  assert.equal(edit("back", "abc", 3), "ab")
  assert.equal(edit("back", "abc", 0), "abc")
  assert.equal(edit("back", "abcdef", 4, 1, 4), "aef")
  assert.equal(edit("back", "a😀", 3), "a")
  assert.equal(edit("forward", "abc", 0), "bc")
  assert.equal(edit("forward", "abc", 3), "abc")
  assert.equal(edit("forward", "abcdef", 1, 1, 4), "aef")
  assert.equal(edit("forward", "😀b", 0), "b")
  assert.equal(edit("forward", "éx", 0), "x")
  assert.equal(Editing.range("back", "", 0, 0, 0), null)
})

test("Ctrl+Backspace and Ctrl+Delete: a word, the spaces next to it with it", () => {
  assert.equal(edit("wordBack", "xy foo bar", 10), "xy foo ")
  assert.equal(edit("wordBack", "xy foo ", 7), "xy ")
  assert.equal(edit("wordBack", "foo bar-baz", 11), "foo bar-")
  assert.equal(edit("wordBack", "foo bar-baz", 8), "foo barbaz")
  assert.equal(edit("wordBack", "foo bar-baz", 7), "foo -baz")
  assert.equal(edit("wordBack", "Hüsker Dü", 9), "Hüsker ")
  assert.equal(edit("wordBack", "one two", 0), "one two")
  assert.equal(edit("wordBack", "one two three", 13, 4, 7), "one  three")
  assert.equal(edit("wordForward", "one two three", 0), "two three")
  assert.equal(edit("wordForward", "one   two", 3), "onetwo")
  assert.equal(edit("wordForward", "a-b", 1), "ab")
  assert.equal(edit("wordForward", "one", 3), "one")
})

test("to the end of the line, and all of it, whatever's selected", () => {
  assert.equal(edit("toEnd", "one two", 3), "one")
  assert.equal(edit("toEnd", "one two", 3, 0, 1), "one")
  assert.equal(edit("all", "one two", 3), "")
  assert.equal(Editing.range("all", "", 0, 0, 0), null)
})

test("dead keys: the accented letter, the accent alone before a space, before an unaccented letter", () => {
  assert.ok(Editing.isDeadKey(deadAcute))
  assert.ok(!Editing.isDeadKey(0x41))
  assert.equal(Editing.compose(deadAcute, "e"), "é")
  assert.equal(Editing.compose(deadAcute, "E"), "É")
  assert.equal(Editing.compose(deadGrave, "a"), "à")
  assert.equal(Editing.compose(deadDiaeresis, "u"), "ü")
  assert.equal(Editing.compose(deadCedilla, "c"), "ç")
  assert.equal(Editing.compose(deadAcute, " "), "'")
  assert.equal(Editing.compose(deadDiaeresis, " "), "\"")
  assert.equal(Editing.compose(deadAcute, "q"), "'q")
  assert.equal(Editing.compose(deadAcute, "t"), "'t")
  assert.equal(Editing.compose(0x41, "e"), "e")
  // Shift waits; an arrow doesn't.
  assert.ok(Editing.isModifierKey(0x01000020))
  assert.ok(!Editing.isModifierKey(0x01000012))
})

test("a paste in a one-line field: no line breaks, tabs or NULs", () => {
  assert.equal(Editing.pasteText("pasted text\n"), "pasted text")
  assert.equal(Editing.pasteText("\r\nArtist\r\nTitle\r\n"), "Artist Title")
  assert.equal(Editing.pasteText("a\n\n\nb"), "a b")
  assert.equal(Editing.pasteText("a\tb\x00c\x1bd"), "a bcd")
  assert.equal(Editing.pasteText("Hüsker Dü"), "Hüsker Dü")
  assert.equal(Editing.pasteText("\n\n"), "")
})

test("how a paste went: too big, too slow, nothing, or pasted", () => {
  assert.equal(Editing.pasteLimit, 4096)
  assert.equal(Editing.pasteOutcome(12, 0, true), "paste")
  assert.equal(Editing.pasteOutcome(4096, 0, true), "paste")
  assert.equal(Editing.pasteOutcome(4097, 0, true), "big")
  assert.equal(Editing.pasteOutcome(4097, 124, true), "big")
  assert.equal(Editing.pasteOutcome(10, 124, true), "slow")
  assert.equal(Editing.pasteOutcome(0, 137, true), "slow")
  assert.equal(Editing.pasteOutcome(0, 9, false), "slow")
  assert.equal(Editing.pasteOutcome(0, 0, true), "none")
  assert.equal(Editing.pasteOutcome(0, 1, true), "none")
})

test("difference: the one change from one text to another", () => {
  const apply = (before, after) => {
    const d = Editing.difference(before, after)
    return before.slice(0, d.start) + d.text + before.slice(d.end)
  }
  for (const [before, after] of [["hello world", "hello, world"], ["abc", ""], ["", "abc"], ["aaa", "aa"],
    ["two three", "one two three"], ["same", "same"], ["xyz", "abc"]]) assert.equal(apply(before, after), after)
  assert.deepEqual(Editing.difference("hello world", "hello, world"), { start: 5, end: 5, text: "," })
  assert.deepEqual(Editing.difference("abc", "abc"), { start: 3, end: 3, text: "" })
})
