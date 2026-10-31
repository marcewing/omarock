# omarock bridge API (v1)

The bridge is a small macOS app on a Mac with Apple Music. It uses MusicKit to
search, browse and play Apple Music, and answers omarock (and its command-line
tool, `tools/omarock-am`) over Tailscale. Its sound reaches the Linux machine
only as an Ogg FLAC stream that **mpd** plays, through mpd's own output. Nothing
here sends audio to the Linux machine any other way. Setting it up:
[README.md](README.md).

The examples use `100.64.0.10` for the Mac's Tailscale address.

## Transport

- HTTP/1.1, JSON bodies, UTF-8. Port **8710**. The bridge listens on the
  Mac's Tailscale address only (`100.64.0.10` here), never on the LAN.
- Every request carries `Authorization: Bearer <token>`. The token is a random
  string kept in `~/Library/Application Support/omarock-bridge/token` on the Mac
  and in `~/.config/omarock/bridge-token` on the Linux machine. A wrong or missing
  token gets 401.
- Every request also carries `X-Omarock-Client: <machine name>`, the contents of
  `/etc/hostname` (`framework`, `dellxps`), so the bridge knows which machine it plays
  for (see **One machine at a time**). Letters, digits, `-`, `.` and `_`, at most 64;
  anything else counts as no header.
- Errors: a non-2xx status and `{"error": "what went wrong, in a sentence"}`.
  Use 400 for bad input, 404 for an unknown id, 409 if MusicKit isn't
  authorized or there's no subscription, and 502 if Apple's API failed.
- The stream is separate: Icecast on the Mac at
  `http://100.64.0.10:8000/omarock.ogg`, Ogg FLAC, 16-bit stereo at the
  Mac's mixing rate (48 kHz). From 0.7.0 (`/v1/health` has `"minBitrate": true`)
  it's encoded with libFLAC's `limit_min_bitrate`: digital silence still costs about
  6 KB/s, not a few hundred bytes, so an mpd with a stock libFLAC that joins in a
  pause doesn't fall tens of seconds behind. Pages are 0.2 s. The audio is captured with a Core Audio process
  tap on the bridge's own playback, muted on the Mac. The Mac can be someone's
  everyday machine, so its default output and other apps' sound are never touched.

## Objects

The bridge normalizes Apple's JSON, so omarock never parses Apple's responses.
Fields Apple doesn't give are omitted, not null. `source` is `"catalog"` or
`"library"`; an id is only meaningful together with its source.

```jsonc
// Artwork: url is Apple's template; omarock fills in {w} and {h}.
{ "url": "https://is1-ssl.mzstatic.com/.../{w}x{h}bb.jpg", "width": 3000, "height": 3000,
  "bgColor": "1a1a1a", "textColor": "f2f2f2" }

// Song
{ "kind": "song", "id": "1440000001", "source": "catalog", "catalogId": "1440000001",
  "title": "Diane", "artist": "Hüsker Dü", "album": "Metal Circus", "albumId": "1440000000",
  "artistId": "14000000", "genres": ["Punk", "Music"], "year": 1983, "releaseDate": "1983-10-01",
  "duration": 248.5, "trackNumber": 5, "discNumber": 1, "composer": "Grant Hart",
  "explicit": false, "audioTraits": ["lossless", "lossy-stereo"], "isrc": "USXX18300001",
  "artwork": { … }, "playable": true }

// Album
{ "kind": "album", "id": "…", "source": "catalog", "catalogId": "…", "title": "Zen Arcade",
  "artist": "Hüsker Dü", "artistId": "…", "genres": ["Punk"], "year": 1984,
  "releaseDate": "1984-07-01", "trackCount": 23, "recordLabel": "SST Records",
  "copyright": "℗ 1984 SST Records", "editorialNotes": "short blurb, plain text",
  "isCompilation": false, "isSingle": false, "explicit": false, "audioTraits": ["lossless"],
  "artwork": { … } }

// Artist
{ "kind": "artist", "id": "…", "source": "catalog", "name": "Hüsker Dü", "genres": ["Punk"],
  "editorialNotes": "…", "artwork": { … } }

// Playlist
{ "kind": "playlist", "id": "p.…", "source": "library", "name": "PunkRock", "curator": "You",
  "description": "…", "trackCount": 42, "lastModified": "2026-10-19T15:02:11Z",
  "canEdit": true, "artwork": { … } }

// Genre (library only): a genre as the library's songs name it. The id is the
// name; years counts its songs by year ("0": songs with no year).
{ "kind": "genre", "id": "Alternative & Punk", "source": "library", "name": "Alternative & Punk",
  "songs": 1203, "years": { "0": 4, "1979": 12, "1984": 140 } }
```

