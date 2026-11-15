.pragma library
// Remote cover art as tools/omarock-art answered for it (ArtCache), shared by
// every omarock panel in the shell, one for each bar: a cover one panel has
// fetched shows on the others too, and isn't fetched twice.

// url -> { file: the file:// URL to show, "" for a refusal; why: the
// refusal's reason; until: when to ask again (ms; 0, not this session) }.
var answers = {}
// url -> the ArtCache fetching it.
var pending = {}

var clients = []

function listen(client) {
  clients.push(client)
}

// An ArtCache going (a plugin reload): what it was fetching, another may.
function forget(client) {
  clients = clients.filter(function(c) { return c !== client })
  for (var url in pending) if (pending[url] === client) delete pending[url]
  tell()
}

// Something new to show, in every panel.
function tell() {
  clients.forEach(function(c) { if (c && typeof c.changed === "function") c.changed() })
}
