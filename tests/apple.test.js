const test = require("node:test")
const assert = require("node:assert/strict")
const Apple = require("../Apple.js")
const Mpd = require("../Mpd.js")

const art = { url: "https://is1-ssl.mzstatic.com/image/thumb/x/{w}x{h}bb.jpg", width: 3000, height: 3000 }

function song(id, title, extra) {
  return Object.assign({ kind: "song", id, source: "catalog", title, artist: "Hüsker Dü", album: "Zen Arcade",
    duration: 125, artwork: art }, extra || {})
}

test("artUrl fills Apple's template at twice the size, within the original", () => {
  assert.equal(Apple.artUrl(art, 36), "https://is1-ssl.mzstatic.com/image/thumb/x/72x72bb.jpg")
  assert.equal(Apple.artUrl({ url: "a/{w}x{h}{c}.{f}", width: 100 }, 360), "a/100x100bb.jpg")
  assert.equal(Apple.artUrl(null, 36), "")
})

test("searchRows lists the library first, then Apple Music, once each", () => {
  const rows = Apple.searchRows({
    library: { albums: [{ kind: "album", id: "l.1", source: "library", catalogId: "100", title: "Zen Arcade",
      artist: "Hüsker Dü", year: 1984 }], playlists: [{ kind: "playlist", id: "p.1", source: "library", name: "PunkRock", trackCount: 2 }] },
    catalog: { albums: [{ kind: "album", id: "100", source: "catalog", title: "Zen Arcade", artist: "Hüsker Dü" },
      { kind: "album", id: "101", source: "catalog", title: "New Day Rising", artist: "Hüsker Dü", year: 1985 }],
      songs: [song("200", "Diane", { explicit: true })] }
  }, [{ id: "20", name: "Punk" }])
  assert.deepEqual(rows.map(r => r.kind + ":" + r.title), ["playlist:PunkRock", "album:Zen Arcade", "genre:Punk",
    "album:New Day Rising", "song:Diane 󰬌"])
  assert.deepEqual(rows.map(r => r.section), ["YOUR PLAYLISTS", "YOUR ALBUMS", "GENRES", "APPLE MUSIC · ALBUMS",
    "APPLE MUSIC · SONGS"])
  assert.equal(rows[1].subtitle, "Hüsker Dü · 1984")
  assert.deepEqual(rows[4].apple, { kind: "song", id: "200", source: "catalog" })
  assert.equal(rows[4].file, "apple:200")
  assert.equal(rows[2].noQueue, true)
})

test("matchGenres folds case and accents", () => {
  const genres = [{ id: "1", name: "Pop" }, { id: "2", name: "Alternative" }, { id: "3", name: "Música Mexicana" }]
  assert.deepEqual(Apple.matchGenres(genres, "musica", Mpd.fold).map(g => g.id), ["3"])
  assert.deepEqual(Apple.matchGenres(genres, "  ", Mpd.fold), [])
})

test("albumView: Play the album, then songs by disc", () => {
  const view = Apple.albumView({ kind: "album", id: "1", source: "catalog", title: "Live", artist: "The Band", year: 1985,
    genres: ["Rock"], recordLabel: "SST", audioTraits: ["lossless"], artwork: art },
    [song("a", "One", { discNumber: 1, trackNumber: 1, artist: "The Band" }),
     song("b", "Two", { discNumber: 2, trackNumber: 1, artist: "The Band" })])
  assert.deepEqual(view.rows.map(r => r.kind + ":" + r.title + ":" + (r.section || "")),
    ["playalbum:Play the album:", "track:One:DISC 1", "track:Two:DISC 2"])
  assert.equal(view.rows[0].subtitle, "2 songs · 4 min")
  assert.equal(view.info.subtitle, "The Band · 1985 · Rock")
  assert.equal(view.info.detail, "SST · Lossless")
  assert.equal(view.rows[2].position, 1)
})

test("artistView: top songs, albums by year, singles, appears on", () => {
  const album = (id, title, year, extra) => Object.assign({ kind: "album", id, source: "catalog", title, artist: "X", year }, extra || {})
  const view = Apple.artistView({ kind: "artist", id: "9", source: "catalog", name: "X", genres: ["Punk"] }, {
    topSongs: [song("s1", "Hit")],
    albums: [album("2", "Later", 1990), album("1", "First", 1984), album("3", "A Single", 1985, { isSingle: true })],
    appearsOn: [album("4", "Comp", 1988, { artist: "Various Artists" })]
  })
  assert.deepEqual(view.rows.map(r => r.kind + ":" + r.title), ["playall:Play top songs", "song:Hit", "album:First",
    "album:Later", "album:A Single", "album:Comp"])
  assert.deepEqual(view.rows.map(r => r.section || ""), ["", "TOP SONGS", "ALBUMS", "", "SINGLES & EPS", "APPEARS ON"])
  assert.equal(view.rows[2].subtitle, "1984")
  assert.equal(view.rows[5].subtitle, "Various Artists · 1988")
  assert.equal(view.info.subtitle, "Artist · Punk")
})

test("queueRows marks the playing entry by its index in the whole queue", () => {
  const rows = Apple.queueRows({ state: "playing", queueOffset: 10, queueIndex: 11,
    queue: [song("a", "One"), song("b", "Two")] })
  assert.deepEqual(rows.map(r => [r.index, r.lead, r.playing]), [[10, "11", false], [11, "12", true]])
})

