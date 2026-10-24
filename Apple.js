// Apple Music for the panel: rows and views built from the bridge's objects
// (bridge/API.md), and the bridge's status in the shape the player card and
// the bar read from mpd. Pure functions, so node can test them
// (tests/apple.test.js).
//
// Spotify's service (spotify/omarock-spotify.py) speaks the same API, so these
// serve it too: the functions that name the service take its name (service),
// "Apple Music" when left out.

var EXPLICIT = "󰬌"
// A song the bridge found it can't play (no Apple Music copy it may stream);
// its row is dimmed, like a local song that has left the library.
var UNPLAYABLE = "Not available to play"

// Apple's artwork URLs are templates; px is the size on screen, so ask for
// twice that, for sharp covers on HiDPI screens.
function artUrl(artwork, px) {
  if (!artwork || !artwork.url) return ""
  var size = Math.max(16, Math.round(px * 2))
  var maxSize = artwork.width > 0 ? Math.min(size, artwork.width) : size
  return artwork.url.split("{w}").join(maxSize).split("{h}").join(maxSize)
    .split("{c}").join("bb").split("{f}").join("jpg")
}

// What the bridge plays: { kind, id, source }.
function ref(item) {
  return { kind: item.kind, id: item.id, source: item.source }
}

// A song's identity across the catalog and the library, to mark the one
// playing in any list ("file" on rows, like mpd's).
function songKey(song) {
  return song ? "apple:" + (song.catalogId || song.id) : ""
}

function formatTime(seconds) {
  seconds = Math.max(0, Math.floor(seconds || 0))
  var h = Math.floor(seconds / 3600)
  var m = Math.floor(seconds / 60) % 60
  var s = seconds % 60
  return (h > 0 ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (s < 10 ? "0" : "") + s
}

function formatTotal(seconds) {
  var minutes = Math.round((seconds || 0) / 60)
  if (minutes < 60) return minutes + " min"
  return Math.floor(minutes / 60) + " h " + (minutes % 60) + " min"
}

function countText(n, word) {
  return n + " " + word + (n === 1 ? "" : "s")
}

function totalSeconds(songs) {
  var seconds = 0
  songs.forEach(function(song) { seconds += song.duration || 0 })
  return seconds
}

// A name to show: a library can have albums with no title, and playlists
// named " ".
function nameOf(item) {
  var name = String(item.title || item.name || "").trim()
  if (name !== "") return name
  return item.kind === "album" ? "Untitled album" : item.kind === "playlist" ? "Untitled playlist" : "Untitled"
}

function titleOf(item) {
  var title = nameOf(item)
  return item.explicit ? title + " " + EXPLICIT : title
}

function yearOf(item) {
  return item.year ? String(item.year) : ""
}

function join(parts) {
  return parts.filter(function(part) { return part !== "" && part !== undefined && part !== null }).join(" · ")
}

// An album's kind of release, after its year.
function releaseKind(album) {
  if (album.isSingle) return "Single"
  if (album.isCompilation) return "Compilation"
  return ""
}

function songRow(song, section) {
  return { kind: "song", section: section || "", lead: "󰝚", title: titleOf(song), name: nameOf(song),
    subtitle: join([song.artist, song.album]), detail: formatTime(song.duration),
    file: songKey(song), apple: ref(song), artwork: song.artwork, item: song }
}

// How many songs, so a one-song "album" shows before it's opened: the songs
// you have of a library album, the whole album's of a catalog one. songs
// replaces it ("1 of 12 songs").
function albumRow(album, section, showArtist, songs) {
  return { kind: "album", section: section || "", lead: "󰀥", title: titleOf(album), name: nameOf(album),
    subtitle: join([showArtist === false ? "" : album.artist, yearOf(album), releaseKind(album),
      songs !== undefined ? songs : album.trackCount > 0 ? countText(album.trackCount, "song") : ""]),
    apple: ref(album), artwork: album.artwork, item: album }
}

function artistRow(artist, section) {
  return { kind: "artist", section: section || "", lead: "󰠃", title: artist.name, name: artist.name,
    subtitle: (artist.genres || [])[0] || "", apple: ref(artist), artwork: artist.artwork }
}

function playlistRow(playlist, section) {
  var parts = []
  if (playlist.source === "catalog" && playlist.curator) parts.push(playlist.curator)
  if (playlist.trackCount > 0) parts.push(countText(playlist.trackCount, "song"))
  return { kind: "playlist", section: section || "", lead: "󰲸", title: nameOf(playlist), name: nameOf(playlist),
    subtitle: join(parts), apple: ref(playlist), artwork: playlist.artwork, playlistName: playlist.name }
}

function genreRow(genre, section) {
  return { kind: "genre", section: section || "", lead: "󰓹", title: genre.name, name: genre.name,
    subtitle: "Apple Music charts", apple: { kind: "genre", id: genre.id, source: "catalog" }, noQueue: true }
}

// Genres whose name matches the query, from the bridge's genre list.
function matchGenres(genres, query, fold) {
  var q = fold(query.trim())
  if (q === "") return []
  return (genres || []).filter(function(genre) { return fold(genre.name).indexOf(q) >= 0 })
}

// For matching names across the library and the catalog: case, accents and
// spacing don't count.
function foldKey(text) {
  var s = String(text || "").toLowerCase()
  if (typeof s.normalize === "function") s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, "")
  return s.replace(/\s+/g, " ").trim()
}

