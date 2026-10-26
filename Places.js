// Where "local" is, for the radio: the place the "Your area" setting names
// (a city, a region such as a state, or a country), found in places.tsv
// (tools/build-places: GeoNames' cities of 15,000 people or more, their
// regions and countries), and what's near it: the regions within the radius,
// across borders too (Kansas City has Kansas; Detroit, Ontario). All on this
// machine: nothing is asked of anyone. Pure functions, so node can test them
// (tests/places.test.js).

var RADIUS = 80
// Regions an area searches at most: its own, then the nearest others.
var MAX_REGIONS = 5

// Lower case, accents off: how names are compared ("Zürich" is "zurich").
function fold(text) {
  return String(text || "").normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase().trim()
}

function km(lat1, lon1, lat2, lon2) {
  var p = Math.PI / 180
  var h = Math.pow(Math.sin((lat2 - lat1) * p / 2), 2)
    + Math.cos(lat1 * p) * Math.cos(lat2 * p) * Math.pow(Math.sin((lon2 - lon1) * p / 2), 2)
  return 12742 * Math.asin(Math.sqrt(Math.min(1, h)))
}

// places.tsv's text as an index: { zones, countries, regions, cities }.
function parse(text) {
  var index = { zones: {}, countries: [], regions: {}, cities: [] }
  String(text || "").split("\n").forEach(function(line) {
    if (line === "" || line[0] === "#") return
    var f = line.split("\t")
    if (f[0] === "Z") index.zones[f[1]] = f[2]
    else if (f[0] === "K") index.countries.push({ cc: f[1], names: f.slice(2) })
    else if (f[0] === "R") {
      var names = f.slice(2).filter(function(n) { return n[0] !== "=" })
      var short = f.slice(2).filter(function(n) { return n[0] === "=" }).map(function(n) { return n.slice(1) })[0] || ""
      index.regions[f[1]] = { code: f[1], cc: f[1].split(".")[0], names: names, short: short }
    } else if (f[0] === "C") {
      index.cities.push({ name: f[1], cc: f[2], region: f[2] + "." + f[3], lat: Number(f[4]), lon: Number(f[5]),
        people: Number(f[6]) * 1000, others: f.slice(7) })
    }
  })
  return index
}

// The country a time zone ("America/New_York") is in, or "".
function countryOfZone(index, zone) {
  return index.zones[String(zone || "").replace(/^:/, "")] || ""
}

function countryNamed(index, word) {
  return index.countries.filter(function(c) { return c.names.some(function(n) { return fold(n) === word }) })[0] || null
}

function countryCoded(index, code) {
  return index.countries.filter(function(c) { return c.cc === code })[0] || null
}

function regionNamed(region, word) {
  return region.names.some(function(n) { return fold(n) === word }) || (region.short !== "" && fold(region.short) === word)
}

function cityNamed(city, word) {
  return fold(city.name) === word || city.others.some(function(n) { return fold(n) === word })
}

function countryName(index, cc) {
  var c = countryCoded(index, cc)
  return c ? c.names[0] : cc
}

// What a word after a comma could mean, likeliest first: a region of the
// preferred country ("Portland, ME" is Maine, not Montenegro), a country
// by name ("UK"), a region elsewhere, a country by its code ("CH").
function readings(index, word, prefer) {
  var out = []
  var folded = fold(word)
  var here = [], there = []
  for (var code in index.regions) {
    var r = index.regions[code]
    if (regionNamed(r, folded)) (r.cc === prefer ? here : there).push({ cc: r.cc, region: code })
  }
  out = out.concat(here)
  var named = countryNamed(index, folded)
  if (named) out.push({ cc: named.cc, region: "" })
  out = out.concat(there)
  var coded = word.length === 2 ? countryCoded(index, word.toUpperCase()) : null
  if (coded) out.push({ cc: coded.cc, region: "" })
  return out
}

