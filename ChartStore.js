.pragma library
// Time Machine's charts and their songs as found (ChartClient), shared by
// every omarock panel in the shell, one for each bar: a chart one panel is
// looking up fills in on another too, and isn't looked up twice.

// year -> the chart, once read.
var charts = {}
// "service:year" -> { rank: the service's Song, or null for none }.
var found = {}
// "service:year" -> { looking, stop, owner (the ChartClient looking), error,
// read (the cache was tried) }.
var states = {}

var clients = []

function listen(client) {
  clients.push(client)
}

// A ChartClient going (a plugin reload): its lookups end with it, so
// another may start them again.
function forget(client) {
  clients = clients.filter(function(c) { return c !== client })
  for (var key in states) if (states[key].owner === client) states[key].looking = false
}

// Something new to show, in every panel.
function tell() {
  clients.forEach(function(c) { if (c && typeof c.changed === "function") c.changed() })
}
