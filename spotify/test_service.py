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

    library()
    print("all passed" if not failures else "FAILED: " + ", ".join(failures))
    sys.exit(1 if failures else 0)


def library():
    """Add to and remove from the library: Spotify's /me/library, 40 URIs a call,
    with a stand-in for the Web API."""
    calls = []
    service.spotify_web.call = lambda method, path, body=None: (calls.append((method, path)), (200, None))[1]
    service.WEB.library = {"songs": []}
    songs = [{"kind": "song", "id": f"t{i}", "source": "catalog"} for i in range(41)]
    out = service.post("library/add", ["library", "add"], {"items": songs + [{"kind": "album", "id": "a1"}]})
    query = [service.urllib.parse.parse_qs(service.urllib.parse.urlparse(p).query)["uris"][0].split(",") for _, p in calls]
    check("add: PUT /me/library, 40 URIs, then the rest", out == {"ok": True} and [m for m, _ in calls] == ["PUT", "PUT"]
          and len(query[0]) == 40 and query[0][0] == "spotify:track:t0" and query[1] == ["spotify:track:t40", "spotify:album:a1"],
          str(calls))
    check("add: the library is read again next time", service.WEB.library is None)
    calls.clear()
    service.post("library/remove", ["library", "remove"], {"items": [songs[0]]})
    check("remove: DELETE /me/library", calls == [("DELETE", "/me/library?uris=spotify%3Atrack%3At0")], str(calls))
    try:
        service.post("library/add", ["library", "add"], {"items": [{"kind": "artist", "id": "x"}]})
        check("an artist isn't added", False)
    except ValueError as e:
        check("an artist isn't added", "songs and albums" in str(e), str(e))
    service.spotify_web.call = lambda method, path, body=None: (403, {"error": {"message": "Insufficient client scope"}})
    try:
        service.post("library/add", ["library", "add"], {"items": [songs[0]]})
        check("Spotify refusing is an error", False)
    except service.ApiError as e:
        check("Spotify refusing is an error", "Insufficient client scope" in str(e), str(e))


if __name__ == "__main__":
    main()
