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

// How many of a library genre's songs are from the year or before, from
// its count by year (songs with no year left out, as elsewhere).
function genreSongs(genre, year) {
  if (!year) return genre.songs || 0
  var n = 0
  Object.keys(genre.years || {}).forEach(function(y) {
    var value = parseInt(y, 10)
    if (value > 0 && value <= year) n += genre.years[y]
  })
  return n
}

// A search's results (apple-bridge/API.md) with what's after the year left
// out: the library's genres count only their songs from the year or before,
// and go when they have none.
function filterResults(results, year) {
  if (!year || !results) return results
  var out = Object.assign({}, results)
  ;["library", "catalog"].forEach(function(side) {
    if (!results[side]) return
    out[side] = Object.assign({}, results[side], { songs: only(results[side].songs, year),
      albums: only(results[side].albums, year) })
    if (results[side].genres)
      out[side].genres = results[side].genres.map(function(genre) {
        return Object.assign({}, genre, { songs: genreSongs(genre, year) })
      }).filter(function(genre) { return genre.songs > 0 })
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

// One of the library's genres (GET /genres/library/{id}): its albums and
// songs from the year or before. Its songs are short ({ id, year }), so
// they go by their year here.
function filterLibraryGenre(data, year) {
  if (!year || !data) return data
  return Object.assign({}, data, { albums: only(data.albums, year), songs: (data.songs || []).filter(function(song) {
    return song.year > 0 && song.year <= year
  }) })
}

// ---------- The chart, from Wikipedia's wikitext ----------
//
// The page comes from the network, so nothing here reads it over and over:
// a page made to slow it down (a "<!--" never closed, a thousand "[[")
// reads as fast as any page its size. The patterns left go back at most
// over the run they've just read (spaces, or text without braces). The
// chart stops at its size, and each title and artist at TEXT_MAX characters.

// Wikipedia's longest are about 110.
var TEXT_MAX = 300
// A cell's attributes: 37 characters at most on Wikipedia's pages.
var ATTRS_MAX = 500
// A table's heading rows and a tie (two songs at 100 in 1969) take a few
// rows past the chart's size: three at most on Wikipedia's pages.
var EXTRA_ROWS = 10

var REF = /<ref/gi
var REF_END = /<\/ref>/gi
var URL_END = /[\s\]]/g

// JavaScript's \s, by character code.
function isSpace(code) {
  return (code >= 9 && code <= 13) || code === 32 || code === 160 || code === 5760 || (code >= 8192 && code <= 8202)
    || code === 8232 || code === 8233 || code === 8239 || code === 8287 || code === 12288 || code === 65279
}

// Where pattern (a /g one) next matches at or after from; -1 if nowhere.
function search(pattern, s, from) {
  pattern.lastIndex = from
  var match = pattern.exec(s)
  return match ? match.index : -1
}

// Comments gone; one never closed stays, with what follows it.
function dropComments(s) {
  var out = []
  var pos = 0
  for (var open = s.indexOf("<!--"); open >= 0; open = s.indexOf("<!--", pos)) {
    var close = s.indexOf("-->", open + 4)
    if (close < 0) break
    out.push(s.slice(pos, open))
    pos = close + 3
  }
  out.push(s.slice(pos))
  return out.join("")
}

// References gone: <ref … /> first, then <ref …>…</ref>.
function dropRefs(s) {
  var out = []
  var pos = 0
  var from = 0
  for (var open = search(REF, s, 0); open >= 0; open = search(REF, s, from)) {
    var gt = s.indexOf(">", open + 4)
    if (gt < 0) break
    if (gt > open + 4 && s.charAt(gt - 1) === "/") {
      out.push(s.slice(pos, open))
      pos = gt + 1
    }
    // A <ref before that > ends there too, as this one did.
    from = gt + 1
  }
  out.push(s.slice(pos))
  s = out.join("")
  out = []
  pos = 0
  for (;;) {
    var start = search(REF, s, pos)
    var end = start < 0 ? -1 : s.indexOf(">", start + 4)
    var close = end < 0 ? -1 : search(REF_END, s, end + 1)
    if (close < 0) break
    out.push(s.slice(pos, start))
    pos = close + 6
  }
  out.push(s.slice(pos))
  return out.join("")
}

// Line breaks as " / ", then the other tags gone. Up to the last >, each <
// has a > ahead, so the pattern reads on to it once; after it, none closes.
function dropTags(s) {
  s = s.replace(/<br\s*\/?>/gi, " / ")
  var last = s.lastIndexOf(">")
  return s.slice(0, last + 1).replace(/<[^>]+>/g, "") + s.slice(last + 1)
}

// Links as their words: [[Page]], [[Page|words]].
function linkWords(s) {
  var out = []
  var pos = 0
  var from = 0
  // The first | ahead (-1: none, -2: not looked for yet).
  var bar = -2
  for (var open = s.indexOf("[["); open >= 0; open = s.indexOf("[[", from)) {
    var close = s.indexOf("]", open + 2)
    if (close < 0) break
    if (s.charAt(close + 1) === "]") {
      if (bar !== -1 && bar < open + 2) bar = s.indexOf("|", open + 2)
      out.push(s.slice(pos, open), s.slice(bar >= 0 && bar < close ? bar + 1 : open + 2, close))
      pos = close + 2
    }
    // A [[ before that ] ends there too, as this one did.
    from = close + 1
  }
  out.push(s.slice(pos))
  return out.join("")
}

// Web links as their words: [https://… words].
function urlWords(s) {
  var out = []
  var pos = 0
  var from = 0
  for (var open = s.indexOf("[http"); open >= 0; open = s.indexOf("[http", from)) {
    var start = s.substr(open + 5, 3) === "://" ? open + 8 : s.substr(open + 5, 4) === "s://" ? open + 9 : -1
    from = open + 1
    if (start < 0) continue
    // The address ends at a space (the words follow) or a ]; a link before
    // it ends there too.
    var stop = search(URL_END, s, start)
    if (stop < 0) break
    from = stop
    if (stop === start || s.charAt(stop) === "]") continue
    var close = s.indexOf("]", stop + 1)
    if (close < 0) break
    out.push(s.slice(pos, open), s.slice(stop + 1, close))
    pos = from = close + 1
  }
  out.push(s.slice(pos))
  return out.join("")
}

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
  var s = dropTags(dropRefs(dropComments(String(text || ""))))
  // Innermost first, so a template inside another goes too.
  for (var guard = 0; guard < 10 && /\{\{[^{}]*\}\}/.test(s); guard++)
    s = s.replace(/\{\{([^{}]*)\}\}/g, function(all, body) { return template(body) })
  s = urlWords(linkWords(s))
  s = s.replace(/'{2,}/g, "")
  s = s.replace(/&quot;/g, '"').replace(/&amp;/g, "&").replace(/&nbsp;/g, " ").replace(/&#0?39;/g, "'")
    .replace(/&ndash;/g, "–").replace(/&mdash;/g, "—")
  return s.replace(/\s+/g, " ").trim()
}

// Whether a cell starts with attributes: name=value again and again, the
// value in quotes or a word (rowspan="2", data-sort-value=Flack). A
// pattern for it, a repeat inside a repeat, can take forever on a long
// one; this reads it once, keeping each place it could be at (a bit each).
function isAttributes(s) {
  var START = 1, NAME = 2, BEFORE = 4, AFTER = 8, QUOTED = 16, QUOTED1 = 32, WORD = 64, DONE = 128
  var at = START
  for (var i = 0; i < s.length && at !== 0; i++) {
    var code = s.charCodeAt(i)
    var c = s.charAt(i)
    var space = isSpace(code)
    var letter = (code >= 97 && code <= 122) || (code >= 65 && code <= 90) || code === 45
    var next = 0
    if (at & (START | DONE)) next |= space ? at & (START | DONE) : letter ? NAME : 0
    if (at & NAME) next |= letter ? NAME : space ? BEFORE : c === "=" ? AFTER : 0
    if (at & BEFORE) next |= space ? BEFORE : c === "=" ? AFTER : 0
    if (at & AFTER) next |= space ? AFTER : c === "|" ? 0 : c === '"' ? QUOTED | WORD : c === "'" ? QUOTED1 | WORD : WORD
    if (at & QUOTED) next |= c === '"' ? DONE : QUOTED
    if (at & QUOTED1) next |= c === "'" ? DONE : QUOTED1
    if (at & WORD) next |= space ? DONE : c === "|" ? 0 : letter ? WORD | NAME : WORD
    at = next
  }
  return (at & (DONE | WORD)) !== 0
}

// A cell's attributes (rowspan="2", data-sort-value="…") and its text: the
// attributes end at the first | outside links and templates, within
// ATTRS_MAX characters.
function splitCell(cell) {
  var depth = 0
  for (var i = 0; i < cell.length && i <= ATTRS_MAX; i++) {
    var c = cell.charAt(i)
    var d = cell.charAt(i + 1)
    if ((c === "[" || c === "{") && d === c) { depth++; i++ }
    else if ((c === "]" || c === "}") && d === c) { depth--; i++ }
    else if (c === "|" && depth === 0) {
      var attrs = cell.slice(0, i)
      if (isAttributes(attrs)) return { attrs: attrs, text: cell.slice(i + 1) }
      break
    }
  }
  return { attrs: "", text: cell }
}

// Where the first wikitable starts: a "{|" with "wikitable" after it on its
// line; -1 if there's none.
function firstTable(text) {
  // The first "wikitable" ahead (-2: not looked for yet).
  var word = -2
  for (var open = text.indexOf("{|"); open >= 0; ) {
    var end = text.indexOf("\n", open)
    if (end < 0) end = text.length
    if (word !== -1 && word < open + 2) word = text.indexOf("wikitable", open + 2)
    if (word < 0) return -1
    if (word < end) return open
    open = text.indexOf("{|", end)
  }
  return -1
}

// The chart in a year's page: [{ rank, title, titles, artist }], in order,
// its places 1 to size (chartSize). Its first wikitable has a row per song:
// the number, the title in quotes (two for a double A-side, "A" / "B"), the
// artist. A cell spanning rows (rowspan, one artist's two songs in a row)
// counts for each.
function parseChart(wikitext, size) {
  var text = String(wikitext || "")
  var places = size > 0 ? size : 100
  var start = firstTable(text)
  if (start < 0) return []
  var end = text.indexOf("\n|}", start)
  var stop = end < 0 ? text.length : end
  var spans = [null, null, null]
  var out = []
  function row(cells) {
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
      var words = plainText(parts.text).slice(0, TEXT_MAX).trim()
      var span = parseInt((parts.attrs.match(/rowspan\s*=\s*["']?(\d+)/i) || [])[1], 10)
      spans[col] = span > 1 ? { text: words, left: span - 1 } : null
      filled.push(words)
    }
    var rank = parseInt(filled[0], 10)
    if (!(rank > 0 && rank <= places)) return
    var title = filled[1]
    var titles = (title.match(/"[^"]+"/g) || []).map(function(t) { return t.slice(1, -1).trim() })
    if (titles.length === 0) titles = [title.replace(/"/g, "").trim()]
    var artist = filled[2]
    if (titles[0] === "" || artist === "") return
    out.push({ rank: rank, title: titles.join(" / "), titles: titles, artist: artist })
  }
  // A row starts at each |- line, after the table's own line. No more rows
  // are read than the chart has, and a few for headings and ties.
  var cells = null
  var rows = 0
  for (var at = text.indexOf("\n", start); at >= 0 && at < stop; ) {
    var next = text.indexOf("\n", at + 1)
    if (next < 0 || next > stop) next = stop
    var line = text.slice(at + 1, next)
    var lead = line.charAt(0)
    at = next
    if (lead === "|" && line.charAt(1) === "-") {
      if (cells) row(cells)
      cells = ++rows > places + EXTRA_ROWS ? null : []
      if (!cells) break
    } else if (cells && (lead === "|" || lead === "!") && line.charAt(1) !== "+" && line.charAt(1) !== "}") {
      line.slice(1).split(lead === "!" ? /!!|\|\|/ : "||").forEach(function(cell) { cells.push(cell) })
    }
  }
  if (cells) row(cells)
  return out
}

// A chart read back from the cache, held to what parseChart gives: places 1
// to the year's chart size, short text, and no more rows.
function cachedChart(data, year) {
  var size = chartSize(year)
  var rows = data && Array.isArray(data.chart) ? data.chart : []
  var out = []
  for (var i = 0; i < rows.length && out.length < size + EXTRA_ROWS; i++) {
    var entry = rows[i]
    if (!entry || typeof entry.rank !== "number" || entry.rank % 1 !== 0 || entry.rank < 1 || entry.rank > size
        || !Array.isArray(entry.titles) || entry.titles.length === 0 || typeof entry.artist !== "string") continue
    var titles = entry.titles
    if (!titles.every(function(t) { return typeof t === "string" }) || titles[0] === "" || titles.join("").length > TEXT_MAX
        || entry.artist === "" || entry.artist.length > TEXT_MAX) continue
    out.push({ rank: entry.rank, title: titles.join(" / "), titles: titles.slice(), artist: entry.artist })
  }
  return out
}

// The songs found before, read back from the cache ({ found: rank -> song
// or null }): only the chart's places, each song as keep() keeps it.
function cachedFound(data, year) {
  var found = data && data.found && typeof data.found === "object" ? data.found : {}
  var out = {}
  for (var rank = 1; rank <= chartSize(year); rank++) {
    if (!Object.prototype.hasOwnProperty.call(found, rank)) continue
    var song = found[rank]
    if (song === null) out[rank] = null
    else if (song && typeof song === "object" && !Array.isArray(song)) out[rank] = keep(song)
  }
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

// A list in an order of its own (Fisher and Yates), as a new list. random:
// Math.random, or a stand-in for tests.
function shuffled(items, random) {
  var out = items.slice()
  for (var i = out.length - 1; i > 0; i--) {
    var j = Math.floor(random() * (i + 1))
    var t = out[i]
    out[i] = out[j]
    out[j] = t
  }
  return out
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
  if (chart.length > 0) {
    rows.push({ kind: "playtop", lead: "󰐊", title: "Play the " + name, subtitle: subtitle })
    rows.push({ kind: "shuffletop", lead: "󰒟", title: "Shuffle the " + name, subtitle: "Its songs in an order of their own" })
  }
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
    genreSongs: genreSongs,
    filterResults: filterResults,
    filterArtist: filterArtist,
    filterGenre: filterGenre,
    filterLibraryGenre: filterLibraryGenre,
    plainText: plainText,
    isAttributes: isAttributes,
    parseChart: parseChart,
    cachedChart: cachedChart,
    cachedFound: cachedFound,
    titleKey: titleKey,
    artistNames: artistNames,
    searchText: searchText,
    searchAgain: searchAgain,
    bestMatch: bestMatch,
    shuffled: shuffled,
    keep: keep,
    chartView: chartView
  }
}
