import QtQuick
import Quickshell
import Quickshell.Io
import "Mpd.js" as Mpd
import "Places.js" as Places
import "Radio.js" as Radio

// Internet radio: stations from Radio Browser (radio-browser.info, free and
// keyless), played by mpd straight from the station's stream. Favorites are
// the mpd stored playlist "Radio", so mpc sees them too; local stations are
// those of the radioArea setting (a city, region or country, found in
// places.tsv on this machine, Places.js), else of the US state the older
// radioState setting or ~/.config/omarock/radio.json named. They're kept in
// ~/.cache/omarock/radio-local.json for a day.
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
  // Every station seen, by uuid; the favorites in the playlist's order; the
  // area's stations (Radio.localStations).
  property var stations: ({})
  property var favorites: []
  property var local: []
  // Where "local" is: the radioArea setting, else (before 0.9.7) a US state
  // from the radioState setting or ~/.config/omarock/radio.json ({ "state":
  // "Washington" }).
  property string setArea: ""
  property string setPlace: ""
  property string filePlace: ""
  readonly property bool legacyArea: root.setArea === ""
  readonly property string areaText: root.setArea !== "" ? root.setArea : root.setPlace !== "" ? root.setPlace : root.filePlace
  // The time zone that says which country a place is likelier in (the
  // timeZone setting, else TZ, else the machine's); and where the cache goes.
  property string timeZone: ""
  property string cacheDir: ""
  // The area found (Places.area), and how finding it goes: "" (none set),
  // "finding", "found" or "unknown" (no place by that name).
  property var area: null
  property string areaState: ""
  // When the local stations were last searched for (ms), 0 never.
  property double localMade: 0
  property bool localSearching: false
  // The local section's name ("near Portland"), and the area in full
  // ("Portland, Maine, United States, with New Hampshire").
  readonly property string place: Radio.localPlace(root.area)
  readonly property string areaLabel: Places.describe(root.area)
  onAreaTextChanged: if (root.cacheRead) root.findArea()
  onTimeZoneChanged: if (root.cacheRead) root.findArea()
  readonly property string playlist: "Radio"
  // Logo and artwork URLs checked before an Image loads them: url -> "ok",
  // "bad" or "pending". Radio Browser's logos are often dead links, and a
  // failed Image logs to the journal; a failed check doesn't.
  property var logos: ({})

  readonly property string currentUuid: root.mpd ? Radio.uuidOf(root.mpd.currentSong.file || "") : ""
  readonly property var station: root.stations[root.currentUuid] || null
  readonly property string rawTitle: root.mpd && root.mpd.currentSong ? root.mpd.currentSong.title || "" : ""
  readonly property var song: Radio.parseTitle(root.rawTitle, root.titleForm)
  readonly property bool ready: root.mpd !== null && root.mpd.ready
  readonly property var currentSong: Radio.songAsMpd(root.mpd ? root.mpd.currentSong : null, root.station, root.titleForm)

  // How each station writes its titles: most "Artist - Title", some "Title
  // - Artist", some with a show's name in front ("The World's Your Oyster:
  // Dumb - Nirvana", WRCT). Learned from your library (Radio.titleVotes):
  // votes by station uuid, { artist, title, show }, each up to 9, kept in
  // ~/.cache/omarock/radio-titles.json. Radio.titleForm reads them.
  property var titleVotes: ({})
  readonly property var titleForm: Radio.titleForm(root.titleVotes[root.currentUuid])
  // Each station's title before this one (a show's name said twice is a
  // show's), and the last title asked about.
  property var lastTitles: ({})
  property string titleAsked: ""
  readonly property bool titlePlaying: root.mpd !== null && root.mpd.status.state === "play"
  onRawTitleChanged: titleTimer.restart()
  onTitlePlayingChanged: if (root.titlePlaying) titleTimer.restart()
  // A few seconds after a title arrives: by then the stream has started, and
  // nothing more is sent to mpd while one starts (MpdClient.playStream).
  Timer {
    id: titleTimer
    interval: 3000
    onTriggered: root.learnTitle()
  }
  function learnTitle() {
    var uuid = root.currentUuid, raw = root.rawTitle
    if (uuid === "" || raw === "" || !root.titlePlaying || !root.mpd.ready) return
    if (root.mpd.streamTuning !== "") {
      titleTimer.restart()
      return
    }
    if (root.titleAsked === uuid + "\n" + raw) return
    root.titleAsked = uuid + "\n" + raw
    // Only a song's title: a station saying its own name between songs isn't
    // the title before.
    var questions = Radio.titleQuestions(raw)
    if (!questions) return
    var previous = root.lastTitles[uuid] || ""
    var last = Object.assign({}, root.lastTitles)
    last[uuid] = raw
    root.lastTitles = last
    var keys = [], commands = []
    function ask(key, filters) {
      if (filters.some(function(f) { return f === "" })) return
      keys.push(key)
      commands.push(Mpd.command("count", [filters.length === 1 ? filters[0] : Mpd.andFilter(filters)]))
    }
    function artist(name) { var p = Mpd.exactPattern(name); return p === "" ? "" : Mpd.tagFilter("artist", "=~", p) }
    function title(name) { var p = Mpd.exactPattern(name); return p === "" ? "" : Mpd.tagFilter("title", "=~", p) }
    ask("artistFirst", [artist(questions.artistFirst)])
    if (questions.bareArtist !== "") ask("bareArtist", [artist(questions.bareArtist)])
    ask("titleFirst", [artist(questions.titleFirst)])
    if (questions.bareTitle !== "") ask("bareTitle", [artist(questions.titleFirst), title(questions.bareTitle)])
    if (commands.length === 0) return
    root.mpd.send(Mpd.commandListOk(commands), function(lines, error) {
      if (!root || typeof root.learnTitle !== "function" || error !== "") return
      var known = {}
      Mpd.splitReplies(lines).forEach(function(reply, i) {
        known[keys[i]] = (parseInt(Mpd.parseObject(reply).songs, 10) || 0) > 0
      })
      root.addTitleVotes(uuid, Radio.titleVotes(questions, known, previous))
    }, true)
  }
  function addTitleVotes(uuid, votes) {
    if (!votes.artist && !votes.title && !votes.show) return
    var had = root.titleVotes[uuid] || {}
    var all = Object.assign({}, root.titleVotes)
    all[uuid] = {
      artist: Math.min(9, (had.artist || 0) + votes.artist),
      title: Math.min(9, (had.title || 0) + votes.title),
      show: Math.min(9, (had.show || 0) + votes.show)
    }
    root.titleVotes = all
    if (root.cacheDir === "") return
    titlesWriter.feed(["sh", "-c", 'umask 077; mkdir -p "$1" && cat > "$1/radio-titles.json.new.$$" && mv "$1/radio-titles.json.new.$$" "$1/radio-titles.json"',
      "sh", root.cacheDir], JSON.stringify(all))
  }
  StdinProcess {
    id: titlesWriter
    stderr: StdioCollector {}
  }
  Process {
    id: titlesReader
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var votes = null
        try { votes = text ? JSON.parse(text) : null } catch (e) {}
        // Learned while this was being read: those stay.
        if (votes && typeof votes === "object") root.titleVotes = Object.assign(votes, root.titleVotes)
      }
    }
    stderr: StdioCollector {}
  }
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
    id: placeFile
    path: Quickshell.env("HOME") + "/.config/omarock/radio.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var config = {}
      try { config = JSON.parse(text()) || {} } catch (e) {}
      root.filePlace = config.state || ""
    }
    onLoadFailed: root.filePlace = ""
    onFileChanged: reload()
  }

  // Read radio.json again: a file made after omarock loaded isn't watched.
  function rereadPlace() { placeFile.reload() }

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

  // ---------- Local stations ----------

  // Where the area is: the cache's, when it's for the same words; else
  // looked up in places.tsv (read for this only, then let go), in the time
  // zone's country first. The old setting was a US state, so it's looked
  // for in the US.
  // The newest lookup and search win: one still under way is dropped.
  property int findSeq: 0
  property int localSeq: 0
  function findArea() {
    var text = root.areaText.trim()
    var seq = ++root.findSeq
    root.localSeq++
    root.localSearching = false
    if (text === "") {
      root.area = null
      root.areaState = ""
      root.local = []
      return
    }
    if (root.cached && root.cached.text === text && root.cached.legacy === root.legacyArea && root.cached.zone === root.timeZone
        && root.cached.area) {
      root.area = root.cached.area
      root.areaState = "found"
      root.local = root.cached.stations || []
      root.localMade = root.cached.made || 0
      root.remember(root.local)
      root.refreshLocal(false)
      return
    }
    root.areaState = "finding"
    root.area = null
    root.local = []
    root.localMade = 0
    root.withZone(function(zone) {
      root.withPlaces(function(index) {
        if (seq !== root.findSeq) return
        var prefer = root.legacyArea ? "US" : Places.countryOfZone(index, zone)
        var place = Places.find(index, text, prefer)
        root.area = place ? Places.area(index, place) : null
        root.areaState = place ? "found" : "unknown"
        if (place) root.refreshLocal(true)
      })
    })
  }

  // The time zone: the setting, else TZ, else /etc/localtime's link.
  function withZone(callback) {
    var zone = root.timeZone !== "" ? root.timeZone : Quickshell.env("TZ") || ""
    if (zone !== "") return callback(zone)
    zoneReader.callbacks = zoneReader.callbacks.concat([callback])
    zoneReader.running = true
  }
  Process {
    id: zoneReader
    property var callbacks: []
    command: ["readlink", "/etc/localtime"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var zone = String(text || "").trim().replace(/^.*zoneinfo\//, "")
        var callbacks = zoneReader.callbacks
        zoneReader.callbacks = []
        callbacks.forEach(function(callback) { callback(zone) })
      }
    }
    stderr: StdioCollector {}
  }

  // places.tsv, beside this file, parsed; read when an area is looked up.
  property var placesWaiting: []
  function withPlaces(callback) {
    root.placesWaiting = root.placesWaiting.concat([callback])
    placesFile.path = decodeURIComponent(Qt.resolvedUrl("places.tsv").toString().replace(/^file:\/\//, ""))
  }
  FileView {
    id: placesFile
    printErrors: false
    onLoaded: {
      var index = Places.parse(text())
      var waiting = root.placesWaiting
      root.placesWaiting = []
      path = ""
      waiting.forEach(function(callback) { callback(index) })
    }
    // Only a lookup that was waiting failed: letting go of the file isn't one.
    onLoadFailed: {
      if (root.placesWaiting.length === 0) return
      root.placesWaiting = []
      root.areaState = "unknown"
    }
  }

  // The area's stations, searched for again once they're a day old (or
  // when force). The searches (Radio.localQueries) go one after another.
  function refreshLocal(force) {
    if (!root.area) {
      if (root.areaState !== "finding") root.local = []
      return
    }
    if (!force && (root.localSearching || Date.now() - root.localMade < 24 * 3600 * 1000)) return
    var area = root.area
    var queries = Radio.localQueries(area)
    var found = [], answered = 0
    var seq = ++root.localSeq
    root.localSearching = true
    function next(i) {
      if (seq !== root.localSeq) return
      if (i >= queries.length) {
        root.localSearching = false
        // Nothing answered (Radio Browser down): keep what there was.
        if (answered === 0) return
        var stations = Radio.localStations(area, found, Places)
        root.remember(stations)
        root.local = stations
        root.localMade = Date.now()
        root.writeCache()
        return
      }
      root.get("/json/stations/search?" + queries[i], function(data) {
        if (data) {
          answered++
          found = found.concat(data)
        }
        next(i + 1)
      })
    }
    next(0)
  }

  // ~/.cache/omarock/radio-local.json: the area found for those words and
  // its stations, so a restart needs neither places.tsv nor a search.
  property bool cacheRead: false
  property var cached: null
  readonly property var cacheFields: ["stationuuid", "name", "url", "url_resolved", "favicon", "tags", "country",
    "countrycode", "state", "iso_3166_2", "language", "homepage", "codec", "bitrate", "hls", "lastcheckok",
    "lastchecktime_iso8601", "clickcount", "votes", "geo_lat", "geo_long"]
  function writeCache() {
    if (root.cacheDir === "" || !root.area) return
    var stations = root.local.map(function(s) {
      var out = {}
      root.cacheFields.forEach(function(k) { if (s[k] !== undefined) out[k] = s[k] })
      return out
    })
    root.cached = { text: root.areaText.trim(), legacy: root.legacyArea, zone: root.timeZone, area: root.area, stations: stations,
      made: root.localMade }
    cacheWriter.feed(["sh", "-c", 'umask 077; mkdir -p "$1" && cat > "$1/radio-local.json.new" && mv "$1/radio-local.json.new" "$1/radio-local.json"',
      "sh", root.cacheDir], JSON.stringify(root.cached))
  }
  StdinProcess {
    id: cacheWriter
    stderr: StdioCollector {}
  }
  Process {
    id: cacheReader
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.cached = text ? JSON.parse(text) : null } catch (e) { root.cached = null }
        root.cacheRead = true
        root.findArea()
      }
    }
    stderr: StdioCollector {}
  }
  Component.onCompleted: {
    if (root.cacheDir === "") {
      root.cacheRead = true
      root.findArea()
      return
    }
    cacheReader.command = ["cat", root.cacheDir + "/radio-local.json"]
    cacheReader.running = true
    titlesReader.command = ["cat", root.cacheDir + "/radio-titles.json"]
    titlesReader.running = true
  }

  // The favorites: the "Radio" playlist's stations, looked up by uuid.
  function refreshFavorites(callback) {
    if (!root.mpd) return
    // No "Radio" playlist yet: no favorites (and no error from mpd to show).
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
    root.refreshLocal(true)
  }

  // The now playing card's art: the song's, else the station's logo.
  readonly property string art: root.logoUrl(root.song.art) || root.logoUrl(root.station ? root.station.favicon : "")
  onSongChanged: root.checkLogo(root.song.art)
  onStationChanged: if (root.station) root.checkLogo(root.station.favicon)

  // The station playing, looked up if it isn't known yet (after a restart).
  // And what it sends learned from (titleTimer).
  onCurrentUuidChanged: {
    titleTimer.restart()
    if (root.currentUuid !== "" && !root.stations[root.currentUuid])
      root.get("/json/stations/byuuid?uuids=" + root.currentUuid, function(data) { root.remember(data) })
  }
}
