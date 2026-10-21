#!/usr/bin/env python3
"""Tests for omarock-spotify's source switching, with a stand-in for Soloist's
WebSocket and for mpd: nothing here reaches Soloist, Spotify or mpd.

    python3 -I spotify/test_service.py
"""
import importlib.util
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("omarock_spotify", HERE / "omarock-spotify.py")
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)
failures = []


def check(what, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + what + (f": {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(what)


class FakeSocket:
    """Soloist's WebSocket: play and pause answer with the event Soloist sends."""
    def __init__(self, soloist):
        self.soloist, self.sent = soloist, []

    def command(self, name, **args):
        self.sent.append(name)
        status = {"play": "playing", "pause": "paused"}.get(name)
        if status:
            threading.Timer(0.05, self.soloist.handle, [{"type": "playback_changed", "status": status}]).start()


def fresh():
    soloist = service.Soloist()
    soloist.ws = FakeSocket(soloist)
    service.SOLOIST = soloist
    service.mpd_paused = []
    service.pause_mpd = lambda quiet=False: service.mpd_paused.append(quiet)
    return soloist


ITEM = {"uri": "spotify:track:4Indecision", "entity_type": "track"}


def main():
    s = fresh()
    check("at start, mpd's: not current", s.status_json()["current"] is False)
    s.handle({"type": "playback_state", "status": "playing", "item": ITEM})
    check("Spotify starting makes it current", s.status_json()["current"] is True)

    out = service.post("release", ["release"], {})
    check("release pauses Spotify", s.ws.sent == ["pause"] and out["state"] == "paused", str(s.ws.sent))
    check("release: not current", out["current"] is False)
    s.status = "playing"   # as if Soloist reported playing late, already playing
    s.handle({"type": "playback_state", "status": "playing", "item": ITEM})
    check("a late report of playing doesn't make it current again", s.status_json()["current"] is False)

    s = fresh()
    s.handle({"type": "playback_state", "status": "paused", "item": ITEM})
    out = service.post("activate", ["activate"], {})
    check("activate: current, mpd paused, Spotify resumes",
          out["current"] is True and service.mpd_paused == [True] and s.ws.sent == ["play"] and out["state"] == "playing",
          f"{out['current']} {service.mpd_paused} {s.ws.sent} {out['state']}")

    s = fresh()
    out = service.post("activate", ["activate"], {})
    check("activate with nothing loaded: current, nothing to play",
          out["current"] is True and s.ws.sent == [] and service.mpd_paused == [True], str(s.ws.sent))
    out = service.post("release", ["release"], {})
    check("release while paused sends nothing", out["current"] is False and s.ws.sent == [], str(s.ws.sent))

    s = fresh()
    s.handle({"type": "playback_state", "status": "playing", "item": ITEM})
    service.mpd_changed(s, None, "play")
    check("connecting to a playing mpd: not current, Spotify not paused", s.yielded and s.ws.sent == [], str(s.ws.sent))
    s.yielded = False
    service.mpd_changed(s, "pause", "play")
    time.sleep(0.1)
    check("mpd starting: Spotify pauses, mpd is current", s.yielded and s.ws.sent == ["pause"], str(s.ws.sent))
    s.ws.sent.clear()
    service.mpd_changed(s, "play", "pause")
    check("mpd pausing changes nothing", s.yielded and s.ws.sent == [], str(s.ws.sent))

    print("all passed" if not failures else "FAILED: " + ", ".join(failures))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
