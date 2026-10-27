import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Mpd.js" as Mpd
import "Apple.js" as Apple
import "Sxm.js" as Sxm
import "Radio.js" as Radio
import "Info.js" as Info
import "Settings.js" as Settings
import "Setup.js" as Setup
import "Hints.js" as Hints
import "TimeMachine.js" as TimeMachine
import "Keeper.js" as Keeper
import "History.js" as History

// omarock's popup. Laid out like crmne.hyprmoncfg: a compact panel with an
// Expand button, and an expanded panel in the same popup with the sources,
// the gear and Compact. mpd is the backend; the panel keeps no music state of
// its own.
Panel {
  id: root
  moduleName: "mre.omarock"
  ipcTarget: "mre.omarock"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string socketPath: {
    var configured = root.setting("socket", "")
    return configured !== "" ? configured : Quickshell.env("XDG_RUNTIME_DIR") + "/mpd/socket"
  }
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
  // The optional sources, each switched on in omarock's settings
  // (Settings.js): its button in the panel, and any following of
  // its service, only then. Internet radio needs nothing set up, so it
  // starts on; the others need a service set up first, so they start off.
  readonly property bool radioEnabled: root.setting("radio", true) === true
  readonly property bool spotifyEnabled: root.setting("spotify", false) === true
  readonly property bool appleEnabled: root.setting("appleMusic", false) === true
  readonly property bool sxmEnabled: root.setting("siriusXM", false) === true
  readonly property bool appleConfigured: appleEnabled && appleBridge !== "" && appleStream !== ""
  // Switched on, or set up (the installer writes apple.json, then switches
  // Apple Music on): read the files again, and see how the bridge is doing.
  onAppleEnabledChanged: if (root.appleEnabled) root.rereadConfig()
  onAppleConfiguredChanged: if (root.appleConfigured) apple.checkHealth()
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
  // The service the rows on screen come from: the one playing, or the one
  // a lookup is in.
  readonly property var browseBridge: lookupService === "apple" ? apple : lookupService === "spotify" ? spotify : bridge
  readonly property bool browseBridgeMode: lookupService !== "" || bridgeMode
  readonly property string radioBrowser: root.setting("radioBrowser", "")
  // The station to come back to when switching to the radio.
  property string lastStation: ""
  // The source playing, and the ones set up: m goes round them. The modes
  // above all follow from it, so they never disagree, even for a moment (the
  // list took a mode caught halfway through a change for another list).
  readonly property string source: spotifyMode ? "spotify" : mpdOnApple ? "apple" : mpdOnSxm ? "sxm" : mpdOnRadio ? "radio" : "local"
  // A source switched on shows even when its service can't be reached:
  // switching to it then says why, which helps while setting it up.
  // A live station's song or artist looked up in Apple Music or Spotify
  // ("apple" or "spotify", else ""): the search, and what it opens, use that
  // service while the station plays on. Playing a result switches to it.
  property string lookupService: ""
  // Where the lookup goes: the lookup setting's pick, or the other one when
  // that's switched off.
  readonly property string lookupTarget: {
    var apple = root.appleConfigured ? "apple" : ""
    var spotify = root.spotifyEnabled ? "spotify" : ""
    return root.setting("lookup", "Apple Music") === "Spotify" ? spotify || apple : apple || spotify
  }
  // Time Machine (TimeMachine.js), when it's switched on in the settings: a
  // year picked at the top (t). Then search, artists, albums, genres,
  // playlists, Shuffle and the random song leave out music from after it,
  // on every source but the live ones, and Top 100 (T) has Billboard's
  // year-end chart for it, played on Apple Music or Spotify. Songs from
  // after it come out of the queue (keepQueueInYear). The year is kept in
  // settings.json (timeMachineYear).
  readonly property bool timeMachineEnabled: root.setting("timeMachine", false) === true
  readonly property int timeYear: {
    if (!root.timeMachineEnabled) return 0
    var year = parseInt(root.setting("timeMachineYear", 0), 10) || 0
    return year >= TimeMachine.firstYear() && year <= new Date().getFullYear() ? year : 0
  }
  // A live station's song looked up keeps every year: it's what's on.
  property bool lookupLive: false
  readonly property int listYear: root.lookupLive ? 0 : root.timeYear
  // Where Top 100 plays: the service playing, else the lookup's.
  readonly property string chartService: root.bridgeMode ? root.bridge.serviceKey : root.lookupTarget
  // History (H): what's been played here, from every source, for the last
  // historyDays (History.js). historyAfter, in the file only, is a test's:
  // a play counts after that many seconds.
  readonly property bool historyEnabled: root.setting("history", true) === true
  readonly property int historyDays: Math.max(1, Math.min(90, parseInt(root.setting("historyDays", 7), 10) || 7))
  readonly property int historyAfter: parseInt(root.setting("historyAfter", 0), 10) || 0
  property bool yearPickerOpen: false
  // What's listed belongs to the year it was listed for.
  onTimeYearChanged: root.clearSearch()
  // The years of the queue's songs (0 where there's none), for the year
  // picker's warning.
  readonly property var queueYears: root.bridgeMode ? root.bridge.queue.map(TimeMachine.yearOf)
    : client.queue.map(function(song) { return parseInt(Mpd.songYear(song), 10) || 0 })
  readonly property var sources: ["local"].concat(appleEnabled ? ["apple"] : []).concat(spotifyEnabled ? ["spotify"] : [])
    .concat(sxmEnabled ? ["sxm"] : []).concat(radioEnabled ? ["radio"] : [])
  readonly property var sourceNames: ({ local: "local music", apple: "Apple Music", spotify: "Spotify", sxm: "SiriusXM", radio: "the radio" })
  // Anything listed belongs to the source it came from.
  onSourceChanged: {
    root.triedSource = ""
    root.pickerItem = null
    root.clearSearch()
    root.recheckQueue()
    // A song of yours from History, once local music is back.
    if (root.source === "local" && root.historyPending !== "") {
      var file = root.historyPending
      root.historyPending = ""
      Qt.callLater(function() { client.queueFiles([file], "play") })
    }
  }
  // The channel to come back to when switching to SiriusXM.
  property string lastChannel: ""
  // What the player card, the transport keys and the bar follow.
  readonly property var player: bridgeMode ? bridge : sxmMode ? sxm : radioMode ? radio : client
  // Live sources: no seeking, shuffle or repeat; a pause is a stop.
  readonly property bool live: sxmMode || radioMode
  // Under the album in the player card: the genre, and Explicit, Lossless or
  // Dolby Atmos.
  // Under the song in the player card: Explicit, Lossless, Dolby Atmos (the
  // genre has a line of its own).
  readonly property string bridgeExtra: bridge.elsewhere !== "" ? "Playing on " + bridge.elsewhere + " · Play moves it here"
    : bridge.song ? Apple.badges(bridge.song) : ""
  // Under the station in the player card: where it is, its genres and sound.
  readonly property string radioExtra: radio.station ? Radio.describe(radio.station) : ""
  // Under the channel in the player card: the show, else the genre.
  readonly property string sxmExtra: sxm.now && sxm.now.show ? sxm.now.show : sxm.channel ? sxm.channel.genre : ""
  // The local song Apple Music interrupted, { id, elapsed }, to resume it.
  property var localResume: null
  property string lastMpdState: ""
  // Matches manifest.json (tests/mpd.test.js checks). Logged on load and shown
  // in the key list, to tell which code the shell is running.
  readonly property string version: "0.11.3"

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
  readonly property alias yearPicker: yearPicker

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
  property var confirmTarget: null
  // The info card (i) while it's open: { card (Info.js), coverFile, logo,
  // coverUrl, loading }.
  property var infoCard: null
  // The settings view (the gear, or ,). The settings live in omarock's own
  // file, ~/.config/omarock/settings.json (Settings.js says what each is);
  // one not in it falls back to the widget's entry in Omarchy's shell.json.
  property bool settingsOpen: false
  readonly property string configDir: Quickshell.env("HOME") + "/.config/omarock"
  property var fileSettings: ({})
  // Omarchy's Panel reads the widget's entry only: omarock's file comes first.
  function setting(name, fallback) {
    return Settings.value(root.fileSettings, root.settings, name, fallback)
  }
  // The rows the settings screen shows, as each piece is set up or not.
  readonly property var settingsSchema: Settings.shown(root.settingStates)
  // What's set up here (tools/omarock-sources state): each piece, and the
  // last ./install run. Read at start, when the settings open, after a
  // switch, and while a setup this panel started is running.
  property var sourcesState: null
  readonly property string sourcesTool: decodeURIComponent(String(Qt.resolvedUrl("tools/omarock-sources")).replace(/^file:\/\//, ""))
  readonly property string installPath: decodeURIComponent(String(Qt.resolvedUrl("install")).replace(/^file:\/\//, ""))
  // Each piece as the settings show it (Settings.shown): set up or not, an
  // update waiting, and what's wrong while it's switched on. Until
  // omarock-sources answers, a source switched on counts as set up.
  readonly property var settingStates: {
    var s = root.sourcesState || {}
    var sp = s.spotify, xm = s.siriusxm, am = s["apple-music"], so = s.sound
    var days = sp ? sp.soloistDays : -1
    var soloist = spotify.health.soloist || {}
    return {
      local: { setUp: client.ready },
      spotify: {
        setUp: sp ? sp.setUp : root.spotifyEnabled,
        update: !sp || !sp.setUp ? false
          : days >= 80 ? "Soloist, Spotify's player, stops working " + (days >= 90 ? "now: its build is " + days + " days old" : "in " + (90 - days) + " days")
          : !sp.upToDate,
        signedIn: !!spotify.health.web && spotify.health.web.signedIn === true,
        attention: !root.spotifyEnabled || !spotify.healthKnown ? ""
          : !spotify.reachable ? "Can't reach omarock-spotify"
          : soloist.loggedIn === false ? "Soloist isn't signed in to your account" : ""
      },
      sxm: {
        setUp: xm ? xm.setUp : root.sxmEnabled,
        update: !!xm && xm.setUp && !xm.upToDate,
        attention: !root.sxmEnabled || !sxm.healthKnown ? ""
          : !sxm.available || sxm.lastError !== "" ? (sxm.lastError || "Can't reach omarock-sxm") : ""
      },
      apple: {
        setUp: am ? am.setUp : root.appleEnabled,
        update: false,
        attention: !root.appleEnabled ? ""
          : !root.appleConfigured ? "The bridge's address isn't set"
          : !apple.healthKnown ? ""
          : !apple.reachable ? "Can't reach the bridge at " + root.appleBridge
          : !apple.healthAuthorized ? "The bridge can't use Apple Music yet" : ""
      },
      sound: { setUp: !!so && so.setUp, update: !!so && so.setUp && !so.upToDate, attention: "" }
    }
  }
  // Accounts and keys as tools/omarock-account shows them: names, and
  // whether each secret is set, never a secret.
  property var accounts: ({})
  readonly property var settingValues: {
    var out = {}
    root.settingsSchema.forEach(function(f) {
      if (Settings.stored(f)) out[f.key] = root.setting(f.key)
      else if (f.type === "folder") out[f.key] = client.musicDirectory.replace(Quickshell.env("HOME"), "~")
      else if (f.type === "account" || f.type === "secret") out[f.key] = root.accounts[f.key]
    })
    return out
  }
  // What an empty text setting means.
  readonly property var settingPlaceholders: ({
    radioArea: "none: no local stations"
  })
  // Under each source: a setup running in a terminal (or one that didn't
  // finish), else off, else what's wrong, else how it's doing.
  readonly property var settingNotes: {
    function note(text, kind) { return { text: text, kind: kind || "" } }
    var states = root.settingStates
    var flow = root.sourcesState ? root.sourcesState.flow : null
    function flowNote(piece, setUp) {
      if (!flow || flow.piece !== piece) return null
      if (flow.result === "running") return note(flow.action === "remove" ? "Being removed, in a terminal…" : "Being set up, in a terminal…")
      if (flow.action === "setup" && !setUp && (flow.result === "failed" || flow.result === "stopped"))
        return note("Its setup didn't finish. Set up carries on where it stopped.", "bad")
      return null
    }
    // flowNote, else for one set up: off, what's wrong, else how it's doing.
    function sourceNote(piece, state, on, off, fine) {
      return flowNote(piece, state.setUp) || (!state.setUp ? note("")
        : !on ? note(off) : state.attention !== "" ? note(state.attention, "bad") : fine)
    }
    var output = root.sourcesState && root.sourcesState.sound ? root.sourcesState.sound.output : ""
    return {
      localSetUp: flowNote("local", states.local.setUp) || note(""),
      radio: !root.radioEnabled ? note("Off")
        : radio.area ? note("Local stations " + (radio.area.kind === "city" ? "near " : "from ") + radio.area.name, "ok")
        : note("No area set (below): no local stations"),
      // Where the area was found, or why not.
      radioArea: radio.areaState === "finding" ? note("Finding it…")
        : radio.areaState === "unknown" ? note("No city, region or country called " + radio.areaText.trim()
          + " here. A city of 15,000 people or more, or your state, region or country.", "bad")
        : radio.areaState === "found" ? note(radio.areaLabel + (radio.localSearching ? " · looking for stations…"
          : radio.localMade > 0 ? " · " + root.countText(radio.local.length, "station") : ""), "ok")
        : note(""),
      spotify: sourceNote("spotify", states.spotify, root.spotifyEnabled,
        "Off: its services are stopped. Your accounts and keys are kept.",
        !spotify.healthKnown ? note("Checking…")
          : spotify.healthAuthorized ? note("Runs, and is signed in", "ok")
          : note("Not signed in for search and your library: Sign in, below", "bad")),
      siriusXM: sourceNote("siriusxm", states.sxm, root.sxmEnabled,
        "Off: omarock-sxm is stopped. Your login is kept.",
        !sxm.healthKnown ? note("Checking…") : note("omarock-sxm runs, and is signed in", "ok")),
      appleMusic: sourceNote("apple-music", states.apple, root.appleEnabled,
        "Off: it's gone from the panel. The bridge's address and token are kept.",
        !apple.healthKnown ? note("Checking…") : note("The bridge at " + root.appleBridge + " answers", "ok")),
      sound: sourceNote("sound", states.sound, true, "",
        note(output !== "" ? "Plays only into " + client.outputDescription(output) : "Plays only into the output it was set up with", "ok")),
      spotifyLogin: !root.spotifyEnabled ? note("")
        : !spotify.reachable ? note("omarock-spotify isn't running", "bad")
        : !states.spotify.signedIn ? note("Not signed in yet", "bad")
        : spotify.health.web.signInEndsAt ? note("Until " + new Date(spotify.health.web.signInEndsAt * 1000)
          .toLocaleDateString(Qt.locale(), "MMMM d, yyyy") + ", when Spotify asks again", "ok")
        : note("Signed in", "ok"),
      musicFolder: note(client.musicDirectory === "" ? "mpd doesn't say: it tells only clients on its unix socket" : "")
    }
  }
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
  readonly property bool confirmOpen: confirmTarget !== null
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

  // "Playing · song 3 of 12" (playStateWord, then queuePlace); stateText
  // adds "Apple Music · " in Apple Music mode, except under the header, where
  // the switch beside it says so. The compact header leaves out the song.
  readonly property string playStateWord: {
    if (!client.ready) return "Not connected"
    if (root.bridgeMode && !root.bridge.ready) return "Not connected"
    if (root.sxmMode && !sxm.available) return "SiriusXM isn't running"
    var s = root.player.status
    return s.state === "play" ? "Playing" : s.state === "pause" ? "Paused" : "Stopped"
  }
  readonly property string queuePlace: {
    if (!client.ready || (root.bridgeMode && !root.bridge.ready) || (root.sxmMode && !sxm.available)) return ""
    var s = root.player.status
    return s.song >= 0 && s.queueLength > 0 ? " · song " + (s.song + 1) + " of " + s.queueLength : ""
  }
  readonly property string playStateText: root.playStateWord + root.queuePlace
  readonly property string sourcePrefix: root.bridgeMode ? root.bridge.service + " · " : root.sxmMode ? "SiriusXM · "
    : root.radioMode ? "Radio · " : ""
  readonly property string stateText: root.sourcePrefix + root.playStateText

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
  // Typing in the search box, where letters are text, not keys.
  readonly property bool typing: !!root.searchField && root.searchField.activeFocus

  // What Enter (→ out of the search box) does on a row of a kind, for the
  // hints; null where it does nothing.
  function enterHint(kind, typing) {
    var hint = Hints.hint
    if (root.opens(kind)) return typing ? hint("Enter", "open", "Open it", true) : hint("→", "open", "Open it (or Enter)", true)
    if (kind === "channel" || kind === "station") return hint("Enter", "tune", "Tune it", true)
    if (kind === "track") return hint("Enter", "play from here", "Play from this song", true)
    if (kind === "playtop") return hint("Enter", "play them all", "Play the chart's songs, from the top", true)
    if (kind === "shuffletop") return hint("Enter", "shuffle them", "Play the chart's songs in an order of their own", true)
    if (kind === "chartmiss") return null
    if (kind === "historylookup") return hint("Enter", "look it up", "Find it in Apple Music or Spotify (a station's song)", true)
    if (kind === "shuffleall") return hint("Enter", "shuffle all", "Shuffle all the songs", true)
    if (kind === "savequeue") return hint("Enter", "save the queue", "Save the queue as a playlist", true)
    return kind !== "note" && kind !== "" ? hint("Enter", "play", "Play it", true) : null
  }

  // The keys that do something here (Hints.js): the line under the list
  // shows what fits, the most useful first, and the keys page all of them.
  readonly property var hintParts: {
    var hint = Hints.hint
    if (root.cardFocus !== "") {
      var enter = root.cardHint()
      var line = (root.cardPosition() || { row: -1 }).row
      return (enter ? [enter] : []).concat([
        hint((root.cardLinks[line] || []).length > 1 ? "↑↓←→" : "↑↓", "move", "Between the song's links; ↓ from the last goes back to the list"),
        hint("Esc", "to the list", "Back to the list", true),
        hint("i", "info", "Everything known about the song playing"), hint("?", "keys", "", true)])
    }
    var parts = root.listHintParts()
    // At the top of the list, ↑ goes up to the song playing.
    if (!root.typing && root.cursorActive && root.cursorIndex === 0 && root.cardLinks.length > 0)
      parts.splice(Math.max(0, parts.length - 1), 0, hint("↑", "now playing", "Up to the song playing: its artist, album and the rest"))
    return parts
  }

  function listHintParts() {
    var row = root.enterRow
    var kind = row ? row.kind : ""
    var hint = Hints.hint
    var next = root.sourceNames[root.nextSource()]
    var source = root.sources.length < 2 ? [] : [hint("m", next, "Switch to " + next)]
    var info = hint("i", "info", "Everything known about it")
    var keys = hint("?", "keys", "", true)
    var library = root.libraryHint(root.browsing ? root.browseTop : null, row)
    // Time Machine: its year's Top 100, else picking a year.
    var time = root.timeYear > 0 ? [hint("T", TimeMachine.chartName(root.timeYear).toLowerCase(),
        "Billboard's " + TimeMachine.chartName(root.timeYear) + " of " + root.timeYear)]
      : root.timeMachineEnabled ? [hint("t", "time machine", "Time Machine: pick a year")] : []
    var parts = []
    // In the search box: what the box does with Enter, ↓ and Esc.
    if (root.typing) {
      var top = root.searchMode ? root.rows[root.cursorActive ? root.cursorIndex : 0] : null
      var enter = top ? root.enterHint(top.kind, true) : null
      if (enter) parts.push(enter)
      if (top && root.rowQueues(top)) parts.push(hint("Shift+Enter", "add to queue", "Add it to the end of the queue"))
      if (root.query === "" && !root.browsing) return parts.concat([hint("Esc", "to the list", "Leave the search box for the list", true)])
      if (root.rows.length > 0) parts.push(hint("↓", "to the list", "Down to the list, where the other keys work", true))
      return parts.concat([root.browsing ? hint("Esc", "back", "Back a level", true) : hint("Esc", "clear", "Clear the search", true)])
    }
    if (!root.searchMode && !root.browsing && (root.sxmMode || root.radioMode)) {
      var steps = root.sxmMode ? hint("n p", "channel", "Next or previous channel") : hint("n p", "favourite", "Next or previous favourite")
      parts = root.cursorActive && row
        ? [hint("Enter", "tune", "Tune it", true), hint("A", row.favorite ? "unfavourite" : "favourite",
          row.favorite ? "Take it out of your favourites" : "Add it to your favourites"), info, steps]
        : [hint("Space", "play/stop", "Play or stop", true),
          hint("/", root.sxmMode ? "find a channel" : "find a station", root.sxmMode ? "Search the channels" : "Search for a station"), steps]
      return parts.concat(root.cursorActive && row ? [] : time, source, [hint("H", "history", "What you've played here")], [keys])
    }
    if (!root.searchMode && !root.browsing) {
      if (!root.cursorActive || !row)
        return [hint("Space", "play/pause", "Play or pause", true), hint("/", "search", "Search"),
          hint("P", "playlists", "Your playlists")].concat(time, source, [hint("H", "history", "What you've played here"), keys])
      parts = [hint("Enter", "play", "Play from this song", true), hint("A", "add to playlist", "Add the song to a playlist")]
      if (!root.bridgeMode || root.bridge.canRemove) parts.push(hint("x", "remove", "Take the song out of the queue"))
      parts.push(info)
      if (library !== "") parts.push(hint("L", library))
      return parts.concat([hint("P", "playlists", "Your playlists"), keys])
    }
    var main = root.enterHint(kind, false)
    if (main) parts.push(main)
    if (root.rowQueues(row)) parts.push(hint("a", "add to queue", "Add it to the end of the queue"))
    if (root.playlistItem(root.browseTop, row)) parts.push(hint("A", "add to playlist", "Add it to a playlist"))
    if (kind === "channel" || kind === "station")
      parts.push(hint("A", row.favorite ? "unfavourite" : "favourite", row.favorite ? "Take it out of your favourites" : "Add it to your favourites"))
    if (row && row.removable)
      parts.push(kind === "playlist" ? hint("x", "delete", "Delete the playlist (asks first)") : hint("x", "remove", "Take it out of the playlist"))
    if (root.infoRequest(root.browseTop, row)) parts.push(info)
    if (library !== "") parts.push(hint("L", library))
    parts.push(root.browsing ? hint("←", "back", "Back a level", true) : hint("Esc", "clear", "Clear the search", true), keys)
    return parts
  }

  // The keys page's RIGHT NOW: the same keys, ? aside (it's open).
  readonly property var hereKeys: Hints.rows(root.hintParts.filter(function(part) { return part.key !== "?" }))

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
    // While the Mac plays for another machine, this one's mpd stopping
    // (leaveStream) leaves it playing, and mpd playing takes it over.
    if (!root.mpdOnApple || state === was || String(client.currentSong.id) !== String(client.status.songId)) return
    var mine = apple.elsewhere === ""
    if (state === "pause") {
      client.send("stop")
      if (apple.bridgeStatus.state === "playing" && mine) apple.pause()
    } else if (state === "stop" && was === "play") {
      if (apple.bridgeStatus.state === "playing" && mine) apple.pause()
    } else if (state === "play" && (apple.bridgeStatus.state === "paused" || !mine)) {
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

  // The pointer left the card: close 3 s later, unless it comes back.
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

  Component.onCompleted: {
    console.info("omarock " + root.version + " loaded")
    root.readSources()
  }
  // Which panel keeps the queue to Time Machine's year (Keeper.js).
  readonly property string keeperId: Math.random().toString(36).slice(2)
  Component.onDestruction: Keeper.release(root.keeperId)

  onOpenedChanged: {
    client.ticking = root.opened
    apple.ticking = root.opened
    spotify.ticking = root.opened
    if (root.opened && root.spotifyEnabled) spotify.checkHealth()
    sxm.watching = root.opened && root.sxmEnabled
    if (root.opened && root.sxmEnabled) sxm.checkHealth()
    radio.watching = root.opened
    if (root.opened && root.radioMode) radio.refreshLocal(false)
    if (root.opened && root.appleConfigured && !root.appleMode) apple.checkHealth()
    // Apple's genres need the catalog; fetch them again if they didn't come before.
    if (root.opened && root.appleMode && apple.genres.length === 0) apple.refreshGenres()
    root.cardResized()
    // Closing keeps it all as it was: the search, where you'd browsed to,
    // the cursor, the picker, the info card, Keys and settings, and where
    // the keys went (returnFocus). Only a delete's confirmation doesn't
    // wait, and a setting being typed is dropped, not saved half typed.
    if (root.opened) {
      root.rereadConfig()
      client.forgetMissingCovers()
      root.coverDirectory = ""
      root.updateCover()
      client.refreshStatus()
      if (!root.cursorActive) Qt.callLater(root.showCurrentSong)
    } else {
      // The keys leave a moment later, so the search box still has them.
      root.searchFocused = !!root.searchField && root.searchField.activeFocus
      root.confirmTarget = null
      settingsView.cancelEdit()
    }
  }

  // Whether the search box had the keys when the panel closed.
  property bool searchFocused: false

  // The panel opening gives the keys back to where they were.
  function returnFocus() {
    if (root.yearPickerOpen) yearPicker.takeFocus()
    else if (root.pickerOpen) playlistPicker.takeFocus()
    else if (root.searchFocused && root.searchField) root.searchField.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
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
    root.lookupService = ""
    root.lookupFocus = ""
    root.lookupLive = false
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
    if (root.browseBridgeMode) {
      var bridge = root.browseBridge
      bridge.search(query, function(results, error) {
        if (sequence !== root.searchSequence) return
        results = TimeMachine.filterResults(results, root.listYear)
        root.resultRows = results ? Apple.searchRows(results, Apple.matchGenres(bridge.genres, query, Mpd.fold), bridge.service) : []
        root.searching = false
        if (!results) root.say(error)
        // A lookup's results start on the first song, or artist, found.
        var first = root.resultRows.findIndex(function(row) { return row.kind === root.lookupFocus })
        if (first >= 0) {
          root.cursorActive = true
          root.cursorIndex = first
        }
        root.lookupFocus = ""
      })
      return
    }
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
    // Albums are known by name here, so their covers are looked up as the
    // rows come into view, as a genre's are.
    results.albums.forEach(function(album, i) {
      rows.push({ kind: "album", section: i === 0 ? "ALBUMS" : "", lead: "󰀥",
        title: album.album, subtitle: root.albumSubtitle(album, false),
        artist: album.albumartist, album: album.album, cover: { album: album.album, artist: album.albumartist } })
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
      || kind === "historylist"
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

  // The rows at the top of a level that stand for all of it (Play the album,
  // Shuffle all songs, Save the queue as a playlist): its heading shows them
  // as buttons, and the list leaves them out. The cursor still goes up onto
  // them from the first song, so Enter, a and A act on the whole of it there.
  readonly property var buttonKinds: ["playalbum", "playplaylist", "playall", "shuffleall", "playtop", "shuffletop", "savequeue",
    "historylist"]

  function buttonRows(rows) {
    var count = 0
    while (rows && count < rows.length && root.buttonKinds.indexOf(rows[count].kind) >= 0) count++
    return count
  }

  // A column's heading buttons: one for each of those rows, then Add to queue
  // and Add to playlist for the first. Each is { index, mode, icon, label, tip },
  // the tip ending with the key that does the same with the cursor on them.
  function levelButtons(role) {
    if (role === "") return []
    var level = root.columnLevel(role)
    var rows = level.rows || []
    var count = root.buttonRows(rows)
    var buttons = []
    // about: what the first stands for, beside them ("12 songs · 48:10"). A
    // playlist's heading says it already.
    for (var i = 0; i < count; i++)
      buttons.push({ index: i, mode: "play", icon: rows[i].lead, label: root.buttonLabel(rows[i]),
        tip: root.buttonTip(rows[i]) + " (Enter)",
        about: rows[i].kind === "playplaylist" || rows[i].kind === "historylist" ? "" : rows[i].subtitle || "" })
    if (count > 0 && root.rowQueues(rows[0]))
      buttons.push({ index: 0, mode: "add", icon: "󰐕", label: "Add to queue", tip: "Add its songs to the end of the queue (a)" })
    if (count > 0 && root.playlistItem(level.entry, rows[0]))
      buttons.push({ index: 0, mode: "playlist", icon: "󰐒", label: "Add to playlist", tip: "Add its songs to a playlist, or to a new one (A)" })
    return buttons
  }

  function buttonLabel(row) {
    if (row.kind === "savequeue") return "Save the queue as a playlist"
    if (row.kind === "historylist") return "History"
    if (row.kind === "shuffleall" || row.kind === "shuffletop") return "Shuffle"
    if (row.kind === "playall") return row.title
    return "Play"
  }

  function buttonTip(row) {
    if (row.kind === "savequeue") return "Save the songs in the queue as a playlist"
    if (row.kind === "historylist") return "What you've played here lately, from every source (also H)"
    var what = row.kind === "playalbum" ? "the album" : row.kind === "playplaylist" ? "the playlist"
      : row.kind === "shuffleall" ? "the genre's songs, shuffled,"
      : row.kind === "playtop" ? "the chart's songs" : row.kind === "shuffletop" ? "the chart's songs, shuffled,"
      : row.items ? "their top songs" : "all their songs"
    return "Replace the queue with " + what + " and play " + (row.kind === "playalbum" || row.kind === "playplaylist" ? "it" : "them")
  }

  function makeEntry(row, index) {
    if (row.kind === "historylist")
      return { kind: "history", title: "History", artist: "", album: "", genre: "", playlist: "", from: index,
        rows: [], info: ({}), files: [], loaded: false }
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

  // Time Machine's year: t, or its button at the top. Switched off in the
  // settings, it isn't there.
  function openYearPicker() {
    if (!root.timeMachineEnabled) {
      root.say("Time Machine is off: switch it on in the settings (,)")
      return
    }
    root.keysOpen = false
    root.pickerItem = null
    root.yearPickerOpen = true
  }

  function closeYearPicker() {
    root.yearPickerOpen = false
    keyCatcher.forceActiveFocus()
  }

  // A year (0: off), kept in settings.json. The queue's songs from after it
  // come out of it, as the picker warned.
  function pickYear(year) {
    root.closeYearPicker()
    if (year === root.timeYear) return
    root.saveSetting("timeMachineYear", year)
    root.say(year > 0 ? "Time Machine: " + year + ". Only music from then or before; "
      + TimeMachine.chartName(year) + " (T) has its chart" : "Time Machine is off: all your music again")
    if (year > 0) root.keepQueueInYear(true)
  }

  // Time Machine keeps the queue to its year: songs from after it come out
  // of mpd's queue and Apple Music's; Spotify's can't be changed, so a song
  // from after it playing there is skipped. Done when a year is picked, and
  // again as the queue or the source changes (queueKeeper), so a song added
  // later (from mpc, or a phone) goes too. Songs without a year stay.
  // announce: say what went.
  function keepQueueInYear(announce) {
    var year = root.timeYear
    // One panel does it, of the one on each bar.
    if (year === 0 || !Keeper.claim(root.keeperId)) return
    // Nothing extra goes to mpd while a stream starts (MpdClient.playStream).
    if (client.streamTuning !== "") {
      queueKeeper.restart()
      return
    }
    // mpd keeps its song while another source plays: it waits on it paused.
    client.removeAfterYear(year, root.source !== "local", function(count) {
      if (announce && count > 0) root.say("Time Machine: " + year + ". " + root.countText(count, "song")
        + " from after it came out of the queue")
    })
    if (root.bridgeMode) root.keepBridgeInYear(root.bridge, year, announce)
  }

  // Apple Music's or Spotify's queue (the window its status lists): a song
  // from after the year playing jumps to the next one up to it (or pauses,
  // with none), then the later ones come out, the last first so the others
  // keep their places. Not while it plays for another machine. The year's
  // Top 100 stays, whatever year the versions found say (ChartClient.songIds).
  property bool bridgeKeeping: false
  function keepBridgeInYear(bridge, year, announce) {
    if (root.bridgeKeeping || bridge.elsewhere !== "") return
    root.bridgeKeeping = true
    charts.songIds(bridge.serviceKey, year, function(chartSongs) {
      root.bridgeKeeping = false
      if (bridge.elsewhere === "" && root.timeYear === year) root.trimBridge(bridge, year, announce, chartSongs)
    })
  }

  function trimBridge(bridge, year, announce, chartSongs) {
    var status = bridge.bridgeStatus
    var queue = status.queue || []
    var offset = status.queueOffset || 0
    var current = status.queueIndex
    function later(song) { return TimeMachine.yearOf(song) > year && !chartSongs[song.id] }
    var steps = []
    var going = []
    queue.forEach(function(song, i) { if (bridge.canRemove && later(song) && offset + i !== current) going.push(offset + i) })
    var playing = queue[current - offset]
    if (playing && later(playing) && status.state === "playing") {
      var next = -1
      for (var i = current - offset + 1; i < queue.length && next < 0; i++) if (!later(queue[i])) next = offset + i
      if (next >= 0) {
        steps.push(["/v1/queue/jump", { index: next }])
        if (bridge.canRemove) going.push(current)
      } else {
        steps.push(["/v1/pause", {}])
      }
    }
    going.sort(function(a, b) { return b - a }).forEach(function(index) { steps.push(["/v1/queue/remove", { index: index }]) })
    if (steps.length === 0) return
    root.bridgeKeeping = true
    function run(k) {
      if (k === steps.length) {
        root.bridgeKeeping = false
        if (announce && going.length > 0) root.say("Time Machine: " + year + ". " + root.countText(going.length, "song")
          + " from after it came out of " + bridge.service + "'s queue")
        else if (steps[0][0] === "/v1/pause") root.say("Nothing in " + bridge.service + "'s queue is from " + year + " or before")
        // What changed meanwhile (another device adding to the queue).
        root.recheckQueue()
        return
      }
      bridge.post(steps[k][0], steps[k][1], function(data, error) {
        if (error !== "") root.bridgeKeeping = false
        else run(k + 1)
      })
    }
    run(0)
  }

  // The queue changed (or the source did): Time Machine looks at it again,
  // once it settles.
  function recheckQueue() {
    if (root.timeYear > 0) queueKeeper.restart()
  }

  // T or the Top 100 button: Billboard's chart for Time Machine's year, from
  // the queue like Playlists, its songs found on chartService (as a lookup
  // finds a station's, which the level's rows then belong to).
  function openTop100() {
    if (root.timeYear === 0) {
      root.say(root.timeMachineEnabled ? "Pick a year first: t, or Time Machine at the top" : "Time Machine is off: switch it on in the settings (,)")
      return
    }
    if (root.browseRoot === "queue" && root.browseStack.length === 1 && root.browseTop.kind === "top100") return
    var service = root.chartService
    root.clearSearch()
    root.leaveSearch()
    root.lookupService = service
    root.browseRoot = "queue"
    var year = root.timeYear
    var entry = { kind: "top100", year: year, service: service, title: TimeMachine.chartName(year) + " of " + year,
      artist: "", album: "", genre: "", playlist: "", from: -1, rows: [], info: ({}), files: [], loaded: false }
    root.browseStack = [entry]
    root.loadBrowse(entry)
  }

  // The Top 100 level's rows, from the chart and what's been found so far.
  function showTop100(entry) {
    var target = entry.service === "apple" ? apple : entry.service === "spotify" ? spotify : null
    var key = target ? target.serviceKey : ""
    var state = target ? charts.stateOf(key, entry.year) : ({})
    var view = TimeMachine.chartView(entry.year, charts.chartOf(entry.year), target ? charts.foundFor(key, entry.year) : ({}),
      { service: target ? target.service : "", looking: !!state.looking, error: state.error || entry.error || "" }, Apple)
    entry.rows = view.rows
    entry.info = view.info
    entry.songItems = view.songItems
    entry.loaded = true
  }

  function loadTop100(entry, done) {
    var target = entry.service === "apple" ? apple : entry.service === "spotify" ? spotify : null
    charts.chart(entry.year, function(chart, error) {
      if (!chart) {
        entry.rows = []
        entry.info = { title: entry.title, subtitle: "Billboard's year-end chart", failed: true, emptyText: error + ". ← goes back." }
        entry.loaded = true
        done()
        return
      }
      root.showTop100(entry)
      done()
      if (!target) return
      if (target.ready) charts.findSongs(entry.year, target)
      else target.checkHealth(function(ok, healthError) {
        if (ok) charts.findSongs(entry.year, target)
        else {
          entry.error = healthError || "can't reach it"
          root.top100Changed()
        }
      })
    })
  }

  // A song found (or not): the level shows it, in place.
  function top100Changed() {
    var entry = root.browseTop
    if (!entry || entry.kind !== "top100" || !entry.loaded || entry.info.failed) return
    root.showTop100(entry)
    root.browseRows = entry.rows
    root.browseInfo = entry.info
  }

  // Its rows play on the service the songs were found on, which then
  // becomes the source; a song plays the chart from there, and Shuffle
  // plays it in an order of its own. The Mac can take ten seconds or more
  // to load a hundred songs, so the chart stays, saying so, until they play.
  property bool chartStarting: false
  function activateTop100(entry, row, index, mode) {
    if (root.chartStarting) {
      root.say("Still starting the " + entry.title + "…")
      return
    }
    if (row.kind === "chartmiss") {
      root.say(row.missing ? row.title + " isn't on " + root.browseBridge.service
        : entry.service === "" ? "Switch on Apple Music or Spotify in the settings to play the chart"
        : "Still looking for " + row.title + " on " + root.browseBridge.service)
      return
    }
    if (row.playable === false) {
      root.say(row.title + " isn't available to play")
      return
    }
    var items = entry.songItems || []
    if (items.length === 0) {
      root.say(entry.service === "" ? "Switch on Apple Music or Spotify in the settings to play the chart"
        : "None of the chart's songs have been found yet")
      return
    }
    var play = mode !== "add"
    var whole = row.kind === "playtop" || row.kind === "shuffletop"
    var bridge = root.browseBridge
    var service = entry.service
    if (row.kind === "shuffletop") items = TimeMachine.shuffled(items, Math.random)
    var what = whole ? entry.title + (row.kind === "shuffletop" ? ", shuffled," : "") : "the " + entry.title + " from " + row.title
    if (!play) {
      bridge.playItems(whole ? items : [row.apple], "add", 0, function(data, error) { if (error !== "") root.say(error) })
      root.say("Added " + (whole ? entry.title : row.title) + " to " + bridge.service + "'s queue")
      return
    }
    root.chartStarting = true
    root.say("Starting " + what + " on " + bridge.service + "…")
    bridge.playItems(items, "play", whole ? 0 : row.position, function(data, error) {
      root.chartStarting = false
      if (error !== "") {
        root.say(error)
        return
      }
      if (root.browseTop === entry) {
        root.clearSearch()
        root.leaveSearch()
      }
      if (service !== "") root.setSource(service)
      root.say("Playing " + what + " on " + bridge.service)
    })
  }

  // ---------- History (H): what's been played here (History.js) ----------

  // What's playing, as History.entryFor takes it.
  function historyNow() {
    if (root.bridgeMode) {
      var item = root.bridge.bridgeStatus.song
      if (!item) return null
      return { title: item.title, artist: item.artist, album: item.album, duration: item.duration,
        ref: { kind: "song", id: item.id, source: item.source || "catalog" } }
    }
    var song = root.player.currentSong || ({})
    if (root.sxmMode)
      return { title: song.title, artist: song.artist, station: sxm.channel ? sxm.channel.name : root.songAlbum,
        isAd: !!(sxm.now && sxm.now.isAd) }
    if (root.radioMode) return { title: song.title, artist: song.artist, station: song.album }
    return { title: root.songTitle, artist: root.songArtist, album: root.songAlbum, file: song.file,
      duration: parseFloat(song.duration || song.time || 0) }
  }

  // The song playing, and how long it's been heard here: once that's long
  // enough (History.counts), it's added. Only one panel adds (Keeper.js).
  property var historyHeard: ({ key: "", seconds: 0, added: false })
  function tickHistory(seconds) {
    if (!Keeper.claim(root.keeperId, "history")) return
    var entry = History.entryFor(root.source, root.historyNow())
    var key = History.keyOf(entry)
    var heard = root.historyHeard
    if (key !== heard.key) heard = root.historyHeard = { key: key, seconds: 0, added: false }
    if (!entry || heard.added) return
    heard.seconds += seconds
    if (!History.counts(heard.seconds, entry.duration || 0, root.live, root.historyAfter)) return
    heard.added = true
    entry.at = Date.now()
    history.add(entry)
  }

  // H, or History at the top of Playlists: opened from the queue, as
  // Playlists is, on any source.
  function openHistory() {
    if (root.browseRoot === "queue" && root.browseStack.length === 1 && root.browseTop.kind === "history") return
    root.clearSearch()
    root.leaveSearch()
    root.browseRoot = "queue"
    var entry = root.makeEntry({ kind: "historylist" }, -1)
    root.browseStack = [entry]
    root.loadBrowse(entry)
  }

  function loadHistory(entry, done) {
    history.read(function(entries) {
      root.showHistory(entry, entries)
      done()
    })
  }

  function showHistory(entry, entries) {
    entry.rows = History.rows(entries, Date.now(), function(at) {
      return new Date(at).toLocaleTimeString(Qt.locale(), Locale.ShortFormat)
    })
    entry.info = History.info(entries, root.historyDays, root.historyEnabled)
    entry.files = []
    entry.loaded = true
  }

  // A play added, or the list cleared: History, if it's open, shows it.
  function historyChanged() {
    var entry = root.browseTop
    if (!entry || entry.kind !== "history" || !entry.loaded) return
    root.showHistory(entry, history.entries)
    root.browseRows = entry.rows
    root.browseInfo = entry.info
  }

  // History's own button at the top of Playlists, after Save the queue
  // (a button row: Panel.buttonKinds).
  function withHistoryRow(rows) {
    var at = 0
    while (at < rows.length && root.buttonKinds.indexOf(rows[at].kind) >= 0) at++
    var row = { kind: "historylist", lead: "󰋚", title: "History", noQueue: true,
      subtitle: root.historyEnabled ? "What you've played here in the last " + (root.historyDays === 1 ? "day" : root.historyDays + " days")
        : "Off: switch it on in the settings (,)" }
    return rows.slice(0, at).concat([row], rows.slice(at))
  }

  // A song from History plays where it was heard, when that's still there:
  // a song of yours from mpd, an Apple Music or Spotify song by its id (that
  // service then becomes the source, as Top 100's does). A station's song
  // can't be heard again from the station, so it's looked up in Apple Music
  // or Spotify, as the card's links do; so is a song from a service that's
  // off or can't be reached.
  property string historyPending: ""
  function activateHistory(row, mode) {
    var e = row.history
    if (!e) return
    if (mode === "open") mode = "play"
    if (e.source === "local") {
      if (mode === "add") {
        client.queueFiles([e.file], "add")
        root.say("Added " + e.title + " to the queue" + (root.source !== "local" ? " of your music" : ""))
        return
      }
      if (root.source === "local") {
        client.queueFiles([e.file], "play")
        root.clearSearch()
        root.leaveSearch()
      } else {
        // Once the switch has happened (it puts back what local music was
        // playing): onSourceChanged.
        root.historyPending = e.file
        historyPendingDrop.restart()
        root.setSource("local")
      }
      root.say("Playing " + e.title)
      return
    }
    var target = e.source === "apple" && root.appleEnabled ? apple : e.source === "spotify" && root.spotifyEnabled ? spotify : null
    if (target && e.ref && target.ready) {
      var service = e.source
      target.playItems([e.ref], mode === "add" ? "add" : "play", 0, function(data, error) {
        if (error !== "") root.say(error)
        else if (mode === "add") root.say("Added " + e.title + " to " + target.service + "'s queue")
        else {
          root.setSource(service)
          root.say("Playing " + e.title + " on " + target.service)
        }
      })
      return
    }
    if (mode === "add") {
      root.say(e.title + " was on " + (e.station || History.NAMES[e.source]) + ": Enter looks it up")
      return
    }
    root.lookUpSong(e.title, e.artist, "song")
  }

  // The playing song's album, artist or genre, as a level to open, or null:
  // Apple Music's and Spotify's songs name their album and artist by id, and
  // a genre opens Apple's charts when it's one of its top genres; local songs
  // go by their tags. Live stations have none.
  function playingEntry(kind) {
    if (root.live) return null
    if (root.bridgeMode) {
      var item = root.bridge.bridgeStatus.song
      if (!item) return null
      if (kind === "genre") {
        var key = Apple.foldKey((item.genres || [])[0])
        var genre = key === "" ? null : root.bridge.genres.find(function(g) { return Apple.foldKey(g.name) === key })
        return genre ? root.makeEntry({ kind: "genre", apple: { kind: "genre", id: genre.id, source: "catalog" },
          title: genre.name }, -1) : null
      }
      var ids = root.playingIds()
      var id = kind === "album" ? ids.albumId : ids.artistId
      if (!id) return null
      return root.makeEntry({ kind: kind, apple: { kind: kind, id: id, source: kind === "album" ? ids.albumSource : ids.artistSource },
        title: (kind === "album" ? item.album : item.artist) || "" }, -1)
    }
    var song = client.currentSong
    if (!song || !song.file) return null
    if (kind === "genre") return song.genre ? root.makeEntry({ kind: "genre", genre: song.genre }, -1) : null
    if (kind === "album")
      return song.album ? root.makeEntry({ kind: "album", album: song.album, artist: song.albumartist || song.artist || "" }, -1) : null
    var artist = Mpd.songArtist(song)
    return artist !== "" ? root.makeEntry({ kind: "artist", artist: artist }, -1) : null
  }

  // A live station's song, as it says it (SiriusXM's or a radio station's
  // title): something to look up. Not an ad, nor the station's own name.
  readonly property bool liveSong: root.live && !!root.player.currentSong.artist && !(root.sxmMode && sxm.now && sxm.now.isAd)
  // The kind of row a lookup's results should start on: "song" or "artist".
  property string lookupFocus: ""

  // A click on a live station's song or artist (or o and O): look it up in
  // Apple Music or Spotify (lookupTarget), while the station plays on.
  function lookUp(kind) {
    var song = root.player.currentSong
    if (!root.liveSong) {
      root.say("The station isn't saying what song this is")
      return
    }
    root.lookUpSong(song.title, song.artist, kind)
  }

  // A song (or its artist) looked up there: a station's, or one from History.
  function lookUpSong(title, artist, kind) {
    var service = root.lookupTarget
    if (service === "") {
      root.say("Switch on Apple Music or Spotify to look up the station's songs")
      return
    }
    var target = service === "apple" ? apple : spotify
    var text = kind === "artist" ? artist : title + " " + artist
    function go() {
      root.clearSearch()
      root.lookupService = service
      root.lookupFocus = kind
      root.lookupLive = true
      root.leaveSearch()
      if (root.searchField) root.searchField.text = text
      root.setQuery(text)
      root.say(target.service + ": " + (kind === "artist" ? artist : title) + ". Enter plays it there; Esc comes back")
    }
    if (target.ready) go()
    else target.checkHealth(function(ok, error) {
      if (ok) go()
      else root.say(error !== "" ? error : "Can't reach " + target.service)
    })
  }

  // The bridge's playing song's album and artist ids: from its status, else
  // from /v1/info (AppleClient.songLinks), each with the source it's from.
  function playingIds() {
    var item = root.bridge.bridgeStatus.song || ({})
    var asked = root.bridge.songLinks[Apple.songKey(item)] || ({})
    return { albumId: item.albumId || asked.albumId || "", albumSource: (item.albumId ? item.source : asked.source) || "catalog",
      artistId: item.artistId || asked.artistId || "", artistSource: (item.artistId ? item.source : asked.source) || "catalog" }
  }

  // Adds to (and Spotify's removals from) your library made here, by
  // libraryKey: true or false. The Mac's Music library gets an add through
  // iCloud a while later, so until the bridge knows, this says it's in.
  property var libraryEdits: ({})
  // The libraryKey of the item being added or removed, while it is.
  property string librarySaving: ""

  function libraryKey(service, item) {
    return service + ":" + item.kind + ":" + item.source + ":" + item.id
  }

  // Whether an Apple Music or Spotify item is in your library: "yes", "no",
  // or "" while nobody knows. known is what the service said, if it did.
  function inLibrary(service, item, known) {
    var edit = root.libraryEdits[root.libraryKey(service, item)]
    if (edit !== undefined) return edit ? "yes" : "no"
    if (known === true || (known === undefined && item.source === "library")) return "yes"
    return known === false ? "no" : ""
  }

  // The info card's answer, with what was added or removed here since. For
  // an album open in the list, what its heading says: all yours, or how
  // many of its songs are (songsInLibrary).
  function withLibraryEdit(service, item, extra) {
    var edit = root.libraryEdits[root.libraryKey(service, item)]
    var out = edit === undefined ? extra : Object.assign({}, extra, { inLibrary: edit, checking: false })
    var shown = item.kind === "album" ? root.shownAlbumLibrary(item) : null
    if (shown && service === "apple" && shown.state === "yes")
      out = Object.assign({}, out, { inLibrary: true, checking: false })
    else if (shown && shown.have > 0 && out.inLibrary !== true)
      out = Object.assign({}, out, { songsInLibrary: { have: shown.have, total: shown.total } })
    return out
  }

  // root.albumLibrary for this album, if it's the one open or previewed.
  function shownAlbumLibrary(item) {
    function same(entry) {
      return !!entry && !!entry.apple && entry.apple.kind === "album" && entry.apple.id === item.id && entry.apple.source === item.source
    }
    return same(root.browseTop) ? root.browseAlbumLibrary : same(root.previewEntry) ? root.previewAlbumLibrary : null
  }

  // The song playing on Apple Music or Spotify, as an item, and whether it's
  // in your library (its status says, else /v1/info: AppleClient.songLinks).
  readonly property var playingItem: {
    var song = root.bridgeMode ? root.bridge.bridgeStatus.song : null
    return song && song.id ? { kind: "song", id: song.id, source: song.source || "catalog", title: song.title || "This song" } : null
  }
  readonly property string playingLibrary: {
    var song = root.bridgeMode ? root.bridge.bridgeStatus.song : null
    if (!root.playingItem) return ""
    var asked = root.bridge.songLinks[Apple.songKey(song)] || ({})
    return root.inLibrary(root.bridge.serviceKey, root.playingItem, song.inLibrary !== undefined ? song.inLibrary : asked.inLibrary)
  }
  // The card's Add to library ("" hides it), and what it says under the
  // pointer when a click takes the song out again (Spotify).
  readonly property string playingLibraryText: {
    if (!root.playingItem) return ""
    if (root.librarySaving === root.libraryKey(root.bridge.serviceKey, root.playingItem))
      return root.playingLibrary === "yes" ? "Removing…" : "Adding…"
    return root.playingLibrary === "yes" ? "󰄬 In your library" : "󰐕 Add to library"
  }
  readonly property string playingLibraryHover: root.playingLibrary === "yes" && root.bridge.canUnsave ? "󰅖 Remove from library" : ""
  readonly property bool canAddPlayingToPlaylist: !root.live && root.player.ready && !!root.player.currentSong.file

  // The now playing card's links: the album, the artist and the genre open
  // (o, O, g), a live station's song and artist are looked up, then Add to
  // library and Add to playlist.
  readonly property bool cardTitleLink: root.liveSong && root.lookupTarget !== ""
  readonly property bool cardArtistLink: root.live ? root.cardTitleLink : root.playingEntry("artist") !== null
  readonly property bool cardAlbumLink: root.playingEntry("album") !== null
  readonly property bool cardGenreLink: root.playingEntry("genre") !== null
  // The same, as the keys reach them: ↑ from the top of the list goes up
  // into the card, ↑↓ go between its lines and ←→ along the last, Enter
  // acts, and ↓ from the last line or Esc goes back to the list. Rows top
  // to bottom; the Add links share the last.
  readonly property var cardLinks: {
    var rows = [["title", root.cardTitleLink], ["artist", root.cardArtistLink], ["album", root.cardAlbumLink],
      ["genre", root.cardGenreLink]].filter(function(r) { return r[1] }).map(function(r) { return [r[0]] })
    var add = []
    if (root.playingLibraryText !== "") add.push("library")
    if (root.canAddPlayingToPlaylist) add.push("playlist")
    return add.length > 0 ? rows.concat([add]) : rows
  }
  // The link with the keys ("" while they're in the list), and the list's
  // cursor to go back to (-1: it wasn't showing).
  property string cardFocus: ""
  property int cardReturn: -1
  // A link gone with the song: the nearest the list, or back to it.
  onCardLinksChanged: if (root.cardFocus !== "" && !root.cardPosition()) {
    var last = root.cardLinks[root.cardLinks.length - 1]
    if (last) root.cardFocus = last[0]
    else root.leaveCard(false)
  }
  onCursorActiveChanged: if (root.cursorActive) root.cardFocus = ""
  onTypingChanged: if (root.typing) root.cardFocus = ""

  function cardPosition() {
    for (var r = 0; r < root.cardLinks.length; r++) {
      var c = root.cardLinks[r].indexOf(root.cardFocus)
      if (c >= 0) return { row: r, column: c }
    }
    return null
  }

  // ↑ from the top of the list: the card's last line.
  function enterCard() {
    var links = root.cardLinks
    if (links.length === 0) return false
    root.cardReturn = root.cursorActive ? root.cursorIndex : -1
    root.cardFocus = links[links.length - 1][0]
    root.cursorActive = false
    return true
  }

  // Back to the list, where the cursor was. into (↓): the cursor shows
  // even if it wasn't.
  function leaveCard(into) {
    root.cardFocus = ""
    if (root.cardReturn >= 0 && root.rows.length > 0) {
      root.cursorIndex = Math.min(root.cardReturn, root.rows.length - 1)
      root.cursorActive = true
    } else if (into) root.moveCursor(1)
  }

  function moveInCard(dx, dy) {
    var at = root.cardPosition()
    if (!at) { root.leaveCard(false); return }
    var links = root.cardLinks
    if (dy !== 0) {
      var r = at.row + dy
      if (r >= links.length) root.leaveCard(true)
      else if (r >= 0) root.cardFocus = links[r][Math.min(at.column, links[r].length - 1)]
      return
    }
    var line = links[at.row]
    if (at.column + dx >= 0 && at.column + dx < line.length) root.cardFocus = line[at.column + dx]
  }

  // Enter on a link: what a click does. What opens has the keys.
  function activateCard() {
    var link = root.cardFocus
    if (link === "library") root.libraryPlaying()
    else if (link === "playlist") root.addPlayingToPlaylist()
    else {
      root.cardFocus = ""
      if (link === "title") root.lookUp("song")
      else root.openPlaying(link)
    }
  }

  // What Enter does on the link with the keys, for the hints.
  function cardHint() {
    var hint = Hints.hint
    var link = root.cardFocus
    var service = root.sourceNames[root.lookupTarget] || ""
    if (link === "title") return hint("Enter", "look it up", "Find the song in " + service + " (or o)", true)
    if (link === "artist") return root.live ? hint("Enter", "look it up", "Find the artist in " + service + " (or O)", true)
      : hint("Enter", "open the artist", "Open the artist playing (or O)", true)
    if (link === "album") return hint("Enter", "open the album", "Open the album playing (or o)", true)
    if (link === "genre") return hint("Enter", "open the genre", "Open the genre of the song playing (or g)", true)
    if (link === "library") return root.playingLibrary !== "yes" ? hint("Enter", "add to library", "Add the song to your library (or L)", true)
      : root.bridge.canUnsave ? hint("Enter", "remove from library", "Take the song out of your library (or L)", true) : null
    if (link === "playlist") return hint("Enter", "add to playlist", "Add the song to a playlist (or A)", true)
    return null
  }

  // L, or the card's Add to library: add the item to target's library, or
  // take it out again where the service can (Spotify). state is what
  // inLibrary says; after runs once it's done. A library item that isn't in
  // the library (only on a playlist added to it) is added as its catalog
  // copy, catalogId: the bridge adds catalog items only.
  function toggleLibrary(target, item, state, title, after, catalogId) {
    if (root.libraryKinds(target).indexOf(item.kind) < 0) {
      root.say("Your " + target.service + " library takes " + (target.serviceKey === "apple" ? "songs, albums and playlists" : "songs and albums"))
      return
    }
    if (state === "yes" && !target.canUnsave) {
      root.say(title + " is in your library already")
      return
    }
    var save = state !== "yes"
    var ref = { kind: item.kind, id: item.id, source: item.source }
    if (save && target.serviceKey === "apple" && item.source === "library" && item.kind !== "playlist") {
      if (!catalogId) {
        root.say(target.service + " has no copy of " + title + " to add to your library")
        return
      }
      ref = { kind: item.kind, id: catalogId, source: "catalog" }
    }
    var key = root.libraryKey(target.serviceKey, item)
    if (root.librarySaving === key) return
    root.librarySaving = key
    target.saveToLibrary([ref], save, function(error, reply) {
      if (root.librarySaving === key) root.librarySaving = ""
      if (error === "" && reply && reply.added === 0) error = target.service + " added nothing"
      if (error !== "") { root.say(error); return }
      var edits = Object.assign({}, root.libraryEdits)
      edits[key] = save
      root.libraryEdits = edits
      root.say(save ? "Added " + title + " to your " + target.service + " library"
        : "Took " + title + " out of your " + target.service + " library")
      if (after) after()
    })
  }

  function libraryPlaying() {
    var item = root.playingItem
    if (!item) {
      root.say("L adds the Apple Music or Spotify song playing to your library")
      return
    }
    var asked = root.bridge.songLinks[Apple.songKey(root.bridge.bridgeStatus.song)] || ({})
    root.toggleLibrary(root.bridge, item, root.playingLibrary, item.title, null, asked.catalogId)
  }

  function libraryKinds(target) {
    return target.serviceKey === "apple" ? ["song", "album", "playlist"] : ["song", "album"]
  }

  // L on a row: its song, album or playlist (a Play row stands for its level).
  function libraryItem(entry, row) {
    return row && (row.kind === "playalbum" || row.kind === "playplaylist") && entry && entry.apple ? entry.apple
      : row ? row.apple : null
  }

  // What L would do on a row, for the hints: "" where it does nothing.
  function libraryHint(entry, row) {
    var item = root.libraryItem(entry, row)
    var target = root.browseBridge
    if (!item || !root.browseBridgeMode || root.libraryKinds(target).indexOf(item.kind) < 0) return ""
    var album = entry && item === entry.apple && item.kind === "album" ? root.albumLibrary(entry, entry.rows) : null
    var state = album ? album.state : root.inLibrary(target.serviceKey, item, row.item ? row.item.inLibrary : undefined)
    return state !== "yes" ? "add to library" : target.canUnsave ? "remove from library" : ""
  }

  function libraryRow(entry, row) {
    var item = root.libraryItem(entry, row)
    if (!item || !root.browseBridgeMode) {
      root.say("L adds Apple Music and Spotify songs and albums to your library")
      return
    }
    if (entry && item === entry.apple && item.kind === "album") {
      root.libraryAlbum(entry, entry.rows)
      return
    }
    var title = item === (entry && entry.apple) ? entry.title : row.name || row.title || "It"
    root.toggleLibrary(root.browseBridge, item, root.inLibrary(root.browseBridge.serviceKey, item), title)
  }

  // How much of an Apple Music or Spotify album is in your library, for its
  // heading and the marks on its songs; null for anything else.
  // - text: "In your library", "4 of 31 in your library" or "Add to library";
  //   hover: what a click does instead, where that differs; active: a click
  //   can do something.
  // - state: what L acts on. On Apple Music "yes" once every song is yours;
  //   on Spotify, the album saved (its songs are liked one by one).
  // - owned: the rows (by index) of the songs you have, when you have some.
  // The songs' inLibrary come with the album (bridge 0.4.1, omarock-spotify
  // 0.2.2); what was added or taken out here since counts too.
  function albumLibrary(entry, rows) {
    if (!entry || !entry.apple || entry.apple.kind !== "album" || !entry.loaded || !root.browseBridgeMode) return null
    var bridge = root.browseBridge
    var service = bridge.serviceKey
    var album = entry.apple
    var albumAdded = root.libraryEdits[root.libraryKey(service, album)] === true
    var owned = {}
    var have = 0
    var total = 0
    rows.forEach(function(row, i) {
      if (row.kind !== "track" || !row.apple) return
      total++
      var known = row.item ? row.item.inLibrary : undefined
      if ((service === "apple" && albumAdded) || root.inLibrary(service, row.apple, known) === "yes") {
        owned[i] = true
        have++
      }
    })
    var saved = service === "apple" ? total > 0 && have === total
      : root.inLibrary(service, album, entry.info && entry.info.item ? entry.info.item.inLibrary : undefined) === "yes"
    var some = have > 0 && have < total
    var out = { state: saved ? "yes" : "no", owned: some ? owned : ({}), active: !saved || bridge.canUnsave, have: have, total: total,
      text: saved ? "󰄬 In your library" : some || have > 0 ? "󰄬 " + have + " of " + total + " in your library" : "󰐕 Add to library",
      hover: saved ? (bridge.canUnsave ? "󰅖 Remove from library" : "") : have > 0 ? "󰐕 Add the album" : "" }
    if (root.librarySaving === root.libraryKey(service, album)) {
      out.text = saved ? "Removing…" : "Adding…"
      out.hover = ""
      out.active = false
    }
    return out
  }
  readonly property var browseAlbumLibrary: root.albumLibrary(root.browseTop, root.browseRows)
  readonly property var previewAlbumLibrary: root.albumLibrary(root.previewEntry, root.previewRows)

  // L on an album's Play row, or a click on its heading's line.
  function libraryAlbum(entry, rows) {
    var summary = root.albumLibrary(entry, rows)
    if (summary) root.toggleLibrary(root.browseBridge, entry.apple, summary.state, entry.title)
  }

  // L in the info card: what it shows; then the card says so.
  function libraryInfo() {
    var open = root.infoCard
    if (!open || !open.request || open.request.type !== "apple" || open.loading) {
      if (open && !open.loading) root.say("L adds Apple Music and Spotify songs and albums to your library")
      return
    }
    var item = open.request.item
    var kind = open.card.statusKind
    root.toggleLibrary(root.browseBridge, item, kind === "yes" ? "yes" : kind === "no" ? "no" : "",
      open.card.title || item.title || "It", function() {
        if (root.infoCard === open) root.openInfo(open.request)
      }, open.catalogId)
  }
  // The info card's link for it ("" for none).
  readonly property string infoLibraryAction: {
    var open = root.infoCard
    if (!open || !open.request || open.request.type !== "apple" || open.loading) return ""
    if (root.librarySaving === root.libraryKey(root.browseBridge.serviceKey, open.request.item)) return "Saving…"
    var kind = open.card.statusKind
    if (kind === "yes") return root.browseBridge.canUnsave ? "Remove from library (L)" : ""
    return kind === "no" || kind === "some" || kind === "unknown" ? "Add to library (L)" : ""
  }

  // The card's Add to playlist: the picker, for the song playing.
  function addPlayingToPlaylist() {
    var item = root.playingItem
    if (item) {
      root.openPicker({ result: { items: [{ kind: "song", id: item.id, source: item.source }] }, title: item.title })
      return
    }
    var song = client.currentSong
    if (!root.bridgeMode && song && song.file)
      root.openPicker({ result: { kind: "song", file: song.file }, title: Mpd.songTitle(song) })
  }

  // o, O and g, or a click on the now playing card's album, artist or genre:
  // opened from the queue, so ← comes back to it. An album opens on the song
  // playing, an artist on its album, a genre on its artist.
  function openPlaying(kind) {
    if (root.live && kind !== "genre") {
      root.lookUp(kind === "artist" ? "artist" : "song")
      return
    }
    var entry = root.playingEntry(kind)
    if (!entry) {
      root.say(root.live ? "A live station has no album or artist to open"
        : !root.player.currentSong.file ? "Nothing is playing"
        : "This song has no " + kind + " to open")
      return
    }
    if (root.browseRoot === "queue" && root.browseStack.length === 1 && root.sameEntry(root.browseTop, entry)) return
    root.clearSearch()
    root.leaveSearch()
    root.browseRoot = "queue"
    root.browseStack = [entry]
    root.loadBrowse(entry, function() {
      var song = root.player.currentSong
      var albumId = root.bridgeMode ? root.playingIds().albumId : ""
      var index = root.browseRows.findIndex(function(row) {
        if (kind === "album") return row.kind === "track" && row.file === song.file
        if (kind === "genre") return row.kind === "artist" && !row.apple && row.artist === (song.albumartist || song.artist)
        return row.kind === "album" && (row.apple ? row.apple.id === albumId : row.album === song.album)
      })
      // A compilation's song: the genre lists its album under Compilations.
      if (index < 0 && kind === "genre") index = root.browseRows.findIndex(function(row) { return row.kind === "compilations" })
      if (index >= 0) root.cursorIndex = index
    })
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
    // Out of Top 100, the source's own rows again.
    if (!top && left.kind === "top100") root.lookupService = ""
    // Back in the queue (from Playlists), the cursor rests.
    root.cursorActive = root.rows.length > 0 && left.from >= 0
    root.cursorIndex = Math.max(0, Math.min(left.from, root.rows.length - 1))
    // Back at the results, the level just left is the preview again.
    if (!top && left.loaded && root.searchMode) root.setPreview(left)
    if (!top) root.browseRoot = "search"
  }

  function resetBrowse() {
    if (root.browseStack.length > 0 && root.browseStack[0].kind === "top100") root.lookupService = ""
    root.browseSequence++
    root.browseRoot = "search"
    root.browseStack = []
    root.browseRows = []
    root.browseInfo = ({})
    root.browseLoading = false
  }

  // then(): after it shows, to move the cursor (optional).
  function loadBrowse(entry, then) {
    var sequence = ++root.browseSequence
    root.browseRows = []
    root.browseInfo = root.placeholderInfo(entry)
    root.browseLoading = true
    root.cursorActive = false
    root.cursorIndex = 0
    root.loadEntry(entry, function() {
      if (sequence !== root.browseSequence) return
      root.showEntry(entry)
      if (then) then()
    })
  }

  function showEntry(entry) {
    root.browseRows = entry.rows
    root.browseInfo = entry.info
    root.browseLoading = false
    // Start on the first album or song; the heading's buttons are just above
    // it. A chart starts on its Play button.
    var first = root.buttonRows(entry.rows)
    root.cursorActive = entry.rows.length > 0
    root.cursorIndex = first < entry.rows.length && entry.kind !== "top100" ? first : 0
  }

  function placeholderInfo(entry) {
    return { title: entry.title, coverFile: "",
      subtitle: entry.kind === "artist" ? "Artist" : entry.kind === "genre" ? "Genre"
        : entry.kind === "playlist" ? "Playlist" : entry.kind === "playlists" ? ""
        : entry.kind === "top100" ? "Billboard's year-end chart" : entry.kind === "history" ? "What you've played here" : "Album" }
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
    var bridge = root.browseBridge
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
    // Time Machine: an album from after its year has no songs here, and a
    // playlist, an artist or a genre only those from its year or before.
    var year = root.listYear
    if (ref.kind === "playlists") {
      bridge.refreshPlaylists(shown(function(data) {
        var view = Apple.playlistsView(data, bridge.status.queueLength, bridge.service)
        view.rows = root.withHistoryRow(view.rows)
        return view
      }))
    } else if (ref.kind === "album") {
      bridge.album(ref.source, ref.id, shown(function(data) {
        var after = !TimeMachine.inYear(data.album, year)
        var view = Apple.albumView(data.album, after ? [] : data.tracks || [], bridge.service)
        if (after) view.info.emptyText = "From " + TimeMachine.yearOf(data.album) + ", after Time Machine's " + year + "."
        return view
      }))
    } else if (ref.kind === "artist") {
      root.loadAppleArtist(entry, show, shown)
    } else if (ref.kind === "playlist") {
      bridge.playlist(ref.source, ref.id, shown(function(data) {
        var tracks = (data.tracks || []).filter(function(song) { return TimeMachine.inYear(song, year) })
        var view = Apple.playlistView(data.playlist, tracks, data.note)
        if (tracks.length === 0 && (data.tracks || []).length > 0)
          view.info.emptyText = "None of its songs are from " + year + " or before (Time Machine)."
        return view
      }))
    } else if (ref.kind === "genre") {
      bridge.genre(ref.id, shown(function(data) {
        return Apple.genreView(data.genre || { name: entry.title }, TimeMachine.filterGenre(data, year))
      }))
    }
  }

  // An artist from your library and the catalog together, as one page.
  // While the bridge fetches the artist, a search of the other side looks
  // for the same name; when it's there and isn't the same object (Spotify's
  // followed artists are its catalog's), both are fetched and merged.
  // When the artist's own id doesn't open, that name on the other side
  // opens instead: a library song whose album the bridge doesn't count as
  // yours carries an artist id its artist route can't find.
  function loadAppleArtist(entry, show, shown) {
    var bridge = root.browseBridge
    var ref = entry.apple
    var other = ref.source === "library" ? "catalog" : "library"
    var main = null
    var mainError = null
    var found = undefined
    var failed = shown(null)
    function merge(data) {
      data = TimeMachine.filterArtist(data, root.listYear)
      var mine = ref.source === "library" ? main : data
      var theirs = ref.source === "library" ? data : main
      show(Apple.mergedArtistView({ artist: mine.artist, data: mine }, { artist: theirs.artist, data: theirs }, bridge.service))
    }
    function instead() {
      var match = found ? Apple.findArtist(found, other, entry.title) : null
      if (!match) { failed(null, mainError); return }
      bridge.artist(other, match.id, function(data) {
        if (data) show(Apple.artistView(data.artist, TimeMachine.filterArtist(data, root.listYear), bridge.service))
        else failed(null, mainError)
      })
    }
    function both() {
      if (found === undefined) return
      if (mainError !== null) { instead(); return }
      if (!main) return
      var match = found ? Apple.findArtist(found, other, main.artist.name || entry.title) : null
      if (!match || match.id === ref.id) {
        show(Apple.artistView(main.artist, main, bridge.service))
        return
      }
      bridge.artist(other, match.id, function(data) {
        if (data) merge(data)
        else show(Apple.artistView(main.artist, main, bridge.service))
      })
    }
    bridge.artist(ref.source, ref.id, function(data, error) {
      if (!data) mainError = error || "The artist didn't open"
      else main = TimeMachine.filterArtist(data, root.listYear)
      both()
    })
    bridge.search(entry.title, function(results) {
      found = results || null
      both()
    }, other)
  }

  // Fills in entry.rows, entry.info and entry.files from mpd, then done().
  function loadEntry(entry, done) {
    if (entry.apple) {
      root.loadAppleEntry(entry, done)
      return
    }
    if (entry.kind === "top100") {
      root.loadTop100(entry, done)
      return
    }
    if (entry.kind === "history") {
      root.loadHistory(entry, done)
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
        show(root.withHistoryRow(root.playlistsRows(playlists)), { title: entry.title, coverFile: "",
          subtitle: playlists.length === 0 ? "None yet" : root.countText(playlists.length, "playlist") }, [])
      })
    } else if (entry.kind === "playlist") {
      client.playlistSongs(entry.playlist, function(songs, error) {
        if (!songs) {
          show([], { title: entry.title, subtitle: "Playlist", coverFile: "", failed: true,
            emptyText: error.indexOf("No such playlist") >= 0 ? "This playlist is gone. ← goes back." : "" }, [])
          return
        }
        show(root.playlistSongRows(songs), root.playlistInfo(entry, songs), Mpd.filesOf(client.playlistInYear(songs)))
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
    return { kind: "album", lead: "󰀥", title: album.album, subtitle: root.albumSubtitle(album, true),
      artist: album.albumartist, album: album.album, cover: { album: album.album, artist: album.albumartist } }
  }

  // An album row's line from mpd's list (search, a genre): its artist (or
  // how many), the year, and how many songs.
  function albumSubtitle(album, withYear) {
    var parts = [album.albumartist !== "" ? album.albumartist : album.artists.length + " artists"]
    if (withYear && album.year !== "") parts.push(album.year)
    if (album.songCount > 0) parts.push(root.countText(album.songCount, "song"))
    return parts.join(" · ")
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
  // With Time Machine on, only its songs from the year or before are listed
  // (each with its place in the playlist, which x takes out).
  function playlistSongRows(songs) {
    var listed = root.timeYear > 0 ? client.playlistInYear(songs) : songs
    if (listed.length === 0) return []
    var seconds = 0
    listed.forEach(function(song) { seconds += Mpd.songSeconds(song) })
    var rows = [{ kind: "playplaylist", lead: "󰐊", title: "Play the playlist",
      subtitle: root.countText(listed.length, "song") + " · " + Mpd.formatTotal(seconds) }]
    var present = 0
    songs.forEach(function(song, i) {
      if (listed !== songs && listed.indexOf(song) < 0) return
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
    var listed = root.timeYear > 0 ? client.playlistInYear(songs) : songs
    var seconds = 0
    var cover = ""
    listed.forEach(function(song) {
      seconds += Mpd.songSeconds(song)
      if (cover === "" && !Mpd.isMissing(song)) cover = song.file
    })
    var count = listed === songs ? root.countText(songs.length, "song")
      : listed.length + " of " + root.countText(songs.length, "song") + ", to " + root.timeYear
    return { title: entry.title, coverFile: cover,
      subtitle: "Playlist · " + count + (listed.length > 0 ? " · " + Mpd.formatTotal(seconds) : ""),
      emptyText: listed.length === 0 && songs.length > 0 ? "None of its songs are from " + root.timeYear + " or before (Time Machine)."
        : "This playlist is empty. Find a song, album or artist and press A to add it." }
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
    if (entry && entry.kind === "top100") {
      root.activateTop100(entry, row, index, mode)
      return
    }
    if (row.kind === "historylist") {
      if (mode !== "add") root.openRow(index)
      return
    }
    if (entry && entry.kind === "history") {
      root.activateHistory(row, mode)
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
    // With Time Machine leaving some of a playlist's songs or an artist's
    // top songs out, the ones listed play (its Play row's items), not all.
    var listed = root.listYear > 0 && entry && entry.rows.length > 0 && entry.rows[0].items ? entry.rows[0].items : null
    if (row.kind === "playalbum" || row.kind === "playplaylist" || row.kind === "playall") {
      name = entry.title
      items = listed || [entry.apple]
    } else if (row.kind === "track" && mode === "play") {
      items = listed || [entry.apple]
      start = row.position
    }
    var bridge = root.browseBridge
    // From a lookup, it plays on that service, which then becomes the source.
    var switchTo = mode === "play" ? root.lookupService : ""
    bridge.playItems(items, mode === "play" ? "play" : "add", start, function(data, error) {
      if (error !== "") root.say(error)
      else if (switchTo !== "") root.setSource(switchTo)
    })
    if (mode === "play") {
      root.clearSearch()
      root.leaveSearch()
      root.say("Playing " + name + (switchTo !== "" ? " on " + bridge.service : ""))
    } else {
      root.say("Added " + name + " to " + (root.lookupService !== "" ? bridge.service + "'s queue" : "the queue"))
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

  function openSettings() {
    root.keysOpen = false
    root.closeInfo()
    settingsView.reset()
    root.settingsOpen = true
    accountReader.running = true
    root.readSources()
    // How each switched-on source is doing, now.
    if (root.spotifyEnabled) spotify.checkHealth()
    if (root.sxmEnabled) sxm.checkHealth()
    if (root.appleConfigured) apple.checkHealth()
  }

  function closeSettings() {
    root.settingsOpen = false
    keyCatcher.forceActiveFocus()
  }

  // Saving a setting writes omarock's settings file, all of it, one write at
  // a time; it takes effect at once, as the panel already has it.
  property bool settingsUnsaved: false
  function saveSetting(key, value) {
    root.fileSettings = Settings.withValue(root.fileSettings, key, value)
    // Time Machine switched off forgets its year: on again, it starts off.
    if (key === "timeMachine" && value !== true) root.fileSettings = Settings.withValue(root.fileSettings, "timeMachineYear", 0)
    root.settingsUnsaved = true
    root.writeSettings()
    // A source switched off stops its services (keeping its accounts and
    // keys); switched on, they start again.
    var piece = root.switchPieces[key]
    if (piece) {
      sourceSwitcher.queue = sourceSwitcher.queue.concat([[root.sourcesTool, value === true ? "start" : "stop", piece]])
      root.switchSources()
    }
  }
  readonly property var switchPieces: ({ spotify: "spotify", siriusXM: "siriusxm", appleMusic: "apple-music" })
  function switchSources() {
    if (sourceSwitcher.running || sourceSwitcher.queue.length === 0) return
    sourceSwitcher.command = sourceSwitcher.queue[0]
    sourceSwitcher.queue = sourceSwitcher.queue.slice(1)
    sourceSwitcher.running = true
  }

  // A piece's setup or removal (./install PIECE, ./install --remove PIECE)
  // in a terminal, as Omarchy runs its own installs, with the setup window's
  // choices after the piece (--yes terms, --output NAME). The panel closes,
  // so the terminal has the keyboard, and follows the run in setup.json
  // (tools/omarock-sources) until it ends.
  readonly property string setupTerminal: "omarchy-launch-floating-terminal-with-presentation"
  property var setupLaunched: null
  function shellWord(word) {
    word = String(word)
    return /^[A-Za-z0-9_.\/:=@%+,-]+$/.test(word) ? word : "'" + word.replace(/'/g, "'\\''") + "'"
  }
  function runSetup(piece, remove, extra) {
    if (root.setupLaunched) {
      root.say("A setup is still running in its terminal")
      return
    }
    var args = remove ? " --remove " + piece : piece !== "local" ? " " + piece : ""
    args += (extra || []).map(function(w) { return " " + root.shellWord(w) }).join("")
    root.setupLaunched = { piece: piece, action: remove ? "remove" : "setup", at: Date.now() / 1000 }
    Quickshell.execDetached([root.setupTerminal, "'" + root.installPath.replace(/'/g, "'\\''") + "'" + args])
    setupFollow.restart()
    root.close()
  }
  function readSources() {
    if (!sourcesReader.running) sourcesReader.running = true
  }
  // omarock-sources answered: if it's the end of the run this panel
  // started, read everything that run may have changed.
  function sourcesRead(state) {
    root.sourcesState = state
    var launched = root.setupLaunched
    var flow = state ? state.flow : null
    if (!launched || !flow || flow.piece !== launched.piece || flow.at < launched.at - 5 || flow.result === "running") return
    root.setupLaunched = null
    setupFollow.stop()
    root.rereadConfig()
    accountReader.running = true
    serviceRecheck.restart()
    if (root.spotifyEnabled) spotify.checkHealth()
    if (root.sxmEnabled) sxm.checkHealth()
    if (root.appleConfigured) apple.checkHealth()
  }
  function writeSettings() {
    if (!root.settingsUnsaved || settingWriter.running) return
    root.settingsUnsaved = false
    settingWriter.command = ["sh", "-c", 'mkdir -p "$1" && printf "%s" "$2" > "$1/settings.json.new" && mv "$1/settings.json.new" "$1/settings.json"',
      "sh", root.configDir, JSON.stringify(root.fileSettings, null, 2) + "\n"]
    settingWriter.running = true
  }

  // An account, a key or the music folder (tools/omarock-account): the value
  // goes over stdin, never on a command line. One at a time.
  readonly property string accountTool: decodeURIComponent(String(Qt.resolvedUrl("tools/omarock-account")).replace(/^file:\/\//, ""))
  readonly property var accountCommands: ({ sxmUser: "sxm-user", sxmPassword: "sxm-password", spotifyClient: "spotify-client",
    soloistKey: "soloist-key", bridgeToken: "bridge-token", musicFolder: "music-folder" })
  function saveAccount(key, value) {
    if (accountWriter.running) {
      root.say("Still saving the last change: try again in a moment")
      return
    }
    accountWriter.key = key
    accountWriter.secret = value
    accountWriter.command = [root.accountTool, root.accountCommands[key]]
    accountWriter.running = true
    root.say(key === "musicFolder" ? "Changing the music folder: mpd restarts…" : "Saving…")
  }
  // The settings screen's buttons: setting a piece up (its window first,
  // then the terminal), setting it up again (Fix, Update: straight to the
  // terminal), removing one, Spotify's sign-in.
  readonly property var setupWindows: ({ spotify: "spotify", siriusXM: "siriusxm", appleMusic: "apple-music", sound: "sound" })
  readonly property var setupActions: ({ localSetUp: "local", spotifyUpdate: "spotify", sxmUpdate: "siriusxm",
    appleUpdate: "apple-music", soundUpdate: "sound" })
  readonly property var removeActions: ({ spotifyRemove: "spotify", sxmRemove: "siriusxm", appleRemove: "apple-music",
    soundRemove: "sound" })
  function settingAction(key) {
    if (root.setupWindows[key]) return root.openSetupWindow(root.setupWindows[key])
    if (root.setupActions[key]) return root.runSetup(root.setupActions[key], false)
    if (root.removeActions[key]) return root.runSetup(root.removeActions[key], true)
    if (key === "historyClear") {
      root.confirmTarget = { clearHistory: true }
      return
    }
    if (key !== "spotifyLogin") return
    if (root.settingStates.spotify.signedIn) {
      root.confirmTarget = { signOut: true }
      return
    }
    spotify.get("/v1/login", function(data, error) {
      if (data && data.url) {
        Qt.openUrlExternally(data.url)
        root.say("Spotify's sign-in is open in your browser")
      } else {
        root.say(error !== "" ? error : "omarock-spotify has no sign-in to offer")
      }
    })
  }
  // A new music folder, from the settings: asked about first, once the
  // settings' field has handed the keys back (the dialog takes them).
  function askMusicFolder(path) {
    if (path === "" || path === root.settingValues.musicFolder) return
    Qt.callLater(function() { root.confirmTarget = { folder: path } })
  }

  // Esc: close the key list, else leave the now playing card for the list,
  // else back out of an artist or album, else clear the search, else close
  // the panel.
  function stepBack() {
    if (root.yearPickerOpen) root.closeYearPicker()
    else if (root.pickerOpen) root.closePicker()
    else if (root.confirmOpen) root.cancelConfirm()
    else if (root.settingsOpen) root.closeSettings()
    else if (root.infoOpen) root.closeInfo()
    else if (root.keysOpen) root.keysOpen = false
    else if (root.cardFocus !== "") root.leaveCard(false)
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
      root.confirmTarget = { playlist: row.playlist, songs: row.songs }
    }
  }

  function cancelConfirm() {
    root.confirmTarget = null
    keyCatcher.forceActiveFocus()
  }

  function acceptConfirm() {
    var folder = root.confirmTarget ? root.confirmTarget.folder || "" : ""
    var name = root.confirmTarget ? root.confirmTarget.playlist || "" : ""
    var signOut = !!root.confirmTarget && root.confirmTarget.signOut === true
    var clearHistory = !!root.confirmTarget && root.confirmTarget.clearHistory === true
    root.cancelConfirm()
    if (folder !== "") {
      root.saveAccount("musicFolder", folder)
      return
    }
    if (clearHistory) {
      history.clear(function() { root.say("History cleared") })
      root.historyHeard = { key: "", seconds: 0, added: false }
      return
    }
    if (signOut) {
      root.signOutSpotify()
      return
    }
    if (name === "") return
    client.deletePlaylist(name, function(error) {
      if (error !== "") return
      root.say("Deleted the playlist " + name)
      if (root.browseTop && root.browseTop.kind === "playlist" && root.browseTop.playlist === name) root.goBack()
    })
  }

  // Spotify's Sign out: omarock-spotify forgets the Web API's sign-in
  // (Soloist stays paired).
  function signOutSpotify() {
    spotify.post("/v1/logout", {}, function(data, error) {
      root.say(error === "No such endpoint." ? "To sign out, update omarock-spotify first: Update… under Spotify"
        : error !== "" ? "Couldn't sign out: " + error : "Signed out of Spotify")
      spotify.checkHealth()
    })
  }

  // A: what a row adds to a playlist, as { result, title }, or null.
  function playlistItem(entry, row) {
    if (!row || row.missing) return null
    var kind = row.kind
    // History: a song of yours, into one of your playlists (while the picker
    // has mpd's, on local music or a station).
    if (entry && entry.kind === "history")
      return kind === "history" && row.history.source === "local" && !root.browseBridgeMode
        ? { result: { kind: "song", file: row.file }, title: row.title } : null
    // Top 100: a song, or the chart's songs found (as a playlist of the service's).
    if (entry && entry.kind === "top100") {
      if (kind === "playtop") return (entry.songItems || []).length > 0 ? { result: { items: entry.songItems }, title: entry.title } : null
      return row.apple ? { result: { items: [row.apple] }, title: row.title } : null
    }
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
    if (item.result.items) {
      root.browseBridge.refreshPlaylists(function(list) {
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
      var bridge = root.browseBridge
      var target = bridge.playlists.filter(function(p) { return p.name === name })[0]
      if (isNew || !target) bridge.createPlaylist(name, item.result.items, done)
      else bridge.addToPlaylist(target.id, item.result.items, done)
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
      if (!!entry.apple !== root.browseBridgeMode) return
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
    var song = kind === "song" || kind === "track" || kind === "queue" || (kind === "history" && row.history.source === "local")
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
        root.infoCard = Object.assign({ card: card, coverFile: "", logo: "", coverUrl: "", loading: loading, request: request }, look)
    }
    if (request.type === "apple") {
      var item = request.item
      var bridge = root.browseBridge
      show(Info.appleItem(item, root.withLibraryEdit(bridge.serviceKey, item, { checking: item.source !== "library" }), bridge.serviceKey),
        { coverUrl: Apple.artUrl(item.artwork, 160) }, true)
      bridge.info(item, function(extra) {
        var full = extra.item || item
        show(Info.appleItem(full, root.withLibraryEdit(bridge.serviceKey, item, extra), bridge.serviceKey),
          { coverUrl: Apple.artUrl(full.artwork, 160), catalogId: (extra.catalog && extra.catalog.id) || full.catalogId || "" }, false)
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
    else if (t === "+" || t === "=") (player.ownVolume ? player : client).nudgeVolume(5)
    else if (t === "-" || t === "_") (player.ownVolume ? player : client).nudgeVolume(-5)
    else if (t === "s") player.setRandom(!status.random)
    else if (t === "r") player.setRepeat(!status.repeat)
    else if (t === "m" && root.sources.length > 1) root.nextSourceKey()
    else if (t === "e") root.expanded = !root.expanded
    else if (t === "?") root.keysOpen = !root.keysOpen
    else if (t === ",") root.openSettings()
    else if (t === "i") root.showInfo()
    else if (t === "P") root.openPlaylists()
    else if (t === "H") root.openHistory()
    else if (t === "t" && root.timeMachineEnabled) root.openYearPicker()
    else if (t === "T" && root.timeMachineEnabled) root.openTop100()
    else if (t === "o") root.openPlaying("album")
    else if (t === "O") root.openPlaying("artist")
    else if (t === "g") root.openPlaying("genre")
    else if (t === "L") {
      if (root.cursorActive) root.libraryRow(root.browseTop, root.cursorRow())
      else root.libraryPlaying()
    } else if (t === "a") {
      var row = root.cursorRow()
      if (root.rowQueues(row)) root.activateRow(root.cursorIndex, "add")
    } else if (t === "A") {
      var picked = root.cursorRow()
      if (picked && (picked.kind === "channel" || picked.kind === "station")) root.toggleFavorite(picked)
      else if (root.cursorActive) root.addToPlaylistIn(root.browseTop, root.rows, root.cursorIndex)
      else if (root.canAddPlayingToPlaylist) root.addPlayingToPlaylist()
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
    yearLimit: root.timeYear
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
    onQueueChanged: root.recheckQueue()
  }

  // omarock's settings file, followed as it changes (by the settings
  // screen, the installer, or by hand).
  FileView {
    id: settingsFile
    path: root.configDir + "/settings.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.fileSettings = Settings.parse(text())
    onLoadFailed: root.fileSettings = {}
    onFileChanged: reload()
  }

  // Writes the settings file (writeSettings), and says why if it couldn't.
  Process {
    id: settingWriter
    stderr: StdioCollector { id: settingWriterErrors; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.say("Couldn't save the settings: " + (String(settingWriterErrors.text || "").trim().split("\n")[0] || "no reason given"))
      Qt.callLater(root.writeSettings)
    }
  }

  // Saves an account, a key or the music folder (saveAccount).
  Process {
    id: accountWriter
    property string key: ""
    property string secret: ""
    stdinEnabled: true
    stderr: StdioCollector { id: accountWriterErrors; waitForEnd: true }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode) {
      var key = accountWriter.key
      if (exitCode !== 0) {
        root.say("Couldn't save it: " + (String(accountWriterErrors.text || "").trim().split("\n")[0] || "no reason given"))
      } else {
        root.say(key === "musicFolder" ? "mpd plays from the new folder now, and is reading it"
          : key === "sxmUser" || key === "sxmPassword" ? "Saved: omarock-sxm is signing in again"
          : key === "soloistKey" ? "Saved: Soloist is restarting" : "Saved")
        if (key === "bridgeToken") apple.reloadToken()
        serviceRecheck.restart()
      }
      accountReader.running = true
    }
  }

  // What's set up (tools/omarock-sources state), for the settings screen.
  Process {
    id: sourcesReader
    command: [root.sourcesTool, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = null
        try { state = JSON.parse(text) } catch (e) {}
        if (state) root.sourcesRead(state)
      }
    }
  }

  // Stops or starts a source's services as its switch changes, one at a
  // time, then reads what's set up again.
  Process {
    id: sourceSwitcher
    property var queue: []
    stderr: StdioCollector { id: sourceSwitcherErrors; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.say("Couldn't " + (sourceSwitcher.command[1] === "start" ? "start" : "stop") + " its services: "
          + (String(sourceSwitcherErrors.text || "").trim().split("\n")[0] || "no reason given"))
      root.readSources()
      serviceRecheck.restart()
      Qt.callLater(root.switchSources)
    }
  }

  // A setup running in its terminal: setup.json, read every 1.5 s until the
  // run ends. A terminal that never started the run is given up after 90 s.
  Timer {
    id: setupFollow
    interval: 1500
    repeat: true
    onTriggered: {
      var launched = root.setupLaunched
      if (!launched) return stop()
      var flow = root.sourcesState ? root.sourcesState.flow : null
      var started = flow && flow.piece === launched.piece && flow.at >= launched.at - 5
      if (!started && Date.now() / 1000 - launched.at > 90) {
        root.setupLaunched = null
        root.say("The setup's terminal didn't start: " + root.setupTerminal + " is Omarchy's")
        return stop()
      }
      root.readSources()
    }
  }

  // What's set (tools/omarock-account show), for the settings screen.
  Process {
    id: accountReader
    command: [root.accountTool, "show"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.accounts = JSON.parse(text) || {} } catch (e) { root.accounts = {} }
      }
    }
  }

  // A service just restarted with a new login or key: how it's doing, once
  // it has had a moment.
  Timer {
    id: serviceRecheck
    interval: 5000
    onTriggered: {
      if (root.sxmEnabled) sxm.checkHealth()
      if (root.spotifyEnabled) spotify.checkHealth()
      if (root.appleConfigured) apple.checkHealth()
    }
  }

  // omarock's files in ~/.config/omarock, read again. FileView watches a file
  // only if it was there when omarock loaded, so one made later (by the
  // installer, or by hand) is read when the panel opens or its source is
  // switched on.
  function rereadConfig() {
    settingsFile.reload()
    appleConfigFile.reload()
    apple.reloadToken()
    radio.rereadPlace()
  }

  FileView {
    id: appleConfigFile
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
    setArea: root.setting("radioArea", "")
    setPlace: root.setting("radioState", "")
    timeZone: root.setting("timeZone", "")
    cacheDir: Quickshell.env("HOME") + "/.cache/omarock"
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

  // This machine's name, for the services that play on one machine at a
  // time (Apple Music, Spotify): they say where they play instead.
  property string clientName: ""
  FileView {
    path: "/etc/hostname"
    printErrors: false
    onLoaded: root.clientName = text().trim()
  }

  AppleClient {
    id: apple
    baseUrl: root.appleBridge
    tokenFile: root.appleTokenFile
    mpd: client
    clientName: root.clientName
    active: root.mpdOnApple
    idleStopSeconds: Math.max(0, Number(root.setting("appleIdleStop", 60)) || 0)
    // On unless switched off: only a patched libFLAC keeps up without it.
    rejoinAfterChange: root.setting("appleRejoin", true) === true
    onLastErrorChanged: if (root.appleMode && apple.lastError !== "") root.say(apple.lastError)
    onBridgeStatusChanged: if (root.appleMode) root.recheckQueue()
  }

  // Spotify's service. Followed whenever Spotify is switched on, as its
  // status says whether Spotify is the source; without the service, it
  // looks again every 30 s.
  AppleClient {
    id: spotify
    baseUrl: root.spotifyService
    mpd: client
    clientName: root.clientName
    service: "Spotify"
    serviceKey: "spotify"
    streamed: false
    canRemove: false
    canUnsave: true
    libraryUpdateText: "To add to your library, update omarock-spotify: Update… under Spotify, in the settings"
    bridgeName: "omarock-spotify"
    unreachableText: "Can't reach omarock-spotify (systemctl --user status omarock-spotify)"
    unauthorizedText: "Spotify isn't signed in: run omarock-sp login"
    active: root.spotifyEnabled
    retryMs: root.spotifyMode ? 3000 : 30000
    idleStopSeconds: 0
    onLastErrorChanged: if (root.spotifyMode && spotify.lastError !== "") root.say(spotify.lastError)
    onBridgeStatusChanged: if (root.spotifyMode) root.recheckQueue()
  }

  // Time Machine's charts, and their songs as Apple Music and Spotify have them.
  ChartClient {
    id: charts
    source: root.setting("chartSource", "") || "https://en.wikipedia.org"
    cacheDir: Quickshell.env("HOME") + "/.cache/omarock/charts"
    onChanged: root.top100Changed()
  }

  // History's file, and once a second while something plays, whether the
  // song playing has now been heard long enough to count (History.counts).
  HistoryClient {
    id: history
    path: Quickshell.env("HOME") + "/.local/share/omarock/history.jsonl"
    days: root.historyDays
    onChanged: root.historyChanged()
  }
  Timer {
    id: historyTick
    interval: 1000
    repeat: true
    running: root.historyEnabled && root.playing && root.hasSong
    onTriggered: root.tickHistory(1)
  }
  // A song of yours from History waits for local music this long.
  Timer {
    id: historyPendingDrop
    interval: 10000
    onTriggered: root.historyPending = ""
  }

  Timer {
    id: searchDelay
    interval: 180
    onTriggered: root.runSearch()
  }

  // Time Machine's look at the queue, once a change has settled.
  Timer {
    id: queueKeeper
    interval: 400
    onTriggered: root.keepQueueInYear(false)
  }

  Timer {
    id: previewDelay
    interval: 120
    onTriggered: root.updatePreview()
  }

  Timer {
    id: noticeTimer
    interval: 3500
    // "Tuning …" stays until the station answers, "Starting the Top 100…"
    // until it plays, and mpd stuck stays said.
    onTriggered: if (client.stalled || client.streamTuning !== "" || root.chartStarting) restart(); else root.notice = ""
  }

  Timer {
    id: leaveDelay
    interval: 3000
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
    focusTarget: focusReturn
    contentWidth: panel.fittedContentWidth(Style.space(root.expanded ? 1120 : 430))
    contentHeight: root.expanded
      ? panel.fittedContentHeight(Style.space(740))
      : panel.fittedContentHeight(layout.item ? layout.item.implicitHeight : Style.space(400))
    onContentWidthChanged: root.cardResized()
    onContentHeightChanged: root.cardResized()

    // What the panel focuses as it opens; it passes the keys on (returnFocus).
    Item {
      id: focusReturn
      onActiveFocusChanged: if (activeFocus) root.returnFocus()
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The search box, the playlist picker and the delete dialog take
      // their own keys.
      blocked: (!!root.searchField && root.searchField.activeFocus) || root.pickerOpen || root.confirmOpen
        || root.yearPickerOpen || (root.settingsOpen && settingsView.editing !== "")

      // ↑↓ move, → opens an artist or album, ← goes back. Shift+←→ seek
      // (the Shortcuts below take those before this sees them).
      onMoveRequested: function(dx, dy) {
        if (root.settingsOpen) {
          if (dy !== 0) settingsView.move(dy)
          else settingsView.adjust(dx)
          return
        }
        if (root.infoOpen) {
          if (dy !== 0) infoView.scroll(dy)
          else if (dx < 0) root.closeInfo()
          return
        }
        if (root.keysOpen) return
        if (root.cardFocus !== "") { root.moveInCard(dx, dy); return }
        // ↑ from the top of the list: up into the now playing card.
        if (dy < 0 && (root.rows.length === 0 || (root.cursorActive && root.cursorIndex === 0)) && root.enterCard()) return
        if (dy !== 0) root.moveCursor(dy)
        else if (dx > 0) root.openCursorRow()
        else root.goBack()
      }
      onReturnRequested: root.returnPressed = true
      onActivateRequested: {
        var enter = root.returnPressed
        root.returnPressed = false
        if (root.settingsOpen) { settingsView.activate(); return }
        if (root.infoOpen) { root.closeInfo(); return }
        if (root.keysOpen) { root.keysOpen = false; return }
        if (enter && root.cardFocus !== "") { root.activateCard(); return }
        if (enter && root.cursorActive) root.activateRow(root.cursorIndex, "open")
        else if (enter && root.searchMode && !root.browsing) root.activateRow(0, "open")
        else root.playPause()
      }
      onDeleteRequested: if (root.cursorActive && !root.keysOpen && !root.infoOpen && !root.settingsOpen) root.removeRow(root.cursorIndex)
      onCloseRequested: root.stepBack()
      // Tab and Shift+Tab: the settings' tabs there; elsewhere the next or
      // previous panel in this part of the bar, as Omarchy's own panels do.
      // The bar knows omarock by its widget (Ui.Panel's switchPanel passes
      // the panel, which it doesn't find).
      onTabRequested: function(direction) {
        if (root.settingsOpen) settingsView.nextTab(direction)
        else if (root.bar && typeof root.bar.switchPanelFrom === "function") root.bar.switchPanelFrom(root.barIdentity, direction)
      }
      onTextKey: function(text) {
        if (root.settingsOpen) {
          if (text === ",") root.closeSettings()
          else if (text === "+" || text === "=") settingsView.adjust(1)
          else if (text === "-" || text === "_") settingsView.adjust(-1)
          return
        }
        if (root.infoOpen) {
          if (text === "i") root.closeInfo()
          else if (text === "L") root.libraryInfo()
          return
        }
        if (root.keysOpen && text === "w") root.openKeysWindow()
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
        visible: !root.keysOpen && !root.infoOpen && !root.settingsOpen
        onLoaded: Qt.callLater(root.showCurrentSong)
      }

      KeysHelp {
        anchors.fill: parent
        visible: root.keysOpen
        foreground: root.foreground
        fontFamily: root.fontFamily
        version: root.version
        here: root.hereKeys
        onCloseRequested: root.keysOpen = false
        onWindowRequested: root.openKeysWindow()
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
        actionText: root.infoLibraryAction
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCloseRequested: root.closeInfo()
        onActionRequested: root.libraryInfo()
      }

      SettingsView {
        id: settingsView
        objectName: "settingsView"
        anchors.fill: parent
        visible: root.settingsOpen
        schema: root.settingsSchema
        values: root.settingValues
        notes: root.settingNotes
        placeholders: root.settingPlaceholders
        notice: root.notice
        wide: root.expanded
        foreground: root.foreground
        fontFamily: root.fontFamily
        onChangeRequested: function(key, value) { root.saveSetting(key, value) }
        onAccountRequested: function(key, value) { root.saveAccount(key, value) }
        onActionRequested: function(key) { root.settingAction(key) }
        onFolderRequested: function(path) { root.askMusicFolder(path) }
        onCloseRequested: root.closeSettings()
        onEditFinished: keyCatcher.forceActiveFocus()
      }

      PlaylistPicker {
        id: playlistPicker
        objectName: "playlistPicker"
        anchors.fill: parent
        z: 10
        open: root.pickerOpen
        title: root.pickerItem ? root.pickerItem.title : ""
        playlists: root.browseBridgeMode ? root.browseBridge.playlists.filter(function(p) { return p.canEdit !== false }) : client.playlists
        counts: root.playlistCounts
        foreground: root.foreground
        fontFamily: root.fontFamily
        onPicked: function(name, isNew) { root.pickPlaylist(name, isNew) }
        onCanceled: root.closePicker()
      }

      YearPicker {
        id: yearPicker
        objectName: "yearPicker"
        anchors.fill: parent
        z: 10
        open: root.yearPickerOpen
        year: root.timeYear
        queueYears: root.queueYears
        skipsInstead: root.spotifyMode
        foreground: root.foreground
        fontFamily: root.fontFamily
        onPicked: function(year) { root.pickYear(year) }
        onCanceled: root.closeYearPicker()
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        message: root.confirmTarget && root.confirmTarget.folder
          ? "Play music from “" + root.confirmTarget.folder + "”? omarock keeps a copy of mpd.conf, changes only its "
            + "music_directory line, then restarts mpd (anything playing stops for a moment) and reads the new folder."
          : root.confirmTarget && root.confirmTarget.signOut
          ? "Sign omarock out of Spotify? Search and your library stop working here until you sign in again. "
            + "Spotify's player stays paired to your account."
          : root.confirmTarget && root.confirmTarget.clearHistory
          ? "Clear the history? Everything played so far is forgotten. Your music and playlists stay as they are."
          : root.confirmTarget
          ? "Delete the playlist “" + root.confirmTarget.playlist + "”? "
            + (root.confirmTarget.songs > 0 ? "Its " + root.countText(root.confirmTarget.songs, "song") + " stay in the library."
              : "It's empty.")
          : ""
        confirmText: root.confirmTarget && root.confirmTarget.folder ? "Change it"
          : root.confirmTarget && root.confirmTarget.signOut ? "Sign out"
          : root.confirmTarget && root.confirmTarget.clearHistory ? "Clear" : "Delete"
        background: Commons.Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelConfirm()
        onConfirmed: root.acceptConfirm()
        onOpenedChanged: if (opened) {
          selectedIndex = 1
          confirmKeys.forceActiveFocus()
        }
      }

      // The dialog's keys: Enter, Esc, ← → and Tab; it swallows the rest.
      Item {
        id: confirmKeys
        Keys.onPressed: function(event) {
          confirmDialog.handleKey(event)
          event.accepted = true
        }
      }

      Shortcut {
        sequence: "Shift+Right"
        enabled: root.opened && !root.keysOpen && !root.pickerOpen && !root.confirmOpen && !root.infoOpen && !root.yearPickerOpen
          && !(root.searchField && root.searchField.activeFocus)
        onActivated: root.player.seekBy(10)
      }

      Shortcut {
        sequence: "Shift+Left"
        enabled: root.opened && !root.keysOpen && !root.pickerOpen && !root.confirmOpen && !root.infoOpen && !root.yearPickerOpen
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
      text: "󰗜"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
    }
  }

  component HeaderLabels: Column {
    // The compact header: the play state alone, no "· song 3 of 12".
    property bool brief: false
    spacing: Style.space(1)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "omarock"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: ((root.sources.length > 1 ? "" : root.sourcePrefix) + (parent.brief ? root.playStateWord : root.playStateText)).toUpperCase()
      color: root.connected ? root.dim : Commons.Color.urgent
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

  // Time Machine, once it's switched on in the settings: the year picked, or
  // OFF. A click (or t) picks another. brief: the year alone (compact).
  component TimeMachineChip: Button {
    property bool brief: false
    objectName: "timeMachineChip"
    visible: root.timeMachineEnabled
    width: visible ? implicitWidth : 0
    text: (brief ? "" : "Time Machine: ") + (root.timeYear > 0 ? root.timeYear : "OFF")
    iconText: "󰋚"
    iconSize: fontSize
    horizontalPadding: brief ? Math.round(Style.spacing.controlPaddingX / 2) : Style.spacing.controlPaddingX
    bordered: true
    selected: root.timeYear > 0
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    tooltipText: root.timeYear > 0 ? "Time Machine: only music from " + root.timeYear + " or before. Another year, or off (t)"
      : "Time Machine: pick a year, for only its music and older, and its Top 100 (t)"
    onClicked: root.openYearPicker()
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
      } else if (event.text === "/") {
        // The way into this box; in it, it does nothing (AC/DC is "ac dc").
        event.accepted = true
      }
    }
  }

  // Above the queue: its length, and the way to the playlists (and with
  // Time Machine's year picked, to its Top 100).
  component QueueHeading: Item {
    implicitHeight: Math.max(queueTitle.implicitHeight, playlistsButton.implicitHeight)

    PanelSectionHeader {
      id: queueTitle
      anchors.left: parent.left
      anchors.right: top100Button.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: root.queueHeading
      elide: Text.ElideRight
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Button {
      id: top100Button
      objectName: "top100Button"
      visible: root.timeYear > 0
      width: visible ? implicitWidth : 0
      anchors.right: playlistsButton.left
      anchors.rightMargin: visible && playlistsButton.visible ? Style.space(8) : 0
      anchors.verticalCenter: parent.verticalCenter
      text: root.timeYear > 0 ? TimeMachine.chartName(root.timeYear) : ""
      iconText: "󰔸"
      iconSize: fontSize
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      tooltipText: root.timeYear > 0 ? "Billboard's " + TimeMachine.chartName(root.timeYear) + " of " + root.timeYear
        + (root.chartService !== "" ? ", on " + (root.chartService === "apple" ? "Apple Music" : "Spotify") : "") + " (T)" : ""
      onClicked: root.openTop100()
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
    // An album's root.albumLibrary, to mark the songs you have.
    property var album: listRoot.role === "current" && root.browsing ? root.browseAlbumLibrary
      : listRoot.role === "preview" ? root.previewAlbumLibrary : null
    // The list it shows; "" for the columns that only follow along, which
    // start at the top whenever their rows change.
    property string listKey: listRoot.role === "current" ? root.listKey : ""
    property string shownKey: ""
    // The rows its heading shows as buttons (root.buttonRows), left out here.
    readonly property int buttonRows: root.buttonRows(listRoot.model)
    onMarkIndexChanged: Qt.callLater(listRoot.keepMarkVisible)
    // Not the row under the pointer: the pointer put the cursor there, and
    // scrolling a row half off the edge into view moved the list under the
    // pointer (the list rocked a row up and down as the mouse went over it).
    function keepMarkVisible() {
      if (listRoot.markIndex < 0 || listRoot.markIndex >= list.count) return
      var item = list.itemAtIndex(listRoot.markIndex)
      if (item && item.pointerOver) return
      list.positionViewAtIndex(listRoot.markIndex, ListView.Contain)
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
        readonly property bool pointerOver: trackRow.pointerOver
        readonly property bool asButton: entryColumn.index < listRoot.buttonRows
        onModelDataChanged: root.requestCover(entryColumn.modelData)
        Component.onCompleted: root.requestCover(entryColumn.modelData)
        width: ListView.view.width
        visible: !entryColumn.asButton
        height: entryColumn.asButton ? 0 : implicitHeight
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
          id: trackRow
          width: parent.width
          entry: entryColumn.modelData
          cursor: listRoot.markIndex === entryColumn.index
          actionsOnCursor: listRoot.role === "current"
          playingFile: root.playingFile
          libraryMark: !!listRoot.album && listRoot.album.owned[entryColumn.index] === true
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
  // left column once something is open, and the level's buttons under it.
  // The columns set one height for both, so their lists line up.
  component ColumnHeading: Item {
    id: heading
    property string title: ""
    property string subtitle: ""
    // An album's root.albumLibrary, for the line under its title.
    property var library: null
    property string cover: ""
    property bool showBack: false
    // The column (root.columnLevel) whose buttons it shows.
    property string role: "current"
    implicitHeight: headingTop.height + (headingButtons.visible ? Style.space(8) + headingButtons.implicitHeight : 0)

    Item {
      id: headingTop
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: Math.max(Style.space(44), headingBack.implicitHeight, headingLabels.implicitHeight)

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

        SubtitleLine {
          objectName: "headingLine:" + heading.role
          width: parent.width
          text: [heading.subtitle, headingButtons.elsewhere].filter(function(part) { return part !== "" }).join(" · ")
          library: heading.library
        }
      }
    }

    LevelButtons {
      id: headingButtons
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: headingTop.bottom
      anchors.topMargin: Style.space(8)
      role: heading.role
    }
  }

  // A level's buttons (root.levelButtons): Play, Add to queue, Add to
  // playlist. They wrap onto a second line where a column is too narrow, and
  // what Play stands for ("12 songs · 48:10") follows them where it fits
  // (else the heading's second line has it: elsewhere). The cursor on that
  // row (↑ from the first song) shows on the button Enter presses.
  component LevelButtons: Item {
    id: levelButtons
    property string role: "current"
    readonly property var buttons: root.levelButtons(levelButtons.role)
    readonly property string about: levelButtons.buttons.length > 0 ? levelButtons.buttons[0].about : ""
    property Item lastButton: null
    readonly property real aboutX: levelButtons.lastButton ? levelButtons.lastButton.x + levelButtons.lastButton.width + Style.space(10) : 0
    readonly property string elsewhere: levelButtons.about !== "" && !aboutText.visible ? levelButtons.about : ""
    visible: levelButtons.buttons.length > 0
    implicitHeight: visible ? buttonFlow.implicitHeight : 0

    Flow {
      id: buttonFlow
      objectName: "levelButtons:" + levelButtons.role
      width: parent.width
      spacing: Style.space(8)

      Repeater {
        model: levelButtons.buttons
        onItemAdded: function(index, item) { if (index === levelButtons.buttons.length - 1) levelButtons.lastButton = item }
        onItemRemoved: function(index, item) { if (levelButtons.lastButton === item) levelButtons.lastButton = null }

        Button {
          required property var modelData
          objectName: "levelButton:" + modelData.label
          text: modelData.label
          iconText: modelData.icon
          iconSize: fontSize
          bordered: true
          hasCursor: levelButtons.role === "current" && modelData.mode === "play" && root.cursorActive
            && root.cursorIndex === modelData.index
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          tooltipText: modelData.tip
          onClicked: {
            if (modelData.mode === "playlist") root.columnAddToPlaylist(levelButtons.role, modelData.index)
            else root.columnActivate(levelButtons.role, modelData.index, modelData.mode)
          }
        }
      }
    }

    Text {
      id: aboutText
      objectName: "levelAbout:" + levelButtons.role
      textFormat: Text.PlainText
      x: levelButtons.aboutX
      y: levelButtons.lastButton ? levelButtons.lastButton.y : 0
      height: levelButtons.lastButton ? levelButtons.lastButton.height : implicitHeight
      visible: levelButtons.about !== "" && !!levelButtons.lastButton && levelButtons.aboutX + implicitWidth <= levelButtons.width
      verticalAlignment: Text.AlignVCenter
      text: levelButtons.about
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // A heading's second line, and on an album, how much of it is in your
  // library at the right (root.albumLibrary), a link while a click can act.
  component SubtitleLine: Item {
    id: line
    property string text: ""
    property var library: null
    visible: line.text !== "" || !!line.library
    implicitHeight: Math.max(subtitleText.implicitHeight, libraryLink.implicitHeight)

    Text {
      id: subtitleText
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: libraryLink.visible ? libraryLink.left : parent.right
      anchors.rightMargin: libraryLink.visible ? Style.space(10) : 0
      anchors.verticalCenter: parent.verticalCenter
      text: line.text
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Text {
      id: libraryLink
      objectName: "albumLibrary"
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: !!line.library
      readonly property bool hot: libraryMouse.containsMouse && !!line.library && line.library.active
      text: !line.library ? "" : libraryLink.hot && line.library.hover ? line.library.hover : line.library.text
      color: line.library && line.library.state === "yes" && !libraryLink.hot ? Commons.Color.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.underline: libraryLink.hot

      MouseArea {
        id: libraryMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: line.library && line.library.active ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (line.library && line.library.active) root.libraryAlbum(root.browsing ? root.browseTop : root.previewEntry,
          root.browsing ? root.browseRows : root.previewRows)
      }
    }
  }

  // Above the list while browsing: Back, the cover (for an album), and what
  // is open, with its buttons under them.
  component BrowseHeading: Item {
    implicitHeight: browseTop.height + (browseButtons.visible ? Style.space(8) + browseButtons.implicitHeight : 0)

    Item {
      id: browseTop
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      // One height with or without a cover, so the popup keeps its size.
      height: Math.max(backButton.implicitHeight, Style.space(44), browseLabels.implicitHeight)

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

        SubtitleLine {
          objectName: "headingLine:current"
          width: parent.width
          text: [root.infoSubtitle(root.browseInfo), browseButtons.elsewhere].filter(function(part) { return part !== "" }).join(" · ")
          library: root.browseAlbumLibrary
        }
      }
    }

    LevelButtons {
      id: browseButtons
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: browseTop.bottom
      anchors.topMargin: Style.space(8)
    }
  }

  // The key hints, or the latest notice, in a fixed number of lines, so the
  // panel never changes height: hints that don't fit are left out (the keys
  // page has them all), and a notice too long is cut short.
  component HintLine: Item {
    id: hintLine
    property int lines: 1
    property alias horizontalAlignment: hintText.horizontalAlignment
    implicitHeight: root.captionLine * lines

    Text {
      id: hintText
      objectName: "hints"
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.notice !== "" ? root.notice
        : hintLine.width > 0 && root.captionLine > 0 ? Hints.fit(root.hintParts, hintLine.width - 1, hintLine.lines, root.captionWidth) : ""
      color: root.notice !== "" ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      elide: Text.ElideRight
      maximumLineCount: hintLine.lines
    }
  }

  FontMetrics {
    id: captionMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
  FontMetrics {
    id: bodyMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }
  readonly property int captionLine: Math.ceil(captionMetrics.lineSpacing)
  readonly property int bodyLine: Math.ceil(bodyMetrics.lineSpacing)
  function captionWidth(text) { return captionMetrics.advanceWidth(text) }

  // The keys in a window of their own (the keys page's Window, or w), to
  // keep beside the panel; RIGHT NOW follows the panel. Hyprland floats a
  // window whose size is fixed as it maps, centred, rather than tile it. So
  // it maps at a fixed size, then lets go of it after its first frame: it
  // can be resized, and opens again at the size it was.
  readonly property alias keysWindow: keysFloat
  function openKeysWindow() {
    root.keysOpen = false
    if (keysFloat.visible) return
    keysFloat.resizable = false
    root.showFloating(keysFloat)
  }
  function closeKeysWindow() { keysFloat.visible = false }

  FloatingWindow {
    id: keysFloat
    title: "omarock keys"
    visible: false
    color: Commons.Color.popups.background
    property size lastSize: Qt.size(Style.space(520), Style.space(720))
    property bool resizable: false
    readonly property size openSize: Qt.size(
      Math.min(lastSize.width, screen ? screen.width - Style.space(80) : lastSize.width),
      Math.min(lastSize.height, screen ? screen.height - Style.space(80) : lastSize.height))
    implicitWidth: openSize.width
    implicitHeight: openSize.height
    // Qt's own "no maximum" (QWINDOWSIZE_MAX), which it tells Wayland as none.
    minimumSize: resizable ? Qt.size(Style.space(320), Style.space(240)) : openSize
    maximumSize: resizable ? Qt.size(16777215, 16777215) : openSize
    onVisibleChanged: if (!visible) {
      keysFloat.lastSize = Qt.size(keysFloat.width, keysFloat.height)
      keysFloat.resizable = false
    }
    // Closed by Hyprland (Super+W): it's gone, but still visible to QML,
    // and w couldn't bring it back.
    onClosed: keysFloat.visible = false

    // The first frame is the map, which Hyprland has seen by the time
    // anything sent after it arrives.
    Connections {
      target: keysFloat.visible && !keysFloat.resizable ? keysWindowView.Window.window : null
      function onFrameSwapped() {
        keysFloat.resizable = true
        root.floatIfTiled(keysFloat.title)
      }
    }

    KeysHelp {
      id: keysWindowView
      objectName: "keysWindow"
      anchors.fill: parent
      anchors.margins: Style.space(16)
      windowed: true
      focus: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      version: root.version
      here: root.hereKeys
      onCloseRequested: root.closeKeysWindow()
    }
  }

  // A piece's setup window (Set up… on its tab of the settings, SetupView,
  // Setup.js): how the piece works, what it needs and where to get it, and
  // the fields for it. Start setup saves them (tools/omarock-account, over
  // stdin) and runs ./install PIECE in a terminal, with the window's choices
  // after it. The panel closes, so the window has the keys, and stays shut
  // while you go to the browser for keys. Like the keys window, it maps at
  // a fixed size, so Hyprland floats it, then can be resized.
  readonly property alias setupWindow: setupFloat
  function openSetupWindow(piece) {
    if (root.setupLaunched) {
      root.say("A setup is still running in its terminal")
      return
    }
    accountReader.running = true
    setupView.macs = []
    setupView.outputs = []
    setupView.defaultOutput = ""
    setupView.piece = piece
    setupView.reset()
    if (piece === "apple-music") tailnetReader.running = true
    if (piece === "sound") outputsReader.running = true
    root.close()
    if (!setupFloat.visible) {
      setupFloat.resizable = false
      root.showFloating(setupFloat)
    } else if (setupView.Window.window) {
      setupView.Window.window.requestActivate()
    }
  }
  // Closed or cancelled: what was typed goes, secrets first, and a Start
  // setup still saving runs nothing.
  function closeSetupWindow() {
    root.floatingNext = root.floatingNext.filter(function(w) { return w !== setupFloat })
    setupWriter.queue = []
    setupWriter.piece = ""
    setupView.piece = ""
    setupView.reset()
    setupFloat.visible = false
  }
  // Start setup: each value into its file, one at a time, then the terminal.
  // A value that can't be saved stops it there, and the window says why.
  function startSetup(writes, args) {
    setupWriter.piece = setupView.piece
    setupWriter.queue = writes
    setupWriter.args = args
    root.nextSetupWrite()
  }
  function nextSetupWrite() {
    if (setupWriter.running || setupWriter.piece === "") return
    if (setupWriter.queue.length === 0) {
      var piece = setupWriter.piece
      var args = setupWriter.args
      setupWriter.args = []
      root.closeSetupWindow()
      root.runSetup(piece, false, args)
      return
    }
    var next = setupWriter.queue[0]
    setupWriter.queue = setupWriter.queue.slice(1)
    setupWriter.secret = next[1]
    setupWriter.command = [root.accountTool, next[0]]
    setupWriter.running = true
  }

  FloatingWindow {
    id: setupFloat
    title: "omarock: " + (Setup.title(setupView.piece) || "set up")
    visible: false
    color: Commons.Color.popups.background
    property size lastSize: Qt.size(Style.space(640), Style.space(780))
    property bool resizable: false
    readonly property size openSize: Qt.size(
      Math.min(lastSize.width, screen ? screen.width - Style.space(80) : lastSize.width),
      Math.min(lastSize.height, screen ? screen.height - Style.space(80) : lastSize.height))
    implicitWidth: openSize.width
    implicitHeight: openSize.height
    minimumSize: resizable ? Qt.size(Style.space(420), Style.space(360)) : openSize
    maximumSize: resizable ? Qt.size(16777215, 16777215) : openSize
    onVisibleChanged: if (!visible) {
      setupFloat.lastSize = Qt.size(setupFloat.width, setupFloat.height)
      setupFloat.resizable = false
    }
    // Closed by Hyprland (Super+W), as Cancel.
    onClosed: root.closeSetupWindow()

    Connections {
      target: setupFloat.visible && !setupFloat.resizable ? setupView.Window.window : null
      function onFrameSwapped() {
        setupFloat.resizable = true
        root.floatIfTiled(setupFloat.title)
      }
    }

    SetupView {
      id: setupView
      objectName: "setupView"
      anchors.fill: parent
      anchors.margins: Style.space(18)
      foreground: root.foreground
      fontFamily: root.fontFamily
      known: root.accounts
      host: root.clientName
      onStartRequested: function(writes, args) { root.startSetup(writes, args) }
      onCloseRequested: root.closeSetupWindow()
    }
  }

  // omarock's own windows (the setup windows, the keys) float, centred, from
  // their first frame: a rule of their own, added to the running Hyprland
  // just before one shows, as Omarchy adds its About window's (a config
  // reload drops it). Their size is fixed as they map too, which Hyprland
  // also floats. Should one tile anyway, a moment after it opens it's
  // floated and centred, as Omarchy's own scripts do it: the Lua
  // dispatcher, else the old one.
  readonly property string windowRule: 'if omarock_window_rule then omarock_window_rule:set_enabled(false) end; '
    + 'omarock_window_rule = hl.window_rule({ match = { class = "^org.quickshell$", title = "^omarock(: Set up .*| keys)$" }, '
    + 'float = true, center = true })'
  property var floatingNext: []
  function showFloating(window) {
    root.floatingNext = root.floatingNext.concat([window])
    if (!windowRuler.running) windowRuler.running = true
  }
  Process {
    id: windowRuler
    command: ["sh", "-c", 'hyprctl eval "$1" >/dev/null 2>&1; exit 0', "sh", root.windowRule]
    onExited: {
      var windows = root.floatingNext
      root.floatingNext = []
      windows.forEach(function(w) { w.visible = true })
    }
  }
  function floatIfTiled(title) {
    windowFloater.title = title
    floatCheck.restart()
  }
  Timer {
    id: floatCheck
    interval: 400
    onTriggered: if (!windowFloater.running) windowFloater.running = true
  }
  Process {
    id: windowFloater
    property string title: ""
    command: ["sh", "-c", 'w=$(hyprctl clients -j 2>/dev/null | jq -r --arg t "$1" '
      + '\'first(.[] | select(.title == $t and (.floating | not)) | .address) // empty\' 2>/dev/null); [ -n "$w" ] || exit 0; '
      + 'hyprctl dispatch "hl.dsp.window.float({ action = \\"on\\", window = \\"address:$w\\" })" >/dev/null 2>&1 '
      + '|| hyprctl dispatch setfloating "address:$w" >/dev/null 2>&1; '
      + 'hyprctl dispatch "hl.dsp.window.center({ window = \\"address:$w\\" })" >/dev/null 2>&1 '
      + '|| hyprctl dispatch centerwindow >/dev/null 2>&1; exit 0', "sh", windowFloater.title]
  }

  // Saves the setup window's values (startSetup), one at a time, each over
  // stdin, never on a command line.
  Process {
    id: setupWriter
    property string piece: ""
    property var queue: []
    property var args: []
    property string secret: ""
    stdinEnabled: true
    stderr: StdioCollector { id: setupWriterErrors; waitForEnd: true }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        setupWriter.queue = []
        setupView.busy = false
        setupView.notice = "Couldn't save it: " + (String(setupWriterErrors.text || "").trim().split("\n")[0] || "no reason given")
        accountReader.running = true
        return
      }
      Qt.callLater(root.nextSetupWrite)
    }
  }

  // The tailnet's Macs, for Apple Music's setup window: none without Tailscale.
  Process {
    id: tailnetReader
    command: ["sh", "-c", "command -v tailscale >/dev/null && tailscale status --json 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: setupView.macs = Setup.tailnetMacs(text)
    }
  }

  // PipeWire's outputs and the default one, for the sound output's setup
  // window: the default on the first line, then the outputs as JSON.
  Process {
    id: outputsReader
    command: ["sh", "-c", "printf '%s\\n' \"$(pactl get-default-sink 2>/dev/null)\"; pactl -f json list sinks 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var at = text.indexOf("\n")
        setupView.outputs = Setup.outputList(at < 0 ? "" : text.slice(at + 1))
        setupView.defaultOutput = at < 0 ? "" : text.slice(0, at).trim()
      }
    }
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
          brief: true
          anchors.left: compactIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: compactChip.visible ? compactChip.left : compactSource.visible ? compactSource.left : expandButton.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
        }

        TimeMachineChip {
          id: compactChip
          brief: true
          anchors.right: compactSource.visible ? compactSource.left : expandButton.left
          anchors.rightMargin: Style.space(8)
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
          // Its icon alone beside Time Machine's chip, so omarock's name fits.
          text: compactChip.visible ? "" : "Expand"
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
        active: root.opened
        canOpenAlbum: root.cardAlbumLink
        canOpenArtist: root.cardArtistLink
        canOpenTitle: root.cardTitleLink
        canOpenGenre: root.cardGenreLink
        focusedLink: root.cardFocus
        foreground: root.foreground
        fontFamily: root.fontFamily
        onOpenAlbum: root.openPlaying("album")
        onOpenArtist: root.openPlaying("artist")
        onOpenTitle: root.lookUp("song")
        onOpenGenre: root.openPlaying("genre")
        libraryText: root.playingLibraryText
        libraryHoverText: root.playingLibraryHover
        libraryActive: root.librarySaving === "" && (root.playingLibrary !== "yes" || root.bridge.canUnsave)
        canAddToPlaylist: root.canAddPlayingToPlaylist
        onLibraryClicked: root.libraryPlaying()
        onAddToPlaylist: root.addPlayingToPlaylist()
      }

      PanelSeparator { foreground: root.foreground }

      SearchBox { width: parent.width }

      QueueHeading {
        id: compactQueueHeading
        width: parent.width
        visible: !root.searchMode && !root.browsing
      }

      BrowseHeading {
        id: compactBrowseHeading
        width: parent.width
        visible: root.browsing
      }

      TrackList {
        width: parent.width
        // What the heading above takes comes out of the list, so the panel
        // is the same height on the queue, in search and browsing; and so
        // does the hints' second line, so it's as tall as it was with one.
        height: Style.space(310) - root.captionLine
          - (compactQueueHeading.visible ? compactQueueHeading.height + parent.spacing : 0)
          - (compactBrowseHeading.visible ? compactBrowseHeading.height + parent.spacing : 0)
      }

      PanelSeparator { foreground: root.foreground }

      HintLine {
        width: parent.width
        lines: 2
      }
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
          objectName: "headerButtons"
          anchors.right: parent.right
          anchors.verticalCenter: expandedIcon.verticalCenter
          spacing: Style.space(10)

          TimeMachineChip {
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: compactButton.implicitHeight
          }

          SourceSwitch { anchors.verticalCenter: parent.verticalCenter }

          Button {
            objectName: "settingsButton"
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰒓"
            iconSize: fontSize
            implicitHeight: compactButton.implicitHeight
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            tooltipText: "Settings (,)"
            onClicked: root.openSettings()
          }

          Button {
            id: compactButton
            anchors.verticalCenter: parent.verticalCenter
            text: "Compact"
            iconText: "󰊔"
            iconSize: fontSize
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
        active: root.opened
        canOpenAlbum: root.cardAlbumLink
        canOpenArtist: root.cardArtistLink
        canOpenTitle: root.cardTitleLink
        canOpenGenre: root.cardGenreLink
        focusedLink: root.cardFocus
        foreground: root.foreground
        fontFamily: root.fontFamily
        onOpenAlbum: root.openPlaying("album")
        onOpenArtist: root.openPlaying("artist")
        onOpenTitle: root.lookUp("song")
        onOpenGenre: root.openPlaying("genre")
        libraryText: root.playingLibraryText
        libraryHoverText: root.playingLibraryHover
        libraryActive: root.librarySaving === "" && (root.playingLibrary !== "yes" || root.bridge.canUnsave)
        canAddToPlaylist: root.canAddPlayingToPlaylist
        onLibraryClicked: root.libraryPlaying()
        onAddToPlaylist: root.addPlayingToPlaylist()
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
        // Both headings as tall as the taller, so the lists line up.
        readonly property real headingHeight: Math.max(leftHeading.implicitHeight, rightHeading.implicitHeight)
        readonly property var parentInfo: root.browseStack.length >= 2
          ? root.browseStack[root.browseStack.length - 2].info
          : root.browseRoot === "queue" ? { title: "Queue", subtitle: root.queueSummary, coverFile: "" }
          : { title: "Results", subtitle: "“" + root.query.trim() + "”", coverFile: "" }

        ColumnHeading {
          id: leftHeading
          anchors.left: parent.left
          anchors.top: parent.top
          width: columnsArea.columnWidth
          height: columnsArea.headingHeight
          role: root.browsing ? "parent" : ""
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
          height: columnsArea.headingHeight
          role: root.browsing ? "current" : "preview"
          title: root.browsing ? (root.browseInfo.title || "") : (root.previewInfo.title || "")
          subtitle: root.infoSubtitle(root.browsing ? root.browseInfo : root.previewInfo)
          library: root.browsing ? root.browseAlbumLibrary : root.previewAlbumLibrary
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
        color: Style.normalFillFor(root.foreground, Commons.Color.accent)
        borderSpec: Border.controlSpec("normal", root.foreground, Commons.Color.accent)

        Item {
          id: footerRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(12)
          anchors.rightMargin: Style.space(12)
          // A line of each, whatever the song's title needs (another
          // script's font can be taller).
          implicitHeight: Math.max(root.bodyLine, footerHints.implicitHeight)

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

          HintLine {
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
