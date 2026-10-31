// omarock's settings: what each one is, the tabs and groups the settings
// screen shows them in, and how a value is found. The values live in omarock's own file,
// ~/.config/omarock/settings.json; one not in it falls back to the widget's
// entry in Omarchy's shell.json (where omarock kept them before 0.6), then
// to its default here.
//
// Most rows are settings in that file. A few are kept elsewhere, and the
// settings screen hands them to the panel instead of saving them:
//   "account" and "secret": a login or a key, in its own file in
//     ~/.config/omarock (tools/omarock-account); a secret is never shown;
//   "action": a button (signing in to Spotify, setting a source up);
//     a field can have one too, beside it (`button`, and `action`, the key
//     the panel is handed);
//   "folder": mpd's music folder, in mpd.conf (changed after asking).
//
// A few settings are in the file only, never on the screen: `socket`
// (mpd's, which ./install sets when mpd listens somewhere else);
// `appleBridge` and `appleStream`, which override apple.json (./install
// apple-music writes that); `appleRejoin` (default on: reconnect mpd to the
// Apple Music stream after each change, which only a bridge before 0.7.0
// needs); `appleStreamLag` (1.9), how far behind the Apple Music stream mpd
// is taken to play until omarock has measured it (the harness sets 0: its
// fake mpd isn't behind); `timeMachineYear`, the year Time
// Machine's button picked (0 or none: off); `radioState`, the US state
// "Your area" replaced (still read while radioArea is empty); `timeZone`,
// the time zone that says which country an area is likelier in (else the
// machine's: the harness sets it); `historyAfter`, a test's: a play counts
// for History after that many seconds; `streamRetryFor` (300), how long
// a live stream that lost its connection is played again before omarock
// gives up; and the addresses the test
// harness points at its fakes, `spotifyService`, `sxmService`, `radioBrowser`,
// `chartSource` (Wikipedia, for Time Machine's charts) and `appleTokenFile`.
// Panel.qml gives each its default.
//
// Spotify, SiriusXM, Apple Music and omarock's sound output are each set up
// on their own: a button opens the piece's setup window (Setup.js), which
// takes what it needs, then runs ./install PIECE in a terminal. A
// "source" row is that piece's button until it's set up, then its switch
// (or, for the sound output, which has no switch, a line saying where it
// plays). The piece's other rows show only once it's set up: its settings,
// an Update or Fix button when it needs one, and Remove. Pure functions, so
// node can test them (tests/settings.test.js).

