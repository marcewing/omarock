const test = require("node:test")
const assert = require("node:assert/strict")
const Radio = require("../Radio.js")

const wjrr = { stationuuid: "u1", name: "101.1 WJRR Orlando's Rock Station ", url_resolved: "https://stream.revma.ihrhls.com/zc593",
  favicon: "https://i.iheart.com/x.png", tags: "alternative,rock,orlando", state: "Florida", codec: "AAC", bitrate: 0, hls: 0 }
const kexp = { stationuuid: "u2", name: "KEXP 90.3", url_resolved: "http://live-aacplus-64.kexp.org/kexp64.aac", favicon: "",
  tags: "indie", state: "Washington", codec: "AAC+", bitrate: 64, hls: 0 }
const hlsOnly = { stationuuid: "u3", name: "iHeart Café", url_resolved: "http://x/hls.m3u8", tags: "", state: "", codec: "AAC", hls: 1 }

test("a queued station carries its uuid after #, which the server never sees", () => {
  const url = Radio.streamUrl(wjrr)
  assert.equal(url, "https://stream.revma.ihrhls.com/zc593#omarock-radio=u1")
  assert.equal(Radio.uuidOf(url), "u1")
  assert.equal(Radio.isRadio("iTunes Music/x.mp3"), false)
})

test("listRows: favorites, then local stations not already favorites", () => {
  const rows = Radio.listRows([kexp], [wjrr, kexp, hlsOnly], "u2", "Florida")
  assert.deepEqual(rows.map(r => [r.section, r.title, r.favorite, r.playing, r.missing === true]), [
    ["FAVORITES", "KEXP 90.3", true, true, false],
    ["LOCAL · FLORIDA", "101.1 WJRR Orlando's Rock Station", false, false, false],
    ["", "iHeart Café", false, false, true]])
  assert.equal(rows[1].subtitle, "Florida · alternative, rock · AAC")
  assert.equal(rows[0].subtitle, "Washington · indie · AAC+ 64k")
  assert.equal(rows[2].subtitle, "Can't play: HLS only")
  assert.equal(rows[1].artwork.url, "https://i.iheart.com/x.png")
  assert.equal(rows[0].artwork, undefined)
})

test("listRows puts a station found by search at the top, so A can keep it", () => {
  const rows = Radio.listRows([kexp], [kexp], "u1", "Washington", wjrr)
  assert.deepEqual(rows.map(r => [r.section, r.title, r.playing]), [
    ["NOW PLAYING", "101.1 WJRR Orlando's Rock Station", true], ["FAVORITES", "KEXP 90.3", false]])
  assert.equal(Radio.listRows([kexp], [], "u2", "", kexp).filter(r => r.kind === "station").length, 1)
})

test("parseTitle reads iHeart's tagged titles and plain Artist - Title", () => {
  assert.deepEqual(Radio.parseTitle('Days Of The New - text="Touch, Peel & Stand" song_spot="M" amgArtworkURL="http://assets.iheart.com/a.jpg" length="00:04:55"'),
    { artist: "Days Of The New", title: "Touch, Peel & Stand", art: "http://assets.iheart.com/a.jpg" })
  assert.deepEqual(Radio.parseTitle('Ad - text="Spot Block" amgArtworkURL="null"'), { artist: "Ad", title: "Spot Block", art: "" })
  assert.deepEqual(Radio.parseTitle("Wilco - Jesus, Etc."), { artist: "Wilco", title: "Jesus, Etc.", art: "" })
  assert.deepEqual(Radio.parseTitle("KEXP"), { artist: "", title: "KEXP", art: "" })
})

test("parseTitle reads a station's form: the title first, a show's name in front", () => {
  const wrct = "The World's Your Oyster: Criminal - Fiona Apple"
  assert.deepEqual(Radio.parseTitle(wrct), { artist: "The World's Your Oyster: Criminal", title: "Fiona Apple", art: "" })
  assert.deepEqual(Radio.parseTitle(wrct, { titleFirst: true, show: true }), { artist: "Fiona Apple", title: "Criminal", art: "" })
  assert.deepEqual(Radio.parseTitle(wrct, { titleFirst: true }), { artist: "Fiona Apple", title: "The World's Your Oyster: Criminal", art: "" })
  // Title first splits at the last dash, artist first at the first.
  assert.deepEqual(Radio.parseTitle("Song - Live - Band", { titleFirst: true }), { artist: "Band", title: "Song - Live", art: "" })
  assert.deepEqual(Radio.parseTitle("Band - Song - Live"), { artist: "Band", title: "Song - Live", art: "" })
  // A show's name in front of the artist; a colon in the title stays.
  assert.deepEqual(Radio.parseTitle("Morning Jazz: Miles Davis - So What", { show: true }), { artist: "Miles Davis", title: "So What", art: "" })
  assert.deepEqual(Radio.parseTitle("Wilco - Jesus, Etc.: Live", { show: true }), { artist: "Wilco", title: "Jesus, Etc.: Live", art: "" })
  // No show's name to take off: as it is.
  assert.deepEqual(Radio.parseTitle("Criminal - Fiona Apple", { titleFirst: true, show: true }), { artist: "Fiona Apple", title: "Criminal", art: "" })
  // iHeart's tagged titles never change.
  assert.deepEqual(Radio.parseTitle('Days Of The New - text="Touch"', { titleFirst: true, show: true }), { artist: "Days Of The New", title: "Touch", art: "" })
})

