# Developing omarock

## Layout

| File | What it is |
| --- | --- |
| `install` | The guided installer (bash and gum): mpd, the plugin, then each source, using the `tools/install-*` scripts |
| `manifest.json` | The plugin's manifest |
| `Settings.js` | omarock's settings: what each is, the settings screen's groups, and how a value is found (`~/.config/omarock/settings.json`, else the widget's entry in shell.json, as before 0.6, else its default) |
| `BarWidget.qml` | The bar: cover and song; loads the panel once |
| `Panel.qml` | The popup: compact and expanded layouts, keys, search, browsing, the sources |
| `MpdClient.qml` | The mpd connection: an idle socket for change events, a command socket; the volume (mpd's, or the audio bus's) |
| `Mpd.js` | Pure helpers: quoting, parsing, accent-insensitive patterns, albums, covers |
| `PlayerCard.qml` | Now playing, seek, transport, volume |
| `TrackRow.qml`, `CoverArt.qml` | A row of any list, and a cover with a placeholder |
| `KeysHelp.qml`, `InfoCard.qml`, `PlaylistPicker.qml` | The key list (`?`, over the panel or in its own window), the info card (`i`), the playlist picker (`A`) |
| `Hints.js` | Pure helpers: the hint line's keys, fitted to its fixed number of lines |
| `SettingsView.qml` | The settings (`,` or the gear): Settings.js as a form, each source with its service's state; settings go into settings.json, accounts, keys and the music folder through `tools/omarock-account` |
| `Info.js` | Pure helpers: the info card's contents for each source |
| `AppleClient.qml`, `Apple.js` | A client for the bridge API (bridge/API.md), shaped like MpdClient; Apple Music's and Spotify's rows and views |
| `SxmClient.qml`, `Sxm.js` | SiriusXM, through omarock-sxm |
| `RadioClient.qml`, `Radio.js` | Radio Browser: search, local stations, favourites (the mpd playlist "Radio"), ICY titles |
| `audio/` | The optional PipeWire bus (one volume, one pinned output) and its guard |
| `spotify/` | omarock-spotify (the bridge API for Spotify), Soloist's unit, the Web API client, MPRIS |
| `sxm/` | omarock-sxm, the SiriusXM relay |
| `bridge/` | The Apple Music bridge, a macOS app, and its API (`API.md`) |
| `patches/` | libFLAC and mpd-mpris patches that make Apple Music's stream play well (see bridge/README.md) |
| `tools/` | Installers (`install-audio`, `install-spotify`, `update-soloist`, `build-libflac`, `build-mpd-mpris`), CLIs (`omarock-am`, `omarock-sp`, `omarock-volume`, `omarock-account`), and the test harness (`capture/`) |
| `tests/` | node tests for the pure helpers |

## How it works

- **mpd holds the state.** The queue, stored playlists, playback and the library
  all live in mpd, so `mpc`, the media keys and omarock always agree. omarock keeps
  no music state of its own.
- **One player object.** `Panel.player` is MpdClient, or a client of the same
  shape for the source playing (AppleClient, SxmClient, RadioClient). The player
  card and the bar only read that shape.
- **The source follows from what's playing.** Apple Music, SiriusXM and the radio
  are mpd playing a stream: the bridge's, an omarock-sxm channel, or a station
  (whose URL carries `#omarock-radio=<uuid>`, which mpd keeps and never sends).
  Spotify doesn't play through mpd, so omarock-spotify keeps that mode instead
  (`current` in its status). `Panel.source` is computed once from all of that, and
  every mode follows from it, so the modes never disagree mid-update.
- **One API, two services.** omarock-spotify speaks the Apple Music bridge's API
  (bridge/API.md), so AppleClient and Apple.js serve both.
- **Opt-in sources.** A source's switch (`spotify`, `appleMusic`, `siriusXM`,
  `radio`) gives it a button and lets omarock talk to its service; switched off,
  omarock doesn't contact it.

## Tests

```bash
node --test tests/*.test.js
tools/capture/capture.py [out-dir]                      # everything, against fakes
tools/capture/capture.py --only bar,apple,spotify [out-dir]
tools/capture/capture.py --scratch-mpd ~/Music/SomeArtist [out-dir]
tools/capture/capture.py --real-mpd [out-dir]           # read-only, your mpd
tools/capture/capture.py --bus --only bus-volume        # with a private PipeWire
python3 -I audio/test-bus.py
python3 -I spotify/test_service.py
dbus-run-session -- python3 -I spotify/test_mpris.py
```

