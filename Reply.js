// JSON from outside (a service's answer, a program's output), read without
// risk to the shell. Qt 6.12's JSON.parse crashes the whole shell, the bar
// and every plugin with it (SIGSEGV), on one array of more than about 540,000
// members: an answer of only 1.1 MB ([0,0,…]). So an answer is looked over
// first, in one pass that skips over its strings: one longer than the
// caller's cap, one with an array or object of more than MEMBERS members, or
// nested deeper than DEPTH, isn't parsed at all. And a string longer than
// STRING_MAX is cut there: a row's title of megabytes would hold the shell
// while it's laid out. Pure, so node can test it (tests/reply.test.js).

// No answer omarock reads comes near these: the largest list is a library
// playlist's songs (Apple Music allows 100,000), the longest text an
// album's notes.
var MEMBERS = 100000
var DEPTH = 256
var STRING_MAX = 20000

// What one pass over text finds: why it can't be parsed safely ("big": over
// maxBytes characters, which are never more than its bytes; "members";
// "deep"; "syntax": a string left open, a bracket closed that wasn't opened),
// or "", and whether a string in it is longer than STRING_MAX.
function scan(text, maxBytes) {
  var n = text.length
  if (maxBytes > 0 && n > maxBytes) return { why: "big", long: false }
  // Members seen so far in each container open (0: none yet), the commas
  // after the first.
  var counts = []
  var depth = 0
  var long = false
  for (var i = 0; i < n; i++) {
    var c = text.charCodeAt(i)
    if (c === 34) {
      // On to the string's closing quote: one after an even run of
      // backslashes. Each backslash is looked at once.
      var q = i
      for (;;) {
        q = text.indexOf('"', q + 1)
        if (q < 0) return { why: "syntax", long: long }
        var b = q - 1
        while (text.charCodeAt(b) === 92) b--
        if ((q - 1 - b) % 2 === 0) break
      }
      if (q - i > STRING_MAX) long = true
      if (depth > 0 && counts[depth - 1] === 0) counts[depth - 1] = 1
      i = q
    } else if (c === 44) {
      if (depth > 0 && ++counts[depth - 1] > MEMBERS) return { why: "members", long: long }
    } else if (c === 91 || c === 123) {
      if (depth > 0 && counts[depth - 1] === 0) counts[depth - 1] = 1
      if (depth === DEPTH) return { why: "deep", long: long }
      counts[depth++] = 0
    } else if (c === 93 || c === 125) {
      if (depth === 0) return { why: "syntax", long: long }
      depth--
    } else if (c > 32 && depth > 0 && counts[depth - 1] === 0) {
      counts[depth - 1] = 1
    }
  }
  return { why: "", long: long }
}

function check(text, maxBytes) {
  return scan(text, maxBytes).why
}

function cut(key, value) {
  return typeof value === "string" && value.length > STRING_MAX ? value.slice(0, STRING_MAX) : value
}

// { data, error }: the value, or null and why not: "empty", "syntax", or
// scan's "big", "members" or "deep" (refused).
function parse(text, maxBytes) {
  if (typeof text !== "string" || text === "") return { data: null, error: "empty" }
  var found = scan(text, maxBytes)
  if (found.why !== "") return { data: null, error: found.why }
  try {
    return { data: found.long ? JSON.parse(text, cut) : JSON.parse(text), error: "" }
  } catch (e) {
    return { data: null, error: "syntax" }
  }
}

// Whether parse's error means the answer was refused for its size.
function refused(error) {
  return error === "big" || error === "members" || error === "deep"
}

if (typeof module !== "undefined") {
  module.exports = {
    MEMBERS: MEMBERS,
    DEPTH: DEPTH,
    STRING_MAX: STRING_MAX,
    check: check,
    parse: parse,
    refused: refused
  }
}
