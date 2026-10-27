import QtQuick
import Quickshell.Io
import "Apple.js" as Apple
import "Info.js" as Info

// The Apple Music bridge on the Mac (bridge/API.md), over HTTP on the
// tailnet. Where the player card and the bar read the player, it has
// MpdClient's shape: ready, lastError, status, currentSong, elapsed and the
// transport functions. Volume stays mpd's, and so does the sound: mpd plays
// the bridge's stream, so play also makes sure mpd is playing it.
//
// Spotify's service (spotify/omarock-spotify.py, on this machine) speaks the
// same API, so a second one drives it, with streamed false: Soloist plays into
// omarock's bus itself, not through mpd.
Item {
  id: root

  property string baseUrl: ""
  property string tokenFile: ""
  property var mpd: null
  // The service, as the panel names it, and its key in Info.js.
  property string service: "Apple Music"
  property string serviceKey: "apple"
  // Whether its sound comes through mpd (the bridge's stream).
  property bool streamed: true
  // Whether songs can be taken out of its queue (Spotify's can't).
  property bool canRemove: true
  // Whether things can be taken out of your library (Apple Music's API can
  // only add), and what to update when the service can't do either yet.
  property bool canUnsave: false
  property string libraryUpdateText: "To add to your library, update the bridge on the Mac (./install there)"
  // For the errors the panel shows.
  property string bridgeName: "The Apple Music bridge"
  property string unreachableText: "Can't reach the Apple Music bridge on the Mac"
  property string unauthorizedText: "Apple Music access isn't allowed on the Mac yet"
  // How long to wait before trying again when the status fails.
  property int retryMs: 3000
  // Follow the bridge's status (a long poll) while true: in Apple Music mode;
  // always, for Spotify, whose status says whether it is the source.
  property bool active: false
  property bool ticking: false
  // Stop mpd once the Mac has been paused or stopped this long (0: never).
  property int idleStopSeconds: 60
  // This machine's name, sent with every request (X-Omarock-Client). Apple
  // Music and Spotify play on one machine at a time: the one that last
  // pressed Play. The others hear nothing, and are told where it plays.
  property string clientName: ""
  // Reconnect mpd to the stream 2 s after each change made here (catchUp).
  // Only for a stock libFLAC, which falls behind on a quiet stream; with
  // the patched one (tools/build-libflac) mpd stays about 0.3 s behind by
  // itself, and the reconnect is a stutter 2 s into every song.
  property bool rejoinAfterChange: false

  property string token: ""
  property bool reachable: false
  // How often a request failed outright (reachable went false), for tests.
  property int dropouts: 0
  property bool authorized: false
  // What /v1/health said last. A status reply also sets `authorized` (the
  // token works), but omarock-spotify answers status before it's signed in.
  property bool healthAuthorized: false
  property bool canPlayCatalog: false
  property string lastError: ""
  // The bridge's own status (API.md, "Status") and current Song.
  property var bridgeStatus: ({})
  property var genres: []
  // Your Apple Music playlists, as the picker wants them: { name, modified, ... }.
  property var playlists: []
  property real elapsed: 0
  property real elapsedBase: 0
  property real elapsedAt: 0
  property int pollSequence: 0
  // Requests in flight, aborted when they outlive their deadline.
  property var inflight: []

  readonly property bool configured: baseUrl !== ""
  readonly property bool ready: reachable && authorized
  readonly property var song: bridgeStatus.song || null
  readonly property var currentSong: Apple.songAsMpd(bridgeStatus.song)
  // Spotify without omarock's sound output: Soloist's own volume is the
  // volume, and its status has it. Otherwise it's mpd's (or the bus's).
  // (Tested here, not through ownVolume, which can lag a new status.)
  readonly property var status: Apple.statusAsMpd(bridgeStatus,
    typeof bridgeStatus.volume === "number" ? bridgeStatus.volume : mpd ? mpd.status.volume : -1)
  readonly property bool ownVolume: typeof bridgeStatus.volume === "number"
  readonly property var queue: bridgeStatus.queue || []
  // Spotify's: whether it is omarock's source now (it played since mpd did,
  // or omarock switched to it).
  readonly property bool current: bridgeStatus.current === true
  // The machine it plays on instead ("dellxps"), or "": here it's paused,
  // and Play moves it here. Pause, skip and seek are refused meanwhile.
  readonly property string elsewhere: bridgeStatus.elsewhere || ""

  // Another machine took the Mac's music: this one's mpd stops listening,
  // and the Mac plays on for it.
  onElsewhereChanged: root.leaveStream()
  function leaveStream() {
    if (root.elsewhere !== "" && root.streamed && root.active && root.mpd && root.mpd.status.state === "play") root.mpd.send("stop")
  }

  FileView {
    id: tokenView
    path: root.tokenFile
    watchChanges: true
    printErrors: false
    onLoaded: root.token = text().trim()
    onFileChanged: reload()
    onLoadFailed: root.token = ""
  }

  // Read the token again: a file made after omarock loaded isn't watched.
  function reloadToken() { tokenView.reload() }

  // One HTTP request; callback(data, error) with error "" on success.
  function request(method, path, body, callback, timeoutMs) {
    if (!root.configured) {
      if (callback) callback(null, root.service + " isn't set up")
      return
    }
    var xhr = new XMLHttpRequest()
    var entry = { xhr: xhr, deadline: Date.now() + (timeoutMs || 10000), timedOut: false, path: path.split("?")[0],
      sentAt: Date.now(), ahead: root.inflight.map(function(e) { return e.path }) }
    xhr.onreadystatechange = function() {
      // A reply that arrives after a plugin reload destroyed this client
      // (Apple Music's long poll, say) has nowhere to go. Mid-teardown the
      // client may still be there with its functions gone ("Property
      // 'logTiming' … is not a function").
      if (xhr.readyState !== XMLHttpRequest.DONE || !root || typeof root.logTiming !== "function") return
      root.inflight = root.inflight.filter(function(e) { return e !== entry })
      root.logTiming(method, entry, xhr.status)
      var data = null
      try { data = xhr.responseText ? JSON.parse(xhr.responseText) : null } catch (e) {}
      if (xhr.status >= 200 && xhr.status < 300) {
        root.reachable = true
        if (callback) callback(data, "")
        return
      }
      var error = entry.timedOut ? root.bridgeName + " didn't answer"
        : xhr.status === 0 ? root.unreachableText
        : xhr.status === 401 ? root.bridgeName + " refused omarock's token"
        : (data && data.error) || root.bridgeName + " said " + xhr.status
      if (xhr.status === 0) {
        if (root.reachable) root.dropouts++
        root.reachable = false
      }
      if (callback) callback(null, error)
    }
    xhr.open(method, root.baseUrl + path)
    if (root.token !== "") xhr.setRequestHeader("Authorization", "Bearer " + root.token)
    if (root.clientName !== "") xhr.setRequestHeader("X-Omarock-Client", root.clientName)
    // What tells omarock-spotify the request is omarock's, not a web page's.
    xhr.setRequestHeader("X-Omarock", "1")
    root.inflight = root.inflight.concat([entry])
    if (body !== undefined && body !== null) {
      xhr.setRequestHeader("Content-Type", "application/json")
      xhr.send(JSON.stringify(body))
    } else {
      xhr.send()
    }
  }

  // For the journal, as MpdClient logs slow mpd commands: every transport
  // command (POST), and anything else over 2 s, with what was in flight when
  // it went out (Qt sends at most 6 requests to a host at once). Not the
  // status long poll, which waits on purpose. When a song picked in search
  // takes seconds to play, this says where the time went.
  function logTiming(method, entry, status) {
    var took = Date.now() - entry.sentAt
    // A volume drag sends a run of POSTs: only a slow one is worth a line.
    if (entry.path === "/v1/status" || ((method !== "POST" || entry.path === "/v1/volume") && took <= 2000)) return
    console.info("omarock: " + root.service + " " + method + " " + entry.path + " answered in " + took + " ms ("
      + (status || "no answer") + "), sent with " + entry.ahead.length + " in flight"
      + (entry.ahead.length > 0 ? ": " + entry.ahead.slice(0, 8).join(", ") : ""))
  }

  function get(path, callback, timeoutMs) { root.request("GET", path, null, callback, timeoutMs || 15000) }

  // A transport command; the bridge answers with its new status.
  function post(path, body, callback) {
    root.request("POST", path, body || {}, function(data, error) {
      if (data && data.seq !== undefined) root.applyStatus(data)
      if (error !== "") root.lastError = error
      if (callback) callback(data, error)
    }, 15000)
  }

  // The last /v1/health answer: omarock-spotify's says whether Soloist is
  // signed in (soloist.loggedIn), for the settings. healthKnown: it has
  // answered at least once (or failed to).
  property var health: ({})
  property bool healthKnown: false
  function checkHealth(callback) {
    root.get("/v1/health", function(data, error) {
      root.health = data || {}
      root.healthKnown = true
      root.reachable = !!data
      root.authorized = !!data && data.authorized === true
      root.healthAuthorized = root.authorized
      root.canPlayCatalog = !!data && data.canPlayCatalog === true
      root.lastError = !data ? error
        : !root.authorized ? root.unauthorizedText : ""
      if (root.ready && root.genres.length === 0) root.refreshGenres()
      if (callback) callback(root.ready, root.lastError)
    }, 5000)
  }

  function applyStatus(data) {
    root.bridgeStatus = data
    root.elapsedBase = data.position || 0
    root.elapsedAt = Date.now()
    root.elapsed = root.elapsedBase
    root.fillSongLinks()
  }

  // The playing song's album and artist ids, and whether it's in your library,
  // by song key, for the songs whose status doesn't say (MusicKit's queue
  // entries often lack the ids; older bridges never say inLibrary, nor any
  // bridge for a library song, which may be only on a playlist added to the
  // library): asked of /v1/info once a song, { albumId, artistId, source,
  // inLibrary, catalogId }, or null while asking.
  property var songLinks: ({})

  function fillSongLinks() {
    var song = root.song
    if (!song || !song.id) return
    if (song.albumId && song.artistId && song.inLibrary !== undefined) return
    var key = Apple.songKey(song)
    if (root.songLinks[key] !== undefined) return
    var asking = Object.assign({}, root.songLinks)
    asking[key] = null
    root.songLinks = asking
    root.get("/v1/info/" + song.source + "/song/" + encodeURIComponent(song.id), function(data) {
      var item = data && data.item ? data.item : {}
      var links = Object.assign({}, root.songLinks)
      links[key] = { albumId: item.albumId || "", artistId: item.artistId || "", source: item.source || song.source,
        inLibrary: data ? data.inLibrary : undefined, catalogId: data && data.catalog ? data.catalog.id || "" : "" }
      root.songLinks = links
    })
  }

  // Add to your library (songs, albums, and Apple Music's playlists), or,
  // where canUnsave, take out of it. callback(error, reply), "" when done.
  function saveToLibrary(items, save, callback) {
    root.request("POST", save ? "/v1/library/add" : "/v1/library/remove", { items: items }, function(data, error) {
      if (callback) callback(error === "No such endpoint." ? root.libraryUpdateText : error, data)
    }, 30000)
  }

  // The long poll: the bridge answers at once when its status moved past
  // ours, else after up to 25 s.
  function poll() {
    // Called later (Qt.callLater) by a reply that landed mid-reload: the
    // client may be half torn down by then ("Property 'get' … is not a function").
    if (!root || typeof root.get !== "function") return
    var sequence = ++root.pollSequence
    var since = root.bridgeStatus.seq
    root.get("/v1/status" + (since !== undefined ? "?since=" + since : ""), function(data, error) {
      if (sequence !== root.pollSequence || !root.active) return
      if (data) {
        root.authorized = true
        // A long poll that timed out brings the same status: keep the lists as
        // they are and only re-time the position.
        if (data.seq === root.bridgeStatus.seq && data.state === root.bridgeStatus.state) {
          root.elapsedBase = data.position || 0
          root.elapsedAt = Date.now()
        } else {
          root.applyStatus(data)
        }
        Qt.callLater(root.poll)
      } else {
        root.lastError = error
        retryPoll.restart()
      }
    }, 35000)
  }

  onActiveChanged: {
    if (root.active) root.checkHealth(function() { root.poll() })
    else root.pollSequence++
  }
  Component.onCompleted: if (root.active) root.checkHealth(function() { root.poll() })

  // Playback. Play also starts mpd on the stream when it isn't playing, and
  // takes the music over from another machine.
  function playPause() {
    if (root.bridgeStatus.state === "playing" && root.elsewhere === "" && (!root.streamed || root.mpd.status.state === "play"))
      root.post("/v1/pause")
    else root.resume()
  }
  // Not while it plays on another machine: leaving Apple Music here, say,
  // mustn't stop it there.
  function pause() { if (root.elsewhere === "") root.post("/v1/pause") }
  // The Mac first, then mpd on the stream (see catchUp).
  function resume() { root.post("/v1/resume", {}, root.catchUp) }
  // Only while mpd's source is this stream: a song played here from a lookup
  // (the radio playing) mustn't start the radio.
  function startStream() {
    if (root.streamed && root.active && root.mpd && root.mpd.status.state !== "play") root.mpd.send("play")
  }
  // Spotify: become omarock's source (mpd stops, and Spotify carries on with
  // what it had), or stop being it (Spotify pauses).
  function activate(callback) { root.post("/v1/activate", {}, callback) }
  function release(callback) { root.post("/v1/release", {}, callback) }
  // Once the bridge has made a change asked for here (a song picked, next,
  // previous, a seek, play): mpd plays the stream if it isn't already. With
  // rejoinAfterChange, it also reconnects to the live stream, as below.
  //
  // Why rejoin was needed, before libFLAC was patched: mpd connected to the
  // stream while it was quiet (the bridge idle or paused: about 350 bytes a
  // second) waits until it has enough data, then plays all it buffered, and
  // stays that far behind the Mac (42 s behind, once: the song heard wasn't
  // the one shown, and picking another seemed to do nothing).
  // A network stall does the same. playid of the stream's own entry
  // reconnects at live, with the output left open; mpd stopped just plays.
  // A change reaches the stream 1.5 to 1.8 s after the bridge's reply
  // (measured by recording the stream on the Mac), so mpd rejoins 2 s after
  // it, when the stream carries the new sound: joined while it is still
  // quiet, mpd would be behind again.
  function catchUp(data, error) {
    if (error !== "" || !root.streamed) return
    if (root.rejoinAfterChange) rejoinTimer.restart()
    else root.startStream()
  }
  function rejoin() {
    if (!root.active || !root.mpd) return
    if (root.mpd.status.state === "play" && root.mpd.status.songId !== "") root.mpd.send("playid " + root.mpd.status.songId)
    else root.startStream()
  }

  Timer {
    id: rejoinTimer
    interval: 2000
    onTriggered: root.rejoin()
  }

  // The Mac paused or stopped while mpd still plays its quiet stream. After
  // idleStopSeconds, mpd stops: the mount then has no listener,
  // so the bridge can be updated, and nothing trickles over the tailnet.
  // mpd keeps the stream as its current song, so the mode stays Apple Music.
  // Playing again reconnects, through catchUp (rejoin plays a stopped mpd) or
  // the panel's followMpd for the media keys. With the patched libFLAC, a
  // fresh connection is 0.3 s behind live, so holding the stream gains little.
  readonly property bool idle: root.streamed && root.active && root.ready && root.idleStopSeconds > 0 && !!root.mpd
    && root.mpd.status.state === "play"
    && (root.bridgeStatus.state === "paused" || root.bridgeStatus.state === "stopped")
  onIdleChanged: if (root.idle) idleStop.restart(); else idleStop.stop()

  Timer {
    id: idleStop
    interval: root.idleStopSeconds * 1000
    onTriggered: if (root.idle) root.mpd.send("stop")
  }
  function next() { root.post("/v1/next", {}, root.catchUp) }
  function previous() { root.post("/v1/previous", {}, root.catchUp) }
  function seekTo(seconds) {
    root.elapsedBase = seconds
    root.elapsedAt = Date.now()
    root.elapsed = seconds
    root.post("/v1/seek", { position: seconds }, root.catchUp)
  }
  function seekBy(delta) { root.seekTo(Math.max(0, root.elapsed + delta)) }
  function setRandom(on) { root.post("/v1/shuffle", { on: on }) }
  function setRepeat(on) { root.post("/v1/repeat", { mode: on ? "all" : "off" }) }
  // Its own volume: one change in flight, a drag sending only the latest.
  property int volumeWanted: -1
  property bool volumeSending: false
  function setVolume(value) {
    if (!root.ownVolume) {
      if (root.mpd) root.mpd.setVolume(value)
      return
    }
    root.volumeWanted = Math.round(Math.max(0, Math.min(100, value)))
    if (!root.volumeSending) root.sendVolume()
  }
  function sendVolume() {
    var value = root.volumeWanted
    root.volumeSending = true
    root.post("/v1/volume", { volume: value }, function() {
      root.volumeSending = false
      if (root.volumeWanted !== value) root.sendVolume()
      else root.volumeWanted = -1
    })
  }
  // + and -: from the volume last asked for.
  function nudgeVolume(delta) {
    if (!root.ownVolume) {
      if (root.mpd) root.mpd.nudgeVolume(delta)
      return
    }
    root.setVolume((root.volumeWanted >= 0 ? root.volumeWanted : root.bridgeStatus.volume) + delta)
  }

  // items: [{ kind, id, source }]; mode "play" (replace the queue, from
  // item start), "next" or "add".
  function playItems(items, mode, start, callback) {
    root.post("/v1/play", { items: items, mode: mode, start: start || 0 }, function(data, error) {
      if (mode === "play") root.catchUp(data, error)
      if (callback) callback(data, error)
    })
  }
  function jump(index) { root.post("/v1/queue/jump", { index: index }, root.catchUp) }
  function removeAt(index) { root.post("/v1/queue/remove", { index: index }) }

  // Browsing.
  // scope: "all" (the default), "library" or "catalog".
  function search(query, callback, scope) {
    root.get("/v1/search?scope=" + (scope || "all") + "&limit=8&q=" + encodeURIComponent(query), callback)
  }
  function album(source, id, callback) { root.get("/v1/albums/" + source + "/" + encodeURIComponent(id), callback) }
  function artist(source, id, callback) { root.get("/v1/artists/" + source + "/" + encodeURIComponent(id), callback) }
  function playlist(source, id, callback) { root.get("/v1/playlists/" + source + "/" + encodeURIComponent(id), callback) }
  function genre(id, callback) { root.get("/v1/genres/" + encodeURIComponent(id) + "?limit=25", callback) }

  // The info card (i): the bridge's /v1/info for a song or album (API.md,
  // "Info"). An older bridge has no such route; then a library search by
  // title tells whether a catalog item is in the library. callback(extra),
  // as Info.appleItem takes it, with error set when neither answered.
  function info(item, callback) {
    root.get("/v1/info/" + item.source + "/" + item.kind + "/" + encodeURIComponent(item.id), function(data, error) {
      if (data) { callback(data); return }
      if (item.source === "library") { callback({ inLibrary: true }); return }
      if (error !== "No such endpoint.") { callback({ error: error }); return }
      root.get("/v1/search?scope=library&limit=25&q=" + encodeURIComponent(item.title || item.name || ""), function(results, searchError) {
        callback(results ? { inLibrary: Info.foundInLibrary(item, results, Apple.foldKey) } : { error: searchError })
      })
    })
  }

  function refreshGenres() {
    root.get("/v1/genres", function(data) { if (data) root.genres = data })
  }

  function refreshPlaylists(callback) {
    root.get("/v1/library/playlists", function(data, error) {
      if (data) root.playlists = data.map(function(p) { return Object.assign({ modified: p.lastModified || "" }, p) })
      if (callback) callback(data, error)
    })
  }

  // Playlists: items are expanded to songs by the bridge.
  function addToPlaylist(id, items, callback) {
    root.request("POST", "/v1/library/playlists/" + encodeURIComponent(id) + "/tracks", { items: items },
      function(data, error) {
        root.refreshPlaylists()
        if (callback) callback(error)
      }, 30000)
  }
  function createPlaylist(name, items, callback) {
    root.request("POST", "/v1/library/playlists", { name: name, items: items }, function(data, error) {
      root.refreshPlaylists()
      if (callback) callback(error)
    }, 30000)
  }

  Timer {
    id: retryPoll
    interval: root.retryMs
    onTriggered: if (root.active) root.checkHealth(function() { root.poll() })
  }

  Timer {
    interval: 500
    repeat: true
    running: root.ticking && root.bridgeStatus.state === "playing"
    onTriggered: {
      var duration = root.song ? root.song.duration || 0 : 0
      var at = root.elapsedBase + (Date.now() - root.elapsedAt) / 1000
      root.elapsed = duration > 0 ? Math.min(duration, at) : at
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.inflight.length > 0
    onTriggered: {
      var now = Date.now()
      root.inflight.forEach(function(entry) {
        if (entry.deadline < now && !entry.timedOut) {
          entry.timedOut = true
          entry.xhr.abort()
        }
      })
    }
  }
}