var schema = [
  { key: "localSetUp", type: "action", label: "Set up your music", button: "Set up…", source: "local", when: "missing",
    description: "mpd plays everything omarock plays, and omarock can't reach it. This sets it up, in a terminal: mpd, and where your music is." },
  { key: "musicFolder", type: "folder", label: "Your music folder",
    description: "Where mpd finds your music. Changing it restarts mpd (after asking) and reads the new folder." },
  { key: "radio", type: "boolean", label: "Internet radio", defaultValue: true,
    description: "Stations from Radio Browser, played by mpd. Nothing to set up." },
  { key: "radioArea", type: "string", label: "Your area", defaultValue: "",
    description: "For the radio's local stations: your city, or your state, region or country, such as Portland, Maine or Manchester, UK. Stations within 80 km (50 miles) come first, from the states and countries next door too. Found on this machine, from GeoNames' places." },
  { key: "lookup", type: "enum", label: "Look up songs in", options: ["Apple Music", "Spotify"],
    defaultValue: "Apple Music",
    description: "Click a song or artist playing on SiriusXM or the radio to find it there, while the station plays on. Time Machine's Top 100 plays there too, away from Apple Music and Spotify. The other one if this one is off." },

  { key: "history", type: "boolean", label: "Keep a history of what you play", defaultValue: true,
    description: "H lists what you've played here, from every source, by day: a song once you've heard half of it or 4 minutes, a station's after 30 s. It stays on this machine (~/.local/share/omarock/history.jsonl)." },
  { key: "historyDays", type: "integer", label: "Days of history to keep", min: 1, max: 90, step: 1, defaultValue: 7,
    description: "Older plays come out of it." },
  { key: "historyClear", type: "action", label: "Clear the history", button: "Clear…",
    description: "Forget everything played so far (asks first)." },

  { key: "timeMachine", type: "boolean", label: "Time Machine", defaultValue: false,
    description: "A Time Machine button at the top of the panel: enter a year, and only music from then or before shows, with that year's Top 100 from Billboard (as Wikipedia lists it). Songs from after it come out of the queue." },

  { key: "spotify", type: "source", source: "spotify", name: "Spotify", label: "Spotify", defaultValue: false,
    description: "Played here by Spotify's own player. Off stops it, and keeps your accounts and keys.",
    setUpDescription: "Needs Spotify Premium, and a free Spotify developer app. Set up shows what to do and takes the app's keys, then finishes in a terminal." },
  { key: "spotifyUpdate", type: "action", source: "spotify", name: "Spotify", when: "fix",
    updateDescription: "omarock was updated, and its Spotify service has changes to install. Update does it, in a terminal: Spotify stops for a moment if it's playing." },
  { key: "spotifyClient", type: "account", label: "Your Spotify app's Client ID", source: "spotify",
    description: "From your app in Spotify's developer dashboard (spotify/README.md)." },
  { key: "soloistKey", type: "secret", label: "The Soloist key", source: "spotify",
    description: "From the same dashboard, never shown. Saving it restarts Soloist." },
  { key: "spotifyLogin", type: "action", label: "Sign in to Spotify", button: "Sign in", source: "spotify",
    description: "For search and your library: Spotify's sign-in, in your browser. It lasts six months.",
    signedIn: { label: "Signed in to Spotify", button: "Sign out",
      description: "For search and your library. Signing out leaves Spotify's player paired to your account; Remove takes everything off." } },
  { key: "spotifyRemove", type: "action", label: "Remove Spotify", button: "Remove…", source: "spotify", remove: true,
    description: "Stops and deletes its services, with your app's Client ID, the Soloist key and the sign-ins. Set up brings it back." },

  { key: "siriusXM", type: "source", source: "sxm", name: "SiriusXM", label: "SiriusXM", defaultValue: false,
    description: "SiriusXM's live channels, played by mpd. Off stops it, and keeps your login.",
    setUpDescription: "Needs a SiriusXM subscription with streaming. Unofficial: it signs in as SiriusXM's web player does, which SiriusXM's terms forbid. Set up explains it and takes your login, then finishes in a terminal." },
  { key: "sxmUpdate", type: "action", source: "sxm", name: "SiriusXM", when: "fix",
    updateDescription: "omarock was updated, and its SiriusXM service has changes to install. Update does it, in a terminal: a channel playing stops for a moment." },
  { key: "sxmUser", type: "account", label: "SiriusXM email or username", source: "sxm" },
  { key: "sxmPassword", type: "secret", label: "SiriusXM password", source: "sxm",
    description: "Kept for omarock-sxm only, and never shown. Saving it signs in again." },
  { key: "sxmRemove", type: "action", label: "Remove SiriusXM", button: "Remove…", source: "sxm", remove: true,
    description: "Stops and deletes omarock-sxm, with your SiriusXM login. Set up brings it back." },

  { key: "appleMusic", type: "source", source: "apple", name: "Apple Music", label: "Apple Music", defaultValue: false,
    description: "Played on your Mac by omarock's bridge, and heard here. Off keeps the bridge's address and token.",
    setUpDescription: "Needs a Mac running omarock's bridge: on the Mac, ./install in omarock's clone sets it up (with your Apple Developer membership). Set up then connects this machine to it." },
  { key: "appleUpdate", type: "action", source: "apple", name: "Apple Music", when: "fix" },
  { key: "bridgeToken", type: "secret", label: "The bridge's token", source: "apple",
    button: "Copy with ssh", action: "bridgeTokenCopy",
    description: "Paste it, or copy it from the Mac (needs its Remote Login)." },
  { key: "appleIdleStop", type: "integer", label: "Let go of the stream when the Mac is paused", source: "apple",
    min: 0, max: 3600, step: 10, defaultValue: 60, description: "After this many seconds (0: never)." },
  { key: "appleRemove", type: "action", label: "Remove Apple Music", button: "Remove…", source: "apple", remove: true,
    description: "Deletes the bridge's address and token here, and the patched builds for its stream. The bridge on your Mac remains." },

  { key: "sound", type: "source", source: "sound", name: "omarock's sound output", label: "omarock's sound output", switchless: true,
    description: "Everything omarock plays goes into one output, with one volume, and never moves to another.",
    setUpDescription: "Optional, and most don't need it: everything omarock plays goes into one output you pick, with one volume, and never moves to another. It matters when some output must never carry music (a radio transmitter's audio interface, say)." },
  { key: "soundUpdate", type: "action", source: "sound", name: "omarock's sound output", when: "fix",
    updateDescription: "omarock was updated, and its sound output has changes to install. Update does it, in a terminal: the music stops for a moment." },
  { key: "soundRemove", type: "action", label: "Remove omarock's sound output", button: "Remove…", source: "sound", remove: true,
    description: "omarock then plays into your default output, and follows it when that changes." },

  { key: "topSongs", type: "enum", label: "An artist's top songs", options: ["At the top", "At the bottom"],
    defaultValue: "At the top",
    description: "On Apple Music's and Spotify's artist pages: above the albums, or below them. Play top songs stays at the top." },
  { key: "closeOnLeave", type: "boolean", label: "Close the panel when the pointer leaves it", defaultValue: true,
    description: "3 seconds after it leaves, unless it comes back." },
  { key: "maxLabelWidth", type: "integer", label: "How wide the song gets on the bar",
    min: 80, max: 600, step: 10, defaultValue: 300, description: "In pixels." },
  { key: "scrollBarSong", type: "boolean", label: "Scroll a long song on the bar", defaultValue: false,
    description: "Wider than that, it scrolls now and then instead of ending in …. In the panel, a long song always scrolls." }
]