function itemKey(item) {
  return foldKey(item.title || item.name) + "\u0000" + foldKey(item.artist)
}

// Search results: your library first (what you picked), then Apple Music.
// An album or song you own is listed once, as yours: by catalog id when the
// bridge has one, else by title and artist. So is an artist, by name: yours
// opens to your albums and the catalog's together.
function searchRows(results, genres, service) {
  service = service || "Apple Music"
  var upper = service.toUpperCase()
  var library = results.library || {}
  var catalog = results.catalog || {}
  var owned = {}
  ;["songs", "playlists"].forEach(function(type) {
    (library[type] || []).forEach(function(item) {
      if (item.catalogId) owned[item.catalogId] = true
      if (type !== "playlists") owned[type + "\u0000" + itemKey(item)] = true
    })
  })
  function fresh(items, type) {
    return (items || []).filter(function(item) {
      return !owned[item.id] && !(type && owned[type + "\u0000" + itemKey(item)])
    })
  }
  // An album you have only part of is in both lists.
  var albumCounts = ownedCounts(library.albums || [], itemKey)
  function catalogAlbumRow(album, section) {
    var row = albumRow(album, section)
    var have = songsOwned(albumCounts, album, itemKey)
    if (have >= 0) row.subtitle = join([row.subtitle, "you have " + have])
    return row
  }
  var catalogAlbums = (catalog.albums || []).filter(function(album) {
    var have = songsOwned(albumCounts, album, itemKey)
    return have < 0 || partly(album, have)
  })
  var rows = []
  function add(items, section, make) {
    items.forEach(function(item, i) { rows.push(make(item, i === 0 ? section : "")) })
  }
  add(library.playlists || [], "YOUR PLAYLISTS", playlistRow)
  add(library.artists || [], "YOUR ARTISTS", artistRow)
  add(library.albums || [], "YOUR ALBUMS", function(a, s) { return albumRow(a, s) })
  add(library.songs || [], "YOUR SONGS", songRow)
  add(genres || [], "GENRES", genreRow)
  var yourArtists = {}
  ;(library.artists || []).forEach(function(artist) { yourArtists[foldKey(artist.name)] = true })
  add((catalog.artists || []).filter(function(artist) { return !yourArtists[foldKey(artist.name)] }),
    upper + " · ARTISTS", artistRow)
  add(catalogAlbums, upper + " · ALBUMS", catalogAlbumRow)
  add(fresh(catalog.songs, "songs"), upper + " · SONGS", songRow)
  add(fresh(catalog.playlists), upper + " · PLAYLISTS", playlistRow)
  // Before the bridge can reach the catalog, the library still searches.
  if (results.catalogError)
    rows.push({ kind: "note", section: upper, lead: "󰋼", title: "The " + service + " catalog isn't available",
      subtitle: results.catalogError })
  return rows
}

