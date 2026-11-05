// Internet radio for the panel: stations from Radio Browser
// (radio-browser.info, a free community directory), and the station mpd
// plays, in the shape the player card and the bar read from mpd. Pure
// functions, so node can test them (tests/radio.test.js).
//
// A station queued by omarock is its stream URL with "#omarock-radio=<uuid>"
// after it. The server never sees what follows "#", and mpd keeps it, so the
// queue and the "Radio" playlist (the favorites) say which station it is.

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

// The list: the station playing when it's neither a favorite nor local
// (one found by search, so A can keep it), the favorites, then the most
// listened stations near you. place: the local section's name ("near
// Portland"), or "" when no area is set.
function listRows(favorites, local, playingUuid, place, playing) {
  var ids = favorites.map(function(s) { return s.stationuuid })
  var rows = []
  var listed = ids.concat(local.map(function(s) { return s.stationuuid }))
  if (playing && listed.indexOf(playing.stationuuid) < 0) rows.push(stationRow(playing, "NOW PLAYING", playingUuid, ids))
  favorites.forEach(function(s, i) { rows.push(stationRow(s, i === 0 ? "FAVORITES" : "", playingUuid, ids)) })
  local.filter(function(s) { return ids.indexOf(s.stationuuid) < 0 }).forEach(function(s, i) {
    rows.push(stationRow(s, i === 0 ? "LOCAL · " + place.toUpperCase() : "", playingUuid, ids))
  })
  // No area set: say how, as the local stations are otherwise just missing.
  if (!place)
    rows.push({ kind: "note", section: "LOCAL", lead: "󰋼", title: "Set your area for its local stations",
      subtitle: "In omarock's settings (,): Your area, a city or region" })
  return rows
}

// ---------- Local stations: those of an area (Places.area) ----------
//
// Radio Browser's stations say where they are in their own words: a
// region field typed by volunteers ("Maine", "Portland, OR", "Bayern"),
// often left out, and coordinates on a fifth of them. So an area's stations
// are searched for several ways (localQueries), and each one found is
// weighed (localTier): near (within the radius by its coordinates, or a
// city near by name) comes before the rest of the area's regions.

var LOCAL_LIMIT = 40

// The local section's name: "near Portland", "Maine", "Germany".
function localPlace(area) {
  if (!area) return ""
  return area.kind === "city" ? "near " + area.name : area.name
}

// The searches (Radio Browser's /json/stations/search) that find an area's
// stations: by coordinates; by each region's names (the region field
// holds any of them, "Lewiston, Maine" too) and the city's; and stations
// named or tagged for its region, or for a city no other shares its name with.
function localQueries(area) {
  if (!area) return []
  var common = "hidebroken=true&order=clickcount&reverse=true"
  var out = []
  function add(field, value, cc, limit) {
    out.push(field + "=" + encodeURIComponent(value) + (cc ? "&countrycode=" + cc : "") + "&" + common + "&limit=" + limit)
  }
  if (area.kind === "country") {
    out.push("countrycode=" + area.cc + "&" + common + "&limit=" + LOCAL_LIMIT)
    return out
  }
  if (area.lat !== null && area.lat !== undefined)
    out.push("geo_lat=" + area.lat + "&geo_long=" + area.lon + "&geo_distance=" + area.radius * 1000 + "&" + common + "&limit=100")
  area.regions.forEach(function(r) { r.names.slice(0, 2).forEach(function(n) { add("state", n, r.cc, 100) }) })
  var home = area.regions[0]
  if (area.kind === "city") add("state", area.name, area.cc, 100)
  if (home) {
    add("name", home.names[0], home.cc, 50)
    add("tag", home.names[0].toLowerCase(), home.cc, 50)
  }
  if (area.kind === "city" && !area.ambiguous) {
    add("name", area.name, area.cc, 50)
    add("tag", area.name.toLowerCase(), area.cc, 50)
  }
  return out
}

// Folded text as words: punctuation is a space ("St.Louis" is "st louis").
function wordsOf(text, Places) {
  return " " + Places.fold(text).replace(/[^a-z0-9]+/g, " ").trim() + " "
}

// Whether words (wordsOf) have a name (folded) among them, whole.
function hasWord(words, name) {
  name = String(name || "").replace(/[^a-z0-9]+/g, " ").trim()
  return name !== "" && words.indexOf(" " + name + " ") >= 0
}