// The settings screen's tabs, and the groups on each. A tab with one group
// needs no heading: the tab names it.
var tabs = ["omarock", "Apple Music", "SiriusXM", "Spotify", "Sound"]

var groups = [
  { tab: "omarock", title: "YOUR MUSIC AND THE RADIO", keys: ["localSetUp", "musicFolder", "radio", "radioArea", "lookup"] },
  { tab: "omarock", title: "HISTORY", keys: ["history", "historyDays", "historyClear"] },
  { tab: "omarock", title: "TIME MACHINE", keys: ["timeMachine"] },
  { tab: "omarock", title: "THE PANEL AND THE BAR", keys: ["topSongs", "closeOnLeave", "maxLabelWidth", "scrollBarSong"] },
  { tab: "Apple Music", title: "", keys: ["appleMusic", "appleUpdate", "bridgeToken", "appleIdleStop", "appleRemove"] },
  { tab: "SiriusXM", title: "", keys: ["siriusXM", "sxmUpdate", "sxmUser", "sxmPassword", "sxmRemove"] },
  { tab: "Spotify", title: "", keys: ["spotify", "spotifyUpdate", "spotifyClient", "soloistKey", "spotifyLogin", "spotifyRemove"] },
  { tab: "Sound", title: "", keys: ["sound", "soundUpdate", "soundRemove"] }
]

// The piece ./install sets up for a row's source, and back.
var pieces = { local: "", spotify: "spotify", sxm: "siriusxm", apple: "apple-music", sound: "sound" }

// The settings kept in settings.json (not accounts, actions or the folder).
// A source's switch is one; the sound output's row has none.
function stored(field) {
  return field.type === "boolean" || field.type === "string" || field.type === "integer" || field.type === "enum"
    || (field.type === "source" && !field.switchless)
}

var defaults = (function() {
  var out = {}
  schema.forEach(function(field) { if (stored(field)) out[field.key] = field.defaultValue })
  return out
})()

// A setting's value: settings.json's, else the widget's in shell.json, else
// fallback (or its default).
function value(file, widget, key, fallback) {
  var v = file ? file[key] : undefined
  if (v === undefined || v === null) v = widget ? widget[key] : undefined
  if (v === undefined || v === null) v = fallback !== undefined ? fallback : defaults[key]
  return v
}

// The settings file's text as settings: an object, else none.
function parse(text) {
  try {
    var parsed = JSON.parse(text || "{}")
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed
  } catch (e) {}
  return {}
}

// The settings with one changed, as a new object.
function withValue(file, key, v) {
  var out = {}
  for (var k in (file || {})) out[k] = file[k]
  out[key] = v
  return out
}

function copy(field, changes) {
  var out = {}
  for (var k in field) out[k] = field[k]
  for (var c in changes) out[c] = changes[c]
  return out
}

// The rows to show, as the pieces are now. states: per source (local,
// spotify, sxm, apple, sound) { setUp, update, attention }: set up or not,
// an update waiting, and what's wrong (or "").
//   - a source row: Set up… until it's set up, then its switch (the sound
//     output: a line, with no control);
//   - the source's other rows: once it's set up;
//   - its Update or Fix row: once set up, while it needs one (Fix, when
//     something's wrong, comes before Update);
//   - local music's Set up: only while mpd can't be reached.
function shown(states) {
  states = states || {}
  var out = []
  schema.forEach(function(field) {
    var st = field.source ? (states[field.source] || {}) : {}
    if (field.type === "source") {
      if (st.setUp) out.push(copy(field, { type: field.switchless ? "info" : "boolean" }))
      else out.push(copy(field, { type: "action", button: "Set up…", description: field.setUpDescription }))
    } else if (field.when === "missing") {
      if (!st.setUp) out.push(field)
    } else if (field.when === "fix") {
      if (!st.setUp || !(st.attention || st.update)) return
      // detail: what the tab's dot says on hover.
      out.push(st.attention
        ? copy(field, { label: "Set " + field.name + " up again", button: "Fix…", detail: field.name + ": " + st.attention,
          description: "Runs its setup again, in a terminal: it carries on with whatever's missing." })
        : copy(field, { label: "Update " + field.name, button: "Update…", detail: field.name + ": an update is waiting",
          description: st.update === true ? field.updateDescription : st.update }))
    } else if (!field.source || st.setUp) {
      out.push(field.signedIn && st.signedIn ? copy(field, field.signedIn) : field)
    }
  })
  return out
}

if (typeof module !== "undefined") {
  module.exports = { schema: schema, tabs: tabs, groups: groups, pieces: pieces, defaults: defaults, stored: stored, value: value,
    parse: parse, withValue: withValue, shown: shown }
}
