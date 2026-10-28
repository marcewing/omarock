#!/usr/bin/python3
"""A fake omarock bridge (apple-bridge/API.md), for testing the panel's Apple Music
mode away from the Mac.

Serves a small made-up catalog and library over HTTP on 127.0.0.1, with the
bridge's JSON shapes, a long-polled status, a player that keeps time, and
artwork PNGs it draws itself. Every request is logged (method, path, body) so
the tests can check what the panel asked for. Nothing here makes a sound.

    fake_bridge.py <port-file> <token> <request-log> [--spotify <mpd-socket>]

--spotify makes it omarock-spotify (spotify/omarock-spotify.py) instead: no
token, no genres, a queue that songs can't be taken out of, catalog playlists
whose songs aren't listed, and "current" in the status. Like the real service,
it watches the (fake) mpd: Spotify starting to play stops or pauses mpd and
makes Spotify current; mpd starting to play pauses Spotify and makes it not
current; /v1/activate and /v1/release are omarock switching to and from it.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unicodedata
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fake_mpd import png  # noqa: E402

PORT = 0


def art(colour):
    return {"url": f"http://127.0.0.1:{PORT}/art/{colour}/{{w}}x{{h}}bb.png", "width": 1200, "height": 1200,
            "bgColor": colour, "textColor": "f2f2f2"}


def fold(text):
    text = unicodedata.normalize("NFD", str(text).lower())
    return "".join(c for c in text if not unicodedata.combining(c))


ARTISTS = [
    {"kind": "artist", "id": "c-ar-1", "source": "catalog", "name": "Hüsker Dü", "genres": ["Punk"],
     "editorialNotes": "Minneapolis trio."},
    {"kind": "artist", "id": "c-ar-2", "source": "catalog", "name": "Bob Mould", "genres": ["Alternative"]},
    # What the fake SiriusXM plays on 80s on 8, to look up.
    {"kind": "artist", "id": "c-ar-3", "source": "catalog", "name": "REO Speedwagon", "genres": ["Rock"]},
]
ALBUMS = {
    # id: (title, artist id, artist, year, colour, extra, [(title, seconds, disc)])
    "c-al-1": ("Zen Arcade", "c-ar-1", "Hüsker Dü", 1984, "8a3324", {"recordLabel": "SST Records"},
               [("Something I Learned Today", 124, 1), ("Broken Home, Broken Heart", 121, 1),
                ("Chartered Trips", 213, 2), ("Turn On the News", 263, 2)]),
    "c-al-2": ("New Day Rising", "c-ar-1", "Hüsker Dü", 1985, "c9a227", {"recordLabel": "SST Records"},
               [("New Day Rising", 151, 1), ("Girl Who Lives on Heaven Hill", 188, 1), ("Celebrated Summer", 244, 1)]),
    "c-al-3": ("Workbook", "c-ar-2", "Bob Mould", 1989, "3a6ea5", {"recordLabel": "Virgin"},
               [("Sunspots", 140, 1), ("See a Little Light", 197, 1)]),
    "c-al-4": ("Makes No Sense at All", "c-ar-1", "Hüsker Dü", 1985, "5a8a3c", {"isSingle": True},
               [("Makes No Sense at All", 165, 1)]),
    "c-al-5": ("Hi Infidelity", "c-ar-3", "REO Speedwagon", 1980, "b03030", {"recordLabel": "Epic"},
               [("Keep On Loving You", 200, 1), ("Take It On The Run", 239, 1)]),
}


def make_catalog():
    songs, albums = {}, {}
    n = 0
    for album_id, (title, artist_id, artist, year, colour, extra, tracks) in ALBUMS.items():
        album = {"kind": "album", "id": album_id, "source": "catalog", "catalogId": album_id, "title": title,
                 "artist": artist, "artistId": artist_id, "genres": ["Punk"], "year": year,
                 "releaseDate": f"{year}-07-01", "trackCount": len(tracks), "isCompilation": False,
                 "isSingle": False, "explicit": False, "audioTraits": ["lossless"], "artwork": art(colour),
                 "editorialNotes": f"{title}, from {year}.", "copyright": f"℗ {year}", "tracks": []}
        album.update(extra)
        number = {}
        for name, seconds, disc in tracks:
            n += 1
            number[disc] = number.get(disc, 0) + 1
            song = {"kind": "song", "id": f"c-so-{n}", "source": "catalog", "catalogId": f"c-so-{n}", "title": name,
                    "artist": artist, "album": title, "albumId": album_id, "artistId": artist_id, "genres": ["Punk"],
                    "year": year, "releaseDate": album["releaseDate"], "duration": float(seconds),
                    "trackNumber": number[disc], "discNumber": disc, "explicit": name == "Turn On the News",
                    "audioTraits": ["lossless"], "artwork": art(colour), "playable": True}
            songs[song["id"]] = song
            album["tracks"].append(song["id"])
        albums[album_id] = album
    return songs, albums


# Built in main, once the port (in the artwork URLs) is known.
SONGS, CATALOG_ALBUMS = {}, {}
GENRES = [{"id": "20", "name": "Alternative"}, {"id": "21", "name": "Rock"}, {"id": "14", "name": "Pop"},
          {"id": "1006", "name": "Punk"}]


class NoEndpoint(Exception):
    """A route this bridge doesn't have (an older bridge's 404)."""


class Refused(Exception):
    """Something the service can't do (a 409), like Spotify removing from its queue."""


