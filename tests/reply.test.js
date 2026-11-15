const test = require("node:test")
const assert = require("node:assert/strict")
const Reply = require("../Reply.js")

test("an answer like the bridge's parses as JSON.parse has it", () => {
  const answer = JSON.stringify({
    seq: 7, state: "playing", queue: [{ id: "1", title: "Hüsker \"Dü\", [live]", artist: "a\\b" }, { id: "2", title: "{x}," }],
    library: { genres: [], albums: [{}] }, note: "commas, [brackets] and {braces} in a string don't count"
  })
  assert.deepEqual(Reply.parse(answer, 1 << 20), { data: JSON.parse(answer), error: "" })
  assert.deepEqual(Reply.parse("[]", 10).data, [])
  assert.equal(Reply.parse("0", 10).data, 0)
  assert.equal(Reply.parse('"a,b"', 10).data, "a,b")
})

test("one array or object of too many members is refused: Qt's JSON.parse crashes the shell on one", () => {
  // 1.2 MB of [0,0,…]: 600,000 members, past the ~540,000 that crash Qt 6.12.
  const dense = "[" + "0,".repeat(599999) + "0]"
  assert.equal(Reply.check(dense, 4 << 20), "members")
  assert.deepEqual(Reply.parse(dense, 4 << 20), { data: null, error: "members" })
  assert.ok(Reply.refused("members"))
  const keys = "{" + Array.from({ length: Reply.MEMBERS + 1 }, (_, i) => '"k' + i + '":0').join(",") + "}"
  assert.equal(Reply.check(keys, 0), "members")
  const nested = JSON.stringify({ a: [{ b: Array(Reply.MEMBERS + 1).fill(1) }] })
  assert.equal(Reply.check(nested, 0), "members", "counted in the container they're in, however deep")
  assert.equal(Reply.check("[" + Array(Reply.MEMBERS).fill("{}").join(",") + "]", 0), "", "MEMBERS itself is fine")
  // Many containers, each small: 200,000 arrays of ten, as Qt parses them.
  const many = "[" + Array(20).fill("[" + Array(10000).fill("[0,1,2,3,4,5,6,7,8,9]").join(",") + "]").join(",") + "]"
  assert.equal(Reply.check(many, 0), "")
})

test("commas and brackets inside strings, escaped quotes and backslashes included, aren't counted", () => {
  const text = JSON.stringify(["a,".repeat(Reply.MEMBERS + 5), "\\\",[,{", "\\", 'x\\"y,z'])
  assert.equal(Reply.check(text, 0), "")
  assert.deepEqual(Reply.parse(text, 0).data.slice(1), JSON.parse(text).slice(1))
  assert.equal(Reply.check('["a\\\\",' + '0,'.repeat(3) + '0]', 0), "", "an escaped backslash ends before the quote")
  assert.equal(Reply.check('["a\\"]', 0), "syntax", "an escaped quote doesn't end the string")
})

test("a string longer than STRING_MAX is cut there, wherever it is; the rest as it was", () => {
  const long = "x".repeat(Reply.STRING_MAX + 5000)
  const answer = { songs: [{ title: long, artist: "Hüsker Dü" }], note: long, n: 3 }
  const got = Reply.parse(JSON.stringify(answer), 0)
  assert.equal(got.error, "")
  assert.equal(got.data.songs[0].title, "x".repeat(Reply.STRING_MAX))
  assert.equal(got.data.note.length, Reply.STRING_MAX)
  assert.equal(got.data.songs[0].artist, "Hüsker Dü")
  assert.equal(got.data.n, 3)
  assert.equal(Reply.parse(JSON.stringify(long), 0).data.length, Reply.STRING_MAX)
})

test("text over the cap, too deep, or broken", () => {
  assert.equal(Reply.check("[1,2,3]", 6), "big")
  assert.equal(Reply.check("[1,2,3]", 7), "")
  assert.equal(Reply.parse("[1,2,3]", 6).error, "big")
  assert.equal(Reply.check("[".repeat(1000000), 0), "deep")
  assert.equal(Reply.check("[".repeat(Reply.DEPTH) + "]".repeat(Reply.DEPTH), 0), "")
  assert.equal(Reply.check("[".repeat(Reply.DEPTH + 1), 0), "deep")
  assert.equal(Reply.check("]", 0), "syntax")
  assert.equal(Reply.check('{"a', 0), "syntax")
  assert.deepEqual(Reply.parse("", 10), { data: null, error: "empty" })
  assert.deepEqual(Reply.parse(null, 10), { data: null, error: "empty" })
  assert.deepEqual(Reply.parse("<html>", 10), { data: null, error: "syntax" })
  assert.ok(!Reply.refused("syntax") && !Reply.refused("empty") && Reply.refused("big") && Reply.refused("deep"))
})

test("one pass, linear: 16 MB of strings full of backslashes and quotes, or of commas, in well under a second", () => {
  const backslashes = JSON.stringify(Array(4000).fill('\\"'.repeat(1000)))
  const commas = "[" + Array(80000).fill('"' + ",".repeat(200) + '"').join(",") + "]"
  for (const text of [backslashes, commas]) {
    const start = process.hrtime.bigint()
    assert.equal(Reply.check(text, 0), "")
    assert.ok(Number(process.hrtime.bigint() - start) / 1e6 < 1000, text.length + " characters")
  }
})
