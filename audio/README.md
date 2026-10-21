# omarock's audio bus

An optional PipeWire output, **omarock**, that all of omarock's sound goes into:
mpd's, and Spotify's (Soloist). The bus plays into one output you choose, and
nowhere else. It gives you:
- **One volume for every source,** omarock's knob, whatever is playing.
- **One pinned output.** omarock's sound never falls back to another output when
  yours goes away, and nothing can move it. That matters on a machine with
  outputs that must never carry music, such as a radio transmitter's audio
  interface, or a TV's HDMI input in another room. If your output goes away, the
  bus waits, silent.

Spotify needs it (Soloist plays into the bus). For the other sources it's optional:
without it, omarock uses mpd's own volume, and mpd plays wherever its config says.

```
mpd ─────────┐
             ├──► omarock (bus) ──► your output
Soloist ─────┘
```

## Set it up

1. **Pick the output** the bus plays into. Its node name is the second column of:
   ```bash
   pactl list sinks short
   ```
2. **Install the bus,** from your omarock clone (the plugin's folder,
   `~/.config/omarchy/plugins/marc.omarock`, or a clone of your own):
   ```bash
   tools/install-audio --start --output alsa_output.usb-Your_Card-00.analog-stereo
   ```
   It remembers the output in `~/.config/omarock/audio-output`, so later installs
   need no `--output`. Check: `wpctl status` lists an output called "omarock", and
   `pw-link -l` shows `omarock.output` going to your output, and only there.
3. **Point mpd at the bus,** with its own volume at full. In `~/.config/mpd/mpd.conf`,
   replace your `audio_output` block with:
   ```
   audio_output {
       type        "pipewire"
       name        "omarock"
       target      "omarock"
       mixer_type  "none"
   }
   ```
   Then set the bus's volume (`tools/omarock-volume 40`, say) and
   `systemctl --user restart mpd`. Check: `mpc outputs` shows "omarock", and
   `pw-link -l` shows `mpd.omarock` going into `omarock`.

omarock finds the bus by itself: its knob, `+` and `-` then set the bus's volume.

**Volume afterwards:**
- `mpc volume` and MPRIS volume no longer change anything, since mpd has no mixer.
  Use omarock, or `tools/omarock-volume [N|+N|-N]`.
- Omarchy's volume keys still set your output's own volume, so there are two in a
  row: your output's, then the bus's.

## What's in it

| File | What it does |
| --- | --- |
| `omarock-bus.conf` | The bus, as its own `pipewire -c` process (as PipeWire's filter-chain.service runs), so it starts and stops without restarting PipeWire. Its output is pinned (`@OUTPUT@`, filled in by `tools/install-audio`): no fallback, no move, and silent while the output is missing. |
| `omarock-bus.service` | Runs it (bound to pipewire.service). |
| `omarock-players.conf` | PipeWire client config, for `~/.config/pipewire/client.conf.d/`. mpd's stream and Soloist's stay on the bus, wait silently while it's missing, and keep their own volume at full. |
| `omarock-guard.py`, `.service` | Watches PipeWire's links, and cuts any made by hand (`pw-link`, a patchbay) that would take omarock's sound off its path. It logs each cut and shows a notification, at most once every ten minutes for the same pair. Recorders may listen in. |
| `test-bus.py` | All of the above, on a throwaway PipeWire with silent fake outputs, never your real one. |

The installer copies these from a commit, never from your working tree, so a
half-done edit can't change where the sound goes on the next restart.

## Remove it, in reverse

1. Put mpd.conf's old `audio_output` block back, and restart mpd.
2. `systemctl --user disable --now omarock-bus omarock-guard`.
3. Delete the two units from `~/.config/systemd/user/`, the folder
   `~/.local/share/omarock/audio/`, `~/.config/pipewire/client.conf.d/50-omarock-players.conf`
   and `~/.config/omarock/audio-output`.
