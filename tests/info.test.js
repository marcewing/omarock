const test = require("node:test")
const assert = require("node:assert/strict")
const Info = require("../Info.js")
const Apple = require("../Apple.js")
const Mpd = require("../Mpd.js")

// A card's fields as "GROUP: Label = value" lines, for compact assertions.
function lines(card) {
  return card.groups.flatMap(g => g.fields.map(f => g.title + ": " + f.label + " = " + f.value))
}

const zen = {
  file: "iTunes Music/Hüsker Dü/Zen Arcade/01 Something I Learned Today.mp3",
  "last-modified": "2026-08-05T18:54:34Z", added: "2026-10-18T20:00:00Z", format: "44100:16:2",
  artist: "Hüsker Dü", title: "Something I Learned Today", album: "Zen Arcade", track: "1", date: "1984",
  genre: "Alternative & Punk", time: "123", duration: "122.698"
}

test("localSong: the tags, then the file, from lsinfo and listfiles", () => {
  const card = Info.localSong(zen, { size: 2599585, musicDirectory: "/home/you/Music/" })
  assert.equal(card.serviceName, "Local music")
  assert.equal(card.kindName, "Song")
  assert.equal(card.status, "")
  assert.equal(card.title, "Something I Learned Today")
  assert.deepEqual(card.lines, ["Hüsker Dü", "Zen Arcade · 1984"])
  assert.deepEqual(lines(card), [
    "SONG: Artist = Hüsker Dü", "SONG: Album = Zen Arcade", "SONG: Track = 1", "SONG: Date = 1984",
    "SONG: Genre = Alternative & Punk", "SONG: Length = 2:03",
    "FILE: Type = MP3 · 44.1 kHz · 16-bit · stereo", "FILE: Bitrate = 169 kbps (average)", "FILE: Size = 2.5 MB",
    "FILE: Path = /home/you/Music/iTunes Music/Hüsker Dü/Zen Arcade/01 Something I Learned Today.mp3",
    "FILE: Added to mpd = 18 Oct 2026", "FILE: Modified = 5 Aug 2026"
  ])
})

test("localSong: tags it doesn't lay out, MusicBrainz ids and stickers get their own groups", () => {
  const card = Info.localSong(Object.assign({}, zen, { albumartist: "Various", disc: "2", composer: "Bob Mould",
    musicbrainz_trackid: "abc", ensemble: "", work: "Zen", movementnumber: "2", movement: "Pride" }), {
    stickers: { rating: "8" } })
  const all = lines(card)
  assert.ok(all.includes("SONG: Album artist = Various"))
  assert.ok(all.includes("SONG: Track = 1 (disc 2)"))
  assert.ok(all.includes("SONG: Work = Zen · movement 2 · Pride"))
  assert.ok(all.includes("IDENTIFIERS: MusicBrainz recording = abc"))
  assert.ok(all.includes("STICKERS: rating = 8"))
  assert.ok(!all.some(l => l.startsWith("FILE: Size")), "no size without listfiles")
  const odd = Info.localSong(Object.assign({}, zen, { replaygain: "x" }), {})
  assert.ok(lines(odd).includes("OTHER TAGS: Replaygain = x"))
})

