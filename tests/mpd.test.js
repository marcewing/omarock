const test = require("node:test")
const assert = require("node:assert/strict")
const Mpd = require("../Mpd.js")

// mpd's =~ uses PCRE; JS has no inline (?i), so test the pattern with the i flag.
function jsRegex(pattern) {
  return new RegExp(pattern.replace(/^\(\?i\)/, ""), "i")
}

test("quote escapes backslashes and double quotes", () => {
  assert.equal(Mpd.quote('say "hi"'), '"say \\"hi\\""')
  assert.equal(Mpd.quote("a\\b"), '"a\\\\b"')
  assert.equal(Mpd.command("add", ["Music/It's \"Live\".mp3"]), 'add "Music/It\'s \\"Live\\".mp3"')
})

test("output commands are refused, anywhere in a command list", () => {
  assert.equal(Mpd.isForbidden("enableoutput 1"), true)
  assert.equal(Mpd.isForbidden("  toggleoutput 0"), true)
  assert.equal(Mpd.isForbidden(Mpd.commandList(["clear", "outputset 0 x y", "play"])), true)
  assert.equal(Mpd.isForbidden("OUTPUTSET 0 a b"), true)
  assert.equal(Mpd.isForbidden("outputs"), false)
  assert.equal(Mpd.isForbidden(Mpd.commandList(["clear", "play"])), false)
})

test("filters quote twice, once for the filter and once for the protocol", () => {
  const filter = Mpd.andFilter([Mpd.tagFilter("albumartist", "==", "Hüsker Dü"), Mpd.tagFilter("album", "==", 'Say "Yes"')])
  assert.equal(Mpd.command("find", [filter]),
    'find "((albumartist == \\"Hüsker Dü\\") AND (album == \\"Say \\\\\\"Yes\\\\\\"\\"))"')
})

test("queueCommands plays from a song or appends", () => {
  assert.deepEqual(Mpd.queueCommands(["a/1.mp3", "a/2.mp3"], "play", 1),
    ["clear", 'add "a/1.mp3"', 'add "a/2.mp3"', "play 1"])
  assert.deepEqual(Mpd.queueCommands(["a/1.mp3"], "play"), ["clear", 'add "a/1.mp3"', "play 0"])
  assert.deepEqual(Mpd.queueCommands(["a/b.mp3"], "add"), ['add "a/b.mp3"'])
})

test("command_list_ok replies split per command", () => {
  assert.equal(Mpd.commandListOk(["count a", "count b"]), "command_list_ok_begin\ncount a\ncount b\ncommand_list_end")
  assert.deepEqual(Mpd.splitReplies(["songs: 23", "playtime: 9", "list_OK", "songs: 20", "list_OK"]),
    [["songs: 23", "playtime: 9"], ["songs: 20"]])
  assert.deepEqual(Mpd.splitReplies(["list_OK", "songs: 1", "list_OK"]), [[], ["songs: 1"]])
})

test("mergeAlbums makes one row of a compilation listed once per artist", () => {
  const rows = Mpd.mergeAlbums([
    { albumartist: "Aztec Camera", album: "Left Of The Dial" },
    { albumartist: "Black Flag", album: "Left Of The Dial" },
    { albumartist: "Hüsker Dü", album: "Zen Arcade" },
    { albumartist: "Hüsker Dü", album: "" }
  ])
  assert.equal(rows.length, 2)
  assert.deepEqual(rows[0], { album: "Left Of The Dial", artists: ["Aztec Camera", "Black Flag"], year: "", albumartist: "" })
  assert.equal(rows[1].albumartist, "Hüsker Dü")
})

const song = (file, track, extra) => Object.assign({ file, track: String(track) }, extra)

test("albumOrder plays a compilation split over artist folders in track order", () => {
  const songs = [
    song("Alison Krauss/O Brother/04 River.mp3", 4, { artist: "Alison Krauss" }),
    song("Harry McClintock/O Brother/02 Candy.mp3", 2, { artist: "Harry McClintock" }),
    song("Comp/O Brother/01 Lazarus.mp3", 1, { artist: "James Carter" }),
    song("Comp/O Brother/2-01 Bonus.mp3", 1, { artist: "James Carter", disc: "2/2" })
  ]
  assert.equal(Mpd.sharedName(songs), false)
  assert.deepEqual(Mpd.albumOrder(songs).map(s => s.track + "/" + (s.disc || "1")), ["1/1", "2/1", "4/1", "1/2/2"])
})