// The album view: Play the album, then its songs, by disc when it has several.
function albumView(album, tracks, service) {
  var artists = {}
  var discs = {}
  tracks.forEach(function(song) {
    artists[song.artist || ""] = true
    discs[song.discNumber || 1] = true
  })
  var various = Object.keys(artists).length > 1
  var multiDisc = Object.keys(discs).length > 1
  var rows = []
  if (tracks.length > 0)
    rows.push({ kind: "playalbum", lead: "󰐊", title: "Play the album",
      subtitle: countText(tracks.length, "song") + " · " + formatTotal(totalSeconds(tracks)) })
  var lastDisc = 0
  tracks.forEach(function(song, i) {
    var disc = song.discNumber || 1
    var unplayable = song.playable === false
    rows.push({ kind: "track", section: multiDisc && disc !== lastDisc ? "DISC " + disc : "",
      lead: String(song.trackNumber || i + 1), title: titleOf(song), name: song.title,
      subtitle: unplayable ? UNPLAYABLE : various ? song.artist || "" : "",
      detail: unplayable ? "" : formatTime(song.duration), file: songKey(song), apple: ref(song), position: i,
      playable: !unplayable, missing: unplayable, item: song })
    lastDisc = disc
  })
  return { rows: rows, info: {
    title: nameOf(album), artwork: album.artwork, item: album,
    subtitle: join([album.artist, yearOf(album), (album.genres || [])[0]]),
    detail: join([album.recordLabel, album.audioTraits && album.audioTraits.indexOf("lossless") >= 0 ? "Lossless" : "",
      album.audioTraits && album.audioTraits.indexOf("atmos") >= 0 ? "Dolby Atmos" : ""]),
    notes: album.editorialNotes || "", copyright: album.copyright || "",
    emptyText: (service || "Apple Music") + " lists no songs for this album." } }
}

function byYear(a, b) {
  return (a.year || 0) - (b.year || 0)
}

// A single or an EP: Apple marks singles, and names EPs "… - EP".
function isShort(album) {
  return album.isSingle === true || / - (single|ep)$/i.test(album.title || album.name || "")
}

// Play top songs, then the first five.
function topSongRows(top) {
  var rows = []
  if (top.length === 0) return rows
  rows.push({ kind: "playall", lead: "󰐊", title: "Play top songs", subtitle: countText(top.length, "song") })
  top.slice(0, 5).forEach(function(song, i) {
    var row = songRow(song, i === 0 ? "TOP SONGS" : "")
    row.subtitle = song.album || ""
    rows.push(row)
  })
  return rows
}

// The artist view: their top songs, then albums by year (singles and EPs
// after the albums), then the albums they appear on.
function artistView(artist, data, service) {
  var rows = topSongRows(data.topSongs || [])
  var albums = (data.albums || []).slice().sort(byYear)
  var full = albums.filter(function(album) { return !isShort(album) })
  var singles = albums.filter(isShort)
  full.forEach(function(album, i) { rows.push(albumRow(album, i === 0 ? "ALBUMS" : "", false)) })
  singles.forEach(function(album, i) { rows.push(albumRow(album, i === 0 ? "SINGLES & EPS" : "", false)) })
  ;(data.appearsOn || []).forEach(function(album, i) { rows.push(albumRow(album, i === 0 ? "APPEARS ON" : "")) })
  return { rows: rows, info: {
    title: artist.name, artwork: artist.artwork,
    subtitle: join(["Artist", (artist.genres || [])[0]]),
    detail: artist.source === "library" ? "In your library" : "",
    notes: artist.editorialNotes || "",
    emptyText: (service || "Apple Music") + " lists nothing for this artist." } }
}

// The same artist on the other side (side is "library" or "catalog") of a
// search's results: the one whose name matches, case and accents aside.
function findArtist(results, side, name) {
  var key = foldKey(name)
  if (key === "") return null
  var artists = ((results || {})[side] || {}).artists || []
  for (var i = 0; i < artists.length; i++)
    if (foldKey(artists[i].name) === key) return artists[i]
  return null
}

// An album as the library and the catalog both name it: "Lvl IV" is
// "LVL IV", and "Let Me Out - Single" is "Let Me Out".
function albumKey(album) {
  return foldKey(album.title || album.name).replace(/ - (single|ep)$/, "")
}

// The songs you have of each album in your library, under its catalog id
// and key(album): the most of any copy (you may have two).
function ownedCounts(albums, key) {
  var counts = {}
  albums.forEach(function(album) {
    var n = album.trackCount || 0
    ;[album.catalogId, key(album)].forEach(function(k) {
      if (k) counts[k] = Math.max(counts[k] || 0, n)
    })
  })
  return counts
}

// How many of a catalog album's songs you have, from ownedCounts: -1 for
// none, and its whole count when a copy has them all (or doesn't say).
function songsOwned(counts, album, key) {
  var n = Math.max(counts[album.id] === undefined ? -1 : counts[album.id],
    counts[key(album)] === undefined ? -1 : counts[key(album)])
  if (n < 0) return -1
  return n > 0 && album.trackCount > n ? n : album.trackCount || n
}

