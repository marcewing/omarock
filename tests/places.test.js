const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Places = require("../Places.js")
const Radio = require("../Radio.js")

const index = Places.parse(fs.readFileSync(path.join(__dirname, "..", "places.tsv"), "utf8"))
const area = (text, prefer) => Places.area(index, Places.find(index, text, prefer))

test("a place by name: a city, narrowed by its region or country; a region; a country", () => {
  assert.equal(Places.find(index, "Portland, Maine", "US").label, "Portland, Maine, United States")
  assert.equal(Places.find(index, "portland, me", "US").label, "Portland, Maine, United States")
  assert.equal(Places.find(index, "Manchester, UK", "US").label, "Manchester, England, United Kingdom")
  assert.equal(Places.find(index, "Toronto, ON", "US").label, "Toronto, Ontario, Canada")
  assert.equal(Places.find(index, "Bayern", "DE").kind, "region")
  assert.equal(Places.find(index, "München", "DE").name, "Munich")
  assert.equal(Places.find(index, "Wien", "AT").label, "Vienna, Austria")
  assert.equal(Places.find(index, "Germany", "US").kind, "country")
  assert.equal(Places.find(index, "Nowhereville", "US"), null)
  assert.equal(Places.find(index, "Portland, Narnia", "US"), null)
})

test("one word: the time zone's country first, a region before a city", () => {
  assert.equal(Places.countryOfZone(index, "America/New_York"), "US")
  assert.equal(Places.countryOfZone(index, ":Europe/Berlin"), "DE")
  // An old name, as the laptop's /etc/localtime is (a hard link).
  assert.equal(Places.countryOfZone(index, "US/Eastern"), "US")
  // Washington the state, as the old "Your US state" meant.
  assert.equal(Places.find(index, "Washington", "US").kind, "region")
  assert.equal(Places.find(index, "Washington, DC", "US").kind, "city")
  assert.equal(Places.find(index, "Portland", "US").label, "Portland, Oregon, United States")
  assert.equal(Places.find(index, "Manchester", "US").label, "Manchester, New Hampshire, United States")
  assert.equal(Places.find(index, "Manchester", "GB").label, "Manchester, England, United Kingdom")
  assert.equal(Places.find(index, "Vancouver", "US").label, "Vancouver, Washington, United States")
  assert.equal(Places.find(index, "Vancouver", "CA").label, "Vancouver, British Columbia, Canada")
  // "Georgia" after a comma: the US state for a US user, as it has Atlanta.
  assert.equal(Places.find(index, "Atlanta, Georgia", "DE").label, "Atlanta, Georgia, United States")
})

test("an area has the regions near its city, across borders too", () => {
  const codes = a => a.regions.map(r => r.code)
  assert.deepEqual(codes(area("Portland, Maine", "US")), ["US.ME", "US.NH"])
  assert.deepEqual(codes(area("Kansas City", "US")), ["US.MO", "US.KS"])
  assert.deepEqual(codes(area("Detroit", "US")), ["US.MI", "CA.08"])
  assert.equal(area("Basel", "CH").regions.map(r => r.cc).sort().join(), "CH,CH,CH,DE,FR")
  assert.deepEqual(codes(area("Maine", "US")), ["US.ME"])
  assert.equal(Places.describe(area("Kansas City", "US")), "Kansas City, Missouri, United States, with Kansas")
  const kc = area("Kansas City", "US")
  assert.ok(kc.near.includes("overland park") && kc.far.includes("st. louis") && kc.farBig.includes("st. louis"))
  assert.ok(kc.ambiguous, "Kansas City, Kansas shares its name")
  assert.ok(kc.others.some(r => r.short === "or") && !kc.others.some(r => r.short === "ks"))
})

const station = (name, state, extra) => Object.assign({ stationuuid: name, name: name, state: state, countrycode: "US",
  tags: "", clickcount: 1, geo_lat: null, geo_long: null }, extra)

