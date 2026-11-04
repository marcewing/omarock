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
      artist: "Hüsker Dü", year: 1984, trackCount: 1 }], playlists: [{ kind: "playlist", id: "p.1", source: "library", name: "PunkRock", trackCount: 2 }] },
    catalog: { albums: [{ kind: "album", id: "100", source: "catalog", title: "Zen Arcade", artist: "Hüsker Dü" },
      { kind: "album", id: "101", source: "catalog", title: "New Day Rising", artist: "Hüsker Dü", year: 1985 }],
      songs: [song("200", "Diane", { explicit: true })] }
  }, [{ id: "20", name: "Punk" }])
  assert.deepEqual(rows.map(r => r.kind + ":" + r.title), ["playlist:PunkRock", "album:Zen Arcade", "genre:Punk",
    "album:New Day Rising", "song:Diane 󰬌"])
  assert.deepEqual(rows.map(r => r.section), ["YOUR PLAYLISTS", "YOUR ALBUMS", "GENRES", "APPLE MUSIC · ALBUMS",
    "APPLE MUSIC · SONGS"])
  // The songs you have of it, so a one-song album shows before it's opened.
  assert.equal(rows[1].subtitle, "Hüsker Dü · 1984 · 1 song")
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

test("searchRows lists an artist you have once, as yours", () => {
  const rows = Apple.searchRows({
    library: { artists: [{ kind: "artist", id: "l.9", source: "library", name: "Future Leaders Of The World" }] },
    catalog: { artists: [{ kind: "artist", id: "9", source: "catalog", name: "Future Leaders of the World" },
      { kind: "artist", id: "8", source: "catalog", name: "Tyler, The Creator" }] }
  })
  assert.deepEqual(rows.map(r => r.section + ":" + r.apple.id), ["YOUR ARTISTS:l.9", "APPLE MUSIC · ARTISTS:8"])
})

test("findArtist matches a name on the other side, case and accents aside", () => {
  const results = { library: { artists: [{ id: "l.1", name: "Husker Du" }] },
    catalog: { artists: [{ id: "2", name: "Hüsker Dü Tribute" }, { id: "1", name: "Hüsker Dü" }] } }
  assert.equal(Apple.findArtist(results, "catalog", "hüsker dü").id, "1")
  assert.equal(Apple.findArtist(results, "library", "Hüsker Dü").id, "l.1")
  assert.equal(Apple.findArtist(results, "catalog", "Bob Mould"), null)
  assert.equal(Apple.findArtist(null, "catalog", "Hüsker Dü"), null)
  assert.equal(Apple.findArtist(results, "catalog", ""), null)
})

test("mergedArtistView: your albums, then the catalog's others, singles and appears on", () => {
  const album = (id, source, title, year, extra) => Object.assign({ kind: "album", id, source, title, artist: "F", year }, extra || {})
  const mine = { artist: { kind: "artist", id: "l.9", source: "library", name: "F" },
    data: { topSongs: [song("l.s1", "Mine")], albums: [album("l.2", "library", "Lvl IV", 2004),
      album("l.3", "library", "B-Sides", 2009), album("l.4", "library", "Dark Paradise", 2023, { catalogId: "7" })] } }
  const theirs = { artist: { kind: "artist", id: "9", source: "catalog", name: "F", genres: ["Rock"], artwork: art },
    data: { topSongs: [song("s1", "Hit")], albums: [album("5", "catalog", "LVL IV", 2004),
      album("6", "catalog", "Let Me Out - Single", 2004, { isSingle: true }), album("7", "catalog", "Dark Paradise (Live)", 2023),
      album("8", "catalog", "Second", 2006), album("9", "catalog", "Unplugged - EP", 2023)],
      appearsOn: [album("10", "catalog", "Comp", 2001, { artist: "Various Artists" })] } }
  const view = Apple.mergedArtistView(mine, theirs)
  // LVL IV is yours by title, Dark Paradise (Live) by catalog id.
  assert.deepEqual(view.rows.map(r => (r.section || "") + "|" + r.kind + ":" + r.title + ":" + (r.apple ? r.apple.source : "")),
    ["|playall:Play top songs:", "TOP SONGS|song:Hit:catalog",
     "YOUR ALBUMS|album:Lvl IV:library", "|album:B-Sides:library", "|album:Dark Paradise:library",
     "APPLE MUSIC ALBUMS|album:Second:catalog", "SINGLES & EPS|album:Let Me Out - Single:catalog",
     "|album:Unplugged - EP:catalog", "APPEARS ON|album:Comp:catalog"])
  assert.equal(view.info.title, "F")
  assert.equal(view.info.subtitle, "Artist · Rock")
  assert.equal(view.info.detail, "In your library")
  // Without catalog top songs, the library's.
  theirs.data.topSongs = []
  assert.equal(Apple.mergedArtistView(mine, theirs, "Spotify").rows[1].title, "Mine")
  assert.equal(Apple.mergedArtistView(mine, theirs, "Spotify").rows[5].section, "SPOTIFY ALBUMS")
  // Marc: "a setting that puts the top songs at the top or the bottom",
  // being "constantly scrolling past those": Play top songs stays first.
  theirs.data.topSongs = [song("s1", "Hit"), song("s2", "Other")]
  assert.deepEqual(Apple.mergedArtistView(mine, theirs, "Apple Music", true).rows.map(r => (r.section || "") + "|" + r.title),
    ["|Play top songs", "YOUR ALBUMS|Lvl IV", "|B-Sides", "|Dark Paradise", "APPLE MUSIC ALBUMS|Second",
     "SINGLES & EPS|Let Me Out - Single", "|Unplugged - EP", "APPEARS ON|Comp", "TOP SONGS|Hit", "|Other"])
  const alone = Apple.artistView(theirs.artist, theirs.data, "Apple Music", true).rows.map(r => r.kind + ":" + r.title)
  assert.deepEqual([alone[0], alone[alone.length - 2], alone[alone.length - 1]], ["playall:Play top songs", "song:Hit", "song:Other"])
  assert.equal(Apple.artistView(theirs.artist, theirs.data, "Apple Music", false).rows[1].title, "Hit")
  // No top songs: nothing moves, and no button.
  assert.equal(Apple.artistView(mine.artist, { albums: mine.data.albums }, "Apple Music", true).rows[0].title, "Lvl IV")
})