// You have only some of its songs: listed with the catalog's albums too.
function partly(album, have) {
  return have >= 0 && album.trackCount > 0 && have < album.trackCount
}

// One artist from both sides, each { artist, data } as the bridge's artist
// route gives it: the catalog's top songs, your albums, then the catalog's
// albums you don't have, its singles and EPs, and the albums they appear on.
function mergedArtistView(mine, theirs, service) {
  service = service || "Apple Music"
  var top = theirs.data.topSongs || []
  var rows = topSongRows(top.length > 0 ? top : mine.data.topSongs || [])
  var yours = (mine.data.albums || []).slice().sort(byYear)
  var catalog = theirs.data.albums || []
  // An album you have all of is yours only; one you have part of is in both
  // lists, each saying how much you have.
  var counts = ownedCounts(yours, albumKey)
  var whole = {}
  catalog.forEach(function(album) {
    ;[album.id, albumKey(album)].forEach(function(k) { whole[k] = Math.max(whole[k] || 0, album.trackCount || 0) })
  })
  var others = catalog.filter(function(album) {
    var have = songsOwned(counts, album, albumKey)
    return have < 0 || partly(album, have)
  }).sort(byYear)
  var full = others.filter(function(album) { return !isShort(album) })
  var singles = others.filter(isShort)
  function theirRow(album, section) {
    var row = albumRow(album, section, false)
    var have = songsOwned(counts, album, albumKey)
    if (have >= 0) row.subtitle = join([row.subtitle, "you have " + have])
    return row
  }
  yours.forEach(function(album, i) {
    var of = Math.max(whole[album.catalogId] || 0, whole[albumKey(album)] || 0)
    rows.push(albumRow(album, i === 0 ? "YOUR ALBUMS" : "", false,
      album.trackCount > 0 && of > album.trackCount ? album.trackCount + " of " + of + " songs" : undefined))
  })
  full.forEach(function(album, i) { rows.push(theirRow(album, i === 0 ? "ON " + service.toUpperCase() : "")) })
  singles.forEach(function(album, i) { rows.push(theirRow(album, i === 0 ? "SINGLES & EPS" : "")) })
  ;(theirs.data.appearsOn || []).forEach(function(album, i) { rows.push(albumRow(album, i === 0 ? "APPEARS ON" : "")) })
  var artist = theirs.artist
  return { rows: rows, info: {
    title: artist.name || mine.artist.name, artwork: artist.artwork || mine.artist.artwork,
    subtitle: join(["Artist", (artist.genres || mine.artist.genres || [])[0]]),
    detail: "In your library",
    notes: artist.editorialNotes || "",
    emptyText: service + " lists nothing for this artist." } }
}

// A playlist's view: Play the playlist, then its songs, each with its cover.
// note: why the songs aren't listed (Spotify lists them only for your own
// playlists); the playlist still plays.
function playlistView(playlist, tracks, note) {
  var rows = []
  if (tracks.length > 0)
    rows.push({ kind: "playplaylist", lead: "󰐊", title: "Play the playlist",
      subtitle: countText(tracks.length, "song") + " · " + formatTotal(totalSeconds(tracks)) })
  else if (note) {
    rows.push({ kind: "playplaylist", lead: "󰐊", title: "Play the playlist",
      subtitle: playlist.trackCount > 0 ? countText(playlist.trackCount, "song") : "" })
    rows.push({ kind: "note", lead: "󰋼", title: "Its songs aren't listed", subtitle: note })
  }
  tracks.forEach(function(song, i) {
    var unplayable = song.playable === false
    rows.push({ kind: "track", lead: String(i + 1), title: titleOf(song), name: song.title,
      subtitle: unplayable ? UNPLAYABLE : join([song.artist, song.album]),
      detail: unplayable ? "" : formatTime(song.duration), file: songKey(song), apple: ref(song), position: i,
      artwork: song.artwork, playable: !unplayable, missing: unplayable, item: song })
  })
  return { rows: rows, info: {
    title: nameOf(playlist), artwork: playlist.artwork,
    subtitle: join(["Playlist", countText(tracks.length, "song"), tracks.length > 0 ? formatTotal(totalSeconds(tracks)) : ""]),
    detail: playlist.source === "catalog" ? playlist.curator || "" : "",
    notes: playlist.description || "",
    emptyText: "This playlist is empty. Find a song, album or artist and press A to add it." } }
}

