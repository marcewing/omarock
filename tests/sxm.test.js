const test = require("node:test")
const assert = require("node:assert/strict")
const Sxm = require("../Sxm.js")
const Mpd = require("../Mpd.js")

const base = "http://127.0.0.1:8720"
const channels = [
  { id: "a", number: "2", name: "SiriusXM Hits 1", genre: "Pop", favorite: false, logo: base + "/art/x/{w}x{h}" },
  { id: "b", number: "8", name: "80s on 8", genre: "Rock", favorite: true },
  { id: "c", number: "20", name: "E Street Radio", genre: "Rock", favorite: true },
  { id: "d", number: "36", name: "Alt Nation", genre: "Rock", favorite: false },
]
const now = { a: { artist: "Noah Kahan", title: "Orbiter" }, b: { artist: "REO Speedwagon", title: "Take It On The Run" },
  d: { isAd: true, show: "Alt Nation" } }

test("stream URLs carry the channel id", () => {
  assert.equal(Sxm.channelIdOf(base + "/stream/abc-1", base), "abc-1")
  assert.equal(Sxm.channelIdOf("iTunes Music/x.mp3", base), "")
})

test("channelRows: favorites first, then every channel, with what's on", () => {
  const rows = Sxm.channelRows(channels, now, "b")
  assert.deepEqual(rows.map(r => [r.section, r.title, r.playing]), [
    ["FAVORITES", "80s on 8", true], ["", "E Street Radio", false],
    ["ALL CHANNELS", "SiriusXM Hits 1", false], ["", "80s on 8", true], ["", "E Street Radio", false], ["", "Alt Nation", false]])
  assert.equal(rows[0].subtitle, "REO Speedwagon – Take It On The Run")
  assert.equal(rows[5].subtitle, "Alt Nation")
  assert.equal(rows[2].artwork.url, base + "/art/x/{w}x{h}")
  assert.equal(rows[1].subtitle, "Rock")
})

test("searchRows: a number, then names, then genre and what's playing", () => {
  assert.deepEqual(Sxm.searchRows(channels, now, "8", Mpd.fold).map(r => r.title), ["80s on 8"])
  assert.deepEqual(Sxm.searchRows(channels, now, "rock", Mpd.fold).map(r => [r.section, r.title]),
    [["BY GENRE", "80s on 8"], ["", "E Street Radio"], ["", "Alt Nation"]])
  assert.deepEqual(Sxm.searchRows(channels, now, "kahan", Mpd.fold).map(r => [r.section, r.title]), [["PLAYING NOW", "SiriusXM Hits 1"]])
})

test("stepChannel moves through favorites from a favorite, else by number", () => {
  assert.equal(Sxm.stepChannel(channels, "b", 1).id, "c")
  assert.equal(Sxm.stepChannel(channels, "c", 1).id, "b")
  assert.equal(Sxm.stepChannel(channels, "a", 1).id, "b")
  assert.equal(Sxm.stepChannel(channels, "a", -1).id, "d")
})

test("songAsMpd: the song, with the channel as the album; an ad shows the show", () => {
  assert.deepEqual(Sxm.songAsMpd(channels[1], now.b, "f"),
    { file: "f", album: "80s on 8 · 8", genre: "Rock", title: "Take It On The Run", artist: "REO Speedwagon" })
  assert.deepEqual(Sxm.songAsMpd(channels[3], now.d, "f"),
    { file: "f", album: "Alt Nation · 36", genre: "Rock", title: "Alt Nation", artist: "Ad break" })
})
