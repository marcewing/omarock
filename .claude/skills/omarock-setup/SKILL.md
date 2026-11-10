---
name: omarock-setup
description: Set up omarock, the Omarchy bar music player in this repo, or any of its parts (mpd and its socket, the plugin, the audio bus, Spotify, Apple Music, SiriusXM), or find out why one isn't working. Use when someone asks to install, configure, switch on, update or troubleshoot omarock or one of its music sources.
---

# Setting up omarock

omarock is a plugin for Omarchy's bar, and a client for mpd. Local music and
internet radio need only mpd. Spotify, Apple Music and SiriusXM each need a
service set up, which also switches them on in omarock's settings. The guides
have the details: `README.md` (install), `audio/README.md`, `spotify/README.md`,
`sxm/README.md`, `apple-bridge/README.md`. Read the relevant one before a step; this
skill is the order to go in, and what to watch out for.

## The installer first

The installer is interactive, checking first and asking before each change. It
needs a real terminal (gum prompts), so it can't run from Claude's shell:
suggest the user run it in one of their own.
- `./install` in the clone sets up local music and the radio: mpd, then the
  plugin on the bar, and offers Super+Ctrl+M to open it (a marked line in
  `~/.config/hypr/bindings.lua`, if the key is free).
- Each source then has its own: **Set up…** in omarock's settings (`,` in the
  panel) opens its setup window, which takes the keys or login and then runs
  it in a terminal, or the user runs `./install spotify`,
  `./install siriusxm`, `./install apple-music` or `./install sound` (omarock's
  sound output, the audio bus: optional).
- Each can be run again any time, to finish or update. `./install --remove
  PIECE` takes one off with its accounts and keys, and `./install --uninstall`
  takes everything off, asking before each piece.
- `tools/omarock-sources state` shows what's set up (JSON, never a secret), and
  how the last run ended.

Then run `tools/omarock-doctor` and help with whatever is left, using the steps
below.

## Ground rules

- **Look first.** Run `tools/omarock-doctor` before anything else, and again after
  each step. It only reads, and says what's missing and how to fix it.
- **Secrets stay out of the conversation.** Never print, cat, or ask the user to
  paste a password, key or token: the Soloist key, `spotify-token.json`,
  `siriusxm.json`, the bridge's token. Have the user put it in the file themselves
  (`nano ~/.config/omarock/…`). Check that files exist and are mode 600, never
  their contents.
- **Ask before you change the system.** That means mpd.conf,
  `~/.config/omarchy/shell.json`, PipeWire or WirePlumber config, systemd units
  and firewall rules. Back a file up before editing it, and say what changed.
  Restarting the shell (`omarchy restart shell`) restarts every bar plugin: say
  so first.
- **The audio output is the user's choice.** Ask which output omarock may play
  into. Some machines have outputs that must never carry music, a radio
  transmitter's audio interface, say. Never guess the output, and never change a
  pinned one without the user.
- **Don't start music** to test something without asking.
- **Use the installers.** `tools/install-audio`, `tools/install-spotify` and
  `tools/install-sxm` install from a commit; don't copy files into
  `~/.local/share/omarock` by hand.
- **One thing at a time:** mpd, then the plugin, then the audio bus if wanted,
  then one source at a time, checking each before moving on.

## 1. mpd

