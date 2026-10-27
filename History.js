// History: what was played here, for a few days (the historyDays setting,
// 7 by default), from every source, kept in ~/.local/share/omarock/
// history.jsonl, a line of JSON a play (HistoryClient.qml). H, or History
// at the top of Playlists, lists it newest first, by day. Pure functions, so
// node can test them (tests/history.test.js).

// The source icons, as the header's switches show them.
var ICONS = { local: "󱍙", apple: "󰀵", spotify: "󰓇", sxm: "󰑱", radio: "󰐹" }
var NAMES = { local: "Your music", apple: "Apple Music", spotify: "Spotify", sxm: "SiriusXM", radio: "Radio" }
var DAY = 24 * 3600 * 1000

function trimmed(value) { return String(value || "").trim() }

// What's playing as a history entry, or null when it isn't a song: a
// station between songs (its own name, a slogan, an ad), nothing at all.
// info: { title, artist, album, file, duration, station, isAd, ref }, as the
// panel has them for the source.
function entryFor(source, info) {
  if (!info) return null
  var title = trimmed(info.title)
  var artist = trimmed(info.artist)
  if (title === "") return null
  var entry = { source: source, title: title, artist: artist }
  if (source === "radio" || source === "sxm") {
    var station = trimmed(info.station)
    if (info.isAd || artist === "" || title === station || artist === station) return null
    entry.station = station
    return entry
  }
  entry.album = trimmed(info.album)
  if (info.duration > 0) entry.duration = Math.round(info.duration)
  if (source === "local") {
    if (!info.file) return null
    entry.file = info.file
  } else {
    if (!info.ref || !info.ref.id) return null
    entry.ref = { kind: "song", id: String(info.ref.id), source: info.ref.source || "catalog" }
  }
  return entry
}

// The same song still playing: what tells one play from the next.
function keyOf(entry) {
  if (!entry) return ""
  var what = entry.file || (entry.ref ? entry.ref.id : "") || entry.station + "|" + entry.artist + "|" + entry.title
  return entry.source + "|" + what
}

// Whether a song has been listened to long enough to count, as scrobblers
// count it: half the song or 4 minutes, whichever comes first, and never a
// song under 30 s. A station's song has no length: 30 s of it. after (a
// test's setting, in seconds) replaces all that.
function counts(listened, duration, live, after) {
  if (after > 0) return listened >= after
  if (live || !(duration > 0)) return listened >= 30
  return duration >= 30 && listened >= Math.min(duration / 2, 240)
}

// The entries of the last days, oldest first.
function prune(entries, now, days) {
  var since = now - Math.max(1, days) * DAY
  return entries.filter(function(e) { return e && e.at >= since })
}

// The file: a line of JSON an entry. A line that isn't one is skipped.
function parse(text) {
  var out = []
  String(text || "").split("\n").forEach(function(line) {
    if (line.trim() === "") return
    try {
      var e = JSON.parse(line)
      if (e && typeof e.at === "number" && e.title && NAMES[e.source]) out.push(e)
    } catch (err) {}
  })
  return out.sort(function(a, b) { return a.at - b.at })
}

function line(entry) {
  return JSON.stringify(entry)
}

function midnight(t) {
  var d = new Date(t)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

var WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// A day's heading: TODAY, YESTERDAY, a weekday this past week, else the date.
function dayLabel(at, now) {
  var days = Math.round((midnight(now) - midnight(at)) / DAY)
  var d = new Date(at)
  if (days <= 0) return "TODAY"
  if (days === 1) return "YESTERDAY"
  if (days < 7) return WEEKDAYS[d.getDay()].toUpperCase()
  return (WEEKDAYS[d.getDay()].slice(0, 3) + " " + d.getDate() + " " + MONTHS[d.getMonth()]).toUpperCase()
}

// The level's rows, newest first, a heading on each day's first. time(at)
// says the time as this machine does.
function rows(entries, now, time) {
  var out = []
  var day = ""
  entries.slice().reverse().forEach(function(e) {
    var label = dayLabel(e.at, now)
    // A station's song can only be looked up (Panel.activateHistory).
    var live = e.source === "radio" || e.source === "sxm"
    out.push({ kind: live ? "historylookup" : "history", section: label !== day ? label : "", lead: ICONS[e.source] || "󰝚",
      title: e.title, subtitle: [e.artist, e.station || e.album || "", NAMES[e.source]].filter(function(p) { return !!p }).join(" · "),
      detail: time(e.at), file: e.file || "", noQueue: live, history: e })
    day = label
  })
  return out
}

function info(entries, days, enabled) {
  var span = days === 1 ? "the last day" : "the last " + days + " days"
  return { title: "History", coverFile: "",
    subtitle: entries.length === 0 ? span : entries.length + (entries.length === 1 ? " song" : " songs") + " · " + span,
    emptyText: enabled ? "Nothing played in " + span + " yet. Songs show here once you've heard half of one, or 4 minutes."
      : "History is off: switch it on in the settings (,)." }
}

if (typeof module !== "undefined") {
  module.exports = { ICONS: ICONS, NAMES: NAMES, entryFor: entryFor, keyOf: keyOf, counts: counts, prune: prune,
    parse: parse, line: line, dayLabel: dayLabel, rows: rows, info: info }
}
