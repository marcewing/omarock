const test = require("node:test")
const assert = require("node:assert/strict")
const TimeMachine = require("../TimeMachine.js")
const Apple = require("../Apple.js")

test("Billboard's year-end charts: the Hot 100 from 1959, a top 50 and a top 30 before", () => {
  assert.equal(TimeMachine.chartName(1996), "Top 100")
  assert.equal(TimeMachine.chartName(1957), "Top 50")
  assert.equal(TimeMachine.chartName(1950), "Top 30")
  assert.equal(TimeMachine.chartPage(1996), "Billboard Year-End Hot 100 singles of 1996")
  assert.equal(TimeMachine.chartPage(1957), "Billboard year-end top 50 singles of 1957")
  assert.equal(TimeMachine.chartPage(1949), "Billboard year-end top 30 singles of 1949")
})

test("the years to pick: last year back to the first chart", () => {
  const years = TimeMachine.years(new Date(2026, 9, 25))
  assert.equal(years[0], 2025)
  assert.equal(years[years.length - 1], 1949)
  assert.equal(years.length, 77)
})

// Wikipedia's shapes, from the real pages: a caption and header rows, a
// rank as a row header on its own line, a sort value, an artist spanning
// two rows, a reference, a comment, a double A-side, a tie.
const PAGE = `Intro text, and an earlier [[link]].
{| class="wikitable sortable" style="text-align: center"
|+ List of songs on ''[[Billboard (magazine)|Billboard]]''{{'s}} chart<ref>{{cite web|url=x}}</ref>
|-
! scope="col" style="background:#dde;"| {{Abbr|No.|Number}}
! scope="col" style="background:#dde;"| Title
! scope="col" style="background:#dde;"| Artist(s)
|-
|1 || "[[Macarena (song)|Macarena]] (Bayside Boys Mix)" || [[Los del Río]]
|-
|2 || "[[Love Yourself]]" || rowspan="2"| [[Justin Bieber]]
|-
|3 || "[[Sorry (Justin Bieber song)|Sorry]]"
|-
| scope="row" | 4
| "[[Levitating (song)|Levitating]]" || [[Dua Lipa]]<!-- not "featuring DaBaby" -->
|-
|5 ||data-sort-value="&quot;First Time"| "[[The First Time Ever I Saw Your Face]]" ||data-sort-value="Flack"| [[Roberta Flack]]
|-
|6 || "[[You're Makin' Me High]]" / "[[Let It Flow (song)|Let It Flow]]" || [[Toni Braxton]]
|-
|7 || "[[Yeah! (Usher song)|Yeah!]]" || [[Usher (musician)|Usher]] featuring [[Lil Jon]] and [[Ludacris]]
|-
|7 || "Let Me" || [[Paul Revere & the Raiders]]
|}
{| class="wikitable"
|-
|99 || "Not the chart" || Someone
|}`

test("the chart: rank, title (or titles) and artist, from the first table", () => {
  const chart = TimeMachine.parseChart(PAGE)
  assert.deepEqual(chart.map(e => [e.rank, e.title, e.artist]), [
    [1, "Macarena (Bayside Boys Mix)", "Los del Río"],
    [2, "Love Yourself", "Justin Bieber"],
    [3, "Sorry", "Justin Bieber"],
    [4, "Levitating", "Dua Lipa"],
    [5, "The First Time Ever I Saw Your Face", "Roberta Flack"],
    [6, "You're Makin' Me High / Let It Flow", "Toni Braxton"],
    [7, "Yeah!", "Usher featuring Lil Jon and Ludacris"],
    [7, "Let Me", "Paul Revere & the Raiders"]
  ])
  assert.deepEqual(chart[5].titles, ["You're Makin' Me High", "Let It Flow"])
  assert.deepEqual(TimeMachine.parseChart("No table here."), [])
})

test("wikitext as plain text", () => {
  assert.equal(TimeMachine.plainText("[[Usher (musician)|Usher]] featuring [[Lil Jon]]"), "Usher featuring Lil Jon")
  assert.equal(TimeMachine.plainText("''Hello''<ref name=a/> {{nowrap|World}}<!-- x -->"), "Hello World")
  assert.equal(TimeMachine.plainText("A<br />B &amp; C"), "A / B & C")
})

