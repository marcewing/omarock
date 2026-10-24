#!/usr/bin/python3
"""A small fake mpd for testing omarock away from the real one.

Serves a made-up library (with accents, covers, compilations and a two-disc
album) on a unix socket, speaks enough of the protocol for the panel (status,
queue, idle, list/search/find/count filters, command lists, listfiles,
config, stored playlists), and logs every command it receives. One stored
playlist, "Late Night", holds a song that has left the library: like mpd,
listplaylistinfo gives only its file line and load skips it. Like the real library's iTunes
compilations, one compilation has no AlbumArtist tag, so mpd's rule applies:
an albumartist filter falls back to the song's artist. Output commands are answered with an error and logged,
so tests can check the panel never sends one.

    fake_mpd.py <socket> <music-dir> <command-log>
"""
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import random
import re
import socketserver
import struct
import sys
import threading
import time
import zlib

SUBSYSTEMS = ["database", "update", "stored_playlist", "playlist", "player", "mixer", "options"]
OUTPUT_COMMANDS = {"enableoutput", "disableoutput", "toggleoutput", "outputset"}

ALBUMS = [
    # albumartist (None: no tag, filed under Compilations), album, year,
    # cover colours (or None), [(title, artist, seconds[, disc])]. Genres are
    # in GENRES.
    ("Glass Harbor", "Low Tide Signals", "2019", ((246, 178, 107), (58, 31, 61)), [
        ("Glasswork", None, 214), ("Paper Lanterns", None, 248), ("Undertow", None, 191),
        ("Salt in the Wiring", None, 263), ("Harbor Lights", None, 305)]),
    ("Glass Harbor", "Paper Satellites", "2021", None, [
        ("Orbit Song", None, 201), ("Static Bloom", None, 233), ("Long Distance", None, 187),
        ("Satellites", None, 276)]),
    ("Flügel Café", "Nachtzug", "1986", ((90, 140, 190), (20, 24, 48)), [
        ("Nachtzug", None, 222), ("Über den Dächern", None, 198), ("Café Noir", None, 240),
        ("Schnee", None, 175)]),
    ("The Quiet Riots", "Basement Tapes", "1983", ((200, 60, 60), (30, 10, 10)), [
        ("Turn It Down", None, 97), ("Basement", None, 132), ("No Future Plans", None, 88),
        ("Riot Quietly", None, 121), ("Last Bus Home", None, 143), ("Feedback Loop", None, 156)]),
    ("Various Artists", "Left Of The Signal", "1988", None, [
        ("Small Hours", "Glass Harbor", 210), ("Fernweh", "Flügel Café", 185),
        ("Static Kids", "The Quiet Riots", 99)]),
    (None, "Signal Hill Sampler", "1990", ((120, 170, 90), (20, 40, 20)), [
        ("Lighthouse", "Glass Harbor", 233), ("Am Hafen", "Flügel Café", 201),
        ("Noise Floor", "The Quiet Riots", 102), ("Dead Air", "The Quiet Riots", 95)]),
    ("The Quiet Riots", "Live at the Basement", "1985", None, [
        ("Intro", None, 45, 1), ("Turn It Down", None, 110, 1), ("Basement", None, 140, 1),
        ("Feedback Loop", None, 170, 2), ("Encore", None, 200, 2)]),
]


GENRES = {"Low Tide Signals": "Indie Pop", "Paper Satellites": "Indie Pop", "Nachtzug": "Electronica/Dance",
          "Basement Tapes": "Alternative & Punk", "Live at the Basement": "Alternative & Punk",
          "Left Of The Signal": "Alternative & Punk", "Signal Hill Sampler": "Alternative & Punk"}
# Stickers, as mpd's sticker database would hold them (sticker list song).
STICKERS = {"Glass Harbor/Low Tide Signals/01 Glasswork.flac": {"rating": "8"}}
LABELS = {"albumartist": "AlbumArtist", "album": "Album", "artist": "Artist", "date": "Date", "genre": "Genre"}


def png(path, top, bottom, size=240):
    """A vertical-gradient PNG, written without any imaging library."""
    rows = bytearray()
    for y in range(size):
        t = y / (size - 1)
        colour = bytes(round(a + (b - a) * t) for a, b in zip(top, bottom))
        rows += b"\x00" + colour * size
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(bytes(rows))) + chunk(b"IEND", b""))


