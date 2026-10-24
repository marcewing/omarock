# omarock's audio bus

An optional PipeWire output, **omarock**, that all of omarock's sound goes into:
mpd's, and Spotify's (Soloist). omarock's settings call it **omarock's sound
output**. The bus plays into one output you choose, and nowhere else. It gives
you:
- **One volume for every source,** omarock's knob, whatever is playing.
- **One pinned output.** omarock's sound never falls back to another output when
  yours goes away, and nothing can move it. That matters on a machine with
  outputs that must never carry music, such as a radio transmitter's audio
  interface, or a TV's HDMI input in another room. If your output goes away, the
  bus waits, silent.

Without it, mpd plays wherever its config says, with its own volume, and Soloist
into the default output, with its own: omarock's knob sets whichever is playing.

```
mpd ─────────┐
             ├──► omarock (bus) ──► your output
Soloist ─────┘
```

## Set it up

The easy way: **Set up…** under SOUND in omarock's settings, or `./install sound`
from your clone. It asks which output, then does what follows, and restarts
Spotify's player (if you have it) to play into the bus. By hand:

1. **Pick the output** the bus plays into. Its node name is the second column of:
   ```bash
   pactl list sinks short
   ```
2. **Install the bus,** from your omarock clone (the plugin's folder,
   `~/.config/omarchy/plugins/mre.omarock`, or a clone of your own):
   ```bash
   tools/install-audio --start --output alsa_output.usb-Your_Card-00.analog-stereo
   ```
   It remembers the output in `~/.config/omarock/audio-output`, so later installs
   need no `--output`. Check: `wpctl status` lists an output called "omarock", and
   `pw-link -l` shows `omarock.output` going to your output, and only there.
3. **Point mpd at the bus,** with its own volume at full. Add this to
   `~/.config/mpd/mpd.conf`, in place of any `audio_output` block it has (keep a
   copy of that, to go back):
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

**Remove…** under SOUND in omarock's settings, `./install --remove sound`, and
`./install --uninstall` do this, asking first, and put back the output mpd had
before. By hand:

1. Take omarock's `audio_output` block out of mpd.conf (put your old one back, if
   you had one), and `systemctl --user restart mpd`.
2. Then:
   ```bash
   systemctl --user disable --now omarock-bus omarock-guard
   rm -f ~/.config/systemd/user/omarock-bus.service ~/.config/systemd/user/omarock-guard.service
   systemctl --user daemon-reload
   rm -rf ~/.local/share/omarock/audio
   rm -f ~/.config/pipewire/client.conf.d/50-omarock-players.conf ~/.config/omarock/audio-output
   ```
