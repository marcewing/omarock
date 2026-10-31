const test = require("node:test")
const assert = require("node:assert/strict")
const Heard = require("../Heard.js")

const song = (id, duration) => ({ id, source: "catalog", title: "Song " + id, duration: duration || 200 })
const playing = (id, position, index) => ({ state: "playing", position, song: song(id), queueIndex: index || 0 })
const paused = (id, position, index) => ({ state: "paused", position, song: song(id), queueIndex: index || 0 })

test("no delay: the newest status, its time running", () => {
  const entries = [{ at: 0, status: playing("a", 10) }, { at: 5000, status: playing("b", 0, 1) }]
  const s = Heard.shown(entries, 6000, 0, false, -1)
  assert.equal(s.status.song.id, "b")
  assert.equal(s.elapsed, 1)
  assert.equal(s.waiting, false)
  assert.equal(Heard.shown(entries, 6000, 0, true, 42).elapsed, 42, "a seek's target shows while it's asked for")
})

test("a song that starts by itself shows when its sound arrives", () => {
  const entries = [{ at: 0, status: playing("a", 10) }, { at: 5000, status: playing("b", 0, 1) }]
  let s = Heard.shown(entries, 6000, 2, false, -1)
  assert.equal(s.status.song.id, "a", "the old song is still heard")
  assert.equal(s.elapsed, 14, "its time is the time heard: 10 + (6 - 2)")
  assert.equal(s.waiting, false)
  assert.equal(s.next, 7000, "it changes when the new song's sound arrives")
  s = Heard.shown(entries, 7500, 2, false, -1)
  assert.equal(s.status.song.id, "b")
  assert.equal(s.elapsed, 0.5)
  assert.equal(s.next, 0)
})

test("the time heard stops at the end of the song", () => {
  const entries = [{ at: 0, status: { state: "playing", position: 195, song: song("a", 200), queueIndex: 0 } }]
  assert.equal(Heard.shown(entries, 20000, 2, false, -1).elapsed, 200)
})

test("a change made here shows at once, its time waiting until it's heard", () => {
  const entries = [{ at: 0, status: playing("a", 10) }, { at: 5000, status: playing("c", 0.2, 2), user: true }]
  let s = Heard.shown(entries, 5500, 2.3, false, -1)
  assert.equal(s.status.song.id, "c")
  assert.equal(s.waiting, true)
  assert.equal(s.elapsed, 0.2)
  assert.equal(s.next, 7300)
  s = Heard.shown(entries, 7400, 2.3, false, -1)
  assert.equal(s.status.song.id, "c")
  assert.equal(s.waiting, false)
  assert.ok(Math.abs(s.elapsed - 0.3) < 1e-9, "then the time heard: " + s.elapsed)
})

test("while a change is asked for: the time waits", () => {
  const entries = [{ at: 0, status: playing("a", 10) }]
  const s = Heard.shown(entries, 5000, 2, true, -1)
  assert.equal(s.status.song.id, "a")
  assert.equal(s.waiting, true)
  assert.equal(Heard.shown(entries, 5000, 2, true, 90).elapsed, 90, "a seek waits at its target")
})

test("a later status about the same song shows with the change", () => {
  const later = Object.assign(playing("c", 0.4, 2), { song: Object.assign(song("c"), { albumId: "x" }) })
  const entries = [{ at: 0, status: playing("a", 10) }, { at: 5000, status: playing("c", 0.2, 2), user: true },
    { at: 5200, status: later }]
  const s = Heard.shown(entries, 5500, 2, false, -1)
  assert.equal(s.status.song.albumId, "x")
  assert.equal(s.elapsed, 0.2)
})

test("pause made here: paused at once, the time running on until the sound stops", () => {
  const entries = [{ at: 0, status: playing("a", 10) }, { at: 5000, status: paused("a", 15), user: true }]
  let s = Heard.shown(entries, 5500, 2, false, -1)
  assert.equal(s.status.state, "paused")
  assert.equal(s.waiting, false)
  assert.equal(s.elapsed, 13.5, "heard: 10 + 3.5")
  s = Heard.shown(entries, 6900, 2, false, -1)
  assert.equal(s.elapsed, 14.9)
  s = Heard.shown(entries, 8000, 2, false, -1)
  assert.equal(s.elapsed, 15, "stopped where the Mac paused")
})

test("playing on another machine: the time stands", () => {
  const entries = [{ at: 0, status: Object.assign(playing("a", 10), { elsewhere: "dellxps" }) }]
  assert.equal(Heard.positionAt(entries[0], 5000), 10)
})

test("prune keeps the status heard and those after it", () => {
  const entries = [0, 1000, 2000, 3000, 4000].map(at => ({ at, status: playing("a", at / 1000) }))
  assert.deepEqual(Heard.prune(entries, 4500, 2).map(e => e.at), [2000, 3000, 4000])
  assert.deepEqual(Heard.prune(entries, 4500, 0).map(e => e.at), [4000])
  const many = Array.from({ length: 60 }, (_, i) => ({ at: 10000 + i, status: playing("a", 0) }))
  assert.equal(Heard.prune(many, 0, 2).length, 40)
})

test("overlay: the queue and options now, the song as heard", () => {
  const live = Object.assign(playing("b", 1, 1), { queue: ["a", "b"], shuffle: true, volume: 30 })
  const o = Heard.overlay(live, playing("a", 50, 0))
  assert.equal(o.song.id, "a")
  assert.equal(o.queueIndex, 0)
  assert.equal(o.position, 50)
  assert.deepEqual(o.queue, ["a", "b"])
  assert.equal(o.shuffle, true)
  assert.equal(o.volume, 30)
})