test("titles match across punctuation, case, accents and a version in brackets", () => {
  const key = TimeMachine.titleKey
  assert.equal(key("Macarena (Bayside Boys Mix)"), key("Macarena"))
  assert.equal(key("Don't Cry"), key("Dont Cry"))
  assert.equal(key("Hotel California - 2013 Remaster"), key("Hotel California"))
  assert.equal(key("(Everything I Do) I Do It for You"), "i do it for you")
  assert.equal(key("(I Can't Get No) Satisfaction"), key("Satisfaction"))
  assert.equal(key("7"), "7")
})

test("an artist credit's names, and what to search for", () => {
  assert.deepEqual(TimeMachine.artistNames("Usher featuring Lil Jon and Ludacris"), ["usher", "lil jon", "ludacris"])
  assert.deepEqual(TimeMachine.artistNames("Dionne and Friends (Dionne Warwick, Gladys Knight, Elton John and Stevie Wonder)"),
    ["dionne", "friends", "dionne warwick", "gladys knight", "elton john", "stevie wonder"])
  const yeah = { titles: ["Yeah!"], artist: "Usher featuring Lil Jon and Ludacris" }
  assert.equal(TimeMachine.searchText(yeah), "Yeah! Usher")
  assert.equal(TimeMachine.searchAgain(yeah), "")
  const day = { titles: ["One Sweet Day"], artist: "Mariah Carey and Boyz II Men" }
  assert.equal(TimeMachine.searchText(day), "One Sweet Day Mariah Carey Boyz II Men")
  assert.equal(TimeMachine.searchAgain(day), "One Sweet Day Mariah Carey")
})

const song = (id, title, artist, year, extra) => Object.assign({ kind: "song", id, source: "catalog", title, artist, year }, extra)

test("the best match: the title by one of the chart's artists, from the chart's year if there's one", () => {
  const entry = { rank: 1, titles: ["Macarena (Bayside Boys Mix)"], title: "Macarena (Bayside Boys Mix)", artist: "Los del Río" }
  const karaoke = song("k", "Macarena (Bayside Boys Mix)", "Karaoke Kings", 2004)
  const later = song("l", "Macarena (Bayside Boys Remix)", "Los Del Rio", 2012)
  const original = song("o", "Macarena (Bayside Boys Remix)", "Los Del Rio", 1995)
  assert.equal(TimeMachine.bestMatch(entry, [karaoke, later, original], 1996).id, "o")
  assert.equal(TimeMachine.bestMatch(entry, [karaoke, later], 1996).id, "l")
  assert.equal(TimeMachine.bestMatch(entry, [karaoke], 1996), null)
  const yeah = { rank: 1, titles: ["Yeah!"], artist: "Usher featuring Lil Jon and Ludacris" }
  assert.equal(TimeMachine.bestMatch(yeah, [song("y", "Yeah! (feat. Lil Jon & Ludacris)", "USHER", 2004)], 2004).id, "y")
  assert.equal(TimeMachine.bestMatch(yeah, [song("y", "Yeah! feat. Lil Jon", "Usher", 2004)], 2004).id, "y")
  assert.equal(TimeMachine.bestMatch(yeah, [song("n", "Yeah Yeah Yeahs", "Usher", 2004)], 2004), null)
  const hotel = { rank: 1, titles: ["Hotel California"], artist: "Eagles" }
  assert.equal(TimeMachine.bestMatch(hotel, [song("h", "Hotel California Live 1977", "Eagles", 2005)], 1977).id, "h")
  const double = { rank: 6, titles: ["You're Makin' Me High", "Let It Flow"], artist: "Toni Braxton" }
  assert.equal(TimeMachine.bestMatch(double, [song("f", "Let It Flow", "Toni Braxton", 1995)], 1996).id, "f")
})

