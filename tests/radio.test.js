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

test("listRows: favourites, then local stations not already favourites", () => {
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

test("songAsMpd: the song when sent, else the station; the station as the album", () => {
  assert.deepEqual(Radio.songAsMpd({ file: "f", title: "Wilco - Jesus, Etc.", name: "KEXP" }, kexp),
    { file: "f", title: "Jesus, Etc.", artist: "Wilco", album: "KEXP 90.3", genre: "indie" })
  assert.deepEqual(Radio.songAsMpd({ file: "f", name: "Some Stream" }, null),
    { file: "f", title: "Some Stream", artist: "", album: "", genre: "" })
})

test("stepStation goes round the playable favourites", () => {
  assert.equal(Radio.stepStation([kexp, hlsOnly, wjrr], "u2", 1).stationuuid, "u1")
  assert.equal(Radio.stepStation([kexp, wjrr], "u1", 1).stationuuid, "u2")
  assert.equal(Radio.stepStation([kexp, wjrr], "nope", -1).stationuuid, "u2")
  assert.equal(Radio.stepStation([], "u1", 1), null)
})

test("listRows without a state ends with how to set one", () => {
  const rows = Radio.listRows([kexp], [], "u2", "")
  assert.deepEqual(rows.map(r => r.kind), ["station", "note"])
  assert.equal(rows[1].section, "LOCAL")
  assert.match(rows[1].subtitle, /settings.*Your US state/)
  // With a state, no note.
  assert.ok(Radio.listRows([kexp], [wjrr], "u2", "Florida").every(r => r.kind === "station"))
})
