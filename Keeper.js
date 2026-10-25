.pragma library
// Shared by every omarock panel in the shell: there's one for each bar, so
// one per screen. Time Machine's keeping of the queue (Panel.keepQueueInYear)
// is done by one of them; two would each take the same songs out, and Apple
// Music's queue by index, so the second would take out the wrong ones.

var owner = ""

// Whether this panel (its id) does it: the first to ask, until it goes.
function claim(id) {
  if (owner === "") owner = id
  return owner === id
}

function release(id) {
  if (owner === id) owner = ""
}