test("an album you have only part of is in both lists, each saying how much", () => {
  const album = (id, source, title, year, trackCount, extra) =>
    Object.assign({ kind: "album", id, source, title, artist: "F", year, trackCount }, extra || {})
  const mine = { artist: { kind: "artist", id: "l.9", source: "library", name: "F" },
    data: { albums: [album("l.1", "library", "Whole", 2001, 10), album("l.2", "library", "Part", 2003, 1),
      // Two copies of one album: the fuller one counts.
      album("l.3", "library", "Twice", 2005, 2), album("l.4", "library", "TWICE", 2005, 9)] } }
  const theirs = { artist: { kind: "artist", id: "9", source: "catalog", name: "F" },
    data: { albums: [album("1", "catalog", "Whole", 2001, 10), album("2", "catalog", "Part", 2003, 12),
      album("3", "catalog", "Twice", 2005, 9)] } }
  const view = Apple.mergedArtistView(mine, theirs)
  assert.deepEqual(view.rows.map(r => (r.section || "") + "|" + r.title + "|" + r.subtitle),
    ["YOUR ALBUMS|Whole|2001 · 10 songs", "|Part|2003 · 1 of 12 songs", "|Twice|2005 · 2 of 9 songs", "|TWICE|2005 · 9 songs",
     "APPLE MUSIC ALBUMS|Part|2003 · 12 songs · you have 1"])

  const rows = Apple.searchRows({
    library: { albums: [album("l.2", "library", "Part", 2003, 1), album("l.1", "library", "Whole", 2001, 10)] },
    catalog: { albums: [album("2", "catalog", "Part", 2003, 12), album("1", "catalog", "Whole", 2001, 10)] }
  })
  assert.deepEqual(rows.map(r => r.section + "|" + r.title + "|" + r.subtitle),
    ["YOUR ALBUMS|Part|F · 2003 · 1 song", "|Whole|F · 2001 · 10 songs", "APPLE MUSIC · ALBUMS|Part|F · 2003 · 12 songs · you have 1"])
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

test("an album, song or artist you own is listed once, as yours, even without a catalog id", () => {
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
     "album:Warehouse: Songs and Stories:catalog", "song:Diane:catalog"])
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

test("your library's genres come right after your playlists, and open to their artists", () => {
  const genre = { kind: "genre", id: "Alternative & Punk", source: "library", name: "Alternative & Punk", songs: 1203 }
  const rows = Apple.searchRows({ library: { playlists: [{ kind: "playlist", id: "p.1", source: "library", name: "PunkRock" }],
    songs: [song("i.1", "Diane", { source: "library" })], genres: [genre] } },
    [{ id: "1006", name: "Punk" }])
  assert.deepEqual(rows.map((r) => r.section), ["YOUR PLAYLISTS", "YOUR GENRES", "YOUR SONGS", "GENRES"])
  assert.equal(rows[1].subtitle, "1,203 songs")
  assert.deepEqual(rows[1].apple, { kind: "genre", id: "Alternative & Punk", source: "library" })
  assert.equal(rows[1].noQueue, true)
  assert.equal(rows[3].subtitle, "Apple Music charts")
})

test("a library genre: Shuffle, its artists in the bridge's order, then its compilations", () => {
  const album = (id, title, artist, artistId, extra) => Object.assign({ kind: "album", id, source: "library", title, artist,
    artistId, year: 1984, trackCount: 2, artwork: art }, extra || {})
  const data = {
    albums: [album("a1", "Workbook", "Bob Mould", "ar1"), album("a2", "Zen Arcade", "Hüsker Dü", "ar2"),
      album("a3", "New Day Rising", "Husker Du", undefined), album("a4", "Left of the Dial", "Various Artists", undefined),
      album("a5", "Hits", "Sugar", "ar3", { isCompilation: true }), album("a6", "Odd", "Nobody", undefined)],
    songs: [{ id: "s1", year: 1989, duration: 140 }, { id: "s2", year: 1984, duration: 120 }]
  }
  const view = Apple.libraryGenreView({ id: "Alternative & Punk", name: "Alternative & Punk" }, data, 0)
  assert.deepEqual(view.rows.map((r) => r.kind + ":" + r.title),
    ["shuffleall:Shuffle all songs", "artist:Bob Mould", "artist:Hüsker Dü", "compilations:Compilations"])
  assert.deepEqual(view.rows[0].items, [{ kind: "song", id: "s1", source: "library" }, { kind: "song", id: "s2", source: "library" }])
  assert.equal(view.rows[0].subtitle, "2 songs · 4 min")
  // The same artist spelt without accents is one; an artist with no id is a compilation.
  assert.equal(view.rows[2].subtitle, "2 albums")
  assert.deepEqual(view.rows[2].apple, { kind: "artist", id: "ar2", source: "library" })
  assert.equal(view.rows[3].subtitle, "3 albums")
  assert.equal(view.info.subtitle, "Genre · your library · 2 artists · 6 albums")
  const comps = Apple.libraryCompilationsView({ id: "Alternative & Punk", name: "Alternative & Punk" }, data, 0)
  assert.deepEqual(comps.rows.map((r) => r.title), ["Left of the Dial", "Hits", "Odd"])
  assert.equal(comps.info.subtitle, "Alternative & Punk · 3 albums")
  // Nothing left: Time Machine says why.
  const empty = Apple.libraryGenreView({ name: "Grunge" }, { albums: [], songs: [] }, 1989)
  assert.deepEqual(empty.rows, [])
  assert.equal(empty.info.emptyText, "None of your Grunge songs are from 1989 or before (Time Machine).")
})

test("the bridge's stream: its base finds the address from before 0.9.0, and with any secret", () => {
  const before = "http://my-mac.local:8000/omarock.ogg"
  const now = "http://my-mac.local:8000/omarock-0123456789abcdef0123456789abcdef.ogg"
  assert.equal(Apple.streamBase(before), "http://my-mac.local:8000/omarock")
  assert.equal(Apple.streamBase(now), "http://my-mac.local:8000/omarock")
  assert.ok(Apple.isStream(before, now))
  assert.ok(Apple.isStream(now, before))
  assert.ok(Apple.isStream(now, now))
  assert.ok(Apple.isStream("http://100.64.0.10:8000/omarock.ogg", now), "another host's bridge stream counts too (another Mac, or another way to this one)")
  assert.ok(!Apple.isStream("Hüsker Dü/Zen Arcade/01.flac", now))
  assert.ok(!Apple.isStream(now, ""), "no stream known: nothing is it")
  // A streamURL of the user's is its own base.
  assert.equal(Apple.streamBase("http://relay.example:8080/live"), "http://relay.example:8080/live")
  assert.ok(Apple.isStream("http://relay.example:8080/live", "http://relay.example:8080/live"))
})

test("the bridge's stream: a host in any case, and the same secret by another address", () => {
  const secret = "0123456789abcdef0123456789abcdef"
  // Qt asks the bridge in lower case; apple.json keeps the case typed.
  assert.ok(Apple.isStream("http://my-mac.local:8000/omarock-" + secret + ".ogg", "http://My-Mac.local:8000/omarock-" + secret + ".ogg"))
  assert.ok(Apple.isStream("http://my-mac.local:8000/omarock.ogg", "http://My-Mac.local:8000/omarock-" + secret + ".ogg"))
  // The Mac by its Tailscale address and by its .local name: one stream.
  assert.ok(Apple.isStream("http://my-mac.local:8000/omarock-" + secret + ".ogg", "http://100.64.0.10:8000/omarock-" + secret + ".ogg"))
  // Another Mac's bridge, set up before this one: still Apple Music (Play swaps it).
  assert.ok(Apple.isStream("http://old-mac.local:8000/omarock-" + "f".repeat(32) + ".ogg", "http://100.64.0.10:8000/omarock-" + secret + ".ogg"))
  assert.ok(Apple.isStream("http://old-mac.local:8000/omarock.ogg", "http://new-mac.local:8000/omarock-" + secret + ".ogg"))
  assert.ok(!Apple.isStream("http://radio.example:8000/omarock-live.ogg", "http://new-mac.local:8000/omarock-" + secret + ".ogg"))
  assert.ok(!Apple.isStream("http://old-mac.local:8000/omarock.ogg", "http://relay.example:8080/live"), "a streamURL of the user's: only itself")
  assert.equal(Apple.streamSecret("http://h:8000/omarock.ogg"), "")
  assert.equal(Apple.streamBase("HTTP://My-Mac.LOCAL:8000/omarock.ogg"), "http://my-mac.local:8000/omarock")
})