test("a station's tier: near by coordinates or a near city's name, then its regions; others not", () => {
  const portland = area("Portland, Maine", "US")
  const tier = s => Radio.localTier(portland, s, Places, {})
  assert.equal(tier(station("WMPG", "Portland, Maine")), 1)
  assert.equal(tier(station("WYAR", "", { geo_lat: 43.8, geo_long: -70.2 })), 1)
  assert.equal(tier(station("Lewiston", "Lewiston, Maine")), 1)
  assert.equal(tier(station("WHSN", "Bangor, ME")), 0, "Bangor is Maine, but 180 km off")
  assert.equal(tier(station("WUNH", "New Hampshire")), 2, "the next state's")
  assert.equal(tier(station("KBOO", "Portland, OR")), 0, "the other Portland")
  assert.equal(tier(station("KEXP", "Washington")), 0)
  assert.equal(tier(station("Far", "Maine", { geo_lat: 47.0, geo_long: -68.0 })), 0, "its coordinates are far off")
  assert.equal(tier(station("WCYY 94.3 Maine", "")), 2, "named for its region")
  assert.equal(tier(station("CBC", "Ontario", { countrycode: "CA" })), 0)
  assert.equal(tier(station("ISO", "", { iso_3166_2: "US-NH" })), 2)
  const kc = area("Kansas City", "US")
  assert.equal(Radio.localTier(kc, station("KLOU", "St. Louis, Missouri"), Places, {}), 0)
  assert.equal(Radio.localTier(kc, station("Z107.7 St. Louis", "Missouri"), Places, {}), 0)
  assert.equal(Radio.localTier(kc, station("Hard Rock Heaven", "Kansas"), Places, {}), 2)
  const oregon = area("Portland, Oregon", "US")
  assert.equal(Radio.localTier(oregon, station("KBOO 90.7 Portland, OR", "Oregon"), Places, {}), 1)
  assert.equal(Radio.localTier(oregon, station("KUOW", "Washington"), Places, {}), 2)
})

test("localStations: near first, then the rest, each by listens; crowded coordinates count for nothing", () => {
  const portland = area("Portland, Maine", "US")
  const shared = { geo_lat: 43.66, geo_long: -70.26 }
  const found = [station("WUNH", "New Hampshire", { clickcount: 50 }), station("WMPG", "Portland, Maine", { clickcount: 3 }),
    station("WMPG", "Portland, Maine"), station("KBOO", "Portland, OR", { clickcount: 99 }),
    station("WBLM", "", { geo_lat: 43.9, geo_long: -70.3, clickcount: 9 })]
    .concat([1, 2, 3, 4, 5, 6, 7, 8].map(n => station("Net " + n, "Texas", Object.assign({ clickcount: 100 }, shared))))
  assert.deepEqual(Radio.localStations(portland, found, Places).map(s => s.name), ["WBLM", "WMPG", "WUNH"])
  assert.equal(Radio.localPlace(portland), "near Portland")
  assert.equal(Radio.localPlace(area("Maine", "US")), "Maine")
})

test("localQueries: by coordinates, each region's names, the city's, and names and tags", () => {
  const qs = Radio.localQueries(area("Munich", "DE"))
  assert.ok(qs[0].startsWith("geo_lat=48.137&geo_long=11.575&geo_distance=80000&"))
  assert.ok(qs.includes("state=Bavaria&countrycode=DE&hidebroken=true&order=clickcount&reverse=true&limit=100"))
  assert.ok(qs.some(q => q.startsWith("state=Bayern&countrycode=DE&")))
  assert.ok(qs.some(q => q.startsWith("state=Munich&countrycode=DE&")))
  assert.ok(qs.some(q => q.startsWith("name=Munich&")), "Munich is the only Munich")
  assert.ok(!Radio.localQueries(area("Portland, Maine", "US")).some(q => q.startsWith("name=Portland")), "two Portlands")
  assert.deepEqual(Radio.localQueries(area("Germany", "US")), ["countrycode=DE&hidebroken=true&order=clickcount&reverse=true&limit=40"])
})
