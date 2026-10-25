// Pure helpers for omarock's mpd client: protocol quoting and parsing,
// accent-insensitive search patterns, cover lookup and display formatting.
// No QML imports, so node can test it (tests/mpd.test.js).

// mpd output commands. omarock never sends these: this machine's other audio
// outputs are radio transmitters, and mpd is pinned to one safe output.
var FORBIDDEN = ["enableoutput", "disableoutput", "toggleoutput", "outputset"]

function isForbidden(text) {
  var lines = String(text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var word = lines[i].trim().split(/\s+/)[0].toLowerCase()
    if (FORBIDDEN.indexOf(word) >= 0) return true
  }
  return false
}

// One protocol argument: double-quoted, with backslashes and quotes escaped.
function quote(value) {
  return '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
}

function command(name, args) {
  var parts = [name]
  for (var i = 0; i < (args || []).length; i++) parts.push(quote(args[i]))
  return parts.join(" ")
}

// Several commands in one round trip; mpd runs them in order and stops at the
// first error.
// A command's name, for logs: "setvol" for "setvol 40", the first command's
// for a command list.
function commandWord(text) {
  var lines = String(text || "").split("\n").filter(function(l) { return l && l.indexOf("command_list") !== 0 })
  return lines.length > 0 ? lines[0].split(" ")[0] + (lines.length > 1 ? "…" : "") : ""
}

function commandList(commands) {
  return ["command_list_begin"].concat(commands).concat(["command_list_end"]).join("\n")
}

// The same, but mpd ends each command's reply with "list_OK", so
// splitReplies can hand back one reply per command.
function commandListOk(commands) {
  return ["command_list_ok_begin"].concat(commands).concat(["command_list_end"]).join("\n")
}

function splitReplies(lines) {
  var replies = [[]]
  for (var i = 0; i < lines.length; i++) {
    if (lines[i] === "list_OK") replies.push([])
    else replies[replies.length - 1].push(lines[i])
  }
  if (replies[replies.length - 1].length === 0) replies.pop()
  return replies
}

// A filter expression comparing one tag, e.g. (albumartist == "Hüsker Dü").
function tagFilter(tag, op, value) {
  return "(" + tag + " " + op + " " + quote(value) + ")"
}

function andFilter(filters) {
  return filters.length === 1 ? filters[0] : "(" + filters.join(" AND ") + ")"
}

// Time Machine (TimeMachine.js): songs from `year` or before, by the year
// their Date tag starts with ("1996", "1996-03-12T08:00:00Z"); songs without
// one are left out. mpd's filters can't compare, so it's a pattern, from the
// year 1000: 1996 is ^(1[0-8][0-9]{2}|19[0-8][0-9]|199[0-5]|1996).
function yearPattern(year) {
  var y = String(year)
  var parts = []
  for (var i = 0; i < 4; i++) {
    var digit = parseInt(y.charAt(i), 10)
    var low = i === 0 ? 1 : 0
    if (digit <= low) continue
    var rest = 3 - i
    parts.push(y.slice(0, i) + (digit - 1 === low ? String(low) : "[" + low + "-" + (digit - 1) + "]")
      + (rest > 1 ? "[0-9]{" + rest + "}" : rest === 1 ? "[0-9]" : ""))
  }
  parts.push(y)
  return "^(" + parts.join("|") + ")"
}

function yearFilter(year) {
  return tagFilter("date", "=~", yearPattern(year))
}

// A filter narrowed to Time Machine's year; as it was when year is 0.
function withYear(filter, year) {
  return year > 0 ? andFilter([filter, yearFilter(year)]) : filter
}

// Songs from after the year: a Date tag that isn't up to it. Streams and
// songs without a date aren't among them.
function afterYearFilter(year) {
  return andFilter([tagFilter("date", "!=", ""), tagFilter("date", "!~", yearPattern(year))])
}

// The same for a song in hand.
function inYear(song, year) {
  var y = songYear(song)
  return !(year > 0) || (y !== "" && parseInt(y, 10) <= year)
}

function parsePair(line) {
  var at = line.indexOf(": ")
  if (at < 0) return null
  return { key: line.slice(0, at).toLowerCase(), value: line.slice(at + 2) }
}

// "key: value" lines into one object with lowercased keys. Repeated tags (two
// Artist lines) are joined.
function parseObject(lines) {
  var out = {}
  for (var i = 0; i < lines.length; i++) {
    var pair = parsePair(lines[i])
    if (!pair) continue
    out[pair.key] = out[pair.key] !== undefined && pair.key !== "file"
      ? out[pair.key] + ", " + pair.value : pair.value
  }
  return out
}

