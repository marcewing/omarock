#!/usr/bin/env python3
"""omarock-spotify: Spotify for omarock, speaking the Apple Music bridge's API.

Spotify's Soloist (omarock-soloist.service) plays, into omarock's PipeWire bus.
This service drives it over Soloist's local WebSocket API, and uses the Spotify
Web API (your own developer app: spotify_web.py) for what Soloist can't do:
search, browsing, the library, playlists, and starting an album or playlist at
a given song. It answers omarock (and tools/omarock-sp) on 127.0.0.1:8730 with
the JSON of bridge/API.md, so omarock's Apple Music code serves Spotify too.

Also:
- Soloist's own volume stays at 100: the bus's volume is omarock's one volume.
- One player at a time: mpd starting to play pauses Spotify; Spotify starting
  to play pauses mpd (stops it on a stream, which is live).
- Spotify is omarock's current source ("current" in the status) from when it
  starts playing, or omarock switches to it (POST /v1/activate), until mpd
  plays or omarock switches away (POST /v1/release). So the mode lives here,
  as Apple Music's lives in mpd's queue, and omarock-sp shows it.
- The media keys: Spotify is an MPRIS player too (spotify_mpris.py), so
  `omarchy-shell media` can pause it, skip and so on. From when mpd plays
  until Spotify plays again, it offers nothing, so the keys act on mpd.
- Spotify's sign-in ends after 6 months: GET /v1/login gives the page to open,
  and /callback takes Spotify's answer (this port is the app's redirect URI).

    omarock-spotify.py [--port 8730]
"""
import json
import os
import re
import socket
import sys
import threading
import time
import unicodedata
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import soloist_ws  # noqa: E402
import spotify_web  # noqa: E402