test("localAlbum: the album artist, years, discs and its files together", () => {
  const songs = [
    { file: "A/Live/1-01 Intro.flac", artist: "The Quiet Riots", albumartist: "The Quiet Riots", album: "Live",
      date: "1985", disc: "1", duration: "45", format: "44100:16:2", genre: "Punk", added: "2026-10-18T20:00:00Z" },
    { file: "A/Live/2-01 Encore.flac", artist: "The Quiet Riots", albumartist: "The Quiet Riots", album: "Live",
      date: "1986", disc: "2", duration: "200", format: "44100:16:2", genre: "Punk", added: "2026-10-19T20:00:00Z" }
  ]
  const card = Info.localAlbum(songs, { size: 30000000, folders: ["A/Live"], cover: "cover.jpg" })
  assert.equal(card.kindName, "Album")
  assert.equal(card.title, "Live")
  assert.deepEqual(card.lines, ["The Quiet Riots", "1985–1986"])
  assert.deepEqual(lines(card), [
    "ALBUM: Album artist = The Quiet Riots", "ALBUM: Year = 1985–1986", "ALBUM: Genre = Punk", "ALBUM: Songs = 2",
    "ALBUM: Discs = 2", "ALBUM: Length = 4 min",
    "FILES: Type = FLAC · 44.1 kHz · 16-bit · stereo", "FILES: Bitrate = 980 kbps (average)", "FILES: Size = 28.6 MB",
    "FILES: Folder = A/Live", "FILES: Cover = cover.jpg", "FILES: Added to mpd = 18 Oct 2026"
  ])
  const comp = Info.localAlbum([{ file: "C/x/1.mp3", artist: "A", album: "Mix" }, { file: "C/y/2.mp3", artist: "B", album: "Mix" }],
    { folders: ["C/x", "C/y"], cover: "" })
  assert.equal(comp.lines[0], "Various artists")
  assert.ok(lines(comp).includes("ALBUM: Artists = A, B"))
  assert.ok(lines(comp).includes("FILES: Folders = 2: C/x, C/y"))
  assert.ok(lines(comp).includes("FILES: Cover = None in the folder"))
})

const diane = { kind: "song", id: "1440857781", source: "catalog", catalogId: "1440857781", title: "Diane",
  artist: "Hüsker Dü", album: "Metal Circus", genres: ["Punk", "Music"], year: 1983, releaseDate: "1983-10-01",
  duration: 248.5, trackNumber: 5, discNumber: 1, composer: "Grant Hart", explicit: false,
  audioTraits: ["lossless", "lossy-stereo"], isrc: "USSS18300001", playable: true }

test("appleItem: the library status leads the card", () => {
  assert.equal(Info.appleItem(diane, { checking: true }).status, "Checking your library…")
  assert.equal(Info.appleItem(diane, {}).statusKind, "unknown")
  const out = Info.appleItem(diane, { inLibrary: false })
  assert.equal(out.serviceName, "Apple Music")
  assert.equal(out.status, "Not in your library")
  assert.equal(out.statusKind, "no")
  const mine = Info.appleItem(Object.assign({}, diane, { source: "library", id: "-53002" }), {})
  assert.equal(mine.status, "In your library")
  assert.ok(lines(mine).includes("YOUR LIBRARY: Library id = -53002"))
  // A library row taken out of the library (Spotify): the service's word wins.
  const gone = Info.appleItem(Object.assign({}, diane, { source: "library" }), { inLibrary: false }, "spotify")
  assert.equal(gone.statusKind, "no")
  // An album you have some songs of, counted from its list; all of it wins.
  const metal = { kind: "album", id: "1440857700", source: "catalog", title: "Metal Circus", artist: "Hüsker Dü" }
  const part = Info.appleItem(metal, { inLibrary: false, songsInLibrary: { have: 1, total: 7 } })
  assert.equal(part.status, "1 of 7 songs in your library")
  assert.equal(part.statusKind, "some")
  assert.equal(Info.appleItem(metal, { inLibrary: true, songsInLibrary: { have: 1, total: 7 } }).statusKind, "yes")
  assert.equal(Info.appleItem(metal, { inLibrary: false, songsInLibrary: { have: 0, total: 7 } }).statusKind, "no")
  assert.deepEqual(lines(out), [
    "SONG: Artist = Hüsker Dü", "SONG: Album = Metal Circus", "SONG: Track = 5 (disc 1)", "SONG: Released = 1 Oct 1983",
    "SONG: Genre = Punk", "SONG: Composer = Grant Hart", "SONG: Length = 4:09",
    "APPLE MUSIC: Audio = Lossless, AAC", "APPLE MUSIC: ISRC = USSS18300001", "APPLE MUSIC: Catalog id = 1440857781"
  ])
})