// Your Apple Music playlists: Save the queue as one, then the playlists by name.
function playlistsView(playlists, queueLength, service) {
  service = service || "Apple Music"
  var rows = [{ kind: "savequeue", lead: "󰆓", title: "Save the queue as a playlist",
    subtitle: queueLength > 0 ? countText(queueLength, "song") + " in the queue" : "The queue is empty" }]
  var sorted = playlists.slice().sort(function(a, b) { return nameOf(a).toLowerCase() < nameOf(b).toLowerCase() ? -1 : 1 })
  sorted.forEach(function(playlist, i) { rows.push(playlistRow(playlist, i === 0 ? "YOUR PLAYLISTS" : "")) })
  if (playlists.length === 0)
    rows.push({ kind: "note", lead: "󰋼", title: "No " + service + " playlists yet",
      subtitle: "Press A on a song, album or artist to start one" })
  return { rows: rows, info: {
    title: service + " playlists", subtitle: playlists.length === 0 ? "None yet" : countText(playlists.length, "playlist") } }
}

// A genre: Apple Music's charts for it.
function genreView(genre, data) {
  var rows = []
  ;(data.albums || []).forEach(function(album, i) { rows.push(albumRow(album, i === 0 ? "TOP ALBUMS" : "")) })
  ;(data.songs || []).forEach(function(song, i) { rows.push(songRow(song, i === 0 ? "TOP SONGS" : "")) })
  return { rows: rows, info: { title: genre.name, subtitle: "Genre · Apple Music charts",
    emptyText: "Apple Music has no charts for this genre." } }
}

// The bridge's queue as queue rows; index is the position in the whole queue.
function queueRows(status) {
  var offset = status.queueOffset || 0
  return (status.queue || []).map(function(song, i) {
    return { kind: "queue", index: offset + i, lead: String(offset + i + 1), title: titleOf(song), name: song.title,
      subtitle: join([song.artist, song.album]), detail: formatTime(song.duration),
      file: songKey(song), apple: ref(song), artwork: song.artwork, item: song,
      playing: status.state !== "stopped" && offset + i === status.queueIndex }
  })
}

// The current song, as mpd's currentsong would have it.
function songAsMpd(song) {
  if (!song) return {}
  return { file: songKey(song), title: song.title || "", artist: song.artist || "", album: song.album || "",
    date: yearOf(song), genre: (song.genres || [])[0] || "" }
}

// The bridge's status, as mpd's status would have it, with the volume given
// (mpd's, or Spotify's own).
// Playing on another machine (status.elsewhere) is paused here.
function statusAsMpd(status, volume) {
  var state = status.state === "playing" && !status.elsewhere ? "play"
    : status.state === "playing" || status.state === "paused" ? "pause" : "stop"
  return { state: state, volume: volume, elapsed: status.position || 0,
    duration: status.song ? status.song.duration || 0 : 0,
    song: status.song ? status.queueIndex : -1, songId: status.song ? songKey(status.song) : "",
    random: status.shuffle === true, repeat: status.repeat === "all" || status.repeat === "one",
    single: false, consume: false, queueLength: status.queueLength || 0, updating: false, error: "" }
}

// Badges for the now playing card: Explicit, Lossless, Dolby Atmos.
function badges(song) {
  if (!song) return ""
  var traits = song.audioTraits || []
  return join([song.explicit ? "Explicit" : "", traits.indexOf("lossless") >= 0 || traits.indexOf("hi-res-lossless") >= 0 ? "Lossless" : "",
    traits.indexOf("atmos") >= 0 ? "Dolby Atmos" : ""])
}

if (typeof module !== "undefined") {
  module.exports = {
    artUrl: artUrl,
    nameOf: nameOf,
    ref: ref,
    songKey: songKey,
    formatTime: formatTime,
    formatTotal: formatTotal,
    songRow: songRow,
    albumRow: albumRow,
    artistRow: artistRow,
    playlistRow: playlistRow,
    genreRow: genreRow,
    matchGenres: matchGenres,
    foldKey: foldKey,
    searchRows: searchRows,
    albumView: albumView,
    artistView: artistView,
    findArtist: findArtist,
    mergedArtistView: mergedArtistView,
    playlistView: playlistView,
    playlistsView: playlistsView,
    genreView: genreView,
    queueRows: queueRows,
    songAsMpd: songAsMpd,
    statusAsMpd: statusAsMpd,
    badges: badges
  }
}
