#!/usr/bin/python3
"""A fake omarock-sxm service (sxm/README.md), for testing the panel's
SiriusXM mode: a few channels, what's playing on them, favourites, and
artwork it draws itself. It serves no audio (the fake mpd never fetches the
streams). Every request is logged (method, path) for the tests.

    fake_sxm.py <port-file> <request-log>
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fake_mpd import png  # noqa: E402

PORT = 0
CHANNELS = [
    # id, number, name, genre, favourite, colour
    ("ch-2", "2", "SiriusXM Hits 1", "Pop", False, "c0306a"),
    ("ch-8", "8", "80s on 8", "Rock", True, "e0a020"),
    ("ch-20", "20", "E Street Radio", "Rock", True, "4060c0"),
    ("ch-36", "36", "Alt Nation", "Rock", False, "30a060"),
    ("ch-67", "67", "Real Jazz", "Jazz", False, "603090"),
] + [
    # Enough channels for the list to scroll, as a real account's 400-odd do.
    (f"ch-{n}", str(n), f"Deep Cuts {n}", "Rock", False, "506070") for n in range(100, 125)
]
NOW = {"ch-2": ("Noah Kahan", "Orbiter", ""), "ch-8": ("REO Speedwagon", "Take It On The Run", "80s on 8 with Alan Hunter"),
       "ch-20": ("Bruce Springsteen", "Badlands", ""), "ch-36": ("", "", "Alt Nation"), "ch-67": ("Miles Davis", "So What", "")}


class State:
    def __init__(self, log):
        self.log = log
        self.lock = threading.Lock()
        self.favorites = {c[0] for c in CHANNELS if c[4]}


def art(colour):
    return f"http://127.0.0.1:{PORT}/art/{colour}/{{w}}x{{h}}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def reply(self, code, data, kind="application/json"):
        body = data if isinstance(data, bytes) else json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def handle_any(self, method):
        state = self.server.state
        with state.lock:
            state.log.write(json.dumps({"method": method, "path": self.path}) + "\n")
            state.log.flush()
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        if parts[:1] == ["art"]:
            colour, size = parts[1], int(parts[2].split("x")[0])
            top = tuple(int(colour[i:i + 2], 16) for i in (0, 2, 4))
            with tempfile.NamedTemporaryFile(suffix=".png") as f:
                png(Path(f.name), top, tuple(c // 3 for c in top), min(size, 512))
                return self.reply(200, Path(f.name).read_bytes(), "image/png")
        path = "/".join(parts)
        if path == "v1/health":
            return self.reply(200, {"ok": True, "version": "fake", "account": True, "loggedIn": True, "error": "", "playing": []})
        if path == "v1/channels":
            return self.reply(200, [{"id": cid, "number": num, "name": name, "shortName": "", "genre": genre,
                                     "description": "", "logo": art(colour), "stream": f"http://127.0.0.1:{PORT}/stream/{cid}",
                                     "favorite": cid in state.favorites, "available": True}
                                    for cid, num, name, genre, _, colour in CHANNELS])
        if path == "v1/nowplaying":
            return self.reply(200, {cid: {"artist": a, "title": t, "show": show, "isAd": not a and not t,
                                          "startedAt": "2026-10-19T20:00:00Z", "art": art("888888") if a else None}
                                    for cid, (a, t, show) in NOW.items()})
        if parts[:2] == ["v1", "favorites"] and len(parts) == 3:
            with state.lock:
                (state.favorites.add if method == "POST" else state.favorites.discard)(parts[2])
            return self.reply(200, {"ok": True})
        return self.reply(404, {"error": "No such route"})

    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")
    def do_DELETE(self): self.handle_any("DELETE")


def main():
    global PORT
    port_file, log = Path(sys.argv[1]), Path(sys.argv[2])
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    PORT = server.server_address[1]
    server.state = State(log.open("a"))
    port_file.write_text(str(PORT))
    print("fake sxm ready", flush=True)
    server.serve_forever()


if __name__ == "__main__": main()