test("titleForm: the title first only on more votes for it; a show's name on any", () => {
  assert.deepEqual(Radio.titleForm(undefined), { titleFirst: false, show: false })
  assert.deepEqual(Radio.titleForm({ artist: 1, title: 1 }), { titleFirst: false, show: false })
  assert.deepEqual(Radio.titleForm({ artist: 1, title: 2, show: 1 }), { titleFirst: true, show: true })
})

test("titleQuestions and titleVotes: learned from the artists and songs you have", () => {
  const q = Radio.titleQuestions("The World's Your Oyster: Criminal - Fiona Apple")
  assert.deepEqual(q, { artistFirst: "The World's Your Oyster: Criminal", bareArtist: "Criminal", titleFirst: "Fiona Apple",
    bareTitle: "Criminal", show: "The World's Your Oyster" })
  assert.equal(Radio.titleQuestions("KEXP"), null)
  assert.equal(Radio.titleQuestions('Days Of The New - text="Touch"'), null)
  // Fiona Apple is yours, with Criminal: the title first, after a show's name.
  assert.deepEqual(Radio.titleVotes(q, { titleFirst: true, bareTitle: true }, ""), { artist: 0, title: 1, show: 1 })
  // Only the artist: the title first; the same show's name before: a show.
  assert.deepEqual(Radio.titleVotes(q, { titleFirst: true }, ""), { artist: 0, title: 1, show: 0 })
  assert.deepEqual(Radio.titleVotes(q, {}, "The World's Your Oyster: Dumb - Nirvana"), { artist: 0, title: 0, show: 1 })
  assert.deepEqual(Radio.titleVotes(q, {}, "All Things Folk: Say goodbye - Thanh Force"), { artist: 0, title: 0, show: 0 })
  // Artist first; an artist after a show's name.
  const wilco = Radio.titleQuestions("Wilco - Jesus, Etc.")
  assert.deepEqual(Radio.titleVotes(wilco, { artistFirst: true }, ""), { artist: 1, title: 0, show: 0 })
  const jazz = Radio.titleQuestions("Morning Jazz: Miles Davis - So What")
  assert.deepEqual(Radio.titleVotes(jazz, { bareArtist: true }, ""), { artist: 1, title: 0, show: 1 })
  // Both, or neither, an artist you have: no vote on the order.
  assert.deepEqual(Radio.titleVotes(wilco, { artistFirst: true, titleFirst: true }, ""), { artist: 0, title: 0, show: 0 })
  assert.deepEqual(Radio.titleVotes(wilco, {}, ""), { artist: 0, title: 0, show: 0 })
})

test("songAsMpd: the song when sent, else the station; the station as the album", () => {
  assert.deepEqual(Radio.songAsMpd({ file: "f", title: "Wilco - Jesus, Etc.", name: "KEXP" }, kexp),
    { file: "f", title: "Jesus, Etc.", artist: "Wilco", album: "KEXP 90.3", genre: "indie" })
  assert.deepEqual(Radio.songAsMpd({ file: "f", name: "Some Stream" }, null),
    { file: "f", title: "Some Stream", artist: "", album: "", genre: "" })
})

test("stepStation goes around the playable favorites", () => {
  assert.equal(Radio.stepStation([kexp, hlsOnly, wjrr], "u2", 1).stationuuid, "u1")
  assert.equal(Radio.stepStation([kexp, wjrr], "u1", 1).stationuuid, "u2")
  assert.equal(Radio.stepStation([kexp, wjrr], "nope", -1).stationuuid, "u2")
  assert.equal(Radio.stepStation([], "u1", 1), null)
})

test("listRows without an area ends with how to set one", () => {
  const rows = Radio.listRows([kexp], [], "u2", "")
  assert.deepEqual(rows.map(r => r.kind), ["station", "note"])
  assert.equal(rows[1].section, "LOCAL")
  assert.match(rows[1].subtitle, /settings.*Your area/)
  // With an area, no note.
  assert.ok(Radio.listRows([kexp], [wjrr], "u2", "Florida").every(r => r.kind === "station"))
})
