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

omarock-spotify listens on 127.0.0.1 only, and answers only omarock's own
requests: they carry an `X-Omarock: 1` header, which a web page can't send.

## What you need

- **Spotify Premium.**
- **A Spotify developer app,** free, at
  [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard), made
  with your own account. omarock uses its Client ID to search, browse, read
  your library and save songs and albums to it, through Spotify's Web API.
- **A Soloist API key** for the player, from the same dashboard.
- An x86_64 machine: the Soloist build that `tools/update-soloist` fetches.

## Set it up

The easy way: **Set up…** under SPOTIFY in omarock's settings (`,` in the panel).
Its window links to the dashboard and takes the Client ID and the Soloist key;
then a terminal does the rest of what follows, opens the firewall for the
pairing and closes it again, and switches Spotify on. `./install spotify` from
your clone does it all in the terminal.
Run it again (the settings' **Fix…** does) to finish a setup that stopped.

By hand, run the tools from your omarock clone: the plugin's folder,
`~/.config/omarchy/plugins/mre.omarock`, or a clone of your own.

1. **omarock's sound output** is optional ([audio/README.md](../audio/README.md)).
2. **The developer app.** In the dashboard, create an app. Give it the redirect
   URI `http://127.0.0.1:8730/callback`, and tick the Web API. Then save its
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
4. **Soloist and the service:**
   ```bash
   tools/update-soloist             # downloads Soloist from Spotify
   tools/install-spotify --start    # installs and starts both services
   ```
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
   button appears in the panel, and `m` goes round to it. The settings also
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
  So the first look at a year's Top 100 takes a minute or two; after that it's
  kept. Artist pages, which cost the most requests (up to 13), are kept for 10
  minutes. If Spotify still says too many requests, omarock-spotify asks
  nothing more until the time Spotify gives is up, and the panel says when to
  try again.
- **`tools/omarock-sp`** drives it from a terminal: `status`, `search`, `play`,
  `pause`, `next`, `on` and `off` (make Spotify omarock's source, or not), and more
  (`--help`).

## Keeping it working

- **Soloist builds expire after 90 days.** omarock's settings offer **Update…**
  ten days before, which fetches a new one; or run `tools/update-soloist`.
- **The Web API sign-in lasts 6 months.** omarock's settings show when it ends,
  under Spotify. Then **Sign in** there, or run `tools/omarock-sp login` again.
  **Sign out** there forgets it (Spotify's player stays paired: **Remove…** takes
  everything off).
- **Logs:** `journalctl --user -u omarock-spotify -u omarock-soloist`.

## Secrets and the network

- `~/.config/omarock/soloist-key` and `~/.config/omarock/spotify-token.json` hold
  your key and your sign-in. Keep them private (mode 600), and don't paste them
  anywhere. If one leaks, make a new key in the dashboard, or sign in again.
- Soloist takes its key only on its command line (`--api-key`), so while it runs,
  another user on this machine can read it with `ps`. On a machine of your own
  that's no one; on a shared one, bear it in mind.
- omarock-spotify and Soloist's control API listen on 127.0.0.1 only.
  omarock-spotify answers only omarock's own requests (`X-Omarock: 1`), so a web
  page you visit can't drive it.
- Soloist's Connect discovery listens on every interface (mDNS, and a random TCP
  port), as any Spotify speaker does. Soloist has no setting to turn it off.

## Remove it

**Remove…** under SPOTIFY in omarock's settings, or `./install --remove spotify`,
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
| `omarock-soloist.service` | Soloist, as a Connect speaker named after the machine, playing into the bus if it's set up, else the default output |
| `omarock-spotify.py`, `.service` | The service on 127.0.0.1:8730: status (a long poll), search, albums, artists, playlists, info, transport, saving to your library (`/me/library`), and Spotify's sign-in |
| `spotify_web.py` | The Web API client (PKCE: no client secret). Also a CLI: `spotify_web.py get /me/player/devices` |
| `soloist_ws.py` | A small WebSocket client for Soloist's API |
| `spotify_mpris.py` | Spotify as an MPRIS player ("Spotify"), so the media keys work on it |
| `test_service.py`, `test_mpris.py` | Tests, with stand-ins for Soloist, mpd and the session bus |
