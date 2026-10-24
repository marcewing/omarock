#!/usr/bin/env python3
"""Tests for spotify_mpris.py, on a private session bus with a stand-in Soloist.

    dbus-run-session -- python3 -I spotify/test_mpris.py

It refuses to run on the real session bus (Omarchy's shell would see the
player). gdbus is the client, as another program on the bus would be.
"""
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

NAME = "org.mpris.MediaPlayer2.omarock_spotify"
PATH = "/org/mpris/MediaPlayer2"
PLAYER = "org.mpris.MediaPlayer2.Player"
failures = []


def check(what, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + what + (f": {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(what)


class FakeSoloist:
    def __init__(self):
        self.cond = threading.Condition()
        self.seq = 1
        self.logged_in = True
        self.status = "idle"
        self.active = True
        self.item = None
        self.options = {}
        self.yielded = False
        self.position = 0.0
        self.sent = []

    def changed(self):
        with self.cond:
            self.seq += 1
            self.cond.notify_all()

    def position_now(self):
        return self.position

    def song_for(self, entity):
        return {"kind": "song", "id": entity["id"], "title": entity["title"], "artist": "Hüsker Dü",
                "album": "Zen Arcade", "duration": 134.0, "trackNumber": 6,
                "artwork": {"url": "https://i.scdn.co/image/zen"}}

    def safe(self, name, **args):
        self.sent.append((name, args))

    # As omarock-spotify's Soloist: another device's playing is paused here.
    def playing_elsewhere(self):
        return not self.active and self.status in ("playing", "buffering")

    def heard(self):
        return "paused" if self.playing_elsewhere() else self.status

    def play_here_soon(self):
        self.sent.append(("play", {}) if self.active else ("move here", {}))


def gdbus(*args):
    return subprocess.run(["gdbus", "call", "--session", "--dest", NAME, "--object-path", PATH, *args],
                          capture_output=True, text=True, timeout=5)


def get(prop, interface=PLAYER):
    r = gdbus("--method", "org.freedesktop.DBus.Properties.Get", interface, prop)
    return r.stdout.strip() if r.returncode == 0 else "ERROR " + r.stderr.strip()


def call(method, *args):
    r = gdbus("--method", f"{PLAYER}.{method}", *args)
    return r.returncode == 0


def until(test, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if test():
            return True
        time.sleep(0.05)
    return test()


def main():
    address = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    if not address or address == f"unix:path=/run/user/{os.getuid()}/bus":
        sys.exit("run me under dbus-run-session, never on the real session bus")
    import spotify_mpris
    soloist = FakeSoloist()
    log = []
    spotify_mpris.start(soloist, log.append)
    monitor = subprocess.Popen(["gdbus", "monitor", "--session", "--dest", NAME],
                               stdout=subprocess.PIPE, text=True)
    signals = []
    threading.Thread(target=lambda: [signals.append(line) for line in monitor.stdout], daemon=True).start()
    time.sleep(0.3)

    check("Identity is Spotify", get("Identity", "org.mpris.MediaPlayer2") == "(<'Spotify'>,)",
          get("Identity", "org.mpris.MediaPlayer2"))
    check("nothing loaded: Stopped", get("PlaybackStatus") == "(<'Stopped'>,)", get("PlaybackStatus"))
    check("nothing loaded: can't play", get("CanPlay") == "(<false>,)", get("CanPlay"))
    check("nothing loaded: Metadata empty", get("Metadata") == "(<@a{sv} {}>,)", get("Metadata"))
    check("unknown property is an error", get("Nonsense").startswith("ERROR"), get("Nonsense"))
    call("Play")
    check("Play with nothing loaded sends nothing", soloist.sent == [], str(soloist.sent))

    soloist.item = {"id": "4Indecision", "title": "Indecision Time"}
    soloist.status = "playing"
    soloist.position = 38.0
    soloist.changed()
    check("PropertiesChanged: Playing", until(lambda: any("'Playing'" in s for s in signals)), "".join(signals))
    meta = get("Metadata")
    check("Metadata has the song", all(x in meta for x in (
        "'xesam:title': <'Indecision Time'>", "'xesam:artist': <['Hüsker Dü']>", "'xesam:album': <'Zen Arcade'>",
        "'mpris:length': <int64 134000000>", "'mpris:artUrl': <'https://i.scdn.co/image/zen'>",
        "'mpris:trackid': <objectpath '/org/omarock/spotify/track/4Indecision'>")), meta)
    check("Position in microseconds", get("Position") == "(<int64 38000000>,)", get("Position"))
    check("Volume stays 1.0", get("Volume") == "(<1.0>,)", get("Volume"))

    soloist.sent.clear()
    call("PlayPause")
    call("Next")
    call("Previous")
    check("PlayPause while playing pauses; Next, Previous",
          [n for n, _ in soloist.sent] == ["pause", "skip_next", "skip_prev"], str(soloist.sent))
    soloist.status = "paused"
    soloist.changed()
    until(lambda: any("'Paused'" in s for s in signals))
    soloist.sent.clear()
    call("PlayPause")
    check("PlayPause while paused plays", soloist.sent == [("play", {})], str(soloist.sent))

    soloist.sent.clear()
    call("Seek", "10000000")
    check("Seek +10 s from 38 s", soloist.sent == [("seek", {"position_ms": 48000})], str(soloist.sent))
    soloist.sent.clear()
    call("SetPosition", "/org/omarock/spotify/track/4Indecision", "5000000")
    call("SetPosition", "/org/omarock/spotify/track/other", "9000000")
    check("SetPosition only for the current song", soloist.sent == [("seek", {"position_ms": 5000})],
          str(soloist.sent))
    soloist.sent.clear()
    call("Seek", "200000000")
    check("Seek past the end goes to the next song", soloist.sent == [("skip_next", {})], str(soloist.sent))

    soloist.sent.clear()
    gdbus("--method", "org.freedesktop.DBus.Properties.Set", PLAYER, "Volume", "<0.2>")
    check("setting Volume is ignored", soloist.sent == [] and get("Volume") == "(<1.0>,)", str(soloist.sent))
    gdbus("--method", "org.freedesktop.DBus.Properties.Set", PLAYER, "Shuffle", "<true>")
    gdbus("--method", "org.freedesktop.DBus.Properties.Set", PLAYER, "LoopStatus", "<'Track'>")
    check("Shuffle and LoopStatus go to Soloist", soloist.sent == [
        ("set_shuffle", {"enabled": True}), ("set_repeat_track", {"enabled": True}),
        ("set_repeat_context", {"enabled": False})], str(soloist.sent))

    signals.clear()
    soloist.position = 90.0
    soloist.changed()
    check("a jump in the same song sends Seeked", until(lambda: any(".Seeked" in s for s in signals)),
          "".join(signals))
    signals.clear()
    soloist.item = {"id": "5Dreams", "title": "Dreams Reoccurring"}
    soloist.position = 0.0
    soloist.status = "playing"
    soloist.changed()
    until(lambda: any("Dreams Reoccurring" in s for s in signals))
    time.sleep(0.3)
    check("a new song sends Metadata, not Seeked",
          any("Dreams Reoccurring" in s for s in signals) and not any(".Seeked" in s for s in signals),
          "".join(signals))
    soloist.status = "paused"
    soloist.yielded = True
    soloist.changed()
    check("after mpd plays: Stopped", until(lambda: get("PlaybackStatus") == "(<'Stopped'>,)"),
          get("PlaybackStatus"))
    check("after mpd plays: can't play or skip", get("CanPlay") == "(<false>,)" and get("CanGoNext") == "(<false>,)",
          get("CanPlay") + get("CanGoNext"))
    check("after mpd plays: Metadata empty", get("Metadata") == "(<@a{sv} {}>,)", get("Metadata"))
    soloist.sent.clear()
    for method in ("PlayPause", "Play", "Next", "Previous"):
        call(method)
    call("Seek", "1000000")
    check("after mpd plays: the keys send Spotify nothing", soloist.sent == [], str(soloist.sent))
    soloist.yielded = False
    soloist.changed()
    check("Spotify again: Paused, can play", until(lambda: get("PlaybackStatus") == "(<'Paused'>,)")
          and get("CanPlay") == "(<true>,)", get("PlaybackStatus") + get("CanPlay"))

    # Another machine's Spotify playing: paused here, the keys don't reach
    # it, and Play moves it here.
    soloist.active = False
    soloist.status = "playing"
    soloist.changed()
    time.sleep(0.3)
    check("playing on another machine: Paused here", get("PlaybackStatus") == "(<'Paused'>,)", get("PlaybackStatus"))
    soloist.sent.clear()
    for method in ("Pause", "Stop", "Next", "Previous"):
        call(method)
    call("Seek", "1000000")
    check("playing on another machine: pause, skip and seek send nothing", soloist.sent == [], str(soloist.sent))
    call("PlayPause")
    check("playing on another machine: PlayPause moves it here", soloist.sent == [("move here", {})], str(soloist.sent))
    monitor.terminate()
    print(f"{'FAILED: ' + ', '.join(failures) if failures else 'all passed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