VERSION = "0.2.0"
SOLOIST_PORT = 8731
SOLOIST_DATA = Path.home() / ".local/share/omarock-soloist"
MPD_SOCKET = Path(os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000")) / "mpd/socket"
SIGN_IN_DAYS = 182


def log(message):
    print("omarock-spotify: " + message, file=sys.stderr, flush=True)


# ---------- Spotify's objects, as bridge/API.md's ----------

def fold(text):
    s = unicodedata.normalize("NFD", str(text or "").lower())
    return re.sub(r"\s+", " ", "".join(c for c in s if not unicodedata.combining(c))).strip()


def artwork(images):
    """The largest image, as the bridge's artwork (a plain URL: no {w} {h})."""
    images = [i for i in (images or []) if i and i.get("url")]
    if not images:
        return None
    best = max(images, key=lambda i: i.get("width") or 0)
    out = {"url": best["url"]}
    if best.get("width"): out["width"] = best["width"]
    if best.get("height"): out["height"] = best["height"]
    return out


def year_and_date(release_date):
    out = {}
    if release_date and release_date[:4].isdigit():
        out["year"] = int(release_date[:4])
        if len(release_date) == 10:
            out["releaseDate"] = release_date
    return out


def names(artists):
    return ", ".join(a["name"] for a in (artists or []) if a and a.get("name"))


def clean(obj):
    """Fields Spotify doesn't give are left out, not null (bridge/API.md)."""
    return {k: v for k, v in obj.items() if v is not None and v != "" and v != []}


def song(track, source="catalog", album=None):
    album = album or track.get("album") or {}
    artists = track.get("artists") or []
    out = {"kind": "song", "id": track["id"], "source": source, "catalogId": track["id"],
           "title": track.get("name", ""), "artist": names(artists),
           "artistId": artists[0]["id"] if artists and artists[0].get("id") else None,
           "album": album.get("name"), "albumId": album.get("id"),
           "duration": track["duration_ms"] / 1000 if track.get("duration_ms") else None,
           "trackNumber": track.get("track_number"), "discNumber": track.get("disc_number"),
           "explicit": bool(track.get("explicit")), "isrc": (track.get("external_ids") or {}).get("isrc"),
           "artwork": artwork(album.get("images")), "playable": track.get("is_playable", True) is not False}
    out.update(year_and_date(album.get("release_date")))
    return clean(out)


def album_obj(album, source="catalog"):
    artists = album.get("artists") or []
    copyrights = album.get("copyrights") or []
    out = {"kind": "album", "id": album["id"], "source": source, "catalogId": album["id"],
           "title": album.get("name", ""), "artist": names(artists),
           "artistId": artists[0]["id"] if artists and artists[0].get("id") else None,
           "genres": album.get("genres") or None, "trackCount": album.get("total_tracks"),
           "recordLabel": album.get("label"), "copyright": copyrights[0]["text"] if copyrights else None,
           "isCompilation": album.get("album_type") == "compilation", "isSingle": album.get("album_type") == "single",
           "artwork": artwork(album.get("images"))}
    out.update(year_and_date(album.get("release_date")))
    return clean(out)


def artist_obj(artist, source="catalog"):
    return clean({"kind": "artist", "id": artist["id"], "source": source, "name": artist.get("name", ""),
                  "genres": artist.get("genres") or None, "artwork": artwork(artist.get("images"))})


def playlist_obj(playlist, me=""):
    owner = playlist.get("owner") or {}
    mine = owner.get("id") == me
    items = playlist.get("items") or playlist.get("tracks") or {}
    return clean({"kind": "playlist", "id": playlist["id"], "source": "library" if mine else "catalog",
                  "name": playlist.get("name", ""), "curator": owner.get("display_name"),
                  "description": re.sub(r"<[^>]+>", "", playlist.get("description") or "") or None,
                  "trackCount": items.get("total"), "canEdit": mine or bool(playlist.get("collaborative")),
                  "artwork": artwork(playlist.get("images"))})


def uri_id(uri):
    return (uri or "").rsplit(":", 1)[-1]


def song_from_entity(entity):
    """A song from Soloist's entity, before the Web API fills in the rest."""
    d = (entity or {}).get("decorations") or {}
    parent = ((d.get("parent") or {}).get("entity") or {})
    covers = ((d.get("visual_identity") or {}).get("cover")) or []
    sizes = {"small": 64, "default": 300, "large": 640, "xlarge": 1000}
    images = [{"url": c["url"], "width": sizes.get(c.get("size"), 0)} for c in covers if c.get("url")]
    creators = [((c.get("decorations") or {}).get("identity") or {}).get("name") for c in d.get("creators") or []]
    duration = (d.get("playback") or {}).get("duration_ms")
    tid = uri_id(entity.get("uri"))
    return clean({"kind": "song", "id": tid, "source": "catalog", "catalogId": tid,
                  "title": (d.get("identity") or {}).get("name", ""),
                  "artist": ", ".join(c for c in creators if c),
                  "album": ((parent.get("decorations") or {}).get("identity") or {}).get("name"),
                  "albumId": uri_id(parent.get("uri")) if parent.get("uri") else None,
                  "duration": duration / 1000 if duration else None, "artwork": artwork(images), "playable": True})


# ---------- Soloist: its state, and commands to it ----------

class Soloist:
    def __init__(self):
        self.cond = threading.Condition()
        self.send_lock = threading.Lock()
        self.ws = None
        self.seq = 1
        self.connected = False
        self.logged_in = False
        self.active = False
        self.status = "idle"
        self.item = None
        self.context = None
        self.position = {"position_ms": 0, "timestamp_ms": 0, "speed": 0}
        self.volume = 100
        self.options = {}
        self.previous = []
        self.upcoming = []
        self.tracks = {}          # id -> song, filled in from the Web API
        self.wanted = []          # ids to fill in
        self.full_queue_at = 0.0
        self.on_playing = None    # called when Spotify starts playing
        # Spotify isn't omarock's current source: mpd played since Spotify
        # did, or omarock switched away (POST /v1/release). The media keys
        # are mpd's meanwhile (spotify_mpris.py shows nothing to act on).
        self.yielded = True

    def changed(self):
        with self.cond:
            self.seq += 1
            self.cond.notify_all()

    def command(self, name, **args):
        with self.send_lock:
            if not self.ws:
                raise RuntimeError("Spotify's Soloist isn't running (systemctl --user status omarock-soloist)")
            self.ws.command(name, **args)

    def wait(self, since, test=None, timeout=3.0):
        """Wait for a change after seq since (and test(), if given)."""
        deadline = time.monotonic() + timeout
        with self.cond:
            while time.monotonic() < deadline:
                if self.seq != since and (test is None or test()):
                    return True
                self.cond.wait(deadline - time.monotonic())
        return False

    def run(self):
        while True:
            try:
                ws = soloist_ws.WebSocket(port=SOLOIST_PORT)
            except (OSError, soloist_ws.Closed):
                time.sleep(3)
                continue
            with self.send_lock:
                self.ws = ws
            self.connected = True
            log("connected to Soloist")
            try:
                ws.command("get_auth_state")
                ws.command("get_state")
                ws.command("get_queue", limit=0)
                while True:
                    self.handle(ws.recv())
            except (OSError, soloist_ws.Closed, ValueError) as e:
                log(f"lost Soloist ({e}); reconnecting")
            with self.send_lock:
                self.ws = None
            self.connected = False
            self.changed()
            time.sleep(2)

    def want(self, entity):
        tid = uri_id((entity or {}).get("uri"))
        if (entity or {}).get("entity_type") == "track" and tid and tid not in self.tracks and tid not in self.wanted:
            self.wanted.append(tid)

    def handle(self, m):
        t = m.get("type")
        was_playing = self.status == "playing"
        if t == "auth_state":
            self.logged_in, self.active = bool(m.get("logged_in")), bool(m.get("is_active"))
        elif t == "playback_state":
            self.status = m.get("status", self.status)
            self.item, self.context = m.get("item"), m.get("context")
            self.position = m.get("position") or self.position
            self.volume = m.get("volume", self.volume)
            self.active = bool(m.get("is_active", self.active))
            self.options = m.get("options") or self.options
            self.want(self.item)
        elif t == "track_changed":
            self.item = m.get("item")
            self.want(self.item)
            self.full_queue()
        elif t == "playback_changed":
            self.status = m.get("status", self.status)
        elif t == "volume_changed":
            self.volume = m.get("volume", self.volume)
            if self.volume != 100:
                # The bus's volume is the volume; Soloist's stays at full.
                log(f"Soloist's volume went to {self.volume}; back to 100")
                threading.Thread(target=lambda: self.safe("set_volume", volume=100), daemon=True).start()
            return
        elif t == "device_changed":
            self.active = bool(m.get("is_active", self.active))
        elif t == "context_changed":
            self.context = m.get("context")
        elif t == "options_changed":
            self.options = m.get("options") or self.options
        elif t == "position_sync":
            old = self.position_now()
            self.position = m.get("position") or self.position
            if abs(self.position_now() - old) < 2:
                return  # it only kept time: no change to report
        elif t == "queue_changed":
            self.previous, self.upcoming = m.get("previous") or [], m.get("upcoming") or []
            for e in self.previous + self.upcoming:
                self.want(e.get("item"))
            if len(self.upcoming) >= 10:
                self.full_queue()  # broadcasts carry 10; ask for all
        elif t == "error":
            log("Soloist: " + str(m.get("message")))
            return
        else:
            return
        # Only a start counts: a late report of playing, after a release has
        # paused it, mustn't make Spotify current again.
        if self.status == "playing" and not was_playing:
            self.yielded = False
        self.changed()
        if self.status == "playing" and not was_playing and self.on_playing:
            threading.Thread(target=self.on_playing, daemon=True).start()

    def safe(self, name, **args):
        try: self.command(name, **args)
        except RuntimeError as e: log(str(e))

    def full_queue(self):
        if time.monotonic() - self.full_queue_at > 2:
            self.full_queue_at = time.monotonic()
            threading.Thread(target=lambda: self.safe("get_queue", limit=0), daemon=True).start()

    def position_now(self):
        p = self.position
        ms = p.get("position_ms", 0)
        if p.get("speed") and p.get("timestamp_ms"):
            ms += (time.time() * 1000 - p["timestamp_ms"]) * p["speed"]
        return max(0.0, ms / 1000)

    def song_for(self, entity):
        if not entity:
            return None
        tid = uri_id(entity.get("uri"))
        return self.tracks.get(tid) or song_from_entity(entity)

    def status_json(self):
        state = {"playing": "playing", "buffering": "playing", "paused": "paused"}.get(self.status, "stopped")
        if not self.item:
            state = "stopped"
        current = self.song_for(self.item)
        queue = [self.song_for(e.get("item")) for e in reversed(self.previous)]
        index = len(queue)
        queue.append(current) if current else None
        queue += [self.song_for(e.get("item")) for e in self.upcoming]
        queue = [q for q in queue if q]
        repeat = (self.options or {}).get("repeat", "off")
        out = {"seq": self.seq, "state": state, "current": not self.yielded, "position": round(self.position_now(), 2), "positionAt": time.time(),
               "queue": queue, "queueIndex": index if current else 0, "queueOffset": 0, "queueLength": len(queue),
               "shuffle": bool((self.options or {}).get("shuffle")),
               "repeat": {"context": "all", "track": "one"}.get(repeat, "off")}
        if current and state != "stopped":
            out["song"] = current
        return out

    def enrich_forever(self):
        """Artist names, album ids, track numbers: Soloist's events leave them out."""
        while True:
            if not self.wanted:
                time.sleep(0.5)
                continue
            tid = self.wanted.pop(0)
            try:
                status, data = spotify_web.call("GET", f"/tracks/{tid}")
                if status == 200 and isinstance(data, dict):
                    self.tracks[tid] = song(data)
                    self.changed()
            except (spotify_web.NotSignedIn, spotify_web.ApiError, OSError) as e:
                log(f"couldn't fill in track {tid}: {e}")
                time.sleep(5)


# ---------- mpd: one player at a time ----------

def mpd_command(lines):
    """Send commands to mpd on a short connection; returns the reply lines."""
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(5)
        s.connect(str(MPD_SOCKET))
        f = s.makefile("rwb")
        f.readline()
        out = []
        for line in lines:
            f.write(line.encode() + b"\n")
            f.flush()
            while True:
                reply = f.readline().decode().rstrip("\n")
                if reply == "OK" or reply.startswith("ACK") or not reply:
                    break
                out.append(reply)
        return out


def mpd_state():
    reply = mpd_command(["status", "currentsong"])
    fields = dict(l.split(": ", 1) for l in reply if ": " in l)
    return fields.get("state", ""), fields.get("file", "")


def pause_mpd(quiet=False):
    """Spotify started: mpd stops playing (a stream stops, as it's live)."""
    try:
        state, file = mpd_state()
        if state == "play":
            mpd_command(["stop" if "://" in file else "pause 1"])
            if not quiet:
                log("Spotify started playing: " + ("stopped" if "://" in file else "paused") + " mpd")
    except OSError as e:
        log(f"couldn't reach mpd: {e}")


def mpd_changed(soloist, last, state):
    """mpd's state went from last (None: just connected) to state."""
    if state != "play" or last == "play":
        return
    if not soloist.yielded:
        soloist.yielded = True
        soloist.changed()
    if last is not None and soloist.status in ("playing", "buffering"):
        log("mpd started playing: pausing Spotify")
        soloist.safe("pause")


def watch_mpd(soloist):
    """mpd started: Spotify pauses."""
    while True:
        try:
            with socket.socket(socket.AF_UNIX) as s:
                s.connect(str(MPD_SOCKET))
                f = s.makefile("rwb")
                f.readline()
                last = None
                while True:
                    f.write(b"status\n"); f.flush()
                    state = ""
                    while True:
                        line = f.readline().decode().rstrip("\n")
                        if not line or line == "OK" or line.startswith("ACK"):
                            break
                        if line.startswith("state: "):
                            state = line[7:]
                    mpd_changed(soloist, last, state)
                    last = state
                    f.write(b"idle player\n"); f.flush()
                    while True:
                        line = f.readline().decode().rstrip("\n")
                        if not line:
                            raise OSError("mpd closed the connection")
                        if line == "OK":
                            break
        except OSError:
            time.sleep(3)


# ---------- the Web API side ----------

class Web:
    def __init__(self):
        self.lock = threading.Lock()
        self.me = None
        self.library = None
        self.library_at = 0.0
        self.pending_login = None

    def get(self, path):
        status, data = spotify_web.call("GET", path)
        if status == 404:
            raise LookupError(f"Spotify has no {path}")
        if status >= 400:
            raise ApiError(status, data)
        return data

    def pages(self, path, limit=50, most=500):
        """Every item of a paged list, up to most."""
        items = []
        url = path + ("&" if "?" in path else "?") + f"limit={limit}"
        while url and len(items) < most:
            data = self.get(url)
            items += [i for i in data.get("items") or [] if i]
            url = data.get("next")
        return items

    def me_id(self):
        if self.me is None:
            self.me = self.get("/me")
        return self.me.get("id", "")

    def country(self):
        self.me_id()
        return self.me.get("country", "")

    def library_items(self, refresh=False):
        """Your library: liked songs, saved albums, followed artists, playlists (10 minutes)."""
        with self.lock:
            if self.library is None or refresh or time.monotonic() - self.library_at > 600:
                me = self.me_id()

                def part(name, read):
                    # Spotify is replacing these list endpoints (2026): one
                    # that goes leaves its part empty, not the whole library.
                    try:
                        return read()
                    except (ApiError, LookupError) as e:
                        log(f"your Spotify {name}: {e}")
                        return []
                self.library = {
                    "songs": part("liked songs", lambda: [dict(song(i["track"], "library"), added=i.get("added_at"))
                                                          for i in self.pages("/me/tracks", most=1000) if i.get("track")]),
                    "albums": part("albums", lambda: [dict(album_obj(i["album"], "library"), added=i.get("added_at"))
                                                      for i in self.pages("/me/albums", most=500) if i.get("album")]),
                    "artists": part("artists", lambda: [artist_obj(a, "library") for a in self.followed_artists()]),
                    "playlists": part("playlists", lambda: [playlist_obj(p, me) for p in self.pages("/me/playlists", most=200)]),
                }
                self.library_at = time.monotonic()
            return self.library

    def followed_artists(self):
        items, url = [], "/me/following?type=artist&limit=50"
        while url and len(items) < 500:
            data = self.get(url).get("artists") or {}
            items += [a for a in data.get("items") or [] if a]
            url = data.get("next")
        return items

    def search(self, query, scope, limit):
        out = {}
        if scope in ("all", "library"):
            q = fold(query)
            lib = self.library_items()
            def hits(items, *keys):
                found = [i for i in items if any(q in fold(i.get(k)) for k in keys)]
                found.sort(key=lambda i: (not fold(i.get(keys[0])).startswith(q), fold(i.get(keys[0]))))
                return found[:limit]
            out["library"] = {"songs": hits(lib["songs"], "title", "artist", "album"),
                              "albums": hits(lib["albums"], "title", "artist"),
                              "artists": hits(lib["artists"], "name"),
                              "playlists": hits(lib["playlists"], "name")}
        if scope in ("all", "catalog"):
            try:
                n = max(1, min(int(limit), 10))
                data = self.get("/search?" + urllib.parse.urlencode(
                    {"q": query, "type": "track,album,artist,playlist", "limit": n, "market": "from_token"}))
                me = self.me_id()
                out["catalog"] = {
                    "songs": [song(t) for t in (data.get("tracks") or {}).get("items") or [] if t],
                    "albums": [album_obj(a) for a in (data.get("albums") or {}).get("items") or [] if a],
                    "artists": [artist_obj(a) for a in (data.get("artists") or {}).get("items") or [] if a],
                    "playlists": [playlist_obj(p, me) for p in (data.get("playlists") or {}).get("items") or [] if p]}
            except (ApiError, LookupError) as e:
                out["catalog"] = {"songs": [], "albums": [], "artists": [], "playlists": []}
                out["catalogError"] = str(e)
        return out

    def album(self, aid, source="catalog"):
        data = self.get(f"/albums/{aid}?market=from_token")
        tracks = [song(t, source, album=data) for t in (data.get("tracks") or {}).get("items") or [] if t]
        nxt = (data.get("tracks") or {}).get("next")
        while nxt:
            page = self.get(nxt)
            tracks += [song(t, source, album=data) for t in page.get("items") or [] if t]
            nxt = page.get("next")
        return {"album": album_obj(data, source), "tracks": tracks}

    def artist(self, aid, source="catalog"):
        artist = self.get(f"/artists/{aid}")
        # An artist's albums come 10 at a time now (larger pages answer 400).
        albums = self.pages(f"/artists/{aid}/albums?include_groups=album,single,compilation&market=from_token", limit=10, most=100)
        seen, own = set(), []
        for a in albums:
            key = (fold(a.get("name")), a.get("album_type"))
            if key not in seen:
                seen.add(key)
                own.append(album_obj(a))
        appears = self.pages(f"/artists/{aid}/albums?include_groups=appears_on&market=from_token", limit=10, most=20)
        # Spotify took away artist top tracks (2026): a search by artist stands in.
        found = self.get("/search?" + urllib.parse.urlencode(
            {"q": f'artist:"{artist.get("name", "")}"', "type": "track", "limit": 10, "market": "from_token"}))
        top = [song(t) for t in (found.get("tracks") or {}).get("items") or []
               if t and any(a.get("id") == aid for a in t.get("artists") or [])]
        return {"artist": artist_obj(artist, source), "albums": own,
                "appearsOn": [album_obj(a) for a in appears], "topSongs": top}

    def playlist(self, pid):
        data = self.get(f"/playlists/{pid}?market=from_token")
        obj = playlist_obj(data, self.me_id())
        if "items" not in data or not isinstance(data.get("items"), dict) or not data["items"].get("href"):
            # Spotify lists the songs of your own (or collaborative) playlists only.
            return {"playlist": obj, "tracks": [], "note": "Spotify lists the songs of your own playlists only. It can still play this one."}
        tracks = []
        for entry in self.pages(f"/playlists/{pid}/items?market=from_token", most=1000):
            t = entry.get("item") or entry.get("track")
            if t and t.get("type") == "track" and t.get("id"):
                tracks.append(song(t))
        return {"playlist": obj, "tracks": tracks}

    def expand(self, items, soloist):
        """Items to track URIs, as the bridge expands them to songs."""
        uris = []
        for item in items:
            kind, iid = item.get("kind"), item.get("id", "")
            if kind == "song":
                uris.append("spotify:track:" + iid)
            elif kind == "album":
                uris += ["spotify:track:" + t["id"] for t in self.album(iid)["tracks"] if t.get("playable", True)]
            elif kind == "playlist":
                uris += ["spotify:track:" + t["id"] for t in self.playlist(iid)["tracks"]]
            elif kind == "artist":
                uris += ["spotify:track:" + t["id"] for t in self.artist(iid)["topSongs"]]
            elif kind == "queue":
                uris += ["spotify:track:" + s["id"] for s in soloist.status_json()["queue"]]
            else:
                raise ValueError(f"can't play a {kind}")
        return uris

    def info(self, source, kind, iid):
        if kind == "song":
            data = self.get(f"/tracks/{iid}?market=from_token")
            item, uri = song(data, source), "spotify:track:" + iid
        elif kind == "album":
            data = self.get(f"/albums/{iid}?market=from_token")
            item, uri = album_obj(data, source), "spotify:album:" + iid
        else:
            raise ValueError("kind is song or album.")
        out = {"item": item, "catalog": clean({"id": iid, "url": (data.get("external_urls") or {}).get("spotify")})}
        status, contains = spotify_web.call("GET", "/me/library/contains?" + urllib.parse.urlencode({"uris": uri}))
        if status == 200 and isinstance(contains, list) and contains:
            out["inLibrary"] = bool(contains[0])
        if out.get("inLibrary"):
            lib = self.library_items()
            mine = next((x for x in lib["songs" if kind == "song" else "albums"] if x["id"] == iid), None)
            out["library"] = clean({"id": iid, "added": (mine or {}).get("added")})
        return out


class ApiError(Exception):
    def __init__(self, status, data):
        message = ((data or {}).get("error") or {}).get("message") if isinstance(data, dict) else None
        super().__init__(f"Spotify said {status}" + (f": {message}" if message else ""))
        self.status = status


def device_id():
    try:
        return (SOLOIST_DATA / ".device_id").read_text().strip()
    except OSError:
        return ""


# ---------- the HTTP API ----------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def reply(self, code, data, kind="application/json"):
        body = data if isinstance(data, bytes) else json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass

    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")

    def handle_any(self, method):
        url = urllib.parse.urlparse(self.path)
        query = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        except ValueError:
            return self.reply(400, {"error": "The body isn't JSON."})
        if url.path == "/callback":
            return self.callback(query)
        parts = [urllib.parse.unquote(p) for p in url.path.split("/") if p]
        if parts[:1] != ["v1"]:
            return self.reply(404, {"error": "No such endpoint."})
        try:
            return self.reply(200, self.route(method, parts[1:], query, body))
        except spotify_web.NotSignedIn as e:
            return self.reply(409, {"error": f"Spotify sign-in needed ({e}). Sign in again: omarock-sp login"})
        except LookupError as e:
            return self.reply(404, {"error": str(e)})
        except ValueError as e:
            return self.reply(400, {"error": str(e)})
        except RuntimeError as e:
            return self.reply(409, {"error": str(e)})
        except ApiError as e:
            return self.reply(502, {"error": str(e)})
        except Exception as e:  # noqa: BLE001
            log(f"{method} {url.path}: {e!r}")
            return self.reply(500, {"error": f"omarock-spotify failed: {e}"})

    def callback(self, query):
        pending = WEB.pending_login
        ok = pending and query.get("state") == pending["state"] and query.get("code")
        if ok:
            try:
                spotify_web.finish_login(query["code"], pending)
                WEB.pending_login = None
                WEB.me = None
                log("signed in to Spotify again")
                page = "<h2>omarock is signed in to Spotify.</h2><p>You can close this tab.</p>"
            except (spotify_web.NotSignedIn, spotify_web.ApiError) as e:
                ok, page = False, f"<h2>Spotify sign-in failed</h2><p>{e}</p>"
        else:
            page = f"<h2>Spotify sign-in failed: {query.get('error', 'no sign-in was started here')}</h2>"
        self.reply(200 if ok else 400, page.encode(), "text/html; charset=utf-8")

    def route(self, method, parts, query, body):
        path = "/".join(parts)
        if method == "GET":
            if path == "health":
                return health()
            if path == "status":
                return long_poll(query.get("since"))
            if path == "login":
                url, WEB.pending_login = spotify_web.authorize_url()
                return {"url": url}
            if path == "search":
                return WEB.search(query.get("q", ""), query.get("scope", "all"), int(query.get("limit", 8)))
            if path == "genres":
                return []  # Spotify took away browse categories (2026)
            if parts[:1] == ["genres"]:
                raise LookupError("Spotify has no genre charts for apps any more")
            if len(parts) == 3 and parts[0] == "albums":
                return WEB.album(parts[2], parts[1])
            if len(parts) == 3 and parts[0] == "artists":
                return WEB.artist(parts[2], parts[1])
            if len(parts) == 3 and parts[0] == "playlists":
                return WEB.playlist(parts[2])
            if path == "library/playlists":
                return sorted(WEB.library_items(refresh=True)["playlists"], key=lambda p: fold(p.get("name")))
            if len(parts) == 4 and parts[0] == "info":
                return WEB.info(parts[1], parts[2], parts[3])
        if method == "POST":
            return post(path, parts, body)
        raise LookupError("No such endpoint.")


def health():
    signed = spotify_web.signed_in_at()
    out = {"ok": True, "version": VERSION, "authorized": SOLOIST.logged_in and signed is not None,
           "current": not SOLOIST.yielded,
           "canPlayCatalog": SOLOIST.logged_in, "stream": "", "storefront": "",
           "soloist": {"connected": SOLOIST.connected, "loggedIn": SOLOIST.logged_in, "active": SOLOIST.active},
           "web": {"signedIn": signed is not None}}
    if signed:
        out["web"]["signInEndsAt"] = signed + SIGN_IN_DAYS * 86400
    try:
        out["storefront"] = WEB.country()
    except Exception:  # noqa: BLE001
        pass
    return out


def long_poll(since):
    if since is not None:
        deadline = time.monotonic() + 25
        with SOLOIST.cond:
            while str(SOLOIST.seq) == str(since) and time.monotonic() < deadline:
                SOLOIST.cond.wait(deadline - time.monotonic())
    return SOLOIST.status_json()


def settled(since, test=None, timeout=3.0):
    """The new status, once Soloist has reported the change (the bridge's
    replies are settled too)."""
    SOLOIST.wait(since, test, timeout)
    return SOLOIST.status_json()


def web_play(body):
    dev = device_id()
    if not dev:
        raise RuntimeError("Soloist has no device id yet: is omarock-soloist running?")
    status, data = spotify_web.call("PUT", "/me/player/play?" + urllib.parse.urlencode({"device_id": dev}), body)
    if status >= 400:
        raise ApiError(status, data)


def post(path, parts, body):
    seq = SOLOIST.seq
    if path == "play":
        items, mode, start = body.get("items") or [], body.get("mode", "play"), int(body.get("start", 0))
        if not items:
            raise ValueError("nothing to play")
        if mode == "play":
            if len(items) == 1 and items[0].get("kind") in ("album", "playlist"):
                kind, iid = items[0]["kind"], items[0]["id"]
                web_play({"context_uri": f"spotify:{kind}:{iid}", "offset": {"position": max(0, start)}})
            elif len(items) == 1 and items[0].get("kind") == "artist":
                web_play({"context_uri": "spotify:artist:" + items[0]["id"]})
            else:
                uris = WEB.expand(items, SOLOIST)[:500]
                if not uris:
                    raise ValueError("nothing playable")
                web_play({"uris": uris, "offset": {"position": min(max(0, start), len(uris) - 1)}})
            return settled(seq, lambda: SOLOIST.status == "playing", 6)
        # next and add: Spotify's queue takes songs after what's queued already.
        for uri in WEB.expand(items, SOLOIST)[:100]:
            SOLOIST.command("add_to_queue", uri=uri)
        return settled(seq)
    if path == "activate":
        # omarock switched to Spotify: mpd stops playing, and Spotify carries
        # on with what it had, if anything.
        SOLOIST.yielded = False
        SOLOIST.changed()
        pause_mpd(quiet=True)
        if SOLOIST.item and SOLOIST.status not in ("playing", "buffering") and body.get("resume", True):
            SOLOIST.command("play")
            return settled(seq, lambda: SOLOIST.status == "playing")
        return SOLOIST.status_json()
    if path == "release":
        # omarock switched away: Spotify pauses and stops being the source.
        playing = SOLOIST.status in ("playing", "buffering")
        if playing:
            SOLOIST.command("pause")
        SOLOIST.yielded = True
        SOLOIST.changed()
        return settled(SOLOIST.seq, lambda: SOLOIST.status not in ("playing", "buffering")) if playing else SOLOIST.status_json()
    if path == "pause":
        SOLOIST.command("pause")
        return settled(seq, lambda: SOLOIST.status != "playing")
    if path == "resume":
        if SOLOIST.item:
            SOLOIST.command("play")
            return settled(seq, lambda: SOLOIST.status == "playing")
        return SOLOIST.status_json()
    if path == "toggle":
        return post("pause" if SOLOIST.status == "playing" else "resume", parts, body)
    if path in ("next", "previous"):
        SOLOIST.command("skip_next" if path == "next" else "skip_prev")
        return settled(seq)
    if path == "seek":
        SOLOIST.command("seek", position_ms=int(float(body["position"]) * 1000))
        return settled(seq, timeout=1.5)
    if path == "queue/jump":
        status = SOLOIST.status_json()
        steps = int(body["index"]) - status["queueIndex"]
        for _ in range(abs(steps)):
            SOLOIST.command("skip_next" if steps > 0 else "skip_prev")
            time.sleep(0.15)
        return settled(seq)
    if path == "queue/remove":
        raise RuntimeError("Spotify can't take songs out of its queue")
    if path == "shuffle":
        SOLOIST.command("set_shuffle", enabled=bool(body.get("on")))
        return settled(seq)
    if path == "repeat":
        mode = body.get("mode", "off")
        SOLOIST.command("set_repeat_track", enabled=mode == "one")
        SOLOIST.command("set_repeat_context", enabled=mode == "all")
        return settled(seq)
    if path == "library/playlists":
        status, data = spotify_web.call("POST", "/me/playlists", {"name": body["name"], "public": False})
        if status >= 400:
            raise ApiError(status, data)
        uris = WEB.expand(body.get("items") or [], SOLOIST)
        add_to_playlist(data["id"], uris)
        WEB.library_items(refresh=True)
        return playlist_obj(dict(data, items={"total": len(uris)}), WEB.me_id())
    if len(parts) == 4 and parts[:2] == ["library", "playlists"] and parts[3] == "tracks":
        uris = WEB.expand(body.get("items") or [], SOLOIST)
        add_to_playlist(parts[2], uris)
        WEB.library_items(refresh=True)
        return next((p for p in WEB.library["playlists"] if p["id"] == parts[2]), {"kind": "playlist", "id": parts[2]})
    raise LookupError("No such endpoint.")


def add_to_playlist(pid, uris):
    for i in range(0, len(uris), 100):
        status, data = spotify_web.call("POST", f"/playlists/{pid}/items", {"uris": uris[i:i + 100]})
        if status >= 400:
            raise ApiError(status, data)


SOLOIST = Soloist()
WEB = Web()


def main():
    port = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 8730
    SOLOIST.on_playing = pause_mpd
    threading.Thread(target=SOLOIST.run, daemon=True).start()
    threading.Thread(target=SOLOIST.enrich_forever, daemon=True).start()
    threading.Thread(target=watch_mpd, args=(SOLOIST,), daemon=True).start()
    try:
        import spotify_mpris
        spotify_mpris.start(SOLOIST, log)
    except Exception as e:  # noqa: BLE001 (the API works without the media keys)
        log(f"no MPRIS, so no media keys: {e}")
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    log(f"listening on 127.0.0.1:{port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
