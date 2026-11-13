# Spotify for omarock

Spotify plays on your machine through **Soloist**, Spotify's own headless player
(a Spotify Connect speaker). **omarock-spotify** drives it, and answers omarock
with the same API as the Apple Music bridge, so the panel treats both alike.
Soloist plays into your default output, with its own volume, which omarock's
knob sets. With omarock's sound output set up (the bus, `audio/`), it plays into
that instead: one volume for everything, and only the output you pinned.

```
omarock, omarock-sp ──► omarock-spotify (127.0.0.1:8730) ──► Soloist (127.0.0.1:8731)
media keys (MPRIS) ──┘          │                                   │
                                └─► Spotify's Web API               └─► your speakers (or the omarock bus)
```

omarock-spotify listens on 127.0.0.1 only, and answers only your account's
programs, and of those only omarock's own requests: they carry an
`X-Omarock: 1` header, which a web page can't send. Soloist's control port is
for your account alone too (below).

## What you need

- **Spotify Premium.**
- **A Spotify developer app,** free, at
  [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard), made
  with your own account. omarock uses its Client ID to search, browse, read
  your library and save songs and albums to it, through Spotify's Web API.
- **A Soloist API key** for the player, from the same dashboard.
- **Soloist itself,** which you download from Spotify (step 4), for an x86_64
  machine.

## Set it up

The easy way: **Set up…** on the Spotify tab of omarock's settings (`,` in the panel).
Its window links to the dashboard and to Soloist's downloads, takes the Client
ID and the Soloist key, and waits for Soloist in your Downloads folder; then a
terminal does the rest of what follows, opens the firewall for the pairing and
closes it again, and switches Spotify on. `./install spotify` from
your clone does it all in the terminal.
Run it again (the settings' **Fix…** does) to finish a setup that stopped.

By hand, run the tools from your omarock clone: the plugin's folder,
`~/.config/omarchy/plugins/marcewing.omarock`, or a clone of your own.

1. **omarock's sound output** is optional ([audio/README.md](../audio/README.md)).
2. **The developer app.** In the dashboard, create an app. Give it the redirect
   URI `http://127.0.0.1:8730/callback`, and check Web API. Then save its
   Client ID for omarock:
   ```bash
   mkdir -p ~/.config/omarock
   echo '{ "clientId": "YOUR CLIENT ID", "redirectUri": "http://127.0.0.1:8730/callback" }' \
     > ~/.config/omarock/spotify.json
   ```
3. **The Soloist key.** Put it in a file only you can read:
   ```bash
   install -m 600 /dev/null ~/.config/omarock/soloist-key
   nano ~/.config/omarock/soloist-key     # paste the key, save
   ```
4. **Soloist and the service.** Download Soloist from Spotify's
   [downloads page](https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates):
   Linux x86_64, `soloist_release_x86_64.tar.gz`, into `~/Downloads`. omarock
   doesn't download it for you: Spotify offers only an unversioned "latest"
   build, with no checksums or signatures, and its terms don't allow passing it
   on. Then:
   ```bash
   tools/install-spotify --start    # installs both services, and omarock's shim
   tools/update-soloist install     # installs Soloist from ~/Downloads, and checks it
   ```
   `update-soloist` reads the download without running it: an x86-64 program
   built to work with omarock's shim (below), and not expired. It installs it,
   starts it with the shim, and watches its log, where the shim says it handed
   Soloist its key and guards its control port. Only then does Soloist's unit
   start that build (its hash is kept in `~/.local/lib/omarock-soloist/soloist.sha256`),
   and a copy is kept: a build that doesn't pass is swapped back for the last
   one that did.
5. **Pair Soloist with your account, once.** Open Spotify on a phone or computer
   on the same network, choose your machine's name under *Connect to a device*,
   and play something. Soloist keeps the sign-in.
   - Behind a firewall (Omarchy turns ufw on), the device won't show until you
     let Soloist's discovery in, for the pairing only.
   - Its port changes each time it starts: find it with `ss -ltnp | grep soloist`,
     then `sudo ufw allow PORT/tcp`. Add `sudo ufw allow 5353/udp` if mDNS is blocked.
   - Remove the rules once it's paired.
6. **Sign in to the Web API:** `tools/omarock-sp login`. It opens Spotify's
   sign-in page; afterwards `tools/omarock-sp health` says `"authorized": true`.
7. **Switch Spotify on** in omarock's settings (`,` in the panel). A Spotify
   button appears in the panel, and `m` goes around to it. The settings also
   change the Client ID and the Soloist key later, and sign you in again.

## How it behaves

- **One player at a time.** Switching to Spotify pauses mpd where it was;
  switching back plays on from there. Spotify started from your phone (Connect)
  makes omarock follow it, and mpd playing (`mpc play`, the media keys) takes over
  from Spotify.
- **One machine at a time.** A Spotify account plays on one device at a time.
  With omarock on two machines, Play on one moves Spotify to that machine's
  Soloist (Spotify's transfer). The other's panel shows it paused, "Playing on
  framework · Play moves it here", and its pause, skip, seek and media keys
  don't reach the machine playing. Spotify playing on another device doesn't
  pause this machine's mpd either.
- **The media keys** work on Spotify while it's the source, and on mpd otherwise.
- **The volume.** Without omarock's sound output, the knob sets Soloist's own
  volume (as your phone does). With it, Soloist's stays at full and the bus's is
  omarock's one volume.
- **What an app like this can't get from Spotify:**
  - genres;
  - the songs of other people's playlists (they still play);
  - taking songs out of Spotify's queue;
  - more than 10 search results of each kind.
- **Asking Spotify gently.** Spotify limits how often an app may ask it
  things, more tightly for one in development mode, as yours is, and it doesn't
  say how often. So omarock-spotify sends at most 20 requests at once, then one a
  second (no more than 50 in any 30 seconds). Background work (filling in the
  queue's songs, finding the Top 100's songs) waits for what you're looking at.
  So finding a year's Top 100 takes a minute or two the first time (it starts
  as soon as you pick the year); after that it's kept. Artist pages, which cost the most requests (up to 13), are kept for 10
  minutes. If Spotify still says too many requests, omarock-spotify asks
  nothing more until the time Spotify gives is up, and the panel says when to
  try again.
- **`tools/omarock-sp`** drives it from a terminal: `status`, `search`, `play`,
  `pause`, `next`, `on` and `off` (make Spotify omarock's source, or not), and more
  (`--help`).

## Keeping it working

- **Soloist builds expire after 90 days.** Ten days before, a dot on Spotify
  in the panel's header, and on the gear, says so. Download a new build from
  Spotify, then **Update…** on the Spotify tab of omarock's settings (or
  `./install spotify`, or `tools/update-soloist install`) installs and checks it.
  A newer build waiting in `~/Downloads` gets the dot too.
- **A Soloist put in by hand** (over `~/.local/lib/omarock-soloist/soloist`)
  isn't started until it's checked: **Update…**, or `tools/update-soloist check`.
- **The Web API sign-in lasts 6 months.** omarock's settings show when it ends,
  on the Spotify tab. Then **Sign in** there, or run `tools/omarock-sp login` again.
  **Sign out** there forgets it (Spotify's player stays paired: **Remove…** takes
  everything off).
- **Logs:** `journalctl --user -u omarock-spotify -u omarock-soloist`.

## Secrets and the network

- `~/.config/omarock/soloist-key` and `~/.config/omarock/spotify-token.json` hold
  your key and your sign-in. Keep them private (mode 600), and don't paste them
  anywhere. If one leaks, make a new key in the dashboard, or sign in again.
  Soloist keeps its own sign-in in `~/.local/share/omarock-soloist` and
  `~/.cache/omarock-soloist`, which are yours alone too.
- **omarock's shim.** A small library loaded into Soloist alone
  (`omarock-soloist-shim.so`, built from `omarock-soloist-shim.c` by
  `tools/install-spotify`, which needs a C compiler: Omarchy's `base-devel` has
  one) does two things:
  - Soloist takes its key only as an argument (`--api-key`), and any account on
    the machine can read a program's arguments (`ps`). So its unit gives it a
    stand-in, `--api-key @key`, and the shim hands Soloist the key from
    `soloist-key` as it starts. `ps` shows only `@key`.
  - Soloist's control API (127.0.0.1:8731: what's playing, the queue, play,
    volume) has no sign-in of its own, and every account on the machine can
    reach 127.0.0.1. Its Spotify Connect discovery (below) takes a sign-in from
    whoever pairs. Of the connections from this machine, the shim hands Soloist
    only those whose other end belongs to your account, by the kernel's socket
    table (`/proc/net/tcp`), and closes the rest before Soloist sees them.
    Phones and computers on your network still reach the discovery port, to
    pair.

  `tools/omarock-doctor` checks both.
