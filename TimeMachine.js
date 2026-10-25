// Time Machine: a year picked at the top of the panel. Then omarock lists
// only music from that year or before, and Top 100 plays Billboard's
// year-end chart for it, as Wikipedia lists it, found on Apple Music or
// Spotify. Mpd.js has the filter for mpd; these are the rest. Pure
// functions, so node can test them (tests/timemachine.test.js).

// Billboard's year-end singles charts on Wikipedia: the Hot 100 since 1959,
// a top 50 for 1956 to 1958, and a top 30 from 1949.
function firstYear() { return 1949 }

function chartSize(year) {
  return year >= 1959 ? 100 : year >= 1956 ? 50 : 30
}

function chartName(year) {
  return "Top " + chartSize(year)
}

// The Wikipedia page with a year's chart.
function chartPage(year) {
  return year >= 1959 ? "Billboard Year-End Hot 100 singles of " + year
    : "Billboard year-end top " + chartSize(year) + " singles of " + year
}

// The years to pick from, newest first: up to last year (a year's chart
// comes out in December), back to the first chart.
function years(now) {
  var out = []
  for (var y = now.getFullYear() - 1; y >= firstYear(); y--) out.push(y)
  return out
}

// The year of a song or album from Apple Music or Spotify: its year, else
// its release date's. 0 when it has neither.
function yearOf(item) {
  if (item && item.year > 0) return item.year
  var match = item && item.releaseDate ? String(item.releaseDate).match(/^\d{4}/) : null
  return match ? parseInt(match[0], 10) : 0
}

// Whether an item shows in `year` (0: Time Machine is off). Songs and albums
// go by their year, and ones without a year are left out, as local songs
// without a date are; artists, playlists and genres always show.
function inYear(item, year) {
  if (!year || !item || (item.kind !== "song" && item.kind !== "album")) return true
  var y = yearOf(item)
  return y > 0 && y <= year
}

function only(items, year) {
  return (items || []).filter(function(item) { return inYear(item, year) })
}

// A search's results (bridge/API.md) with what's after the year left out.
function filterResults(results, year) {
  if (!year || !results) return results
  var out = Object.assign({}, results)
  ;["library", "catalog"].forEach(function(side) {
    if (!results[side]) return
    out[side] = Object.assign({}, results[side], { songs: only(results[side].songs, year),
      albums: only(results[side].albums, year) })
  })
  return out
}

// An artist's page (GET /artists): their albums and songs from the year or before.
function filterArtist(data, year) {
  if (!year || !data) return data
  return Object.assign({}, data, { albums: only(data.albums, year), appearsOn: only(data.appearsOn, year),
    topSongs: only(data.topSongs, year) })
}

// A genre's charts (GET /genres/{id}).
function filterGenre(data, year) {
  if (!year || !data) return data
  return Object.assign({}, data, { albums: only(data.albums, year), songs: only(data.songs, year) })
}

// ---------- The chart, from Wikipedia's wikitext ----------

// Templates: the words of the ones that hold some ({{nowrap|…}},
// {{sort|key|text}}), none of the others (references, notes).
function template(body) {
  var parts = body.split("|")
  var name = parts[0].trim().toLowerCase()
  if (name === "'s") return "'s"
  if (name === "nowrap" || name === "nobr" || name === "small" || name === "abbr") return parts[1] || ""
  if (name === "sort" || name === "sortname") return parts[parts.length - 1] || ""
  return ""
}

