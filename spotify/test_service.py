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
REAL_CALL = service.spotify_web.call  # the tests below swap in their own
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
    queue_jump()
    web_pages()
    other_accounts()
    dropped()
    limited()
    paced()
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




def queue_jump():
    """Marc, 10-26: a click on the top of the queue played the song under it,
    the bar flashing through every song. The jump stepped back with
    skip_prev, which restarts a song a few seconds in. Now one Web API call:
    the album or playlist from that song, else the queue's songs from it."""
    def track(name): return {"item": {"uri": "spotify:track:" + name, "entity_type": "track"}}
    plays = []
    real_play = service.web_play

    def queue(context):
        s = fresh()
        s.handle({"type": "playback_state", "status": "playing", "item": track("plows")["item"], "is_active": True,
                  "context": context})
        s.handle({"type": "queue_changed", "previous": [track("rome"), track("first")], "upcoming": [track("compute"), track("luau")]})
        return s

    def fake_play(fails=False):
        def play(body):
            plays.append(body)
            if fails and "context_uri" in body:
                raise service.ApiError(404, {"error": {"message": "not in the album"}})
            uri = body["offset"].get("uri") or body["uris"][body["offset"]["position"]]
            threading.Timer(0.05, service.SOLOIST.handle, [{"type": "track_changed", "item": {"uri": uri}}]).start()
        return play
    try:
        s = queue({"uri": "spotify:album:yankcrime"})
        names = [uri.split(":")[-1] for uri, _ in s.queue_list()[0]]
        check("the queue as the status lists it: before, playing, after",
              names == ["first", "rome", "plows", "compute", "luau"] and s.queue_list()[1] == 2, str(names))
        service.web_play = fake_play()
        out = service.post("queue/jump", ["queue", "jump"], {"index": 0})
        check("a jump back plays the album from that song, in one go, with no skips",
              plays == [{"context_uri": "spotify:album:yankcrime", "offset": {"uri": "spotify:track:first"}}]
              and not any(c.startswith("skip") for c in s.ws.sent) and out["song"]["id"] == "first", f"{plays} {s.ws.sent}")

        plays.clear()
        s = queue(None)
        service.web_play = fake_play()
        service.post("queue/jump", ["queue", "jump"], {"index": 4})
        check("from no album or playlist: the queue's songs, from that one",
              plays == [{"uris": ["spotify:track:" + n for n in ["first", "rome", "plows", "compute", "luau"]], "offset": {"position": 4}}],
              str(plays))

        plays.clear()
        s = queue({"uri": "spotify:playlist:mix"})
        service.web_play = fake_play(fails=True)
        service.post("queue/jump", ["queue", "jump"], {"index": 1})
        check("a song not in the playlist (queued by hand): the queue's songs instead",
              len(plays) == 2 and plays[1]["offset"] == {"position": 1}, str(plays))

        plays.clear()
        s = queue({"uri": "spotify:album:yankcrime"})
        service.web_play = fake_play()
        service.post("queue/jump", ["queue", "jump"], {"index": 2})
        check("the song playing: back to its start", plays == [] and s.ws.sent == ["seek"], f"{plays} {s.ws.sent}")
    finally:
        service.web_play = real_play


