// The editing a text field does itself (GuardedField.qml): to Qt every
// field is read-only, so Qt never reads the clipboard into one. What a key
// types, what Backspace, Delete and their Ctrl forms take, a dead key's
// accent, what a paste puts in, and how it went. Pure, so node can test it
// (tests/editing.test.js).

// Over this many bytes the clipboard isn't pasted: the helper reads one
// more, to tell (GuardedField.pasteCommand).
var pasteLimit = 4096

var Ctrl = 0x04000000
var Alt = 0x08000000
var Meta = 0x10000000

// The text a key types, or "": nothing for a Ctrl, Alt or Super chord (as
// in Omarchy's own search lines, those are shortcuts) or for a key that
// types no printable text (Tab, Enter, Esc, Backspace).
function typed(text, modifiers) {
  if (!text || (modifiers & (Ctrl | Alt | Meta))) return ""
  if (control(text.charCodeAt(0))) return ""
  return text.replace(/[\x00-\x1f\x7f-\x9f]/g, "")
}

function control(code) {
  return code < 0x20 || (code >= 0x7f && code <= 0x9f)
}

function highSurrogate(code) { return code >= 0xd800 && code <= 0xdbff }
function lowSurrogate(code) { return code >= 0xdc00 && code <= 0xdfff }

// Marks that belong to the character before them: Delete takes them with it.
function mark(code) {
  return (code >= 0x300 && code <= 0x36f) || (code >= 0x1ab0 && code <= 0x1aff) || (code >= 0x1dc0 && code <= 0x1dff)
    || (code >= 0x20d0 && code <= 0x20ff) || (code >= 0xfe00 && code <= 0xfe0f) || (code >= 0xfe20 && code <= 0xfe2f)
}

