import QtQuick
import Quickshell.Io
import Quickshell.Services.Pipewire
import "Mpd.js" as Mpd

// omarock's link to mpd over its unix socket. Like most mpd clients it keeps
// two connections: one parked in `idle`, which mpd answers when something
// changes, and one for commands. All state stays in mpd, so mpc, the media
// keys and the other widgets see the same queue and playback.
//
// Output commands (enableoutput, toggleoutput, outputset) are refused here:
// this machine's other audio outputs are radio transmitters.
Item {
  id: root

  property string socketPath: ""
  property bool active: true

  readonly property bool ready: idleSocket.connected && root.idleGreeted
  property string lastError: ""

  property string musicDirectory: ""
  // mpd's status as mpd reports it; status is the same with the volume
  // omarock shows (the bus's, where there is one).
  property var mpdStatus: Mpd.parseStatus([])
  readonly property var status: root.busVolume >= 0
    ? Object.assign({}, root.mpdStatus, { volume: root.busVolume }) : root.mpdStatus

  // omarock's audio bus (audio/omarock-bus.conf): the PipeWire output
  // "omarock" that all of omarock's sound plays into, mpd's and Spotify's.
  // Where it exists, its volume is omarock's one volume for every source,
  // set here at once, and mpd's own stays at full (mpd.conf:
  // mixer_type "none"). Without it (another machine), the volume is mpd's.
  readonly property var busNode: {
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++)
      if (nodes[i] && nodes[i].name === "omarock" && nodes[i].isSink) return nodes[i]
    return null
  }
  readonly property int busVolume: root.busNode && root.busNode.audio ? Math.round(root.busNode.audio.volume * 100) : -1
  PwObjectTracker { objects: root.busNode ? [root.busNode] : [] }
  // A PipeWire output's own name for people ("Framework Audio Expansion
  // Card"), for the settings; its node name if PipeWire doesn't have it.
  function outputDescription(name) {
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++)
      if (nodes[i] && nodes[i].name === name) return nodes[i].description || nodes[i].nickname || name
    return name
  }
  property var currentSong: ({})
  property var queue: []
  property int queueTotalSeconds: 0
  // Stored playlists, [{ name, modified }], kept current through idle.
  property var playlists: []
  // Seconds into the current song, ticked locally between status reads.
  property real elapsed: 0
  property bool ticking: false

  // The queue is read in one window; a longer queue shows the first part.
  readonly property int queueWindow: 1000

  // A command 15 s without its reply: mpd is stuck (it has deadlocked),
  // until a reply comes.
  property bool stalled: false
  property real inflightSince: 0

  property bool idleGreeted: false
  property bool commandGreeted: false
  property var idleChanges: []
  property var pending: []
  property var inflight: null
  property var replyLines: []
  property var coverCache: ({})
  // "album\0artist" -> one song file, to find the cover of an album that a
  // list only knows by name.
  property var albumFileCache: ({})
  property real elapsedBase: 0
  property real elapsedAt: 0

  signal coverResolved(string directory, string url)
  // A stored playlist was made, changed or deleted, by omarock or another
  // client; playlists is already current.
  signal playlistsEdited()

  readonly property string idleCommand: "idle database update stored_playlist playlist player mixer options"

  // Send one command (or a command list); callback(lines, error) gets the
  // reply. Commands queue while the socket (re)connects.
  // quiet: an error is expected (deleting an entry that may be gone already),
  // so it isn't reported (lastError, the journal).
  function send(text, callback, quiet) {
    if (Mpd.isForbidden(text)) {
      console.warn("omarock: refused an mpd output command")
      if (callback) callback([], "refused")
      return
    }
    // While mpd is unreachable, fail now rather than replay a stale "next"
    // minutes later.
    if (!root.ready) {
      if (callback) callback([], "not connected")
      return
    }
    var ahead = (root.inflight ? [root.inflight] : []).concat(root.pending).map(function(c) { return Mpd.commandWord(c.text) })
    root.pending.push({ text: text, callback: callback || null, quiet: quiet === true, queuedAt: Date.now(), ahead: ahead })
    root.pump()
  }

  function sendList(commands, callback) {
    root.send(commands.length === 1 ? commands[0] : Mpd.commandList(commands), callback)
  }

  function pump() {
    if (root.inflight || root.pending.length === 0 || !root.active) return
    if (!commandSocket.connected) {
      commandSocket.connected = true
      return
    }
    if (!root.commandGreeted) return
    root.inflight = root.pending.shift()
    root.inflightSince = Date.now()
    root.replyLines = []
    commandSocket.write(root.inflight.text + "\n")
    commandSocket.flush()
  }

  function dropPending() {
    var dropped = root.pending
    root.pending = []
    for (var i = 0; i < dropped.length; i++)
      if (dropped[i].callback) dropped[i].callback([], "not connected")
  }

  function finishCommand(error) {
    root.stalled = false
    var done = root.inflight
    // A slow reply goes to the journal: how long mpd took, and how long the
    // command waited behind others on this connection first.
    var now = Date.now()
    if (done && now - done.queuedAt > 700)
      console.info("omarock: mpd " + Mpd.commandWord(done.text) + " took " + (now - root.inflightSince) + " ms, after "
        + (root.inflightSince - done.queuedAt) + " ms queued" + (done.ahead.length > 0 ? " behind " + done.ahead.slice(0, 6).join(", ") : ""))
    var lines = root.replyLines
    root.inflight = null
    root.replyLines = []
    if (error !== "" && !(done && done.quiet)) {
      root.lastError = error.replace(/^ACK \[[^\]]*\] \{[^}]*\} /, "")
      console.warn("omarock: mpd said " + error)
    }
    if (done && done.callback) done.callback(lines, error)
    root.pump()
  }

  function commandLine(line) {
    if (!root.commandGreeted) {
      if (line.indexOf("OK MPD ") === 0) {
        root.commandGreeted = true
        root.pump()
      }
      return
    }
    if (!root.inflight) return
    if (line === "OK") root.finishCommand("")
    else if (line.indexOf("ACK ") === 0) root.finishCommand(line)
    else root.replyLines.push(line)
  }

  function idleLine(line) {
    if (!root.idleGreeted) {
      if (line.indexOf("OK MPD ") === 0) {
        root.idleGreeted = true
        root.lastError = ""
        root.refreshAll()
        root.enterIdle()
      }
      return
    }
    if (line.indexOf("changed: ") === 0) {
      root.idleChanges.push(line.slice(9))
    } else if (line === "OK") {
      var changes = root.idleChanges
      root.idleChanges = []
      root.handleChanges(changes)
      root.enterIdle()
    }
  }

  function enterIdle() {
    idleSocket.write(root.idleCommand + "\n")
    idleSocket.flush()
  }

  function handleChanges(changes) {
    var status = false, song = false, queue = false, stored = false
    for (var i = 0; i < changes.length; i++) {
      var c = changes[i]
      if (c === "player") { status = true; song = true }
      else if (c === "playlist") { status = true; queue = true; song = true }
      else if (c === "mixer" || c === "options" || c === "update") status = true
      else if (c === "database") { root.coverCache = ({}); root.albumFileCache = ({}) }
      else if (c === "stored_playlist") stored = true
    }
    if (status) root.refreshStatus()
    if (song) root.refreshCurrentSong()
    if (queue) root.refreshQueue()
    if (stored) root.refreshPlaylists(true)
  }

  function refreshAll() {
    root.send("config", function(lines, error) {
      if (error === "") root.musicDirectory = Mpd.parseObject(lines).music_directory || ""
    })
    root.refreshStatus()
    root.refreshCurrentSong()
    root.refreshQueue()
    root.refreshPlaylists(false)
  }

  function refreshStatus() {
    root.send("status", function(lines, error) {
      if (error === "") root.applyStatus(lines)
    })
  }

  function applyStatus(lines) {
    var s = Mpd.parseStatus(lines)
    root.mpdStatus = s
    root.elapsedBase = s.elapsed
    root.elapsedAt = Date.now()
    root.elapsed = s.elapsed
  }

  function refreshCurrentSong() {
    root.send("currentsong", function(lines, error) {
      if (error === "") root.currentSong = Mpd.parseObject(lines)
    })
  }

  function refreshQueue() {
    root.send("playlistinfo 0:" + root.queueWindow, function(lines, error) {
      if (error !== "") return
      var songs = Mpd.parseSongs(lines)
      var total = 0
      for (var i = 0; i < songs.length; i++) total += parseFloat(songs[i].duration || songs[i].time || 0) || 0
      root.queue = songs
      root.queueTotalSeconds = Math.round(total)
    })
  }

  function refreshPlaylists(edited) {
    root.send("listplaylists", function(lines, error) {
      if (error !== "") return
      root.playlists = Mpd.parsePlaylists(lines)
      if (edited) root.playlistsEdited()
    })
  }

  // Song counts and playing time of some stored playlists; callback({ name:
  // { songs, seconds } }), leaving out any that mpd can't read.
  function playlistLengths(names, callback) {
    if (names.length === 0) { callback({}); return }
    root.send(Mpd.commandListOk(names.map(function(name) { return Mpd.command("playlistlength", [name]) })),
      function(lines, error) {
        var lengths = {}
        // A list stops at its first error; the replies before it still count.
        Mpd.splitReplies(lines).forEach(function(reply, i) {
          var total = Mpd.parseObject(reply)
          lengths[names[i]] = { songs: parseInt(total.songs, 10) || 0, seconds: parseFloat(total.playtime) || 0 }
        })
        callback(lengths)
      })
  }

  // Every stored playlist with its length, for the Playlists view;
  // callback([{ name, modified, songs, seconds }]) sorted by name, or null.
  function playlistSummaries(callback) {
    root.send("listplaylists", function(lines, error) {
      if (error !== "") { callback(null); return }
      var playlists = Mpd.byName(Mpd.parsePlaylists(lines))
      root.playlistLengths(playlists.map(function(p) { return p.name }), function(lengths) {
        callback(playlists.map(function(p) {
          var length = lengths[p.name] || { songs: 0, seconds: 0 }
          return { name: p.name, modified: p.modified, songs: length.songs, seconds: length.seconds }
        }))
      })
    })
  }

  // One stored playlist's songs in order; callback(songs), or null and mpd's
  // error. Songs that have left the library come back as only a file.
  function playlistSongs(name, callback) {
    root.send(Mpd.command("listplaylistinfo", [name]), function(lines, error) {
      callback(error === "" ? Mpd.parseSongs(lines) : null, error)
    })
  }

  function queuePlaylist(name, mode, start) {
    root.sendList(Mpd.playlistQueueCommands(name, mode, start))
  }

  function deletePlaylist(name, callback) {
    root.send(Mpd.command("rm", [name]), function(lines, error) { if (callback) callback(error) })
  }

  function removeFromPlaylist(name, position, callback) {
    root.send(Mpd.command("playlistdelete", [name, position]), function(lines, error) { if (callback) callback(error) })
  }

  // Something onto the end of a stored playlist, which mpd makes if it is
  // new: a search result or a browse row (resultFiles), a whole genre, or
  // the queue (kind "queue"). callback(error).
  function addToPlaylist(name, result, isNew, callback) {
    function finish(lines, error) { if (callback) callback(error) }
    if (result.kind === "queue") {
      root.send(Mpd.command("save", isNew ? [name] : [name, "append"]), finish)
    } else if (result.kind === "genre") {
      root.send(Mpd.command("searchaddpl", [name, Mpd.tagFilter("genre", "==", result.genre)]), finish)
    } else {
      root.resultFiles(result, function(files) {
        if (!files || files.length === 0) { if (callback) callback("nothing to add"); return }
        root.sendList(Mpd.playlistAddCommands(name, files), finish)
      })
    }
  }

  // The cover image for a song's folder, as a file:// URL ("" when the folder
  // has none). mpd lists the folder, so missing covers never hit the disk as
  // failed image loads. Answers arrive through coverResolved.
  function cover(file) {
    if (!Mpd.isLocalFile(file || "") || root.musicDirectory === "") return
    var dir = Mpd.directoryOf(file)
    if (root.coverCache[dir] !== undefined) {
      if (root.coverCache[dir] !== "pending") root.coverResolved(dir, root.coverCache[dir])
      return
    }
    root.coverCache[dir] = "pending"
    root.send(Mpd.command("listfiles", [dir]), function(lines, error) {
      var name = error === "" ? Mpd.pickCover(Mpd.parseValues(lines, "file")) : null
      var url = name ? Mpd.fileUrl(root.musicDirectory + "/" + (dir === "" ? "" : dir + "/") + name) : ""
      root.coverCache[dir] = url
      root.coverResolved(dir, url)
    })
  }

  // Covers arrive while the panel is closed too (beets fills them in over
  // hours), so forget the folders that had none.
  function forgetMissingCovers() {
    var kept = {}
    for (var dir in root.coverCache)
      if (root.coverCache[dir] !== "" && root.coverCache[dir] !== "pending") kept[dir] = root.coverCache[dir]
    root.coverCache = kept
  }

  // Playback. Play with nothing queued plays a song picked at random.
  function playPause() {
    if (root.status.state === "play") root.send("pause 1")
    else if (root.status.state === "pause") root.send("pause 0")
    else if (root.status.queueLength === 0) root.playRandomSong()
    else root.send("play")
  }
  function playRandomSong() {
    root.send("stats", function(lines, error) {
      var songs = error === "" ? parseInt(Mpd.parseObject(lines).songs) || 0 : 0
      if (songs > 0) root.sendList(Mpd.randomSongCommands(Math.floor(Math.random() * songs), root.status.queueLength))
    })
  }
  function next() { root.send("next") }
  function previous() { root.send("previous") }
  function playQueueId(id) { root.send(Mpd.command("playid", [id])) }
  function removeQueueId(id) { root.send(Mpd.command("deleteid", [id])) }
  function seekTo(seconds) {
    if (root.status.state === "stop") return
    var target = Math.max(0, Math.min(root.status.duration || seconds, seconds))
    root.elapsedBase = target
    root.elapsedAt = Date.now()
    root.elapsed = target
    root.send("seekcur " + target.toFixed(1))
  }
  function seekBy(delta) { root.seekTo(root.elapsed + delta) }
  // Volume. mpd's mixer can be slow (while it plays a live stream, such as
  // Apple Music's), so only one setvol is in flight and a drag sends only the
  // latest value instead of queueing every step.
  property int volumeWanted: -1
  property int volumeSending: -1
  function setVolume(value) {
    if (root.busVolume >= 0) {
      root.busNode.audio.volume = Math.max(0, Math.min(100, Math.round(value))) / 100
      return
    }
    if (root.status.volume < 0) return
    root.volumeWanted = Math.round(Math.max(0, Math.min(100, value)))
    if (root.volumeSending < 0) root.sendVolume()
  }
  function sendVolume() {
    var value = root.volumeWanted
    root.volumeWanted = -1
    root.volumeSending = value
    root.send("setvol " + value, function() {
      root.volumeSending = -1
      if (root.volumeWanted >= 0) root.sendVolume()
    })
  }
  // + and -: from the volume last asked for, not the one mpd last reported.
  function nudgeVolume(delta) {
    var base = root.volumeWanted >= 0 ? root.volumeWanted : root.volumeSending >= 0 ? root.volumeSending : root.status.volume
    root.setVolume(base + delta)
  }
  function setRandom(on) { root.send("random " + (on ? 1 : 0)) }
  function setRepeat(on) { root.send("repeat " + (on ? 1 : 0)) }

  // Apple Music, SiriusXM or the radio: a stream as the queue entry right
  // after the current song ("+0", so a stale idea of the queue can't put it
  // in the wrong place), playing. Then the entries of other streams, those
  // whose file starts with one of `drop` (the source or channel just left,
  // and any strays), are deleted. They're looked up in mpd at that moment:
  // the queue omarock holds can lag behind a quick run of changes.
  //
  // playid, while something plays, holds every mpd client until the new
  // stream has connected (a second or more for some stations), so when it
  // answers the stream is playing; the panel says "Tuning …" meanwhile.
  // Nothing more is sent to mpd while a stream starts. mpd 0.24.15 has
  // deadlocked twice as a stream started on its PipeWire output (every
  // client waiting, the old station playing on): once after stop + playid
  // (it closes the output and reopens it at once), once while omarock read
  // status four times a second to see the sound start. Neither happened in
  // hours of plain playid.
  //
  // The newest request wins. One overtaken by another (n pressed twice, a
  // second station picked while the first connects) goes no further, its
  // callback isn't called, and the newer one deletes its entry. A stream
  // already playing, or on its way, isn't asked for again.
  // callback(error): "" when mpd plays it.
  property int streamRequest: 0
  // The stream asked for last, until mpd plays it or fails.
  property string streamTuning: ""
  function playStream(url, drop, callback) {
    if (url === root.streamTuning) return
    if (root.streamTuning === "" && root.currentSong.file === url && root.status.state === "play") {
      if (callback) callback("")
      return
    }
    var request = ++root.streamRequest
    root.streamTuning = url
    var add = root.status.song >= 0 ? Mpd.command("addid", [url, "+0"]) : Mpd.command("addid", [url])
    root.send(add, function(lines, error) {
      if (request !== root.streamRequest) return
      var id = Mpd.parseObject(lines).id
      if (error !== "" || !id) {
        root.streamTuning = ""
        if (callback) callback(error || "mpd didn't add the stream")
        return
      }
      root.send(Mpd.command("playid", [id]), function(lines, playError) {
        if (request !== root.streamRequest) return
        root.streamTuning = ""
        if (playError === "") root.deleteStreams(drop || [], id)
        if (callback) callback(playError)
      })
    })
  }

  // Leaving the streams: a request still on its way goes no further.
  function cancelStream() {
    root.streamRequest++
    root.streamTuning = ""
  }

  // Delete the queue entries whose file starts with one of `prefixes`
  // (or, for a pattern starting with "#", contains it: radio stations carry
  // "#omarock-radio=…"), except `keepId`, then callback(). One deleteid at a
  // time, quietly: in a command list, one entry already gone would stop the
  // rest.
  function deleteStreams(prefixes, keepId, callback) {
    if (prefixes.length === 0) {
      if (callback) callback()
      return
    }
    var finds = prefixes.map(function(prefix) {
      return Mpd.command("playlistsearch", [Mpd.tagFilter("file", prefix.charAt(0) === "#" ? "contains" : "starts_with", prefix)])
    })
    root.sendList(finds, function(lines) {
      var ids = Mpd.parseValues(lines, "id").filter(function(id) { return id !== keepId })
      if (ids.length === 0) {
        if (callback) callback()
        return
      }
      ids.forEach(function(id, i) {
        root.send(Mpd.command("deleteid", [id]), i === ids.length - 1 && callback ? function() { callback() } : null, true)
      })
    })
  }

  // A live source (a stream) plays in mpd's repeat-one mode, so a stream that
  // drops reconnects instead of mpd going on to the next song (local music);
  // a station that refuses stops there. Back on local, repeat and single are
  // as they were. The panel calls this when the source changes by its own
  // hand; single already on is taken as ours, never as how it was.
  property var beforeLive: null
  function setLive(on) {
    if (on) {
      if (root.beforeLive === null)
        root.beforeLive = root.status.single ? { repeat: false, single: false } : { repeat: root.status.repeat, single: false }
      if (!root.status.repeat || !root.status.single) root.sendList(["repeat 1", "single 1"])
    } else if (root.beforeLive !== null || root.status.single) {
      var was = root.beforeLive || { repeat: false, single: false }
      root.beforeLive = null
      root.sendList(["repeat " + (was.repeat ? 1 : 0), "single " + (was.single ? 1 : 0)])
    }
  }

  // Back to local music: delete the streams' entries (mpd carries on with
  // the next song), then resume the song they interrupted, at the time it was
  // left, if it is still queued.
  function leaveStream(prefixes, resume) {
    root.cancelStream()
    root.deleteStreams(prefixes, "", function() {
      if (resume && root.queue.some(function(song) { return song.id === resume.id }))
        root.send(Mpd.command("seekid", [resume.id, resume.elapsed.toFixed(1)]))
    })
  }

  // Songs into the queue: mode "play" replaces the queue and plays from song
  // `start`, "add" appends.
  function queueFiles(files, mode, start) {
    if (files.length > 0) root.sendList(Mpd.queueCommands(files, mode, start))
  }

  function queueGenre(genre, mode) {
    root.sendList(Mpd.genreCommands(genre, mode))
  }

  // A search result (an artist, an album, a genre, a playlist or a song)
  // into the queue, in the same order its own view shows.
  function playResult(result, mode) {
    if (result.kind === "genre") root.queueGenre(result.genre, mode)
    else if (result.kind === "playlist") root.queuePlaylist(result.playlist, mode)
    else root.resultFiles(result, function(files) { if (files) root.queueFiles(files, mode) })
  }

  // The song files behind a result, in its view's order; callback(files),
  // or null when mpd fails. kind "files" carries its own list.
  function resultFiles(result, callback) {
    if (result.kind === "song") callback([result.file])
    else if (result.kind === "files") callback(result.files)
    else if (result.kind === "album") root.albumSongs(result.album, result.artist, function(songs) {
      callback(songs ? Mpd.filesOf(songs) : null)
    })
    else if (result.kind === "artist") root.artistAlbums(result.artist, function(view) {
      callback(view ? Mpd.artistFiles(view) : null)
    })
    else if (result.kind === "playlist") root.playlistSongs(result.playlist, function(songs) {
      callback(songs ? Mpd.filesOf(songs.filter(function(song) { return !Mpd.isMissing(song) })) : null)
    })
    else callback(null)
  }

  // One album's songs in play order; callback(songs), or null when mpd
  // fails. artist, when known, picks the right album when several share the
  // name (Mpd.albumOrder).
  function albumSongs(album, artist, callback) {
    var filter = album !== "" ? Mpd.tagFilter("album", "==", album)
      : Mpd.andFilter([Mpd.tagFilter("albumartist", "==", artist), Mpd.tagFilter("album", "==", "")])
    root.send(Mpd.command("find", [filter]), function(lines, error) {
      callback(error === "" ? Mpd.albumOrder(Mpd.parseSongs(lines), artist) : null)
    })
  }

  // A genre for the genre view; callback({ songs, seconds, albums }), or
  // null when mpd fails. Albums come from one grouped list, merged by name.
  function genreAlbums(genre, callback) {
    var filter = Mpd.tagFilter("genre", "==", genre)
    root.send(Mpd.commandListOk([
      Mpd.command("count", [filter]),
      Mpd.command("list", ["album", filter, "group", "date", "group", "albumartist"]),
      Mpd.command("count", [filter, "group", "album"])
    ]), function(lines, error) {
      if (error !== "") { callback(null); return }
      var replies = Mpd.splitReplies(lines)
      var total = Mpd.parseObject(replies[0] || [])
      var albums = Mpd.mergeAlbums(Mpd.parseRows(replies[1] || [], "album"))
      var counts = {}
      Mpd.parseCounts(replies[2] || [], "album").forEach(function(c) { counts[c.name] = c.songs })
      albums.forEach(function(album) { album.songCount = counts[album.album] || 0 })
      callback({
        genre: genre,
        songs: parseInt(total.songs, 10) || 0,
        seconds: parseFloat(total.playtime) || 0,
        albums: Mpd.sortGenreAlbums(albums)
      })
    })
  }

  // Each album's number of songs, by name (as omarock knows an album):
  // callback({ name: songs }), empty if mpd failed.
  function albumCounts(names, callback) {
    if (names.length === 0) { callback({}); return }
    root.send(Mpd.commandListOk(names.map(function(name) {
      return Mpd.command("count", [Mpd.tagFilter("album", "==", name)])
    })), function(lines, error) {
      var counts = {}
      if (error === "") Mpd.splitReplies(lines).forEach(function(reply, i) {
        counts[names[i]] = parseInt(Mpd.parseObject(reply).songs, 10) || 0
      })
      callback(counts)
    })
  }

  // One song file of an album, for its cover; callback(file), "" if none.
  function albumFile(album, artist, callback) {
    var key = album + "\u0000" + artist
    if (root.albumFileCache[key] !== undefined) { callback(root.albumFileCache[key]); return }
    var filter = artist !== ""
      ? Mpd.andFilter([Mpd.tagFilter("albumartist", "==", artist), Mpd.tagFilter("album", "==", album)])
      : Mpd.tagFilter("album", "==", album)
    root.send(Mpd.command("find", [filter]) + " window 0:1", function(lines, error) {
      var songs = error === "" ? Mpd.parseSongs(lines) : []
      root.albumFileCache[key] = songs.length > 0 ? songs[0].file : ""
      callback(root.albumFileCache[key])
    })
  }

  // The info card (Info.js): a song's tags (lsinfo), the size of its file
  // (from its folder's listfiles) and its stickers. callback(song, extra);
  // song is null when mpd doesn't know the file. Errors are expected (a file
  // gone, no sticker database), so they aren't reported.
  function songInfo(file, callback) {
    root.send(Mpd.command("lsinfo", [file]), function(lines, error) {
      var song = error === "" ? Mpd.parseSongs(lines)[0] || null : null
      if (!song) { callback(null, {}); return }
      var dir = Mpd.directoryOf(file)
      root.send(Mpd.command("listfiles", [dir]), function(listing, listError) {
        var size = listError === "" ? Mpd.parseFileSizes(listing)[dir === "" ? file : file.slice(dir.length + 1)] : undefined
        root.send(Mpd.command("sticker", ["list", "song", file]), function(stickers, stickerError) {
          callback(song, { size: size, stickers: stickerError === "" ? Mpd.parseStickers(stickers) : {},
            musicDirectory: root.musicDirectory })
        }, true)
      }, true)
    }, true)
  }

  // An album for the info card: its songs (albumSongs), the size of all its
  // files and the cover in its folders. callback(songs, extra); songs is
  // null when mpd fails.
  function albumInfo(album, artist, callback) {
    root.albumSongs(album, artist, function(songs) {
      if (!songs || songs.length === 0) { callback(songs, {}); return }
      var folders = Mpd.foldersOf(songs)
      root.send(Mpd.commandListOk(folders.map(function(dir) { return Mpd.command("listfiles", [dir]) })), function(lines, error) {
        if (error !== "") { callback(songs, { folders: folders }); return }
        var size = 0
        var cover = ""
        Mpd.splitReplies(lines).forEach(function(reply, i) {
          var sizes = Mpd.parseFileSizes(reply)
          songs.forEach(function(song) {
            if (Mpd.directoryOf(song.file) !== folders[i]) return
            size += sizes[folders[i] === "" ? song.file : song.file.slice(folders[i].length + 1)] || 0
          })
          if (cover === "") cover = Mpd.pickCover(Mpd.parseValues(reply, "file")) || ""
        })
        callback(songs, { size: size, folders: folders, cover: cover })
      }, true)
    })
  }

  // An album artist's albums for the artist view; callback({ albums,
  // appearsOn }), or null when mpd fails. One count per album tells their own
  // albums from the compilations they appear on. mpd's albumartist falls
  // back to artist only for a song with no album artist, so compilations
  // that have one ("Various Artists") come from a second find, by artist.
  function artistAlbums(artist, callback) {
    root.send(Mpd.commandListOk([
      Mpd.command("find", [Mpd.tagFilter("albumartist", "==", artist)]),
      Mpd.command("find", [Mpd.tagFilter("artist", "==", artist)])
    ]), function(lines, error) {
      if (error !== "") { callback(null); return }
      var replies = Mpd.splitReplies(lines)
      var albums = Mpd.groupAlbums(Mpd.unionSongs(Mpd.parseSongs(replies[0] || []), Mpd.parseSongs(replies[1] || [])))
      var named = albums.filter(function(album) { return album.album !== "" })
      if (named.length === 0) { callback(Mpd.splitAppearances(albums, {})); return }
      root.send(Mpd.commandListOk(named.map(function(album) {
        return Mpd.command("count", [Mpd.tagFilter("album", "==", album.album)])
      })), function(lines, error) {
        var totals = {}
        if (error === "") Mpd.splitReplies(lines).forEach(function(reply, i) {
          totals[named[i].album] = parseInt(Mpd.parseObject(reply).songs, 10) || 0
        })
        callback(Mpd.splitAppearances(albums, totals))
      })
    })
  }

  // Accent-insensitive search over playlist names, genres, artists, albums
  // and song titles. The queries pipeline on the command socket; callback
  // gets { playlists, genres, artists, albums, songs } once all have answered.
  function search(query, callback) {
    var pattern = Mpd.searchPattern(query)
    if (pattern === "") { callback({ playlists: [], genres: [], artists: [], albums: [], songs: [] }); return }
    var out = { playlists: [], genres: [], artists: [], albums: [], albumsByArtist: [], songs: [] }
    var left = 6
    function done() {
      if (--left > 0) return
      var seen = {}
      var albums = []
      var all = Mpd.sortByMatch(Mpd.mergeAlbums(out.albums), query, function(a) { return a.album })
        .concat(Mpd.sortByMatch(Mpd.mergeAlbums(out.albumsByArtist), query, function(a) { return a.artists[0] }))
      for (var i = 0; i < all.length && albums.length < 40; i++) {
        if (seen[all[i].album]) continue
        seen[all[i].album] = true
        albums.push(all[i])
      }
      // How many songs each has, so a one-song album shows before it's opened.
      root.albumCounts(albums.map(function(album) { return album.album }), function(counts) {
        albums.forEach(function(album) { album.songCount = counts[album.album] || 0 })
        callback({
          playlists: out.playlists,
          genres: Mpd.sortByMatch(out.genres, query, function(g) { return g.name }).slice(0, 8),
          artists: Mpd.sortByMatch(out.artists, query, function(a) { return a }).slice(0, 12),
          albums: albums,
          songs: out.songs
        })
      })
    }
    var named = Mpd.sortByMatch(root.playlists.filter(function(p) { return Mpd.nameMatches(p.name, query) }),
      query, function(p) { return p.name }).slice(0, 8)
    root.playlistLengths(named.map(function(p) { return p.name }), function(lengths) {
      out.playlists = named.filter(function(p) { return lengths[p.name] }).map(function(p) {
        return { name: p.name, songs: lengths[p.name].songs, seconds: lengths[p.name].seconds }
      })
      done()
    })
    root.send(Mpd.command("count", [Mpd.tagFilter("genre", "=~", pattern), "group", "genre"]), function(lines, error) {
      out.genres = Mpd.parseCounts(lines, "genre").filter(function(g) { return g.name !== "" })
      done()
    })
    root.send(Mpd.command("list", ["albumartist", Mpd.tagFilter("albumartist", "=~", pattern)]), function(lines, error) {
      out.artists = Mpd.parseValues(lines, "albumartist").filter(function(a) { return a !== "" })
      done()
    })
    root.send(Mpd.command("list", ["album", Mpd.tagFilter("album", "=~", pattern), "group", "albumartist"]), function(lines, error) {
      out.albums = Mpd.parseGrouped(lines, "albumartist", "album")
      done()
    })
    root.send(Mpd.command("list", ["album", Mpd.tagFilter("albumartist", "=~", pattern), "group", "albumartist"]), function(lines, error) {
      out.albumsByArtist = Mpd.parseGrouped(lines, "albumartist", "album")
      done()
    })
    root.send(Mpd.command("search", [Mpd.tagFilter("title", "=~", pattern)]) + " window 0:40", function(lines, error) {
      out.songs = Mpd.parseSongs(lines)
      done()
    })
  }

  function reconnect() {
    if (!root.active || root.socketPath === "") return
    if (!idleSocket.connected) idleSocket.connected = true
  }

  onSocketPathChanged: reconnect()
  onActiveChanged: reconnect()
  Component.onCompleted: reconnect()

  Socket {
    id: idleSocket
    path: root.socketPath
    connected: false
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.idleLine(line) }
    }
    onConnectedChanged: {
      if (connected) return
      root.idleGreeted = false
      root.idleChanges = []
      reconnectTimer.restart()
    }
    // Disconnect after Quickshell has handed the error over, not while it
    // does: Quickshell 0.3.2 frees the socket on disconnect, then touches it
    // again once the error handlers return, and crashes the whole shell
    // (every mpd restart, on Omarchy 4.0.6). Stopping its own reconnects
    // still matters: reconnectTimer tries again in 3 s.
    onError: function(error) {
      Qt.callLater(function() { idleSocket.connected = false })
      if (root.lastError === "") root.lastError = "Can't reach mpd at " + root.socketPath
      reconnectTimer.restart()
    }
  }

  // mpd closes a command connection after a minute without commands; the
  // next command simply reconnects.
  Socket {
    id: commandSocket
    path: root.socketPath
    connected: false
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.commandLine(line) }
    }
    onConnectedChanged: {
      if (connected) return
      root.commandGreeted = false
      // A command cut off mid-reply is dropped, not resent: it may already
      // have run (resending "next" would skip twice).
      if (root.inflight) root.finishCommand("ACK [0@0] {} connection closed")
      if (root.pending.length > 0) commandRetryTimer.restart()
    }
    onError: function(error) {
      // After the error is handed over, as idleSocket's.
      Qt.callLater(function() { commandSocket.connected = false })
      if (root.ready) commandRetryTimer.restart()
      else root.dropPending()
    }
  }

  Timer {
    id: reconnectTimer
    interval: 3000
    onTriggered: root.reconnect()
  }

  Timer {
    id: commandRetryTimer
    interval: 1000
    onTriggered: root.pump()
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.inflight !== null && !root.stalled
    onTriggered: if (Date.now() - root.inflightSince > 15000) root.stalled = true
  }

  Timer {
    interval: 500
    repeat: true
    running: root.ticking && root.status.state === "play"
    onTriggered: root.elapsed = Math.min(root.status.duration || 1e9,
      root.elapsedBase + (Date.now() - root.elapsedAt) / 1000)
  }
}
