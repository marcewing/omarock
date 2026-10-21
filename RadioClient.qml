import QtQuick
import Quickshell
import Quickshell.Io
import "Mpd.js" as Mpd
import "Radio.js" as Radio

// Internet radio: stations from Radio Browser (radio-browser.info, free and
// keyless), played by mpd straight from the station's stream. Favourites are
// the mpd stored playlist "Radio", so mpc sees them too; local stations come
// from the state in ~/.config/omarock/radio.json ({ "state": "Washington" }).
// Where the player card and the bar read the player it has MpdClient's shape;
// changing station is asked of the panel (tuneRequested), which retunes mpd.
Item {
  id: root

  // A Radio Browser server ("https://de1.api.radio-browser.info"); empty
  // picks one from the list the project publishes.
  property string api: ""
  property var mpd: null
  property bool active: false
  property bool watching: false

  property string server: ""
  property string lastError: ""
  // Every station seen, by uuid; the favourites in the playlist's order; the
  // most listened stations in `place`.
  property var stations: ({})
  property var favorites: []
  property var local: []
  property string place: ""
  readonly property string playlist: "Radio"
  // Logo and artwork URLs checked before an Image loads them: url -> "ok",
  // "bad" or "pending". Radio Browser's logos are often dead links, and a
  // failed Image logs to the journal; a failed check doesn't.
  property var logos: ({})

  readonly property string currentUuid: root.mpd ? Radio.uuidOf(root.mpd.currentSong.file || "") : ""
  readonly property var station: root.stations[root.currentUuid] || null
  readonly property var song: Radio.parseTitle(root.mpd && root.mpd.currentSong ? root.mpd.currentSong.title : "")
  readonly property bool ready: root.mpd !== null && root.mpd.ready
  readonly property var currentSong: Radio.songAsMpd(root.mpd ? root.mpd.currentSong : null, root.station)
  // Live radio: no seeking, no queue position, no shuffle or repeat.
  readonly property var status: ({
    state: root.mpd ? root.mpd.status.state : "stop", volume: root.mpd ? root.mpd.status.volume : -1,
    elapsed: 0, duration: 0, song: -1, songId: root.currentUuid, random: false, repeat: false,
    single: false, consume: false, queueLength: 0, updating: false, error: ""
  })
  readonly property real elapsed: 0
  readonly property var queue: []

  signal tuneRequested(var station)

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarock/radio.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var config = {}
      try { config = JSON.parse(text()) || {} } catch (e) {}
      root.place = config.state || ""
      root.refreshLocal()
    }
    onLoadFailed: root.place = ""
    onFileChanged: reload()
  }

  function xhr(url, callback) {
    var request = new XMLHttpRequest()
    request.onreadystatechange = function() {
      // A reply that arrives after a plugin reload destroyed this client
      // (Apple Music's long poll, say) has nowhere to go. Mid-teardown the
      // client may still be there with its functions gone ("Property
      // 'logTiming' … is not a function").
      if (request.readyState !== XMLHttpRequest.DONE || !root || typeof root.xhr !== "function") return
      var data = null
      try { data = request.responseText ? JSON.parse(request.responseText) : null } catch (e) {}
      if (request.status >= 200 && request.status < 300 && data !== null) callback(data, "")
      else callback(null, request.status === 0 ? "Can't reach Radio Browser" : "Radio Browser said " + request.status)
    }
    request.open("GET", url)
    request.send()
  }

  // A server to ask: the setting, else one from Radio Browser's own list.
  function withServer(callback) {
    if (root.api !== "") return callback(root.api)
    if (root.server !== "") return callback(root.server)
    root.xhr("https://all.api.radio-browser.info/json/servers", function(list) {
      var names = (list || []).map(function(s) { return s.name }).filter(function(n) { return n })
      root.server = "https://" + (names.length > 0 ? names[Math.floor(Math.random() * names.length)] : "de1.api.radio-browser.info")
      callback(root.server)
    })
  }

  function get(path, callback) {
    root.withServer(function(base) {
      root.xhr(base + path, function(data, error) {
        if (error !== "") root.lastError = error
        if (callback) callback(data, error)
      })
    })
  }

  function remember(list) {
    var known = Object.assign({}, root.stations)
    ;(list || []).forEach(function(s) { if (s && s.stationuuid) known[s.stationuuid] = s })
    root.stations = known
  }

  // Search by name (call signs and frequencies are in the names) and by tag,
  // the most listened first.
  function search(query, callback) {
    var q = encodeURIComponent(query.trim())
    var order = "&hidebroken=true&order=clickcount&reverse=true"
    var byName = null, byTag = null, pending = 2
    function done() {
      if (--pending > 0) return
      var found = (byName || []).concat(byTag || [])
      root.remember(found)
      callback(byName || byTag ? found : null, root.lastError)
    }
    root.get("/json/stations/search?name=" + q + order + "&limit=30", function(data) { byName = data; done() })
    root.get("/json/stations/search?tag=" + q + order + "&limit=15", function(data) { byTag = data; done() })
  }

  // The most listened stations in `place`. The directory's state field is
  // filled in by volunteers and often left out, so stations with the state's
  // name in their name or tags count too.
  function refreshLocal() {
    if (root.place === "") {
      root.local = []
      return
    }
    var place = encodeURIComponent(root.place)
    var common = "&countrycode=US&hidebroken=true&order=clickcount&reverse=true&limit=40"
    var found = [], pending = 3
    function done(data) {
      if (data) found = found.concat(data)
      if (--pending > 0) return
      var seen = {}
      var stations = found.filter(function(s) {
        if (seen[s.stationuuid]) return false
        seen[s.stationuuid] = true
        return true
      }).sort(function(a, b) { return (b.clickcount || 0) - (a.clickcount || 0) })
      root.remember(stations)
      root.local = stations
    }
    root.get("/json/stations/search?state=" + place + "&stateExact=true" + common, done)
    root.get("/json/stations/search?name=" + place + common, done)
    root.get("/json/stations/search?tag=" + place.toLowerCase() + common, done)
  }

  // The favourites: the "Radio" playlist's stations, looked up by uuid.
  function refreshFavorites(callback) {
    if (!root.mpd) return
    // No "Radio" playlist yet: no favourites (and no error from mpd to show).
    if (!root.mpd.playlists.some(function(p) { return p.name === root.playlist })) {
      root.favorites = []
      if (callback) callback()
      return
    }
    root.mpd.playlistSongs(root.playlist, function(songs) {
      var uuids = (songs || []).map(function(s) { return Radio.uuidOf(s.file) }).filter(function(u) { return u })
      if (uuids.length === 0) {
        root.favorites = []
        if (callback) callback()
        return
      }
      root.get("/json/stations/byuuid?uuids=" + uuids.join(","), function(data) {
        root.remember(data)
        root.favorites = uuids.map(function(u) { return root.stations[u] }).filter(function(s) { return s })
        if (callback) callback()
      })
    })
  }

  function isFavorite(uuid) {
    return root.favorites.some(function(s) { return s.stationuuid === uuid })
  }

  function toggleFavorite(uuid, callback) {
    var station = root.stations[uuid]
    if (!station || !root.mpd) return
    if (root.isFavorite(uuid)) {
      root.mpd.playlistSongs(root.playlist, function(songs) {
        var at = (songs || []).findIndex(function(s) { return Radio.uuidOf(s.file) === uuid })
        if (at < 0) return
        root.mpd.removeFromPlaylist(root.playlist, at, function(error) { if (callback) callback(error, false) })
      })
    } else {
      root.mpd.send(Mpd.command("playlistadd", [root.playlist, Radio.streamUrl(station)]), function(lines, error) {
        if (callback) callback(error, true)
      })
    }
  }

  // A logo's URL once it's known to load, else "" (and a check starts).
  function logoUrl(url) {
    return url && root.logos[url] === "ok" ? url : ""
  }

  function checkLogo(url) {
    if (!url || root.logos[url] !== undefined) return
    root.setLogo(url, "pending")
    var request = new XMLHttpRequest()
    request.onreadystatechange = function() {
      // A reply that arrives after a plugin reload destroyed this client
      // (Apple Music's long poll, say) has nowhere to go. Mid-teardown the
      // client may still be there with its functions gone ("Property
      // 'logTiming' … is not a function").
      if (request.readyState !== XMLHttpRequest.DONE || !root || typeof root.xhr !== "function") return
      var type = request.getResponseHeader("Content-Type") || ""
      root.setLogo(url, request.status >= 200 && request.status < 300 && type.indexOf("image/") === 0 ? "ok" : "bad")
    }
    request.open("GET", url)
    request.responseType = "arraybuffer"
    request.send()
  }

  function setLogo(url, state) {
    var logos = Object.assign({}, root.logos)
    logos[url] = state
    root.logos = logos
  }

  // Radio Browser counts plays, to rank stations; it asks clients to say.
  function click(uuid) {
    root.get("/json/url/" + encodeURIComponent(uuid), null)
  }

  function playPause() {
    if (root.mpd) root.mpd.send(root.mpd.status.state === "play" ? "stop" : "play")
  }
  function next() { root.step(1) }
  function previous() { root.step(-1) }
  function step(delta) {
    var target = Radio.stepStation(root.favorites, root.currentUuid, delta)
    if (target) root.tuneRequested(target)
  }
  function seekTo(seconds) {}
  function seekBy(delta) {}
  function setRandom(on) {}
  function setRepeat(on) {}
  function setVolume(value) { if (root.mpd) root.mpd.setVolume(value) }

  // A different server (the setting changed): start over with it.
  onApiChanged: {
    root.server = ""
    root.refreshLocal()
  }

  // The now playing card's art: the song's, else the station's logo.
  readonly property string art: root.logoUrl(root.song.art) || root.logoUrl(root.station ? root.station.favicon : "")
  onSongChanged: root.checkLogo(root.song.art)
  onStationChanged: if (root.station) root.checkLogo(root.station.favicon)

  // The station playing, looked up if it isn't known yet (after a restart).
  onCurrentUuidChanged: {
    if (root.currentUuid !== "" && !root.stations[root.currentUuid])
      root.get("/json/stations/byuuid?uuids=" + root.currentUuid, function(data) { root.remember(data) })
  }
}