def public(album):
    return {k: v for k, v in album.items() if k != "tracks"}


class Bridge:
    def __init__(self, log, mpd_socket=None):
        self.log = log
        # As omarock-spotify, with the fake mpd's socket.
        self.spotify = mpd_socket is not None
        self.mpd_socket = mpd_socket
        self.current = False
        self.lock = threading.Condition()
        self.seq = 1
        self.queue = [SONGS[i] for i in CATALOG_ALBUMS["c-al-2"]["tracks"]]
        self.index = 0
        self.state = "paused"
        self.base, self.started = 30.0, time.monotonic()
        self.shuffle, self.repeat = False, "off"
        # GET /v1/info, which older bridges lack (POST /v1/fake/info turns it on).
        self.info_route = False
        # The status's songs without albumId, artistId and inLibrary, and an
        # album's songs without inLibrary, as an older bridge sends them
        # (POST /v1/fake/bare).
        self.bare = False
        # The status's song from the library, but only on a playlist added to
        # it, as bridge 0.4.2 tells it: its artist id doesn't open on the
        # library's artist route (MusicKit doesn't list its album; bridges
        # before 0.4.2), and /v1/info says it isn't in the library until its
        # catalog copy is added (POST /v1/fake/orphan).
        self.orphan = False
        # Play answering 3 s late (POST /v1/fake/slow).
        self.slow = False
        # Albums and artists answering 1 s late, as a Spotify artist page
        # does (up to 13 Web API requests; POST /v1/fake/slowpages).
        self.slowpages = False
        # Searches answering late: POST /v1/fake/slowsearch {on, seconds}
        # (0.5 s if not said).
        self.slowsearch = 0
        # The machine it plays for (X-Omarock-Client), as the bridge 0.5 and
        # omarock-spotify 0.2.3 tell it: to another, while playing, the
        # status says where (and Spotify's says paused), and pause, skip and
        # seek are refused; Play moves it. POST /v1/fake/elsewhere {name}:
        # another machine pressed Play.
        self.owner, self.away = "", False
        self.refused = 0
        # POST /v1/library/add, which older bridges lack (POST /v1/fake/library
        # takes it away); what it added, and what Spotify's remove took out.
        self.library_route = True
        self.saved, self.unsaved = set(), set()
        # omarock-spotify 0.3 without omarock's sound output: Soloist's own
        # volume, in the status and set by POST /v1/volume (POST
        # /v1/fake/volume {on} switches it; off, as with the bus).
        self.volume = None
        # omarock-spotify's Web API sign-in: POST /v1/logout forgets it, POST
        # /v1/fake/signin {on} sets it (no browser here).
        self.signed_in = True
        # The library: a copy of Zen Arcade, and two playlists of songs.
        zen = dict(public(CATALOG_ALBUMS["c-al-1"]), id="l-al-1", source="library", catalogId="c-al-1")
        self.library_albums = [zen]
        # Its artist, as the library has it (Apple Music; Spotify's are followed artists).
        self.library_artists = [] if self.spotify else [
            {"kind": "artist", "id": "l-ar-1", "source": "library", "name": "Hüsker Dü"}]
        self.playlists = {
            "p-1": {"kind": "playlist", "id": "p-1", "source": "library", "name": "PunkRock", "curator": "You",
                    "canEdit": True, "lastModified": "2026-10-19T15:00:00Z", "artwork": art("aa2222"),
                    "songs": ["c-so-1", "c-so-5"]},
            "p-2": {"kind": "playlist", "id": "p-2", "source": "library", "name": "Road Songs", "curator": "You",
                    "canEdit": True, "lastModified": "2026-10-18T09:00:00Z", "songs": ["c-so-9"]},
        }
        self.catalog_playlists = {
            "c-pl-1": {"kind": "playlist", "id": "c-pl-1", "source": "catalog", "name": "Punk Essentials",
                       "curator": "Apple Music Punk", "description": "The canon.", "artwork": art("222222"),
                       "songs": ["c-so-1", "c-so-5", "c-so-8"]},
        }

    def owns(self, kind, cid):
        """Whether the library has it: Zen Arcade, and whatever was added;
        not the orphan song playing until it's added."""
        if (kind, cid) in self.unsaved: return False
        if (kind, cid) in self.saved: return True
        if self.orphan and kind == "song" and self.queue and cid == self.queue[self.index]["catalogId"]: return False
        zen = CATALOG_ALBUMS["c-al-1"]
        return cid in zen["tracks"] if kind == "song" else cid == "c-al-1"

    def changed(self):
        self.seq += 1
        self.lock.notify_all()
        # Spotify started playing: it's the source, and mpd stops.
        if self.spotify and self.state == "playing" and not self.was_playing:
            self.current = True
            threading.Thread(target=self.stop_mpd, daemon=True).start()
        self.was_playing = self.state == "playing"

    was_playing = False

    def mpd(self, command):
        with socket.socket(socket.AF_UNIX) as s:
            s.connect(self.mpd_socket)
            f = s.makefile("rwb")
            f.readline()
            f.write((command + "\n").encode()); f.flush()
            lines = []
            for raw in f:
                line = raw.decode().rstrip("\n")
                if line == "OK" or line.startswith("ACK"): break
                lines.append(line)
            return dict(l.split(": ", 1) for l in lines if ": " in l)

    def stop_mpd(self):
        status = self.mpd("status")
        if status.get("state") == "play":
            file = self.mpd("currentsong").get("file", "")
            self.mpd("stop" if "://" in file else "pause 1")

    def watch_mpd(self):
        """mpd starting to play pauses Spotify, which stops being the source."""
        last = None
        while True:
            try:
                with socket.socket(socket.AF_UNIX) as s:
                    s.connect(self.mpd_socket)
                    f = s.makefile("rwb")
                    f.readline()
                    while True:
                        f.write(b"status\n"); f.flush()
                        state = ""
                        for raw in f:
                            line = raw.decode().rstrip("\n")
                            if line == "OK" or line.startswith("ACK"): break
                            if line.startswith("state: "): state = line[7:]
                        if state == "play" and last != "play":
                            with self.lock:
                                self.current = False
                                # Another machine's Spotify plays on.
                                if self.state == "playing" and last is not None and not self.away:
                                    self.base, self.started, self.state = self.position(), time.monotonic(), "paused"
                                self.changed()
                        last = state
                        f.write(b"idle player\n"); f.flush()
                        for raw in f:
                            if raw == b"OK\n": break
            except OSError:
                time.sleep(0.5)

    def position(self):
        return self.base + (time.monotonic() - self.started if self.state == "playing" else 0)

    def elsewhere(self, client):
        return self.owner if self.away and client != self.owner and self.state == "playing" else ""

    def status(self, client=""):
        out = {"seq": self.seq, "state": self.state, "current": self.current, "position": round(self.position(), 2),
               "positionAt": time.time(), "queue": self.queue, "queueIndex": self.index, "queueOffset": 0,
               "queueLength": len(self.queue), "shuffle": self.shuffle, "repeat": self.repeat}
        if self.volume is not None:
            out["volume"] = self.volume
        if self.elsewhere(client):
            out["elsewhere"] = self.owner
            if self.spotify: out["state"] = "paused"
        if self.queue and self.state != "stopped":
            song = self.queue[self.index]
            out["song"] = dict(song, inLibrary=self.owns("song", song["catalogId"]))
        if self.bare and "song" in out:
            out["song"] = {k: v for k, v in out["song"].items() if k not in ("albumId", "artistId", "inLibrary")}
        if self.orphan and "song" in out:
            # As the bridge sends a library song: no catalogId, no inLibrary.
            song = {k: v for k, v in out["song"].items() if k not in ("inLibrary", "catalogId")}
            out["song"] = dict(song, id="l-" + out["song"]["catalogId"], source="library", artistId="l-ar-gone")
        return out

    def play_at(self, index, state="playing"):
        self.index, self.base, self.started, self.state = index, 0.0, time.monotonic(), state
        self.changed()

    def playlist(self, source, pid):
        table = self.playlists if source == "library" else self.catalog_playlists
        if pid not in table: raise KeyError(pid)
        p = table[pid]
        return dict({k: v for k, v in p.items() if k != "songs"}, trackCount=len(p["songs"])), [SONGS[s] for s in p["songs"]]

    def playlist_view(self, source, pid):
        playlist, tracks = self.playlist(source, pid)
        if self.spotify and source == "catalog":
            return {"playlist": playlist, "tracks": [],
                    "note": "Spotify lists the songs of your own playlists only. It can still play this one."}
        return {"playlist": playlist, "tracks": tracks}

    def album(self, source, aid):
        if source == "library":
            album = next(a for a in self.library_albums if a["id"] == aid)
            return album, [dict(SONGS[s], id="l-" + s, source="library") for s in CATALOG_ALBUMS[album["catalogId"]]["tracks"]]
        return public(CATALOG_ALBUMS[aid]), [SONGS[s] for s in CATALOG_ALBUMS[aid]["tracks"]]

    def expand(self, items):
        """Items to songs, as the bridge plays them or adds them to playlists."""
        songs = []
        for item in items:
            kind, iid, source = item["kind"], item.get("id", ""), item.get("source", "catalog")
            if kind == "song": songs.append(SONGS[iid[2:] if iid.startswith("l-") else iid])
            elif kind == "album": songs += self.album(source, iid)[1]
            elif kind == "playlist": songs += self.playlist(source, iid)[1]
            elif kind == "artist": songs += [s for s in SONGS.values() if s["artistId"] == iid][:5]
            elif kind == "queue": songs += self.queue
            else: raise ValueError("can't play a " + kind)
        return songs

    def info(self, source, kind, iid):
        """GET /v1/info (API.md, "Info"): the library holds Zen Arcade."""
        zen = CATALOG_ALBUMS["c-al-1"]
        if kind == "song":
            cid = iid[2:] if iid.startswith("l-") else iid
            item = SONGS[cid] if source == "catalog" else dict(SONGS[cid], id=iid, source="library")
            mine = self.owns("song", cid)
            library = {"id": "l-" + cid, "added": "2019-04-02T17:03:11Z", "playCount": 12, "skipCount": 1,
                       "lastPlayed": "2026-10-18T21:40:02Z", "rating": 80, "fileKind": "Apple Music AAC audio file",
                       "bitrate": 256, "sampleRate": 44100, "fileSize": 4194304, "cloud": True, "drm": True}
        elif kind == "album":
            cid = "c-al-1" if iid == "l-al-1" else iid
            item = self.album(source, iid)[0]
            mine = self.owns("album", cid)
            library = {"id": "l-al-1", "added": "2019-04-02T17:03:11Z", "trackCount": 4, "playCount": 40,
                       "lastPlayed": "2026-10-18T21:40:02Z"}
        else:
            raise ValueError("info is for songs and albums")
        out = {"item": item, "inLibrary": mine,
               "catalog": {"id": cid, "url": f"https://music.apple.com/us/{kind}/{cid}"}}
        if mine or source == "library": out["library"] = library
        return out

    def search(self, q, scope, limit):
        words = fold(q).split()
        # Every word somewhere in the names, as Apple's search finds "title artist".
        def hit(*names):
            hay = " ".join(fold(n or "") for n in names)
            return all(w in hay for w in words)
        # Library songs match by title only, so the artist searches keep their rows.
        library = {"songs": [dict(SONGS[s], id="l-" + s, source="library") for s in CATALOG_ALBUMS["c-al-1"]["tracks"]
                             if hit(SONGS[s]["title"])][:limit], "albums": [a for a in self.library_albums if hit(a["title"]) or hit(a["artist"])][:limit],
                   "artists": [a for a in self.library_artists if hit(a["name"])][:limit],
                   "playlists": [self.playlist("library", p)[0] for p, v in self.playlists.items() if hit(v["name"])][:limit]}
        catalog = {"songs": [s for s in SONGS.values() if hit(s["title"], s["artist"])][:limit],
                   "albums": [public(a) for a in CATALOG_ALBUMS.values() if hit(a["title"], a["artist"])][:limit],
                   "artists": [a for a in ARTISTS if hit(a["name"])][:limit],
                   "playlists": [self.playlist("catalog", p)[0] for p, v in self.catalog_playlists.items() if hit(v["name"])][:limit]}
        out = {}
        if scope in ("all", "library"): out["library"] = library
        if scope in ("all", "catalog"): out["catalog"] = catalog
        return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def reply(self, code, data, content_type="application/json"):
        body = data if isinstance(data, bytes) else json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the panel dropped an image it no longer shows

    def handle_any(self, method):
        bridge = self.server.bridge
        url = urlparse(self.path)
        # As omarock-spotify: only requests that say they're omarock's.
        if bridge.spotify and url.path.startswith("/v1/") and self.headers.get("X-Omarock") != "1":
            return self.reply(403, {"error": "Only omarock asks here (X-Omarock: 1)."})
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        parts = [p for p in url.path.split("/") if p]
        if parts[:1] == ["art"]:
            size = int(parts[2].split("x")[0])
            colour = parts[1]
            top = tuple(int(colour[i:i + 2], 16) for i in (0, 2, 4))
            with tempfile.NamedTemporaryFile(suffix=".png") as f:
                png(Path(f.name), top, tuple(c // 3 for c in top), min(size, 512))
                return self.reply(200, Path(f.name).read_bytes(), "image/png")
        with bridge.lock:
            bridge.log.write(json.dumps({"method": method, "path": url.path, "query": query, "body": body}) + "\n")
            bridge.log.flush()
        if url.path == "/v1/health":
            if bridge.spotify:
                web = {"signedIn": True, "signInEndsAt": int(time.time()) + 180 * 86400} if bridge.signed_in else {"signedIn": False}
                return self.reply(200, {"ok": True, "version": "fake", "authorized": bridge.signed_in, "canPlayCatalog": True,
                                        "current": bridge.current, "stream": "", "storefront": "US", "web": web})
            return self.reply(200, {"ok": True, "version": "fake", "authorized": True, "canPlayCatalog": True,
                                    "stream": f"http://127.0.0.1:{PORT}/omarock.ogg", "storefront": "us"})
        if self.server.token and self.headers.get("Authorization") != "Bearer " + self.server.token:
            return self.reply(401, {"error": "Wrong or missing token"})
        if bridge.slowpages and method == "GET" and parts[1:2] in (["albums"], ["artists"]):
            time.sleep(1)
        if bridge.slowsearch and method == "GET" and parts[1:2] == ["search"]:
            time.sleep(bridge.slowsearch)
        try:
            return self.reply(200, self.route(bridge, method, parts[1:], query, body))
        except NoEndpoint:
            return self.reply(404, {"error": "No such endpoint."})
        except Refused as e:
            return self.reply(409, {"error": str(e)})
        except KeyError as e:
            return self.reply(404, {"error": f"No such item {e}"})
        except (ValueError, IndexError) as e:
            return self.reply(400, {"error": str(e)})

    def route(self, b, method, parts, query, body):
        path = "/".join(parts)
        client = self.headers.get("X-Omarock-Client", "")
        if method == "GET" and path == "status":
            with b.lock:
                since = query.get("since")
                deadline = time.monotonic() + 25
                while since is not None and int(since) == b.seq and time.monotonic() < deadline:
                    b.lock.wait(deadline - time.monotonic())
                return b.status(client)
        # A Mac slow to load what it's asked to play, as it is with a hundred
        # songs (POST /v1/fake/slow {on}): the reply waits, the rest doesn't.
        if method == "POST" and path == "play" and b.slow:
            time.sleep(3)
        with b.lock:
            if method == "POST":
                if path == "fake/elsewhere":
                    b.owner, b.away = body["name"], True
                    if b.queue and b.state != "playing":
                        b.base, b.started, b.state = b.position(), time.monotonic(), "playing"
                    b.changed()
                    return {"ok": True}
                if b.elsewhere(client):
                    if path in ("pause", "next", "previous", "seek"):
                        b.refused += 1
                        raise Refused(f"{'Spotify' if b.spotify else 'Apple Music'} is playing on {b.owner}: Play moves it here")
                    if path == "toggle": path = "resume"
                if client and (path in ("resume", "queue/jump", "activate") or path == "play" and body.get("mode", "play") == "play"):
                    if b.away or b.owner != client:
                        b.owner, b.away = client, False
                        b.changed()
                if path == "fake/info":
                    b.info_route = bool(body["on"])
                    return {"ok": True}
                if path == "fake/volume":
                    b.volume = 40 if body["on"] else None
                    b.changed()
                    return b.status(client)
                if path == "fake/signin":
                    b.signed_in = body["on"]
                    return {"ok": True}
                if path == "logout" and b.spotify:
                    b.signed_in = False
                    return {"ok": True}
                if path == "volume":
                    if b.volume is None:
                        raise Refused("omarock's sound output sets the volume, not Spotify")
                    b.volume = max(0, min(100, int(round(float(body["volume"])))))
                    b.changed()
                    return b.status(client)
                if path == "fake/library":
                    # And forget what was added or taken out.
                    b.library_route = bool(body["on"])
                    b.saved, b.unsaved = set(), set()
                    b.changed()
                    return {"ok": True}
                if path in ("library/add", "library/remove"):
                    if not b.library_route or (path == "library/remove" and not b.spotify): raise NoEndpoint()
                    kinds = ("song", "album") if b.spotify else ("song", "album", "playlist")
                    added = 0
                    for item in body["items"]:
                        if item["kind"] not in kinds: raise ValueError("can't add a " + item["kind"])
                        # Apple Music's bridge adds catalog items only, and counts them.
                        if not b.spotify and path == "library/add" and item.get("source") == "library": continue
                        key = (item["kind"], item["id"][2:] if item["id"].startswith("l-") else item["id"])
                        (b.saved if path == "library/add" else b.unsaved).add(key)
                        (b.unsaved if path == "library/add" else b.saved).discard(key)
                        added += 1
                    b.changed()
                    return {"ok": True} if b.spotify else {"ok": True, "added": added}
                if path == "fake/slowsearch":
                    b.slowsearch = float(body.get("seconds", 0.5)) if body["on"] else 0
                    return {"ok": True}
                if path in ("fake/bare", "fake/orphan", "fake/slow", "fake/slowpages"):
                    setattr(b, path[5:], bool(body["on"]))
                    b.changed()
                    return {"ok": True}
                if b.spotify and path == "activate":
                    b.current = True
                    if b.queue and b.state != "playing":
                        b.base, b.started, b.state = b.position(), time.monotonic(), "playing"
                    else:
                        threading.Thread(target=b.stop_mpd, daemon=True).start()
                    b.changed()
                    return b.status(client)
                if b.spotify and path == "release":
                    if b.state == "playing":
                        b.base, b.started, b.state = b.position(), time.monotonic(), "paused"
                    b.current = False
                    b.changed()
                    return b.status(client)
                if b.spotify and path == "queue/remove":
                    raise Refused("Spotify can't take songs out of its queue")
                if path == "play":
                    songs = b.expand(body["items"])
                    mode = body.get("mode", "play")
                    if mode == "play":
                        b.queue = songs
                        b.play_at(min(body.get("start", 0), len(songs) - 1))
                    elif mode == "next":
                        b.queue[b.index + 1:b.index + 1] = songs
                        b.changed()
                    else:
                        b.queue = b.queue + songs
                        b.changed()
                    return b.status(client)
                if path in ("pause", "resume", "toggle"):
                    want = {"pause": "paused", "resume": "playing"}.get(path) or ("paused" if b.state == "playing" else "playing")
                    if b.queue and want != b.state:
                        b.base, b.started, b.state = b.position(), time.monotonic(), want
                        b.changed()
                    return b.status(client)
                if path in ("next", "previous"):
                    b.play_at(max(0, min(len(b.queue) - 1, b.index + (1 if path == "next" else -1))))
                    return b.status(client)
                if path == "seek":
                    b.base, b.started = float(body["position"]), time.monotonic()
                    return b.status(client)
                if path == "queue/jump":
                    b.play_at(int(body["index"]))
                    return b.status(client)
                if path == "queue/remove":
                    i = int(body["index"])
                    del b.queue[i]
                    if i < b.index: b.index -= 1
                    b.changed()
                    return b.status(client)
                if path == "shuffle":
                    b.shuffle = bool(body["on"])
                    b.changed()
                    return b.status(client)
                if path == "repeat":
                    b.repeat = body["mode"]
                    b.changed()
                    return b.status(client)
                if path == "library/playlists":
                    pid = f"p-{len(b.playlists) + 1}"
                    b.playlists[pid] = {"kind": "playlist", "id": pid, "source": "library", "name": body["name"],
                                        "curator": "You", "canEdit": True, "lastModified": "2026-10-19T16:00:00Z",
                                        "songs": [s["id"] for s in b.expand(body.get("items", []))]}
                    return b.playlist("library", pid)[0]
                if len(parts) == 4 and parts[:2] == ["library", "playlists"] and parts[3] == "tracks":
                    p = b.playlists[parts[2]]
                    p["songs"] += [s["id"] for s in b.expand(body["items"])]
                    p["lastModified"] = "2026-10-19T16:30:00Z"
                    return b.playlist("library", parts[2])[0]
            if method == "GET":
                limit = int(query.get("limit", 8))
                if path == "search": return b.search(query["q"], query.get("scope", "all"), limit)
                if parts[0] == "info":
                    if not b.info_route: raise NoEndpoint()
                    return b.info(parts[1], parts[2], parts[3])
                if parts[0] == "albums":
                    album, tracks = b.album(parts[1], parts[2])
                    if parts[1] == "catalog" and not b.bare:
                        # inLibrary, as bridge 0.4.1 and omarock-spotify 0.2.2 give it.
                        # An album added to Apple Music brings its songs; Spotify
                        # saves the album apart from the songs.
                        whole = not b.spotify and b.owns("album", parts[2])
                        tracks = [dict(t, inLibrary=whole or b.owns("song", t["id"])) for t in tracks]
                        if b.spotify: album = dict(album, inLibrary=b.owns("album", parts[2]))
                    return {"album": album, "tracks": tracks}
                if parts[0] == "artists" and parts[1] == "library":
                    artist = next((a for a in b.library_artists if a["id"] == parts[2]), None)
                    if artist is None: raise KeyError(f"No library artist with id {parts[2]}.")
                    albums = [a for a in b.library_albums if a["artist"] == artist["name"]]
                    top = [dict(SONGS[s], id="l-" + s, source="library") for s in CATALOG_ALBUMS["c-al-1"]["tracks"]]
                    return {"artist": artist, "albums": albums, "topSongs": top, "appearsOn": []}
                if parts[0] == "artists":
                    artist = next(a for a in ARTISTS if a["id"] == parts[2])
                    albums = [public(a) for a in CATALOG_ALBUMS.values() if a["artistId"] == parts[2]]
                    top = [s for s in SONGS.values() if s["artistId"] == parts[2]][:5]
                    return {"artist": artist, "albums": albums, "topSongs": top, "appearsOn": []}
                if parts[0] == "playlists":
                    return b.playlist_view(parts[1], parts[2])
                if path == "library/playlists":
                    return sorted((b.playlist("library", p)[0] for p in b.playlists), key=lambda p: p["name"].lower())
                if path == "genres": return [] if b.spotify else GENRES
                if parts[0] == "genres":
                    if b.spotify: raise KeyError("Spotify has no genre charts")
                    genre = next(g for g in GENRES if g["id"] == parts[1])
                    return {"genre": genre, "albums": [public(CATALOG_ALBUMS["c-al-2"]), public(CATALOG_ALBUMS["c-al-3"])],
                            "songs": [SONGS["c-so-5"], SONGS["c-so-8"]]}
        raise KeyError(path)

    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")


def main():
    global PORT, SONGS, CATALOG_ALBUMS
    port_file, token, log = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    mpd_socket = sys.argv[sys.argv.index("--spotify") + 1] if "--spotify" in sys.argv else None
    # FAKE_BRIDGE_PORT: a fixed port (the installer's test expects the real one, 8710).
    server = ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("FAKE_BRIDGE_PORT", "0"))), Handler)
    server.daemon_threads = True
    PORT = server.server_address[1]
    SONGS, CATALOG_ALBUMS = make_catalog()
    server.token = token
    server.bridge = Bridge(log.open("a"), mpd_socket)
    if mpd_socket:
        threading.Thread(target=server.bridge.watch_mpd, daemon=True).start()
    port_file.write_text(str(PORT))
    print("fake spotify ready" if mpd_socket else "fake bridge ready", flush=True)
    server.serve_forever()


if __name__ == "__main__": main()
