# Patches for smooth Apple Music

Apple Music reaches mpd as a live Ogg FLAC stream from the Mac. mpd-mpris doesn't
handle that stream well, and its patch fixes it; the mpd patch is in mpd 0.24.17.
They're optional, and only matter for Apple Music. Each is offered upstream; once
your distribution ships the fix, drop the patch.

| Patch | Fixes | Upstream |
| --- | --- | --- |
| `mpd-ogg-codec-detect.patch` | A smaller mpd bug: if a stream's first bytes arrive in pieces, mpd hands an Ogg stream to ffmpeg instead of its own decoder. Not needed with Icecast, which sends the headers at once. | [MusicPlayerDaemon/MPD#2606](https://github.com/MusicPlayerDaemon/MPD/pull/2606): merged, in mpd 0.24.17 |
| `mpd-mpris-stream-art.patch` | **The freezes.** mpd-mpris asks mpd for a stream's cover art on every play, pause and stop. To answer, mpd probes the stream for several seconds, and answers no other client meanwhile. Patched, it keeps a stream's art across events, and doesn't ask for a remote URI's art at all. | [natsukagami/mpd-mpris#89](https://github.com/natsukagami/mpd-mpris/pull/89) (the first of the two commits): merged, after 0.4.4 |

The second mpd-mpris commit, skipping art lookups for every remote URI, isn't in
the upstream request. mpd can find cover art for music files served over HTTP,
and that commit gives that up. Leave it out (apply only the first commit) if you
queue such files.

## libFLAC: no patch any more

libFLAC's Ogg reader fills each 8 KiB read before returning any audio. On a
paused Mac's stream, that once meant mpd waited tens of seconds, then played
that far behind. omarock used to patch the reader
([xiph/flac#939](https://github.com/xiph/flac/pull/939)). libFLAC's maintainers
pointed at the encoder's `--limit-min-bitrate` instead, made for this: it keeps
silence from shrinking to almost nothing. Since 0.7.0 the bridge encodes its
stream with it, and Arch's own libFLAC stays under 2 s behind.

A patched libFLAC built for an older bridge can go: `./install apple-music`
offers to remove it. By hand: delete
`~/.config/systemd/user/mpd.service.d/omarock-flac.conf` and
`~/.local/lib/omarock-flac`, then `systemctl --user daemon-reload && systemctl
--user restart mpd`.

## mpd-mpris

```bash
tools/build-mpd-mpris        # builds mpd-mpris 0.4.4 (Arch's version), patched, into ~/.local/lib/omarock-mpris
mkdir -p ~/.config/systemd/user/mpd-mpris.service.d
printf '[Service]\nExecStart=\nExecStart=%%h/.local/lib/omarock-mpris/mpd-mpris -no-instance\n' \
  > ~/.config/systemd/user/mpd-mpris.service.d/omarock-mpris.conf
systemctl --user daemon-reload && systemctl --user restart mpd-mpris
```

**Remove:** delete the drop-in, then `systemctl --user daemon-reload && systemctl
--user restart mpd-mpris`. (`./install --uninstall` offers this.)

## The mpd patch

It's a fix inside mpd itself, and mpd 0.24.17 includes it. Apply it to mpd's
source only if you build an older mpd yourself.
