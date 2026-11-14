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
  // The most read of an answer or a cache file (a year's page is under 20
  // KB), and how long Wikipedia has to answer.
  property int maxBytes: 1048576
  property int maxSeconds: 20
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
      var cached = TimeMachine.cachedChart(data, year)
      if (cached.length > 0) {
        Store.charts[year] = cached
        callback(cached, "")
        return
      }
      root.fetchChart(year, callback)
    })
  }

  // Wikipedia's page for a year, one at a time; asked for again while it's
  // on its way, the answer goes to both.
  property var fetches: []
  function fetchChart(year, callback) {
    if (Store.charts[year]) { callback(Store.charts[year], ""); return }
    var waiting = (fetcher.current ? [fetcher.current] : []).concat(root.fetches)
    for (var i = 0; i < waiting.length; i++)
      if (waiting[i].year === year) { waiting[i].callbacks.push(callback); return }
    root.fetches = root.fetches.concat([{ year: year, callbacks: [callback] }])
    Qt.callLater(root.nextFetch)
  }
  function nextFetch() {
    if (fetcher.current || root.fetches.length === 0) return
    fetcher.current = root.fetches[0]
    root.fetches = root.fetches.slice(1)
    fetcher.code = -1
    fetcher.body = null
    fetcher.late = false
    var url = root.source + "/w/api.php?action=parse&format=json&formatversion=2&redirects=1&prop=wikitext&page="
      + encodeURIComponent(TimeMachine.chartPage(fetcher.current.year))
    // curl stops at maxBytes (63), as they arrive since curl 8.4, and at
    // maxSeconds (28). Wikipedia asks API clients to say who they are.
    fetcher.command = ["curl", "-s", "--proto", "=http,https", "--max-filesize", String(root.maxBytes),
      "--max-time", String(root.maxSeconds), "-A", root.userAgent, "-H", "Api-User-Agent: " + root.userAgent, "--url", url]
    fetcher.running = true
    fetchDeadline.restart()
  }
  Process {
    id: fetcher
    property var current: null
    // Its exit code (-1 until it exits) and what it wrote (null until it ends).
    property int code: -1
    property var body: null
    property bool late: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        fetcher.body = text || ""
        fetcher.finish()
      }
    }
    stderr: StdioCollector {}
    onExited: function(exitCode) {
      fetcher.code = exitCode
      fetcher.finish()
    }
    function finish() {
      if (fetcher.code < 0 || fetcher.body === null || !fetcher.current) return
      fetchDeadline.stop()
      var fetch = fetcher.current
      var body = fetcher.body
      fetcher.current = null
      fetcher.body = null
      Qt.callLater(root.nextFetch)
      root.fetched(fetch, fetcher.late ? 28 : fetcher.code, body)
    }
  }
  // curl's own deadline, should it not keep it.
  Timer {
    id: fetchDeadline
    interval: (root.maxSeconds + 5) * 1000
    onTriggered: if (fetcher.running) {
      fetcher.late = true
      fetcher.running = false
    }
  }

  // What came of a fetch (curl's exit code, and the answer): the chart, or
  // why not, for each that asked.
  function fetched(fetch, code, text) {
    var year = fetch.year
    var page = TimeMachine.chartPage(year)
    var chart = null
    var error = ""
    var data = null
    if (code === 63 || text.length > root.maxBytes)
      error = "Wikipedia's page for " + year + "'s chart is too big to read"
    else if (code !== 0) error = "Can't reach Wikipedia for " + year + "'s chart"
    else {
      try { data = text ? JSON.parse(text) : null } catch (e) {}
      if (data && data.error)
        error = data.error.code === "missingtitle" ? "Wikipedia has no page for " + year + "'s chart"
          : "Wikipedia said: " + String(data.error.info || data.error.code).slice(0, 200)
      else {
        chart = data && data.parse ? TimeMachine.parseChart(data.parse.wikitext, TimeMachine.chartSize(year)) : []
        if (chart.length < 10) {
          chart = null
          error = "Couldn't read " + year + "'s chart on Wikipedia (" + page + ")"
        }
      }
    }
    if (chart) {
      Store.charts[year] = chart
      root.writeCache(year + ".json", { page: page, chart: chart })
    }
    fetch.callbacks.forEach(function(callback) { callback(chart, error) })
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
    var year = parseInt(key.slice(key.indexOf(":") + 1), 10)
    root.readCache(key.replace(":", "-") + ".json", function(data) {
      if (!state.read && data) {
        var cached = TimeMachine.cachedFound(data, year)
        var have = Store.found[key] || (Store.found[key] = {})
        for (var rank in cached) if (have[rank] === undefined) have[rank] = cached[rank]
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
    reader.command = ["head", "-c", String(root.maxBytes), reader.current.path]
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
    writer.feed(["sh", "-c", 'umask 077; mkdir -p "$1" && cat > "$1/$2.new" && mv "$1/$2.new" "$1/$2"',
      "sh", root.cacheDir, write[0]], write[1])
  }
  StdinProcess {
    id: writer
    stderr: StdioCollector {}
    onExited: Qt.callLater(root.nextWrite)
  }
}