- omarock-spotify listens on 127.0.0.1 only, and checks each connection's other
  end the same way: another account's programs are refused. Of yours, it
  answers only omarock's own requests (`X-Omarock: 1`), so a web page you visit
  can't drive it.
- Soloist's Connect discovery listens on every interface (mDNS, and a random TCP
  port), as any Spotify speaker does, and Soloist has no setting to turn it off.
  Anything that reaches it can pair, signing Soloist in to its own account. Your
  firewall (Omarchy's ufw) keeps the network out except while you pair, and the
  shim keeps this machine's other accounts out.

## Remove it

**Remove…** on the Spotify tab of omarock's settings, or `./install --remove spotify`,
does this, asking first; `./install --uninstall` too. By hand, switch Spotify
off in omarock's settings, then:

```bash
systemctl --user disable --now omarock-spotify omarock-soloist
rm -f ~/.config/systemd/user/omarock-spotify.service ~/.config/systemd/user/omarock-soloist.service
systemctl --user daemon-reload
rm -rf ~/.local/share/omarock/spotify ~/.local/lib/omarock-soloist ~/.local/share/omarock-soloist ~/.cache/omarock-soloist
rm -f ~/.config/omarock/spotify.json ~/.config/omarock/soloist-key ~/.config/omarock/spotify-token.json
```

Then delete the app in Spotify's developer dashboard.

## Files

| File | What it does |
| --- | --- |
| `omarock-soloist.service` | Soloist, as a Connect speaker named after the machine, playing into the bus if it's set up, else the default output; only the build `tools/update-soloist` checked |
| `omarock-soloist-shim.c` | The shim loaded into Soloist: its key off its command line, its ports for your account alone among this machine's programs |
| `omarock-spotify.py`, `.service` | The service on 127.0.0.1:8730: status (a long poll), search, albums, artists, playlists, info, transport, saving to your library (`/me/library`), and Spotify's sign-in |
| `spotify_web.py` | The Web API client (PKCE: no client secret). Also a CLI: `spotify_web.py get /me/player/devices` |
| `soloist_ws.py` | A small WebSocket client for Soloist's API |
| `spotify_mpris.py` | Spotify as an MPRIS player ("Spotify"), so the media keys work on it |
| `test_service.py`, `test_mpris.py`, `test_soloist_shim.py` | Tests, with stand-ins for Soloist, mpd and the session bus |
