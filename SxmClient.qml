import QtQuick
import "Sxm.js" as Sxm

// SiriusXM, through the omarock-sxm service on this machine (sxm/README.md).
// Where the player card and the bar read the player, it has MpdClient's
// shape: ready, lastError, status, currentSong, elapsed and the transport
// functions. The sound is mpd's: it plays the channel's stream, so play and
// stop are mpd's, and changing channel is asked of the panel (tuneRequested),
// which retunes mpd.
Item {
  id: root

  property string baseUrl: "http://127.0.0.1:8720"
  property var mpd: null
  // Poll what's playing while a channel plays, or while the panel is open.
  property bool active: false
  property bool watching: false

  property bool available: false
  property string lastError: ""
  property var channels: []
  property var nowPlaying: ({})
  property real elapsed: 0

  readonly property string prefix: Sxm.streamPrefix(baseUrl)
  readonly property string currentId: root.mpd ? Sxm.channelIdOf(root.mpd.currentSong.file || "", baseUrl) : ""
  readonly property var channel: {
    var id = root.currentId
    return root.channels.filter(function(c) { return c.id === id })[0] || null
  }
  readonly property var now: root.nowPlaying[root.currentId] || null
  readonly property bool ready: root.available && root.mpd !== null && root.mpd.ready
  readonly property var currentSong: Sxm.songAsMpd(root.channel, root.now, root.mpd ? root.mpd.currentSong.file : "")
  // Live radio: no seeking, no queue position, no shuffle or repeat.
  readonly property var status: ({
    state: root.mpd ? root.mpd.status.state : "stop", volume: root.mpd ? root.mpd.status.volume : -1,
    elapsed: root.elapsed, duration: 0, song: -1, songId: root.currentId, random: false, repeat: false,
    single: false, consume: false, queueLength: 0, updating: false, error: ""
  })
  readonly property var queue: []

  signal tuneRequested(var channel)

  function request(method, path, body, callback, timeoutMs) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      // A reply that arrives after a plugin reload destroyed this client
      // (Apple Music's long poll, say) has nowhere to go. Mid-teardown the
      // client may still be there with its functions gone ("Property
      // 'logTiming' … is not a function").
      if (xhr.readyState !== XMLHttpRequest.DONE || !root || typeof root.request !== "function") return
      var data = null
      try { data = xhr.responseText ? JSON.parse(xhr.responseText) : null } catch (e) {}
      if (xhr.status >= 200 && xhr.status < 300) {
        if (callback) callback(data, "")
      } else {
        var error = xhr.status === 0 ? "SiriusXM isn't running (omarock-sxm)"
          : (data && data.error) || "SiriusXM said " + xhr.status
        if (callback) callback(null, error)
      }
    }
    xhr.open(method, root.baseUrl + path)
    // What tells omarock-sxm the request is omarock's, not a web page's.
    xhr.setRequestHeader("X-Omarock", "1")
    if (body !== undefined && body !== null) {
      xhr.setRequestHeader("Content-Type", "application/json")
      xhr.send(JSON.stringify(body))
    } else {
      xhr.send()
    }
  }

  // Whether the service runs and has an account; then its channels.
  // Health has answered at least once (or failed to): the settings say
  // something's wrong only then.
  property bool healthKnown: false
  function checkHealth(callback) {
    root.request("GET", "/v1/health", null, function(data, error) {
      root.healthKnown = true
      root.available = !!data && data.account === true
      root.lastError = !data ? error : data.account ? (data.error || "") : "No SiriusXM account set up"
      if (root.available && root.channels.length === 0) root.refreshChannels()
      if (callback) callback(root.available, root.lastError)
    })
  }

  function refreshChannels(callback) {
    root.request("GET", "/v1/channels", null, function(data, error) {
      if (data) root.channels = data
      else root.lastError = error
      if (callback) callback(data, error)
    }, 60000)
  }

  function refreshNowPlaying() {
    root.request("GET", "/v1/nowplaying", null, function(data) {
      if (data) root.nowPlaying = data
      root.updateElapsed()
    }, 30000)
  }

  // How long the song has been on, from when SiriusXM says it started.
  function updateElapsed() {
    var started = root.now && root.now.startedAt ? Date.parse(root.now.startedAt) : NaN
    root.elapsed = isNaN(started) ? 0 : Math.max(0, (Date.now() - started) / 1000)
  }

  // Transport. Live radio stops rather than pauses, so playing again is live.
  function playPause() {
    if (!root.mpd) return
    root.mpd.send(root.mpd.status.state === "play" ? "stop" : "play")
  }
  function next() { root.step(1) }
  function previous() { root.step(-1) }
  function step(delta) {
    var target = Sxm.stepChannel(root.channels, root.currentId, delta)
    if (target) root.tuneRequested(target)
  }
  function seekTo(seconds) {}
  function seekBy(delta) {}
  function setRandom(on) {}
  function setRepeat(on) {}
  function setVolume(value) { if (root.mpd) root.mpd.setVolume(value) }

  // A channel in or out of the account's favourites (the SiriusXM app's too).
  function toggleFavorite(channelId, callback) {
    var channel = root.channels.filter(function(c) { return c.id === channelId })[0]
    if (!channel) return
    var adding = !channel.favorite
    root.request(adding ? "POST" : "DELETE", "/v1/favorites/" + encodeURIComponent(channelId), null, function(data, error) {
      if (data) {
        root.channels = root.channels.map(function(c) {
          return c.id === channelId ? Object.assign({}, c, { favorite: adding }) : c
        })
      }
      if (callback) callback(error, adding)
    })
  }

  // A channel playing when omarock starts (any plugin's reload starts it
  // again) needs the service checked at once. Otherwise only opening the
  // panel did that, and the bar showed the music note until then. While the
  // service can't be reached, it looks again every 30 s.
  onActiveChanged: if (root.active && !root.available) root.checkHealth()

  Timer {
    interval: 30000
    repeat: true
    running: root.active && !root.available
    onTriggered: root.checkHealth()
  }

  Timer {
    interval: 15000
    repeat: true
    triggeredOnStart: true
    running: (root.active || root.watching) && root.available
    onTriggered: root.refreshNowPlaying()
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.active && root.watching
    onTriggered: root.updateElapsed()
  }
}