test("statusAsMpd and songAsMpd give the player card mpd's shapes", () => {
  const status = { state: "paused", position: 12.5, song: song("a", "One", { year: 1984, genres: ["Punk"] }),
    queueIndex: 3, queueLength: 9, shuffle: true, repeat: "off" }
  assert.deepEqual(Apple.statusAsMpd(status, 70), { state: "pause", volume: 70, elapsed: 12.5, duration: 125,
    song: 3, songId: "apple:a", random: true, repeat: false, single: false, consume: false, queueLength: 9,
    updating: false, error: "" })
  assert.deepEqual(Apple.songAsMpd(status.song), { file: "apple:a", title: "One", artist: "Hüsker Dü",
    album: "Zen Arcade", date: "1984", genre: "Punk" })
  assert.equal(Apple.statusAsMpd({ state: "stopped" }, -1).song, -1)
})

test("badges name explicit, lossless and Atmos", () => {
  assert.equal(Apple.badges(song("a", "x", { explicit: true, audioTraits: ["lossless", "atmos"] })),
    "Explicit · Lossless · Dolby Atmos")
  assert.equal(Apple.badges(song("a", "x")), "")
})

test("untitled albums and playlists get names; a catalog error leaves a note", () => {
  assert.equal(Apple.albumRow({ kind: "album", id: "1", source: "library", title: "", artist: "X" }).title, "Untitled album")
  assert.equal(Apple.playlistRow({ kind: "playlist", id: "2", source: "library", name: " " }).title, "Untitled playlist")
  const rows = Apple.searchRows({ library: { albums: [{ kind: "album", id: "3", source: "library", title: "Zen Arcade" }] },
    catalogError: "Apple Music request failed: Failed to request developer token" }, [])
  assert.deepEqual(rows.map(r => r.kind), ["album", "note"])
  assert.equal(rows[1].section, "APPLE MUSIC")
  assert.match(rows[1].subtitle, /developer token/)
})

test("songs the bridge can't play are dimmed and say so", () => {
  const view = Apple.playlistView({ kind: "playlist", id: "p", source: "library", name: "Bosch" },
    [song("a", "Take Five", { playable: false }), song("b", "C Jam Blues")])
  assert.deepEqual(view.rows.map(r => [r.title, r.missing === true, r.subtitle]),
    [["Play the playlist", false, "2 songs · 4 min"], ["Take Five", true, "Not available to play"],
     ["C Jam Blues", false, "Hüsker Dü · Zen Arcade"]])
  assert.equal(view.rows[1].position, 0)
})

test("an album or song you own is listed once, as yours, even without a catalog id", () => {
  const rows = Apple.searchRows({
    library: { albums: [{ kind: "album", id: "-5300", source: "library", title: "New Day Rising", artist: "Hüsker Dü" }],
      songs: [song("-1", "Celebrated Summer", { source: "library", album: "New Day Rising" })],
      artists: [{ kind: "artist", id: "-9", source: "library", name: "Hüsker Dü" }] },
    catalog: { albums: [{ kind: "album", id: "282", source: "catalog", title: "New Day Rising", artist: "Husker Du" },
      { kind: "album", id: "283", source: "catalog", title: "Warehouse: Songs and Stories", artist: "Hüsker Dü" }],
      songs: [song("901", "Celebrated  summer"), song("902", "Diane")],
      artists: [{ kind: "artist", id: "282971840", source: "catalog", name: "Hüsker Dü", genres: ["Rock"] }] }
  }, [])
  assert.deepEqual(rows.map(r => r.kind + ":" + r.title + ":" + r.apple.source),
    ["artist:Hüsker Dü:library", "album:New Day Rising:library", "song:Celebrated Summer:library",
     "artist:Hüsker Dü:catalog", "album:Warehouse: Songs and Stories:catalog", "song:Diane:catalog"])
})

test("Spotify's service names itself in sections, views and notes", () => {
  const rows = Apple.searchRows({
    catalog: { artists: [{ kind: "artist", id: "1Mxq", source: "catalog", name: "Frank Sinatra" }] },
    catalogError: "Spotify said 429"
  }, [], "Spotify")
  assert.deepEqual(rows.map(r => r.section), ["SPOTIFY · ARTISTS", "SPOTIFY"])
  assert.equal(rows[1].title, "The Spotify catalog isn't available")
  assert.equal(Apple.albumView({ kind: "album", id: "a", source: "catalog", title: "X" }, [], "Spotify").info.emptyText,
    "Spotify lists no songs for this album.")
  assert.equal(Apple.artistView({ kind: "artist", id: "a", source: "catalog", name: "X" }, {}, "Spotify").info.emptyText,
    "Spotify lists nothing for this artist.")
  const view = Apple.playlistsView([], 0, "Spotify")
  assert.equal(view.info.title, "Spotify playlists")
  assert.equal(view.rows[1].title, "No Spotify playlists yet")
  // Left out, the service is Apple Music, as before.
  assert.equal(Apple.playlistsView([], 0).info.title, "Apple Music playlists")
})

test("a playlist whose songs aren't listed still plays, with the reason", () => {
  const view = Apple.playlistView({ kind: "playlist", id: "37i9", source: "catalog", name: "Rock Classics", trackCount: 150 },
    [], "Spotify lists the songs of your own playlists only. It can still play this one.")
  assert.deepEqual(view.rows.map(r => r.kind + ":" + r.title), ["playplaylist:Play the playlist", "note:Its songs aren't listed"])
  assert.equal(view.rows[0].subtitle, "150 songs")
  assert.match(view.rows[1].subtitle, /your own playlists only/)
  // Without a note, an empty playlist is just empty.
  assert.deepEqual(Apple.playlistView({ kind: "playlist", id: "p", source: "library", name: "New" }, []).rows, [])
})
