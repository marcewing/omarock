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
    s.handle({"type": "playback_state", "status": "playing", "item": ITEM, "is_active": True})
    check("Spotify starting makes it current", s.status_json()["current"] is True)

    out = service.post("release", ["release"], {})
    check("release pauses Spotify", s.ws.sent == ["pause"] and out["state"] == "paused", str(s.ws.sent))
    check("release: not current", out["current"] is False)
    s.status = "playing"   # as if Soloist reported playing late, already playing
    s.handle({"type": "playback_state", "status": "playing", "item": ITEM, "is_active": True})
    check("a late report of playing doesn't make it current again", s.status_json()["current"] is False)

    s = fresh()
    s.handle({"type": "playback_state", "status": "paused", "item": ITEM, "is_active": True})
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
    s.handle({"type": "playback_state", "status": "playing", "item": ITEM, "is_active": True})
    service.mpd_changed(s, None, "play")
    check("connecting to a playing mpd: not current, Spotify not paused", s.yielded and s.ws.sent == [], str(s.ws.sent))
    s.yielded = False
    service.mpd_changed(s, "pause", "play")
    time.sleep(0.1)
    check("mpd starting: Spotify pauses, mpd is current", s.yielded and s.ws.sent == ["pause"], str(s.ws.sent))
    s.ws.sent.clear()
    service.mpd_changed(s, "play", "pause")
    check("mpd pausing changes nothing", s.yielded and s.ws.sent == [], str(s.ws.sent))

    elsewhere()
    volume()
    library()
    album_library()
    renewal()
    sign_out()
    print("all passed" if not failures else "FAILED: " + ", ".join(failures))
    sys.exit(1 if failures else 0)


def elsewhere():
    """Another machine's Spotify playing (this Soloist isn't the active
    device): paused here, and not Spotify starting here, so mpd isn't paused;
    pause, skip and seek don't reach it, release and mpd leave it playing;
    resume moves it here, with the Web API."""
    calls = []

    def call(method, path, body=None):
        calls.append((method, path, body))
        return (200, {"device": {"name": "framework"}, "is_playing": True}) if method == "GET" else (204, None)
    service.spotify_web.call = call
    service.device_id = lambda: "dev-here"
    s = fresh()
    s.on_playing = lambda: service.pause_mpd()
    s.handle({"type": "playback_state", "status": "playing", "item": ITEM, "is_active": False})
    time.sleep(0.1)
    out = s.status_json()
    check("elsewhere: paused here, not current, mpd left alone",
          out["state"] == "paused" and out["current"] is False and service.mpd_paused == [], f"{out['state']} {out['current']} {service.mpd_paused}")
    check("elsewhere: says where", out.get("elsewhere") == "framework", str(out.get("elsewhere")))
    for path in ("pause", "next", "seek"):
        try:
            service.post(path, [path], {"position": 10})
            check(f"elsewhere: {path} refused", False)
        except RuntimeError as e:
            check(f"elsewhere: {path} refused, saying where", "playing on framework" in str(e) and s.ws.sent == [], f"{e} {s.ws.sent}")
    service.post("release", ["release"], {})
    s.yielded = False
    service.mpd_changed(s, "pause", "play")
    time.sleep(0.1)
    check("elsewhere: release and mpd starting leave it playing", s.ws.sent == [], str(s.ws.sent))

    calls.clear()
    s.yielded = True
    threading.Timer(0.1, s.handle, [{"type": "playback_state", "status": "playing", "item": ITEM, "is_active": True}]).start()
    out = service.post("resume", ["resume"], {})
    check("resume moves it here", ("PUT", "/me/player", {"device_ids": ["dev-here"], "play": True}) in calls
          and s.ws.sent == [] and out["state"] == "playing" and "elsewhere" not in out, f"{calls} {s.ws.sent} {out['state']}")
    time.sleep(0.1)
    check("moved here, it's Spotify starting here: current, mpd paused",
          out["current"] is True and service.mpd_paused == [False], f"{out['current']} {service.mpd_paused}")


def volume():
    """Without omarock's sound output, Soloist's volume is the volume: in the
    status, set by POST /v1/volume, left where a phone puts it. With it,
    Soloist's stays at 100 and the bus's is the volume."""
    import tempfile
    service.BUS_CONF = Path(tempfile.mkdtemp()) / "omarock-bus.conf"
    s = fresh()
    s.handle({"type": "playback_state", "status": "paused", "item": ITEM, "is_active": True, "volume": 40})
    check("no bus: the status has Soloist's volume", s.status_json().get("volume") == 40, str(s.status_json().get("volume")))
    seq = s.seq
    s.handle({"type": "volume_changed", "volume": 65})
    time.sleep(0.1)
    check("no bus: a phone's change stays, and is reported", s.ws.sent == [] and s.status_json()["volume"] == 65 and s.seq != seq,
          f"{s.ws.sent} {s.status_json().get('volume')}")
    s.ws.command = lambda name, **args: s.ws.sent.append((name, args))
    service.post("volume", ["volume"], {"volume": 30.4})
    check("no bus: POST /v1/volume sets Soloist's", s.ws.sent == [("set_volume", {"volume": 30})], str(s.ws.sent))

    service.BUS_CONF.write_text("")
    s = fresh()
    s.ws.command = lambda name, **args: s.ws.sent.append((name, args))
    s.handle({"type": "playback_state", "status": "paused", "item": ITEM, "is_active": True, "volume": 100})
    check("the bus: no volume in the status", "volume" not in s.status_json())
    s.handle({"type": "volume_changed", "volume": 40})
    time.sleep(0.1)
    check("the bus: Soloist's goes back to 100", s.ws.sent == [("set_volume", {"volume": 100})], str(s.ws.sent))
    try:
        service.post("volume", ["volume"], {"volume": 30})
        check("the bus: POST /v1/volume refused", False)
    except RuntimeError as e:
        check("the bus: POST /v1/volume refused", "sound output" in str(e), str(e))


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