def build_library(music):
    songs = []
    for albumartist, album, year, cover, tracks in ALBUMS:
        top = albumartist or "Compilations"
        folder = music / top / album
        folder.mkdir(parents=True, exist_ok=True)
        if cover: png(folder / "cover.png", *cover)
        track = 0
        for title, artist, seconds, *disc in tracks:
            track = 1 if disc and track and disc[0] != songs[-1].get("disc") else track + 1
            name = (f"{disc[0]}-" if disc else "") + f"{track:02d} {title}.flac"
            (folder / name).touch()
            song = {"file": f"{top}/{album}/{name}", "title": title, "artist": artist or albumartist,
                    "album": album, "date": year, "track": str(track), "duration": float(seconds),
                    "genre": GENRES[album]}
            if albumartist: song["albumartist"] = albumartist
            if disc: song["disc"] = disc[0]
            songs.append(song)
    return songs


def tokenize(line):
    args, i = [], 0
    while i < len(line):
        if line[i].isspace():
            i += 1
        elif line[i] == '"':
            i += 1
            buf = []
            while i < len(line) and line[i] != '"':
                if line[i] == "\\" and i + 1 < len(line): i += 1
                buf.append(line[i])
                i += 1
            args.append("".join(buf))
            i += 1
        else:
            j = i
            while j < len(line) and not line[j].isspace(): j += 1
            args.append(line[i:j])
            i = j
    return args


def split_and(text):
    parts, depth, quoted, start, i = [], 0, False, 0, 0
    while i < len(text):
        c = text[i]
        if quoted:
            if c == "\\": i += 1
            elif c == '"': quoted = False
        elif c == '"': quoted = True
        elif c == "(": depth += 1
        elif c == ")": depth -= 1
        elif depth == 0 and text.startswith(" AND ", i):
            parts.append(text[start:i])
            start = i + 5
            i += 4
        i += 1
    parts.append(text[start:])
    return [p.strip() for p in parts]


def parse_filter(text, ignore_case=False):
    text = text.strip()
    if not (text.startswith("(") and text.endswith(")")): raise ValueError("bad filter " + text)
    inner = text[1:-1].strip()
    if inner.startswith("("):
        preds = [parse_filter(p, ignore_case) for p in split_and(inner)]
        return lambda song: all(p(song) for p in preds)
    base = re.match(r'base\s+"(.*)"$', inner)
    if base:
        folder = base.group(1).rstrip("/")
        return lambda song: folder == "" or song["file"].startswith(folder + "/")
    m = re.match(r'(\w+)\s*(==|!=|=~|!~|contains|starts_with)\s*"(.*)"$', inner, re.S)
    if not m: raise ValueError("bad filter " + inner)
    tag, op, raw = m.group(1).lower(), m.group(2), re.sub(r"\\(.)", r"\1", m.group(3))
    def value(song): return tag_value(song, tag)
    if op in ("=~", "!~"):
        pattern = re.compile(raw, re.I if ignore_case else 0)
        hit = lambda song: bool(pattern.search(value(song)))
        return hit if op == "=~" else (lambda song: not hit(song))
    if op == "starts_with":
        return lambda song: value(song).startswith(raw)
    if op == "contains":
        return lambda song: (raw.lower() in value(song).lower()) if ignore_case else (raw in value(song))
    eq = (lambda song: value(song).lower() == raw.lower()) if ignore_case else (lambda song: value(song) == raw)
    return eq if op == "==" else (lambda song: not eq(song))


def tag_value(song, tag):
    """A tag as mpd's filters see it: albumartist falls back to artist."""
    if tag == "albumartist": return str(song.get("albumartist") or song.get("artist", ""))
    return str(song.get(tag, ""))


def song_lines(song, pos=None, songid=None):
    """Like mpd, only the tags a song has: a stream URL has none."""
    out = [f"file: {song['file']}"]
    for key, label in [("title", "Title"), ("artist", "Artist"), ("albumartist", "AlbumArtist"), ("album", "Album"),
                       ("date", "Date"), ("genre", "Genre"), ("track", "Track"), ("disc", "Disc")]:
        if song.get(key): out.append(f"{label}: {song[key]}")
    if song.get("duration"): out += [f"Time: {round(song['duration'])}", f"duration: {song['duration']:.3f}"]
    if pos is not None: out += [f"Pos: {pos}", f"Id: {songid}"]
    return out