// Words, for Ctrl+Backspace and Ctrl+Delete: runs of anything but spaces
// and punctuation; a punctuation mark is a word of its own (as Qt has it).
function space(c) { return /\s/.test(c) }
function punctuation(c) {
  var code = c.charCodeAt(0)
  return /[!-\/:-@\[-`{-~]/.test(c) || (code >= 0xa1 && code <= 0xbf && code !== 0xaa && code !== 0xba)
    || (code >= 0x2010 && code <= 0x205e) || (code >= 0x3000 && code <= 0x303f)
}
function wordChar(c) { return !space(c) && !punctuation(c) }

// What an edit takes out of text, { start, end }, or null for nothing:
// "back" (Backspace) and "forward" (Delete) a character, "wordBack"
// (Ctrl+Backspace) and "wordForward" (Ctrl+Delete) a word, "toEnd" the rest
// of the line, "all" all of it. A selection is what goes, but for the last
// two.
function range(action, text, cursor, selectionStart, selectionEnd) {
  var hasSelection = selectionStart !== selectionEnd
  if (action === "all") return text.length > 0 ? { start: 0, end: text.length } : null
  if (action === "toEnd") return cursor < text.length ? { start: cursor, end: text.length } : null
  if (hasSelection) return { start: selectionStart, end: selectionEnd }
  var at = cursor
  if (action === "back") {
    if (at <= 0) return null
    at--
    if (at > 0 && lowSurrogate(text.charCodeAt(at)) && highSurrogate(text.charCodeAt(at - 1))) at--
    return { start: at, end: cursor }
  }
  if (action === "forward") {
    if (at >= text.length) return null
    at += highSurrogate(text.charCodeAt(at)) && lowSurrogate(text.charCodeAt(at + 1)) ? 2 : 1
    while (at < text.length && mark(text.charCodeAt(at))) at++
    return { start: cursor, end: at }
  }
  if (action === "wordBack") {
    while (at > 0 && space(text[at - 1])) at--
    if (at > 0 && wordChar(text[at - 1])) while (at > 0 && wordChar(text[at - 1])) at--
    else if (at > 0) at--
    return at < cursor ? { start: at, end: cursor } : null
  }
  if (action === "wordForward") {
    if (at < text.length && wordChar(text[at])) while (at < text.length && wordChar(text[at])) at++
    else if (at < text.length && !space(text[at])) at++
    while (at < text.length && space(text[at])) at++
    return at > cursor ? { start: cursor, end: at } : null
  }
  return null
}

// Dead keys, by Qt's key codes, for layouts that type accents with them
// (US International, German, French...): the mark each puts on the next
// letter, and what it types before a space, or before a letter it has no
// accented form of.
var deadKeys = {
  0x01001250: ["\u0300", "`"],      // grave
  0x01001251: ["\u0301", "'"],      // acute
  0x01001252: ["\u0302", "^"],      // circumflex
  0x01001253: ["\u0303", "~"],      // tilde
  0x01001254: ["\u0304", "\u00af"], // macron
  0x01001255: ["\u0306", "\u02d8"], // breve
  0x01001256: ["\u0307", "\u02d9"], // dot above
  0x01001257: ["\u0308", "\""],     // diaeresis
  0x01001258: ["\u030a", "\u00b0"], // ring above
  0x01001259: ["\u030b", "\u02dd"], // double acute
  0x0100125a: ["\u030c", "\u02c7"], // caron
  0x0100125b: ["\u0327", "\u00b8"], // cedilla
  0x0100125c: ["\u0328", "\u02db"], // ogonek
  0x01001260: ["\u0323", "."],      // dot below
  0x01001261: ["\u0309", "\u02c0"], // hook above
  0x01001262: ["\u031b", "\u02bc"]  // horn
}

function isDeadKey(key) {
  return deadKeys[key] !== undefined
}

// What a dead key and the text typed after it make: "é" for ´ then e, "'"
// for ´ then a space or ´ again, "'q" for ´ then q.
function compose(deadKey, text) {
  var dead = deadKeys[deadKey]
  if (!dead) return text
  if (text === "" || text === " ") return dead[1]
  var first = highSurrogate(text.charCodeAt(0)) ? text.slice(0, 2) : text.slice(0, 1)
  var accented = (first + dead[0]).normalize("NFC")
  return (accented.length === first.length ? accented : dead[1] + first) + text.slice(first.length)
}

// Keys that only change the next one (Shift for É): a dead key waits
// through them. Any other key that types nothing drops it.
var modifierKeys = [0x01000020, 0x01000021, 0x01000022, 0x01000023, 0x01000024, 0x01000025, 0x01000026,
  0x01000053, 0x01000054, 0x01000056, 0x01000057, 0x01001103, 0x0100117e]

function isModifierKey(key) {
  return modifierKeys.indexOf(key) >= 0
}

// What a paste puts in a one-line field: line breaks at either end dropped,
// those between become a space, tabs a space, and NULs and other control
// characters go.
function pasteText(raw) {
  return String(raw).replace(/^[\r\n\u2028\u2029]+|[\r\n\u2028\u2029]+$/g, "")
    .replace(/[\r\n\u2028\u2029]+/g, " ").replace(/\t/g, " ").replace(/[\x00-\x1f\x7f-\x9f]/g, "")
}

// How a paste went, from the helper's output (its size in bytes) and exit:
// "big" over the limit, "slow" past the deadline (timeout's 124, or 137
// once it had to kill; or a crash), "none" for nothing to paste (an empty
// clipboard, no text in it), else "paste".
function pasteOutcome(bytes, exitCode, normalExit) {
  if (bytes > pasteLimit) return "big"
  if (!normalExit || exitCode === 124 || exitCode === 137) return "slow"
  if (exitCode !== 0 || bytes === 0) return "none"
  return "paste"
}

// The smallest change that makes before into after, { start, end, text }:
// replace before's start..end with text. For undo, so a field's text
// changes once, not cleared and then filled.
function difference(before, after) {
  var start = 0
  var most = Math.min(before.length, after.length)
  while (start < most && before[start] === after[start]) start++
  var tail = 0
  while (tail < most - start && before[before.length - 1 - tail] === after[after.length - 1 - tail]) tail++
  return { start: start, end: before.length - tail, text: after.slice(start, after.length - tail) }
}

if (typeof module !== "undefined") {
  module.exports = {
    pasteLimit: pasteLimit,
    typed: typed,
    range: range,
    isDeadKey: isDeadKey,
    compose: compose,
    isModifierKey: isModifierKey,
    pasteText: pasteText,
    pasteOutcome: pasteOutcome,
    difference: difference
  }
}
