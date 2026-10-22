# SiriusXM for omarock

omarock-sxm is a small service on your machine. It signs in to your SiriusXM
account and serves each **live channel** as one continuous stream, which mpd
plays like an internet radio station. It plays nothing itself, so the sound
goes wherever mpd's goes. It listens on 127.0.0.1:8720 only. On-demand shows
and Xtra channels aren't included.

## Read this first: it's unofficial

omarock-sxm uses [aiosxm](https://github.com/MizterB/aiosxm) (MIT), which talks
to the API of SiriusXM's web player. SiriusXM doesn't offer that API to anyone
else, and its Customer Agreement forbids "manipulation of the Service" and
"spoofing" a web device (§9(c) and §9(k)). So:
- **Your account is at risk.** SiriusXM could flag, limit or close it.
- **It may stop working** whenever SiriusXM changes its web player.

It's polite about it: it behaves like one listener, and fetches a channel only
while mpd plays it. Whether that's acceptable is your call.

## What you need

- A SiriusXM subscription that includes streaming (listening in the app or on
  the web).
- Python 3 (Omarchy has it). The installer makes a venv of its own.

## Set it up

1. Install the service, from your omarock clone (the plugin's folder,
   `~/.config/omarchy/plugins/mre.omarock`, or a clone of your own):
   ```bash
   tools/install-sxm --start
   ```
   It makes a venv with aiosxm in `~/.local/share/omarock/sxm-venv`, puts the
   service in `~/.local/share/omarock/sxm/`, and starts it. It also creates
   `~/.config/omarock/siriusxm.json`, readable only by you.
2. Put your SiriusXM login in that file:
   ```json
   { "username": "you@example.com", "password": "…" }
   ```
   Then `systemctl --user restart omarock-sxm`.
3. Check it signed in:
   ```bash
   curl -s 127.0.0.1:8720/v1/health
   ```
   It should say `"account": true` and `"loggedIn": true`.
4. **Switch SiriusXM on** in omarock's settings (`,` in the panel). A SiriusXM
   button appears in the panel, and `m` goes round to it. The login can be
   changed there later too.

In SiriusXM, the list is your favourite channels, then all of them, each with
what's on. `A` adds or removes a favourite: your account's, so the SiriusXM app
sees the change too.

## When it doesn't work

- **`"account": false`:** the login file is missing, empty or not valid JSON.
- **An error saying an entitlement was "revoked":** that account's subscription
  doesn't include streaming.
- **No channels, or channels that won't play:** `journalctl --user -u omarock-sxm`.
- **The SiriusXM button says the service isn't running:**
  `systemctl --user status omarock-sxm`.

## Remove it

`./install --uninstall` does this, asking first. By hand, switch SiriusXM off in
omarock's settings, then:

```bash
systemctl --user disable --now omarock-sxm
rm -f ~/.config/systemd/user/omarock-sxm.service
systemctl --user daemon-reload
rm -rf ~/.local/share/omarock/sxm ~/.local/share/omarock/sxm-venv ~/.config/omarock/siriusxm.json
```

## What it serves

| Route | What |
| --- | --- |
| `GET /stream/{channel_id}` | The channel, live, as ADTS AAC (256k). With `Icy-MetaData: 1` (mpd sends it), the stream carries "Artist - Title", so `mpc current` shows the song. It starts two segments behind live, as a cushion. |
| `GET /v1/health` | `{ ok, version, account, loggedIn, error, playing }` |
| `GET /v1/channels` | Live channels by number: `{ id, number, name, shortName, genre, description, logo, stream, favorite, available }` |
| `GET /v1/nowplaying` | `{ channelId: { artist, title, show, isAd, startedAt, art } }` for every channel |
| `POST`, `DELETE /v1/favorites/{id}` | Add a channel to the account's favourites, or remove it |
| `GET /art/{key}/{w}x{h}` | A redirect to SiriusXM's artwork at that size. `logo` and `art` are templates with `{w}` and `{h}`. |

It stops fetching a channel 20 s after its last listener leaves. The now-playing
feed is polled every 15 s while a channel plays, or for 5 minutes after omarock
last asked.

## Testing

`sxm/test_relay.py` checks the relay's listeners. Run it with the venv's Python:
`~/.local/share/omarock/sxm-venv/bin/python sxm/test_relay.py`.

Don't test with `ffplay` or `mpv`: they play to your default output, not through
mpd. Decode to nowhere instead (`ffmpeg -i http://127.0.0.1:8720/stream/ID -f null -`),
or use a throwaway mpd whose only output is `null`.
