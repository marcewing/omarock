// SiriusXM for the panel: channel rows built from the omarock-sxm service
// (sxm/README.md), and the channel playing in the shape the player card and
// the bar read from mpd. Pure functions, so node can test them
// (tests/sxm.test.js).

var FAVORITE = "󰋑"

// The service's streams all start with this; a stream URL ends in the channel id.
function streamPrefix(base) {
  return base + "/stream/"
}

function channelIdOf(file, base) {
  var prefix = streamPrefix(base)
  return file && file.indexOf(prefix) === 0 ? file.slice(prefix.length) : ""
}

// What a channel is playing, as one line: "Artist – Title", or the show.
function nowLine(now) {
  if (!now) return ""
  if (now.isAd) return now.show || "Ad break"
  var parts = [now.artist, now.title].filter(function(p) { return p })
  return parts.length > 0 ? parts.join(" – ") : (now.show || "")
}

function channelRow(channel, now, section, playingId) {
  return { kind: "channel", section: section || "", lead: channel.number, title: channel.name,
    subtitle: nowLine(now) || channel.genre || "", detail: channel.favorite ? FAVORITE : channel.number,
    channelId: channel.id, number: channel.number, name: channel.name, favorite: channel.favorite === true,
    artwork: channel.logo ? { url: channel.logo } : undefined, noQueue: true,
    playing: channel.id === playingId, missing: channel.available === false }
}

// The channel list: favorites first, then every channel by number.
function channelRows(channels, nowPlaying, playingId) {
  var rows = []
  var favorites = channels.filter(function(c) { return c.favorite })
  favorites.forEach(function(c, i) { rows.push(channelRow(c, nowPlaying[c.id], i === 0 ? "FAVORITES" : "", playingId)) })
  channels.forEach(function(c, i) { rows.push(channelRow(c, nowPlaying[c.id], i === 0 ? "ALL CHANNELS" : "", playingId)) })
  return rows
}

// Search: a channel number, or words in the name, genre, or what's on now.
// Exact numbers and name matches first.
function searchRows(channels, nowPlaying, query, fold, playingId) {
  var q = fold(query.trim())
  if (q === "") return []
  var scored = []
  channels.forEach(function(c) {
    var name = fold(c.name)
    var score = c.number === q ? 0 : name.indexOf(q) === 0 ? 1 : name.indexOf(q) >= 0 ? 2
      : fold(c.genre).indexOf(q) >= 0 ? 3 : fold(nowLine(nowPlaying[c.id])).indexOf(q) >= 0 ? 4 : -1
    if (score >= 0) scored.push({ channel: c, score: score })
  })
  scored.sort(function(a, b) { return a.score - b.score || numberOf(a.channel) - numberOf(b.channel) })
  function group(score) { return score >= 4 ? "PLAYING NOW" : score >= 3 ? "BY GENRE" : "CHANNELS" }
  return scored.map(function(s, i) {
    var section = i === 0 || group(s.score) !== group(scored[i - 1].score) ? group(s.score) : ""
    return channelRow(s.channel, nowPlaying[s.channel.id], section, playingId)
  })
}

function numberOf(channel) {
  var n = parseInt(channel.number, 10)
  return isNaN(n) ? 1e6 : n
}

// n and p: the next or previous favorite when the channel playing is one,
// else the next or previous channel by number. Wraps around.
function stepChannel(channels, currentId, delta) {
  var current = channels.filter(function(c) { return c.id === currentId })[0]
  var ring = current && current.favorite ? channels.filter(function(c) { return c.favorite }) : channels
  ring = ring.filter(function(c) { return c.available !== false })
  if (ring.length === 0) return null
  var at = ring.indexOf(current)
  if (at < 0) return ring[0]
  return ring[(at + delta + ring.length) % ring.length]
}

// The channel playing, as mpd's currentsong would have it: the song as the
// title, the channel as the album.
function songAsMpd(channel, now, file) {
  if (!channel) return {}
  var song = { file: file || "", album: channel.number ? channel.name + " · " + channel.number : channel.name, genre: channel.genre || "" }
  if (now && !now.isAd && (now.title || now.artist)) {
    song.title = now.title || ""
    song.artist = now.artist || ""
  } else {
    song.title = now && now.show ? now.show : channel.name
    song.artist = now && now.isAd ? "Ad break" : ""
  }
  return song
}

if (typeof module !== "undefined") {
  module.exports = {
    streamPrefix: streamPrefix,
    channelIdOf: channelIdOf,
    nowLine: nowLine,
    channelRows: channelRows,
    searchRows: searchRows,
    stepChannel: stepChannel,
    songAsMpd: songAsMpd
  }
}
