---
name: omarock-setup
description: Set up omarock, the Omarchy bar music player in this repo, or any of its parts (mpd and its socket, the plugin, the audio bus, Spotify, Apple Music, SiriusXM), or find out why one isn't working. Use when someone asks to install, configure, switch on, update or troubleshoot omarock or one of its music sources.
---

# Setting up omarock

omarock is a plugin for Omarchy's bar, and a client for mpd. Local music and
internet radio need only mpd. Spotify, Apple Music and SiriusXM each need a
service set up, which also switches them on in omarock's settings. The guides
have the details: `README.md` (install), `audio/README.md`, `spotify/README.md`,
`sxm/README.md`, `bridge/README.md`. Read the relevant one before a step; this
skill is the order to go in, and what to watch out for.

## The installer first

The installer is interactive, checking first and asking before each change. It
needs a real terminal (gum prompts), so it can't run from Claude's shell:
suggest the user run it in one of their own.
- `./install` in the clone sets up local music and the radio: mpd, then the
  plugin on the bar.
- Each source then has its own: **Set up…** in omarock's settings (`,` in the
  panel) runs it in a terminal, or the user runs `./install spotify`,
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
  turns stored playlists off, and omarock's playlists and radio favourites with
  them. Use README.md's five-line mpd.conf, and make its folders. mpd scans on its
  first start; after that, new music needs `mpc update`.
- **The socket.** omarock reaches mpd only through a unix socket, by default
  `$XDG_RUNTIME_DIR/mpd/socket`. There are two ways (README.md, Install), so let
  the user choose:
  - `mpd.socket` is easiest, but also opens TCP port 6600 on every interface.
  - A `bind_to_address` line with a `RuntimeDirectory=mpd` drop-in opens only the
    socket.

  If their mpd already listens elsewhere, setting omarock's `socket` setting may be
  simpler than changing mpd.
- **The media keys** need `mpd-mpris` running, with README.md's `follow-mpd.conf`
  drop-in: without it, mpd-mpris dies the first time mpd restarts and stays down.
- **Covers** are image files in each album's folder (`cover.jpg` and the like).
  Embedded art isn't shown.

## 2. The plugin

- `omarchy plugin add https://github.com/marcewing/omarock --enable` (or
  `file://` to a clone).
- **Check it loaded:** `journalctl --user -b | grep "omarock .* loaded"`. The bar
  shows a record (nothing queued), or the song playing.
- **"Waiting for mpd…"** means the socket: back to step 1.

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
- **Check:** `curl -s 127.0.0.1:8720/v1/health` shows `account` and `loggedIn`
  true. A "revoked" entitlement means the subscription lacks streaming.
- **Then the switch:** `siriusXM` on.

## 6. Apple Music

There are two halves, and the Mac's is the user's to build. Follow
`bridge/README.md`.
- **On the Mac:** the user builds and installs the bridge, with their own Apple
  Developer team and MusicKit enabled, and allows Apple Music access when macOS
  asks. `./install` in a clone on the Mac walks them through it (it runs
  `bridge/install`). Both machines need Tailscale (or another way to reach the Mac).
- **Here:**
  - `~/.config/omarock/apple.json` names the bridge and the stream.
  - The bridge's token goes in `~/.config/omarock/bridge-token` (mode 600), put
    there by the user.
- **The stream's lag:** with the stock libFLAC, keep `appleRejoin` on (the default).
  For smooth starts, offer the patches in `patches/README.md`: the patched
  libFLAC (then `"appleRejoin": false` in settings.json) and mpd-mpris. Ask before changing
  mpd's or mpd-mpris's unit.
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

- **The bar shows only a record:** nothing is queued, or mpd isn't reachable
  (doctor, mpd section).
- **A source's button says its service isn't running:**
  `systemctl --user status omarock-…`, then its log, `journalctl --user -u omarock-…`.
- **A change didn't take effect after an update:** `omarchy restart shell` (ask first).
- **omarock's own log:** `journalctl --user -b | grep omarock`. It logs its version
  on load, slow mpd commands, and each request to Spotify's or the Mac's service.
