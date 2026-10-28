import QtQuick
import Quickshell.Io
import "TimeMachine.js" as TimeMachine
import "ChartStore.js" as Store

// Time Machine's Top 100: Billboard's year-end chart, read from Wikipedia's
// page for the year (TimeMachine.parseChart), and its songs found on Apple
// Music or Spotify, a search for each (TimeMachine.bestMatch). Both are kept
// in ~/.cache/omarock/charts, so a year looked up once opens at once, and
// shared by the panels (ChartStore.js).
Item {
  id: root

  // Wikipedia, or the harness's stand-in.
  property string source: "https://en.wikipedia.org"
  property string cacheDir: ""
  // Searches in flight at once: Apple Music's, and Spotify's (its Web API
  // allows a development app fewer calls).
  property int parallel: 3
  property int spotifyParallel: 2

  // Something new to show: a chart read, a song found (in any panel).
  signal changed()

  Component.onCompleted: Store.listen(root)
  Component.onDestruction: Store.forget(root)

  readonly property string userAgent: "omarock (https://github.com/marcewing/omarock)"

  function chartOf(year) { return Store.charts[year] || [] }
  function foundFor(service, year) { return Store.found[service + ":" + year] || ({}) }
  function stateOf(service, year) { return Store.states[service + ":" + year] || ({}) }

  // The chart for a year; callback(chart, error).
  function chart(year, callback) {
    if (Store.charts[year]) { callback(Store.charts[year], ""); return }
    root.readCache(year + ".json", function(data) {
      if (data && data.chart && data.chart.length > 0) {
        Store.charts[year] = data.chart
        callback(data.chart, "")
        return
      }
      root.fetchChart(year, callback)
    })
  }

  function fetchChart(year, callback) {
    var page = TimeMachine.chartPage(year)
    var url = root.source + "/w/api.php?action=parse&format=json&formatversion=2&redirects=1&prop=wikitext&page="
      + encodeURIComponent(page)
    var request = new XMLHttpRequest()
    var timeout = Qt.createQmlObject("import QtQuick; Timer { interval: 20000 }", root)
    timeout.triggered.connect(function() { request.abort() })
    request.onreadystatechange = function() {
      // Gone with a plugin reload, as in the other clients.
      if (request.readyState !== XMLHttpRequest.DONE || !root || typeof root.fetchChart !== "function") return
      timeout.destroy()
      var data = null
      try { data = request.responseText ? JSON.parse(request.responseText) : null } catch (e) {}
      if (request.status === 0) { callback(null, "Can't reach Wikipedia for " + year + "'s chart"); return }
      if (data && data.error)
        return callback(null, data.error.code === "missingtitle" ? "Wikipedia has no page for " + year + "'s chart"
          : "Wikipedia said: " + (data.error.info || data.error.code))
      var chart = data && data.parse ? TimeMachine.parseChart(data.parse.wikitext) : []
      if (chart.length < 10) { callback(null, "Couldn't read " + year + "'s chart on Wikipedia (" + page + ")"); return }
      Store.charts[year] = chart
      root.writeCache(year + ".json", { page: page, chart: chart })
      callback(chart, "")
    }
    request.open("GET", url)
    // Wikipedia asks API clients to say who they are.
    request.setRequestHeader("Api-User-Agent", root.userAgent)
    request.send()
    timeout.start()
  }

  // Look for the chart's songs on target (an AppleClient), those not known
  // yet, a few at a time; changed() as each is found.
  function findSongs(year, target) {
    var key = target.serviceKey + ":" + year
    var state = Store.states[key] || (Store.states[key] = { looking: false, error: "", read: false })
    if (state.looking) {
      // Stopping for another year, and wanted again: on it goes.
      state.stop = false
      return
    }
    var chart = root.chartOf(year)
    if (chart.length === 0) return
    state.looking = true
    state.stop = false
    state.owner = root
    state.error = ""
    function go() {
      var have = Store.found[key] || (Store.found[key] = {})
      var left = chart.filter(function(entry) { return have[entry.rank] === undefined })
      var running = 0
      var failures = 0
      if (left.length === 0) {
        state.looking = false
        Store.tell()
        return
      }
      Store.tell()
      function finished() {
        state.looking = false
        if (failures > 0) state.error = failures + " didn't answer: open it again to try them again"
        root.writeCache(key.replace(":", "-") + ".json", { found: have })
        Store.tell()
      }
      function next() {
        // A plugin reload, mid-search.
        if (!root || typeof root.findSongs !== "function") return
        if (left.length === 0 || state.stop) {
          if (running === 0) finished()
          return
        }
        var entry = left.shift()
        running++
        root.lookUp(target, entry, year, function(song, error) {
          running--
          if (error !== "") failures++
          else have[entry.rank] = song ? TimeMachine.keep(song) : null
          Store.tell()
          next()
        })
      }
      var lanes = target.serviceKey === "spotify" ? root.spotifyParallel : root.parallel
      for (var i = 0; i < lanes; i++) next()
    }
    root.readFound(key, go)
  }

  // Every lookup but this service's for this year stops where it is, what
  // it found kept: Time Machine's year changed (0 for off), or where its
  // Top 100 plays, and only that chart shows.
  function keepOnly(service, year) {
    for (var key in Store.states)
      if (key !== service + ":" + year && Store.states[key].looking) Store.states[key].stop = true
  }

  // What was found before, from the cache, once; then().
  function readFound(key, then) {
    var state = Store.states[key] || (Store.states[key] = { looking: false, error: "", read: false })
    if (state.read) { then(); return }
    root.readCache(key.replace(":", "-") + ".json", function(data) {
      if (!state.read && data && data.found) {
        var have = Store.found[key] || (Store.found[key] = {})
        for (var rank in data.found) if (have[rank] === undefined) have[rank] = data.found[rank]
      }
      state.read = true
      then()
    })
  }

  // The ids of the chart's songs found on a service: they belong to its
  // year, whatever year the version found says (a later re-release, say),
  // so Time Machine keeps them in the queue. callback({ id: true }).
  function songIds(service, year, callback) {
    var key = service + ":" + year
    root.readFound(key, function() {
      var ids = {}
      var have = Store.found[key] || {}
      for (var rank in have) if (have[rank]) ids[have[rank].id] = true
      callback(ids)
    })
  }

  // One song: a search, then a second with fewer words if the first found
  // nothing; callback(song or null, error).
  function lookUp(target, entry, year, callback) {
    function search(text, then) {
      target.search(text, function(data, error) {
        // A search whose catalog part failed (too many requests, say) found
        // nothing yet: not kept as "not there".
        if (!data || data.catalogError) { callback(null, (data && data.catalogError) || error || "no answer"); return }
        then(TimeMachine.bestMatch(entry, (data.catalog || {}).songs || [], year))
      }, "catalog", true)
    }
    search(TimeMachine.searchText(entry), function(song) {
      var again = TimeMachine.searchAgain(entry)
      if (song || again === "") callback(song, "")
      else search(again, function(second) { callback(second, "") })
    })
  }

  // ---------- The cache: one JSON file a chart, one a service's songs ----------

  property var reads: []
  function readCache(name, callback) {
    if (root.cacheDir === "") { callback(null); return }
    root.reads = root.reads.concat([{ path: root.cacheDir + "/" + name, callback: callback }])
    root.nextRead()
  }
  function nextRead() {
    if (reader.running || root.reads.length === 0) return
    reader.current = root.reads[0]
    root.reads = root.reads.slice(1)
    reader.command = ["cat", reader.current.path]
    reader.running = true
  }
  Process {
    id: reader
    property var current: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = null
        try { data = text ? JSON.parse(text) : null } catch (e) {}
        var callback = reader.current ? reader.current.callback : null
        reader.current = null
        if (callback) callback(data)
      }
    }
    stderr: StdioCollector {}
    onExited: Qt.callLater(root.nextRead)
  }

  property var writes: []
  function writeCache(name, data) {
    if (root.cacheDir === "") return
    root.writes = root.writes.concat([[name, JSON.stringify(Object.assign({ made: new Date().toISOString() }, data))]])
    root.nextWrite()
  }
  function nextWrite() {
    if (writer.running || root.writes.length === 0) return
    var write = root.writes[0]
    root.writes = root.writes.slice(1)
    writer.command = ["sh", "-c", 'mkdir -p "$1" && printf "%s" "$3" > "$1/$2.new" && mv "$1/$2.new" "$1/$2"',
      "sh", root.cacheDir, write[0], write[1]]
    writer.running = true
  }
  Process {
    id: writer
    stderr: StdioCollector {}
    onExited: Qt.callLater(root.nextWrite)
  }
}
