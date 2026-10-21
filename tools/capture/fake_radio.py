#!/usr/bin/python3
"""A fake Radio Browser (radio-browser.info's JSON API), for testing the
panel's radio: a few stations, search by name, tag and state, lookup by uuid,
the click counter, and logos it draws itself. No audio (the fake mpd never
fetches the streams). Every request is logged (path) for the tests.

    fake_radio.py <port-file> <request-log>
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import tempfile
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fake_mpd import png  # noqa: E402

PORT = 0
STATIONS = [
    # uuid, name, state, tags, codec, bitrate, hls, clicks, colour
    ("st-kexp", "KEXP 90.3 FM", "Washington", "indie,alternative", "AAC+", 64, 0, 900, "e0a020"),
    ("st-kuow", "KUOW 94.9", "Washington", "news,public radio", "MP3", 128, 0, 400, "3060c0"),
    ("st-wxpn", "WXPN 88.5", "Pennsylvania", "aaa,rock", "MP3", 128, 0, 700, "c03030"),
    ("st-wjrr", "101.1 WJRR Orlando's Rock Station", "Florida", "rock", "AAC", 0, 0, 300, "202020"),
    ("st-hls", "HLS Only FM", "Washington", "pop", "AAC", 0, 1, 100, "808080"),
] + [
    # Enough local stations for the list to scroll, each listened to less.
    (f"st-w{n}", f"KW{n:02d} 8{n % 10}.{n % 7} FM", "Washington", "community", "MP3", 128, 0, 90 - n, "4a6a4a")
    for n in range(1, 21)
]


def station(row):
    uuid, name, state, tags, codec, bitrate, hls, clicks, colour = row
    return {"stationuuid": uuid, "name": name, "url": f"http://radio.example/{uuid}",
            "url_resolved": f"http://radio.example/{uuid}" + ("/hls.m3u8" if hls else ""),
            "homepage": "", "favicon": f"http://127.0.0.1:{PORT}/logo/{colour}.png", "tags": tags,
            "country": "The United States Of America", "countrycode": "US", "state": state, "codec": codec,
            "bitrate": bitrate, "hls": hls, "lastcheckok": 1, "clickcount": clicks, "votes": clicks // 10}


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

    def do_GET(self):
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        with open(self.server.log_path, "a") as log:
            log.write(json.dumps({"path": url.path, "query": query}) + "\n")
        parts = [p for p in url.path.split("/") if p]
        if parts[:1] == ["logo"]:
            colour = parts[1].split(".")[0]
            top = tuple(int(colour[i:i + 2], 16) for i in (0, 2, 4))
            with tempfile.NamedTemporaryFile(suffix=".png") as f:
                png(Path(f.name), top, tuple(c // 3 for c in top), 128)
                return self.reply(200, Path(f.name).read_bytes(), "image/png")
        all_stations = [station(r) for r in STATIONS]
        if url.path == "/json/stations/search":
            found = all_stations
            if query.get("name"): found = [s for s in found if query["name"].lower() in s["name"].lower()]
            if query.get("tag"): found = [s for s in found if query["tag"].lower() in s["tags"].lower().split(",")]
            if query.get("state"): found = [s for s in found if s["state"] == query["state"]]
            found.sort(key=lambda s: -s["clickcount"])
            return self.reply(200, found[:int(query.get("limit", 100))])
        if url.path == "/json/stations/byuuid":
            wanted = query.get("uuids", "").split(",")
            return self.reply(200, [s for s in all_stations if s["stationuuid"] in wanted])
        if parts[:2] == ["json", "url"]:
            return self.reply(200, {"ok": True, "message": "retrieved station url"})
        return self.reply(404, {"error": "No such route"})


def main():
    global PORT
    port_file, log = Path(sys.argv[1]), Path(sys.argv[2])
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    PORT = server.server_address[1]
    server.log_path = log
    port_file.write_text(str(PORT))
    print("fake radio ready", flush=True)
    server.serve_forever()


if __name__ == "__main__": main()