// A song list (playlistinfo, search, find) into objects. Each song starts at
// its "file:" line.
function parseSongs(lines) {
  var songs = []
  var song = null
  for (var i = 0; i < lines.length; i++) {
    var pair = parsePair(lines[i])
    if (!pair) continue
    if (pair.key === "file") {
      song = { file: pair.value }
      songs.push(song)
    } else if (song) {
      song[pair.key] = song[pair.key] !== undefined ? song[pair.key] + ", " + pair.value : pair.value
    }
  }
  return songs
}

// Every value of one key, e.g. the names from "list albumartist".
function parseValues(lines, key) {
  var values = []
  key = key.toLowerCase()
  for (var i = 0; i < lines.length; i++) {
    var pair = parsePair(lines[i])
    if (pair && pair.key === key) values.push(pair.value)
  }
  return values
}

// A "listfiles" reply as name -> size in bytes.
function parseFileSizes(lines) {
  var sizes = {}
  var name = null
  for (var i = 0; i < lines.length; i++) {
    var pair = parsePair(lines[i])
    if (!pair) continue
    if (pair.key === "file" || pair.key === "directory") name = pair.key === "file" ? pair.value : null
    else if (pair.key === "size" && name !== null) sizes[name] = parseInt(pair.value, 10) || 0
  }
  return sizes
}

// "sticker list" lines ("sticker: rating=8") as name -> value.
function parseStickers(lines) {
  var stickers = {}
  parseValues(lines, "sticker").forEach(function(text) {
    var at = text.indexOf("=")
    if (at > 0) stickers[text.slice(0, at)] = text.slice(at + 1)
  })
  return stickers
}

// The folders songs are in, in order, once each.
function foldersOf(songs) {
  var folders = []
  songs.forEach(function(song) {
    var dir = directoryOf(song.file)
    if (folders.indexOf(dir) < 0) folders.push(dir)
  })
  return folders
}

// "list album group albumartist" prints a group line, then the albums in it.
function parseGrouped(lines, groupKey, valueKey) {
  var rows = []
  var group = ""
  groupKey = groupKey.toLowerCase()
  valueKey = valueKey.toLowerCase()
  for (var i = 0; i < lines.length; i++) {
    var pair = parsePair(lines[i])
    if (!pair) continue
    if (pair.key === groupKey) group = pair.value
    else if (pair.key === valueKey) {
      var row = {}
      row[groupKey] = group
      row[valueKey] = pair.value
      rows.push(row)
    }
  }
  return rows
}

// A "list" with several groups, e.g. "list album group date group
// albumartist": group lines set the current value of their tag, and each
// valueKey line is a row carrying the current group values.
function parseRows(lines, valueKey) {
  var rows = []
  var current = {}
  valueKey = valueKey.toLowerCase()
  for (var i = 0; i < lines.length; i++) {
    var pair = parsePair(lines[i])
    if (!pair) continue
    if (pair.key !== valueKey) {
      current[pair.key] = pair.value
      continue
    }
    var row = {}
    for (var key in current) row[key] = current[key]
    row[valueKey] = pair.value
    rows.push(row)
  }
  return rows
}

// "count ... group genre": one { name, songs, seconds } per group value.
function parseCounts(lines, groupKey) {
  var counts = []
  groupKey = groupKey.toLowerCase()
  for (var i = 0; i < lines.length; i++) {
    var pair = parsePair(lines[i])
    if (!pair) continue
    if (pair.key === groupKey) counts.push({ name: pair.value, songs: 0, seconds: 0 })
    else if (counts.length === 0) continue
    else if (pair.key === "songs") counts[counts.length - 1].songs = parseInt(pair.value, 10) || 0
    else if (pair.key === "playtime") counts[counts.length - 1].seconds = parseFloat(pair.value) || 0
  }
  return counts
}

function parseStatus(lines) {
  var raw = parseObject(lines)
  function num(key, fallback) {
    var value = parseFloat(raw[key])
    return isNaN(value) ? fallback : value
  }
  return {
    state: raw.state || "stop",
    volume: num("volume", -1),
    elapsed: num("elapsed", 0),
    duration: num("duration", 0),
    song: num("song", -1),
    songId: raw.songid || "",
    random: raw.random === "1",
    repeat: raw.repeat === "1",
    single: raw.single === "1",
    consume: raw.consume === "1",
    queueLength: num("playlistlength", 0),
    updating: raw.updating_db !== undefined,
    error: raw.error || ""
  }
}