test("Time Machine's year leaves out songs and albums after it, and ones without a year", () => {
  assert.ok(TimeMachine.inYear(song("a", "A", "B", 1996), 1996))
  assert.ok(!TimeMachine.inYear(song("a", "A", "B", 1997), 1996))
  assert.ok(TimeMachine.inYear({ kind: "album", releaseDate: "1990-03-01" }, 1996))
  assert.ok(!TimeMachine.inYear({ kind: "song", title: "No year" }, 1996))
  assert.ok(TimeMachine.inYear({ kind: "artist", name: "Anyone" }, 1996))
  assert.ok(TimeMachine.inYear(song("a", "A", "B", 2020), 0))
  const results = { library: { songs: [song("s1", "Old", "X", 1980), song("s2", "New", "X", 2000)], albums: [], artists: [{ kind: "artist" }] },
    catalog: { songs: [], albums: [{ kind: "album", year: 1999 }, { kind: "album", year: 1970 }], playlists: [{ kind: "playlist" }] } }
  const kept = TimeMachine.filterResults(results, 1996)
  assert.deepEqual(kept.library.songs.map(s => s.id), ["s1"])
  assert.deepEqual(kept.catalog.albums.map(a => a.year), [1970])
  assert.equal(kept.library.artists.length, 1)
  assert.equal(kept.catalog.playlists.length, 1)
  assert.equal(results.library.songs.length, 2)
  assert.equal(TimeMachine.filterResults(results, 0), results)
  const artist = TimeMachine.filterArtist({ artist: {}, albums: [{ kind: "album", year: 1999 }], topSongs: [song("t", "T", "X", 1990)] }, 1996)
  assert.deepEqual([artist.albums.length, artist.topSongs.length, artist.appearsOn.length], [0, 1, 0])
})

test("the Top 100 view: Play them all, then the chart by its places, found, not found or still looked for", () => {
  const chart = [{ rank: 1, title: "A", titles: ["A"], artist: "X" }, { rank: 2, title: "B", titles: ["B"], artist: "Y" },
    { rank: 3, title: "C", titles: ["C"], artist: "Z" }]
  const found = { 1: song("a1", "A", "X", 1990, { album: "Al", duration: 200, artwork: { url: "u" } }), 2: null }
  const view = TimeMachine.chartView(1990, chart, found, { service: "Apple Music" }, Apple)
  assert.deepEqual(view.rows.map(r => r.kind + ":" + r.lead + ":" + r.title), ["playtop:󰐊:Play the Top 100",
    "shuffletop:󰒟:Shuffle the Top 100", "track:1:A", "chartmiss:2:B", "chartmiss:3:C"])
  assert.equal(view.rows[0].subtitle, "Finding them on Apple Music: 2 of 3")
  assert.equal(view.rows[2].subtitle, "X · Al")
  assert.equal(view.rows[2].artwork, undefined)
  assert.deepEqual(view.rows[2].apple, { kind: "song", id: "a1", source: "catalog" })
  assert.equal(view.rows[3].subtitle, "Y · not on Apple Music")
  assert.ok(view.rows[3].missing && !view.rows[4].missing)
  assert.deepEqual(view.songItems, [{ kind: "song", id: "a1", source: "catalog" }])
  assert.equal(view.info.title, "Top 100 of 1990")
  found[3] = null
  assert.equal(TimeMachine.chartView(1990, chart, found, { service: "Apple Music" }, Apple).rows[0].subtitle, "1 of 3 found on Apple Music")
  const none = TimeMachine.chartView(1990, chart, found, { service: "" }, Apple)
  assert.match(none.rows[0].subtitle, /Switch on Apple Music or Spotify/)
  assert.deepEqual(none.songItems, [])
})

test("Shuffle: every item once, in another order, the list given untouched", () => {
  const items = [1, 2, 3, 4, 5, 6]
  let seed = 7
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647
  const out = TimeMachine.shuffled(items, random)
  assert.deepEqual([...out].sort(), items)
  assert.notDeepEqual(out, items)
  assert.deepEqual(items, [1, 2, 3, 4, 5, 6])
})

test("a song kept for the cache keeps what its row and Play need, not the rest", () => {
  const kept = TimeMachine.keep(song("a", "A", "X", 1990, { artwork: { url: "u", width: 100, height: 100, bgColor: "000" },
    editorialNotes: "long", duration: 3 }))
  assert.deepEqual(kept, { kind: "song", id: "a", source: "catalog", title: "A", artist: "X", year: 1990, duration: 3,
    artwork: { url: "u", width: 100, height: 100 } })
})
