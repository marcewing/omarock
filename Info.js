// The info card (i): everything omarock knows about a song, album, station
// or channel, as { service, serviceName, kindName, status, statusKind, title,
// lines, groups: [{ title, fields: [{ label, value }] }], notes }. At the top,
// the card says which service it is and, for Apple Music and Spotify, whether
// it is in your library. Pure functions, so node can test them
// (tests/info.test.js).

var SERVICES = {
  local: { name: "Local music", icon: "󱍙" },
  apple: { name: "Apple Music", icon: "󰀵" },
  spotify: { name: "Spotify", icon: "󰓇" },
  sxm: { name: "SiriusXM", icon: "󰑱" },
  radio: { name: "Radio", icon: "󰐹" }
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function present(value) {
  return value !== undefined && value !== null && String(value).trim() !== ""
}

function field(label, value) {
  return present(value) ? { label: label, value: String(value) } : null
}

function group(title, fields) {
  return { title: title, fields: fields.filter(function(f) { return f !== null }) }
}

// The card, with empty groups dropped.
function card(service, kindName, title, lines, groups, extra) {
  var out = { service: service, serviceName: SERVICES[service].name, icon: SERVICES[service].icon,
    kindName: kindName, title: title, status: "", statusKind: "",
    lines: lines.filter(present),
    groups: groups.filter(function(g) { return g.fields.length > 0 }), notes: "" }
  return Object.assign(out, extra || {})
}

function join(parts, separator) {
  return parts.filter(present).join(separator || " · ")
}

function pad(n) {
  return (n < 10 ? "0" : "") + n
}

// "18 Oct 2026"; with time, "18 Oct 2026, 21:40" in local time. Dates
// without a time (a release date, "1984") stay as they are.
function formatDate(text, withTime) {
  if (!present(text)) return ""
  var s = String(text)
  if (/^\d{4}$/.test(s)) return s
  var day = s.match(/^(\d{4})-(\d{2})-(\d{2})$/)
  if (day) return parseInt(day[3], 10) + " " + MONTHS[parseInt(day[2], 10) - 1] + " " + day[1]
  var d = new Date(s)
  if (isNaN(d.getTime())) return s
  var out = d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear()
  return withTime ? out + ", " + pad(d.getHours()) + ":" + pad(d.getMinutes()) : out
}

function formatLength(seconds) {
  seconds = Math.max(0, Math.round(seconds || 0))
  var h = Math.floor(seconds / 3600)
  var m = Math.floor(seconds / 60) % 60
  var s = seconds % 60
  return h > 0 ? h + ":" + pad(m) + ":" + pad(s) : m + ":" + pad(s)
}

function formatTotal(seconds) {
  var minutes = Math.round((seconds || 0) / 60)
  if (minutes < 60) return minutes + " min"
  return Math.floor(minutes / 60) + " h " + (minutes % 60) + " min"
}

function formatBytes(bytes) {
  if (!(bytes > 0)) return ""
  if (bytes < 1024 * 1024) return Math.max(1, Math.round(bytes / 1024)) + " KB"
  if (bytes < 1024 * 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + " MB"
  return (bytes / 1024 / 1024 / 1024).toFixed(2) + " GB"
}

function plural(n, word) {
  return n + " " + word + (n === 1 ? "" : "s")
}

function formatRate(rate) {
  return rate > 0 ? (rate % 1000 === 0 ? rate / 1000 : (rate / 1000).toFixed(1)) + " kHz" : ""
}

// mpd's audio format, "44100:16:2", as "44.1 kHz · 16-bit · stereo".
function formatAudio(format) {
  if (!present(format)) return ""
  var parts = String(format).split(":")
  if (parts.length !== 3) return String(format)
  var rateText = formatRate(parseInt(parts[0], 10))
  var bits = parts[1] === "f" ? "32-bit float" : parts[1] === "dsd" ? "DSD" : parts[1] + "-bit"
  var channels = parts[2] === "1" ? "mono" : parts[2] === "2" ? "stereo" : parts[2] + " channels"
  return join([rateText, bits, channels])
}

var FILE_TYPES = { mp3: "MP3", m4a: "M4A (AAC or Apple Lossless)", aac: "AAC", flac: "FLAC", ogg: "Ogg",
  oga: "Ogg", opus: "Opus", wav: "WAV", aif: "AIFF", aiff: "AIFF", wma: "WMA", ape: "Monkey's Audio",
  wv: "WavPack", dsf: "DSD", dff: "DSD", mpc: "Musepack" }

function fileType(file) {
  var name = String(file || "")
  var dot = name.lastIndexOf(".")
  if (dot < 0 || name.indexOf("://") >= 0) return ""
  var ext = name.slice(dot + 1).toLowerCase()
  return FILE_TYPES[ext] || ext.toUpperCase()
}

// The average bitrate from the file's size and length: "256 kbps".
function averageBitrate(bytes, seconds) {
  if (!(bytes > 0) || !(seconds > 0)) return ""
  return Math.round(bytes * 8 / seconds / 1000) + " kbps"
}

function songSeconds(song) {
  return parseFloat(song.duration || song.time || 0) || 0
}

function trackText(track, disc) {
  var t = parseInt(track, 10)
  var d = parseInt(disc, 10)
  if (!(t > 0)) return d > 0 ? "Disc " + d : ""
  return d > 0 ? t + " (disc " + d + ")" : String(t)
}

// mpd's tag names (lowercased by Mpd.parseSongs) the card lays out itself;
// any other tag goes under OTHER TAGS.
var MPD_SHOWN = ["file", "title", "artist", "albumartist", "album", "track", "disc", "date", "originaldate",
  "genre", "composer", "performer", "conductor", "work", "movement", "movementnumber", "showmovement",
  "ensemble", "location", "grouping", "label", "mood", "comment", "time", "duration", "format",
  "last-modified", "added", "pos", "id", "prio", "range", "name",
  "artistsort", "albumsort", "albumartistsort", "titlesort", "composersort"]
var MUSICBRAINZ = [["musicbrainz_trackid", "MusicBrainz recording"], ["musicbrainz_releasetrackid", "MusicBrainz track"],
  ["musicbrainz_albumid", "MusicBrainz release"], ["musicbrainz_releasegroupid", "MusicBrainz release group"],
  ["musicbrainz_artistid", "MusicBrainz artist"], ["musicbrainz_albumartistid", "MusicBrainz album artist"],
  ["musicbrainz_workid", "MusicBrainz work"]]

function capitalized(key) {
  return key.charAt(0).toUpperCase() + key.slice(1)
}

function otherTags(song) {
  var known = MPD_SHOWN.concat(MUSICBRAINZ.map(function(m) { return m[0] }))
  return Object.keys(song).filter(function(key) { return known.indexOf(key) < 0 }).sort()
    .map(function(key) { return field(capitalized(key), song[key]) })
}

// A local song. song: mpd's song (lsinfo, with Format, Added and
// Last-Modified); extra: { size (bytes, from listfiles), stickers: { name:
// value }, musicDirectory }.
function localSong(song, extra) {
  extra = extra || {}
  var seconds = songSeconds(song)
  var artist = song.artist || song.albumartist || ""
  var title = song.title || String(song.file || "").replace(/^.*\//, "").replace(/\.[^.]*$/, "")
  var year = song.date ? String(song.date).slice(0, 4) : ""
  var stickers = extra.stickers || {}
  var path = extra.musicDirectory ? extra.musicDirectory.replace(/\/$/, "") + "/" + song.file : song.file
  return card("local", "Song", title, [artist, join([song.album, year])], [
    group("SONG", [
      field("Artist", artist),
      song.albumartist && song.albumartist !== artist ? field("Album artist", song.albumartist) : null,
      field("Album", song.album),
      field("Track", trackText(song.track, song.disc)),
      field("Date", song.date),
      song.originaldate && song.originaldate !== song.date ? field("Original date", song.originaldate) : null,
      field("Genre", song.genre),
      field("Composer", song.composer),
      field("Performer", song.performer),
      field("Conductor", song.conductor),
      field("Ensemble", song.ensemble),
      field("Work", join([song.work, song.movementnumber ? "movement " + song.movementnumber : "", song.movement])),
      field("Grouping", song.grouping),
      field("Label", song.label),
      field("Mood", song.mood),
      field("Comment", song.comment),
      field("Length", seconds > 0 ? formatLength(seconds) : "")
    ]),
    group("FILE", [
      field("Type", join([fileType(song.file), formatAudio(song.format)])),
      field("Bitrate", averageBitrate(extra.size, seconds) ? averageBitrate(extra.size, seconds) + " (average)" : ""),
      field("Size", formatBytes(extra.size)),
      field("Path", path),
      field("Added to mpd", formatDate(song.added)),
      field("Modified", formatDate(song["last-modified"]))
    ]),
    group("OTHER TAGS", otherTags(song)),
    group("IDENTIFIERS", MUSICBRAINZ.map(function(m) { return field(m[1], song[m[0]]) })),
    group("STICKERS", Object.keys(stickers).sort().map(function(name) { return field(name, stickers[name]) }))
  ])
}

// The values the songs have for one tag, most common first.
function valuesOf(songs, key) {
  var counts = {}
  var order = []
  songs.forEach(function(song) {
    String(song[key] || "").split(", ").forEach(function(value) {
      if (value === "") return
      if (counts[value] === undefined) { counts[value] = 0; order.push(value) }
      counts[value]++
    })
  })
  return order.sort(function(a, b) { return counts[b] - counts[a] })
}

function listText(values, most) {
  if (values.length <= most) return values.join(", ")
  return values.slice(0, most).join(", ") + " and " + (values.length - most) + " more"
}

function range(values) {
  var sorted = values.slice().sort()
  if (sorted.length === 0) return ""
  return sorted[0] === sorted[sorted.length - 1] ? sorted[0] : sorted[0] + "–" + sorted[sorted.length - 1]
}

// A local album. songs: mpd's songs of the album; extra: { size (bytes, all
// its files), folders: [paths], cover: the cover file's name or "" }.
function localAlbum(songs, extra) {
  extra = extra || {}
  var seconds = 0
  var counts = {}
  songs.forEach(function(song) {
    seconds += songSeconds(song)
    var artist = song.albumartist || song.artist || ""
    counts[artist] = (counts[artist] || 0) + 1
  })
  var top = Object.keys(counts).sort(function(a, b) { return counts[b] - counts[a] })[0] || ""
  var albumArtist = top !== "" && counts[top] * 2 > songs.length ? top : "Various artists"
  var artists = valuesOf(songs, "artist")
  var years = valuesOf(songs, "date").map(function(d) { return d.slice(0, 4) })
  var discs = valuesOf(songs, "disc")
  var types = valuesOf(songs, "file").map(fileType).filter(function(t, i, all) { return t !== "" && all.indexOf(t) === i })
  var formats = valuesOf(songs, "format").map(formatAudio)
  var added = valuesOf(songs, "added").sort()
  var modified = valuesOf(songs, "last-modified").sort()
  var folders = extra.folders || []
  var title = songs.length > 0 && songs[0].album ? songs[0].album : "Songs without an album"
  return card("local", "Album", title, [albumArtist, range(years)], [
    group("ALBUM", [
      field("Album artist", albumArtist),
      artists.length > 1 ? field("Artists", listText(artists, 6)) : null,
      field("Year", range(years)),
      field("Genre", listText(valuesOf(songs, "genre"), 3)),
      field("Label", listText(valuesOf(songs, "label"), 3)),
      field("Songs", songs.length > 0 ? String(songs.length) : ""),
      discs.length > 1 ? field("Discs", String(discs.length)) : null,
      field("Length", seconds > 0 ? formatTotal(seconds) : "")
    ]),
    group("FILES", [
      field("Type", join([types.join(", "), formats.length === 1 ? formats[0] : formats.length > 1 ? "mixed formats" : ""])),
      field("Bitrate", averageBitrate(extra.size, seconds) ? averageBitrate(extra.size, seconds) + " (average)" : ""),
      field("Size", formatBytes(extra.size)),
      field(folders.length > 1 ? "Folders" : "Folder", folders.length > 1 ? folders.length + ": " + listText(folders, 3) : folders[0]),
      field("Cover", extra.cover === undefined ? "" : extra.cover !== "" ? extra.cover : "None in the folder"),
      field("Added to mpd", added.length > 0 ? formatDate(added[0]) : ""),
      field("Modified", modified.length > 0 ? formatDate(modified[modified.length - 1]) : "")
    ]),
    group("IDENTIFIERS", [
      field("MusicBrainz release", listText(valuesOf(songs, "musicbrainz_albumid"), 2)),
      field("MusicBrainz release group", listText(valuesOf(songs, "musicbrainz_releasegroupid"), 2)),
      field("MusicBrainz album artist", listText(valuesOf(songs, "musicbrainz_albumartistid"), 2))
    ])
  ])
}

var TRAITS = { "lossless": "Lossless", "hi-res-lossless": "Hi-Res Lossless", "lossy-stereo": "AAC",
  "atmos": "Dolby Atmos", "dolby-audio": "Dolby Audio", "spatial": "Spatial Audio" }

function traitsText(traits) {
  return (traits || []).map(function(t) { return TRAITS[t] || t }).join(", ")
}

// A library rating, 0 to 100, as stars.
function stars(rating) {
  var n = Math.round((rating || 0) / 20)
  if (!(n > 0)) return ""
  return "★★★★★".slice(0, n) + "☆☆☆☆☆".slice(0, 5 - n)
}

function yesNo(value) {
  return value === true ? "Yes" : value === false ? "No" : ""
}

// Whether an Apple Music item is in the library, for the top of the card:
// [text, kind] where kind is "yes", "no", "checking" or "unknown". What the
// service says outranks the row's source: a Spotify song taken out of the
// library still has a library row's source.
function libraryStatus(item, extra) {
  if (extra.inLibrary === true) return ["In your library", "yes"]
  if (extra.inLibrary === false) return ["Not in your library", "no"]
  if (item.source === "library") return ["In your library", "yes"]
  if (extra.checking) return ["Checking your library…", "checking"]
  return ["Can't tell if it's in your library", "unknown"]
}

// An Apple Music song or album. item: the bridge's Song or Album; extra:
// the bridge's /v1/info answer (inLibrary, library, catalog), or
// { checking: true } while it's on its way. service: "apple", or "spotify"
// for omarock-spotify's, which has the same shape.
function appleItem(item, extra, service) {
  extra = extra || {}
  service = service || "apple"
  var serviceName = SERVICES[service].name
  var lib = extra.library || {}
  var isAlbum = item.kind === "album"
  var status = libraryStatus(item, extra)
  var title = String(item.title || item.name || "").trim() || (isAlbum ? "Untitled album" : "Untitled")
  var released = item.releaseDate ? formatDate(item.releaseDate) : item.year ? String(item.year) : ""
  var catalogId = (extra.catalog && extra.catalog.id) || item.catalogId || (item.source === "catalog" ? item.id : "")
  var libraryId = lib.id || (item.source === "library" ? item.id : "")
  var main = isAlbum
    ? group("ALBUM", [
        field("Artist", item.artist),
        field("Released", released),
        field("Genre", (item.genres || []).filter(function(g) { return g !== "Music" }).join(", ")),
        field("Songs", item.trackCount > 0 ? String(item.trackCount) : ""),
        field("Label", item.recordLabel),
        field("Copyright", item.copyright),
        field("Kind", item.isSingle ? "Single" : item.isCompilation ? "Compilation" : ""),
        field("Explicit", item.explicit ? "Yes" : "")
      ])
    : group("SONG", [
        field("Artist", item.artist),
        field("Album", item.album),
        field("Track", trackText(item.trackNumber, item.discNumber)),
        field("Released", released),
        field("Genre", (item.genres || []).filter(function(g) { return g !== "Music" }).join(", ")),
        field("Composer", item.composer),
        field("Length", item.duration > 0 ? formatLength(item.duration) : ""),
        field("Explicit", item.explicit ? "Yes" : ""),
        field("Playable", item.playable === false ? "No: " + serviceName + " won't stream it" : "")
      ])
  var apple = group(serviceName.toUpperCase(), [
    field("Audio", traitsText(item.audioTraits)),
    field("ISRC", item.isrc),
    field("Catalog id", catalogId),
    field("Link", extra.catalog && extra.catalog.url)
  ])
  var mine = group("YOUR LIBRARY", [
    field("Added", formatDate(lib.added)),
    isAlbum ? field("Songs you have", lib.trackCount > 0 ? plural(lib.trackCount, "song") + (item.trackCount > 0 ? " of " + item.trackCount : "") : "") : null,
    field("Plays", lib.playCount !== undefined ? String(lib.playCount) : ""),
    field("Skips", lib.skipCount > 0 ? String(lib.skipCount) : ""),
    field("Last played", formatDate(lib.lastPlayed, true)),
    field("Rating", stars(lib.rating)),
    // In the Music app's Favorite Songs playlist (once Loved Songs), per the bridge.
    field("Favourite", yesNo(lib.loved)),
    field("File", lib.fileKind),
    field("Bitrate", lib.bitrate > 0 ? lib.bitrate + " kbps" : ""),
    field("Sample rate", formatRate(lib.sampleRate)),
    field("Size", formatBytes(lib.fileSize)),
    field("In iCloud", yesNo(lib.cloud)),
    field("Purchased", lib.purchased ? "Yes" : ""),
    field("Protected (DRM)", yesNo(lib.drm)),
    field("Grouping", lib.grouping),
    field("BPM", lib.bpm > 0 ? String(lib.bpm) : ""),
    field("Comments", lib.comments),
    field("Modified", formatDate(lib.modified)),
    field("Library id", libraryId)
  ])
  var lines = isAlbum ? [item.artist, released] : [item.artist, join([item.album, item.year ? String(item.year) : ""])]
  return card(service, isAlbum ? "Album" : "Song", title, lines, [main, apple, mine],
    { status: status[0], statusKind: status[1], notes: item.editorialNotes || "" })
}

function favoriteStatus(favorite) {
  return favorite ? ["In your favourites", "yes"] : ["Not in your favourites", "no"]
}

// A station from Radio Browser. extra: { favorite, now: { artist, title }
// when it's the one playing }.
function station(st, extra) {
  extra = extra || {}
  var now = extra.now || {}
  var tags = String(st.tags || "").split(",").map(function(t) { return t.trim() }).filter(present)
  // "Oregon, US"; a station without a state gives its country's name.
  var place = st.state ? join([st.state, st.countrycode || st.country], ", ") : st.country || ""
  var status = favoriteStatus(extra.favorite)
  var codec = st.codec && st.codec !== "UNKNOWN" ? st.codec : ""
  var checked = st.lastcheckok === 1 ? "Working" : st.lastcheckok === 0 ? "Not working" : ""
  return card("radio", "Station", String(st.name || "").trim() || "Untitled station",
    [place, join([now.artist, now.title], " – ")], [
      group("ON NOW", [field("Artist", now.artist), field("Title", now.title)]),
      group("STATION", [
        field("Place", place),
        field("Language", st.language),
        field("Genres", tags.join(", ")),
        field("Website", st.homepage)
      ]),
      group("STREAM", [
        field("Format", join([codec, st.bitrate > 0 ? st.bitrate + " kbps" : ""])),
        field("HLS", st.hls === 1 ? "Yes: mpd can't play it" : ""),
        field("URL", st.url_resolved || st.url),
        field("Last check", join([checked, formatDate(st.lastchecktime_iso8601, true)]))
      ]),
      group("RADIO BROWSER", [
        field("Votes", st.votes > 0 ? String(st.votes) : ""),
        field("Listens", st.clickcount > 0 ? String(st.clickcount) : ""),
        field("Station id", st.stationuuid)
      ])
    ], { status: status[0], statusKind: status[1] })
}

// A SiriusXM channel from omarock-sxm. now: what's on it.
function channel(ch, now) {
  now = now || {}
  var status = favoriteStatus(ch.favorite === true)
  var nowLine = now.isAd ? "Ad break" : join([now.artist, now.title], " – ")
  return card("sxm", "Channel", ch.name || "Untitled channel",
    [join([ch.number ? "Channel " + ch.number : "", ch.genre]), nowLine || now.show || ""], [
      group("ON NOW", [
        field("Artist", now.isAd ? "" : now.artist),
        field("Title", now.isAd ? "Ad break" : now.title),
        field("Show", now.show),
        field("Started", formatDate(now.startedAt, true))
      ]),
      group("CHANNEL", [
        field("Number", ch.number),
        field("Genre", ch.genre),
        field("Short name", ch.shortName && ch.shortName !== ch.name ? ch.shortName : ""),
        field("Available", ch.available === false ? "No: not on your plan, or off the air" : ""),
        field("Channel id", ch.id)
      ])
    ], { status: status[0], statusKind: status[1], notes: ch.description || "" })
}

// Apple Music: whether a library search found the item (the fallback when
// the bridge has no /v1/info). results: the bridge's search answer.
function foundInLibrary(item, results, fold) {
  var type = item.kind === "album" ? "albums" : "songs"
  var key = function(x) { return fold(x.title || x.name || "") + "\u0000" + fold(x.artist || "") }
  var want = key(item)
  return ((results && results.library && results.library[type]) || []).some(function(x) {
    return (item.id && x.catalogId === item.id) || key(x) === want
  })
}

if (typeof module !== "undefined") {
  module.exports = {
    SERVICES: SERVICES,
    formatDate: formatDate,
    formatAudio: formatAudio,
    formatBytes: formatBytes,
    fileType: fileType,
    averageBitrate: averageBitrate,
    localSong: localSong,
    localAlbum: localAlbum,
    appleItem: appleItem,
    station: station,
    channel: channel,
    foundInLibrary: foundInLibrary,
    stars: stars
  }
}