test("albums sharing a name are told apart by artist", () => {
  const songs = [
    song("Queen/Greatest Hits/02 Bites.mp3", 2, { artist: "Queen", album: "Greatest Hits", date: "1981" }),
    song("Queen/Greatest Hits/01 Rhapsody.mp3", 1, { artist: "Queen", album: "Greatest Hits", date: "1981" }),
    song("ABBA/Greatest Hits/01 SOS.mp3", 1, { artist: "ABBA", album: "Greatest Hits", date: "1976" })
  ]
  assert.equal(Mpd.sharedName(songs), true)
  assert.deepEqual(Mpd.albumOrder(songs, "Queen").map(s => s.track), ["1", "2"])
  // No artist: folder by folder.
  assert.deepEqual(Mpd.albumOrder(songs, "").map(s => s.artist + s.track), ["ABBA1", "Queen1", "Queen2"])
  const albums = Mpd.albumsSharingName(songs)
  assert.deepEqual(albums.map(a => a.albumartist + " " + a.year + " " + a.songs.length), ["ABBA 1976 1", "Queen 1981 2"])
})

test("groupAlbums sorts an artist's albums by year, songs without an album last", () => {
  const albums = Mpd.groupAlbums([
    song("H/Candy/01.mp3", 1, { album: "Candy Apple Grey", date: "1986", duration: "200" }),
    song("H/odd.mp3", 0, { album: "" }),
    song("H/Zen/02.mp3", 2, { album: "Zen Arcade", date: "1984", duration: "60" }),
    song("H/Zen/01.mp3", 1, { album: "Zen Arcade", date: "1984-07-01", duration: "40.5" })
  ])
  assert.deepEqual(albums.map(a => a.album), ["Zen Arcade", "Candy Apple Grey", ""])
  assert.equal(albums[0].year, "1984")
  assert.equal(albums[0].seconds, 100.5)
  assert.deepEqual(albums[0].songs.map(s => s.track), ["1", "2"])
})

test("splitAppearances: under half the album's songs means a compilation", () => {
  const albums = [
    { album: "Zen Arcade", songs: [1, 2, 3] },
    { album: "Left Of The Dial", songs: [1] },
    { album: "", songs: [1] }
  ]
  const view = Mpd.splitAppearances(albums, { "Zen Arcade": 3, "Left Of The Dial": 20 })
  assert.deepEqual(view.albums.map(a => a.album), ["Zen Arcade", ""])
  assert.deepEqual(view.appearsOn.map(a => a.album + " " + a.total), ["Left Of The Dial 20"])
  assert.deepEqual(Mpd.artistFiles({ albums: [{ songs: [{ file: "a" }] }], appearsOn: [{ songs: [{ file: "b" }] }] }),
    ["a", "b"])
})

test("unionSongs: the artist's songs by album artist, then by artist, each file once", () => {
  const own = [song("Zen Arcade/01.mp3", 1), song("Zen Arcade/02.mp3", 2)]
  const performed = [song("Zen Arcade/02.mp3", 2), song("Left Of The Dial/3-07.mp3", 7, { albumartist: "Various Artists" })]
  assert.deepEqual(Mpd.unionSongs(own, performed).map(s => s.file),
    ["Zen Arcade/01.mp3", "Zen Arcade/02.mp3", "Left Of The Dial/3-07.mp3"])
})

test("parseSongs splits on file lines and joins repeated tags", () => {
  const songs = Mpd.parseSongs([
    "file: a/1.mp3", "Title: One", "Artist: X", "Artist: Y", "Pos: 0", "Id: 5",
    "file: a/2.mp3", "Title: Two: The Sequel", "Pos: 1", "Id: 6"
  ])
  assert.equal(songs.length, 2)
  assert.equal(songs[0].artist, "X, Y")
  assert.equal(songs[1].title, "Two: The Sequel")
  assert.equal(songs[1].id, "6")
})

test("parseGrouped keeps each album with its album artist", () => {
  const rows = Mpd.parseGrouped([
    "AlbumArtist: Hüsker Dü", "Album: New Day Rising", "Album: Zen Arcade",
    "AlbumArtist: Minutemen", "Album: Double Nickels on the Dime"
  ], "AlbumArtist", "Album")
  assert.deepEqual(rows[1], { albumartist: "Hüsker Dü", album: "Zen Arcade" })
  assert.deepEqual(rows[2], { albumartist: "Minutemen", album: "Double Nickels on the Dime" })
})