// Accent folding for search. mpd's regex works on bytes, so a character class
// like [uü] can't match ü; each foldable letter becomes an alternation instead.
var ACCENTS = {
  a: "àáâãäåāă", c: "çćč", e: "èéêëēėę", i: "ìíîïī", n: "ñń",
  o: "òóôõöøō", u: "ùúûüū", y: "ýÿ", s: "śš", z: "źżž", l: "ł"
}

function fold(text) {
  var s = String(text || "").toLowerCase()
  if (typeof s.normalize === "function") s = s.normalize("NFD").replace(/[̀-ͯ]/g, "")
  return s.replace(/ø/g, "o").replace(/ł/g, "l").replace(/ß/g, "ss")
}

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// A case- and accent-insensitive pattern for an mpd =~ filter: "husker" also
// matches "Hüsker". A space also matches punctuation between words, or none:
// "hip hop" finds "Hip-Hop/Rap", "ac dc" finds "AC/DC".
function searchPattern(query) {
  var folded = fold(query).trim().replace(/\s+/g, " ")
  var out = ""
  for (var i = 0; i < folded.length; i++) {
    var ch = folded[i]
    var accents = ACCENTS[ch]
    if (ch === " ") {
      out += "[ ./_-]*"
    } else if (accents) {
      var options = [ch]
      for (var j = 0; j < accents.length; j++) options.push(accents[j], accents[j].toUpperCase())
      out += "(" + options.join("|") + ")"
    } else {
      out += escapeRegex(ch)
    }
  }
  return out === "" ? "" : "(?i)" + out
}

// Rank a name against the query: whole-name prefix first, then a word that
// starts with it, then anywhere. Lower is better.
function matchRank(name, query) {
  var n = fold(name)
  var q = fold(query).trim()
  if (q === "") return 3
  if (n.indexOf(q) === 0) return 0
  if (n.indexOf(" " + q) >= 0) return 1
  return 2
}

function sortByMatch(items, query, nameOf) {
  return items.slice().sort(function(a, b) {
    var diff = matchRank(nameOf(a), query) - matchRank(nameOf(b), query)
    if (diff !== 0) return diff
    return fold(nameOf(a)) < fold(nameOf(b)) ? -1 : fold(nameOf(a)) > fold(nameOf(b)) ? 1 : 0
  })
}

// The queue commands for a list of songs. "play" replaces the queue and plays
// from song `start`; "add" appends them to the end of the queue. Songs go in
// one by one, so the queue keeps the order the panel showed.
function queueCommands(files, mode, start) {
  var adds = files.map(function(file) { return command("add", [file]) })
  return mode === "play" ? ["clear"].concat(adds).concat(["play " + (start || 0)]) : adds
}

// "list album group albumartist" answers once per album artist, and when a
// song has no AlbumArtist tag mpd uses its Artist instead. iTunes compilations
// have none, so a compilation comes back once per artist on it. Merge the
// rows by album name; albumartist stays set only when there is just one.
function mergeAlbums(rows) {
  var byName = {}
  var albums = []
  for (var i = 0; i < rows.length; i++) {
    var name = rows[i].album
    if (name === "") continue
    var album = byName[name]
    if (!album) {
      album = byName[name] = { album: name, artists: [], year: "" }
      albums.push(album)
    }
    if (album.artists.indexOf(rows[i].albumartist) < 0) album.artists.push(rows[i].albumartist)
    var year = songYear(rows[i])
    if (year !== "" && (album.year === "" || year < album.year)) album.year = year
  }
  albums.forEach(function(album) { album.albumartist = album.artists.length === 1 ? album.artists[0] : "" })
  return albums
}

function trackNumber(value) {
  var n = parseInt(value, 10)
  return isNaN(n) ? 0 : n
}

function compareText(a, b) {
  return a < b ? -1 : a > b ? 1 : 0
}

// Album order: disc, then track, then file name.
function compareTracks(a, b) {
  return (trackNumber(a.disc) || 1) - (trackNumber(b.disc) || 1)
    || trackNumber(a.track) - trackNumber(b.track)
    || compareText(a.file, b.file)
}