// Wikitext as plain text: links as their words; templates, references,
// comments and markup gone.
function plainText(text) {
  var s = String(text || "")
  s = s.replace(/<!--[\s\S]*?-->/g, "")
  s = s.replace(/<ref[^>]*\/>/gi, "").replace(/<ref[^>]*>[\s\S]*?<\/ref>/gi, "")
  s = s.replace(/<br\s*\/?>/gi, " / ").replace(/<[^>]+>/g, "")
  // Innermost first, so a template inside another goes too.
  for (var guard = 0; guard < 10 && /\{\{[^{}]*\}\}/.test(s); guard++)
    s = s.replace(/\{\{([^{}]*)\}\}/g, function(all, body) { return template(body) })
  s = s.replace(/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/g, "$1")
  s = s.replace(/\[https?:\/\/[^\s\]]+\s([^\]]*)\]/g, "$1")
  s = s.replace(/'{2,}/g, "")
  s = s.replace(/&quot;/g, '"').replace(/&amp;/g, "&").replace(/&nbsp;/g, " ").replace(/&#0?39;/g, "'")
    .replace(/&ndash;/g, "–").replace(/&mdash;/g, "—")
  return s.replace(/\s+/g, " ").trim()
}

// A cell's attributes (rowspan="2", data-sort-value="…") and its text: the
// attributes end at the first | outside links and templates.
function splitCell(cell) {
  var depth = 0
  for (var i = 0; i < cell.length; i++) {
    var two = cell.substr(i, 2)
    if (two === "[[" || two === "{{") { depth++; i++ }
    else if (two === "]]" || two === "}}") { depth--; i++ }
    else if (cell.charAt(i) === "|" && depth === 0) {
      var attrs = cell.slice(0, i)
      if (/^\s*([a-z-]+\s*=\s*("[^"]*"|'[^']*'|[^\s|]+)\s*)+$/i.test(attrs)) return { attrs: attrs, text: cell.slice(i + 1) }
      break
    }
  }
  return { attrs: "", text: cell }
}

// The chart in a year's page: [{ rank, title, titles, artist }], in order.
// Its first wikitable has a row per song: the number, the title in quotes
// (two for a double A-side, "A" / "B"), the artist. A cell spanning rows
// (rowspan, one artist's two songs in a row) counts for each.
function parseChart(wikitext) {
  var text = String(wikitext || "")
  var start = text.search(/\{\|[^\n]*wikitable/)
  if (start < 0) return []
  var end = text.indexOf("\n|}", start)
  var body = text.slice(start, end < 0 ? text.length : end)
  var spans = [null, null, null]
  var out = []
  body.split(/\n\|-[^\n]*/).slice(1).forEach(function(row) {
    var cells = []
    row.split("\n").forEach(function(line) {
      var lead = line.charAt(0)
      if ((lead !== "|" && lead !== "!") || line.charAt(1) === "+" || line.charAt(1) === "}") return
      line.slice(1).split(lead === "!" ? /!!|\|\|/ : "||").forEach(function(cell) { cells.push(cell) })
    })
    if (cells.length === 0) return
    var filled = []
    var next = 0
    for (var col = 0; col < 3; col++) {
      if (spans[col] && spans[col].left > 0) {
        filled.push(spans[col].text)
        spans[col].left--
        continue
      }
      var cell = cells[next++]
      if (cell === undefined) { filled.push(""); continue }
      var parts = splitCell(cell)
      var span = parseInt((parts.attrs.match(/rowspan\s*=\s*["']?(\d+)/i) || [])[1], 10)
      spans[col] = span > 1 ? { text: parts.text, left: span - 1 } : null
      filled.push(parts.text)
    }
    var rank = parseInt(plainText(filled[0]), 10)
    if (!(rank > 0)) return
    var title = plainText(filled[1])
    var titles = (title.match(/"[^"]+"/g) || []).map(function(t) { return t.slice(1, -1).trim() })
    if (titles.length === 0) titles = [title.replace(/"/g, "").trim()]
    var artist = plainText(filled[2])
    if (titles[0] === "" || artist === "") return
    out.push({ rank: rank, title: titles.join(" / "), titles: titles, artist: artist })
  })
  return out
}

// ---------- Finding the chart's songs ----------

function fold(text) {
  var s = String(text || "").toLowerCase()
  if (typeof s.normalize === "function") s = s.normalize("NFD").replace(/[̀-ͯ]/g, "")
  return s.replace(/ø/g, "o").replace(/ß/g, "ss")
}

// A title as both sides name it: "Macarena (Bayside Boys Mix)" is
// "Macarena - Bayside Boys Remix", "Yeah! feat. Lil Jon" is "Yeah!", "Don't
// Cry" is "Dont Cry".
function titleKey(title) {
  var s = fold(title)
  var bare = s.replace(/\s*[\(\[][^\)\]]*[\)\]]/g, " ").replace(/\s+-\s+.*$/, "").replace(/\s+(feat\.?|featuring|ft\.)\s.*$/, "")
  if (bare.replace(/[^a-z0-9]/g, "") !== "") s = bare
  return s.replace(/&/g, " and ").replace(/[^a-z0-9 ]+/g, "").replace(/\s+/g, " ").trim()
}

// One title is the other and a version's words ("… Remix", "… Live 1977"),
// not another song that starts the same ("Yeah" and "Yeah Yeah Yeahs").
var VERSION = /^(remix|mix|version|remaster|remastered|live|edit|mono|stereo|radio|single|extended|original|\d{4})\b/

function sameSong(a, b) {
  return (a.indexOf(b + " ") === 0 && VERSION.test(a.slice(b.length + 1)))
    || (b.indexOf(a + " ") === 0 && VERSION.test(b.slice(a.length + 1)))
}

function nameKey(name) {
  return fold(name).replace(/&/g, " and ").replace(/[^a-z0-9 ]+/g, "").replace(/\s+/g, " ").trim()
}

// The names in a chart's artist credit, each on its own: "Mariah Carey and
// Boyz II Men", "Usher featuring Lil Jon and Ludacris", "Dionne and Friends
// (Dionne Warwick, …)". A band's own "and" splits too, which only loosens
// the match.
function artistNames(artist) {
  return String(artist || "").replace(/[()]/g, ",")
    .split(/\s+(?:featuring|feat\.?|ft\.?|with|and|x|vs\.?|duet with)\s+|\s*[,&\/+]\s*/i)
    .map(nameKey).filter(function(name) { return name.length > 1 })
}

// What to search the service for: the first title and the artists, without
// the guests ("featuring …") or the joining words.
function searchText(entry) {
  var artist = String(entry.artist || "").split(/\s+(?:featuring|feat\.?|ft\.?)\s+/i)[0]
    .replace(/\([^)]*\)/g, " ").replace(/\s+(?:and|with|x|vs\.?|duet with)\s+|[,&\/+]/gi, " ")
  return (entry.titles[0] + " " + artist).replace(/\s+/g, " ").trim()
}

// A second try, when the first finds nothing: the title and the first name.
function searchAgain(entry) {
  var names = String(entry.artist || "").replace(/\([^)]*\)/g, " ")
    .split(/\s+(?:featuring|feat\.?|ft\.?|with|and|x|vs\.?|duet with)\s+|\s*[,&\/+]\s*/i)
  var text = (entry.titles[0] + " " + (names[0] || "")).replace(/\s+/g, " ").trim()
  return text !== searchText(entry) ? text : ""
}

// The service's song for a chart entry, from a search's songs, or null:
// the same title (or another version of it, sameSong) by one of its
// artists. A version from the chart's year or before (not a later live
// album or compilation) wins, then the one the service listed first.
function bestMatch(entry, songs, year) {
  var keys = entry.titles.map(titleKey).filter(function(k) { return k !== "" })
  var names = artistNames(entry.artist)
  var best = null
  var bestScore = 0
  ;(songs || []).forEach(function(song, i) {
    var key = titleKey(song.title)
    if (key === "") return
    var title = keys.indexOf(key) >= 0 ? 2 : keys.some(function(k) { return sameSong(key, k) }) ? 1 : 0
    if (title === 0) return
    var artist = nameKey(song.artist)
    if (!names.some(function(n) { return artist.indexOf(n) >= 0 || (artist.length > 2 && n.indexOf(artist) >= 0) })) return
    var y = yearOf(song)
    // A re-recording or a karaoke copy only when there's nothing else.
    var copy = /re-?record|karaoke|tribute/i.test((song.title || "") + " " + (song.album || ""))
    var score = title * 10 + (y > 0 && y <= year + 1 ? 3 : 0) + (copy ? -2 : 0) + (song.playable === false ? -15 : 0) - i * 0.01
    if (score > bestScore) {
      best = song
      bestScore = score
    }
  })
  return best
}

// What's kept of a song found, for the cache: what its row, playing it and
// its info card need.
var KEPT = ["kind", "id", "source", "catalogId", "title", "artist", "album", "albumId", "artistId", "genres",
  "year", "releaseDate", "duration", "explicit", "audioTraits", "playable", "inLibrary", "isrc"]

function keep(song) {
  var out = {}
  KEPT.forEach(function(k) { if (song[k] !== undefined) out[k] = song[k] })
  if (song.artwork) out.artwork = { url: song.artwork.url, width: song.artwork.width, height: song.artwork.height }
  return out
}

// The Top 100 view: Play them all, then the chart, each song as the service
// found it (a row that plays from there), not found, or still looked for.
// found: rank -> the service's Song, null when it has none, undefined while
// it's being looked for. state: { service (its name, "" for none), looking,
// error }. Apple: Apple.js, for the rows. songItems: what Play plays. Each
// row leads with its place on the chart, not the song's cover.
function chartView(year, chart, found, state, Apple) {
  var name = chartName(year)
  var service = state.service || ""
  var rows = []
  var items = []
  var have = 0
  var known = 0
  chart.forEach(function(entry) {
    var song = found[entry.rank]
    if (song !== undefined) known++
    if (song) have++
  })
  var subtitle = service === "" ? "Switch on Apple Music or Spotify in the settings to play these"
    : state.error ? "Couldn't look them up on " + service + ": " + state.error
    : known < chart.length ? "Finding them on " + service + ": " + known + " of " + chart.length
    : have + " of " + chart.length + " found on " + service
  if (chart.length > 0) rows.push({ kind: "playtop", lead: "󰐊", title: "Play the " + name, subtitle: subtitle })
  chart.forEach(function(entry) {
    var song = service !== "" ? found[entry.rank] : undefined
    if (song) {
      rows.push(Object.assign(Apple.songRow(song), { kind: "track", lead: String(entry.rank), title: entry.title,
        subtitle: [entry.artist, song.album || ""].filter(function(p) { return p !== "" }).join(" · "),
        position: items.length, section: "", artwork: undefined, playable: song.playable !== false,
        missing: song.playable === false }))
      items.push(Apple.ref(song))
    } else {
      rows.push({ kind: "chartmiss", lead: String(entry.rank), title: entry.title, noQueue: true,
        subtitle: entry.artist + (song === null ? " · not on " + service : ""), missing: song === null })
    }
  })
  return { rows: rows, songItems: items, info: { title: name + " of " + year,
    subtitle: "Billboard's year-end chart" + (service !== "" ? " · on " + service : ""),
    emptyText: "Billboard's chart for " + year + " has no songs." } }
}

if (typeof module !== "undefined") {
  module.exports = {
    firstYear: firstYear,
    chartSize: chartSize,
    chartName: chartName,
    chartPage: chartPage,
    years: years,
    yearOf: yearOf,
    inYear: inYear,
    filterResults: filterResults,
    filterArtist: filterArtist,
    filterGenre: filterGenre,
    plainText: plainText,
    parseChart: parseChart,
    titleKey: titleKey,
    artistNames: artistNames,
    searchText: searchText,
    searchAgain: searchAgain,
    bestMatch: bestMatch,
    keep: keep,
    chartView: chartView
  }
}
