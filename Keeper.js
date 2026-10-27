.pragma library
// Shared by every omarock panel in the shell: there's one for each bar, so
// one per screen. A few jobs are done by one of them only: Time Machine's
// keeping of the queue (Panel.keepQueueInYear), where two would each take
// the same songs out, and Apple Music's queue by index, so the second would
// take out the wrong ones; and History's adding of plays, where two would
// add each play twice.

var owners = {}

// Whether this panel (its id) does the job ("queue" if none is named): the
// first to ask, until it goes.
function claim(id, job) {
  job = job || "queue"
  if (!owners[job]) owners[job] = id
  return owners[job] === id
}

// Everything this panel did, for another to take on.
function release(id) {
  for (var job in owners) if (owners[job] === id) delete owners[job]
}
