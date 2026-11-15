# Developing omarock

## Coding agents

The tree has no instructions for coding agents: no `CLAUDE.md`, `AGENTS.md`,
`.claude/` or `.agents/`. An Omarchy plugin install copies the whole repository
into `~/.config/omarchy/plugins/`, so an agent someone runs over `~/.config`
would find them and follow them without being asked. `tests/docs.test.js`
keeps it that way. To use them, opt in:
- The setup skill is `docs/claude/omarock-setup/`: copy it into
  `~/.claude/skills/`, then run `claude` in the clone.
- To work on omarock with Claude Code, import this file from your own,
  untracked `CLAUDE.local.md`: a line `@DEVELOPING.md`.

An agent helping set up or fix someone's system:
- **Never prints secrets:** anything in `~/.config/omarock/` that holds a key, a
  token or a password (`soloist-key`, `spotify-token.json`, `siriusxm.json`,
  `bridge-token`). It checks that they exist and their permissions, not their
  contents.
- **Asks before changing system config:** mpd.conf,
  `~/.config/omarchy/shell.json`, PipeWire or WirePlumber config, systemd
  units. It backs a file up before editing it, and says what changed.
- **Treats the audio bus's output as a safety choice.** Some machines have
  outputs that must never carry music (a radio transmitter's audio interface,
  say). The bus plays only into the output `tools/install-audio --output`
  pinned; the agent never picks it, or changes it, without the user.
- **Leaves starting music to the user.** It doesn't play, skip or switch
  sources on someone's system just to test.
- **Installs services from a commit** (`tools/install-audio`,
  `tools/install-spotify`), never runs them from the working tree.

Tests never touch the user's real mpd, PipeWire or services: fakes, a scratch
mpd with mpd's `null` output, or a private PipeWire.

## Layout