test("appleItem: the bridge's library details, and an album's", () => {
  const out = Info.appleItem(diane, { inLibrary: true, catalog: { id: "1440857781", url: "https://music.apple.com/x" },
    library: { id: "39206", added: "2019-04-02T17:03:11Z", playCount: 12, rating: 80, fileKind: "Matched AAC audio file",
      bitrate: 256, sampleRate: 44100, fileSize: 7340032, cloud: true, drm: false, loved: false } })
  assert.equal(out.status, "In your library")
  const all = lines(out)
  for (const want of ["APPLE MUSIC: Link = https://music.apple.com/x", "YOUR LIBRARY: Added = 2 Apr 2019",
    "YOUR LIBRARY: Plays = 12", "YOUR LIBRARY: Rating = ★★★★☆", "YOUR LIBRARY: File = Matched AAC audio file",
    "YOUR LIBRARY: Bitrate = 256 kbps", "YOUR LIBRARY: Sample rate = 44.1 kHz", "YOUR LIBRARY: Size = 7.0 MB",
    "YOUR LIBRARY: In iCloud = Yes", "YOUR LIBRARY: Protected (DRM) = No", "YOUR LIBRARY: Favorite = No",
    "YOUR LIBRARY: Library id = 39206"])
    assert.ok(all.includes(want), want)
  const album = Info.appleItem({ kind: "album", id: "9", source: "catalog", title: "Zen Arcade", artist: "Hüsker Dü",
    trackCount: 23, recordLabel: "SST Records", releaseDate: "1984-07-01", editorialNotes: "A double album." },
  { inLibrary: true, library: { trackCount: 9, playCount: 40 } })
  assert.equal(album.kindName, "Album")
  assert.equal(album.notes, "A double album.")
  assert.deepEqual(album.lines, ["Hüsker Dü", "1 Jul 1984"])
  assert.ok(lines(album).includes("YOUR LIBRARY: Songs you have = 9 songs of 23"))
  assert.ok(lines(album).includes("ALBUM: Label = SST Records"))
})

test("foundInLibrary: by catalog id, else by title and artist, accents aside", () => {
  const results = { library: { songs: [{ title: "Diane", artist: "Husker Du", source: "library" }], albums: [] } }
  assert.equal(Info.foundInLibrary(diane, results, Apple.foldKey), true)
  assert.equal(Info.foundInLibrary(Object.assign({}, diane, { artist: "Someone" }), results, Apple.foldKey), false)
  assert.equal(Info.foundInLibrary({ kind: "album", id: "7", title: "X" },
    { library: { albums: [{ title: "Other", catalogId: "7" }] } }, Apple.foldKey), true)
  assert.equal(Info.foundInLibrary(diane, {}, Apple.foldKey), false)
})

test("station: favorite status, what's on, the stream", () => {
  const out = Info.station({ name: "KXYZ", stationuuid: "u-1", state: "Oregon", country: "The United States Of America", countrycode: "US",
    tags: "community, college", codec: "MP3", bitrate: 128, url_resolved: "http://x/stream", lastcheckok: 1,
    votes: 40, hls: 0 }, { favorite: true, now: { artist: "Low", title: "Words" } })
  assert.equal(out.serviceName, "Radio")
  assert.equal(out.status, "In your favorites")
  assert.deepEqual(out.lines, ["Oregon, US", "Low – Words"])
  assert.deepEqual(lines(out).slice(0, 3), ["ON NOW: Artist = Low", "ON NOW: Title = Words", "STATION: Place = Oregon, US"])
  assert.equal(Info.station({ name: "Y", country: "Canada" }, {}).lines[0], "Canada")
  assert.ok(lines(out).includes("STREAM: Format = MP3 · 128 kbps"))
  assert.ok(lines(out).includes("STREAM: Last check = Working"))
  assert.equal(Info.station({ name: "X" }, {}).status, "Not in your favorites")
})