function sharedName(songs) {
  var owner = {}
  for (var i = 0; i < songs.length; i++) {
    if (!songs[i].track) continue
    var key = (trackNumber(songs[i].disc) || 1) + ":" + trackNumber(songs[i].track)
    var dir = directoryOf(songs[i].file)
    if (owner[key] === undefined) owner[key] = dir
    else if (owner[key] !== dir) return true
  }
  return false
}

// The albums behind a shared album name, one per artist, each
// { album, albumartist, year, songs, seconds }. A folder belongs to the
// artist with the most songs in it.
function albumsSharingName(songs) {
  var folders = {}
  songs.forEach(function(song) {
    var dir = directoryOf(song.file)
    var folder = folders[dir] || (folders[dir] = { songs: [], counts: {} })
    var artist = song.albumartist || song.artist || ""
    folder.songs.push(song)
    folder.counts[artist] = (folder.counts[artist] || 0) + 1
  })
  var byArtist = {}
  var albums = []
  Object.keys(folders).sort().forEach(function(dir) {
    var folder = folders[dir]
    var artist = Object.keys(folder.counts).sort(function(a, b) { return folder.counts[b] - folder.counts[a] })[0]
    var album = byArtist[artist]
    if (!album) {
      album = byArtist[artist] = { album: folder.songs[0].album || "", albumartist: artist, year: "", songs: [], seconds: 0 }
      albums.push(album)
    }
    folder.songs.forEach(function(song) {
      album.songs.push(song)
      album.seconds += songSeconds(song)
      var year = songYear(song)
      if (year !== "" && (album.year === "" || year < album.year)) album.year = year
    })
  })
  return albums
}

// One album's songs in play order. iTunes files a compilation's songs under
// each artist's folder, so an album can span folders. When two folders hold
// the same disc and track, they are different albums with the same name
// ("B-Sides & Rarities"): keep the folders of `artist` when given, and play
// folder by folder.
function albumOrder(songs, artist) {
  if (!sharedName(songs)) return songs.slice().sort(compareTracks)
  if (artist) {
    var mine = {}
    songs.forEach(function(song) {
      if ((song.albumartist || song.artist) === artist) mine[directoryOf(song.file)] = true
    })
    var kept = songs.filter(function(song) { return mine[directoryOf(song.file)] })
    if (kept.length > 0) songs = kept
  }
  return songs.slice().sort(function(a, b) {
    return compareText(directoryOf(a.file), directoryOf(b.file)) || compareTracks(a, b)
  })
}

function songSeconds(song) {
  return parseFloat(song.duration || song.time || 0) || 0
}

// The songs of two finds, each file once, in the order they came.
function unionSongs(first, second) {
  var seen = {}
  return first.concat(second).filter(function(song) {
    if (seen[song.file]) return false
    seen[song.file] = true
    return true
  })
}

// An album artist's songs as albums, each { album, year, songs, seconds },
// oldest first. Songs with no album tag come last, as album "".
function groupAlbums(songs) {
  var byName = {}
  var albums = []
  songs.forEach(function(song) {
    var name = song.album || ""
    var album = byName[name]
    if (!album) {
      album = byName[name] = { album: name, year: "", songs: [], seconds: 0 }
      albums.push(album)
    }
    album.songs.push(song)
    album.seconds += songSeconds(song)
    var year = songYear(song)
    if (year !== "" && (album.year === "" || year < album.year)) album.year = year
  })
  albums.forEach(function(album) { album.songs = albumOrder(album.songs) })
  return albums.sort(function(a, b) {
    return (a.album === "") - (b.album === "")
      || compareText(a.year || "9999", b.year || "9999")
      || compareText(fold(a.album), fold(b.album))
  })
}

// Split an artist's albums into their own and the compilations they appear
// on: albums where they have under half the songs. totals maps album name to
// the album's song count in the whole library.
function splitAppearances(albums, totals) {
  var own = []
  var appearsOn = []
  albums.forEach(function(album) {
    album.total = Math.max(album.songs.length, totals[album.album] || 0)
    if (album.album !== "" && album.songs.length * 2 < album.total) appearsOn.push(album)
    else own.push(album)
  })
  return { albums: own, appearsOn: appearsOn }
}

// A genre's albums (from mergeAlbums) as a record shop files them: by
// artist, then year; compilations (several artists) at the end.
function sortGenreAlbums(albums) {
  return albums.slice().sort(function(a, b) {
    return (a.albumartist === "") - (b.albumartist === "")
      || compareText(fold(a.albumartist), fold(b.albumartist))
      || compareText(a.year || "9999", b.year || "9999")
      || compareText(fold(a.album), fold(b.album))
  })
}