test("parseStatus reads numbers and flags", () => {
  const s = Mpd.parseStatus(["volume: 98", "repeat: 0", "random: 1", "state: play",
    "song: 6", "songid: 7", "elapsed: 69.120", "duration: 284.000", "playlistlength: 13"])
  assert.equal(s.state, "play")
  assert.equal(s.volume, 98)
  assert.equal(s.random, true)
  assert.equal(s.repeat, false)
  assert.equal(s.elapsed, 69.12)
  assert.equal(s.queueLength, 13)
  assert.equal(Mpd.parseStatus([]).state, "stop")
})

test("searchPattern ignores case and accents in both directions", () => {
  const husker = jsRegex(Mpd.searchPattern("husker du"))
  assert.match("Hüsker Dü", husker)
  assert.match("HÜSKER DÜ", jsRegex(Mpd.searchPattern("hüsker")))
  assert.match("Motörhead", jsRegex(Mpd.searchPattern("motorhead")))
  assert.match("Mötley Crüe", jsRegex(Mpd.searchPattern("MOTLEY  crue")))
  assert.ok(Mpd.searchPattern("x").startsWith("(?i)"))
  assert.equal(Mpd.searchPattern("   "), "")
})

test("searchPattern escapes regex characters", () => {
  const p = Mpd.searchPattern("a.b (live)?")
  assert.match("A.B (Live)?", jsRegex(p))
  assert.doesNotMatch("axb (live)", jsRegex(p))
})

test("sortByMatch puts prefix matches first, then word starts", () => {
  const names = ["The Replacements", "Replacements Tribute", "Unreplaceable"]
  assert.deepEqual(Mpd.sortByMatch(names, "replace", n => n),
    ["Replacements Tribute", "The Replacements", "Unreplaceable"])
})

test("pickCover prefers cover.jpg and ignores other images", () => {
  assert.equal(Mpd.pickCover(["01 Song.mp3", "back.jpg", "Folder.JPG", "cover.png", "cover.jpg"]), "cover.jpg")
  assert.equal(Mpd.pickCover(["Folder.JPG", "scan.png"]), "Folder.JPG")
  assert.equal(Mpd.pickCover(["01 Song.mp3"]), null)
})

test("fileUrl percent-encodes each path segment", () => {
  assert.equal(Mpd.fileUrl("/home/you/Music/AC#DC/Live? Yes/cover.jpg"),
    "file:///home/you/Music/AC%23DC/Live%3F%20Yes/cover.jpg")
  // Decomposed ü (as macOS writes folder names) stays decomposed.
  assert.equal(Mpd.fileUrl("/Hüsker"), "file:///Hu%CC%88sker")
})

test("directoryOf and isLocalFile", () => {
  assert.equal(Mpd.directoryOf("iTunes Music/A/B/01 x.mp3"), "iTunes Music/A/B")
  assert.equal(Mpd.directoryOf("x.mp3"), "")
  assert.equal(Mpd.isLocalFile("iTunes Music/a.mp3"), true)
  assert.equal(Mpd.isLocalFile("http://radio.example/stream"), false)
})

test("time formatting", () => {
  assert.equal(Mpd.formatTime(69.9), "1:09")
  assert.equal(Mpd.formatTime(0), "0:00")
  assert.equal(Mpd.formatTime(3725), "1:02:05")
  assert.equal(Mpd.formatTotal(52 * 60), "52 min")
  assert.equal(Mpd.formatTotal(125 * 60), "2 h 5 min")
  assert.equal(Mpd.formatCount(3746), "3,746")
  assert.equal(Mpd.formatCount(20107), "20,107")
  assert.equal(Mpd.formatCount(999), "999")
})

test("a space in a search also matches punctuation between words", () => {
  assert.match("Hip-Hop/Rap", jsRegex(Mpd.searchPattern("hip hop")))
  assert.match("AC/DC", jsRegex(Mpd.searchPattern("ac dc")))
  assert.match("Alternative & Punk", jsRegex(Mpd.searchPattern("alternative")))
})

test("parseRows reads a list with several groups", () => {
  const rows = Mpd.parseRows([
    "AlbumArtist: Jelly Roll Morton", "Date: 1926", "Album: Centennial (Disc 2)", "Album: Centennial (Disc 3)",
    "Date: 1990", "Album: Centennial", "AlbumArtist: Keb' Mo'", "Date: 1998", "Album: Slow Down"
  ], "Album")
  assert.deepEqual(rows[2], { albumartist: "Jelly Roll Morton", date: "1990", album: "Centennial" })
  assert.deepEqual(rows[3], { albumartist: "Keb' Mo'", date: "1998", album: "Slow Down" })
})