test("channel: number and genre, what's on, the description", () => {
  const out = Info.channel({ id: "c1", number: "70", name: "Real Jazz", genre: "Jazz", description: "Classic jazz.",
    favorite: true, available: true }, { artist: "Miles Davis", title: "So What", show: "" })
  assert.equal(out.serviceName, "SiriusXM")
  assert.equal(out.status, "In your favorites")
  assert.deepEqual(out.lines, ["Channel 70 · Jazz", "Miles Davis – So What"])
  assert.equal(out.notes, "Classic jazz.")
  assert.ok(lines(out).includes("CHANNEL: Channel id = c1"))
  assert.deepEqual(Info.channel({ name: "Ads" }, { isAd: true, show: "Break" }).lines, ["Ad break"])
})

test("formats: dates, audio, sizes", () => {
  assert.equal(Info.formatDate("1984"), "1984")
  assert.equal(Info.formatDate("1984-07-01"), "1 Jul 1984")
  assert.equal(Info.formatDate(""), "")
  assert.equal(Info.formatAudio("48000:f:2"), "48 kHz · 32-bit float · stereo")
  assert.equal(Info.formatAudio("22050:16:1"), "22.1 kHz · 16-bit · mono")
  assert.equal(Info.formatBytes(500), "1 KB")
  assert.equal(Info.formatBytes(3 * 1024 * 1024 * 1024), "3.00 GB")
  assert.equal(Info.fileType("a/b.FLAC"), "FLAC")
  assert.equal(Info.fileType("http://x/y.mp3"), "")
  assert.equal(Info.stars(0), "")
})

test("Mpd: listfiles sizes, stickers and folders", () => {
  assert.deepEqual(Mpd.parseFileSizes(["directory: sub", "size: 9", "file: a.mp3", "size: 12", "Last-Modified: x",
    "file: cover.jpg", "size: 3"]), { "a.mp3": 12, "cover.jpg": 3 })
  assert.deepEqual(Mpd.parseStickers(["sticker: rating=8", "sticker: note=a=b"]), { rating: "8", note: "a=b" })
  assert.deepEqual(Mpd.foldersOf([{ file: "x/1" }, { file: "y/2" }, { file: "x/3" }, { file: "top.mp3" }]), ["x", "y", ""])
})

test("appleItem for Spotify: the service and its own group, with the library status", () => {
  const song = { kind: "song", id: "4CguVNCZduDcNNvqpkYhwM", source: "catalog", catalogId: "4CguVNCZduDcNNvqpkYhwM",
    title: "Indecision Time", artist: "Hüsker Dü", album: "Zen Arcade", year: 1984, duration: 134, trackNumber: 6,
    discNumber: 1, isrc: "USSST8400006", playable: false }
  const card = Info.appleItem(song, { inLibrary: false,
    catalog: { id: song.id, url: "https://open.spotify.com/track/4CguVNCZduDcNNvqpkYhwM" } }, "spotify")
  assert.equal(card.service, "spotify")
  assert.equal(card.serviceName, "Spotify")
  assert.equal(card.status, "Not in your library")
  const l = lines(card)
  assert.ok(l.includes("SPOTIFY: Link = https://open.spotify.com/track/4CguVNCZduDcNNvqpkYhwM"), l.join("\n"))
  assert.ok(l.includes("SPOTIFY: ISRC = USSST8400006"))
  assert.ok(l.includes("SONG: Playable = No: Spotify won't stream it"))
  assert.ok(!l.some(x => x.startsWith("APPLE MUSIC")))
  assert.equal(Info.appleItem(song, { inLibrary: true, library: { added: "2026-10-21T12:00:00Z" } }, "spotify").status,
    "In your library")
})