// An album artist that really means a compilation.
function isVarious(name) {
  return /^(various|various artists|va)$/i.test(String(name).trim())
}

// A genre's albums (sorted by sortGenreAlbums) as its artists, each
// { artist, albums } with only the artist's own albums, and its compilations:
// albums with several artists or a "Various Artists" album artist. Artists
// who are only on compilations get no entry of their own.
function genreArtists(albums) {
  var artists = []
  var byName = {}
  var compilations = []
  albums.forEach(function(album) {
    if (album.albumartist === "" || isVarious(album.albumartist)) {
      compilations.push(album)
      return
    }
    var entry = byName[album.albumartist]
    if (!entry) {
      entry = byName[album.albumartist] = { artist: album.albumartist, albums: [] }
      artists.push(entry)
    }
    entry.albums.push(album)
  })
  return { artists: artists, compilations: compilations }
}

// A whole genre into the queue (with Time Machine on, up to its year).
// "play" shuffles it: thousands of songs in folder order would just play
// the artists alphabetically.
function genreCommands(genre, mode, year) {
  var add = command("findadd", [withYear(tagFilter("genre", "==", genre), year)])
  return mode === "play" ? ["clear", add, "shuffle", "play"] : [add]
}

// Play with an empty queue: the index-th song of the whole library (in
// database order; "stats" gives the count), or of Time Machine's year and
// before (a count of yearFilter), added at the end and played.
function randomSongCommands(index, queueLength, year) {
  var filter = year > 0 ? yearFilter(year) : '(base "")'
  return [command("findadd", [filter]) + " window " + index + ":" + (index + 1), "play " + queueLength]
}

// Stored playlists. mpd keeps them in its playlist directory, so mpc and
// every other client see the same ones.

// "listplaylists" into [{ name, modified }].
function parsePlaylists(lines) {
  var playlists = []
  for (var i = 0; i < lines.length; i++) {
    var pair = parsePair(lines[i])
    if (!pair) continue
    if (pair.key === "playlist") playlists.push({ name: pair.value, modified: "" })
    else if (pair.key === "last-modified" && playlists.length > 0) playlists[playlists.length - 1].modified = pair.value
  }
  return playlists
}

function byName(playlists) {
  return playlists.slice().sort(function(a, b) { return compareText(fold(a.name), fold(b.name)) || compareText(a.name, b.name) })
}

// The one changed last first: the playlist you are building stays on top.
function recentFirst(playlists) {
  return playlists.slice().sort(function(a, b) {
    return compareText(b.modified, a.modified) || compareText(fold(a.name), fold(b.name))
  })
}

// A playlist name against a search, the way searchPattern matches tags:
// ignoring case and accents, a space also matching punctuation.
function nameMatches(name, query) {
  var words = fold(query).trim().split(/\s+/).filter(function(w) { return w !== "" })
  if (words.length === 0) return false
  return new RegExp(words.map(escapeRegex).join("[ ./_-]*")).test(fold(name))
}

// mpd refuses playlist names with a slash or a line break.
function validPlaylistName(name) {
  var n = String(name || "").trim()
  return n !== "" && !/[\/\n\r]/.test(n)
}

// A song in a stored playlist that has left the library: listplaylistinfo
// gives only its file line, and load skips it.
function isMissing(song) {
  return Object.keys(song).length === 1
}

// A stored playlist into the queue. "play" replaces the queue and plays from
// song `start`, counted without missing songs; "add" appends it.
function playlistQueueCommands(name, mode, start) {
  var load = command("load", [name])
  return mode === "play" ? ["clear", load, "play " + (start || 0)] : [load]
}

// Songs onto the end of a stored playlist, in order. mpd makes the playlist
// if it doesn't exist yet.
function playlistAddCommands(name, files) {
  return files.map(function(file) { return command("playlistadd", [name, file]) })
}

function filesOf(songs) {
  return songs.map(function(song) { return song.file })
}

// Everything by an artist, in the artist view's order.
function artistFiles(view) {
  var files = []
  view.albums.concat(view.appearsOn).forEach(function(album) { files = files.concat(filesOf(album.songs)) })
  return files
}

function directoryOf(file) {
  var at = String(file || "").lastIndexOf("/")
  return at < 0 ? "" : file.slice(0, at)
}