| File | What it is |
| --- | --- |
| `install` | The guided installer (bash and gum): mpd, the plugin, then each source, using the `tools/install-*` scripts |
| `manifest.json` | The plugin's manifest |
| `Settings.js` | omarock's settings: what each is, the settings screen's tabs and groups, and how a value is found (`~/.config/omarock/settings.json`, else the widget's entry in shell.json, as before 0.6, else its default) |
| `BarWidget.qml` | The bar: cover and song; loads the panel once |
| `Panel.qml` | The popup: compact and expanded layouts, keys, search, browsing, the sources |
| `MpdClient.qml` | The mpd connection: an idle socket for change events, a command socket; the volume (mpd's, or the audio bus's) |
| `Mpd.js` | Pure helpers: quoting, parsing, accent-insensitive patterns, albums, covers |
| `PlayerCard.qml` | Now playing, seek, transport, volume |
| `TrackRow.qml`, `CoverArt.qml` | A row of any list, and a cover with a placeholder |
| `ArtCache.qml`, `ArtStore.js` | Remote cover art (Apple Music's, Spotify's, SiriusXM's, a station's logo, a stream's ICY artwork) as the local files `tools/omarock-art` makes of it, the only thing a cover's Image is given (below, "Covers, fetched and checked outside the shell"); one answer serves every panel (`ArtStore.js`) |
| `KeysHelp.qml`, `InfoCard.qml`, `PlaylistPicker.qml` | The key list (`?`, over the panel or in its own window), the info card (`i`), the playlist picker (`A`) |
| `Hints.js` | Pure helpers: the hint line's keys, fitted to its fixed number of lines |
| `Paging.js` | Pure helpers: where PgUp and PgDn take the cursor (the first or last row in full view, then a page on), for the panel's lists, the settings and the playlist picker |
| `GuardedField.qml`, `Editing.js` | Every text field omarock has: Omarchy's, but read-only to Qt, always, so Qt never reads the clipboard into it; the field does its own typing, deleting, cut and undo (`Editing.js`, pure, tested), and a paste goes through `wl-paste`, at most 4 KB and 2 s. Its owner takes its keys through `keyPressed` (below, "The clipboard, read only on a paste") |
| `Wave.js`, `WavyOutline.qml` | The search box's wavy outline while Time Machine keeps search to its year: the path (pure, tested), and the shape drawing it in the field's own colors |
| `SettingsView.qml` | The settings (`,` or the gear): Settings.js as a form, each source with its service's state; settings go into settings.json, accounts, keys and the music folder through `tools/omarock-account` |
| `Setup.js`, `SetupView.qml` | A piece's setup window (Set up…): how it works, what it needs, links, and its fields (checked live against the bridge for Apple Music); Start setup saves them through `tools/omarock-account`, then runs `./install PIECE` in a terminal with the window's choices (`--yes terms`, `--output NAME`) |
| `Info.js` | Pure helpers: the info card's contents for each source |
| `AppleClient.qml`, `Apple.js` | A client for the bridge API (apple-bridge/API.md), shaped like MpdClient; Apple Music's and Spotify's rows and views |
| `SxmClient.qml`, `Sxm.js` | SiriusXM, through omarock-sxm |
| `RadioClient.qml`, `Radio.js` | Radio Browser: search, local stations, favorites (the mpd playlist "Radio"), ICY titles (each station's form, "Artist - Title" or "Title - Artist" and a show's name in front, learned from your library and kept in `~/.cache/omarock/radio-titles.json`) |
| `ScrollingText.qml` | One line that scrolls when it doesn't fit: the bar's song (a setting) and the now playing card's song, artist and album |
| `Places.js`, `places.tsv` | Where "Your area" is, and the regions near it, from GeoNames' cities of 15,000 people or more (`tools/build-places` makes the file) |
| `TimeMachine.js`, `ChartClient.qml`, `YearPicker.qml`, `Keeper.js` | Time Machine: the year filter for Apple Music and Spotify (mpd's is `Mpd.yearPattern`), Billboard's year-end chart read from Wikipedia's wikitext, its songs found on Apple Music or Spotify (cached in `~/.cache/omarock/charts`), and the box that asks for the year (`t`); the panel keeps the queue to the year (`Panel.keepQueueInYear`, `MpdClient.removeAfterYear`); with a panel on each bar, one keeps the queue (`Keeper.js`, shared by them all) |
| `StdinProcess.qml` | A command given its input on stdin, never its command line: how the panel writes its files (the settings, History, its caches) and sends HTTP |
| `Job.qml` | Every command the panel runs is one (StdinProcess too): a Process stopped past its deadline, and whose start that fails ends as an exit with code 127 and no output (below, "Bounded answers, finite helpers") |
| `Fetch.qml`, `Reply.js` | HTTP for the panel, through curl, capped and on time, the request on curl's stdin; and the look over an answer from outside before it's parsed (pure, tested) |
| `History.js`, `HistoryClient.qml` | History (`H`): what's been played here, from every source, in `~/.local/share/omarock/history.jsonl` (a line of JSON a play), for `historyDays`. `Panel.tickHistory` counts how long the song playing has been heard (half of it or 4 minutes; a station's song 30 s; the file-only `historyAfter` for tests); one panel adds plays (`Keeper.js`'s "history" job). Rows replay by where they were heard (`Panel.activateHistory`); `tools/omarock-history` reads it |
| `audio/` | The optional PipeWire bus (one volume, one pinned output) and its guard: "omarock's sound output" in the settings |
| `spotify/` | omarock-spotify (the bridge API for Spotify), Soloist's unit and the shim loaded into Soloist (`omarock-soloist-shim.c`: its key off its command line, its control port for your account alone), the Web API client, MPRIS |
| `sxm/` | omarock-sxm, the SiriusXM relay |
| `apple-bridge/` | The Apple Music bridge, a macOS app, and its API (`API.md`) |
| `patches/` | The mpd-mpris patch that makes Apple Music's stream play well, and the mpd one (merged upstream) |
| `tools/` | Installers (`install-audio`, `install-spotify`, `install-sxm`, `update-soloist`, `build-mpd-mpris`; `pin-sxm` writes `sxm/requirements.txt`), CLIs (`omarock-am`, `omarock-sp`, `omarock-volume`, `omarock-account`, `omarock-sources`, `omarock-resolve`), the panel's cover fetcher (`omarock-art`), and the test harness (`capture/`) |
| `tests/` | node tests for the pure helpers, and `test_art.py` for `tools/omarock-art` |

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
  (apple-bridge/API.md), so AppleClient and Apple.js serve both.
- **Out of reach.** While the Apple Music bridge or omarock-spotify can't be
  reached, AppleClient asks for `/v1/health` every 3 s (Spotify's every 30 s
  unless it's the source), and starts the status long poll only once health
  answers: a long poll sent while the network is down answers only after its
  25 s wait, so the panel would say "Not connected" that long after the
  service was back. Spotify stays the source meanwhile ("Not connected"), as
  Soloist plays on without omarock-spotify; leaving it then sends the release
  once the service answers. `--only reconnect` covers all three, with
  `fake_mpd`'s `fake_stream_drop` and the fakes' `POST /v1/fake/offline`.
- **Quiet streams, mpd gone.** While a station or channel plays, MpdClient
  asks mpd's status every 5 s, from 15 s into the stream (never as it starts,
  when mpd has deadlocked): a clock that stood still since the last one, or
  mpd sitting 4 s on a command (a starved stream's buffer runs dry, then mpd
  answers no one), is `starved`, and the panel says "Buffering…". While mpd
  is down, `test -S` looks for its socket before each try: each try at a
  missing socket is a Quickshell warning in the journal. SiriusXM's art is
  shown only while omarock-sxm answers, for the same reason. `--only outages`,
  with `fake_mpd`'s `fake_stream_starve` and `fake_down`, and `fake_sxm`'s
  `POST /v1/fake/offline`.
- **The clipboard, read only on a paste.** On Qt 6.12 an editable text field
  reads the whole clipboard each time any program sets it while the shell
  has the keyboard (a panel open), shown or not, and a paste does the same,
  with no limit on its size or on how long it takes (Qt's fix,
  qtdeclarative bcbfae6761, isn't in Arch's Qt): a clipboard offering a huge
  or endless text would freeze the shell, and the bar and every plugin with
  it. So every field is a `GuardedField`, read-only to Qt, always, shown or
  not, and edits itself. In the test VM, with gdb counting
  `QQuickTextInput::q_canPasteChanged` and `QMimeData::text`, a clipboard
  set with omarock's panel open was read 18 times on 1.0.6 and 3 times
  with GuardedFields: the 3 are Omarchy's own fields, which read it with
  omarock switched off too. Selecting, copying, Ctrl+A, the arrows, Home and End
  stay Qt's. A paste (Ctrl+V, Ctrl+Shift+V, Shift+Insert, the Paste key; a
  middle click for the selection) runs `wl-paste` under `timeout` (2 s, then
  its process group is signaled, then killed) through `head -c 4097`: over
  4096 bytes, or no answer, nothing is pasted and the field says why
  (`refusal`). A paste whose field lost the keys, whose text changed, or
  that a newer paste overtook is stopped and dropped. Omarchy's Super+C,
  Super+V and Super+X send Ctrl+C, Ctrl+V and Ctrl+X to the panel
  (Ctrl+Shift+C and Ctrl+Shift+V with a terminal behind it), so both forms
  work: checked in the test VM's own shell, with fcitx5 running, with and
  without a terminal behind the panel. A field's owner handles its keys in `onKeyPressed`, which runs before
  the editing; `Keys.onPressed` on a GuardedField would run after it.
  Compose-key sequences and input methods (fcitx5 typing Chinese, say) don't
  reach a read-only field; dead keys do, and the field puts their accents on
  (`Editing.compose`). `tests/fields.test.js` fails on any text field in the
  QML that isn't `readOnly: true`; `--only guarded-fields` looks through the
  live panel's and setup windows' items for any that isn't, and types,
  deletes, undoes and pastes, with `fake-wl-paste` playing a normal, an
  endless, a slow and a late clipboard.
- **Bounded answers, finite helpers.** The shell runs every plugin and the
  bar on one thread, so no answer from outside may crash it or hold it. Qt
  6.12's `JSON.parse` crashes the whole shell (SIGSEGV) on one array of more
  than about 540,000 members, 1.1 MB of `[0,0,…]`, and Qt's XMLHttpRequest
  keeps every byte of an answer until it ends, with no cap, no word while it
  comes and no deadline of its own (a 114 MB answer arrives over loopback in
  0.6 s). So:
  - **HTTP goes through curl** (`Fetch.qml`): the request on curl's stdin as
    its config (`-K -`), the address and headers (the bridge's token) never
    on a command line; `--max-filesize` stops an answer as it passes the
    cap, `--max-time` the request at its deadline, counted from when it was
    asked for, waiting included, and a watchdog kills a curl that doesn't
    end; only http and https, no redirects, no proxy, no `~/.curlrc`. The
    status comes back, and the body only if it came whole. A few run at
    once (the bridge's 6, as Qt allowed a host), the rest wait their turn.
    Each client's cap comes from the real service's largest answers: the
    bridge 16 MB (a library playlist of thousands of songs was 5 MB, the
    largest genre 0.6 MB), 1 MB for a status (at most 200 songs of the
    queue) or a POST's answer, 64 KB for health; omarock-spotify 8 MB (at
    most 1,000 songs a list); omarock-sxm 2 MB (its channels are 200 KB);
    Radio Browser 1 MB; the setup window's health check 64 KB; Wikipedia's
    chart 1 MB (`ChartClient`'s own curl). An answer refused for its size
    says "…'s answer was too big to read".
  - **Every answer is looked over before it's parsed** (`Reply.parse`): one
    pass, skipping over strings, refuses one over the cap, with an array or
    object of more than 100,000 members, or nested deeper than 256, and cuts
    a string over 20,000 characters (laying out megabytes of one title
    would hold the shell too). At worst it takes about half a second over
    16 MB in the shell, as long as `JSON.parse` itself: the caps keep both
    short.
  - **The services bound what they pass on**: omarock-spotify reads at most
    4 MB of Spotify's answer within 30 s, start to end (urllib's timeout is
    for each read, so a trickle renewed it for ever), never follows a
    redirect or a page off Spotify's API, reads at most 1,000 songs of an
    album, cuts each text it passes on to 1,000 characters (an album's name
    went into each of its songs) and refuses an answer over 8 MB;
    omarock-sxm passes on at most 1,000 channels and entries of what's on
    now, each text 1,000 characters.
  - **Every command the panel runs is a `Job`**, with a deadline. A start
    that fails (no such program; no fork under a pids or memory limit) ends
    as an exit with code 127 and no output: Quickshell 0.3.2 then says only
    that it isn't running, with no started, no exited and no end of its
    output, so whatever waited on those (Time Machine's chart fetch, the
    radio's cache, mpd's socket probe) waited until the plugin reloaded. A
    pipeline whose children could outlive it runs them under `timeout -k`,
    which stops them all; the lists other machines and programs fill
    (Bonjour's, the tailnet's, PipeWire's outputs) are capped with `head -c`.
  - Time Machine reads at most 600 characters of a service's title:
    `titleKey`'s patterns grow with the square of a run of spaces.
  - The radio keeps at most 1,000 stations it has seen, besides the
    favorites, the local ones and the one playing.

  `--only bounded` has the fakes answer as a hostile server could
  (`tools/capture/hostile.py`: 1.2 MB of `[0,0,…]`, an endless answer, one
  that trickles) and checks that each client fails within its deadline with
  its usual words while the shell stays up, and works after; a curl that
  can't start, or never ends (`stuck-curl`), is a failed request, not a lost
  one.
- **Opt-in sources.** A source's switch (`spotify`, `appleMusic`, `siriusXM`,
  `radio`) gives it a button and lets omarock talk to its service; switched off,
  omarock doesn't contact it.
- **Nothing private where other accounts can see it.** Any account on the
  machine can read every process's command line (`ps`), so keys, tokens, the
  pairing code, the Apple Music stream's address (it has a secret in it) and
  whatever the panel writes to a file go to commands on stdin: `StdinProcess`,
  `tools/omarock-account`, `curl -K -`. omarock's files are 0600 in 0700
  folders, and mpd's too (`./install`). Soloist takes its key only as an
  argument, so its unit gives it `@key`, and `omarock-soloist-shim.so`, loaded
  into Soloist alone, hands it the key from its file. The harness writes
  command lines down (`argv-log`, standing in for the panel's sh and jq;
  `argv_logger`, for the tools), and the private-files, history, setup and
  apple-network scenarios check that none of these is on one. The commands
  the docs and setup windows show people follow the same rule:
  `tests/docs.test.js` fails on one that would put a token, a key, a login or a
  file's contents (read into an argument with `$(…)`) on a command line. Before
  a release, `tools/capture/argv-survey` logs every program started, everywhere
  (below).
- **Your account's alone.** Every account on the machine can reach 127.0.0.1,
  so omarock-spotify (8730) and omarock-sxm (8720) look up who owns the other
  end of each connection in the kernel's socket table (`/proc/net/tcp`, `tcp6`:
  the far end's line, local and remote addresses swapped, and its uid) and
  refuse any account but their own, before reading the request; a far end
  that has already closed (listed with no inode, or as uid 0 in TIME_WAIT: no
  owner left to check) is refused too, and logged as such. The `X-Omarock: 1` header
  and the Host check are for web pages, which run as you. Soloist's control
  port (8731) has no sign-in, and its Connect discovery (every interface)
  takes a sign-in from whoever pairs, so the shim does the same in Soloist's
  `accept`: a connection from this machine (from a loopback address, or one of
  its interfaces' own: `getifaddrs`) reaches Soloist only if it's this
  account's. One from another machine (a phone pairing) isn't in this
  machine's socket table, and is handed over as before. Your browser runs as
  you, and a web page can open a WebSocket to 127.0.0.1 (Soloist checks no
  Origin), so of this account's connections the shim also closes one whose
  request has an `Origin` or `Sec-Fetch-` header, as every browser's does and
  omarock-spotify's and the Spotify apps' never do: it looks at the request
  with `MSG_PEEK` (Soloist still reads all of it), for up to a second.
- **Covers, fetched and checked outside the shell.** Qt's `Image` reads a
  remote image whole, with no limit on its size or on how long it takes, then
  decodes whatever its bytes say it is (Omarchy's Qt reads SVG, PDF, TIFF and
  WebP among its image formats), on the thread the bar and every plugin
  share; and a station's logo (Radio Browser's `favicon`) or a stream's ICY
  artwork is anyone's to choose. So no Image in omarock is given a remote
  address. `CoverArt` and the bar's cover show `ArtCache.local(url)`: mpd's
  own covers (`file://`) as they are, anything else only as a file
  `tools/omarock-art` made of it, and nothing (the note) until then or when
  it's refused. Asking is what fetches: a batch of addresses to each of three
  helpers at once, on stdin, the newest first (the rows in view). For each,
  the helper takes http or https only, at most 3 redirects (each checked, none
  from https to http), 10 s and 2 MiB in all, refused as it reads, and a
  server on this machine only if this account runs it (the socket table, as
  above). It keeps only what the bytes say: JPEG and PNG of at most 4096 a
  side, a PNG cut to IHDR, PLTE, tRNS, IDAT and IEND, its image data
  inflating to its size and no more, a JPEG cut to its frame, tables and
  scans and its JFIF and Adobe markers; a Windows icon (most favicons) or a
  GIF's first frame it draws into a PNG; SVG, WebP and the rest are refused.
  Files go in `~/.cache/omarock/art` (0700, its files 0600), named by the
  address's SHA-256. A refusal is remembered, a day, or 2 minutes for one that
  may pass (a server that didn't answer), so a bad address isn't fetched
  again each time its row comes into view; files unused for 30 days go.
  `tests/test_art.py` runs the helper against `tools/capture/fake_art.py`'s
  good and hostile art, and `--only remote-art` checks the panel with it
  (below).
- **The Mac's .local name, checked.** Any account here can publish a .local
  name through avahi while the Mac is away, and would then get what's sent
  to it: the bridge's token, a pairing code, the stream's secret.
  `tools/omarock-resolve` looks a .local name up through the avahi daemon
  itself (its D-Bus API, as nss-mdns does), which says whether the answer is
  a record published here, and refuses that, and any address that reaches
  this machine anyway (127.0.0.0/8, 0.0.0.0/8, its own addresses, ::1, ::,
  IPv4 in IPv6's form, with or without a scope). The tools then connect to
  the address it gave (curl's `--resolve`), rather than looking the name up
  again. A DNS or tailnet name, or an address, is taken as it is. The
  harness's `fake-busctl` answers for the names `$HOME/.fake-hosts` lists.
- **What comes from elsewhere, pinned.** Two optional pieces fetch code from
  outside Arch and this clone: Apple Music's patched mpd-mpris
  (`tools/build-mpd-mpris`) builds mpd-mpris's source from GitHub at a pinned
  commit, its Go modules checked against its go.sum (`-mod=readonly`); and
  omarock-sxm (`tools/install-sxm`) installs aiosxm and its dependencies from
  PyPI with `--require-hashes`, every file's SHA-256 in `sxm/requirements.txt`
  (`tools/pin-sxm` writes it). Each says so where it asks.
- **Soloist, your own download.** Soloist is the one program with nothing to
  pin it by: you download it from Spotify's page (Spotify publishes only an
  unversioned "latest" build, with no checksums or signatures, and doesn't
  allow passing it on), and omarock can't tell where a download came from
  (Firefox records it, in `user.xdg.origin.url`; Omarchy's Chromium doesn't,
  and a web page can start one under any name). So a download is installed
  only once you've seen it (name, size, when it was saved) and said yes, in
  `./install` or `update-soloist install`, and only if it's yours: another
  account's file, one other accounts can change, or one in a folder they can,
  is refused. Reading it is bounded (100 MB, a few hundred files, its program
  256 MB, a minute a step), on disk, not in `/tmp`.
  `tools/update-soloist` reads the download without running it (an x86-64
  program importing glibc's `__libc_start_main` and `accept`/`accept4`, which
  the shim needs; its build number, the time it was built, says whether it's
  expired), installs it, and checks it: Soloist's unit starts it with the shim,
  and its log has to say within 30 s that the shim handed over the key and
  guards the control port and the discovery port (it reaches each once from
  this machine). Its hash goes into `soloist.sha256`, which the unit checks
  at every start (exit 79 for anything else), with `soloist.checking` beside
  it until the check passes; then a copy is kept. A build that fails, or whose
  check is cut short, is swapped back for the last good one, and one whose
  check never finished (`soloist.checking` left over) isn't started.

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
python3 -I tests/test_art.py
python3 -I spotify/test_soloist_shim.py
dbus-run-session -- python3 -I spotify/test_mpris.py
apple-bridge/test-scripts.zsh                           # on a Mac: the bridge scripts
tools/capture/argv-survey capture [out-dir]             # before a release (long)
OMAROCK_THROWAWAY=yes tools/capture/argv-installer      # in a test VM only
OMAROCK_THROWAWAY=yes tools/capture/vm-checks           # in a test VM only
```

`capture.py` runs the real panel in Quickshell, offscreen, with a temporary HOME,
Omarchy's Ristretto theme and the software renderer. It serves a made-up library
from `tools/capture/fake_mpd.py` on the socket the panel uses, and fakes for
everything else:
- `fake_bridge.py` stands in for the Apple Music bridge, and, with `--spotify`,
  for omarock-spotify, watching the fake mpd as the real service watches mpd;
- `fake_sxm.py` for omarock-sxm;
- `fake_radio.py` for Radio Browser; its "Artcheck" stations' logos are
  `fake_art.py`'s art, good and hostile (an endless body, too big, 60 zTXt
  chunks of 7 MiB, an SVG, a PDF, a PNG claiming 30000 pixels a side, a
  redirect loop, one to `file://`, a trickle), served under `/art/`.
  `--only remote-art` checks that the good ones show and the rest show the
  note, that the shell's memory stays put, and that no Image in the panel, the
  bar or the setup windows has a remote source;
- `fake_charts.py` for Wikipedia: 1985's chart, in the shapes Wikipedia's pages
  use (1984's the same), 1982's in a page made to slow a parser down, 1983's
  too big to read, and no page for any other year;
- `fake-systemctl` and `fake-terminal`, first on the panel's PATH: a systemctl
  that only logs and keeps the units "enabled" in the test HOME, and Omarchy's
  terminal launcher, which plays a setup or removal out on the test HOME's
  files (as `./install` would leave them) without a terminal or `./install`;
  `fake-tailscale`, `fake-avahi-browse` and `fake-pactl` give the setup windows
  a tailnet's Mac, the bridges "on the network" that `$HOME/.fake-avahi` lists,
  and two outputs, `fake-hyprctl` stands in for the compositor (a window it
  says is tiled gets floated). `ssh` and `scp` there fail at once: nothing
  should reach another machine. The fake bridge pairs (API.md): `POST
  /v1/fake/pair {code, tries, seconds}` opens a code, as the Mac's installer would.
  The test HOME starts with Spotify and SiriusXM "set up"; `--only setup` sets
  pieces up and removes them through the settings.
- `fake-wl-paste` for the clipboard: it prints `$HOME/.fake-clipboard`
  (`.fake-primary` for the selection), or, as `$HOME/.fake-clipboard-mode`
  says, never ends ("endless"), doesn't answer ("slow") or answers a second
  late ("late"). The harness's `WAYLAND_DISPLAY` names no display, and the
  fake fails without one, as the real one does.
- `hostile.py`, with which the bridge's, omarock-spotify's, omarock-sxm's and
  Radio Browser's fakes answer as a hostile server could (`POST
  /v1/fake/hostile`), and `stuck-curl`, a curl that never ends: `--only
  bounded`. The panel's sh, jq and curl are the real ones, writing their
  command lines down while a scenario asks (`argv-log`).

The panel finds the fakes through settings that are in no settings screen,
only in the file (Settings.js): `spotifyService`, `sxmService`, `radioBrowser`,
`chartSource` and `appleTokenFile`. Pointing them elsewhere on a real machine
works the same.

`apple-bridge/test-scripts.zsh` runs the Mac installer's and `build.sh`'s
helpers against a stand-in bridge on a scratch port, with a scratch support
folder and no control socket, so they ask over TCP, as they do when the bridge
is down and another account may hold its port. zsh's math runs any `$(…)` in an
array subscript (`path[$(cmd)]`), so only digits from the bridge may reach
`(( ))`: it serves such values and checks that nothing runs.

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
  real mpd behavior.
- **`--real-mpd`** only reads.
- **The `real-*` scenarios** read from a real Apple Music bridge through a proxy
  that refuses anything but GETs. They need `OMAROCK_REAL_BRIDGE` and
  `OMAROCK_REAL_STREAM`.

Nothing touches your mpd's queue or playlists, your PipeWire, or the live bar.

**The installer** changes the system it runs on, so test it in a throwaway Omarchy
VM, never on your own desktop. Each run (`./install`, `./install PIECE`,
`./install --remove PIECE`) writes how it went to
`~/.local/state/omarock/setup.json`: running (with its pid), then done, failed or
stopped (Ctrl-C, or the terminal closed: exit 129, 130, 143); the settings
follow it through `tools/omarock-sources state`.
`OMAROCK_INSTALL_ANSWERS=FILE ./install` runs it
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
omarchy plugin update marcewing.omarock          # after each commit
omarchy restart shell
journalctl --user -b | grep omarock         # "omarock <version> loaded"
```

The bar loads committed work only. The shell's own plugin reload isn't enough
for a changed plugin: Quickshell has no `Qt.clearComponentCache()`, so the reload
gets the old compiled QML back from Qt's cache. `omarchy restart shell` starts a
fresh process. Any plugin's reload (yours or another's) also makes omarock again
from scratch, so each source must come up on its own, without the panel being
opened; `--only fresh-start` checks that. A `file://` clone follows the branch
this checkout has out.

## Branches and releases

Work goes on `dev`, and pull requests too. `main` holds releases only:
`omarchy plugin add` and `omarchy plugin update` install main as it is on
GitHub, and the Omarchy marketplace marks any main commit newer than the one it
verified "Update unverified" until that one is verified too. A release bumps the
version (`manifest.json` and `Panel.qml`), merges `dev` into `main`, tags it
`vX.Y.Z`, and asks the marketplace to verify that commit (its Plugin verification
form).

Before a release, nothing private may be on a command line, which any account
on the machine can read. Two runs check it, logging every program started
with its whole command line (`tools/capture/execlog.c`, loaded with
`LD_PRELOAD`), then searching the log for the made-up secrets the tests plant:
- `tools/capture/argv-survey capture`: the whole harness, the panel and its
  fakes (as long as the harness takes).
- `tools/capture/argv-installer`, in a test VM, never on a machine you use:
  `./install`, every piece set up and taken out, `--uninstall`, and the tools,
  with Spotify's and SiriusXM's hosts pointed at the VM itself and a stand-in
  Soloist (`soloist-standin.c`: the real one announces itself on the network),
  downloaded into `~/Downloads`.

Each ends with "Planted secrets on a command line: none", or fails. Each also
lists arguments shaped like a file's contents (several lines, long, JSON):
read them, since jq's and python3's own programs look like that too.

And `tools/capture/vm-checks`, in a test VM too, for what takes a second
account and a Soloist that comes and goes: another account is refused by
omarock-spotify, omarock-sxm and Soloist's control and discovery ports, and
this one isn't, nor (on the discovery port) another machine, which a network
namespace plays; a
Soloist put in by hand isn't started until it's checked; builds that can't work
with the shim are turned down, by reading them or by running them (and the
last good one put back); an expired one is turned down; and a newer download
is installed by `./install spotify`. It ends with "0 failure(s)".

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
- mpd's filters can't compare tags, so Time Machine's "this year or before" is
  a pattern on the Date tag's first four digits (`Mpd.yearPattern`: 1996 is
  `^(1[0-8][0-9]{2}|19[0-8][0-9]|199[0-5]|1996)`), ANDed onto each query.

**Time Machine's charts**
- Wikipedia's year-end pages (Hot 100 from 1959, top 50 for 1956–58, top 30 from
  1949) all parse with `TimeMachine.parseChart`, checked on every year to 2025:
  `|1 || "Title" || Artist` rows, a rank as a row header on its own line
  (2021 on), artists spanning rows, sort values, references, double A-sides
  and ties (two songs at 50 in 1958, at 100 in 1969).
- The page comes from the network and is parsed on the shell's one thread,
  which every plugin and the bar share. So `ChartClient` reads at most 1 MiB
  of it (curl's `--max-filesize`, which stops a transfer as it passes; the
  real pages are 4 to 17 KB) in 20 s, and `parseChart` doesn't read it over
  and over: the patterns it used before grew with the square of a page full
  of `<!--` never closed, or of `{|` with no table (70 ms for 20 KB in the
  shell, so minutes for 1 MiB), and now a hostile 1 MiB page takes under
  0.1 s there. It reads no more rows than the chart has (and a
  few for headings and ties), keeps places 1 to the chart's size, each title
  and artist at most 300 characters, and looks for a cell's attributes in its
  first 500; a chart or songs read back from `~/.cache/omarock/charts` are
  held to the same. Rewritten so, it gives the charts the patterns gave for
  all 77 years, and their text on 600,000 random strings
  (`tests/timemachine.test.js` keeps 20,000).
- Checked against the real catalogs (read-only searches): 99 of 1996's 100 and
  99 of 1965's 100 found on Apple Music, 15 of 15 sampled on Spotify. Some
  1960s songs are only there as later re-recordings, which then stand in.
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
  - Repeat-one reconnects a stream only while its server answers. A refused
    or reset connection (the network down, omarock-sxm restarting) stops mpd
    for good once its buffer (about 45 s) runs out. A network that drops
    packets keeps the connection, and mpd plays on about 10 s after it's back.
    So a live stream that had played for 5 s and stops on any error but a
    refusal (HTTP 4xx) is played again after 2, 5, then every 10 s, for
    `streamRetryFor` (5 minutes), the card saying "Reconnecting…"
    (`Panel.retryStream`; one panel plays it, Keeper.js). Seen in the test
    VM: a real station, the internet refused for 90 s, played again 22 s
    after it was back with 30 s steps.
  - mpd 0.24.15 has deadlocked when sent more commands while a stream started on
    its PipeWire output. omarock sends plain `playid` and nothing else then.
- `setvol` can take seconds while mpd plays a stream, so the volume knob holds
  where it was let go until mpd reports it.
- MpdClient logs any command slower than 0.7 s, and AppleClient every transport
  request, to tell a slow service from a queue in omarock.

**Apple Music's stream**
- **The lag:** libFLAC's Ogg reader fills each 8 KiB read before returning. On a
  live stream of digital silence (a paused Mac), ffmpeg's FLAC encoder sent about
  300 bytes a second, so that took tens of seconds, and mpd then played that far
  behind.
  - From bridge 0.7.0 libFLAC encodes the stream, with `limit_min_bitrate`
    (xiph/flac#90's answer): silence still sends about 6 KB/s. A stock libFLAC
    joining a paused stream stays about 1.7 s behind, against 1.2 s with the reader
    patched (xiph/flac#939, closed in favor of the encoder option). Health's
    `minBitrate` says the stream is that one.
  - For an older bridge, omarock reconnects mpd to the stream 2 s after each
    change (`appleRejoin`), at the cost of a short stutter.
- **What's shown is what's heard:** mpd still plays the stream behind the Mac:
  it buffers 1 s before it plays anything (hard-coded in mpd 0.24, player
  `buffer_before_play_duration`), then libFLAC's reads and the trip from the
  Mac add to that. AppleClient measures mpd's part 4 s after mpd joins the
  stream, then every 30 s (the time since it joined, less mpd's elapsed), and
  adds health's `streamDelay` (0.4 s when a bridge doesn't say). Heard.js then
  shows the bridge's statuses that much late: a song that starts by itself
  shows when it's heard, one picked here shows at once with its time cycling
  dots until its sound arrives, and after a pause the time runs on until the
  sound stops. Only while mpd plays the stream here: Spotify plays on this
  machine, and the stations' titles come inside their streams. `--only heard`
  (the fake mpd's `fake_stream_lag`, the fake bridge's `/v1/fake/streamdelay`
  and `/v1/fake/advance`).
- **The freezes:** mpd-mpris asks mpd for a stream's cover art on every player
  event, and mpd probes the stream for seconds to answer, holding every client.
  `patches/mpd-mpris-stream-art.patch` keeps a stream's art across events.

**QML and Quickshell**
- A ListView given a new array resets its position. omarock's lists use the row
  count as the model and read rows by index, so a list redrawn in place doesn't
  jump.
- A property whose name starts with `on` and a capital is taken for a signal
  handler's name, and silently never works.
- **A Process that fails to start** (Quickshell 0.3.2) logs "Process failed
  to start" and sets `running` false: no `started`, no `exited`, and its
  StdioCollector's `streamFinished` never comes. `running = false` sends
  SIGTERM, and `running` reads true until the process has exited. On a
  normal exit the order is `started`, the output's `streamFinished`,
  `exited`, then `runningChanged` to false. QML can emit a Process's
  `exited` and a collector's `streamFinished` itself, which is how `Job`
  ends a start that failed; a Process type's own handlers run before those
  set where it's used.
- A JS object given to `createObject` as a `var` property's first value
  arrives as a copy: `Fetch` keeps a request's entry in a closure instead.
- **A read-only text field (Qt 6.12)** still selects, copies, moves its
  cursor and says `accepted` on Enter, and its `insert()` and `remove()`
  still work, keeping a binding on `text` and sending `textEdited`; its own
  `undo()` doesn't. It draws no cursor, even with `cursorVisible` set, so
  GuardedField has a cursor delegate. It turns down every ShortcutOverride
  (a `Keys.onShortcutOverride` on it never hears one), so a `Shortcut` in
  its window takes its keys: the panel's Shift+←→ seek is off while a field
  has the keys. And a component's own `Keys.onPressed` runs before one set
  where it's used.
- Hyprland floats a Quickshell `FloatingWindow` whose minimum and maximum
  sizes are the same, and centers it. Without a fixed size it tiles. It decides
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
- **Qt 6.12's QtQuick has a `Color` singleton of its own** (`rgba`, `hsla`,
  `fromString`). It takes the name from Omarchy's `Color` in `qs.Commons`: a
  bare `Color.popups` reads as undefined. In the harness it happened partway
  through the run, after which every color came out undefined. So omarock
  imports `qs.Commons as Commons` and writes `Commons.Color`, as Omarchy's own
  files do since 4.5. `Style`, `Util` and `Border` don't clash.

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
- Soloist logs in once, at start. Started before the network (a boot), it says
  "login failed: make sure --api-key is valid" and stays logged out. Its unit
  waits until Spotify's name resolves. omarock-sxm's login at start waits the
  same way. A user unit can't use `network-online.target`: that's the system
  manager's, and the user manager has no such unit.

**Spotify's Web API, for an app in Development mode** (2026): search returns at
most 10 per page; no genres, browse categories or artist top tracks; the songs of
other people's playlists aren't listed; an artist's albums come at most 10 a page.