`capture.py` runs the real panel in Quickshell, offscreen, with a temporary HOME,
Omarchy's Ristretto theme and the software renderer. It serves a made-up library
from `tools/capture/fake_mpd.py` on the socket the panel uses, and fakes for
everything else:
- `fake_bridge.py` stands in for the Apple Music bridge, and, with `--spotify`,
  for omarock-spotify, watching the fake mpd as the real service watches mpd;
- `fake_sxm.py` for omarock-sxm;
- `fake_radio.py` for Radio Browser.

It drives the panel with real key presses (QtTest's event injector) and clicks,
saves screenshots, and fails on any QML warning from the plugin, or if the panel
sends mpd an output command.

The panel keeps its state when it closes. So the harness's `close` also resets
it (the search, browsing, cards, the cursor), which keeps each scenario
starting fresh; `hide` closes it the way the bar does, as `--only keep-state`
needs.

`--only hints` checks that the panel and its hint line keep their height,
whatever the hints or a notice say, and covers the keys window. Offscreen, a
newly shown window takes the keys, so the scenario hands them back to the
popup. Under Hyprland the open panel keeps them, as a run in the test VM showed.

- **`--scratch-mpd DIR`** starts a throwaway mpd over DIR. Its only output is mpd's
  `null` output, which plays to nowhere. It runs the playlist scenario against
  real mpd behaviour.
- **`--real-mpd`** only reads.
- **The `real-*` scenarios** read from a real Apple Music bridge through a proxy
  that refuses anything but GETs. They need `OMAROCK_REAL_BRIDGE` and
  `OMAROCK_REAL_STREAM`.

Nothing touches your mpd's queue or playlists, your PipeWire, or the live bar.

**The installer** changes the system it runs on, so test it in a throwaway Omarchy
VM, never on your own desktop. `OMAROCK_INSTALL_ANSWERS=FILE ./install` runs it
without gum, answering each prompt from FILE: a line per prompt, `TEXT=ANSWER`,
where TEXT is part of the prompt. Waits are cut to 20 s, and a prompt asked
5 times (a retry its answer can't end) stops the run.
- **Through gum:** `tools/capture/ptydrive.py` runs it in a terminal of its own
  (`ssh -tt` into the VM, say) and presses keys as each prompt shows up.
- **Idempotence:** run `tools/capture/install-fingerprint` before and after a
  run, and diff the two. A second run on a finished install must change nothing,
  and run no commands. Only unfinished or optional steps may ask again.
- **Uninstall:** fingerprint a machine before the install, then after
  `./install --uninstall`, answering yes throughout: the two must match, apart
  from what the uninstaller says stays (mpd's packages and config lines,
  its backups). A second `--uninstall` must find nothing. Then `./install` again,
  to show it comes back.

Offscreen Quickshell has no layer shell, so the harness swaps in
`tools/capture/KeyboardPanel.qml`. It draws the same card in an ordinary window,
bigger than the card, as the real popup is: that's what lets pointer moves off
the card still reach it.

## Trying a change on your bar

```bash
omarchy plugin validate .
omarchy plugin add file://$PWD --enable     # once: the bar loads from this clone
omarchy plugin update mre.omarock          # after each commit
omarchy restart shell
journalctl --user -b | grep omarock         # "omarock <version> loaded"
```

The bar loads committed work only. The shell's own plugin reload isn't enough
for a changed plugin: Quickshell has no `Qt.clearComponentCache()`, so the reload
gets the old compiled QML back from Qt's cache. `omarchy restart shell` starts a
fresh process. Any plugin's reload (yours or another's) also makes omarock again
from scratch, so each source must come up on its own, without the panel being
opened; `--only fresh-start` checks that.

## Findings worth knowing

**mpd**
- Quickshell's `Socket` is a QLocalSocket: unix sockets only.
- mpd's regex (`=~`) works on bytes: `[uü]` can't match ü, but `(u|ü)` can.
  `Mpd.searchPattern` builds such alternations, so "husker" finds Hüsker Dü.
- `listfiles <folder>` shows whether a folder has a cover before the panel asks
  for one, so albums without art don't log failed image loads.
- iTunes rips often lack AlbumArtist on compilations, and spread one album over
  several artist folders. So omarock treats an album as its name, not its
  folder, and spots the few names shared by different albums (`Mpd.sharedName`).
- mpd's `albumartist` filter falls back to `artist` only for songs with no
  AlbumArtist tag. A compilation tagged "Various Artists" never matches an
  artist's name that way. So an artist's page also finds their songs by
  `artist`, which brings in those compilations.
- **Streams:**
  - mpd's HTTP input gives up on a stream that sends nothing for about 10 s, and
    moves on through the queue. So live sources play in repeat-one mode (`repeat 1`,
    `single 1`, restored on local); a stream that drops then reconnects.
  - New streams go in at `+0`, after the current song, not at a position from
    omarock's possibly stale copy of the status.
  - Deletes go one at a time: a command list stops at the first entry already gone.
  - Stream entries are found fresh in mpd (`playlistsearch "(file starts_with …)"`)
    when the source changes.
  - `playid` to a stream holds every mpd client until it connects.
  - mpd 0.24.15 has deadlocked when sent more commands while a stream started on
    its PipeWire output. omarock sends plain `playid` and nothing else then.
- `setvol` can take seconds while mpd plays a stream, so the volume knob holds
  where it was let go until mpd reports it.
- MpdClient logs any command slower than 0.7 s, and AppleClient every transport
  request, to tell a slow service from a queue in omarock.

**Apple Music's stream**
- **The lag:** libFLAC's Ogg reader fills each read request before returning. On
  a live stream of near-silence, that can wait tens of seconds, and then mpd plays
  that far behind.
  - `patches/libflac-ogg-live.patch` returns what it has instead
    (`tools/build-libflac` builds it for mpd only).
  - Without it, omarock reconnects mpd to the stream 2 s after each change
    (`appleRejoin`), at the cost of a short stutter.
- **The freezes:** mpd-mpris asks mpd for a stream's cover art on every player
  event, and mpd probes the stream for seconds to answer, holding every client.
  `patches/mpd-mpris-stream-art.patch` keeps a stream's art across events.

**QML and Quickshell**
- A ListView given a new array resets its position. omarock's lists use the row
  count as the model and read rows by index, so a list redrawn in place doesn't
  jump.
- A property whose name starts with `on` and a capital is taken for a signal
  handler's name, and silently never works.
- Hyprland floats a Quickshell `FloatingWindow` whose minimum and maximum
  sizes are the same, and centres it. Without a fixed size it tiles. It decides
  as the window maps, so the keys window maps at a fixed size, then lets go of
  it after its first frame, and can be resized. (Seen on Hyprland 0.56.2.)
- A reply that lands while a plugin reload tears a client down can find the
  client there but its functions gone; the HTTP clients check for both.
- **Quickshell 0.3.2's `Socket` crashes the whole shell** if an `onError` handler
  sets `connected = false`. 0.3.2 hands the error over, then frees the socket if it
  isn't connected, without checking it's still there. The handler's disconnect
  has already freed it. MpdClient sets it with `Qt.callLater` instead. Without
  that, every mpd restart crashed the shell on Omarchy 4.0.6; 0.3.1 doesn't have
  the bug.

**PipeWire** (audio/)
- A stream with `node.dont-fallback` whose target is missing needs `node.linger`.
  Without it, WirePlumber fails it, and module-loopback unloads the whole bus.
- `pw-play` reports its own application name: match streams by `node.name`.
- PipeWire reads `$HOME/.config/pipewire` even with `XDG_CONFIG_HOME` set, so a
  test PipeWire needs a HOME of its own.

**Spotify's Soloist**
- Soloist reports the account's playback wherever it plays: on another
  machine, its status says playing while nothing plays here. `is_active` says
  whether this Soloist is the device playing; omarock-spotify's `heard()` is
  what plays here.
- Soloist's own play, pause and skip act on whichever device is active, so
  from an idle machine they reach another one. omarock-spotify moves the
  playback here with the Web API (`PUT /me/player`, this device's id) instead,
  and refuses pause, skip and seek while another device plays.

**Spotify's Web API, for an app in Development mode** (2026): search returns at
most 10 per page; no genres, browse categories or artist top tracks; the songs of
other people's playlists aren't listed; an artist's albums come at most 10 a page.
