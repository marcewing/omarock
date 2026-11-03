import QtQuick
import Quickshell.Io
import "Apple.js" as Apple
import "Heard.js" as Heard
import "Info.js" as Info

// The Apple Music bridge on the Mac (apple-bridge/API.md), over HTTP on the
// tailnet. Where the player card and the bar read the player, it has
// MpdClient's shape: ready, lastError, status, currentSong, elapsed and the
// transport functions. Volume stays mpd's, and so does the sound: mpd plays
// the bridge's stream, so play also makes sure mpd is playing it. mpd plays
// it a couple of seconds behind the Mac, so what the card and the bar show
// is the song and time as heard (Heard.js); bridgeStatus is the Mac's, now.
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
  // The token was refused (HTTP 401) the last time it was sent. With
  // checksToken, each health check sends it too: the bridge's health needs no
  // token, so a refused one showed only once something was asked for.
  property bool tokenRefused: false
  property bool checksToken: false
  // Said after "refused omarock's token": where to put it right.
  property string refusedHint: ""
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
  // Only for a bridge before 0.7.0: its stream's silence was so small that
  // a stock libFLAC fell behind on it. From 0.7.0 (health's minBitrate) mpd
  // keeps up by itself, and the reconnect would be a stutter 2 s into every
  // song.
  property bool rejoinAfterChange: false
  readonly property bool rejoins: root.rejoinAfterChange && root.health.minBitrate !== true

  property string token: ""
  property bool reachable: false
  // How often a request failed outright (reachable went false), for tests.
  property int dropouts: 0
  // A run of requests with no answer, for the journal: when it began (ms,
  // 0: none) and how many there have been.
  property real unansweredSince: 0
  property int unansweredCount: 0
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
  property int pollSequence: 0
  // Requests in flight, aborted when they outlive their deadline.
  property var inflight: []

  readonly property bool configured: baseUrl !== ""
  readonly property bool ready: reachable && authorized
  // The song playing and its place in the queue as heard; the queue and the
  // options are the Mac's now.
  readonly property var heardStatus: Heard.overlay(root.bridgeStatus, root.heard.status)
  readonly property var song: heardStatus.song || null
  readonly property var currentSong: Apple.songAsMpd(heardStatus.song)
  // Spotify without omarock's sound output: Soloist's own volume is the
  // volume, and its status has it. Otherwise it's mpd's (or the bus's).
  // (Tested here, not through ownVolume, which can lag a new status.)
  readonly property var status: Apple.statusAsMpd(heardStatus,
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
      background: path.indexOf("&background=1") >= 0,
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
        if (entry.path !== "/v1/health") root.tokenRefused = false
        if (callback) callback(data, "")
        return
      }
      if (xhr.status === 401) root.tokenRefused = true
      var error = entry.timedOut ? root.bridgeName + " didn't answer"
        : xhr.status === 0 ? root.unreachableText
        : xhr.status === 401 ? root.bridgeName + " refused omarock's token" + root.refusedHint
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
  // takes seconds to play, this says where the time went. While nothing
  // answers (the Mac asleep, a laptop on the move), only the first request
  // and the POSTs, then one line when it answers again.
  function logTiming(method, entry, status) {
    var took = Date.now() - entry.sentAt
    if (root.unansweredSince > 0) {
      if (!status) {
        root.unansweredCount++
        if (method !== "POST") return
      } else {
        var gone = Math.round((Date.now() - root.unansweredSince) / 1000)
        console.info("omarock: " + root.service + " answers again, after " + (gone < 120 ? gone + " s" : Math.round(gone / 60) + " min")
          + " and " + root.unansweredCount + (root.unansweredCount === 1 ? " request" : " requests") + " with no answer")
        root.unansweredSince = 0
        root.unansweredCount = 0
      }
    }
    // A volume drag sends a run of POSTs: only a slow one is worth a line.
    // Background requests wait their turn: only a failure is.
    if (entry.path === "/v1/status" || (status && (method !== "POST" || entry.path === "/v1/volume") && took <= 2000)
        || (entry.background && status === 200)) return
    var first = !status && root.unansweredSince === 0
    if (first) {
      root.unansweredSince = entry.sentAt
      root.unansweredCount = 1
    }
    console.info("omarock: " + root.service + " " + method + " " + entry.path + " answered in " + took + " ms ("
      + (status || "no answer") + "), sent with " + entry.ahead.length + " in flight"
      + (entry.ahead.length > 0 ? ": " + entry.ahead.slice(0, 8).join(", ") : "")
      + (first ? "; until it answers, only POSTs are logged" : ""))
  }

  function get(path, callback, timeoutMs) { root.request("GET", path, null, callback, timeoutMs || 15000) }

  // A transport command; the bridge answers with its new status. One that
  // changes what's heard (changes) shows at once (Heard.js).
  function post(path, body, callback, changes) {
    if (changes) {
      root.acting++
      root.updateHeard()
    }
    root.request("POST", path, body || {}, function(data, error) {
      if (data && data.seq !== undefined) root.applyStatus(data)
      if (changes) {
        root.acting--
        if (root.acting === 0) root.seekTarget = -1
        root.updateHeard()
      }
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
      if (data && root.checksToken) {
        if (root.token === "") root.tokenRefused = false
        else root.get("/v1/status", null, 5000)
      }
      if (callback) callback(root.ready, root.lastError)
    }, 5000)
  }

  function applyStatus(data) {
    if (root.releasePending && data.current === true) {
      data = Object.assign({}, data, { current: false })
      Qt.callLater(root.sendRelease)
    } else if (root.releasePending && !root.releasing) {
      root.releasePending = false  // it isn't the source any more anyway (mpd played)
    }
    root.bridgeStatus = data
    root.addHeard(data)
    root.fillSongLinks()
  }

  // What's heard, and when (Heard.js). Each status as it came, flagged when
  // it answers a change made here (acting).
  property var heardEntries: []
  property var heard: ({ status: {}, elapsed: 0, waiting: false, next: 0 })
  property int acting: 0
  // A seek's position while it's asked for (-1: none).
  property real seekTarget: -1
  // A change made here, until its sound arrives: the card's time says "…".
  readonly property bool waiting: root.heard.waiting
  function addHeard(data) {
    root.heardEntries = root.heardEntries.concat([{ at: Date.now(), status: data, user: root.acting > 0 }])
    root.updateHeard()
  }
  function updateHeard() {
    var now = Date.now()
    root.heardEntries = Heard.prune(root.heardEntries, now, root.heardDelay)
    root.heard = Heard.shown(root.heardEntries, now, root.heardDelay, root.acting > 0, root.seekTarget)
    root.elapsed = root.heard.elapsed
  }

  // How far behind the Mac the sound is: mpd's lag on the stream, plus how
  // long the bridge holds the sound before Icecast (its health's
  // streamDelay; 0.4 s before bridge 0.8.0, the trip over the tailnet
  // included). 0 while mpd isn't playing the stream here: nothing is heard.
  readonly property bool hearing: root.streamed && root.active && !!root.mpd && root.mpd.status.state === "play"
    && root.elsewhere === ""
  readonly property real streamDelay: typeof root.health.streamDelay === "number" ? root.health.streamDelay : 0.4
  readonly property real heardDelay: {
    if (!root.hearing) return 0
    var delay = (root.mpdLag >= 0 ? root.mpdLag : root.streamLag) + root.streamDelay
    return delay >= 0.25 ? delay : 0
  }
  onHeardDelayChanged: root.updateHeard()

  // mpd's lag: once it has joined the stream (started playing it, or started
  // it again), its time is 0 until it has buffered enough to play; the time
  // since then less mpd's time is how far behind it plays. Read 4 s after a
  // join, then every 30 s (a stall adds to it). Until then, the lag
  // measured last (streamLag; at first, assumedLag).
  property real assumedLag: 1.9
  property real streamLag: root.assumedLag
  property real mpdLag: -1
  property real joinedAt: 0
  property var lastMpd: null
  Connections {
    target: root.streamed ? root.mpd : null
    function onMpdStatusChanged() { root.measureLag() }
  }
  function measureLag() {
    var s = root.mpd.mpdStatus
    var now = Date.now()
    var last = root.lastMpd
    root.lastMpd = s.state === "play" ? { elapsed: s.elapsed, songId: s.songId } : null
    if (s.state !== "play") {
      root.joinedAt = 0
      root.mpdLag = -1
      lagCheck.stop()
      return
    }
    if (!last || last.songId !== s.songId || s.elapsed + 0.5 < last.elapsed) {
      // Joined (mpd's status comes before its current song, so this isn't
      // known to be the stream yet). Its time is 0 while it buffers.
      root.joinedAt = s.elapsed < 0.5 ? now : 0
      root.mpdLag = -1
      lagCheck.interval = 4000
      lagCheck.restart()
      return
    }
    if (root.active && root.joinedAt > 0 && s.elapsed > 0) {
      root.mpdLag = Math.max(0, (now - root.joinedAt) / 1000 - s.elapsed)
      root.streamLag = root.mpdLag
    }
  }
  Timer {
    id: lagCheck
    onTriggered: {
      if (!root.active || !root.mpd || root.mpd.status.state !== "play") return
      root.mpd.refreshStatus()
      interval = root.mpdLag >= 0 ? 30000 : 2000
      restart()
    }
  }

  // The playing song's album and artist ids, and whether it's in your library,
  // by song key, for the songs whose status doesn't say (MusicKit's queue
  // entries often lack the ids; older bridges never say inLibrary, nor any
  // bridge for a library song, which may be only on a playlist added to the
  // library): asked of /v1/info once a song, { albumId, artistId, source,
  // inLibrary, catalogId }, or null while asking.
  property var songLinks: ({})

  function fillSongLinks() {
    var song = root.bridgeStatus.song
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
        if (data.seq === root.bridgeStatus.seq && data.state === root.bridgeStatus.state
            && data.current === root.bridgeStatus.current) {
          root.addHeard(Object.assign({}, root.bridgeStatus, { position: data.position || 0 }))
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

  // Health first, then the long poll once the bridge answers. While it can't
  // be reached, a long poll would hang for its 35 s; once it could, it would
  // wait up to 25 s for a change before the panel knew the bridge was back.
  function reconnect() {
    if (!root.active) return
    root.checkHealth(function() {
      if (!root.active) return
      if (!root.reachable) {
        retryPoll.restart()
        return
      }
      if (root.releasePending) root.sendRelease()
      root.poll()
    })
  }

  onActiveChanged: {
    if (root.active) root.reconnect()
    else root.pollSequence++
  }
  Component.onCompleted: root.reconnect()

  // Playback. Play also starts mpd on the stream when it isn't playing, and
  // takes the music over from another machine.
  function playPause() {
    if (root.bridgeStatus.state === "playing" && root.elsewhere === "" && (!root.streamed || root.mpd.status.state === "play"))
      root.post("/v1/pause", {}, null, true)
    else root.resume()
  }
  // Not while it plays on another machine: leaving Apple Music here, say,
  // mustn't stop it there.
  function pause() { if (root.elsewhere === "") root.post("/v1/pause", {}, null, true) }
  // The Mac first, then mpd on the stream (see catchUp).
  function resume() { root.post("/v1/resume", {}, root.catchUp, true) }
  // Only while mpd's source is this stream: a song played here from a lookup
  // (the radio playing) mustn't start the radio.
  function startStream() {
    if (root.streamed && root.active && root.mpd && root.mpd.status.state !== "play") root.mpd.send("play")
  }
  // Spotify: become omarock's source (mpd stops, and Spotify carries on with
  // what it had), or stop being it (Spotify pauses).
  function activate(callback) {
    root.releasePending = false
    root.post("/v1/activate", {}, callback)
  }
  // Leaving Spotify, whose service may be out of reach (the panel stays on
  // Spotify while it is): then the mode ends here, at once if it's known to
  // be out of reach, else once the release fails, and the release goes again
  // when the service next answers.
  property bool releasePending: false
  property bool releasing: false
  function release(callback) {
    root.releasePending = true
    if (!root.reachable) root.dropCurrent()
    root.sendRelease(callback)
  }
  function sendRelease(callback) {
    // Qt.callLater'd: the client may be half torn down by then.
    if (!root || typeof root.post !== "function" || root.releasing) return
    root.releasing = true
    root.post("/v1/release", {}, function(data, error) {
      root.releasing = false
      if (error === "") root.releasePending = false
      else root.dropCurrent()
      if (callback) callback(data, error)
    })
  }
  function dropCurrent() {
    if (root.bridgeStatus.current === true) root.bridgeStatus = Object.assign({}, root.bridgeStatus, { current: false })
  }
  // Once the bridge has made a change asked for here (a song picked, next,
  // previous, a seek, play): mpd plays the stream if it isn't already. For a
  // bridge before 0.7.0 (rejoins), it also reconnects to the live stream.
  //
  // Why rejoin was needed with those bridges and a stock libFLAC: mpd
  // connected to the stream while it was quiet (the bridge idle or paused:
  // about 350 bytes a second) waits until it has enough data, then plays all
  // it buffered, and stays that far behind the Mac (42 s behind, once: the
  // song heard wasn't the one shown, and picking another seemed to do
  // nothing).
  // A network stall does the same. playid of the stream's own entry
  // reconnects at live, with the output left open; mpd stopped just plays.
  // A change reaches the stream 1.5 to 1.8 s after the bridge's reply
  // (measured by recording the stream on the Mac), so mpd rejoins 2 s after
  // it, when the stream carries the new sound: joined while it is still
  // quiet, mpd would be behind again.
  function catchUp(data, error) {
    if (error !== "" || !root.streamed) return
    if (root.rejoins) rejoinTimer.restart()
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
  // the panel's followMpd for the media keys. A fresh connection is under 2 s
  // behind live (bridge 0.7.0), so holding the stream gains little.
  readonly property bool idle: root.streamed && root.active && root.ready && root.idleStopSeconds > 0 && !!root.mpd
    && root.mpd.status.state === "play"
    && (root.bridgeStatus.state === "paused" || root.bridgeStatus.state === "stopped")
  onIdleChanged: if (root.idle) idleStop.restart(); else idleStop.stop()

  Timer {
    id: idleStop
    interval: root.idleStopSeconds * 1000
    onTriggered: if (root.idle) root.mpd.send("stop")
  }
  function next() { root.post("/v1/next", {}, root.catchUp, true) }
  function previous() { root.post("/v1/previous", {}, root.catchUp, true) }
  function seekTo(seconds) {
    root.seekTarget = seconds
    root.post("/v1/seek", { position: seconds }, root.catchUp, true)
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
    }, mode === "play")
  }
  function jump(index) { root.post("/v1/queue/jump", { index: index }, root.catchUp, true) }
  function removeAt(index) { root.post("/v1/queue/remove", { index: index }) }

  // Browsing.
  // scope: "all" (the default), "library" or "catalog".
  // background: the service may let it wait (omarock-spotify paces its
  // requests to Spotify, and lets what you're looking at go first).
  function search(query, callback, scope, background) {
    root.get("/v1/search?scope=" + (scope || "all") + "&limit=8" + (background ? "&background=1" : "")
      + "&q=" + encodeURIComponent(query), callback, background ? 60000 : 0)
  }
  function album(source, id, callback) { root.get("/v1/albums/" + source + "/" + encodeURIComponent(id), callback) }
  function artist(source, id, callback) { root.get("/v1/artists/" + source + "/" + encodeURIComponent(id), callback) }
  function playlist(source, id, callback) { root.get("/v1/playlists/" + source + "/" + encodeURIComponent(id), callback) }
  function genre(id, callback) { root.get("/v1/genres/" + encodeURIComponent(id) + "?limit=25", callback) }
  // One of the library's genres (API.md, "Your library's genres"); the id is its name.
  function libraryGenre(id, callback) { root.get("/v1/genres/library/" + encodeURIComponent(id), callback) }

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
    onTriggered: root.reconnect()
  }

  // The time, while the panel shows it; and while something is still to be
  // heard (a song changing when its sound does, on the bar too).
  Timer {
    interval: root.heardDelay > 0 ? 250 : 500
    repeat: true
    running: (root.ticking && (root.bridgeStatus.state === "playing" || root.heard.waiting))
      || (root.heardDelay > 0 && (root.heard.next > 0 || root.heard.waiting))
    onTriggered: root.updateHeard()
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