// The place text names: "Portland, Maine", "Bayern", "Vancouver", "Germany".
// What follows a comma narrows it down: a region ("Maine", "ME") or a
// country ("UK"). One word alone: a region of the preferred country (the
// time zone's) comes first ("Washington" is the state), then its biggest
// city of that name, then a country, then a region elsewhere, then the
// biggest city anywhere.
// Returns { kind: "city"|"region"|"country", name, label, cc, region, lat, lon }, or null.
function find(index, text, prefer) {
  var raw = String(text || "").split(",").map(function(p) { return p.trim() }).filter(function(p) { return p !== "" })
  if (raw.length === 0) return null
  var first = fold(raw[0])
  function asRegion(r) {
    return { kind: "region", name: r.names[0], label: r.names[0] + ", " + countryName(index, r.cc), cc: r.cc, region: r.code,
      lat: null, lon: null }
  }
  function asCity(c) {
    var r = index.regions[c.region]
    // "Vienna, Austria", not "Vienna, Vienna, Austria".
    var within = r && fold(r.names[0]) !== fold(c.name) ? r.names[0] : ""
    return { kind: "city", name: c.name, label: [c.name, within, countryName(index, c.cc)].filter(function(p) { return p !== "" }).join(", "),
      cc: c.cc, region: c.region, lat: c.lat, lon: c.lon }
  }
  function asCountry(c) {
    return { kind: "country", name: c.names[0], label: c.names[0], cc: c.cc, region: "", lat: null, lon: null }
  }
  // Each place of that name, within what the rest narrows it to.
  function matches(cc, region) {
    var regions = []
    for (var k in index.regions) {
      var r = index.regions[k]
      if ((cc === "" || r.cc === cc) && (region === "" || r.code === region) && r.names.some(function(n) { return fold(n) === first }))
        regions.push(r)
    }
    var cities = index.cities.filter(function(c) {
      return (cc === "" || c.cc === cc) && (region === "" || c.region === region) && cityNamed(c, first)
    }).sort(function(a, b) { return b.people - a.people })
    return { regions: regions, cities: cities }
  }
  if (raw.length > 1) {
    // Every reading of what follows, until one has a place by that name:
    // the city first ("Portland, Maine"), else the region ("Bayern, Germany").
    var options = [{ cc: "", region: "" }]
    for (var q = 1; q < raw.length; q++) {
      var next = []
      readings(index, raw[q], prefer).forEach(function(r) {
        options.forEach(function(o) {
          if (o.cc !== "" && o.cc !== r.cc) return
          if (o.region !== "" && r.region !== "" && o.region !== r.region) return
          next.push({ cc: r.cc, region: r.region || o.region })
        })
      })
      options = next
    }
    for (var i = 0; i < options.length; i++) {
      var m = matches(options[i].cc, options[i].region)
      if (m.cities.length > 0) return asCity(m.cities[0])
      if (m.regions.length > 0) return asRegion(m.regions[0])
    }
    return null
  }
  var all = matches("", "")
  var preferred = function(p) { return p.cc === prefer }
  var pick = all.regions.filter(preferred)[0]
  if (pick) return asRegion(pick)
  pick = all.cities.filter(preferred)[0]
  if (pick) return asCity(pick)
  var country = countryNamed(index, first)
  if (country) return asCountry(country)
  if (all.regions.length > 0) return asRegion(all.regions[0])
  if (all.cities.length > 0) return asCity(all.cities[0])
  country = raw[0].length === 2 && raw[0] === raw[0].toUpperCase() ? countryCoded(index, raw[0]) : null
  return country ? asCountry(country) : null
}

// What the radio needs of a place, small enough to keep (Radio.js reads it):
//   regions: its own, then (a city's) the others within the radius, nearest
//     first: { code, cc, names, short, km };
//   others: every other region of those countries ({ cc, names, short }),
//     so a station of another region isn't taken for local;
//   near: the names of the cities within the radius (a city's);
//   far: the names of its regions' cities well past it (half as far again),
//     and farBig those of 100,000 people or more, so "St. Louis, Missouri"
//     isn't local to Kansas City;
//   ambiguous: whether another city of the country has its name.
function area(index, place, radius) {
  if (!place) return null
  radius = radius || RADIUS
  var out = { kind: place.kind, name: place.name, label: place.label, cc: place.cc, lat: place.lat, lon: place.lon,
    radius: radius, regions: [], others: [], near: [], far: [], farBig: [], ambiguous: false }
  function regionOf(code, distance) {
    var r = index.regions[code]
    return r ? { code: r.code, cc: r.cc, names: r.names, short: r.short, km: Math.round(distance) } : null
  }
  if (place.kind === "region") out.regions = [regionOf(place.region, 0)]
  if (place.kind === "city") {
    var nearest = {}
    nearest[place.region] = 0
    var names = {}
    var dLat = radius / 111
    index.cities.forEach(function(c) {
      if (Math.abs(c.lat - place.lat) > dLat) return
      var d = km(place.lat, place.lon, c.lat, c.lon)
      if (d > radius) return
      if (nearest[c.region] === undefined || d < nearest[c.region]) nearest[c.region] = d
      ;[c.name].concat(c.others).forEach(function(n) { names[fold(n)] = true })
    })
    out.regions = Object.keys(nearest).sort(function(a, b) { return nearest[a] - nearest[b] })
      .slice(0, MAX_REGIONS).map(function(code) { return regionOf(code, nearest[code]) }).filter(function(r) { return r })
    out.near = Object.keys(names)
    var mine = {}
    out.regions.forEach(function(r) { mine[r.code] = true })
    var far = {}, farBig = {}
    index.cities.forEach(function(c) {
      if (!mine[c.region] || km(place.lat, place.lon, c.lat, c.lon) <= radius * 1.5) return
      ;[c.name].concat(c.others).forEach(function(n) {
        var name = fold(n)
        if (names[name]) return
        far[name] = true
        if (c.people >= 100000) farBig[name] = true
      })
    })
    out.far = Object.keys(far)
    out.farBig = Object.keys(farBig)
    out.ambiguous = index.cities.some(function(c) {
      return c.cc === place.cc && cityNamed(c, fold(place.name)) && (c.lat !== place.lat || c.lon !== place.lon)
    })
  }
  var countries = {}
  countries[place.cc] = true
  out.regions.forEach(function(r) { countries[r.cc] = true })
  var mine = out.regions.map(function(r) { return r.code })
  for (var code in index.regions) {
    var r = index.regions[code]
    if (countries[r.cc] && mine.indexOf(code) < 0) out.others.push({ cc: r.cc, names: r.names.map(fold), short: fold(r.short) })
  }
  return out
}

// How the settings describe an area: "Portland, Maine, United States, with New Hampshire".
function describe(found) {
  if (!found) return ""
  var with_ = found.regions.slice(1).map(function(r) { return r.names[0] })
  return found.label + (with_.length > 0 ? ", with " + with_.join(", ").replace(/, ([^,]*)$/, " and $1") : "")
}

if (typeof module !== "undefined") {
  module.exports = { RADIUS: RADIUS, fold: fold, km: km, parse: parse, countryOfZone: countryOfZone, find: find, area: area,
    describe: describe }
}
