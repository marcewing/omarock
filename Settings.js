// omarock's settings: what each one is, the groups the settings screen shows
// them in, and how a value is found. The values live in omarock's own file,
// ~/.config/omarock/settings.json; one not in it falls back to the widget's
// entry in Omarchy's shell.json (where omarock kept them before 0.6), then
// to its default here.
//
// Most rows are settings in that file. A few are kept elsewhere, and the
// settings screen hands them to the panel instead of saving them:
//   "account" and "secret": a login or a key, in its own file in
//     ~/.config/omarock (tools/omarock-account); a secret is never shown;
//   "action": a button (signing in to Spotify);
//   "folder": mpd's music folder, in mpd.conf (changed after asking).
// A row with a source shows only while that source is switched on. Pure
// functions, so node can test them (tests/settings.test.js).

var schema = [
  { key: "radio", type: "boolean", label: "Internet radio", defaultValue: true,
    description: "Stations from Radio Browser, played by mpd. Nothing to set up." },
  { key: "radioState", type: "string", label: "Your US state", defaultValue: "",
    description: "For the radio's local stations: a state's name, such as Maine." },
  { key: "spotify", type: "boolean", label: "Spotify", defaultValue: false,
    description: "Needs Spotify Premium and the omarock-spotify service (spotify/README.md)." },
  { key: "appleMusic", type: "boolean", label: "Apple Music", defaultValue: false,
    description: "Needs the omarock bridge on a Mac (bridge/README.md)." },
  { key: "siriusXM", type: "boolean", label: "SiriusXM", defaultValue: false,
    description: "Needs a SiriusXM subscription and the omarock-sxm service (sxm/README.md). Unofficial." },
  { key: "lookup", type: "enum", label: "Look up the radio's songs in", options: ["Apple Music", "Spotify"],
    defaultValue: "Apple Music",
    description: "Click a song or artist playing on SiriusXM or the radio to find it there, while the station plays on. The other one if this one is off." },

  { key: "musicFolder", type: "folder", label: "Your music folder",
    description: "Where mpd finds your music. Changing it restarts mpd (after asking) and reads the new folder." },

  { key: "sxmUser", type: "account", label: "SiriusXM email or username", source: "sxm" },
  { key: "sxmPassword", type: "secret", label: "SiriusXM password", source: "sxm",
    description: "Kept for omarock-sxm only, and never shown. Saving it signs in again." },

  { key: "spotifyClient", type: "account", label: "Your Spotify app's Client ID", source: "spotify",
    description: "From your app in Spotify's developer dashboard (spotify/README.md)." },
  { key: "soloistKey", type: "secret", label: "The Soloist key", source: "spotify",
    description: "From the same dashboard, never shown. Saving it restarts Soloist." },
  { key: "spotifyLogin", type: "action", label: "Sign in to Spotify", button: "Sign in", source: "spotify",
    description: "For search and your library: Spotify's sign-in, in your browser. Pairing your phone is ./install's, as it opens the firewall for a moment." },

  { key: "appleBridge", type: "string", label: "The bridge's address", defaultValue: "",
    description: "Empty: the one in ~/.config/omarock/apple.json." },
  { key: "appleStream", type: "string", label: "The stream's address", defaultValue: "",
    description: "What mpd plays. Empty: the one in ~/.config/omarock/apple.json." },
  { key: "bridgeToken", type: "secret", label: "The bridge's token", source: "apple",
    description: "On the Mac: pbcopy < ~/Library/Application\\ Support/omarock-bridge/token, then paste it here. Never shown." },
  { key: "appleIdleStop", type: "integer", label: "Let go of the stream when the Mac is paused",
    min: 0, max: 3600, step: 10, defaultValue: 60, description: "After this many seconds (0: never)." },
  { key: "appleRejoin", type: "boolean", label: "Reconnect after each change", defaultValue: true,
    description: "Needed with a stock libFLAC, which falls behind on the Mac's quiet stream; it costs a short stutter 2 s into each song. Turn it off once mpd uses the patched libFLAC (patches/README.md)." },

  { key: "closeOnLeave", type: "boolean", label: "Close the panel when the pointer leaves it", defaultValue: true },
  { key: "maxLabelWidth", type: "integer", label: "How wide the song gets on the bar",
    min: 80, max: 600, step: 10, defaultValue: 300, description: "In pixels." },
  { key: "tuiCommand", type: "string", label: "Terminal player", defaultValue: "ncmpcpp",
    description: "What t and the TUI button open." },

  { key: "socket", type: "string", label: "mpd's socket", defaultValue: "",
    description: "Empty: $XDG_RUNTIME_DIR/mpd/socket." },
  { key: "spotifyService", type: "string", label: "omarock-spotify's address", defaultValue: "",
    description: "Empty: http://127.0.0.1:8730." },
  { key: "sxmService", type: "string", label: "omarock-sxm's address", defaultValue: "",
    description: "Empty: http://127.0.0.1:8720." },
  { key: "radioBrowser", type: "string", label: "Radio Browser server", defaultValue: "",
    description: "Empty: one of its servers, picked at random." },
  { key: "appleTokenFile", type: "string", label: "The bridge's token file", defaultValue: "",
    description: "Empty: ~/.config/omarock/bridge-token." }
]

var groups = [
  { title: "SOURCES", keys: ["radio", "radioState", "spotify", "appleMusic", "siriusXM", "lookup"] },
  { title: "YOUR MUSIC", keys: ["musicFolder"] },
  { title: "SIRIUSXM", keys: ["sxmUser", "sxmPassword"] },
  { title: "SPOTIFY", keys: ["spotifyClient", "soloistKey", "spotifyLogin"] },
  { title: "APPLE MUSIC", keys: ["appleBridge", "appleStream", "bridgeToken", "appleIdleStop", "appleRejoin"] },
  { title: "THE PANEL AND THE BAR", keys: ["closeOnLeave", "maxLabelWidth", "tuiCommand"] },
  { title: "ADVANCED", keys: ["socket", "spotifyService", "sxmService", "radioBrowser", "appleTokenFile"] }
]

// The settings kept in settings.json (not accounts, actions or the folder).
function stored(field) {
  return field.type === "boolean" || field.type === "string" || field.type === "integer" || field.type === "enum"
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

// The rows to show: a row with a source only while it's switched on
// (sources: { sxm: true, spotify: false, apple: true }).
function shown(sources) {
  return schema.filter(function(field) { return !field.source || sources[field.source] === true })
}

if (typeof module !== "undefined") {
  module.exports = { schema: schema, groups: groups, defaults: defaults, stored: stored, value: value,
    parse: parse, withValue: withValue, shown: shown }
}