`catalogId` is set on library items that are also in the catalog, so omarock
can open the catalog album or artist from a library song. On macOS, library ids
are iTunes Library persistent ids, signed 64-bit decimals such as
"1234567890123456789" or "-1234567890123456789"; treat every id as an opaque
string, valid only together with its source.

Artwork that only MusicKit can open (library-only items, such as songs
uploaded from iTunes rips, have `musicKit://` artwork) is served by the
bridge itself. Its `url` is then a bridge URL such as
`http://100.64.0.10:8710/v1/artwork/library/song/i.AbC?w={w}&h={h}&k=3f9a…`,
where `k` is the first 16 hex digits of HMAC-SHA256(token, "library/song/i.AbC").
The key makes the URL its own authorization, since an image can't send the
bearer header. omarock treats it like any other artwork template.

## Endpoints

All paths start with `/v1`.

| Method and path | What it does |
| --- | --- |
| `GET /health` | `{ "ok": true, "version": "0.3.0", "authorized": true, "canPlayCatalog": true, "stream": "http://…/omarock.ogg", "storefront": "us" }`, plus diagnostics (`musicAuthorization`, `capturing`, `encoding`), and `"minBitrate": true` from 0.7.0 (see the stream, above). No auth needed, and it reveals nothing private. |
| `POST /authorize` | Asks for MusicKit access (`MusicAuthorization.request()`), which puts a dialog on the Mac's screen; returns health. For someone at the Mac (the bridge also asks at its first launch). |
| `GET /status?since=SEQ` | Now playing. Returns at once if the state's `seq` differs from `SEQ` (or there is no `since`); otherwise waits up to 25 s for a change, then returns the same state (long poll). |
| `POST /play` | `{ "items": [ {kind, id, source}, … ], "start": 0, "mode": "play" }`. `mode` is `play` (replace the queue and start at song `start`), `next` (insert after the current song) or `add` (append). Items are expanded to songs, in order (see **Items** below). `start` is the index into the tracks as the detail route lists them (`/albums|/playlists/{source}/{id}`), counted before unplayable songs are skipped; if that song is unplayable, play starts at the next playable one. A single song that can't be played answers 409 with the reason. Returns the new status. |
| `POST /pause`, `/resume`, `/toggle`, `/next`, `/previous` | Transport; each returns the new status. With nothing loaded, `resume` and `toggle` do nothing and still return 200. |
| `POST /seek` | `{ "position": 73.5 }` (seconds). |
| `POST /queue/jump` | `{ "index": 4 }`: play that queue entry. |
| `POST /queue/remove` | `{ "index": 4 }`. |
| `POST /shuffle`, `/repeat` | `{ "on": true }`; `{ "mode": "off" \| "one" \| "all" }`. |
| `GET /search?q=husker&scope=all&limit=8` | `{ "library": { "songs": […], "albums": […], "artists": […], "playlists": […], "genres": […] }, "catalog": { …same, without genres… } }`. `scope` is `all`, `library` or `catalog`. Case- and accent-insensitive as far as Apple allows. If the catalog half fails, the library half still comes back, with `"catalogError": "…"`. The library's `genres` are those whose name contains the query (see **Your library's genres**). |
| `GET /albums/{source}/{id}` | `{ "album": Album, "tracks": [Song] }`, in disc and track order. A catalog album's tracks carry `inLibrary`, as status songs do (see **Status**); library albums' leave it out. |
| `GET /artists/{source}/{id}` | `{ "artist": Artist, "albums": [Album], "topSongs": [Song] }`. Albums by year; for the catalog, also `"appearsOn": [Album]` where Apple gives it. Every library `artistId` the bridge hands out opens, also an artist only on songs of a playlist added to the library (MusicKit doesn't know those): then the albums and songs are the ones those songs are on. A library artist's albums have the title, year and `trackCount` their own route gives; ones with no songs on this Mac are left out. |
| `GET /playlists/{source}/{id}` | `{ "playlist": Playlist, "tracks": [Song] }`. |
| `GET /library/playlists` | `[Playlist]`, by name. |
| `GET /library/albums?offset=0&limit=100` | `{ "items": [Album], "total": 812 }`, by artist then year. |
| `GET /library/artists?offset=0&limit=100` | `{ "items": [Artist], "total": 403 }`, by name. |
| `GET /library/recent?limit=25` | Recently added albums and playlists. |
| `GET /genres` | The catalog's top-level genres: `[{ "id": "20", "name": "Alternative" }]`. |
| `GET /genres/{id}?limit=25` | `{ "genre": …, "albums": [Album], "songs": [Song] }` (Apple's charts for the genre). |
| `GET /genres/library/{id}` | One of the library's genres (`id` percent-encoded): `{ "genre": Genre, "albums": [Album], "songs": [{ "id", "year", "duration" }] }`. See **Your library's genres**. 404 for a genre no library song has. |
| `GET /artwork/{source}/{kind}/{id}?w=&h=&k=` | `image/jpeg` for artwork only MusicKit can open (see Objects). Authorized by `k`, not the bearer token. |
| `POST /library/playlists` | `{ "name": "…", "items": [ {kind, id, source} ] }` → the new Playlist. (MusicKit can't create or edit playlists on macOS, so the bridge uses Apple Music's REST API through MusicDataRequest.) |
| `POST /library/playlists/{id}/tracks` | `{ "items": [ … ] }`: append, the items expanded to songs. Returns the Playlist. Apple's API can't remove tracks or delete playlists; those come later through AppleScript on the Mac. |
| `POST /library/add` | `{ "items": [ {kind, id, source} ] }`: adds catalog songs, albums and playlists to the library. Returns `{ "ok": true, "added": 2 }` (the catalog items sent to Apple). See **Adding to the library** below. |
| `GET /info/{source}/{kind}/{id}` | Everything known about one song or album (`kind` is `song` or `album`), for omarock's info card (`i`). See **Info** below. |

### Info

What omarock shows when you press `i` on a song or album. At the top, it shows
whether the item is in your library. Fields that aren't known are omitted, as elsewhere.

```jsonc
{ "item": Song,                     // or Album: the object the detail routes give
  "inLibrary": true,                // false: not in the library; omitted: couldn't tell
  "library": {                      // the library copy (ITLib), when inLibrary
    "id": "1234567890123456789",
    "added": "2019-04-02T17:03:11Z", "modified": "2024-01-09T08:12:40Z",
    "playCount": 12, "skipCount": 1, "lastPlayed": "2026-10-18T21:40:02Z",
    "rating": 80,                   // 0-100, only when you set it (not computed)
    "loved": true,                  // omitted when unknown
    "fileKind": "Apple Music AAC audio file",  // ITLib's kind: Matched, Purchased, MPEG, …
    "bitrate": 256, "sampleRate": 44100, "fileSize": 7340032,
    "cloud": true, "purchased": false, "drm": true,
    "comments": "…", "grouping": "…", "bpm": 120 },
  "catalog": { "id": "1440000001", "url": "https://music.apple.com/us/album/…?i=1440000001" }
}                                   // catalog: when the item is also in the catalog
```

For an album, `library` has `id`, `added` (the newest song added), `trackCount`
(the songs in the library), `playCount` (summed over them) and `lastPlayed` (the latest).
The catalog album's own `trackCount` stays in `item`.

How the bridge fills it in:
- **`inLibrary`** for a catalog item is true if either check finds it:
  - Apple's `relate=library`.
  - The ITLib index: the same title and artist, ignoring case, accents, guest credits
    and a trailing "(Remastered)", "[Deluxe Edition]" or "- 2009 Remaster", and within
    3 s of the length (6 s when only the bare titles match). Only songs on the
    library's albums count.
  Apple's relation alone misses songs ripped from CD and uploaded. Where only
  Apple relates it, the bridge follows Apple's library song to the ITLib copy. A
  catalog album Apple relates but the index can't match gives `inLibrary` true and no
  `library` object.
- **`inLibrary`** for a library item is true, except for one that's only on a playlist
  added to the library: Music keeps those songs, but its Songs and Albums don't list
  them, Apple doesn't count them, and library search leaves them out. Those answer
  false (with `library` all the same), until added; adding the `catalog` item puts them
  in the library.
- **`loved`**: ITLib has no flag, so it's membership of the Music app's Favorite Songs
  playlist (once Loved Songs): true or false whenever that playlist exists.
- **`purchased`**: ITLib's isPurchased can read false for "Purchased AAC audio file"
  songs, so a kind starting "Purchased" counts too.
- `rating` only when you set it; `bpm`, `comments`, `grouping`, `bitrate`, `sampleRate`
  and `fileSize` only when non-empty or non-zero.
- **`catalog.id`** is Apple's current canonical id, from the link (old playParams ids are
  redirected). For a library song it comes through the catalog song MusicKit plays it
  as, else a catalog search. For a library album it comes through its first tracks, so it
  can be another edition.
- Catalog items carry `albumId` and `artistId` too.
- Errors: 400 "kind is song or album.", 404 "No library song with id …" (or catalog).
  Answers take 0.1 to 0.7 s.

omarock asks this route first. If the route answers "No such endpoint." (an older
bridge), omarock searches the library by title and matches on artist itself.

### Adding to the library

`POST /library/add` goes through Apple Music API's "Add a Resource to a Library"
(`POST /v1/me/library?ids[songs]=…&ids[albums]=…&ids[playlists]=…`).
- Each item's `kind` is `song`, `album` or `playlist`. Library items (`source:
  "library"`) are in the library already: they're skipped, still with 200.
- Errors:
  - 400 for another kind, an id that isn't a catalog id, or more than 100 items.
  - 502 with Apple's message if Apple refuses.
- Apple accepts the add at once, but Music gets it from iCloud a little later. Apple
  also ignores ids it can't add, and still accepts the rest.
- Until Music has it, the bridge remembers what it added, until the bridge quits:
  - `/info` answers `inLibrary: true` for an added song or album, and for a song on
    an added album. `library` is omitted until ITLib has the item.
  - Status songs show `inLibrary: true` at once, with a new `seq`.
- The library index behind search, an artist's albums and `/library/…` is read every 5
  minutes, and again 30 s, 90 s and 4 minutes after an add.

`POST /library/remove` (omarock-spotify only): the same body; takes items out of the
library. Apple Music's API can't remove, so the bridge has no such route.

### Your library's genres

The catalog's genres are Apple's top-level ones only (`GET /genres`), and a
catalog genre opens Apple's charts. The library's genres are the ones its
songs carry ("Alternative & Punk" on an iTunes rip, "Punk" on a song added
from Apple Music), from the iTunes Library index, with Apple's raw genre ids
given their names. omarock browses them as it does mpd's: a genre opens to
its artists, then their albums.

- **In search,** `library.genres` lists the genres whose name contains the
  query, folded as the rest of search is (case and accents aside), at most
  `limit`, the most songs first. A genre's `songs` counts its songs; `years`
  counts them by year, so omarock's Time Machine can count those from its
  year or before (and leave out a genre with none) without asking again.
- **`GET /genres/library/{id}`:**
  - `albums`: every library album with a song in the genre, by artist, then
    year. Each is an Album as the library routes give it, and opens through
    `/albums/library/{id}`. `artist` is the album artist (else its songs'
    artist), with an `artistId` that opens through `/artists/library/{id}`
    (left out when no song names that artist, as for "Various Artists").
    `trackCount` counts the album's songs **in this genre**. `isCompilation`
    is true for a compilation (ITLib's flag).
  - `songs`: every song in the genre, short: `id` (a library song id, as
    `POST /play` takes with `"kind": "song", "source": "library"`), `year`
    (omitted when unknown) and `duration`. omarock picks from these for
    Shuffle, Time Machine's year applied.
- An album that wouldn't open, or a song that wouldn't play, is left out.
- omarock-spotify has no genres: its search has no `genres`, and it has no
  such route.

### Items

Wherever a request takes `items`, each is `{ kind, id, source }` and the
bridge expands it to songs: a song is itself; an album or playlist is its
tracks in order; an artist is their top songs; `{ "kind": "queue" }` is the
whole current queue (for "Save the queue as a playlist"). Unplayable songs are
skipped, and later detail responses mark them `"playable": false`.

### Status

```jsonc
{ "seq": 118, "state": "playing",          // playing | paused | stopped
  "song": Song,                            // absent when nothing is loaded
  "position": 73.2, "positionAt": 1792419810.25,  // seconds; Unix time it was read
  "queue": [Song, …], "queueIndex": 3,     // at most 200 entries around the current one
  "queueOffset": 0,                        // index of queue[0] in the whole queue;
                                           // queueIndex is in the whole queue too, so the
                                           // current song is queue[queueIndex - queueOffset]
  "queueLength": 23, "shuffle": false, "repeat": "off",
  "elsewhere": "dellxps" }                 // only to a machine the Mac isn't playing for
```

`seq` goes up on every change omarock would show: the song, the state, the
queue, shuffle, repeat or the owner (below). It does not change for position alone; omarock works
the position out from `position`, `positionAt` and `state`.

Songs in `song` and `queue` carry `albumId` and `artistId`, which open with
`GET /albums/{source}/{albumId}` and `GET /artists/{source}/{artistId}` (the song's
`source`). A catalog song's can arrive a moment after the song does, with a new `seq`.

Catalog songs also carry `inLibrary`, true or false as `/info` would answer it. It's
omitted while the bridge can't tell yet, and can arrive a moment after the song. When it
lands or changes (an add, or the library index reloading), `seq` goes up. Library songs
leave it out (`/info` tells one that's only on a playlist added to the library).

### One machine at a time

The Mac has one Apple Music queue, so it plays for one machine at a time: the
**owner**, the machine that last started or took over playback. Requests that make the
sender the owner, by its `X-Omarock-Client`:
- `POST /play` with `mode` `play` (not `next` or `add`).
- `POST /resume`, and `POST /queue/jump`.
- `POST /toggle` when it resumes, or when it comes from another machine while the Mac
  plays for the owner (then it doesn't pause: it takes playback over).

A request without the header (omarock-am, older panels) leaves the owner as it is. The
bridge forgets the owner when it restarts.

To any other machine, while the Mac is playing:
- `GET /status` (long polls too) and the transport replies carry
  `"elsewhere": "<owner>"`. `state` stays the truth (`playing`); omarock shows it as
  paused here and stops listening to the stream, without pausing the Mac.
- `POST /pause`, `/next`, `/previous` and `/seek` answer 409
  `{"error": "Apple Music is playing on dellxps: Play moves it here"}`, a sentence
  omarock shows as is.

While the Mac is paused or stopped, nobody gets `elsewhere` or a 409. Requests without
the header never do. When the owner changes, `seq` goes up, so every waiting long poll
returns, each answered for its own machine. Everything else (shuffle, repeat, adding to
the queue, the library, playlists, `/info`) works the same from any machine.

## Behaviour

- **Nobody listening, nothing playing.** When the Icecast mount has had no
  listener for 30 seconds while the bridge is playing, the bridge pauses. So
  if mpd stops, or omarock isn't running, the Mac doesn't stream Apple Music
  for nobody. (The mount is hidden, so `/status-json.xsl` leaves it out; the
  bridge reads its `<listeners>` from `/admin/stats` with the admin password.)
- The Mac stays awake while playing (an IOPMAssertion), and only then.
- Only the bridge's own playback is captured and muted on the Mac; the Mac's other
  apps and the Mac's default output are never touched.

## How omarock uses it

- **The mode lives in mpd.** Apple Music mode means mpd is playing the bridge
  stream (a queue entry whose file is the stream URL), so `mpc` shows the mode
  too. Switching to Apple Music adds the stream after the current song and
  plays it. Switching back deletes that entry, which leaves the local queue as
  it was.
- In Apple Music mode, omarock's transport, search, browse, queue and bar go
  to the bridge. Volume stays mpd's.
- mpd paused on the stream (the media keys, `mpc pause`) pauses the bridge and
  stops mpd, so playing again reconnects to the live stream instead of resuming
  behind it; mpd playing again resumes the bridge.
- The bridge paused or stopped for a minute (omarock's `appleIdleStop`) stops mpd
  too, so the mount has no listener. That frees the bridge for updates, and nothing
  trickles over Tailscale. Playing again reconnects.
- The command-line tool on the Linux machine, `tools/omarock-am`, wraps these
  endpoints (curl and jq), so Apple Music can be driven from a terminal the way mpd
  is with mpc.
