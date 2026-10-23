// The key hints under the list: the keys that do something here, each a
// hint { key, what, long, keep }, shown as "key what · key what". The line
// keeps its height, so fit() leaves out what doesn't fit, the last hint not
// marked keep first. The keys page shows them all, with long where there is
// one. Pure functions, so node can test them (tests/hints.test.js).

var NBSP = " "

function hint(key, what, long, keep) {
  return { key: key, what: what, long: long || "", keep: !!keep }
}

// A hint as the line shows it: its spaces don't break, so it stays whole.
function label(part) {
  return (part.key + " " + part.what).replace(/ /g, NBSP)
}

// The line breaks only after a dot, so the dot stays with the hint before it.
function join(parts) {
  return parts.map(label).join(NBSP + "· ")
}

// Whether the hints fit in `lines` lines of `width`, where measure(text)
// is a text's width, wrapping as Text's word wrap does at those spaces.
function fits(parts, width, lines, measure) {
  var count = 1
  var line = ""
  for (var i = 0; i < parts.length; i++) {
    var piece = label(parts[i]) + (i < parts.length - 1 ? NBSP + "·" : "")
    if (measure(piece) > width) return false
    var longer = line === "" ? piece : line + " " + piece
    if (line !== "" && measure(longer) > width) {
      count++
      line = piece
    } else {
      line = longer
    }
  }
  return count <= lines
}

// The text of the hints that fit. If even the ones marked keep don't, the
// Text elides them.
function fit(parts, width, lines, measure) {
  var shown = parts.slice()
  while (!fits(shown, width, lines, measure)) {
    var drop = -1
    for (var i = shown.length - 1; i >= 0 && drop < 0; i--)
      if (!shown[i].keep) drop = i
    if (drop < 0) break
    shown.splice(drop, 1)
  }
  return join(shown)
}

// The keys page's rows: [key, what it does].
function rows(parts) {
  return parts.map(function(part) {
    return [part.key, part.long !== "" ? part.long : part.what.charAt(0).toUpperCase() + part.what.slice(1)]
  })
}

if (typeof module !== "undefined") {
  module.exports = {
    hint: hint,
    label: label,
    join: join,
    fits: fits,
    fit: fit,
    rows: rows
  }
}
