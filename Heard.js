// Apple Music as it is heard. mpd plays the bridge's stream a couple of
// seconds behind the Mac (its own 1 s buffer, libFLAC's reads, the trip from
// the Mac), so the bridge's status is ahead of the sound: a song that starts
// on the Mac is heard that much later. The panel shows the status as heard
// (AppleClient.heard): a song changes when its sound does, and the time is
// the time heard. A change made here (a song picked, next, a seek, play,
// pause) shows at once, and the time waits, "…", until its sound arrives.
// Pure functions, so node can test them (tests/heard.test.js).
//
// entries: the bridge's statuses as they came, oldest first, each
// { at (ms), status, user (true: the answer to a change made here) }.

// Seconds into the song at time t (ms), by an entry.
function positionAt(entry, t) {
  var status = entry.status
  var at = status.position || 0
  if (status.state === "playing" && !status.elsewhere) at += Math.max(0, (t - entry.at) / 1000)
  var duration = status.song ? status.song.duration || 0 : 0
  return duration > 0 ? Math.min(duration, at) : at
}

// The same song (at the same place in the queue), playing or not alike.
function sameState(a, b) {
  function key(s) { return (s.song ? (s.song.source || "") + ":" + s.song.id + ":" + s.queueIndex : "") + ":" + s.state }
  return key(a) === key(b)
}

// What shows at now (ms), with the sound delay seconds behind:
// { status, elapsed, waiting, next }, next being when it changes by itself
// (ms), else 0. acting: a change asked for here and not answered yet;
// target: a seek's position while it is (else -1). With no delay (mpd
// isn't playing the stream, or isn't behind it), the newest status.
function shown(entries, now, delay, acting, target) {
  var seeking = target !== undefined && target >= 0
  var last = entries[entries.length - 1]
  if (!last) return { status: {}, elapsed: seeking ? target : 0, waiting: false, next: 0 }
  if (!(delay > 0)) return { status: last.status, elapsed: seeking ? target : positionAt(last, now), waiting: false, next: 0 }
  var heardAt = now - delay * 1000
  var base = 0
  while (base + 1 < entries.length && entries[base + 1].at <= heardAt) base++
  // The newest change made here that isn't heard yet shows at once, with
  // any status after it about the same song.
  var user = -1
  for (var i = entries.length - 1; i >= 0 && entries[i].at > heardAt; i--) {
    if (entries[i].user) {
      user = i
      break
    }
  }
  if (user < 0) {
    return { status: entries[base].status, elapsed: seeking ? target : positionAt(entries[base], heardAt),
      waiting: !!acting, next: base + 1 < entries.length ? entries[base + 1].at + delay * 1000 : 0 }
  }
  var status = entries[user].status
  for (var j = user + 1; j < entries.length && sameState(entries[j].status, entries[user].status); j++) status = entries[j].status
  var playing = status.state === "playing" && !status.elsewhere
  // Playing: its time waits where it starts. Paused: the time heard runs on
  // until the sound stops where the Mac paused.
  var elapsed = seeking ? target
    : playing ? entries[user].status.position || 0
    : Math.min(status.position || 0, positionAt(entries[base], heardAt))
  return { status: status, elapsed: elapsed, waiting: playing || !!acting, next: entries[user].at + delay * 1000 }
}

// The entries still needed at now: from the one heard on.
function prune(entries, now, delay) {
  var heardAt = now - Math.max(0, delay) * 1000
  var base = 0
  while (base + 1 < entries.length && entries[base + 1].at <= heardAt) base++
  return entries.slice(Math.max(base, entries.length - 40))
}

// The bridge's own status with the playing song, state and place in the
// queue as heard: the queue, shuffle, repeat and volume are the Mac's now.
function overlay(live, heard) {
  return Object.assign({}, live, { state: heard.state, position: heard.position, song: heard.song,
    queueIndex: heard.queueIndex, elsewhere: heard.elsewhere })
}

if (typeof module !== "undefined") {
  module.exports = {
    positionAt: positionAt,
    sameState: sameState,
    shown: shown,
    prune: prune,
    overlay: overlay
  }
}
