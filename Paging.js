// PgUp and PgDn in the panel's lists, the settings and the playlist picker:
// the cursor goes to the first or last row in full view, or, already there,
// a page further (as many rows as show), and the list follows it. Pure
// functions, apart from listBoxes, so node can test them
// (tests/paging.test.js).

// The rows in full view, { first, last }, of boxes { index, y, height } in
// the list's own coordinates, top to bottom; null when none is. Rows of no
// height (the level's buttons, Panel.buttonRows) are passed over.
function shown(boxes, top, bottom) {
  var first = -1
  var last = -1
  boxes.forEach(function(box) {
    if (box.height <= 0 || box.y < top - 0.5 || box.y + box.height > bottom + 0.5) return
    if (first < 0) first = box.index
    last = box.index
  })
  return first < 0 ? null : { first: first, last: last }
}

// Where the cursor goes from cursor, in count rows, direction 1 (PgDn) or
// -1 (PgUp). With nothing in full view, ten rows a page.
function page(cursor, count, rows, direction) {
  if (count <= 0) return -1
  var step = rows ? Math.max(1, rows.last - rows.first) : 10
  var to = direction > 0
    ? (rows && cursor < rows.last ? rows.last : cursor + step)
    : (rows && cursor > rows.first ? rows.first : cursor - step)
  return Math.max(0, Math.min(count - 1, to))
}

// A ListView's rows in view, as boxes for shown(). rowTop(item), when
// given, is where the row itself starts in its delegate (under a section's
// heading). Only rows in view are made, so the walk starts at the top one.
function listBoxes(list, rowTop) {
  var top = list.contentY
  var bottom = top + list.height
  var at = -1
  for (var y = top; at < 0 && y < bottom; y += 2) at = list.indexAt(list.width / 2, y)
  var boxes = []
  for (var i = Math.max(0, at); at >= 0 && i < list.count; i++) {
    var item = list.itemAtIndex(i)
    if (!item || item.y > bottom) break
    var start = rowTop ? rowTop(item) : 0
    boxes.push({ index: i, y: item.y + start, height: item.height - start })
  }
  return boxes
}

if (typeof module !== "undefined") {
  module.exports = {
    shown: shown,
    page: page
  }
}
