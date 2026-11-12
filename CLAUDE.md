# omarock, for Claude Code

omarock is a music player for the Omarchy bar: a Quickshell plugin (the QML and
JS at the top level) that is a client for mpd. mpd holds all the state (the
queue, playlists, playback), so `mpc`, the media keys and omarock always agree.
The one thing outside it is History, what's been played from every source,
which `tools/omarock-history` lists. Optional services add more sources: `spotify/` (Spotify through Spotify's
Soloist player), `sxm/` (SiriusXM), and `apple-bridge/` (Apple Music, through an app
on a Mac). `audio/` is an optional PipeWire bus that gives omarock one volume
and pins its sound to one output.

## Helping someone set it up

The quickest route is `./install`, which the user runs in a terminal of their
own: it asks questions with gum, so it can't run from Claude's shell. It sets up
local music and the radio. Spotify, SiriusXM, Apple Music and omarock's sound
output (the audio bus) are each set up on their own: **Set up…** in omarock's
settings opens the piece's setup window (Setup.js), which takes its keys or
login, then runs `./install spotify` (and so on) in a terminal, and `./install
--remove PIECE` takes one off again. `tools/omarock-sources state` shows what's
set up, and `tools/omarock-doctor` anything left to do.

Use the `omarock-setup` skill (`.claude/skills/omarock-setup/`) to help with what
the installer didn't finish, or to set up step by step instead. It checks what's
there, then walks through mpd, the plugin, and each optional source, one at a
time. Each source has its own guide: `spotify/README.md`, `sxm/README.md`,
`apple-bridge/README.md`, `audio/README.md`.

Rules while setting up or fixing someone's system:
- **Never print secrets:** anything in `~/.config/omarock/` that holds a key, a
  token or a password (`soloist-key`, `spotify-token.json`, `siriusxm.json`,
  `bridge-token`). Check that they exist and their permissions, not their contents.
- **Ask before changing system config:** mpd.conf, `~/.config/omarchy/shell.json`,
  PipeWire or WirePlumber config, systemd units. Back a file up before editing it,
  and say what changed.
- **The audio bus's output is a safety choice.** Some machines have outputs that
  must never carry music, a radio transmitter's audio interface, say. The bus
  plays only into the output `tools/install-audio --output` pinned. Never pick it,
  or change it, without the user.
- **Starting music is the user's call.** Don't play, skip or switch sources on
  someone's system just to test; ask first.
- **Services are installed from a commit** (`tools/install-audio`,
  `tools/install-spotify`), never run from the working tree.

## Working on omarock

`DEVELOPING.md` has the layout, the tests and how omarock works inside. In short:
- `node --test tests/*.test.js`: the pure helpers (Mpd.js, Apple.js, Info.js and others).
- `tools/capture/capture.py [out-dir]`: the real panel, offscreen, against fake
  mpd, fake services and a fake Radio Browser; it saves screenshots and fails on any
  QML warning. `--only NAME,…` runs some scenarios.
- `audio/test-bus.py`: the audio bus on a throwaway PipeWire.
- `spotify/test_service.py`, `spotify/test_soloist_key.py`, and `dbus-run-session -- python3 -I spotify/test_mpris.py`.
- Before a release, `tools/capture/argv-survey capture` and, in a test VM,
  `tools/capture/argv-installer`: nothing private on any command line
  (DEVELOPING.md, "Branches and releases").

Tests never touch the user's real mpd, PipeWire or services. Keep it that way:
fakes, a scratch mpd with mpd's `null` output, or a private PipeWire.

Work goes on the `dev` branch; `main` holds releases, which is what Omarchy
installs (DEVELOPING.md, "Branches and releases").

Before installing a change to the live bar, run `omarchy plugin validate .`. Then
`omarchy plugin update marcewing.omarock`, and `omarchy restart shell` to load it: the
shell's own plugin reload keeps running the old code from Qt's cache. Watch
`journalctl --user | grep omarchy-shell` afterwards; the panel logs
`omarock <version> loaded`.