function isLocalFile(file) {
  return file !== "" && !/^[a-z][a-z0-9+.-]*:\/\//i.test(file)
}

// Cover image names, best first. beets writes cover.jpg.
var COVER_NAMES = ["cover", "folder", "front", "album"]
var COVER_TYPES = ["jpg", "jpeg", "png", "webp"]

// Pick the cover from a "listfiles" reply for the album folder.
function pickCover(names) {
  var best = null
  var bestRank = 1e9
  for (var i = 0; i < names.length; i++) {
    var lower = names[i].toLowerCase()
    var dot = lower.lastIndexOf(".")
    if (dot < 0) continue
    var base = COVER_NAMES.indexOf(lower.slice(0, dot))
    var type = COVER_TYPES.indexOf(lower.slice(dot + 1))
    if (base < 0 || type < 0) continue
    var rank = base * 10 + type
    if (rank < bestRank) { best = names[i]; bestRank = rank }
  }
  return best
}

function fileUrl(path) {
  return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
}

function formatTime(seconds) {
  var total = Math.max(0, Math.floor(seconds || 0))
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60
  var ss = (s < 10 ? "0" : "") + s
  if (h > 0) return h + ":" + (m < 10 ? "0" : "") + m + ":" + ss
  return m + ":" + ss
}

// 3746 -> "3,746".
function formatCount(n) {
  return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

function formatTotal(seconds) {
  var minutes = Math.round((seconds || 0) / 60)
  if (minutes < 60) return minutes + " min"
  var h = Math.floor(minutes / 60)
  var m = minutes % 60
  return h + " h" + (m > 0 ? " " + m + " min" : "")
}

function songTitle(song) {
  if (!song) return ""
  if (song.title) return song.title
  var file = String(song.file || "")
  var name = file.slice(file.lastIndexOf("/") + 1)
  var dot = name.lastIndexOf(".")
  return dot > 0 ? name.slice(0, dot) : name
}

function songArtist(song) {
  return song ? (song.artist || song.albumartist || "") : ""
}

function songYear(song) {
  var match = song && song.date ? String(song.date).match(/^\d{4}/) : null
  return match ? match[0] : ""
}

if (typeof module !== "undefined") {
  module.exports = {
    isForbidden: isForbidden,
    quote: quote,
    command: command,
    commandList: commandList,
    commandWord: commandWord,
    commandListOk: commandListOk,
    splitReplies: splitReplies,
    tagFilter: tagFilter,
    andFilter: andFilter,
    yearPattern: yearPattern,
    yearFilter: yearFilter,
    withYear: withYear,
    afterYearFilter: afterYearFilter,
    inYear: inYear,
    parseObject: parseObject,
    parseSongs: parseSongs,
    parseValues: parseValues,
    parseFileSizes: parseFileSizes,
    parseStickers: parseStickers,
    foldersOf: foldersOf,
    parseGrouped: parseGrouped,
    parseRows: parseRows,
    parseCounts: parseCounts,
    parseStatus: parseStatus,
    fold: fold,
    searchPattern: searchPattern,
    matchRank: matchRank,
    sortByMatch: sortByMatch,
    queueCommands: queueCommands,
    mergeAlbums: mergeAlbums,
    sharedName: sharedName,
    albumsSharingName: albumsSharingName,
    albumOrder: albumOrder,
    trackNumber: trackNumber,
    songSeconds: songSeconds,
    groupAlbums: groupAlbums,
    splitAppearances: splitAppearances,
    unionSongs: unionSongs,
    filesOf: filesOf,
    sortGenreAlbums: sortGenreAlbums,
    isVarious: isVarious,
    genreArtists: genreArtists,
    genreCommands: genreCommands,
    randomSongCommands: randomSongCommands,
    parsePlaylists: parsePlaylists,
    byName: byName,
    recentFirst: recentFirst,
    nameMatches: nameMatches,
    validPlaylistName: validPlaylistName,
    isMissing: isMissing,
    playlistQueueCommands: playlistQueueCommands,
    playlistAddCommands: playlistAddCommands,
    artistFiles: artistFiles,
    directoryOf: directoryOf,
    isLocalFile: isLocalFile,
    pickCover: pickCover,
    fileUrl: fileUrl,
    formatTime: formatTime,
    formatTotal: formatTotal,
    formatCount: formatCount,
    songTitle: songTitle,
    songArtist: songArtist,
    songYear: songYear
  }
}
