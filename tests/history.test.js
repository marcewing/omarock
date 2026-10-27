const test = require("node:test")
const assert = require("node:assert/strict")
const History = require("../History.js")

const DAY = 24 * 3600 * 1000

test("a local song, a station's song, and a service's", () => {
  assert.deepEqual(History.entryFor("local", { title: "Sinews", artist: "Drive Like Jehu", album: "Yank Crime",
    file: "Drive Like Jehu/Yank Crime/04 Sinews.mp3", duration: 552.4 }),
    { source: "local", title: "Sinews", artist: "Drive Like Jehu", album: "Yank Crime",
      file: "Drive Like Jehu/Yank Crime/04 Sinews.mp3", duration: 552 })
  assert.deepEqual(History.entryFor("radio", { title: "Gimme Shelter", artist: "The Rolling Stones", station: "WBLM 102.9" }),
    { source: "radio", title: "Gimme Shelter", artist: "The Rolling Stones", station: "WBLM 102.9" })
  assert.deepEqual(History.entryFor("spotify", { title: "Luau", artist: "Drive Like Jehu", album: "Yank Crime", duration: 300,
    ref: { kind: "song", id: "6abc", source: "catalog" } }).ref, { kind: "song", id: "6abc", source: "catalog" })
})

test("not songs: a station saying its own name, an ad, nothing playing", () => {
  assert.equal(History.entryFor("radio", { title: "WBLM 102.9", artist: "", station: "WBLM 102.9" }), null)
  assert.equal(History.entryFor("radio", { title: "The Blimp", artist: "WBLM 102.9", station: "WBLM 102.9" }), null)
  assert.equal(History.entryFor("sxm", { title: "Spot", artist: "Ad break", station: "Hits 1", isAd: true }), null)
  assert.equal(History.entryFor("local", { title: "", artist: "x", file: "a.mp3" }), null)
  assert.equal(History.entryFor("apple", { title: "Song", artist: "x" }), null, "no id to play it by")
})

test("one play from the next: the file, the id, or the station's song", () => {
  const a = History.entryFor("radio", { title: "One", artist: "U2", station: "WCYY" })
  const b = History.entryFor("radio", { title: "Two", artist: "U2", station: "WCYY" })
  assert.notEqual(History.keyOf(a), History.keyOf(b))
  assert.equal(History.keyOf(History.entryFor("local", { title: "x", file: "f.mp3" })), "local|f.mp3")
})

test("a play counts at half the song or 4 minutes; a station's after 30 s", () => {
  assert.equal(History.counts(99, 200, false), false)
  assert.equal(History.counts(100, 200, false), true)
  assert.equal(History.counts(239, 600, false), false)
  assert.equal(History.counts(240, 600, false), true)
  assert.equal(History.counts(20, 25, false), false, "a song under 30 s never counts")
  assert.equal(History.counts(29, 0, true), false)
  assert.equal(History.counts(30, 0, true), true)
  assert.equal(History.counts(2, 600, false, 2), true, "a test's setting")
})

test("the file: a line a play; older than the days kept go; a bad line is skipped", () => {
  const now = Date.UTC(2026, 9, 27, 15)
  const old = { at: now - 8 * DAY, source: "local", title: "Old", file: "o.mp3" }
  const recent = { at: now - DAY, source: "radio", title: "New", artist: "A", station: "S" }
  const entries = History.parse([History.line(recent), "not json", History.line(old), "{}"].join("\n"))
  assert.deepEqual(entries.map(e => e.title), ["Old", "New"], "oldest first")
  assert.deepEqual(History.prune(entries, now, 7).map(e => e.title), ["New"])
  assert.equal(History.prune(entries, now, 30).length, 2)
})

test("rows: newest first, a heading on each day, the source's icon", () => {
  const now = new Date(2026, 9, 27, 15, 0).getTime()
  const entries = [
    { at: new Date(2026, 9, 20, 9, 0).getTime(), source: "local", title: "Luau", artist: "Drive Like Jehu", album: "Yank Crime", file: "l.mp3" },
    { at: new Date(2026, 9, 26, 21, 0).getTime(), source: "sxm", title: "Gimme Shelter", artist: "The Rolling Stones", station: "Classic Vinyl · 26" },
    { at: new Date(2026, 9, 27, 14, 0).getTime(), source: "spotify", title: "Sinews", artist: "Drive Like Jehu", album: "Yank Crime",
      ref: { kind: "song", id: "s1", source: "catalog" } },
    { at: new Date(2026, 9, 27, 14, 9).getTime(), source: "radio", title: "One", artist: "U2", station: "WCYY" }
  ]
  const rows = History.rows(entries, now, at => new Date(at).getHours() + ":" + String(new Date(at).getMinutes()).padStart(2, "0"))
  assert.deepEqual(rows.map(r => r.section), ["TODAY", "", "YESTERDAY", "TUE 20 OCT"])
  assert.deepEqual(rows.map(r => r.title), ["One", "Sinews", "Gimme Shelter", "Luau"])
  assert.equal(rows[0].lead, History.ICONS.radio)
  assert.equal(rows[0].subtitle, "U2 · WCYY · Radio")
  assert.equal(rows[1].subtitle, "Drive Like Jehu · Yank Crime · Spotify")
  assert.equal(rows[0].detail, "14:09")
  assert.equal(rows[3].file, "l.mp3")
  assert.equal(History.dayLabel(new Date(2026, 9, 23, 10).getTime(), now), "FRIDAY")
})

test("the heading line, and what an empty list says", () => {
  assert.equal(History.info([{}, {}], 7, true).subtitle, "2 songs · the last 7 days")
  assert.equal(History.info([], 1, true).subtitle, "the last day")
  assert.match(History.info([], 7, false).emptyText, /History is off/)
})
