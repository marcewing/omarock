// Internet radio for the panel: stations from Radio Browser
// (radio-browser.info, a free community directory), and the station mpd
// plays, in the shape the player card and the bar read from mpd. Pure
// functions, so node can test them (tests/radio.test.js).
//
// A station queued by omarock is its stream URL with "#omarock-radio=<uuid>"
// after it. The server never sees what follows "#", and mpd keeps it, so the
// queue and the "Radio" playlist (the favourites) say which station it is.

var MARKER = "#omarock-radio="
var FAVORITE = "󰋑"

function streamUrl(station) {
  return station.url_resolved + MARKER + station.stationuuid
}

function uuidOf(file) {
  var at = (file || "").indexOf(MARKER)
  return at >= 0 ? file.slice(at + MARKER.length) : ""
}

function isRadio(file) {
  return uuidOf(file) !== ""
}

// mpd can't play HLS.
function playable(station) {
  return !!station.url_resolved && station.hls !== 1
}

function nameOf(station) {
  return String(station.name || "").trim() || "Untitled station"
}

function describe(station) {
  var tags = String(station.tags || "").split(",").map(function(t) { return t.trim() }).filter(function(t) { return t })
  var place = station.state || station.country || ""
  var sound = station.codec && station.codec !== "UNKNOWN" ? station.codec + (station.bitrate > 0 ? " " + station.bitrate + "k" : "") : ""
  return [place, tags.slice(0, 2).join(", "), sound].filter(function(p) { return p }).join(" · ")
}

function stationRow(station, section, playingUuid, favoriteUuids) {
  var favorite = favoriteUuids.indexOf(station.stationuuid) >= 0
  var ok = playable(station)
  return { kind: "station", section: section || "", lead: "󰐹", title: nameOf(station), name: nameOf(station),
    subtitle: ok ? describe(station) : "Can't play: HLS only", detail: favorite ? FAVORITE : "",
    stationUuid: station.stationuuid, favorite: favorite, artwork: station.favicon ? { url: station.favicon } : undefined,
    noQueue: true, missing: !ok, playing: station.stationuuid === playingUuid }
}

// The list: the station playing when it's neither a favourite nor local
// (one found by search, so A can keep it), the favourites, then the most
// listened stations near you.
function listRows(favorites, local, playingUuid, place, playing) {
  var ids = favorites.map(function(s) { return s.stationuuid })
  var rows = []
  var listed = ids.concat(local.map(function(s) { return s.stationuuid }))
  if (playing && listed.indexOf(playing.stationuuid) < 0) rows.push(stationRow(playing, "NOW PLAYING", playingUuid, ids))
  favorites.forEach(function(s, i) { rows.push(stationRow(s, i === 0 ? "FAVORITES" : "", playingUuid, ids)) })
  local.filter(function(s) { return ids.indexOf(s.stationuuid) < 0 }).forEach(function(s, i) {
    rows.push(stationRow(s, i === 0 ? "LOCAL · " + place.toUpperCase() : "", playingUuid, ids))
  })
  // No state set: say how, as the local stations are otherwise just missing.
  if (!place)
    rows.push({ kind: "note", section: "LOCAL", lead: "󰋼", title: "Set your US state for its local stations",
      subtitle: "omarchy bar set mre.omarock radioState Maine" })
  return rows
}

function searchRows(stations, playingUuid, favoriteUuids) {
  var seen = {}
  return stations.filter(function(s) {
    if (seen[s.stationuuid]) return false
    seen[s.stationuuid] = true
    return true
  }).map(function(s, i) { return stationRow(s, i === 0 ? "STATIONS" : "", playingUuid, favoriteUuids) })
}

// The song from a station's ICY title. iHeart's is Artist - text="Title"
// song_spot="M" … amgArtworkURL="…"; most are "Artist - Title".
function parseTitle(raw) {
  raw = String(raw || "").trim()
  var song = { artist: "", title: "", art: "" }
  var text = raw.match(/\btext="([^"]*)"/)
  if (text) {
    song.title = text[1]
    song.artist = raw.slice(0, raw.indexOf(text[0])).replace(/\s*-\s*$/, "").trim()
    var art = raw.match(/\bamgArtworkURL="([^"]*)"/)
    if (art && /^https?:\/\//.test(art[1])) song.art = art[1]
    return song
  }
  var dash = raw.indexOf(" - ")
  if (dash > 0) {
    song.artist = raw.slice(0, dash).trim()
    song.title = raw.slice(dash + 3).trim()
  } else {
    song.title = raw
  }
  return song
}

// The station playing, as mpd's currentsong would have it: the song as the
// title and artist (when the station sends them), the station as the album.
function songAsMpd(mpdSong, station) {
  var file = mpdSong ? mpdSong.file || "" : ""
  if (!file) return {}
  var name = station ? nameOf(station) : (mpdSong.name || "Radio")
  var song = parseTitle(mpdSong.title)
  // No song: the station is the title, and the album line stays empty.
  return { file: file, title: song.title || name, artist: song.title ? song.artist : "", album: song.title ? name : "",
    genre: station ? String(station.tags || "").split(",")[0] : "" }
}

// n and p: the next or previous favourite, wrapping round.
function stepStation(favorites, currentUuid, delta) {
  var ring = favorites.filter(playable)
  if (ring.length === 0) return null
  var at = -1
  ring.forEach(function(s, i) { if (s.stationuuid === currentUuid) at = i })
  if (at < 0) return ring[0]
  return ring[(at + delta + ring.length) % ring.length]
}

if (typeof module !== "undefined") {
  module.exports = {
    MARKER: MARKER,
    streamUrl: streamUrl,
    uuidOf: uuidOf,
    isRadio: isRadio,
    playable: playable,
    describe: describe,
    listRows: listRows,
    searchRows: searchRows,
    parseTitle: parseTitle,
    songAsMpd: songAsMpd,
    stepStation: stepStation
  }
}