test("parseCounts reads count ... group genre", () => {
  assert.deepEqual(Mpd.parseCounts(["Genre: Hip Hop/Rap", "songs: 899", "playtime: 199801",
    "Genre: Hip-Hop/Rap", "songs: 93", "playtime: 21014"], "Genre"),
    [{ name: "Hip Hop/Rap", songs: 899, seconds: 199801 }, { name: "Hip-Hop/Rap", songs: 93, seconds: 21014 }])
})

test("a genre's albums sort by artist and year, compilations last", () => {
  const albums = Mpd.sortGenreAlbums(Mpd.mergeAlbums([
    { albumartist: "Zeta", date: "1990", album: "Late" },
    { albumartist: "Aztec Camera", date: "1986", album: "Left Of The Dial" },
    { albumartist: "Black Flag", date: "1981", album: "Left Of The Dial" },
    { albumartist: "Alpha", date: "2001", album: "Second" },
    { albumartist: "Alpha", date: "1999-05", album: "First" }
  ]))
  assert.deepEqual(albums.map(a => a.album + " " + a.year), ["First 1999", "Second 2001", "Late 1990", "Left Of The Dial 1981"])
  assert.deepEqual(Mpd.genreCommands("Jazz", "play"), ["clear", 'findadd "(genre == \\"Jazz\\")"', "shuffle", "play"])
  assert.deepEqual(Mpd.genreCommands("Jazz", "add"), ['findadd "(genre == \\"Jazz\\")"'])
})

test("genreArtists lists artists with their own albums and gathers compilations", () => {
  const albums = Mpd.sortGenreAlbums(Mpd.mergeAlbums([
    { albumartist: "Hüsker Dü", date: "1984", album: "Zen Arcade" },
    { albumartist: "Hüsker Dü", date: "1986", album: "Candy Apple Grey" },
    { albumartist: "Aztec Camera", date: "1986", album: "Left Of The Dial" },
    { albumartist: "Black Flag", date: "1986", album: "Left Of The Dial" },
    { albumartist: "Various Artists", date: "1988", album: "Sampler" },
    { albumartist: "Minutemen", date: "1984", album: "Double Nickels" }
  ]))
  const view = Mpd.genreArtists(albums)
  assert.deepEqual(view.artists.map(a => a.artist + ":" + a.albums.map(x => x.album).join("+")),
    ["Hüsker Dü:Zen Arcade+Candy Apple Grey", "Minutemen:Double Nickels"])
  assert.deepEqual(view.compilations.map(a => a.album), ["Sampler", "Left Of The Dial"])
  assert.equal(Mpd.isVarious("VARIOUS ARTISTS "), true)
  assert.equal(Mpd.isVarious("Various Positions"), false)
})

test("Panel.qml's version matches manifest.json", () => {
  const fs = require("node:fs")
  const path = require("node:path")
  const root = path.join(__dirname, "..")
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"))
  const panel = fs.readFileSync(path.join(root, "Panel.qml"), "utf8")
  assert.equal(panel.match(/property string version: "([^"]+)"/)[1], manifest.version)
})

test("song display falls back to the file name", () => {
  assert.equal(Mpd.songTitle({ file: "a/b/07 Whirling Hall.mp3" }), "07 Whirling Hall")
  assert.equal(Mpd.songTitle({ file: "x.mp3", title: "Real" }), "Real")
  assert.equal(Mpd.songArtist({ albumartist: "AA" }), "AA")
  assert.equal(Mpd.songYear({ date: "1986-03-01" }), "1986")
  assert.equal(Mpd.songYear({}), "")
})

test("stored playlists parse, sort by name and by last change", () => {
  const lists = Mpd.parsePlaylists(["playlist: road trip", "Last-Modified: 2026-10-18T20:00:00Z",
    "playlist: Älter", "Last-Modified: 2026-10-01T09:00:00Z", "playlist: Zebra", "Last-Modified: 2026-10-18T21:00:00Z"])
  assert.deepEqual(lists[0], { name: "road trip", modified: "2026-10-18T20:00:00Z" })
  assert.deepEqual(Mpd.byName(lists).map(p => p.name), ["Älter", "road trip", "Zebra"])
  assert.deepEqual(Mpd.recentFirst(lists).map(p => p.name), ["Zebra", "road trip", "Älter"])
})