class Fake:
    def __init__(self, music, log):
        self.music = music
        self.log = log
        self.lock = threading.Condition()
        self.songs = build_library(music)
        self.queue = []          # [(id, song)]
        self.next_id = 1
        self.state = "play"
        self.current = 1
        self.elapsed = 69.0
        self.started = time.monotonic()
        self.volume = 72
        self.setvol_delay = 0.0
        # Streams: how long one takes to connect (fake_stream_delay), the
        # ones that refuse (fake_stream_refuse), and mpd's error.
        self.stream_delay = 0.0
        self.refused = []
        self.error = ""
        self.random = False
        self.repeat = True
        self.single = False
        self.events = {}         # connection -> set of pending subsystems
        for s in self.songs[:5] + self.songs[9:13]: self.enqueue(s)
        def file_of(title): return next(s["file"] for s in self.songs if s["title"] == title)
        # Stored playlists: name -> [files], and name -> Last-Modified.
        self.stored = {"Late Night": [file_of("Fernweh"), file_of("Glasswork"), "Gone Away/01 Missing Song.flac",
                                      file_of("Schnee")]}
        self.clock = datetime(2026, 10, 1, 21, 0, tzinfo=timezone.utc)
        self.modified = {"Late Night": self.clock}

    def song_by_file(self, file):
        return next((s for s in self.songs if s["file"] == file), None)

    def touch(self, name):
        """A stored playlist changed: a later Last-Modified, and tell idlers."""
        self.clock += timedelta(minutes=1)
        self.modified[name] = self.clock
        self.changed("stored_playlist")

    def stored_playlist(self, name):
        if name not in self.stored: raise ValueError("No such playlist")
        return self.stored[name]

    def check_name(self, name):
        if not name or "/" in name or "\n" in name: raise ValueError("Bad playlist name")

    def enqueue(self, song):
        self.queue.append((self.next_id, song))
        self.next_id += 1

    def changed(self, *subsystems):
        for pending in self.events.values(): pending.update(subsystems)
        self.lock.notify_all()

    def position(self):
        return self.elapsed + (max(0.0, time.monotonic() - self.started) if self.state == "play" else 0)

    def connecting(self):
        """Like mpd, a stream has no audio format (and no time) until it connects."""
        return self.state == "play" and time.monotonic() < self.started

    def play_index(self, index):
        if not 0 <= index < len(self.queue): return
        file = self.queue[index][1]["file"]
        # Like mpd, playing a stream while something plays holds every client
        # (commands run under the lock) until the stream has connected; after
        # a stop it connects behind.
        holds = "://" in file and self.state == "play"
        if holds: time.sleep(self.stream_delay)
        self.current, self.elapsed, self.started, self.state = index, 0.0, time.monotonic(), "play"
        self.error = ""
        if "://" in file:
            if not holds: self.started += self.stream_delay
            # Like mpd, a station that refuses stops playback, with the reason.
            if any(r in file for r in self.refused):
                self.state = "stop"
                self.error = f'Failed to decode "{file}"; got HTTP status 403'
        self.changed("player")

    def window(self, items, args):
        if "window" in args:
            a, b = args[args.index("window") + 1].split(":")
            return items[int(a):int(b)]
        return items

    def run(self, args):
        """One command; returns reply lines or raises ValueError for an ACK."""
        name, rest = args[0].lower(), args[1:]
        if name in OUTPUT_COMMANDS: raise ValueError("output commands are not allowed")
        if name == "ping": return []
        if name == "config": return [f"music_directory: {self.music}"]
        if name == "stats":
            return [f"artists: {len({s.get('artist', '') for s in self.songs})}",
                    f"albums: {len({s.get('album', '') for s in self.songs})}", f"songs: {len(self.songs)}"]
        if name == "status":
            out = [f"volume: {self.volume}", f"repeat: {int(self.repeat)}", f"random: {int(self.random)}",
                   f"single: {int(self.single)}", "consume: 0", f"playlistlength: {len(self.queue)}", f"state: {self.state}"]
            if self.queue and self.current < len(self.queue):
                qid, song = self.queue[self.current]
                out += [f"song: {self.current}", f"songid: {qid}"]
                if self.state != "stop":
                    out += [f"elapsed: {self.position():.3f}", f"duration: {song['duration']:.3f}"]
                    if not self.connecting(): out.append("audio: 44100:16:2")
            if self.error: out.append(f"error: {self.error}")
            return out
        if name == "currentsong":
            if not self.queue or self.current >= len(self.queue): return []
            qid, song = self.queue[self.current]
            return song_lines(song, self.current, qid)
        if name == "playlistinfo":
            items = list(enumerate(self.queue))
            if rest:
                a, b = (rest[0].split(":") + [""])[:2]
                items = items[int(a):int(b) if b else None]
            return [line for pos, (qid, song) in items for line in song_lines(song, pos, qid)]
        if name == "listfiles":
            folder = self.music / rest[0]
            if not folder.is_dir(): raise ValueError("No such directory")
            out = []
            for p in sorted(folder.iterdir()):
                # The songs are empty files: give them a FLAC's size (900 kbps).
                song = self.song_by_file(str(p.relative_to(self.music)))
                size = round(song["duration"] * 900_000 / 8) if song else p.stat().st_size
                out += [f"file: {p.name}", f"size: {size}", "Last-Modified: 2026-08-05T18:54:34Z"]
            return out
        if name == "lsinfo":
            song = self.song_by_file(rest[0]) if rest else None
            if not song: raise ValueError("No such directory")
            return [f"file: {song['file']}", "Last-Modified: 2026-08-05T18:54:34Z", "Added: 2026-10-18T20:00:00Z",
                    "Format: 44100:16:2"] + song_lines(song)[1:]
        if name == "sticker":
            if rest[:2] != ["list", "song"]: raise ValueError("unsupported sticker command")
            return [f"sticker: {k}={v}" for k, v in STICKERS.get(rest[2], {}).items()]
        if name == "list":
            tag = rest[0].lower()
            pred = parse_filter(rest[1]) if len(rest) > 1 and rest[1].startswith("(") else (lambda s: True)
            matches = [s for s in self.songs if pred(s)]
            # Like mpd, the last group is the outermost: "group date group
            # albumartist" prints an AlbumArtist line, then Date lines under it.
            groups = [rest[i + 1].lower() for i, a in enumerate(rest) if a == "group"][::-1]
            rows = sorted({tuple(tag_value(s, g) for g in groups) + (tag_value(s, tag),) for s in matches})
            out, last = [], None
            for row in rows:
                for depth, g in enumerate(groups):
                    if last is None or row[:depth + 1] != last[:depth + 1]:
                        out.append(f"{LABELS.get(g, g)}: {row[depth]}")
                out.append(f"{LABELS.get(tag, tag)}: {row[-1]}")
                last = row
            return out
        if name == "count":
            pred = parse_filter(rest[0]) if rest and rest[0].startswith("(") else (lambda s: True)
            matches = [s for s in self.songs if pred(s)]
            def totals(songs): return [f"songs: {len(songs)}", f"playtime: {round(sum(s['duration'] for s in songs))}"]
            if "group" not in rest: return totals(matches)
            group = rest[rest.index("group") + 1].lower()
            return [line for value in sorted({tag_value(s, group) for s in matches})
                    for line in [f"{LABELS.get(group, group)}: {value}"]
                    + totals([s for s in matches if tag_value(s, group) == value])]
        if name == "shuffle":
            random.Random(7).shuffle(self.queue)
            self.changed("playlist")
            return []
        if name in ("search", "find"):
            pred = parse_filter(rest[0], ignore_case=(name == "search"))
            return [l for s in self.window([s for s in self.songs if pred(s)], rest) for l in song_lines(s)]
        if name == "findadd":
            pred = parse_filter(rest[0])
            for s in self.window([s for s in self.songs if pred(s)], rest):
                self.enqueue(s)
            self.changed("playlist")
            return []
        if name == "playlistsearch":
            pred = parse_filter(rest[0], ignore_case=True)
            return [line for pos, (qid, song) in enumerate(self.queue) if pred(song)
                    for line in song_lines(song, pos, qid)]
        if name == "addid":
            # A library file, or a URL (the Apple Music bridge's stream).
            song = self.song_by_file(rest[0]) or ({"file": rest[0], "duration": 0.0} if "://" in rest[0] else None)
            if not song: raise ValueError("No such directory")
            entry = (self.next_id, song)
            self.next_id += 1
            # A position, or relative to the current song: "+0" is right after it.
            if len(rest) > 1 and rest[1][:1] in "+-":
                at = self.current + 1 + int(rest[1])
            else:
                at = int(rest[1]) if len(rest) > 1 else len(self.queue)
            self.queue.insert(at, entry)
            if at <= self.current and self.queue and len(self.queue) > 1: self.current += 1
            self.changed("playlist")
            return [f"Id: {entry[0]}"]
        if name == "seekid":
            ids = [qid for qid, _ in self.queue]
            self.play_index(ids.index(int(rest[0])))
            self.elapsed, self.started = float(rest[1]), time.monotonic()
            self.changed("player")
            return []
        if name == "stop":
            self.elapsed, self.state = 0.0, "stop"
            self.changed("player")
            return []
        if name == "add":
            for s in self.songs:
                if s["file"] == rest[0]: self.enqueue(s)
            self.changed("playlist")
            return []
        if name == "clear":
            self.queue, self.current, self.state = [], 0, "stop"
            self.changed("playlist", "player")
            return []
        if name == "play":
            self.play_index(int(rest[0]) if rest else self.current)
            return []
        if name == "playid":
            ids = [qid for qid, _ in self.queue]
            if int(rest[0]) not in ids: raise ValueError("No such song")
            self.play_index(ids.index(int(rest[0])))
            return []
        if name == "pause":
            pause = rest[0] == "1" if rest else self.state == "play"
            if pause and self.state == "play": self.elapsed, self.state = self.position(), "pause"
            elif not pause and self.state == "pause": self.started, self.state = time.monotonic(), "play"
            self.changed("player")
            return []
        if name in ("next", "previous"):
            self.play_index(self.current + (1 if name == "next" else -1))
            return []
        if name == "deleteid":
            ids = [qid for qid, _ in self.queue]
            index = ids.index(int(rest[0]))
            del self.queue[index]
            if index < self.current: self.current -= 1
            # Like mpd, deleting the song playing carries on with the next.
            elif index == self.current and self.state != "stop":
                if self.current < len(self.queue): self.play_index(self.current)
                else: self.current, self.state = 0, "stop"
            self.changed("playlist")
            return []
        if name == "listplaylists":
            return [line for n in self.stored for line in
                    [f"playlist: {n}", f"Last-Modified: {self.modified[n].strftime('%Y-%m-%dT%H:%M:%SZ')}"]]
        if name in ("listplaylist", "listplaylistinfo"):
            files = self.stored_playlist(rest[0])
            if len(rest) > 1:
                a, b = (rest[1].split(":") + [""])[:2]
                files = files[int(a):int(b) if b else None]
            if name == "listplaylist": return [f"file: {f}" for f in files]
            return [line for f in files
                    for line in (song_lines(self.song_by_file(f)) if self.song_by_file(f) else [f"file: {f}"])]
        if name == "playlistlength":
            files = self.stored_playlist(rest[0])
            songs = [self.song_by_file(f) for f in files]
            return [f"songs: {len(files)}", f"playtime: {round(sum(s['duration'] for s in songs if s))}"]
        if name == "playlistadd":
            self.check_name(rest[0])
            # Like mpd, a stream URL can go in a playlist too.
            if not self.song_by_file(rest[1]) and "://" not in rest[1]: raise ValueError("No such directory")
            self.stored.setdefault(rest[0], []).append(rest[1])
            self.touch(rest[0])
            return []
        if name == "searchaddpl":
            self.check_name(rest[0])
            pred = parse_filter(rest[1], ignore_case=True)
            self.stored.setdefault(rest[0], []).extend(s["file"] for s in self.songs if pred(s))
            self.touch(rest[0])
            return []
        if name == "playlistdelete":
            files = self.stored_playlist(rest[0])
            if not 0 <= int(rest[1]) < len(files): raise ValueError("Bad song index")
            del files[int(rest[1])]
            self.touch(rest[0])
            return []
        if name == "rm":
            self.stored_playlist(rest[0])
            del self.stored[rest[0]], self.modified[rest[0]]
            self.changed("stored_playlist")
            return []
        if name == "rename":
            files = self.stored_playlist(rest[0])
            self.check_name(rest[1])
            if rest[1] in self.stored: raise ValueError("Playlist exists already")
            del self.stored[rest[0]], self.modified[rest[0]]
            self.stored[rest[1]] = files
            self.touch(rest[1])
            return []
        if name == "save":
            self.check_name(rest[0])
            mode = rest[1] if len(rest) > 1 else "create"
            if mode == "create" and rest[0] in self.stored: raise ValueError("Playlist already exists")
            if mode == "append": self.stored_playlist(rest[0]).extend(s["file"] for _, s in self.queue)
            else: self.stored[rest[0]] = [s["file"] for _, s in self.queue]
            self.touch(rest[0])
            return []
        if name == "load":
            # Like mpd, songs that have left the library are skipped.
            for f in self.stored_playlist(rest[0]):
                if self.song_by_file(f): self.enqueue(self.song_by_file(f))
            self.changed("playlist")
            return []
        if name == "setvol":
            # A slow mixer, as mpd's is while it plays a live stream: see
            # fake_setvol_delay.
            time.sleep(self.setvol_delay)
            self.volume = max(0, min(100, int(rest[0])))
            self.changed("mixer")
            return []
        if name == "fake_stream_title":
            # Test control, not mpd: the ICY title a stream sends (the current entry).
            if self.queue and self.current < len(self.queue):
                qid, song = self.queue[self.current]
                self.queue[self.current] = (qid, dict(song, title=rest[0]))
                self.changed("player")
            return []
        if name == "fake_stream_delay":
            # Test control, not mpd: streams take this many seconds to connect.
            self.stream_delay = float(rest[0])
            return []
        if name == "fake_stream_refuse":
            # Test control, not mpd: streams whose URL contains this refuse (HTTP 403).
            self.refused.append(rest[0])
            return []
        if name == "fake_setvol_delay":
            # Test control, not mpd: make setvol take this many seconds.
            self.setvol_delay = float(rest[0])
            return []
        if name in ("random", "repeat", "single"):
            setattr(self, name, rest[0] == "1")
            self.changed("options")
            return []
        if name == "seekcur":
            self.elapsed, self.started = float(rest[0]), time.monotonic()
            self.changed("player")
            return []
        raise ValueError("unknown command " + name)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        fake = self.server.fake
        self.wfile.write(b"OK MPD 0.24.0\n")
        batch, list_ok = None, False
        while True:
            raw = self.rfile.readline()
            if not raw: break
            line = raw.decode("utf-8").rstrip("\n")
            with fake.lock:
                fake.log.write(line + "\n")
                fake.log.flush()
            args = tokenize(line)
            if not args: continue
            name = args[0].lower()
            if name == "close": break
            if name in ("command_list_begin", "command_list_ok_begin"):
                batch, list_ok = [], name == "command_list_ok_begin"
                continue
            if batch is not None and name != "command_list_end":
                batch.append(args)
                continue
            if name == "idle":
                self.idle([a for a in args[1:]] or SUBSYSTEMS)
                continue
            commands = batch if name == "command_list_end" else [args]
            batch = None
            reply = []
            with fake.lock:
                try:
                    for cmd in commands:
                        reply += fake.run(cmd)
                        if name == "command_list_end" and list_ok: reply.append("list_OK")
                    reply.append("OK")
                except (ValueError, IndexError) as error:
                    reply.append(f"ACK [2@0] {{{commands[0][0]}}} {error}")
            self.wfile.write(("\n".join(reply) + "\n").encode("utf-8"))

    def finish(self):
        with self.server.fake.lock:
            self.server.fake.events.pop(self, None)
        super().finish()

    def idle(self, wanted):
        fake = self.server.fake
        with fake.lock:
            # Like mpd, a connection's changes are kept from one idle to the
            # next: one that came in between is answered at once. (Starting
            # afresh at each idle lost them, and the panel kept a deleted
            # stream as its current song.)
            pending = fake.events.setdefault(self, set())
            # omarock never sends noidle (it idles on its own connection), so
            # this simply waits for a change.
            while not (pending & set(wanted)):
                fake.lock.wait()
            hits = sorted(pending & set(wanted))
            pending.difference_update(hits)
        self.wfile.write(("".join(f"changed: {s}\n" for s in hits) + "OK\n").encode("utf-8"))


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    path, music, log = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    music.mkdir(parents=True, exist_ok=True)
    server = Server(str(path), Handler)
    server.fake = Fake(music, log.open("a"))
    print("fake mpd ready", flush=True)
    server.serve_forever()


if __name__ == "__main__": main()
