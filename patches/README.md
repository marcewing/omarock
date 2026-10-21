# Patches for smooth Apple Music

Apple Music reaches mpd as a live Ogg FLAC stream from the Mac. Two programs here
don't handle that stream well, and these patches fix them. They're optional, and
only matter for Apple Music. Each is offered upstream; once your distribution
ships the fix, drop the patch.

| Patch | Fixes | Upstream |
| --- | --- | --- |
| `libflac-ogg-live.patch` | **The lag.** libFLAC's Ogg reader fills each 8 KiB read before returning any audio. On a quiet live stream (a paused Mac sends a few hundred bytes a second), mpd then waits, and plays everything it buffered, staying tens of seconds behind the Mac. Patched, it stays about half a second behind. | [xiph/flac#939](https://github.com/xiph/flac/pull/939) |
| `mpd-ogg-codec-detect.patch` | A smaller mpd bug: if a stream's first bytes arrive in pieces, mpd hands an Ogg stream to ffmpeg instead of its own decoder. Not needed with Icecast, which sends the headers at once. | [MusicPlayerDaemon/MPD#2606](https://github.com/MusicPlayerDaemon/MPD/pull/2606) |
| `mpd-mpris-stream-art.patch` | **The freezes.** mpd-mpris asks mpd for a stream's cover art on every play, pause and stop. To answer, mpd probes the stream for several seconds, and answers no other client meanwhile. Patched, it keeps a stream's art across events, and doesn't ask for a remote URI's art at all. | [natsukagami/mpd-mpris#89](https://github.com/natsukagami/mpd-mpris/pull/89) (the first of the two commits) |

The second mpd-mpris commit, skipping art lookups for every remote URI, isn't in
the upstream request. mpd can find cover art for music files served over HTTP,
and that commit gives that up. Leave it out (apply only the first commit) if you
queue such files.

## libFLAC, for mpd only

```bash
tools/build-libflac          # builds your distribution's flac version, patched, into ~/.local/lib/omarock-flac
mkdir -p ~/.config/systemd/user/mpd.service.d
printf '[Service]\nEnvironment=LD_LIBRARY_PATH=%%h/.local/lib/omarock-flac\n' \
  > ~/.config/systemd/user/mpd.service.d/omarock-flac.conf
systemctl --user daemon-reload && systemctl --user restart mpd
```

Only mpd loads the patched library. Check:
`grep omarock-flac /proc/$(systemctl --user show -p MainPID --value mpd)/maps`.
Then switch off omarock's `appleRejoin` setting: it reconnects mpd after each
change, which the patched library doesn't need, and the reconnect is a short
stutter.

**Remove:** delete the drop-in, `systemctl --user daemon-reload && systemctl --user
restart mpd`, and switch `appleRejoin` back on.

## mpd-mpris

```bash
tools/build-mpd-mpris        # builds your distribution's version, patched, into ~/.local/lib/omarock-mpris
mkdir -p ~/.config/systemd/user/mpd-mpris.service.d
printf '[Service]\nExecStart=\nExecStart=%%h/.local/lib/omarock-mpris/mpd-mpris -no-instance\n' \
  > ~/.config/systemd/user/mpd-mpris.service.d/omarock-mpris.conf
systemctl --user daemon-reload && systemctl --user restart mpd-mpris
```

**Remove:** delete the drop-in, then `systemctl --user daemon-reload && systemctl
--user restart mpd-mpris`.

## The mpd patch

It's a fix inside mpd itself. Apply it to mpd's source if you build mpd yourself;
otherwise wait for the release that includes it.