test("playlist names match a search like tags do, and mpd's naming rule holds", () => {
  assert.equal(Mpd.nameMatches("Hüsker Dü Mix", "husker"), true)
  assert.equal(Mpd.nameMatches("Road-Trip 2026", "road trip"), true)
  assert.equal(Mpd.nameMatches("Late Night", "trip"), false)
  assert.equal(Mpd.nameMatches("Late Night", "  "), false)
  assert.equal(Mpd.nameMatches("A (B)", "(b"), true)
  assert.equal(Mpd.validPlaylistName("Punk 80s"), true)
  assert.equal(Mpd.validPlaylistName("AC/DC"), false)
  assert.equal(Mpd.validPlaylistName("   "), false)
})

test("a stored playlist queues with load; songs go onto it with playlistadd", () => {
  assert.deepEqual(Mpd.playlistQueueCommands('Say "Yes"', "play", 2), ["clear", 'load "Say \\"Yes\\""', "play 2"])
  assert.deepEqual(Mpd.playlistQueueCommands("Mix", "add"), ['load "Mix"'])
  assert.deepEqual(Mpd.playlistAddCommands("Mix", ["a/1.mp3", "b/2.mp3"]),
    ['playlistadd "Mix" "a/1.mp3"', 'playlistadd "Mix" "b/2.mp3"'])
})

test("a playlist song that left the library has only its file line", () => {
  const songs = Mpd.parseSongs(["file: a/1.mp3", "Last-Modified: 2026-08-05T18:54:34Z", "Title: One", "duration: 122.698",
    "file: gone/2.mp3", "file: a/3.mp3", "Title: Three"])
  assert.deepEqual(songs.map(Mpd.isMissing), [false, true, false])
})

test("randomSongCommands adds one song of the library and plays it", () => {
  assert.deepEqual(Mpd.randomSongCommands(41, 0), ['findadd "(base \\"\\")" window 41:42', "play 0"])
})

test("Time Machine's year as an mpd pattern: every year up to it, from 1000, and nothing after", () => {
  assert.equal(Mpd.yearPattern(1996), "^(1[0-8][0-9]{2}|19[0-8][0-9]|199[0-5]|1996)")
  assert.equal(Mpd.yearPattern(2010), "^(1[0-9]{3}|200[0-9]|2010)")
  for (const year of [1949, 1959, 1970, 1999, 2000, 2001, 2019, 2025]) {
    const pattern = new RegExp(Mpd.yearPattern(year))
    for (let t = 1000; t <= 2100; t++)
      assert.equal(pattern.test(String(t)) && pattern.test(t + "-03-12T08:00:00Z"), t <= year, year + " " + t)
    assert.ok(!pattern.test("") && !pattern.test("0999") && !pattern.test("unknown"))
  }
})

test("withYear narrows a filter to Time Machine's year; inYear the same for a song", () => {
  assert.equal(Mpd.withYear('(genre == "Jazz")', 0), '(genre == "Jazz")')
  assert.equal(Mpd.withYear('(genre == "Jazz")', 1959), '((genre == "Jazz") AND (date =~ "^(1[0-8][0-9]{2}|19[0-4][0-9]|195[0-8]|1959)"))')
  assert.ok(Mpd.inYear({ date: "1959-08-17" }, 1959) && !Mpd.inYear({ date: "1960" }, 1959))
  assert.ok(!Mpd.inYear({ file: "x" }, 1959) && Mpd.inYear({ file: "x" }, 0))
  assert.deepEqual(Mpd.genreCommands("Jazz", "add", 1959),
    ['findadd "((genre == \\"Jazz\\") AND (date =~ \\"^(1[0-8][0-9]{2}|19[0-4][0-9]|195[0-8]|1959)\\"))"'])
  assert.equal(Mpd.afterYearFilter(1959), '((date != "") AND (date !~ "^(1[0-8][0-9]{2}|19[0-4][0-9]|195[0-8]|1959)"))')
  assert.deepEqual(Mpd.randomSongCommands(3, 2, 1959),
    ['findadd "(date =~ \\"^(1[0-8][0-9]{2}|19[0-4][0-9]|195[0-8]|1959)\\")" window 3:4', "play 2"])
})

test("commandWord names a command, or a list by its first", () => {
  assert.equal(Mpd.commandWord("setvol 40"), "setvol")
  assert.equal(Mpd.commandWord(Mpd.commandList(["repeat 1", "single 1"])), "repeat…")
  assert.equal(Mpd.commandWord('addid "http://x" "+0"'), "addid")
})
