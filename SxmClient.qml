import QtQuick
import "Sxm.js" as Sxm
import "Reply.js" as Reply

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

  // Only while this account holds omarock-sxm's port (ListenerCheck): another
  // account binding it first would get the requests, and choose the channels,
  // titles and art omarock shows.
  readonly property int loopbackPort: {
    var m = /^http:\/\/127\.0\.0\.1:(\d+)(\/|$)/.exec(root.baseUrl)
    return m ? parseInt(m[1], 10) : 0
  }
  ListenerCheck { id: listener; port: root.loopbackPort }

  // The most of an answer read: the channel list is about 200 KB (400
  // channels), what's on now about 160 KB.
  property int maxBytes: 2097152

  // then(), once this account is found holding omarock-sxm's port, checked
  // just before (an account can bind it whenever omarock-sxm restarts); else
  // refused(why). Found held by another account while mpd plays SiriusXM
  // from it, mpd stops, and the art goes (available).
  function whenOurs(then, refused) {
    if (root.loopbackPort === 0) return then()
    listener.verify(function() {
      if (!root || typeof root.whenOurs !== "function") return
      if (listener.ours) return then()
      if (listener.owner !== "") {
        root.available = false
        var file = root.mpd && root.mpd.currentSong ? String(root.mpd.currentSong.file || "") : ""
        if (root.prefix !== "" && file.indexOf(root.prefix) === 0 && root.mpd.status.state === "play") root.mpd.send("stop")
      }
      refused(listener.owner !== ""
        ? "omarock-sxm's port (127.0.0.1:" + root.loopbackPort + ") is held by another account (uid " + listener.owner + "), so omarock doesn't use it"
        : "SiriusXM isn't running (omarock-sxm)")
    })
  }

  // HTTP through curl, capped and on time (Fetch.qml). timeoutMs: 10 s
  // unless the caller says. Each request after a fresh look at who holds the
  // port (whenOurs).
  function request(method, path, body, callback, timeoutMs) {
    root.whenOurs(function() { root.send(method, path, body, callback, timeoutMs) },
                  function(why) { if (callback) callback(null, why) })
  }
  function send(method, path, body, callback, timeoutMs) {
    fetch.request({ url: root.baseUrl + path, method: method, json: body, maxBytes: root.maxBytes, timeoutMs: timeoutMs || 10000,
                    // What tells omarock-sxm the request is omarock's, not a web page's.
                    headers: { "X-Omarock": "1" } }, function(reply) {
      // A reply that arrives after a plugin reload destroyed this client
      // (Apple Music's long poll, say) has nowhere to go. Mid-teardown the
      // client may still be there with its functions gone ("Property
      // 'logTiming' … is not a function").
      if (!root || typeof root.request !== "function") return
      var read = Reply.parse(reply.text, root.maxBytes)
      var data = read.data
      var tooBig = reply.tooBig || Reply.refused(read.error)
      if (reply.status >= 200 && reply.status < 300 && !tooBig) {
        if (callback) callback(data, "")
      } else {
        var error = reply.timedOut ? "omarock-sxm didn't answer"
          : tooBig ? "SiriusXM's answer was too big to read"
          : reply.status === 0 ? "SiriusXM isn't running (omarock-sxm)"
          : (data && data.error ? String(data.error).slice(0, 300) : "") || "SiriusXM said " + reply.status
        // No answer: is the service still there? (Its art is shown only
        // while it is.)
        if (reply.status === 0 && path !== "/v1/health" && root.available) root.checkHealth()
        if (callback) callback(null, error)
      }
    })
  }
  Fetch { id: fetch }
  readonly property var http: fetch  // for the harness

  // Whether the service runs and has an account; then its channels.
  // Health has answered at least once (or failed to): the settings say
  // something's wrong only then.
  property bool healthKnown: false
  function checkHealth(callback) {
    root.checkHealthNow(callback)
  }
  function checkHealthNow(callback) {
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

  // A channel in or out of the account's favorites (the SiriusXM app's too).
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
  // service can't be reached, it looks again every 5 s.
  onActiveChanged: if (root.active && !root.available) root.checkHealth()

  Timer {
    interval: 5000
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