// How local a station is to an area: 1 near, 2 elsewhere in its regions,
// 0 not local. Places: Places.js. crowded: coordinates many stations share
// (one operator's address), which say nothing about where each one plays.
function localTier(area, station, Places, crowded) {
  var cc = String(station.countrycode || "").toUpperCase()
  if (area.kind === "country") return cc === area.cc ? 2 : 0
  var mine = area.regions
  var known = mine.some(function(r) { return r.cc === cc })
  var lat = station.geo_lat, lon = station.geo_long
  var placed = lat !== null && lat !== undefined && lon !== null && lon !== undefined && !crowded[lat + "," + lon]
  var tooFar = false
  if (placed && area.lat !== null && area.lat !== undefined) {
    var d = Places.km(area.lat, area.lon, lat, lon)
    if (d <= area.radius) return 1
    // A little past the radius, its region can still count it; far past, not.
    if (d > area.radius * 1.5) return 0
    tooFar = true
  }
  if (!known) return 0
  function named(r, part) {
    return r.cc === cc && (r.names.some(function(n) { return Places.fold(n) === part }) || (r.short !== "" && Places.fold(r.short) === part))
  }
  var whole = Places.fold(station.state)
  var parts = whole === "" ? [] : [whole].concat(whole.split(/[,\/;]/).map(function(p) { return p.trim() }).filter(function(p) { return p !== "" }))
  var region = false, near = false
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (mine.some(function(r) { return named(r, part) })) region = true
    else if (area.near.indexOf(part) >= 0) near = true
    else if (area.others.some(function(r) { return r.cc === cc && (r.names.indexOf(part) >= 0 || (r.short !== "" && r.short === part)) }))
      // Another region's: "Portland, OR" isn't Portland, Maine.
      return 0
    // A city of its regions, but far away: "St. Louis, Missouri".
    else if ((area.far || []).indexOf(part) >= 0) return 0
  }
  // ISO 3166-2 ("US-ME", "CA-ON"), where it's filled in.
  var iso = String(station.iso_3166_2 || "").toUpperCase().split("-")
  if (iso.length === 2 && iso[0] === cc) {
    var sub = iso[1]
    if (mine.some(function(r) { return r.cc === cc && (r.short === sub || r.code === cc + "." + sub) })) region = true
  }
  if (near && !tooFar) return 1
  // Its name and tags, unless they name a big city far off ("Z107.7 St. Louis").
  var words = wordsOf((station.name || "") + " " + (station.tags || ""), Places)
  if (!near && (area.farBig || []).some(function(n) { return hasWord(words, n) })) return 0
  // The city's name; one another city shares, with its region ("Portland, OR").
  var city = Places.fold(area.name)
  var home = mine[0]
  if (area.kind === "city" && cc === area.cc && (!area.ambiguous ? hasWord(words, city)
      : home && home.names.concat(home.short ? [home.short] : []).some(function(n) { return hasWord(words, city + " " + Places.fold(n)) })))
    return tooFar ? 2 : 1
  if (near || region) return 2
  if (home && cc === home.cc && home.names.some(function(n) { return hasWord(words, Places.fold(n)) })) return 2
  return 0
}

// An area's stations, from what its searches found: near ones first, then
// the rest of its regions, each by how much they're listened to.
function localStations(area, found, Places, limit) {
  if (!area) return []
  var seen = {}
  var stations = found.filter(function(s) {
    if (!s || seen[s.stationuuid]) return false
    seen[s.stationuuid] = true
    return true
  })
  var at = {}
  stations.forEach(function(s) {
    if (s.geo_lat === null || s.geo_lat === undefined) return
    var key = s.geo_lat + "," + s.geo_long
    at[key] = (at[key] || 0) + 1
  })
  var crowded = {}
  for (var key in at) if (at[key] >= 8) crowded[key] = true
  return stations.map(function(s) { return { station: s, tier: localTier(area, s, Places, crowded) } })
    .filter(function(t) { return t.tier > 0 })
    .sort(function(a, b) { return a.tier - b.tier || (b.station.clickcount || 0) - (a.station.clickcount || 0) })
    .slice(0, limit || LOCAL_LIMIT)
    .map(function(t) { return t.station })
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

// n and p: the next or previous favorite, wrapping around.
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
    localPlace: localPlace,
    localQueries: localQueries,
    localTier: localTier,
    localStations: localStations,
    searchRows: searchRows,
    parseTitle: parseTitle,
    songAsMpd: songAsMpd,
    stepStation: stepStation
  }
}