def album_library():
    """The album route says which of its songs, and whether the album, are in
    your library: /me/library/contains, 40 URIs a call."""
    tracks = [{"id": f"t{i}", "name": f"Song {i}", "artists": [{"id": "ar", "name": "Artist"}]} for i in range(41)]
    album = {"id": "a1", "name": "Album", "artists": [{"id": "ar", "name": "Artist"}], "tracks": {"items": tracks}}
    asked = []

    def call(method, path, body=None):
        if path.startswith("/albums/"):
            return 200, album
        uris = service.urllib.parse.parse_qs(service.urllib.parse.urlparse(path).query)["uris"][0].split(",")
        asked.append(uris)
        return 200, [uri in ("spotify:album:a1", "spotify:track:t1", "spotify:track:t40") for uri in uris]
    service.spotify_web.call = call
    out = service.Handler.route(None, "GET", ["albums", "catalog", "a1"], {}, {})
    mine = [t["id"] for t in out["tracks"] if t.get("inLibrary")]
    check("album: the saved album and the liked songs", out["album"].get("inLibrary") is True and mine == ["t1", "t40"]
          and all(t.get("inLibrary") is False for t in out["tracks"] if t["id"] not in mine), str(mine))
    check("album: 40 URIs a call", [len(u) for u in asked] == [40, 2], str([len(u) for u in asked]))
    service.spotify_web.call = lambda method, path, body=None: (200, album) if path.startswith("/albums/") else (403, None)
    out = service.Handler.route(None, "GET", ["albums", "catalog", "a1"], {}, {})
    check("album: Spotify not saying leaves it out", "inLibrary" not in out["album"]
          and not any("inLibrary" in t for t in out["tracks"]))
    asked.clear()
    service.spotify_web.call = call
    service.WEB.album("a1")
    check("album for playing: not asked", asked == [], str(asked))


def renewal():
    """Requests arriving together renew the sign-in once, not each."""
    import json
    import tempfile
    web = service.spotify_web
    folder = Path(tempfile.mkdtemp())
    web.CONFIG, web.TOKENS = folder / "spotify.json", folder / "spotify-token.json"
    web.CONFIG.write_text(json.dumps({"clientId": "test"}))
    web.TOKENS.write_text(json.dumps({"access_token": "old", "refresh_token": "r1", "expires_at": 0}))
    renewals = []

    def token_request(fields):
        renewals.append(fields["refresh_token"])
        time.sleep(0.2)
        return {"access_token": "new", "refresh_token": "r2", "expires_in": 3600}
    web.token_request = token_request
    got, errors = [], []

    def ask():
        try: got.append(web.access_token())
        except Exception as e: errors.append(repr(e))
    threads = [threading.Thread(target=ask) for _ in range(4)]
    for t in threads: t.start()
    for t in threads: t.join()
    check("renewing: once for four requests", renewals == ["r1"] and got == ["new"] * 4 and not errors,
          f"{renewals} {got} {errors}")
    check("renewing: the new tokens saved, nothing left behind",
          json.loads(web.TOKENS.read_text())["refresh_token"] == "r2" and sorted(p.name for p in folder.iterdir())
          == ["spotify-token.json", "spotify.json"], str(list(folder.iterdir())))


def sign_out():
    """POST /v1/logout forgets the Web API's sign-in, and what it fetched."""
    import json
    import tempfile
    web = service.spotify_web
    folder = Path(tempfile.mkdtemp())
    web.TOKENS = folder / "spotify-token.json"
    web.TOKENS.write_text(json.dumps({"access_token": "a", "refresh_token": "r", "expires_at": time.time() + 3600,
                                      "signed_in_at": int(time.time())}))
    service.WEB.me, service.WEB.library = {"id": "me"}, {"playlists": []}
    fresh()
    before = service.health()["web"]
    reply = service.post("logout", ["logout"], {})
    after = service.health()["web"]
    check("sign out: the sign-in and what it fetched are gone",
          before["signedIn"] and reply == {"ok": True} and not after["signedIn"] and not web.TOKENS.exists()
          and service.WEB.me is None and service.WEB.library is None, f"{before} {after}")
    try:
        web.access_token()
        check("sign out: requests then need a new sign-in", False)
    except web.NotSignedIn:
        check("sign out: requests then need a new sign-in", True)
    check("sign out: twice is fine", service.post("logout", ["logout"], {}) == {"ok": True})


if __name__ == "__main__":
    main()
