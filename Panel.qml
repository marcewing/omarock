import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Mpd.js" as Mpd
import "Apple.js" as Apple
import "Sxm.js" as Sxm
import "Radio.js" as Radio
import "Info.js" as Info

// omarock's popup. Laid out like crmne.hyprmoncfg: a compact panel with an
// Expand button, and an expanded panel in the same popup with Keys, TUI and
// Compact. mpd is the backend; the panel keeps no music state of its own.
Panel {
  id: root
  moduleName: "marc.omarock"
  ipcTarget: "marc.omarock"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string socketPath: {
    var configured = root.setting("socket", "")
    return configured !== "" ? configured : Quickshell.env("XDG_RUNTIME_DIR") + "/mpd/socket"
  }
  readonly property string tuiCommand: root.setting("tuiCommand", "ncmpcpp")
  // Close when the pointer leaves the panel, once it has been over it.
  readonly property bool closeOnLeave: root.setting("closeOnLeave", true) === true
  property bool pointerArmed: false

  // Apple Music (bridge/API.md): the bridge on the Mac, and the stream mpd
  // plays from it. Apple Music mode is mpd playing that stream, so the mode
  // lives in mpd too, and mpc shows it. The addresses come from the widget's
  // settings, else ~/.config/omarock/apple.json ({ "bridge", "stream" }),
  // which omarock-am reads too.
  property var appleConfig: ({})
  readonly property string appleBridge: root.setting("appleBridge", "") || appleConfig.bridge || ""
  readonly property string appleStream: root.setting("appleStream", "") || appleConfig.stream || ""
  readonly property string appleTokenFile: {
    var configured = root.setting("appleTokenFile", "")
    return configured !== "" ? configured : Quickshell.env("HOME") + "/.config/omarock/bridge-token"
  }
  // The optional sources, each switched on in the widget's settings (the
  // schema in manifest.json): its button in the panel, and any following of
  // its service, only then. Internet radio needs nothing set up, so it
  // starts on; the others need a service set up first, so they start off.
  readonly property bool radioEnabled: root.setting("radio", true) === true
  readonly property bool spotifyEnabled: root.setting("spotify", false) === true
  readonly property bool appleEnabled: root.setting("appleMusic", false) === true
  readonly property bool sxmEnabled: root.setting("siriusXM", false) === true
  readonly property bool appleConfigured: appleEnabled && appleBridge !== "" && appleStream !== ""
  // mpd's current song is the stream: Apple Music mode, unless Spotify is
  // the source (it plays without mpd, which stops). The same for SiriusXM and
  // the radio.
  readonly property bool mpdOnApple: appleConfigured && !!client.currentSong && client.currentSong.file === appleStream
  readonly property bool appleMode: source === "apple"
  // SiriusXM (sxm/README.md): the omarock-sxm service on this machine. Like
  // Apple Music, its mode is mpd playing one of its streams (a channel).
  readonly property string sxmService: root.setting("sxmService", "") || "http://127.0.0.1:8720"
  readonly property bool mpdOnSxm: !!client.currentSong && (client.currentSong.file || "").indexOf(sxm.prefix) === 0
  readonly property bool sxmMode: source === "sxm"
  // Internet radio (Radio.js): a station mpd plays straight from its stream.
  readonly property bool mpdOnRadio: !!client.currentSong && Radio.isRadio(client.currentSong.file || "")
  readonly property bool radioMode: source === "radio"
  // Spotify (spotify/README.md): Spotify's Soloist plays on this machine,
  // into omarock's bus, not through mpd. omarock-spotify drives it and speaks
  // the Apple Music bridge's API. It also keeps the mode: Spotify is the
  // source from when it starts playing (here, or from a phone), or omarock
  // switches to it, until mpd plays or omarock switches away.
  readonly property string spotifyService: root.setting("spotifyService", "") || "http://127.0.0.1:8730"
  readonly property bool spotifyMode: spotify.reachable && spotify.current
  // Apple Music and Spotify share the bridge's API, rows and views.
  readonly property bool bridgeMode: appleMode || spotifyMode
  readonly property var bridge: spotifyMode ? spotify : apple
  readonly property string radioBrowser: root.setting("radioBrowser", "")
  // The station to come back to when switching to the radio.
  property string lastStation: ""
  // The source playing, and the ones set up: m goes round them. The modes
  // above all follow from it, so they never disagree, even for a moment (the
  // list took a mode caught halfway through a change for another list).
  readonly property string source: spotifyMode ? "spotify" : mpdOnApple ? "apple" : mpdOnSxm ? "sxm" : mpdOnRadio ? "radio" : "local"
  // A source switched on shows even when its service can't be reached:
  // switching to it then says why, which helps while setting it up.
  readonly property var sources: ["local"].concat(appleEnabled ? ["apple"] : []).concat(spotifyEnabled ? ["spotify"] : [])
    .concat(sxmEnabled ? ["sxm"] : []).concat(radioEnabled ? ["radio"] : [])
  readonly property var sourceNames: ({ local: "local music", apple: "Apple Music", spotify: "Spotify", sxm: "SiriusXM", radio: "the radio" })
  // Anything listed belongs to the source it came from.
  onSourceChanged: {
    root.triedSource = ""
    root.pickerItem = null
    root.clearSearch()
  }
  // The channel to come back to when switching to SiriusXM.
  property string lastChannel: ""
  // What the player card, the transport keys and the bar follow.
  readonly property var player: bridgeMode ? bridge : sxmMode ? sxm : radioMode ? radio : client
  // Live sources: no seeking, shuffle or repeat; a pause is a stop.
  readonly property bool live: sxmMode || radioMode
  // Under the album in the player card: the genre, and Explicit, Lossless or
  // Dolby Atmos.
  readonly property string bridgeExtra: bridge.song
    ? [(bridge.song.genres || [])[0] || "", Apple.badges(bridge.song)].filter(function(p) { return p !== "" }).join(" · ") : ""
  // Under the station in the player card: where it is, its genres and sound.
  readonly property string radioExtra: radio.station ? Radio.describe(radio.station) : ""
  // Under the channel in the player card: the show, else the genre.
  readonly property string sxmExtra: sxm.now && sxm.now.show ? sxm.now.show : sxm.channel ? sxm.channel.genre : ""
  // The local song Apple Music interrupted, { id, elapsed }, to resume it.
  property var localResume: null
  property string lastMpdState: ""
  // Matches manifest.json (tests/mpd.test.js checks). Logged on load and shown
  // in the key list, to tell which code the shell is running.
  readonly property string version: "0.5.1"

  property bool expanded: false
  property bool keysOpen: false
  property string query: ""
  property var resultRows: []
  property int searchSequence: 0
  property bool searching: false
  property int cursorIndex: 0
  property bool cursorActive: false
  property bool returnPressed: false
  property string notice: ""
  property string localCoverUrl: ""
  property string coverDirectory: ""
  // Album folder -> cover URL, for the covers in the browse views.
  property var coverUrls: ({})
  // "album\0artist" -> a song file, for album rows known only by name.
  property var albumCoverFiles: ({})
  property var searchField: null
  property var listView: null
  readonly property alias picker: playlistPicker

  // Browsing: from the search results, into an artist, then into an album;
  // or from the queue into Playlists (P), then into a playlist. Each level
  // is { kind, artist, album, genre, playlist, title, from, rows, info,
  // files }; it keeps its rows, so going back is instant.
  property var browseStack: []
  // Where the first level was opened from: "search" or "queue".
  property string browseRoot: "search"
  property var browseRows: []
  property var browseInfo: ({})
  property bool browseLoading: false
  property int browseSequence: 0

  // The expanded panel shows search and browsing as two columns. Before
  // anything is opened, the right one previews what → would open.
  property var previewEntry: null
  property var previewRows: []
  property var previewInfo: ({})
  property bool previewLoading: false
  property int previewSequence: 0

  // Adding to a playlist: the picker is open while pickerItem is set, to
  // { result, title } (what client.addToPlaylist adds, and its name).
  property var pickerItem: null
  // Playlist name -> { songs, seconds }, for the picker's rows.
  property var playlistCounts: ({})
  // The playlist the delete dialog asks about: { playlist, songs }.
  property var deleteTarget: null
  // The info card (i) while it's open: { card (Info.js), coverFile, logo,
  // coverUrl, loading }.
  property var infoCard: null
  property int infoSequence: 0

  readonly property bool connected: client.ready && (!bridgeMode || bridge.ready) && (!sxmMode || sxm.available)
  readonly property bool playing: player.status.state === "play"
  readonly property string coverUrl: bridgeMode ? Apple.artUrl(bridge.song ? bridge.song.artwork : null, 360)
    : sxmMode ? Apple.artUrl({ url: (sxm.now && sxm.now.art) || (sxm.channel && sxm.channel.logo) || "" }, 360)
    : radioMode ? radio.art
    : localCoverUrl
  readonly property bool searchMode: query.trim() !== ""
  readonly property var browseTop: browseStack.length > 0 ? browseStack[browseStack.length - 1] : null
  readonly property bool browsing: browseTop !== null
  readonly property bool columns: expanded && (searchMode || browsing)
  readonly property bool pickerOpen: pickerItem !== null
  readonly property bool confirmOpen: deleteTarget !== null
  readonly property bool infoOpen: infoCard !== null
  // The info card's cover: a local album's (by a song of it), a station's
  // logo once it's known to load, else Apple Music's artwork or a channel's.
  readonly property string infoCoverUrl: !root.infoCard ? ""
    : root.infoCard.coverFile ? (root.coverUrls[Mpd.directoryOf(root.infoCard.coverFile)] || "")
    : root.infoCard.logo ? radio.logoUrl(root.infoCard.logo)
    : root.infoCard.coverUrl
  readonly property var rows: browsing ? browseRows : searchMode ? resultRows : queueRows
  // Which list the keys work in. The same list redrawn (a station tuned, the
  // song moved on) stays where it is; another (a search typed, a level
  // opened) starts at the top.
  readonly property string listKey: root.browsing
    ? "browse:" + root.browseStack.length + ":" + root.browseTop.kind + ":" + root.browseTop.title
    : root.searchMode ? "search:" + root.query : "queue:" + root.source
  readonly property string playingFile: player.status.state !== "stop" && player.currentSong
    ? (player.currentSong.file || "") : ""
  readonly property string backLabel: browseStack.length > 1
    ? "Back to " + browseStack[browseStack.length - 2].title
    : browseRoot === "queue" ? "Back to the queue" : "Back to the results"
  readonly property string nowPlayingText: {
    var song = root.player.currentSong
    if (!song || !song.file) return ""
    var artist = Mpd.songArtist(song)
    return Mpd.songTitle(song) + (artist !== "" ? " · " + artist : "")
  }
  // For the bar: the current song, and whether Play would pick one at random.
  readonly property bool hasSong: player.ready && !!player.currentSong && !!player.currentSong.file
  readonly property string songTitle: hasSong ? Mpd.songTitle(player.currentSong) : ""
  readonly property string songArtist: hasSong ? Mpd.songArtist(player.currentSong) : ""
  readonly property string songAlbum: hasSong ? (player.currentSong.album || "") : ""
  readonly property bool queueEmpty: player.status.queueLength === 0

  readonly property var queueRows: {
    if (root.bridgeMode) return Apple.queueRows(root.bridge.bridgeStatus)
    if (root.sxmMode) return Sxm.channelRows(sxm.channels, sxm.nowPlaying, sxm.currentId)
    if (root.radioMode) return Radio.listRows(radio.favorites, radio.local, radio.currentUuid, radio.place, radio.station)
    var current = client.status.state !== "stop" ? client.status.songId : ""
    return client.queue.map(function(song, i) {
      var artist = Mpd.songArtist(song)
      var parts = []
      if (artist !== "") parts.push(artist)
      if (song.album) parts.push(song.album)
      return {
        kind: "queue",
        id: song.id,
        file: song.file,
        lead: String(i + 1),
        title: Mpd.songTitle(song),
        subtitle: parts.join(" · "),
        detail: Mpd.formatTime(parseFloat(song.duration || song.time || 0)),
        playing: current !== "" && song.id === current
      }
    })
  }

  // "Playing · song 3 of 12"; stateText adds "Apple Music · " in Apple Music
  // mode, except under the header, where the switch beside it says so.
  readonly property string playStateText: {
    if (!client.ready) return "Not connected"
    if (root.bridgeMode && !root.bridge.ready) return "Not connected"
    if (root.sxmMode && !sxm.available) return "SiriusXM isn't running"
    var s = root.player.status
    var word = s.state === "play" ? "Playing" : s.state === "pause" ? "Paused" : "Stopped"
    if (s.song >= 0 && s.queueLength > 0) word += " · song " + (s.song + 1) + " of " + s.queueLength
    return word
  }
  readonly property string stateText: (root.bridgeMode ? root.bridge.service + " · " : root.sxmMode ? "SiriusXM · "
    : root.radioMode ? "Radio · " : "") + root.playStateText

  // The queue's total time, when all of it is listed.
  readonly property int queueSeconds: {
    if (!root.bridgeMode) return client.queueTotalSeconds
    var seconds = 0
    root.bridge.queue.forEach(function(song) { seconds += song.duration || 0 })
    return seconds
  }
  readonly property bool queueComplete: root.player.queue.length === root.player.status.queueLength

  readonly property string queueSummary: {
    if (root.sxmMode) return root.countText(sxm.channels.length, "channel")
    if (root.radioMode) return root.countText(radio.favorites.length, "favourite")
    var n = root.player.status.queueLength
    if (n === 0) return "Empty"
    return root.countText(n, "song") + (root.queueComplete ? " · " + Mpd.formatTotal(root.queueSeconds) : "")
  }

  readonly property string queueHeading: {
    if (root.sxmMode) return "SIRIUSXM · " + sxm.channels.length + " CHANNELS"
    if (root.radioMode) return "RADIO" + (radio.place !== "" ? " · " + radio.place.toUpperCase() : "")
    var n = root.player.status.queueLength
    var title = root.bridgeMode ? root.bridge.service.toUpperCase() + " QUEUE" : "QUEUE"
    if (n === 0) return title
    var heading = title + " · " + n + (n === 1 ? " SONG" : " SONGS")
    if (root.queueComplete) heading += " · " + Mpd.formatTotal(root.queueSeconds).toUpperCase()
    else heading += " · " + root.player.queue.length + " SHOWN"
    return heading
  }

  // The row Enter or → would act on: the cursor's, else the top result. The
  // hints say what Enter does with it, and the columns preview it.
  readonly property int enterIndex: root.cursorActive ? root.cursorIndex : root.searchMode && !root.browsing ? 0 : -1
  readonly property var enterRow: root.rows[root.enterIndex] || null
  onEnterRowChanged: root.schedulePreview()
  onColumnsChanged: root.schedulePreview()
  readonly property string hintText: {
    var row = root.enterRow
    var kind = row ? row.kind : ""
    var source = root.sources.length < 2 ? "" : " · m " + root.sourceNames[root.nextSource()]
    if (!root.searchMode && !root.browsing && root.sxmMode)
      return root.cursorActive && row ? "Enter tune · A " + (row.favorite ? "unfavourite" : "favourite") + " · i info · n p channel" + source + " · ? keys"
        : "Space play/stop · / find a channel · n p channel" + source + " · ? keys"
    if (!root.searchMode && !root.browsing && root.radioMode)
      return root.cursorActive && row ? "Enter tune · A " + (row.favorite ? "unfavourite" : "favourite") + " · i info · n p favourite" + source + " · ? keys"
        : "Space play/stop · / find a station · n p favourite" + source + " · ? keys"
    if (!root.searchMode && !root.browsing)
      return root.cursorActive && row ? "Enter play · A add to playlist" + (root.bridgeMode && !root.bridge.canRemove ? "" : " · x remove")
          + " · i info · P playlists · ? keys"
        : "Space play/pause · / search · P playlists" + source + " · ? keys"
    var parts = [root.opens(kind) ? "→ open" : kind === "channel" || kind === "station" ? "Enter tune" : kind === "track" ? "Enter play from here"
      : kind === "shuffleall" ? "Enter shuffle all" : kind === "savequeue" ? "Enter save the queue"
      : kind === "note" || kind === "" ? "" : "Enter play"]
    if (root.rowQueues(row)) parts.push("a add to queue")
    if (root.playlistItem(root.browseTop, row)) parts.push("A add to playlist")
    if (kind === "channel" || kind === "station") parts.push(row.favorite ? "A unfavourite" : "A favourite")
    if (row && row.removable) parts.push(kind === "playlist" ? "x delete" : "x remove")
    if (root.infoRequest(root.browseTop, row)) parts.push("i info")
    parts.push(root.browsing ? "← back" : "Esc clear", "? keys")
    return parts.filter(function(part) { return part !== "" }).join(" · ")
  }

  function open() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function openFromHotkey() { root.open() }

  function playPause() { root.player.playPause() }
  function nextSong() { root.player.next() }
  function previousSong() { root.player.previous() }

  // Local, Apple Music or SiriusXM. Apple Music and SiriusXM modes are mpd
  // playing a stream: switching to one adds its stream after the current song
  // (dropping the other source's), and switching back to local deletes it and
  // resumes the local song where it was.
  function setSource(name) {
    if (name === root.source) return
    // Leaving Spotify, for anything: it pauses and stops being the source.
    var fromSpotify = root.spotifyMode
    if (fromSpotify) spotify.release()
    if (name === "apple") root.switchToApple()
    else if (name === "spotify") root.switchToSpotify()
    else if (name === "sxm") root.switchToSxm("")
    else if (name === "radio") root.switchToRadio("")
    else root.switchToLocal(fromSpotify)
  }

  // m goes round the sources from the one it last tried, while that switch
  // didn't happen (its service down, or not set up yet), so it moves on past
  // a source that fails instead of asking it again.
  property string triedSource: ""
  function nextSource() {
    var list = root.sources
    var from = root.triedSource !== "" && list.indexOf(root.triedSource) >= 0 ? root.triedSource : root.source
    return list[(list.indexOf(from) + 1) % list.length]
  }
  function nextSourceKey() {
    var target = root.nextSource()
    root.triedSource = target
    root.setSource(target)
  }

  // The streams of the sources other than local, to drop when changing source.
  function streamPrefixes() {
    return [root.appleStream, sxm.prefix, Radio.MARKER].filter(function(p) { return p !== "" })
  }

  // Leaving local music: where its song was, to resume it later.
  function rememberLocal() {
    if (root.source !== "local") return
    var s = client.status
    root.localResume = s.state !== "stop" && s.songId !== "" ? { id: s.songId, elapsed: client.elapsed } : null
  }

  // SiriusXM: tune a channel (the last one, else the first favourite).
  function switchToSxm(channelId) {
    root.say("Connecting to SiriusXM…")
    sxm.checkHealth(function(ok, error) {
      if (!ok) {
        root.say(error !== "" ? error : "SiriusXM isn't available")
        return
      }
      var go = function() {
        var favorite = sxm.channels.filter(function(c) { return c.favorite })[0]
        var id = channelId || root.lastChannel || (favorite || sxm.channels[0] || {}).id || ""
        if (id === "") {
          root.say("SiriusXM has no channels")
          return
        }
        root.rememberLocal()
        if (root.mpdOnApple) apple.pause()
        client.setLive(true)
        root.playLive(sxm.prefix + id, root.streamPrefixes(), root.channelName(id))
        root.clearSearch()
      }
      if (sxm.channels.length > 0) go()
      else sxm.refreshChannels(function(data, error) { if (data) go(); else root.say(error) })
    })
  }

  // A channel from the list, search, or n and p.
  function tune(channelId) {
    if (!root.sxmMode) {
      root.switchToSxm(channelId)
      return
    }
    root.playLive(sxm.prefix + channelId, [sxm.prefix], root.channelName(channelId))
  }

  function channelName(channelId) {
    var channel = sxm.channels.filter(function(c) { return c.id === channelId })[0]
    return channel ? channel.name : "the channel"
  }

  // A station or channel: "Tuning …" until mpd plays it (a station can take
  // a second or two to connect), then "Tuned to …", or why not.
  property string tunedName: ""
  function playLive(url, drop, name) {
    if (url !== client.streamTuning) root.say("Tuning " + name + "…")
    root.tunedName = name
    client.playStream(url, drop, function(error) {
      root.say(error === "" ? "Tuned to " + name : root.streamError(error, name))
    })
  }

  // The radio: tune a station (the last one, else the first favourite, else
  // the most listened local station, else the most listened in the US).
  function switchToRadio(uuid) {
    var pick = function(station) {
      if (!station) {
        root.say("No station found. Press / and search for one.")
        return
      }
      root.rememberLocal()
      if (root.mpdOnApple) apple.pause()
      client.setLive(true)
      root.tuneStation(station)
      root.clearSearch()
    }
    var known = radio.stations[uuid || root.lastStation] || radio.favorites[0] || radio.local[0]
    if (known) {
      pick(known)
      return
    }
    root.say("Finding a station…")
    radio.get("/json/stations/search?countrycode=US&hidebroken=true&order=clickcount&reverse=true&limit=1", function(data) {
      radio.remember(data)
      pick(data && data[0])
    })
  }

  function tuneStation(station) {
    if (!Radio.playable(station)) {
      root.say(station.name.trim() + " only streams HLS, which mpd can't play")
      return
    }
    root.playLive(Radio.streamUrl(station), root.streamPrefixes(), station.name.trim())
    radio.click(station.stationuuid)
  }

  function toggleFavorite(row) {
    // In the list (not search results), the cursor follows it to its new place.
    root.favoriteFollow = root.searchMode || root.browsing ? null
      : { kind: row.kind, id: row.kind === "station" ? row.stationUuid : row.channelId, favorite: !row.favorite,
          until: Date.now() + 10000 }
    var done = function(error, adding) {
      if (error !== "") {
        root.favoriteFollow = null
        root.say(error)
      } else {
        root.say(adding ? row.name + " is a favourite" : row.name + " is no longer a favourite")
      }
    }
    if (row.kind === "station") radio.toggleFavorite(row.stationUuid, done)
    else sxm.toggleFavorite(row.channelId, done)
  }

  // After A, the cursor follows the station or channel, rather than the list
  // staying put while it moves to the favourites. Once the list shows the
  // change (the radio's favourites come back from mpd's "Radio" playlist a
  // moment later), the cursor moves to the station or channel's first row: up
  // in the favourites, or back in its place. That row comes to the middle of
  // the list.
  property var favoriteFollow: null
  onQueueRowsChanged: root.followFavorite()
  function followFavorite() {
    var follow = root.favoriteFollow
    if (!follow) return
    if (Date.now() > follow.until || root.searchMode || root.browsing) {
      root.favoriteFollow = null
      return
    }
    var at = root.queueRows.findIndex(function(r) {
      return r.kind === follow.kind && (follow.kind === "station" ? r.stationUuid : r.channelId) === follow.id
    })
    if (at < 0 || root.queueRows[at].favorite !== follow.favorite) return
    root.favoriteFollow = null
    root.cursorActive = true
    root.cursorIndex = at
    centerTimer.index = at
    centerTimer.restart()
  }

  function switchToApple() {
    if (!root.appleConfigured) {
      root.say("Apple Music isn't set up (bridge/README.md)")
      return
    }
    root.say("Connecting to Apple Music…")
    apple.checkHealth(function(ok, error) {
      if (!ok) {
        root.say(error !== "" ? error : "Can't reach Apple Music on the Mac")
        return
      }
      root.rememberLocal()
      client.setLive(true)
      // mpd joins the stream at once, so the panel switches; the stream is
      // quiet until the Mac resumes, so mpd rejoins once it has
      // (AppleClient.catchUp), or else it would stay behind.
      client.playStream(root.appleStream, root.streamPrefixes())
      apple.post("/v1/resume", {}, apple.catchUp)
      root.clearSearch()
      root.say("Apple Music")
    })
  }

  // Spotify: omarock-spotify makes it the source. mpd stops playing (its
  // song stays where it was), and Spotify carries on with what it had.
  function switchToSpotify() {
    root.say("Connecting to Spotify…")
    spotify.checkHealth(function(ok, error) {
      if (!ok) {
        root.say(error !== "" ? error : "Spotify isn't available")
        return
      }
      root.rememberLocal()
      if (root.mpdOnApple) apple.pause()
      spotify.activate(function(data, activateError) { root.say(activateError !== "" ? activateError : "Spotify") })
      root.clearSearch()
    })
  }

  // fromSpotify: Spotify paused the local song, and nothing says where it
  // was; then it just plays on.
  function switchToLocal(fromSpotify) {
    client.setLive(false)
    if (root.mpdOnApple) apple.pause()
    client.leaveStream(root.streamPrefixes(), root.localResume)
    if (fromSpotify && !root.localResume && client.status.state === "pause") client.send("pause 0")
    root.localResume = null
    root.clearSearch()
    root.say("Local music")
  }

  // In Apple Music mode, mpd paused (the media keys, mpc) pauses the Mac
  // too, and mpd stops rather than pauses, so playing again reconnects to the
  // live stream instead of resuming behind it. mpd playing again resumes the Mac.
  function followMpd() {
    var state = client.status.state
    var was = root.lastMpdState
    root.lastMpdState = state
    // SiriusXM and the radio are live: a pause becomes a stop.
    if (root.live && state === "pause" && was !== "pause") client.send("stop")
    // A stream that failed (a station refusing, say): say why, once.
    var error = client.status.error || ""
    if (root.source !== "local" && !root.spotifyMode && error !== "" && error !== root.lastStreamError && client.streamTuning === "")
      root.say(root.streamError(error, root.live ? root.tunedName : ""))
    root.lastStreamError = error
    // On the Apple Music stream even under Spotify, which stops mpd: the Mac
    // pauses too, rather than playing to nobody. Only when the current song
    // is the one the status is about: mpd's status comes before its current
    // song, so switching from a stopped Apple Music stream to SiriusXM read
    // as the stream playing again, and resumed the Mac to play to nobody.
    if (!root.mpdOnApple || state === was || String(client.currentSong.id) !== String(client.status.songId)) return
    if (state === "pause") {
      client.send("stop")
      if (apple.bridgeStatus.state === "playing") apple.pause()
    } else if (state === "stop" && was === "play") {
      if (apple.bridgeStatus.state === "playing") apple.pause()
    } else if (state === "play" && apple.bridgeStatus.state === "paused") {
      apple.post("/v1/resume", {}, apple.catchUp)
    }
  }

  property string lastStreamError: ""

  // mpd's error for a stream, as a sentence; name is the station's, if known.
  function streamError(error, name) {
    var status = error.match(/HTTP status (\d+)/)
    var what = name || (root.radioMode ? "The station" : "The stream")
    if (status) return what + " refused the connection (HTTP " + status[1] + "). Try another, or again later."
    if (/^ACK /.test(error)) return "Couldn't tune " + (name || "it") + ": " + error.replace(/^ACK \[[^\]]*\] \{[^}]*\} /, "")
    var reason = error.replace(/^Failed to decode "[^"]*"; ?/, "") || "no reason given"
    return name ? name + " didn't play: " + reason : what + " stopped: " + reason
  }

  // The pointer left the card: close after a moment, unless it comes back.
  // On opening, and when the card resizes under a still pointer (Compact, a
  // shorter list), this waits until the pointer is over the card.
  function pointerLeft() {
    if (root.pointerArmed && root.closeOnLeave && root.opened) leaveDelay.restart()
  }

  function cardResized() {
    root.pointerArmed = false
    leaveDelay.stop()
    rearmDelay.restart()
  }

  Component.onCompleted: console.info("omarock " + root.version + " loaded")

  onOpenedChanged: {
    client.ticking = root.opened
    apple.ticking = root.opened
    spotify.ticking = root.opened
    if (root.opened && root.spotifyEnabled) spotify.checkHealth()
    sxm.watching = root.opened && root.sxmEnabled
    if (root.opened && root.sxmEnabled) sxm.checkHealth()
    radio.watching = root.opened
    if (root.opened && root.radioMode) radio.refreshLocal()
    if (root.opened && root.appleConfigured && !root.appleMode) apple.checkHealth()
    // Apple's genres need the catalog; fetch them again if they didn't come before.
    if (root.opened && root.appleMode && apple.genres.length === 0) apple.refreshGenres()
    root.cardResized()
    if (root.opened) {
      root.cursorActive = false
      root.keysOpen = false
      root.closeInfo()
      client.forgetMissingCovers()
      root.coverDirectory = ""
      root.updateCover()
      client.refreshStatus()
      Qt.callLater(root.showCurrentSong)
    } else {
      root.pickerItem = null
      root.deleteTarget = null
      root.clearSearch()
    }
  }

  function launchTui() {
    root.close()
    Quickshell.execDetached(["omarchy-launch-or-focus-tui", root.tuiCommand])
  }

  function say(text) {
    root.notice = text
    noticeTimer.restart()
  }

  function updateCover() {
    var file = client.currentSong ? (client.currentSong.file || "") : ""
    var dir = Mpd.directoryOf(file)
    if (file === "" || !Mpd.isLocalFile(file)) {
      root.coverDirectory = ""
      root.localCoverUrl = ""
      return
    }
    if (dir === root.coverDirectory && root.localCoverUrl !== "") return
    if (dir !== root.coverDirectory) root.localCoverUrl = ""
    root.coverDirectory = dir
    client.cover(file)
  }

  // The queue row of the song playing.
  function currentQueueRow() {
    if (root.sxmMode) {
      var id = sxm.currentId
      return root.queueRows.findIndex(function(row) { return row.channelId === id })
    }
    if (root.radioMode) {
      var uuid = radio.currentUuid
      return root.queueRows.findIndex(function(row) { return row.stationUuid === uuid })
    }
    return root.bridgeMode ? root.player.status.song - (root.bridge.bridgeStatus.queueOffset || 0) : client.status.song
  }

  function showCurrentSong() {
    if (root.searchMode || root.browsing || !root.listView) return
    var index = root.currentQueueRow()
    if (index >= 0 && index < root.queueRows.length) root.listView.positionViewAtIndex(index, ListView.Center)
  }

  // Search.
  function focusSearch() {
    if (root.searchField) root.searchField.forceActiveFocus()
  }

  function leaveSearch() {
    keyCatcher.forceActiveFocus()
  }

  function clearSearch() {
    root.resetBrowse()
    root.clearPreview()
    root.query = ""
    root.resultRows = []
    root.searching = false
    root.searchSequence++
    if (root.searchField) root.searchField.text = ""
    root.cursorActive = false
    root.cursorIndex = 0
  }

  function setQuery(text) {
    if (text === root.query) return
    if (root.browsing) root.resetBrowse()
    root.query = text
    root.cursorActive = false
    root.cursorIndex = 0
    if (text.trim() === "") {
      root.resultRows = []
      root.searching = false
      root.searchSequence++
      searchDelay.stop()
    } else {
      root.searching = true
      searchDelay.restart()
    }
  }

  function runSearch() {
    var sequence = ++root.searchSequence
    var query = root.query
    if (root.sxmMode) {
      root.resultRows = Sxm.searchRows(sxm.channels, sxm.nowPlaying, query, Mpd.fold, sxm.currentId)
      root.searching = false
      return
    }
    if (root.radioMode) {
      radio.search(query, function(stations, error) {
        if (sequence !== root.searchSequence) return
        var favorites = radio.favorites.map(function(s) { return s.stationuuid })
        root.resultRows = stations ? Radio.searchRows(stations, radio.currentUuid, favorites) : []
        root.searching = false
        if (!stations) root.say(error)
      })
      return
    }
    if (root.bridgeMode) {
      var bridge = root.bridge
      bridge.search(query, function(results, error) {
        if (sequence !== root.searchSequence) return
        root.resultRows = results ? Apple.searchRows(results, Apple.matchGenres(bridge.genres, query, Mpd.fold), bridge.service) : []
        root.searching = false
        if (!results) root.say(error)
      })
      return
    }
    client.search(query, function(results) {
      if (sequence !== root.searchSequence) return
      root.resultRows = root.buildResultRows(results)
      root.searching = false
    })
  }

  function buildResultRows(results) {
    var rows = []
    results.playlists.forEach(function(playlist, i) {
      rows.push(root.playlistRow(playlist, i === 0 ? "PLAYLISTS" : "", false))
    })
    results.genres.forEach(function(genre, i) {
      rows.push({ kind: "genre", section: i === 0 ? "GENRES" : "", lead: "󰓹",
        title: genre.name, subtitle: root.countText(genre.songs, "song"), genre: genre.name })
    })
    results.artists.forEach(function(artist, i) {
      rows.push({ kind: "artist", section: i === 0 ? "ARTISTS" : "", lead: "󰠃",
        title: artist, subtitle: "", artist: artist })
    })
    results.albums.forEach(function(album, i) {
      rows.push({ kind: "album", section: i === 0 ? "ALBUMS" : "", lead: "󰀥",
        title: album.album, subtitle: album.albumartist !== "" ? album.albumartist : album.artists.length + " artists",
        artist: album.albumartist, album: album.album })
    })
    results.songs.forEach(function(song, i) {
      var parts = []
      var artist = Mpd.songArtist(song)
      if (artist !== "") parts.push(artist)
      if (song.album) parts.push(song.album)
      rows.push({ kind: "song", section: i === 0 ? "SONGS" : "", lead: "󰝚",
        title: Mpd.songTitle(song), subtitle: parts.join(" · "),
        detail: Mpd.formatTime(parseFloat(song.duration || song.time || 0)), file: song.file })
    })
    return rows
  }

  // Browsing. Enter or a click on an artist or album opens it in the list;
  // Esc or Backspace goes back to where it was opened from.
  function opens(kind) {
    return kind === "artist" || kind === "album" || kind === "genre" || kind === "compilations" || kind === "playlist"
  }

  // Rows that play and add to the queue (▶, +, a). A genre's compilations
  // only open; Save the queue and notes do nothing else.
  function queues(kind) {
    return kind !== "" && kind !== "queue" && kind !== "compilations" && kind !== "savequeue" && kind !== "note"
  }

  // The same for a row: an Apple Music genre only opens (to its charts).
  function rowQueues(row) {
    return !!row && root.queues(row.kind) && !row.missing && row.noQueue !== true
  }

  function makeEntry(row, index) {
    if (row.apple) {
      return { kind: row.kind, apple: row.apple, title: row.name || row.title, artist: "", album: "", genre: "",
        playlist: "", from: index, rows: [], info: ({}), files: [], loaded: false }
    }
    return { kind: row.kind, artist: row.artist || "", album: row.album || "", genre: row.genre || "",
      playlist: row.playlist || "",
      title: row.kind === "album" ? root.albumTitle(row.album) : row.kind === "genre" ? row.genre
        : row.kind === "compilations" ? "Compilations" : row.kind === "playlist" ? row.playlist
        : row.kind === "playlists" ? "Playlists" : row.artist,
      from: index, rows: [], info: ({}), files: [], loaded: false }
  }

  function sameEntry(a, b) {
    if (a.apple || b.apple)
      return !!a.apple && !!b.apple && a.apple.kind === b.apple.kind && a.apple.id === b.apple.id
        && a.apple.source === b.apple.source
    return a.kind === b.kind && a.artist === b.artist && a.album === b.album && a.genre === b.genre
      && a.playlist === b.playlist
  }

  // P or the Playlists button: the Playlists view, opened from the queue.
  function openPlaylists() {
    if (root.sxmMode || root.radioMode) {
      root.say(root.sxmMode ? "Your favourite channels are at the top of the list" : "Your favourite stations are at the top of the list")
      return
    }
    if (root.browseRoot === "queue" && root.browseStack.length === 1 && root.browseTop.kind === "playlists") return
    root.clearSearch()
    root.leaveSearch()
    root.browseRoot = "queue"
    var entry = root.bridgeMode
      ? root.makeEntry({ kind: "playlists", apple: { kind: "playlists", id: "", source: "library" }, title: root.bridge.service + " playlists" }, -1)
      : root.makeEntry({ kind: "playlists" }, -1)
    root.browseStack = [entry]
    root.loadBrowse(entry)
  }

  function openRow(index) {
    var row = root.rows[index]
    if (!row || !root.opens(row.kind)) return
    var entry = root.makeEntry(row, index)
    var preview = root.previewEntry
    root.clearPreview()
    root.leaveSearch()
    // The columns already loaded it as the preview: move it over as is.
    if (preview && preview.loaded && root.sameEntry(preview, entry)) {
      preview.from = index
      root.browseSequence++
      root.browseStack = root.browseStack.concat([preview])
      root.showEntry(preview)
      return
    }
    root.browseStack = root.browseStack.concat([entry])
    root.loadBrowse(entry)
  }

  function goBack() {
    if (!root.browsing) return
    var left = root.browseTop
    var stack = root.browseStack.slice(0, -1)
    var top = stack.length > 0 ? stack[stack.length - 1] : null
    root.browseSequence++
    root.browseLoading = false
    root.browseStack = stack
    root.browseRows = top ? top.rows : []
    root.browseInfo = top ? top.info : ({})
    // Back in the queue (from Playlists), the cursor rests.
    root.cursorActive = root.rows.length > 0 && left.from >= 0
    root.cursorIndex = Math.max(0, Math.min(left.from, root.rows.length - 1))
    // Back at the results, the level just left is the preview again.
    if (!top && left.loaded && root.searchMode) root.setPreview(left)
    if (!top) root.browseRoot = "search"
  }

  function resetBrowse() {
    root.browseSequence++
    root.browseRoot = "search"
    root.browseStack = []
    root.browseRows = []
    root.browseInfo = ({})
    root.browseLoading = false
  }

  function loadBrowse(entry) {
    var sequence = ++root.browseSequence
    root.browseRows = []
    root.browseInfo = root.placeholderInfo(entry)
    root.browseLoading = true
    root.cursorActive = false
    root.cursorIndex = 0
    root.loadEntry(entry, function() {
      if (sequence === root.browseSequence) root.showEntry(entry)
    })
  }

  function showEntry(entry) {
    root.browseRows = entry.rows
    root.browseInfo = entry.info
    root.browseLoading = false
    // Start on the first album or song; the Play row is just above it.
    root.cursorActive = entry.rows.length > 0
    root.cursorIndex = entry.rows.length > 1 ? 1 : 0
  }

  function placeholderInfo(entry) {
    return { title: entry.title, coverFile: "",
      subtitle: entry.kind === "artist" ? "Artist" : entry.kind === "genre" ? "Genre"
        : entry.kind === "playlist" ? "Playlist" : entry.kind === "playlists" ? "" : "Album" }
  }

  // The preview column (expanded panel, before anything is opened): what the
  // cursor's row would open, loaded a moment after the cursor stops.
  function schedulePreview() {
    if (root.columns && !root.browsing) previewDelay.restart()
  }

  function updatePreview() {
    if (!root.columns || root.browsing) return
    var row = root.enterRow
    if (!row || !root.opens(row.kind)) { root.clearPreview(); return }
    var entry = root.makeEntry(row, root.enterIndex)
    if (root.previewEntry && root.sameEntry(root.previewEntry, entry)) return
    var sequence = ++root.previewSequence
    root.previewEntry = entry
    root.previewRows = []
    root.previewInfo = root.placeholderInfo(entry)
    root.previewLoading = true
    root.loadEntry(entry, function() {
      if (sequence !== root.previewSequence) return
      root.previewRows = entry.rows
      root.previewInfo = entry.info
      root.previewLoading = false
    })
  }

  function setPreview(entry) {
    root.previewSequence++
    root.previewEntry = entry
    root.previewRows = entry.rows
    root.previewInfo = entry.info
    root.previewLoading = false
  }

  function clearPreview() {
    root.previewSequence++
    previewDelay.stop()
    root.previewEntry = null
    root.previewRows = []
    root.previewInfo = ({})
    root.previewLoading = false
  }

  // Fills in entry.rows and entry.info from the Apple Music bridge (or
  // Spotify's service), then done().
  function loadAppleEntry(entry, done) {
    var bridge = root.bridge
    function show(view) {
      entry.rows = view.rows
      entry.info = view.info
      entry.files = []
      entry.loaded = true
      done()
    }
    function shown(make) {
      return function(data, error) {
        if (data) show(make(data))
        else show({ rows: [], info: { title: entry.title, subtitle: "", failed: true, emptyText: error + ". ← goes back." } })
      }
    }
    var ref = entry.apple
    if (ref.kind === "playlists") {
      bridge.refreshPlaylists(shown(function(data) { return Apple.playlistsView(data, bridge.status.queueLength, bridge.service) }))
    } else if (ref.kind === "album") {
      bridge.album(ref.source, ref.id, shown(function(data) { return Apple.albumView(data.album, data.tracks || [], bridge.service) }))
    } else if (ref.kind === "artist") {
      bridge.artist(ref.source, ref.id, shown(function(data) { return Apple.artistView(data.artist, data, bridge.service) }))
    } else if (ref.kind === "playlist") {
      bridge.playlist(ref.source, ref.id, shown(function(data) { return Apple.playlistView(data.playlist, data.tracks || [], data.note) }))
    } else if (ref.kind === "genre") {
      bridge.genre(ref.id, shown(function(data) { return Apple.genreView(data.genre || { name: entry.title }, data) }))
    }
  }

  // Fills in entry.rows, entry.info and entry.files from mpd, then done().
  function loadEntry(entry, done) {
    if (entry.apple) {
      root.loadAppleEntry(entry, done)
      return
    }
    function show(rows, info, files) {
      entry.rows = rows
      entry.info = info
      entry.files = files
      entry.loaded = true
      // Row covers are asked for as rows come into view (requestCover).
      if (info.coverFile) client.cover(info.coverFile)
      done()
    }

    function failed() {
      show([], { title: entry.title, subtitle: "", coverFile: "", failed: true }, [])
    }

    if (entry.kind === "playlists") {
      client.playlistSummaries(function(playlists) {
        if (!playlists) { failed(); return }
        show(root.playlistsRows(playlists), { title: entry.title, coverFile: "",
          subtitle: playlists.length === 0 ? "None yet" : root.countText(playlists.length, "playlist") }, [])
      })
    } else if (entry.kind === "playlist") {
      client.playlistSongs(entry.playlist, function(songs, error) {
        if (!songs) {
          show([], { title: entry.title, subtitle: "Playlist", coverFile: "", failed: true,
            emptyText: error.indexOf("No such playlist") >= 0 ? "This playlist is gone. ← goes back." : "" }, [])
          return
        }
        show(root.playlistSongRows(songs), root.playlistInfo(entry, songs),
          Mpd.filesOf(songs.filter(function(song) { return !Mpd.isMissing(song) })))
      })
    } else if (entry.kind === "genre") {
      client.genreAlbums(entry.genre, function(view) {
        if (!view) { failed(); return }
        var split = Mpd.genreArtists(view.albums)
        show(root.genreRows(view, split), { title: entry.title, coverFile: "",
          subtitle: "Genre · " + root.countText(split.artists.length, "artist") + " · "
            + root.countText(view.albums.length, "album") }, [])
      })
    } else if (entry.kind === "compilations") {
      client.genreAlbums(entry.genre, function(view) {
        if (!view) { failed(); return }
        var albums = Mpd.genreArtists(view.albums).compilations
        show(albums.map(function(album) { return root.genreAlbumRow(album) }), { title: entry.title, coverFile: "",
          subtitle: entry.genre + " · " + root.countText(albums.length, "album") }, [])
      })
    } else if (entry.kind === "artist") {
      client.artistAlbums(entry.artist, function(view) {
        if (view) show(root.artistRows(entry, view), { title: entry.title, subtitle: "Artist", coverFile: "" },
          Mpd.artistFiles(view))
        else failed()
      })
    } else {
      client.albumSongs(entry.album, entry.artist, function(songs) {
        if (!songs) failed()
        else if (entry.artist === "" && Mpd.sharedName(songs)) {
          var albums = Mpd.albumsSharingName(songs)
          show(root.sharedNameRows(albums),
            { title: entry.title, subtitle: albums.length + " albums have this name", coverFile: "" }, [])
        } else {
          show(root.albumRows(songs), root.albumInfo(entry, songs), Mpd.filesOf(songs))
        }
      })
    }
  }

  function albumTitle(album) {
    return album !== "" ? album : "Songs without an album"
  }

  function countText(n, word) {
    return Mpd.formatCount(n) + " " + word + (n === 1 ? "" : "s")
  }

  function albumRow(album, artist, section, appears) {
    var parts = album.year !== "" ? [album.year] : []
    if (appears) parts.push("on " + album.songs.length + " of " + album.total + " songs")
    else parts.push(root.countText(album.songs.length, "song"), Mpd.formatTotal(album.seconds))
    return { kind: "album", section: section, lead: "󰀥", coverFile: album.songs[0].file,
      title: root.albumTitle(album.album), subtitle: parts.join(" · "), artist: artist, album: album.album }
  }

  // The artist view: Play all songs, their albums by year, then the
  // compilations they appear on.
  function artistRows(entry, view) {
    var all = view.albums.concat(view.appearsOn)
    var songs = 0
    var seconds = 0
    all.forEach(function(album) { songs += album.songs.length; seconds += album.seconds })
    var rows = [{ kind: "playall", lead: "󰐊", title: "Play all songs",
      subtitle: [root.countText(all.length, "album"), root.countText(songs, "song"), Mpd.formatTotal(seconds)].join(" · ") }]
    view.albums.forEach(function(album, i) {
      rows.push(root.albumRow(album, entry.artist, i === 0 ? "ALBUMS" : "", false))
    })
    view.appearsOn.forEach(function(album, i) {
      rows.push(root.albumRow(album, entry.artist, i === 0 ? "APPEARS ON" : "", true))
    })
    return rows
  }

  // The genre view: Shuffle all songs, then the artists with their own
  // albums in the genre (each shown with the cover of their first), then one
  // row for its compilations. Covers are looked up as rows come into view.
  function genreRows(view, split) {
    var rows = [{ kind: "shuffleall", lead: "󰒟", title: "Shuffle all songs",
      subtitle: root.countText(view.songs, "song") + " · " + Mpd.formatTotal(view.seconds) }]
    split.artists.forEach(function(entry, i) {
      rows.push({ kind: "artist", section: i === 0 ? "ARTISTS" : "", lead: "󰠃", artist: entry.artist,
        title: entry.artist, subtitle: root.countText(entry.albums.length, "album"),
        cover: { album: entry.albums[0].album, artist: entry.artist } })
    })
    if (split.compilations.length > 0) {
      var first = split.compilations[0]
      rows.push({ kind: "compilations", section: split.artists.length === 0 ? "ARTISTS" : "", lead: "󰀥",
        genre: view.genre, title: "Compilations", subtitle: root.countText(split.compilations.length, "album"),
        cover: { album: first.album, artist: first.albumartist } })
    }
    return rows
  }

  // An album row in a genre's lists, known by name until its cover is found.
  function genreAlbumRow(album) {
    var artist = album.albumartist !== "" ? album.albumartist : album.artists.length + " artists"
    return { kind: "album", lead: "󰀥", title: album.album, subtitle: artist + (album.year !== "" ? " · " + album.year : ""),
      artist: album.albumartist, album: album.album, cover: { album: album.album, artist: album.albumartist } }
  }

  // A playlist in the search results or the Playlists view.
  function playlistRow(playlist, section, removable) {
    return { kind: "playlist", section: section, lead: "󰲸", title: playlist.name, playlist: playlist.name,
      songs: playlist.songs, removable: removable,
      subtitle: root.countText(playlist.songs, "song") + (playlist.songs > 0 ? " · " + Mpd.formatTotal(playlist.seconds) : "") }
  }

  // The Playlists view: Save the queue, then the playlists by name.
  function playlistsRows(playlists) {
    var queued = client.status.queueLength
    var rows = [{ kind: "savequeue", lead: "󰆓", title: "Save the queue as a playlist",
      subtitle: queued > 0 ? root.countText(queued, "song") + " in the queue" : "The queue is empty" }]
    playlists.forEach(function(playlist, i) {
      rows.push(root.playlistRow(playlist, i === 0 ? "PLAYLISTS" : "", true))
    })
    if (playlists.length === 0)
      rows.push({ kind: "note", lead: "󰋼", title: "No playlists yet",
        subtitle: "Press A on a song, album, artist or genre to start one" })
    return rows
  }

  // A playlist's view: Play the playlist, then its songs in order, each with
  // its album's cover. Songs that have left the library stay listed, dimmed.
  function playlistSongRows(songs) {
    if (songs.length === 0) return []
    var seconds = 0
    songs.forEach(function(song) { seconds += Mpd.songSeconds(song) })
    var rows = [{ kind: "playplaylist", lead: "󰐊", title: "Play the playlist",
      subtitle: root.countText(songs.length, "song") + " · " + Mpd.formatTotal(seconds) }]
    var present = 0
    songs.forEach(function(song, i) {
      var missing = Mpd.isMissing(song)
      var parts = []
      if (Mpd.songArtist(song) !== "") parts.push(Mpd.songArtist(song))
      if (song.album) parts.push(song.album)
      var row = { kind: "track", lead: String(i + 1), title: Mpd.songTitle(song), file: song.file,
        // position: in the playlist; queuePosition: in the queue after load,
        // which skips missing songs.
        position: i, queuePosition: present, removable: true, missing: missing,
        subtitle: missing ? "Not in the library any more" : parts.join(" · "),
        detail: missing ? "" : Mpd.formatTime(Mpd.songSeconds(song)) }
      if (!missing) {
        row.coverFile = song.file
        present++
      }
      rows.push(row)
    })
    return rows
  }

  function playlistInfo(entry, songs) {
    var seconds = 0
    var cover = ""
    songs.forEach(function(song) {
      seconds += Mpd.songSeconds(song)
      if (cover === "" && !Mpd.isMissing(song)) cover = song.file
    })
    return { title: entry.title, coverFile: cover,
      subtitle: "Playlist · " + root.countText(songs.length, "song") + (songs.length > 0 ? " · " + Mpd.formatTotal(seconds) : ""),
      emptyText: "This playlist is empty. Find a song, album or artist and press A to add it." }
  }

  // A row's cover, asked for when the row is created (so only rows that
  // come into view cost a lookup), and its URL once known. A row has either
  // coverFile (a song of the album) or cover ({ album, artist } to look up).
  function requestCover(row) {
    if (row.kind === "station") {
      if (row.artwork) radio.checkLogo(row.artwork.url)
      return
    }
    if (row.apple) return
    if (row.coverFile) {
      client.cover(row.coverFile)
    } else if (row.cover) {
      var key = row.cover.album + "\u0000" + row.cover.artist
      if (root.albumCoverFiles[key] !== undefined) return
      client.albumFile(row.cover.album, row.cover.artist, function(file) {
        var files = Object.assign({}, root.albumCoverFiles)
        files[key] = file
        root.albumCoverFiles = files
        if (file !== "") client.cover(file)
      })
    }
  }

  function rowCoverUrl(row) {
    if (row.kind === "station") return row.artwork ? radio.logoUrl(row.artwork.url) : ""
    if (row.artwork) return Apple.artUrl(row.artwork, 36)
    var file = row.coverFile || (row.cover ? root.albumCoverFiles[row.cover.album + "\u0000" + row.cover.artist] || "" : "")
    return file ? (root.coverUrls[Mpd.directoryOf(file)] || "") : ""
  }

  // Several albums share this name and none was picked: one row each.
  function sharedNameRows(albums) {
    return albums.map(function(album, i) {
      var row = root.albumRow(album, album.albumartist, i === 0 ? "ALBUMS WITH THIS NAME" : "", false)
      row.subtitle = album.albumartist + " · " + row.subtitle
      return row
    })
  }

  // The album view: Play the album, then its songs, by disc when it has
  // several.
  function albumRows(songs) {
    var artists = {}
    var discs = {}
    var seconds = 0
    songs.forEach(function(song) {
      artists[Mpd.songArtist(song)] = true
      discs[Mpd.trackNumber(song.disc) || 1] = true
      seconds += Mpd.songSeconds(song)
    })
    var various = Object.keys(artists).length > 1
    var multiDisc = Object.keys(discs).length > 1
    var rows = [{ kind: "playalbum", lead: "󰐊", title: "Play the album",
      subtitle: root.countText(songs.length, "song") + " · " + Mpd.formatTotal(seconds) }]
    var lastDisc = 0
    songs.forEach(function(song, i) {
      var disc = Mpd.trackNumber(song.disc) || 1
      rows.push({ kind: "track", section: multiDisc && disc !== lastDisc ? "DISC " + disc : "",
        lead: String(Mpd.trackNumber(song.track) || i + 1), title: Mpd.songTitle(song),
        subtitle: various ? Mpd.songArtist(song) : "", detail: Mpd.formatTime(Mpd.songSeconds(song)),
        file: song.file, position: i })
      lastDisc = disc
    })
    return rows
  }

  // The album view's heading: the album artist (the one with over half the
  // songs, else "Various artists") and the year.
  function albumInfo(entry, songs) {
    var counts = {}
    var year = ""
    songs.forEach(function(song) {
      var artist = song.albumartist || Mpd.songArtist(song)
      counts[artist] = (counts[artist] || 0) + 1
      var y = Mpd.songYear(song)
      if (y !== "" && (year === "" || y < year)) year = y
    })
    var top = Object.keys(counts).sort(function(a, b) { return counts[b] - counts[a] })[0] || ""
    var artist = top !== "" && counts[top] * 2 > songs.length ? top : "Various artists"
    return { title: entry.title, subtitle: artist + (year !== "" ? " · " + year : ""),
      coverFile: songs.length > 0 ? songs[0].file : "" }
  }

  // A heading's cover: Apple Music artwork, or a local album's cover file.
  function infoCover(info) {
    if (!info) return ""
    if (info.artwork) return Apple.artUrl(info.artwork, 44)
    return info.coverFile ? (root.coverUrls[Mpd.directoryOf(info.coverFile)] || "") : ""
  }

  // A heading's second line, with Apple Music's details (label, lossless).
  function infoSubtitle(info) {
    if (!info) return ""
    return [info.subtitle || "", info.detail || ""].filter(function(part) { return part !== "" }).join(" · ")
  }

  // The list cursor, shared by keyboard and mouse.
  function moveCursor(dy) {
    if (root.rows.length === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      var current = root.currentQueueRow()
      root.cursorIndex = !root.searchMode && !root.browsing && current >= 0 && current < root.rows.length ? current : 0
      return
    }
    root.cursorIndex = Math.max(0, Math.min(root.rows.length - 1, root.cursorIndex + dy))
  }

  function hoverRow(index) {
    root.cursorActive = true
    root.cursorIndex = index
  }

  // mode "open" is Enter or a click: it opens an artist or album and plays
  // anything else. "play" replaces the queue; "add" appends to it.
  function activateRow(index, mode) {
    root.activateIn(root.browseTop, root.rows, index, mode)
  }

  // The same for a row of any level: entry is the open artist, album or genre
  // the rows belong to, or null for the search results and the queue.
  function activateIn(entry, rows, index, mode) {
    var row = rows[index]
    if (!row || row.kind === "note") return
    if (row.kind === "station") {
      if (mode === "add") return
      var station = radio.stations[row.stationUuid]
      if (station) root.tuneStation(station)
      root.settleOnTuned(index, function(r) { return r.stationUuid === row.stationUuid })
      return
    }
    if (row.kind === "channel") {
      if (mode === "add") return
      if (row.missing) {
        root.say(row.name + " isn't available")
        return
      }
      root.tune(row.channelId)
      root.settleOnTuned(index, function(r) { return r.channelId === row.channelId })
      return
    }
    if (row.apple || (entry && entry.apple)) {
      root.activateApple(entry, row, index, mode)
      return
    }
    if (row.kind === "queue") {
      if (mode !== "add") client.playQueueId(row.id)
      return
    }
    if (row.kind === "savequeue") {
      root.saveQueue()
      return
    }
    if (row.missing) {
      root.say(row.title + " isn't in the library any more")
      return
    }
    if (mode === "open") {
      if (root.opens(row.kind)) {
        root.openRow(index)
        return
      }
      mode = "play"
    }
    // A genre's compilations only open; they are several albums by name.
    if (row.kind === "compilations") return
    var name = row.title
    if (row.kind === "playall" || row.kind === "playalbum") {
      name = entry.title
      client.queueFiles(entry.files, mode)
    } else if (row.kind === "shuffleall") {
      name = entry.title
      client.queueGenre(entry.genre, mode)
    } else if (row.kind === "playplaylist") {
      name = entry.title
      client.queuePlaylist(entry.playlist, mode)
    } else if (row.kind === "track") {
      // A song in an album or playlist plays it from that song.
      if (mode !== "play") client.queueFiles([row.file], "add")
      else if (entry.kind === "playlist") client.queuePlaylist(entry.playlist, "play", row.queuePosition)
      else client.queueFiles(entry.files, "play", row.position)
    } else {
      client.playResult(row, mode)
    }
    if (mode === "play") {
      root.clearSearch()
      root.leaveSearch()
      root.say("Playing " + name + (row.kind === "genre" || row.kind === "shuffleall" ? ", shuffled" : ""))
    } else {
      root.say("Added " + name + " to the queue")
    }
  }

  // Apple Music rows: the bridge plays them (mpd keeps playing its stream).
  // Spotify's the same, through its service.
  function activateApple(entry, row, index, mode) {
    if (row.kind === "queue") {
      if (mode !== "add") root.bridge.jump(row.index)
      return
    }
    if (row.kind === "savequeue") {
      root.saveQueue()
      return
    }
    if (mode === "open") {
      if (root.opens(row.kind)) {
        root.openRow(index)
        return
      }
      mode = "play"
    }
    if (row.noQueue) return
    if (row.playable === false) {
      root.say((row.name || row.title) + " isn't available to play")
      return
    }
    var name = row.name || row.title
    var items = [row.apple]
    var start = 0
    if (row.kind === "playalbum" || row.kind === "playplaylist" || row.kind === "playall") {
      name = entry.title
      items = [entry.apple]
    } else if (row.kind === "track" && mode === "play") {
      items = [entry.apple]
      start = row.position
    }
    root.bridge.playItems(items, mode === "play" ? "play" : "add", start, function(data, error) {
      if (error !== "") root.say(error)
    })
    if (mode === "play") {
      root.clearSearch()
      root.leaveSearch()
      root.say("Playing " + name)
    } else {
      root.say("Added " + name + " to the queue")
    }
  }

  // The level the open one was opened from: an artist, a genre, Playlists,
  // the search results or the queue.
  function parentLevel() {
    var n = root.browseStack.length
    return n >= 2 ? { entry: root.browseStack[n - 2], rows: root.browseStack[n - 2].rows }
      : { entry: null, rows: root.browseRoot === "queue" ? root.queueRows : root.resultRows }
  }

  // The level a column of the expanded panel shows, for its buttons.
  function columnLevel(role) {
    if (role === "parent") return root.parentLevel()
    if (role === "preview") return { entry: root.previewEntry, rows: root.previewRows }
    return { entry: root.browseTop, rows: root.rows }
  }

  function columnRemove(role, index) {
    var level = root.columnLevel(role)
    root.removeIn(level.entry, level.rows, index)
  }

  function columnAddToPlaylist(role, index) {
    var level = root.columnLevel(role)
    root.addToPlaylistIn(level.entry, level.rows, index)
  }

  // A click or button in the expanded panel's columns. The keys work in the
  // "current" column; left of it is the level it was opened from ("parent"),
  // and before anything is open, right of it is the "preview".
  function columnActivate(role, index, mode) {
    if (role === "current") {
      root.activateRow(index, mode)
    } else if (role === "parent") {
      var parent = root.parentLevel()
      var row = parent.rows[index]
      // Rows that don't open (a queue song, a song result) act in place.
      if (mode !== "open" || !row || !root.opens(row.kind)) {
        root.activateIn(parent.entry, parent.rows, index, mode)
        return
      }
      if (index === root.browseTop.from) return
      root.goBack()
      root.cursorActive = true
      root.cursorIndex = index
      root.activateRow(index, "open")
    } else if (root.previewEntry && root.previewEntry.loaded) {
      if (mode !== "open") { root.activateIn(root.previewEntry, root.previewRows, index, mode); return }
      root.openRow(root.enterIndex)
      root.cursorIndex = index
      root.activateRow(index, "open")
    }
  }

  // After tuning a station or channel, the list doesn't jump back to the
  // start. From the list, the list stays where it is with the cursor on
  // that row. From search, the list comes back with the cursor on it, in the
  // middle, if it's listed.
  function settleOnTuned(index, matches) {
    root.leaveSearch()
    if (!root.searchMode) {
      root.cursorActive = true
      root.cursorIndex = index
      return
    }
    root.clearSearch()
    var at = root.queueRows.findIndex(matches)
    if (at < 0) return
    root.cursorActive = true
    root.cursorIndex = at
    // After the list has settled on its new rows (it keeps the cursor in view).
    centerTimer.index = at
    centerTimer.restart()
  }

  Timer {
    id: centerTimer
    property int index: -1
    interval: 50
    // A row that fits on the list's first screen shows from the top (with
    // its section's heading); one further down comes to the middle.
    onTriggered: {
      var list = root.listView
      if (!list || !root.cursorActive || root.cursorIndex !== index) return
      list.positionViewAtBeginning()
      list.forceLayout()
      var item = list.itemAtIndex(index)
      if (!item || item.y + item.height > list.contentY + list.height) list.positionViewAtIndex(index, ListView.Center)
    }
  }

  // Esc: close the key list, else back out of an artist or album, else clear
  // the search, else close the panel.
  function stepBack() {
    if (root.pickerOpen) root.closePicker()
    else if (root.confirmOpen) root.cancelDelete()
    else if (root.infoOpen) root.closeInfo()
    else if (root.keysOpen) root.keysOpen = false
    else if (root.browsing) root.goBack()
    else if (root.searchMode) root.clearSearch()
    else root.close()
  }

  // x: a song out of the queue or out of the open playlist; on a playlist,
  // ask before deleting it.
  function removeRow(index) {
    root.removeIn(root.browseTop, root.rows, index)
  }

  function removeIn(entry, rows, index) {
    var row = rows[index]
    if (!row) return
    if (row.kind === "queue") {
      if (row.apple && !root.bridge.canRemove) {
        root.say(root.bridge.service + " can't take songs out of its queue")
        return
      }
      if (row.apple) root.bridge.removeAt(row.index)
      else client.removeQueueId(row.id)
      root.say("Removed " + (row.name || row.title))
    } else if (row.kind === "track" && entry && entry.kind === "playlist") {
      client.removeFromPlaylist(entry.playlist, row.position, function(error) {
        if (error === "") root.say("Removed " + row.title + " from " + entry.title)
      })
    } else if (row.kind === "playlist" && row.removable) {
      root.deleteTarget = { playlist: row.playlist, songs: row.songs }
    }
  }

  function cancelDelete() {
    root.deleteTarget = null
    keyCatcher.forceActiveFocus()
  }

  function confirmDelete() {
    var name = root.deleteTarget ? root.deleteTarget.playlist : ""
    root.cancelDelete()
    if (name === "") return
    client.deletePlaylist(name, function(error) {
      if (error !== "") return
      root.say("Deleted the playlist " + name)
      if (root.browseTop && root.browseTop.kind === "playlist" && root.browseTop.playlist === name) root.goBack()
    })
  }

  // A: what a row adds to a playlist, as { result, title }, or null.
  function playlistItem(entry, row) {
    if (!row || row.missing) return null
    var kind = row.kind
    if (row.apple || (entry && entry.apple)) {
      if (kind === "playall" || kind === "playalbum" || kind === "playplaylist")
        return entry ? { result: { items: [entry.apple] }, title: entry.title } : null
      if (row.apple && row.noQueue !== true) return { result: { items: [row.apple] }, title: row.name || row.title }
      return null
    }
    if (kind === "queue" || kind === "song" || kind === "track")
      return { result: { kind: "song", file: row.file }, title: row.title }
    if (kind === "playall" || kind === "playalbum" || kind === "playplaylist")
      return entry ? { result: { kind: "files", files: entry.files }, title: entry.title } : null
    if (kind === "shuffleall") return entry ? { result: { kind: "genre", genre: entry.genre }, title: entry.title } : null
    if (kind === "artist" || kind === "album" || kind === "genre" || kind === "playlist")
      return { result: row, title: row.title }
    return null
  }

  function addToPlaylistIn(entry, rows, index) {
    var item = root.playlistItem(entry, rows[index])
    if (item) root.openPicker(item)
  }

  function saveQueue() {
    if (root.player.status.queueLength === 0) root.say("The queue is empty")
    else if (root.bridgeMode) root.openPicker({ result: { items: [{ kind: "queue", id: "", source: "library" }] }, title: "The queue" })
    else root.openPicker({ result: { kind: "queue" }, title: "The queue" })
  }

  function openPicker(item) {
    root.keysOpen = false
    root.playlistCounts = ({})
    root.pickerItem = item
    if (root.bridgeMode) {
      root.bridge.refreshPlaylists(function(list) {
        if (root.pickerItem !== item || !list) return
        var counts = {}
        list.forEach(function(p) {
          if (counts[p.name] === undefined && typeof p.trackCount === "number") counts[p.name] = { songs: p.trackCount }
        })
        root.playlistCounts = counts
      })
      return
    }
    client.playlistLengths(client.playlists.map(function(p) { return p.name }), function(lengths) {
      if (root.pickerItem === item) root.playlistCounts = lengths
    })
  }

  function closePicker() {
    root.pickerItem = null
    keyCatcher.forceActiveFocus()
  }

  function pickPlaylist(name, isNew) {
    var item = root.pickerItem
    root.closePicker()
    if (!item) return
    if (item.result.items) {
      var done = function(error) {
        if (error !== "") { root.say(error); return }
        if (item.title === "The queue") root.say((isNew ? "Saved the queue as " : "Added the queue to ") + name)
        else root.say(isNew ? "New playlist " + name + ", with " + item.title : "Added " + item.title + " to " + name)
        root.refreshPlaylistViews()
      }
      var target = root.bridge.playlists.filter(function(p) { return p.name === name })[0]
      if (isNew || !target) root.bridge.createPlaylist(name, item.result.items, done)
      else root.bridge.addToPlaylist(target.id, item.result.items, done)
      return
    }
    client.addToPlaylist(name, item.result, isNew, function(error) {
      if (error === "nothing to add") root.say("Nothing to add")
      if (error !== "") return
      if (item.result.kind === "queue") root.say((isNew ? "Saved the queue as " : "Added the queue to ") + name)
      else root.say(isNew ? "New playlist " + name + ", with " + item.title : "Added " + item.title + " to " + name)
    })
  }

  // A stored playlist changed (here or in another client): reload the
  // playlist levels that are open, keeping the cursor where it was, and the
  // search results, which list playlists.
  function refreshPlaylistViews() {
    if (root.searchMode) root.runSearch()
    root.browseStack.forEach(function(entry) {
      if (entry.kind !== "playlist" && entry.kind !== "playlists") return
      if (!!entry.apple !== root.bridgeMode) return
      root.loadEntry(entry, function() {
        if (entry !== root.browseTop) {
          // The left column shows it: hand it the new rows.
          root.browseStack = root.browseStack.slice()
          return
        }
        var keep = root.cursorIndex
        root.browseRows = entry.rows
        root.browseInfo = entry.info
        root.browseLoading = false
        root.cursorActive = root.cursorActive && entry.rows.length > 0
        root.cursorIndex = Math.max(0, Math.min(keep, entry.rows.length - 1))
      })
    })
    var preview = root.previewEntry
    if (preview && preview.kind === "playlist") {
      var sequence = ++root.previewSequence
      root.loadEntry(preview, function() {
        if (sequence !== root.previewSequence) return
        root.previewRows = preview.rows
        root.previewInfo = preview.info
      })
    }
  }

  function cursorRow() {
    return root.cursorActive ? root.rows[root.cursorIndex] : null
  }

  // The info card (i): everything known about a song, album, station or
  // channel (Info.js), with the service at the top and, for Apple Music and
  // Spotify, whether it's in the library. What the row has shows at
  // once; mpd's or the bridge's answer fills it in.
  //
  // What i shows for a row, as { type, ... }, or null for rows it doesn't
  // describe (artists, genres, playlists). entry is the level the row is in;
  // its Play the album row stands for the album.
  function infoRequest(entry, row) {
    if (!row) return null
    var kind = row.kind
    var song = kind === "song" || kind === "track" || kind === "queue"
    if (kind === "station") return { type: "station", uuid: row.stationUuid }
    if (kind === "channel") return { type: "channel", id: row.channelId }
    if (row.item && (song || kind === "album")) return { type: "apple", item: row.item }
    if (kind === "playalbum" && entry && entry.apple)
      return entry.info && entry.info.item ? { type: "apple", item: entry.info.item } : null
    if (row.apple) return null
    if (song && row.file && Mpd.isLocalFile(row.file) && !row.missing) return { type: "localSong", file: row.file, title: row.title }
    if (kind === "album") return { type: "localAlbum", album: row.album || "", artist: row.artist || "", title: row.title }
    if (kind === "playalbum" && entry && entry.kind === "album" && !entry.apple)
      return { type: "localAlbum", album: entry.album, artist: entry.artist, title: entry.title }
    return null
  }

  // Without a cursor, i describes what's playing.
  function nowPlayingInfoRequest() {
    if (root.bridgeMode) return root.bridge.song ? { type: "apple", item: root.bridge.song } : null
    if (root.sxmMode) return sxm.currentId !== "" ? { type: "channel", id: sxm.currentId } : null
    if (root.radioMode) return radio.currentUuid !== "" ? { type: "station", uuid: radio.currentUuid } : null
    var file = client.currentSong.file || ""
    return Mpd.isLocalFile(file) ? { type: "localSong", file: file, title: Mpd.songTitle(client.currentSong) } : null
  }

  function showInfo() {
    var request = root.cursorActive ? root.infoRequest(root.browseTop, root.cursorRow()) : root.nowPlayingInfoRequest()
    if (request) root.openInfo(request)
    else if (root.cursorActive) root.say("i shows the details of a song, album, station or channel")
    else root.say("Nothing is playing: move to a song or album, then press i")
  }

  function openInfo(request) {
    var sequence = ++root.infoSequence
    root.keysOpen = false
    function show(card, look, loading) {
      if (sequence === root.infoSequence)
        root.infoCard = Object.assign({ card: card, coverFile: "", logo: "", coverUrl: "", loading: loading }, look)
    }
    if (request.type === "apple") {
      var item = request.item
      var bridge = root.bridge
      show(Info.appleItem(item, { checking: item.source !== "library" }, bridge.serviceKey), { coverUrl: Apple.artUrl(item.artwork, 160) }, true)
      bridge.info(item, function(extra) {
        var full = extra.item || item
        show(Info.appleItem(full, extra, bridge.serviceKey), { coverUrl: Apple.artUrl(full.artwork, 160) }, false)
      })
    } else if (request.type === "station") {
      var station = radio.stations[request.uuid]
      if (!station) { root.say("Radio Browser hasn't sent this station's details"); return }
      var playing = request.uuid === radio.currentUuid
      radio.checkLogo(station.favicon)
      show(Info.station(station, { favorite: radio.isFavorite(request.uuid), now: playing ? radio.song : null }),
        { logo: station.favicon || "" }, false)
    } else if (request.type === "channel") {
      var channel = sxm.channels.filter(function(c) { return c.id === request.id })[0]
      if (!channel) { root.say("omarock-sxm hasn't sent this channel's details"); return }
      var now = sxm.nowPlaying[request.id] || null
      show(Info.channel(channel, now), { coverUrl: Apple.artUrl({ url: (now && now.art) || channel.logo || "" }, 160) }, false)
    } else if (request.type === "localSong") {
      client.cover(request.file)
      show(Info.localSong({ file: request.file, title: request.title }, {}), { coverFile: request.file }, true)
      client.songInfo(request.file, function(song, extra) {
        if (song) show(Info.localSong(song, extra), { coverFile: request.file }, false)
        else root.closeInfo(sequence, "mpd doesn't know this song any more")
      })
    } else if (request.type === "localAlbum") {
      var placeholder = Info.localAlbum([], {})
      placeholder.title = request.title
      show(placeholder, {}, true)
      client.albumInfo(request.album, request.artist, function(songs, extra) {
        if (!songs || songs.length === 0) { root.closeInfo(sequence, "mpd has no songs for this album"); return }
        var card = Info.localAlbum(songs, extra)
        // Several albums share this name and none was picked (Mpd.sharedName).
        if (request.artist === "" && Mpd.sharedName(songs))
          card.notes = Mpd.albumsSharingName(songs).length + " albums have this name; these details cover them all. "
            + "Open it to pick one."
        client.cover(songs[0].file)
        show(card, { coverFile: songs[0].file }, false)
      })
    }
  }

  // sequence, when given: only if that card is still the one open (a late
  // answer saying it failed).
  function closeInfo(sequence, why) {
    if (sequence !== undefined && sequence !== root.infoSequence) return
    root.infoSequence++
    root.infoCard = null
    if (why) root.say(why)
  }

  // → opens the highlighted artist, album or genre (the top result when nothing is
  // highlighted yet), like Enter; on anything else it does nothing.
  function openCursorRow() {
    var index = root.cursorActive ? root.cursorIndex : root.searchMode && !root.browsing ? 0 : -1
    if (root.rows[index] && root.opens(root.rows[index].kind)) root.openRow(index)
  }

  function handleText(t) {
    var player = root.player
    var status = player.status
    if (t === "/" || t === "\u0006") root.focusSearch()
    else if (t === "n" || t === ">") player.next()
    else if (t === "p" || t === "<") player.previous()
    else if (t === "+" || t === "=") client.nudgeVolume(5)
    else if (t === "-" || t === "_") client.nudgeVolume(-5)
    else if (t === "s") player.setRandom(!status.random)
    else if (t === "r") player.setRepeat(!status.repeat)
    else if (t === "m" && root.sources.length > 1) root.nextSourceKey()
    else if (t === "e") root.expanded = !root.expanded
    else if (t === "t") root.launchTui()
    else if (t === "?") root.keysOpen = !root.keysOpen
    else if (t === "i") root.showInfo()
    else if (t === "P") root.openPlaylists()
    else if (t === "a") {
      var row = root.cursorRow()
      if (root.rowQueues(row)) root.activateRow(root.cursorIndex, "add")
    } else if (t === "A") {
      var picked = root.cursorRow()
      if (picked && (picked.kind === "channel" || picked.kind === "station")) root.toggleFavorite(picked)
      else if (root.cursorActive) root.addToPlaylistIn(root.browseTop, root.rows, root.cursorIndex)
    } else if (t === "\u007f" && root.cursorActive) root.removeRow(root.cursorIndex)
    else if (t === "\b") root.goBack()
  }

  onRowsChanged: {
    if (root.cursorIndex >= root.rows.length) root.cursorIndex = Math.max(0, root.rows.length - 1)
    if (root.rows.length === 0) root.cursorActive = false
  }

  MpdClient {
    id: client
    socketPath: root.socketPath
    onStalledChanged: if (stalled) root.say("mpd isn't answering. If it stays stuck: systemctl --user restart mpd")
    onCurrentSongChanged: root.updateCover()
    onMusicDirectoryChanged: root.updateCover()
    onCoverResolved: function(directory, url) {
      if (directory === root.coverDirectory) root.localCoverUrl = url
      if (url !== "" && root.coverUrls[directory] !== url) {
        var urls = Object.assign({}, root.coverUrls)
        urls[directory] = url
        root.coverUrls = urls
      }
    }
    onLastErrorChanged: if (client.ready && client.lastError !== "") root.say(client.lastError)
    onPlaylistsEdited: root.refreshPlaylistViews()
    // The radio's favourites are the "Radio" playlist: follow the list.
    onPlaylistsChanged: radio.refreshFavorites()
    onStatusChanged: root.followMpd()
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarock/apple.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.appleConfig = JSON.parse(text()) || {} } catch (e) { root.appleConfig = {} }
    }
    onLoadFailed: root.appleConfig = {}
    onFileChanged: reload()
  }

  RadioClient {
    id: radio
    api: root.radioBrowser
    mpd: client
    active: root.radioMode
    onCurrentUuidChanged: if (currentUuid !== "") root.lastStation = currentUuid
    onTuneRequested: function(station) { root.tuneStation(station) }
  }

  SxmClient {
    id: sxm
    baseUrl: root.sxmService
    mpd: client
    active: root.sxmMode
    onCurrentIdChanged: if (currentId !== "") root.lastChannel = currentId
    onTuneRequested: function(channel) { root.tune(channel.id) }
  }

  AppleClient {
    id: apple
    baseUrl: root.appleBridge
    tokenFile: root.appleTokenFile
    mpd: client
    active: root.mpdOnApple
    idleStopSeconds: Math.max(0, Number(root.setting("appleIdleStop", 60)) || 0)
    // On unless switched off: only a patched libFLAC keeps up without it.
    rejoinAfterChange: root.setting("appleRejoin", true) === true
    onLastErrorChanged: if (root.appleMode && apple.lastError !== "") root.say(apple.lastError)
  }

  // Spotify's service. Followed whenever Spotify is switched on, as its
  // status says whether Spotify is the source; without the service, it
  // looks again every 30 s.
  AppleClient {
    id: spotify
    baseUrl: root.spotifyService
    mpd: client
    service: "Spotify"
    serviceKey: "spotify"
    streamed: false
    canRemove: false
    bridgeName: "omarock-spotify"
    unreachableText: "Can't reach omarock-spotify (systemctl --user status omarock-spotify)"
    unauthorizedText: "Spotify isn't signed in: run omarock-sp login"
    active: root.spotifyEnabled
    retryMs: root.spotifyMode ? 3000 : 30000
    idleStopSeconds: 0
    onLastErrorChanged: if (root.spotifyMode && spotify.lastError !== "") root.say(spotify.lastError)
  }

  Timer {
    id: searchDelay
    interval: 180
    onTriggered: root.runSearch()
  }

  Timer {
    id: previewDelay
    interval: 120
    onTriggered: root.updatePreview()
  }

  Timer {
    id: noticeTimer
    interval: 3500
    // "Tuning …" stays until the station answers, and mpd stuck stays said.
    onTriggered: if (client.stalled || client.streamTuning !== "") restart(); else root.notice = ""
  }

  Timer {
    id: leaveDelay
    interval: 400
    onTriggered: if (root.opened && !cardHover.hovered) root.close()
  }

  Timer {
    id: rearmDelay
    interval: 150
    onTriggered: root.pointerArmed = cardHover.hovered
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.expanded ? 1120 : 430))
    contentHeight: root.expanded
      ? panel.fittedContentHeight(Style.space(740))
      : panel.fittedContentHeight(layout.item ? layout.item.implicitHeight : Style.space(400))
    onContentWidthChanged: root.cardResized()
    onContentHeightChanged: root.cardResized()

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The search box, the playlist picker and the delete dialog take
      // their own keys.
      blocked: (!!root.searchField && root.searchField.activeFocus) || root.pickerOpen || root.confirmOpen

      // ↑↓ move, → opens an artist or album, ← goes back. Shift+←→ seek
      // (the Shortcuts below take those before this sees them).
      onMoveRequested: function(dx, dy) {
        if (root.infoOpen) {
          if (dy !== 0) infoView.scroll(dy)
          else if (dx < 0) root.closeInfo()
          return
        }
        if (root.keysOpen) return
        if (dy !== 0) root.moveCursor(dy)
        else if (dx > 0) root.openCursorRow()
        else root.goBack()
      }
      onReturnRequested: root.returnPressed = true
      onActivateRequested: {
        var enter = root.returnPressed
        root.returnPressed = false
        if (root.infoOpen) { root.closeInfo(); return }
        if (root.keysOpen) { root.keysOpen = false; return }
        if (enter && root.cursorActive) root.activateRow(root.cursorIndex, "open")
        else if (enter && root.searchMode && !root.browsing) root.activateRow(0, "open")
        else root.playPause()
      }
      onDeleteRequested: if (root.cursorActive && !root.keysOpen && !root.infoOpen) root.removeRow(root.cursorIndex)
      onCloseRequested: root.stepBack()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (root.infoOpen) {
          if (text === "i") root.closeInfo()
          return
        }
        if (root.keysOpen && text !== "?") return
        root.handleText(text)
      }

      // The whole card, padding included.
      HoverHandler {
        id: cardHover
        margin: panel.padding + Style.space(2)
        onHoveredChanged: {
          if (hovered) {
            root.pointerArmed = true
            leaveDelay.stop()
          } else {
            root.pointerLeft()
          }
        }
      }

      Loader {
        id: layout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: root.expanded ? parent.height : (item ? item.implicitHeight : 0)
        sourceComponent: root.expanded ? expandedLayout : compactLayout
        visible: !root.keysOpen && !root.infoOpen
        onLoaded: Qt.callLater(root.showCurrentSong)
      }

      KeysHelp {
        anchors.fill: parent
        visible: root.keysOpen
        foreground: root.foreground
        fontFamily: root.fontFamily
        tuiName: root.tuiCommand
        version: root.version
        onCloseRequested: root.keysOpen = false
      }

      InfoCard {
        id: infoView
        objectName: "infoCard"
        anchors.fill: parent
        visible: root.infoOpen
        info: root.infoCard ? root.infoCard.card : null
        coverUrl: root.infoCoverUrl
        loading: !!root.infoCard && root.infoCard.loading
        wide: root.expanded
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCloseRequested: root.closeInfo()
      }

      PlaylistPicker {
        id: playlistPicker
        anchors.fill: parent
        z: 10
        open: root.pickerOpen
        title: root.pickerItem ? root.pickerItem.title : ""
        playlists: root.bridgeMode ? root.bridge.playlists.filter(function(p) { return p.canEdit !== false }) : client.playlists
        counts: root.playlistCounts
        foreground: root.foreground
        fontFamily: root.fontFamily
        onPicked: function(name, isNew) { root.pickPlaylist(name, isNew) }
        onCanceled: root.closePicker()
      }

      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        message: root.deleteTarget
          ? "Delete the playlist “" + root.deleteTarget.playlist + "”? "
            + (root.deleteTarget.songs > 0 ? "Its " + root.countText(root.deleteTarget.songs, "song") + " stay in the library."
              : "It's empty.")
          : ""
        confirmText: "Delete"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelDelete()
        onConfirmed: root.confirmDelete()
        onOpenedChanged: if (opened) {
          selectedIndex = 1
          deleteKeys.forceActiveFocus()
        }
      }

      // The dialog's keys: Enter, Esc, ← → and Tab; it swallows the rest.
      Item {
        id: deleteKeys
        Keys.onPressed: function(event) {
          deleteConfirm.handleKey(event)
          event.accepted = true
        }
      }

      Shortcut {
        sequence: "Shift+Right"
        enabled: root.opened && !root.keysOpen && !root.pickerOpen && !root.confirmOpen && !root.infoOpen
          && !(root.searchField && root.searchField.activeFocus)
        onActivated: root.player.seekBy(10)
      }

      Shortcut {
        sequence: "Shift+Left"
        enabled: root.opened && !root.keysOpen && !root.pickerOpen && !root.confirmOpen && !root.infoOpen
          && !(root.searchField && root.searchField.activeFocus)
        onActivated: root.player.seekBy(-10)
      }
    }
  }

  // ---------- Pieces shared by both layouts ----------

  component HeaderIcon: Item {
    implicitWidth: glyph.implicitWidth
    implicitHeight: glyph.implicitHeight
    opacity: root.connected ? 1.0 : 0.5

    Text {
      id: glyph
      textFormat: Text.PlainText
      text: "󰝚"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
    }
  }

  component HeaderLabels: Column {
    spacing: Style.space(1)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "Music"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: (root.sources.length > 1 ? root.playStateText : root.stateText).toUpperCase()
      color: root.connected ? root.dim : Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
      elide: Text.ElideRight
    }
  }

  // Local or Apple Music, when the bridge is set up (m). The compact panel
  // shows the icons only.
  component SourceSwitch: ButtonGroup {
    id: sourceSwitch
    property bool iconsOnly: false
    readonly property var all: [
      { value: "local", label: "Local", icon: "󱍙", tooltip: "Local music, from mpd (m)" },
      { value: "apple", label: "Apple Music", icon: "󰀵", tooltip: "Apple Music, from the Mac (m)" },
      { value: "spotify", label: "Spotify", icon: "󰓇", tooltip: "Spotify, playing on this machine (m)" },
      { value: "sxm", label: "SiriusXM", icon: "󰑱", tooltip: "SiriusXM's live channels (m)" },
      { value: "radio", label: "Radio", icon: "󰐹", tooltip: "Internet radio: FM and other stations (m)" }
    ]
    visible: root.sources.length > 1
    focusable: false
    spacing: Style.space(4)
    options: sourceSwitch.all.filter(function(o) { return root.sources.indexOf(o.value) >= 0 }).map(function(o) {
      return { value: o.value, label: sourceSwitch.iconsOnly ? "" : o.label, icon: o.icon, tooltip: o.tooltip }
    })
    value: root.source
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    onChanged: function(value) { root.setSource(value) }
  }

  component SearchBox: TextField {
    id: field
    placeholderText: root.radioMode ? "Stations: name, call sign, frequency or genre  ( / )"
      : root.sxmMode ? "SiriusXM channels: name, number, genre or artist  ( / )"
      : root.bridgeMode ? "Your " + root.bridge.service + ", and all of " + root.bridge.service + "  ( / )"
      : "Artists, albums, songs, genres, playlists  ( / )"
    foreground: root.foreground
    font.family: root.fontFamily
    Component.onCompleted: {
      field.text = root.query
      root.searchField = field
    }
    // At teardown the panel may already be gone.
    Component.onDestruction: if (root && root.searchField === field) root.searchField = null
    onTextChanged: root.setQuery(field.text)
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        if (root.browsing) root.goBack()
        else if (field.text !== "") root.clearSearch()
        else root.leaveSearch()
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        root.leaveSearch()
        if (root.rows.length > 0) { root.cursorActive = true; root.cursorIndex = 0 }
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (root.searchMode && root.rows.length > 0)
          root.activateRow(root.cursorActive ? root.cursorIndex : 0,
            (event.modifiers & Qt.ShiftModifier) ? "add" : "open")
        event.accepted = true
      } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        root.leaveSearch()
        event.accepted = true
      }
    }
  }

  // Above the queue: its length, and the way to the playlists.
  component QueueHeading: Item {
    implicitHeight: Math.max(queueTitle.implicitHeight, playlistsButton.implicitHeight)

    PanelSectionHeader {
      id: queueTitle
      anchors.left: parent.left
      anchors.right: playlistsButton.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: root.queueHeading
      elide: Text.ElideRight
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Button {
      id: playlistsButton
      visible: !root.live
      width: visible ? implicitWidth : 0
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "Playlists"
      iconText: "󰲸"
      iconSize: fontSize
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      tooltipText: "Your playlists, and saving the queue as one (P)"
      onClicked: root.openPlaylists()
    }
  }

  // A list of rows. By default the one the keys work in; the expanded
  // panel's columns also show the level it came from ("parent", with that
  // row marked) and the preview.
  component TrackList: Item {
    id: listRoot
    property string role: "current"
    // The list showCurrentSong scrolls: the queue's, not a column's.
    property bool registers: true
    property var model: root.rows
    property int markIndex: root.cursorActive ? root.cursorIndex : -1
    // The list it shows; "" for the columns that only follow along, which
    // start at the top whenever their rows change.
    property string listKey: listRoot.role === "current" ? root.listKey : ""
    property string shownKey: ""
    onMarkIndexChanged: Qt.callLater(listRoot.keepMarkVisible)
    function keepMarkVisible() {
      if (listRoot.markIndex >= 0 && listRoot.markIndex < list.count) list.positionViewAtIndex(listRoot.markIndex, ListView.Contain)
    }
    // The rows changed. The ListView's model is their count, and each row
    // reads its entry by index, because a ListView given a new array starts
    // again at the top, scrolling away whenever its rows were redrawn (tuning
    // a station jumped the list to the start). So the same list
    // redrawn with as many rows just updates in place. With a different
    // count, the same list goes back to where it was (as near as ListView
    // places it); another list starts at the top.
    // Another list (a search typed, a level opened, another source) starts
    // at the top, whether its key or its rows change first. Rows that came
    // with the old key still showing count as the new list's.
    onListKeyChanged: {
      if (listRoot.listKey === "" || listRoot.listKey === listRoot.shownKey) return
      listRoot.shownKey = listRoot.listKey
      list.model = listRoot.model.length
      list.positionViewAtBeginning()
      Qt.callLater(listRoot.keepMarkVisible)
    }
    onModelChanged: {
      var same = listRoot.listKey !== "" && listRoot.listKey === listRoot.shownKey
      listRoot.shownKey = listRoot.listKey
      var count = listRoot.model.length
      if (same && list.model === count) return
      var y = list.contentY
      list.model = count
      if (same) {
        list.forceLayout()
        list.contentY = Math.max(list.originY, Math.min(y, list.originY + list.contentHeight - list.height))
      } else {
        list.positionViewAtBeginning()
      }
      Qt.callLater(listRoot.keepMarkVisible)
    }
    property string emptyText: !root.connected ? (root.spotifyMode ? "Waiting for Spotify (omarock-spotify)…"
        : root.appleMode ? "Waiting for Apple Music on the Mac…"
        : root.sxmMode ? "Waiting for SiriusXM (omarock-sxm)…" : "Waiting for mpd…")
      : root.browsing ? (root.browseLoading ? "Loading…" : root.browseInfo.emptyText
        || (root.browseInfo.failed ? "mpd couldn't list this. Esc goes back." : "Nothing here."))
      : root.searchMode ? (root.searching ? "Searching…" : "Nothing matches “" + root.query.trim() + "”.")
      : root.sxmMode ? "No SiriusXM channels yet."
      : root.radioMode ? "No favourite stations yet. Press / to find one, then A to keep it here."
      : root.bridgeMode ? "Nothing queued on " + root.bridge.service + ". Search for an artist, album or song, then press Enter to play it."
      : "The queue is empty. Search for an artist, album or song, then press Enter to play it."

    ListView {
      id: list
      anchors.fill: parent
      clip: true
      spacing: Style.space(2)
      boundsBehavior: Flickable.StopAtBounds
      // The rows' count; see listRoot.onModelChanged.
      model: 0
      highlightFollowsCurrentItem: false
      // Scrolling follows the cursor (markIndex), not ListView's currentIndex.
      Component.onCompleted: {
        model = listRoot.model.length
        listRoot.shownKey = listRoot.listKey
        if (listRoot.registers) root.listView = list
        Qt.callLater(listRoot.keepMarkVisible)
      }
      Component.onDestruction: if (root && root.listView === list) root.listView = null

      ScrollBar.vertical: ScrollBar { objectName: "listScrollBar"; policy: ScrollBar.AsNeeded }

      delegate: Column {
        id: entryColumn
        required property int index
        // The row, read by index (the model is the count).
        readonly property var modelData: listRoot.model[entryColumn.index] || ({})
        onModelDataChanged: root.requestCover(entryColumn.modelData)
        Component.onCompleted: root.requestCover(entryColumn.modelData)
        width: ListView.view.width
        spacing: Style.space(2)

        // A section title ("ALBUMS") above the first row of a section. Its
        // own box sets the height, so the header never sizes itself.
        Item {
          visible: !!entryColumn.modelData.section
          width: parent.width
          height: visible ? sectionHeader.implicitHeight + Style.space(4) : 0

          PanelSectionHeader {
            id: sectionHeader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: entryColumn.modelData.section || ""
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
        }

        TrackRow {
          width: parent.width
          entry: entryColumn.modelData
          cursor: listRoot.markIndex === entryColumn.index
          actionsOnCursor: listRoot.role === "current"
          playingFile: root.playingFile
          coverUrl: root.rowCoverUrl(entryColumn.modelData)
          foreground: root.foreground
          fontFamily: root.fontFamily
          onHoveredRow: if (listRoot.role === "current") root.hoverRow(entryColumn.index)
          onActivated: root.columnActivate(listRoot.role, entryColumn.index, "open")
          onPlayRequested: root.columnActivate(listRoot.role, entryColumn.index, "play")
          onAddRequested: root.columnActivate(listRoot.role, entryColumn.index, "add")
          onPlaylistRequested: root.columnAddToPlaylist(listRoot.role, entryColumn.index)
          onRemoveRequested: root.columnRemove(listRoot.role, entryColumn.index)
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.space(8)
      visible: listRoot.model.length === 0
      text: listRoot.emptyText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  // Above each column of the expanded panel: what it shows, with Back on the
  // left column once something is open. One height for all, so the columns
  // line up.
  component ColumnHeading: Item {
    id: heading
    property string title: ""
    property string subtitle: ""
    property string cover: ""
    property bool showBack: false
    implicitHeight: Math.max(Style.space(44), headingBack.implicitHeight, headingLabels.implicitHeight)

    Button {
      id: headingBack
      visible: heading.showBack
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? implicitWidth : 0
      text: "Back"
      iconText: "󰁍"
      iconSize: fontSize
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      tooltipText: root.backLabel + " (← or Esc)"
      onClicked: root.goBack()
    }

    CoverArt {
      id: headingCover
      visible: heading.cover !== ""
      anchors.left: headingBack.right
      anchors.leftMargin: heading.showBack ? Style.space(12) : 0
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? Style.space(44) : 0
      height: Style.space(44)
      source: heading.cover
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Column {
      id: headingLabels
      anchors.left: headingCover.right
      anchors.leftMargin: heading.showBack || headingCover.visible ? Style.space(12) : 0
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: heading.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: text !== ""
        text: heading.subtitle
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // Above the list while browsing: Back, the cover (for an album), and what
  // is open.
  component BrowseHeading: Item {
    // One height with or without a cover, so the popup keeps its size.
    implicitHeight: Math.max(backButton.implicitHeight, Style.space(44), browseLabels.implicitHeight)

    Button {
      id: backButton
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "Back"
      iconText: "󰁍"
      iconSize: fontSize
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      tooltipText: root.backLabel + " (Esc)"
      onClicked: root.goBack()
    }

    CoverArt {
      id: browseCover
      visible: !!root.browseInfo.coverFile || !!root.browseInfo.artwork
      anchors.left: backButton.right
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? Style.space(44) : 0
      height: width
      source: root.infoCover(root.browseInfo)
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Column {
      id: browseLabels
      anchors.left: browseCover.visible ? browseCover.right : backButton.right
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.browseInfo.title || ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: text !== ""
        text: root.infoSubtitle(root.browseInfo)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component Hints: Text {
    textFormat: Text.PlainText
    text: root.notice !== "" ? root.notice : root.hintText
    color: root.notice !== "" ? root.foreground : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    elide: Text.ElideRight
    maximumLineCount: 2
  }

  // ---------- Compact ----------

  Component {
    id: compactLayout

    Column {
      spacing: Style.space(12)

      Item {
        width: parent.width
        implicitHeight: Math.max(compactIcon.implicitHeight, compactLabels.implicitHeight, expandButton.implicitHeight)

        HeaderIcon {
          id: compactIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        HeaderLabels {
          id: compactLabels
          anchors.left: compactIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: compactSource.visible ? compactSource.left : expandButton.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
        }

        SourceSwitch {
          id: compactSource
          iconsOnly: true
          anchors.right: expandButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        Button {
          id: expandButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Expand"
          iconText: "󰊓"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          tooltipText: "Bigger view (e)"
          onClicked: root.expanded = true
        }
      }

      PanelSeparator { foreground: root.foreground }

      PlayerCard {
        width: parent.width
        mpd: root.player
        coverUrl: root.coverUrl
        sourceName: root.spotifyMode ? "omarock-spotify" : root.appleMode ? "Apple Music on the Mac" : root.sxmMode ? "SiriusXM (omarock-sxm)" : "mpd"
        checkText: root.spotifyMode ? "Check it with: systemctl --user status omarock-spotify" : ""
        extraText: root.bridgeMode ? root.bridgeExtra : root.sxmMode ? root.sxmExtra : root.radioMode ? root.radioExtra : ""
        live: root.live
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      PanelSeparator { foreground: root.foreground }

      SearchBox { width: parent.width }

      QueueHeading {
        width: parent.width
        visible: !root.searchMode && !root.browsing
      }

      BrowseHeading {
        width: parent.width
        visible: root.browsing
      }

      TrackList {
        width: parent.width
        height: Style.space(root.browsing ? 254 : !root.searchMode ? 272 : 310)
      }

      PanelSeparator { foreground: root.foreground }

      Hints { width: parent.width }
    }
  }

  // ---------- Expanded ----------

  Component {
    id: expandedLayout

    Item {
      Item {
        id: expandedHeader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        implicitHeight: Math.max(expandedIcon.implicitHeight, expandedLabels.implicitHeight,
          headerButtons.implicitHeight) + Style.space(12)

        HeaderIcon {
          id: expandedIcon
          anchors.left: parent.left
          anchors.top: parent.top
        }

        HeaderLabels {
          id: expandedLabels
          anchors.left: expandedIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: headerButtons.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: expandedIcon.verticalCenter
        }

        Row {
          id: headerButtons
          anchors.right: parent.right
          anchors.verticalCenter: expandedIcon.verticalCenter
          spacing: Style.space(10)

          SourceSwitch { anchors.verticalCenter: parent.verticalCenter }

          Button {
            id: keysButton
            anchors.verticalCenter: parent.verticalCenter
            text: "? Keys"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.keysOpen = true
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            text: "TUI"
            iconText: "󰆍"
            iconSize: fontSize
            implicitHeight: keysButton.implicitHeight
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            tooltipText: "Open " + root.tuiCommand + " in a terminal (t)"
            onClicked: root.launchTui()
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            text: "Compact"
            iconText: "󰊔"
            iconSize: fontSize
            implicitHeight: keysButton.implicitHeight
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            tooltipText: "Smaller view (e)"
            onClicked: root.expanded = false
          }
        }

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: 1
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
        }
      }

      PlayerCard {
        id: largePlayer
        anchors.left: parent.left
        anchors.top: expandedHeader.bottom
        anchors.topMargin: Style.space(16)
        width: Style.space(360)
        large: true
        mpd: root.player
        coverUrl: root.coverUrl
        sourceName: root.spotifyMode ? "omarock-spotify" : root.appleMode ? "Apple Music on the Mac" : root.sxmMode ? "SiriusXM (omarock-sxm)" : "mpd"
        checkText: root.spotifyMode ? "Check it with: systemctl --user status omarock-spotify" : ""
        extraText: root.bridgeMode ? root.bridgeExtra : root.sxmMode ? root.sxmExtra : root.radioMode ? root.radioExtra : ""
        live: root.live
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Rectangle {
        id: divider
        anchors.left: largePlayer.right
        anchors.leftMargin: Style.space(18)
        anchors.top: expandedHeader.bottom
        anchors.topMargin: Style.space(16)
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(12)
        width: 1
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
      }

      Column {
        id: listColumn
        anchors.left: divider.right
        anchors.leftMargin: Style.space(18)
        anchors.right: parent.right
        anchors.top: expandedHeader.bottom
        anchors.topMargin: Style.space(16)
        spacing: Style.space(12)

        SearchBox { width: parent.width }

        QueueHeading {
          width: parent.width
          visible: !root.searchMode && !root.browsing
        }
      }

      // The queue: one list.
      TrackList {
        visible: !root.columns
        anchors.left: listColumn.left
        anchors.right: parent.right
        anchors.top: listColumn.bottom
        anchors.topMargin: Style.space(8)
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(12)
      }

      // Searching or browsing: two columns. Before anything is open, the
      // results (keys here) and a preview of what → would open; after, the
      // level it was opened from (the results, an artist, Playlists, or the
      // queue) and the open one (keys here). The column without the keys is
      // dimmed.
      Item {
        id: columnsArea
        visible: root.columns
        anchors.left: listColumn.left
        anchors.right: parent.right
        anchors.top: listColumn.bottom
        anchors.topMargin: Style.space(8)
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(12)

        readonly property real gap: Style.space(16)
        readonly property real columnWidth: Math.floor((width - gap) / 2)
        readonly property var parentInfo: root.browseStack.length >= 2
          ? root.browseStack[root.browseStack.length - 2].info
          : root.browseRoot === "queue" ? { title: "Queue", subtitle: root.queueSummary, coverFile: "" }
          : { title: "Results", subtitle: "“" + root.query.trim() + "”", coverFile: "" }

        ColumnHeading {
          id: leftHeading
          anchors.left: parent.left
          anchors.top: parent.top
          width: columnsArea.columnWidth
          showBack: root.browsing
          title: root.browsing ? columnsArea.parentInfo.title : "Results"
          subtitle: root.browsing ? columnsArea.parentInfo.subtitle
            : root.searching && root.resultRows.length === 0 ? "Searching…" : "“" + root.query.trim() + "”"
          cover: root.browsing ? root.infoCover(columnsArea.parentInfo) : ""
        }

        TrackList {
          anchors.left: parent.left
          anchors.top: leftHeading.bottom
          anchors.topMargin: Style.space(8)
          anchors.bottom: parent.bottom
          width: columnsArea.columnWidth
          registers: false
          role: root.browsing ? "parent" : "current"
          model: root.browsing ? root.parentLevel().rows : root.resultRows
          markIndex: root.browsing ? root.browseTop.from : root.cursorActive ? root.cursorIndex : -1
          opacity: root.browsing ? 0.7 : 1
        }

        Rectangle {
          x: columnsArea.columnWidth + Math.floor(columnsArea.gap / 2)
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: 1
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
        }

        ColumnHeading {
          id: rightHeading
          anchors.right: parent.right
          anchors.top: parent.top
          width: columnsArea.columnWidth
          title: root.browsing ? (root.browseInfo.title || "") : (root.previewInfo.title || "")
          subtitle: root.infoSubtitle(root.browsing ? root.browseInfo : root.previewInfo)
          cover: root.infoCover(root.browsing ? root.browseInfo : root.previewInfo)
        }

        TrackList {
          anchors.right: parent.right
          anchors.top: rightHeading.bottom
          anchors.topMargin: Style.space(8)
          anchors.bottom: parent.bottom
          width: columnsArea.columnWidth
          registers: false
          role: root.browsing ? "current" : "preview"
          model: root.browsing ? root.browseRows : root.previewRows
          markIndex: root.browsing && root.cursorActive ? root.cursorIndex : -1
          opacity: root.browsing ? 1 : 0.7
          emptyText: root.browsing ? (root.browseLoading ? "Loading…"
              : root.browseInfo.failed ? (root.browseInfo.emptyText || "mpd couldn't list this. ← goes back.") : "Nothing here.")
            : root.previewLoading ? "Loading…"
            : root.enterRow && root.enterRow.kind === "channel" ? "Enter tunes this channel."
            : root.enterRow && root.enterRow.kind === "station" ? "Enter tunes this station."
            : root.enterRow && !root.opens(root.enterRow.kind)
              ? "Enter plays this. Artists, albums and genres open here with →." : ""
        }
      }

      BorderSurface {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        implicitHeight: footerRow.implicitHeight + Style.space(20)
        height: implicitHeight
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.foreground, Color.accent)
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

        Item {
          id: footerRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(12)
          anchors.rightMargin: Style.space(12)
          implicitHeight: Math.max(footerState.implicitHeight, footerHints.implicitHeight)

          Text {
            id: footerState
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width * 0.4
            text: root.nowPlayingText !== "" ? root.stateText + " · " + root.nowPlayingText : root.stateText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Hints {
            id: footerHints
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width * 0.58
            horizontalAlignment: Text.AlignRight
          }
        }
      }
    }
  }
}