def web_pages():
    """A web page can't drive the service: the real handler, on a spare port."""
    import http.client
    server = service.ThreadingHTTPServer(("127.0.0.1", 0), service.Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def ask(method, path, headers=None, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request(method, path, body=body, headers=headers or {})
        reply = conn.getresponse()
        return reply.status, reply.read().decode()

    omarock = {"X-Omarock": "1"}
    try:
        check("omarock's request gets past the check", ask("GET", "/v1/nosuch", omarock)[0] == 404)
        check("a request without X-Omarock is refused", ask("GET", "/v1/nosuch")[0] == 403)
        check("another name for this address is refused (DNS rebinding)",
              ask("GET", "/v1/nosuch", dict(omarock, Host=f"rebind.example:{port}"))[0] == 403)
        check("a body that isn't JSON is refused (a form's text/plain)",
              ask("POST", "/v1/logout", dict(omarock, **{"Content-Type": "text/plain"}), '{"a": 1}')[0] == 403)
        service.WEB.pending_login = None
        code, page = ask("GET", "/callback?error=%3Cscript%3Ealert(1)%3C/script%3E")
        check("the sign-in page shows an error as text, not as HTML",
              code == 400 and "<script>" not in page and "&lt;script&gt;" in page, page)
    finally:
        server.shutdown()
        server.server_close()


def other_accounts():
    """Another account's programs are refused, by who owns the connection's far
    end in the kernel's socket table. Here every connection is this account's,
    so "another account" is this one with the service told it runs as another."""
    import http.client
    import socket
    check("an address as /proc/net/tcp shows it",
          service.proc_address("127.0.0.1", 8730) == ("0100007F:221A" if sys.byteorder == "little" else "7F000001:221A"),
          service.proc_address("127.0.0.1", 8730))
    check("and as tcp6 shows an IPv6 socket connected to 127.0.0.1",
          service.proc_address("::ffff:127.0.0.1", 8730) == ("0000000000000000FFFF00000100007F:221A"
                                                             if sys.byteorder == "little" else
                                                             "00000000000000000000FFFF7F000001:221A"),
          service.proc_address("::ffff:127.0.0.1", 8730))
    listener = socket.create_server(("127.0.0.1", 0))
    client = socket.create_connection(listener.getsockname())
    accepted, _ = listener.accept()
    check("a connection of this account's: its far end is ours",
          service.socket_owners(accepted.getpeername(), accepted.getsockname()) == [service.ME]
          and service.from_another_account(accepted) is None,
          service.socket_owners(accepted.getpeername(), accepted.getsockname()))
    v6 = socket.socket(socket.AF_INET6)
    v6.connect(("::ffff:127.0.0.1", listener.getsockname()[1]))
    accepted6, _ = listener.accept()
    check("an IPv6 socket's connection to 127.0.0.1 is found too",
          service.socket_owners(accepted6.getpeername(), accepted6.getsockname()) == [service.ME])
    client.close()
    time.sleep(0.1)
    check("a connection whose far end has closed is refused (no owner left to check)",
          service.from_another_account(accepted) is not None,
          service.socket_owners(accepted.getpeername(), accepted.getsockname()))
    for s in (accepted, accepted6, v6, listener):
        s.close()

    # The other way: what omarock-spotify connects to (Soloist's control
    # port), checked before anything is sent, while the connection may still
    # wait in the listener's queue (not accepted yet).
    import soloist_ws
    listener = socket.create_server(("127.0.0.1", 0))
    sent = []
    try:
        soloist_ws.WebSocket(port=listener.getsockname()[1], timeout=2, check=lambda sock: sent.append(
            service.socket_owners(sock.getpeername()[:2], sock.getsockname()[:2], queued=True)) or None)
    except (OSError, soloist_ws.Closed):
        pass  # nothing answers the handshake: only the check matters here
    check("Soloist's port held by this account: its far end, still in the queue, is ours",
          sent == [[service.ME]], sent)
    listener.close()
    listener = socket.create_server(("127.0.0.1", 0))
    real_me = service.ME
    service.ME = real_me + 1  # as if another account held the port
    try:
        try:
            soloist_ws.WebSocket(port=listener.getsockname()[1], timeout=2, check=service.soloist_not_ours)
            refused = None
        except soloist_ws.Closed as e:
            refused = str(e)
        queued = listener.accept()[0]
        queued.settimeout(1)
        try:
            got = queued.recv(100)
        except OSError:
            got = b"(nothing)"
    finally:
        service.ME = real_me
    check("held by another account: omarock-spotify sends it nothing, and says why",
          refused == "Soloist's control port is held by another account" and got in (b"", b"(nothing)"), (refused, got))
    queued.close()
    listener.close()

    server = service.ThreadingHTTPServer(("127.0.0.1", 0), service.Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def ask():
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request("GET", "/v1/nosuch", headers={"X-Omarock": "1"})
        reply = conn.getresponse()
        return reply.status, reply.read().decode()

    me = service.ME
    try:
        check("this account's request gets past the check", ask()[0] == 404)
        service.ME = me + 4242
        code, text = ask()
        check("another account's is refused, before its request is read",
              code == 403 and "Only the account running omarock-spotify" in text, f"{code} {text}")
    finally:
        service.ME = me
        server.shutdown()
        server.server_close()


def dropped():
    """Marc, 10-27: opening an album said "omarock-spotify failed: Remote end
    closed connection without response". Spotify had closed the connection
    without answering; the same album opened at once afterwards."""
    import http.client
    import http.server
    import json
    import tempfile
    web = service.spotify_web
    web.call = REAL_CALL
    folder = Path(tempfile.mkdtemp())
    web.TOKENS = folder / "spotify-token.json"
    web.TOKENS.write_text(json.dumps({"access_token": "a", "refresh_token": "r", "expires_at": time.time() + 3600}))
    seen, drops = [], [0]

    class Api(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass

        def answer(self):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            seen.append(self.command)
            if drops[0]:
                drops[0] -= 1
                return  # the connection closes without a word
            body = b'{"name": "Sixteen Stone"}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        do_GET = do_POST = answer
    api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
    threading.Thread(target=api.serve_forever, daemon=True).start()
    real_api, web.API = web.API, f"http://127.0.0.1:{api.server_address[1]}"
    ours = service.ThreadingHTTPServer(("127.0.0.1", 0), service.Handler)
    threading.Thread(target=ours.serve_forever, daemon=True).start()

    def fails(method):
        try:
            web.call(method, "/albums/x")
            return ""
        except web.ApiError as e:
            return str(e)
    try:
        drops[0] = 1
        got = web.call("GET", "/albums/x")
        check("dropped once: a GET is tried again", got == (200, {"name": "Sixteen Stone"}) and seen == ["GET", "GET"],
              f"{got} {seen}")
        seen.clear(); drops[0] = 2
        error = fails("GET")
        check("dropped twice: a GET says so", "closed the connection" in error and seen == ["GET", "GET"],
              f"{error!r} {seen}")
        seen.clear(); drops[0] = 1
        error = fails("POST")
        check("dropped: a POST isn't tried again", "closed the connection" in error and seen == ["POST"],
              f"{error!r} {seen}")
        seen.clear(); drops[0] = 2
        conn = http.client.HTTPConnection("127.0.0.1", ours.server_address[1], timeout=5)
        conn.request("GET", "/v1/albums/catalog/x", headers={"X-Omarock": "1"})
        reply = conn.getresponse()
        text = reply.read().decode()
        check("dropped: the panel gets a 502 that says to try again",
              reply.status == 502 and "try again" in json.loads(text)["error"], f"{reply.status} {text}")
    finally:
        web.API = real_api
        for server in (api, ours):
            server.shutdown()
            server.server_close()


def limited():
    """Marc, 10-28: "spotify said 429: too many requests". The expanded
    panel's previews had asked for a dozen artist pages in a few seconds,
    each up to 14 requests to Spotify, and every one went on asking."""
    import http.client
    import http.server
    import json
    import tempfile
    web = service.spotify_web
    web.call = REAL_CALL
    folder = Path(tempfile.mkdtemp())
    web.TOKENS = folder / "spotify-token.json"
    web.TOKENS.write_text(json.dumps({"access_token": "a", "refresh_token": "r", "expires_at": time.time() + 3600}))
    seen, limits = [], {"count": 0, "wait": "1"}

    class Api(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass

        def answer(self):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            seen.append(self.command + " " + self.path.split("?")[0])
            if limits["count"]:
                limits["count"] -= 1
                body = b'{"error": {"status": 429, "message": "API rate limit exceeded"}}'
                self.send_response(429)
                self.send_header("Retry-After", limits["wait"])
            else:
                path = self.path.split("?")[0]
                body = json.dumps({"tracks": {"items": []}} if path.endswith("/search")
                                  else {"items": [], "next": None} if path.endswith("/albums")
                                  else {"id": "x", "name": "Bush"}).encode()
                self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        do_GET = do_POST = answer
    api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
    threading.Thread(target=api.serve_forever, daemon=True).start()
    real_api, web.API = web.API, f"http://127.0.0.1:{api.server_address[1]}"
    ours = service.ThreadingHTTPServer(("127.0.0.1", 0), service.Handler)
    threading.Thread(target=ours.serve_forever, daemon=True).start()

    def fails(method):
        try:
            web.call(method, "/albums/x")
            return ""
        except web.ApiError as e:
            return str(e)
    try:
        web.paused_until = web.due = 0.0
        limits.update(count=1, wait="1")
        began = time.monotonic()
        got = web.call("GET", "/albums/x")
        check("429 asking for 1 s: a GET waits, then is tried again",
              got[0] == 200 and len(seen) == 2 and time.monotonic() - began >= 1, f"{got} {seen}")
        seen.clear(); limits.update(count=1, wait="30")
        error = fails("GET")
        check("429 asking for 30 s: says when to try again", "try again in 30 s" in error and len(seen) == 1,
              f"{error!r} {seen}")
        error = fails("GET")
        check("while Spotify asks to wait, nothing is sent", "too many requests" in error and len(seen) == 1,
              f"{error!r} {seen}")
        conn = http.client.HTTPConnection("127.0.0.1", ours.server_address[1], timeout=5)
        conn.request("GET", "/v1/search?q=bush&scope=catalog", headers={"X-Omarock": "1"})
        reply = conn.getresponse()
        text = reply.read().decode()
        check("while Spotify asks to wait, a search says so",
              reply.status == 200 and "too many requests" in json.loads(text).get("catalogError", ""),
              f"{reply.status} {text}")
        web.paused_until = 0.0
        seen.clear(); limits.update(count=1, wait="1")
        error = fails("POST")
        check("429: a POST isn't tried again", "too many requests" in error and len(seen) == 1, f"{error!r} {seen}")
        web.paused_until = 0.0
        seen.clear()
        pages = service.Web()
        first = pages.artist("x")
        asked = len(seen)
        again = pages.artist("x")
        check("an artist page is kept: the second costs Spotify nothing",
              asked >= 4 and len(seen) == asked and again == first, f"{asked} then {len(seen)}")
    finally:
        web.API = real_api
        web.paused_until = 0.0
        for server in (api, ours):
            server.shutdown()
            server.server_close()


def paced():
    """Never as many requests as Spotify allows (Marc, 10-28: "I don't want
    to abuse Spotify and have them shut us off"): BURST at once, then RATE
    a second, with RESERVE of the burst kept from background work. Here 5
    at once, then 10 a second, 3 kept."""
    import http.server
    import json
    import tempfile
    web = service.spotify_web
    web.call = REAL_CALL
    folder = Path(tempfile.mkdtemp())
    web.TOKENS = folder / "spotify-token.json"
    web.TOKENS.write_text(json.dumps({"access_token": "a", "refresh_token": "r", "expires_at": time.time() + 3600}))
    arrived = []

    class Api(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass

        def do_GET(self):
            arrived.append((time.monotonic(), self.path))
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")
    api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
    threading.Thread(target=api.serve_forever, daemon=True).start()
    real = web.API, web.RATE, web.BURST, web.RESERVE
    web.API, web.RATE, web.BURST, web.RESERVE = f"http://127.0.0.1:{api.server_address[1]}", 10.0, 5, 3

    def at_once(n, path, background=False):
        def one():
            web.turns.background = background
            web.call("GET", path)
        threads = [threading.Thread(target=one) for _ in range(n)]
        for t in threads: t.start()
        return threads
    try:
        web.paused_until = web.due = 0.0
        began = time.monotonic()
        for t in at_once(15, "/front"): t.join()
        times = sorted(when - began for when, _ in arrived)
        late = [round(t, 2) for i, t in enumerate(times) if t < (i - 5 + 1) / 10 - 0.02]
        check("15 at once: 5 go, then 10 a second", len(times) == 15 and times[4] < 0.2 and not late and times[-1] >= 0.98,
              f"{[round(t, 2) for t in times]}")
        time.sleep(1.5)
        arrived.clear()
        web.due = 0.0
        began = time.monotonic()
        behind = at_once(10, "/background", background=True)
        time.sleep(0.05)
        front = at_once(3, "/front")
        for t in front: t.join()
        quick = [round(when - began, 2) for when, path in arrived if path == "/front"]
        first = [when for when, path in arrived if path == "/background"]
        check("background work leaves the reserve: 3 asked after 10 queued go at once",
              len(quick) == 3 and max(quick) < 0.2 and len(first) <= 3, f"{quick}, {len(first)} of the background already")
        for t in behind: t.join()
        check("and the background work all goes, after", sum(path == "/background" for _, path in arrived) == 10)
    finally:
        web.API, web.RATE, web.BURST, web.RESERVE = real
        web.turns.background = False
        web.due = 0.0
        api.shutdown()
        api.server_close()

if __name__ == "__main__":
    main()