- `sudo pacman -S mpd mpd-mpris mpc` (all in Arch's `extra`), version 0.24 or later.
- **The config** needs more than `music_directory`: without `playlist_directory`, mpd
  turns stored playlists off, and omarock's playlists and radio favorites with
  them. Use README.md's six-line mpd.conf, and make its folders. mpd scans on its
  first start; after that, new music needs `mpc update`.
- **The socket.** omarock reaches mpd only through a unix socket, by default
  `$XDG_RUNTIME_DIR/mpd/socket`, and mpd should listen only there: a
  `bind_to_address` line with a `RuntimeDirectory=mpd` drop-in (README.md, Install
  by hand). mpd has no logins, so on a TCP port (localhost included, and
  `mpd.socket`'s 6600 on every interface) any account on the machine can read the
  queue, which holds the Apple Music stream's private address. Other clients then
  need `MPD_HOST` (`~/.config/environment.d/omarock-mpd.conf`), and mpd-mpris its
  `mpd-socket.conf` drop-in; ./install offers all three.

  If their mpd already listens on another socket, setting omarock's `socket`
  setting may be simpler than changing mpd.
- **The media keys** need `mpd-mpris` running, with README.md's `follow-mpd.conf`
  drop-in: without it, mpd-mpris dies the first time mpd restarts and stays down.
- **A crash:** mpd's own unit has `Restart=no`, so a crashed mpd stays down.
  `./install` offers a drop-in, `mpd.service.d/restart.conf` (`Restart=on-failure`,
  `RestartSec=2`). With `restore_paused "yes"` in mpd.conf it comes back paused,
  not playing from its last saved state, which can be minutes old.
- **Covers** are image files in each album's folder (`cover.jpg` and the like).
  Embedded art isn't shown.

## 2. The plugin

- `omarchy plugin add https://github.com/marcewing/omarock --enable` (or
  `file://` to a clone).
- **Check it loaded:** `journalctl --user -b | grep "omarock .* loaded"`. The bar
  shows a boombox (nothing queued), or the song playing.
- **"Waiting for mpd…"** means the socket: back to step 1.
- **A key to open it** (ask first: it's Hyprland config): check the key is free
  (`omarchy menu keybindings --print`), then add `o.bind("SUPER + CTRL + M",
  "omarock", "omarchy-shell shell toggle marcewing.omarock")` to
  `~/.config/hypr/bindings.lua`, backed up first. Hyprland reloads it on save;
  `hyprctl configerrors` should stay empty.

## 3. The audio bus (optional: omarock's sound output)

Without it, mpd plays where its config says and Soloist into the default output,
each with its own volume. With it, everything goes into one pinned output.

1. Show the outputs (`pactl list sinks short`), and ask which one omarock should
   use.
2. `tools/install-audio --start --output NAME`.
3. With the user's OK, back up mpd.conf, and replace its `audio_output` with the
   block in `audio/README.md`. Set a sensible volume first (`tools/omarock-volume 40`),
   since mpd's own volume goes to full, then restart mpd.
4. **Check:** `pw-link -l` shows `mpd.omarock → omarock`, and `omarock.output` going
   to the chosen output only.
5. If Spotify is set up, restart Soloist (`systemctl --user restart omarock-soloist`):
   it picks its output as it starts. `./install sound` does all of this.

## 4. Spotify

Follow `spotify/README.md`. What trips people up:
- **Premium** is required.
- **The redirect URI** must be exactly `http://127.0.0.1:8730/callback`.
- **The key file** must be mode 600.
- **Pairing:** it needs the phone to find Soloist on the local network. With ufw
  on, allow Soloist's current TCP port for the pairing only (the user runs the
  sudo commands), then remove the rule.
- **Soloist stops when its build expires** (90 days; exit status 10):
  `tools/update-soloist`.
- **The Web API sign-in lasts 6 months:** `tools/omarock-sp login` again.
- **Check:** `tools/omarock-sp health` shows `"authorized": true`.
- **Then the switch:** `spotify` on.

## 5. SiriusXM

- **Make sure the user has read "Read this first" in `sxm/README.md`:** the
  service is unofficial and may put their account at risk. Go on only if they
  accept that.
- **Install:** `tools/install-sxm --start`. Then the user puts their login in
  `~/.config/omarock/siriusxm.json`, then `systemctl --user restart omarock-sxm`.
- **Check:** `curl -s -H 'X-Omarock: 1' 127.0.0.1:8720/v1/health` shows `account` and `loggedIn`
  true. A "revoked" entitlement means the subscription lacks streaming.
- **Then the switch:** `siriusXM` on.

## 6. Apple Music

There are two halves, and the Mac's is the user's to build. Follow
`apple-bridge/README.md`.
- **On the Mac:** the user builds and installs the bridge, with their own Apple
  Developer team and MusicKit enabled, and allows Apple Music access when macOS
  asks. `./install` in a clone on the Mac walks them through it (it runs
  `apple-bridge/install`). Both machines need to reach each other: the same
  network (the bridge says so over Bonjour: `avahi-browse -rt _omarock._tcp`), or
  Tailscale. Nothing between them is encrypted; say so, and that Tailscale is one
  way to secure it.
- **Here:**
  - `~/.config/omarock/apple.json` names the bridge (`http://my-mac.local:8710`),
    and the stream once the bridge has given it: from bridge 0.9.0 the stream's
    address has a secret, which `/v1/health` gives only with the token.
  - The bridge's token goes in `~/.config/omarock/bridge-token` (mode 600), by
    pairing: the Mac's `./install` ends with a 6-digit code (`./install pair` there
    shows a new one), which the user types into Set up… or Pair with the bridge on
    the Apple Music tab, or `./install apple-music` asks for. Never handle the token
    or the code yourself.
- **The stream's lag:** bridge 0.7.0 and later keep Arch's own libFLAC in step
  (`"minBitrate": true` in its `/v1/health`); for an older one, update it on the
  Mac, and keep `appleRejoin` on (the default) until then. A patched libFLAC left
  from before (`mpd.service.d/omarock-flac.conf`) can go: `./install apple-music`
  offers it. For smooth play and pause, offer the patched mpd-mpris in
  `patches/README.md`. Ask before changing mpd's or mpd-mpris's unit.
- **Check:** `tools/omarock-doctor`'s Apple Music section is all green.
- **Then the switch:** `appleMusic` on.

## Switching a source on

The switches are omarock's settings: `radio` (on by default), `spotify`,
`appleMusic` and `siriusXM` (off). The user can flip them on omarock's settings
screen (`,` in the panel, or the gear in the expanded view), which also says how
each source's service is doing, and changes each source's account and keys and
the music folder. Or, with the user's OK, set one in
`~/.config/omarock/settings.json` (a JSON object, `{ "spotify": true }`; keep
what's there), which the panel follows as it changes. The other settings
(README.md, Settings) are set the same way.

Accounts and keys aren't in that file: each has its own, mode 600. To change one
from a terminal, the user pipes it into `tools/omarock-account` (`--help`), which
restarts the service that uses it. Don't type a secret yourself.

Commands that need the desktop session (`omarchy`, `omarchy-shell`, `qs ipc`)
fail over a bare ssh login, missing `OMARCHY_PATH` and the like. Run them in a
terminal in the session.

## When something's wrong

- **The bar shows only a boombox:** nothing is queued, or mpd isn't reachable
  (doctor, mpd section).
- **A source's button says its service isn't running:**
  `systemctl --user status omarock-…`, then its log, `journalctl --user -u omarock-…`.
- **A change didn't take effect after an update:** `omarchy restart shell` (ask first).
- **omarock's own log:** `journalctl --user -b | grep omarock`. It logs its version
  on load, slow mpd commands, and each request to Spotify's or the Mac's service.
