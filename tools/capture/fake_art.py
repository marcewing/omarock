#!/usr/bin/python3
"""Cover art for testing tools/omarock-art, good and hostile: the radio fake
serves it under /art/ (station logos and ICY artwork point there), and
tests/test_art.py serves it on a port of its own.

    serve(handler, name)   answer a GET for /art/NAME on handler (an
                           http.server request handler); False if there's none
    NAMES                  every NAME

Run on its own, it serves them on a port it writes to <port-file>:

    fake_art.py <port-file> <request-log>
"""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import struct
import sys
import time
import zlib

# 48 by 48, baseline and progressive (made with ImageMagick).
JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/"
    "2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAAwADADASIAAhEBAxEB/8QAFgAB"
    "AQEAAAAAAAAAAAAAAAAAAAQF/8QAFRABAQAAAAAAAAAAAAAAAAAAABP/xAAXAQEBAQEAAAAAAAAAAAAAAAAABAUG/8QAFhEBAQEAAAAAAAAAAAAAAAAAABIT/9oA"
    "DAMBAAIRAxEAPwDHoUS0KMKXa6KqFEtChJoqoUS0KEmiWhRJQoolFauhRJQoSWroUSUKElpqFElCiiUOiuhRJQoSaK6FElChJo//2Q==")
PROGRESSIVE = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/"
    "2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wgARCAAwADADASIAAhEBAxEB/8QAFwAB"
    "AQEBAAAAAAAAAAAAAAAAAAIDBf/EABgBAQADAQAAAAAAAAAAAAAAAAACAwQF/9oADAMBAAIQAxAAAAHjIdvLaBaBmhRO0C0DNCiVoFoH/8QAFBABAAAAAAAAAAAA"
    "AAAAAAAAUP/aAAgBAQABBQIT/8QAFxEAAwEAAAAAAAAAAAAAAAAAABARIP/aAAgBAwEBPwFwhMf/xAAVEQEBAAAAAAAAAAAAAAAAAAAAEv/aAAgBAgEBPwGlKUpS"
    "lKf/xAAUEAEAAAAAAAAAAAAAAAAAAABQ/9oACAEBAAY/AhP/xAAVEAEBAAAAAAAAAAAAAAAAAAAAEf/aAAgBAQABPyGqqqqqqqqqqqqqqqqqqqqqqqr/2gAMAwEA"
    "AgADAAAAEMssssss88//xAAWEQEBAQAAAAAAAAAAAAAAAAARACD/2gAIAQMBAT8QIjAIi//EABQRAQAAAAAAAAAAAAAAAAAAADD/2gAIAQIBAT8QEAf/xAAUEAEA"
    "AAAAAAAAAAAAAAAAAABQ/9oACAEBAAE/EBP/AP8A/wD/AP8A/9k=")
# 20 by 12, plain and interlaced.
GIF = base64.b64decode("R0lGODlhFAAMAPEAAAk1EhJeJByMNyCgQCH5BAAAAAAALAAAAAAUAAwAAAIgnI+pK33+mpy02juD3rz7D4biSJYhgKaoprbuC8cyUAAAOw==")
GIF_INTERLACED = base64.b64decode(
    "R0lGODlhFAAMAPEAADUJNV4SXqAgoIwcjCH5BAAAAAAALAAAAAAUAAwAQAIilI+Zwe0Po3Sj2ovx3AH4D4ahQg5KhlbBxbWuI3pMTNdiAQA7")

PNG = b"\x89PNG\r\n\x1a\n"


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


def png(size, top, bottom, extra=b""):
    """A vertical-gradient RGB PNG; extra: chunks to put after its header."""
    rows = bytearray()
    for y in range(size):
        t = y / (size - 1)
        rows += b"\x00" + bytes(round(a + (b - a) * t) for a, b in zip(top, bottom)) * size
    return (PNG + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + extra
            + chunk(b"IDAT", zlib.compress(bytes(rows))) + chunk(b"IEND", b""))


def with_exif(jpeg):
    """A JPEG with an Exif segment and a comment, which omarock-art drops."""
    exif = b"Exif\0\0" + b"MM\0*" + bytes(200)
    comment = b"made for omarock's tests"
    return (jpeg[:2] + b"\xff\xe1" + struct.pack(">H", len(exif) + 2) + exif
            + b"\xff\xfe" + struct.pack(">H", len(comment) + 2) + comment + jpeg[2:])


def icon():
    """A Windows icon of one 16 by 16 32-bit bitmap: a red square, its corner clear."""
    size = 16
    pixels = bytearray()
    for y in range(size):  # bottom-up
        for x in range(size):
            pixels += bytes((0, 0, 255, 0 if x < 4 and y >= size - 4 else 255))
    mask = bytes(4 * size)
    dib = struct.pack("<IiiHHIIiiII", 40, size, 2 * size, 1, 32, 0, len(pixels) + len(mask), 0, 0, 0, 0) + pixels + mask
    return struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(dib), 22) + dib


_ztxt = None


def ztxt_png():
    """A good PNG carrying 60 zTXt chunks that would inflate to 7 MiB each."""
    global _ztxt
    if _ztxt is None:
        text = chunk(b"zTXt", b"Comment\0\0" + zlib.compress(bytes(7 * 1024 * 1024), 9))
        _ztxt = png(40, (40, 160, 200), (10, 40, 60), text * 60
                    + chunk(b"iCCP", b"icc\0\0" + zlib.compress(bytes(4096)))
                    + chunk(b"tEXt", b"Title\0made for omarock's tests"))
    return _ztxt


SVG = (b'<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">'
       b'<rect width="64" height="64" fill="#c03030"/></svg>\n')
HUGE = PNG + chunk(b"IHDR", struct.pack(">IIBBBBB", 30000, 30000, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(b"\0" * 1000)) + chunk(b"IEND", b"")
NOT_AN_IMAGE = b"<html><body>Not found, but said to be a PNG</body></html>\n" * 20
BIG = 3 * 1024 * 1024

NAMES = ["good.jpg", "good.png", "progressive.jpg", "ztxt.png", "favicon.ico", "logo.gif", "interlaced.gif",
         "endless.png", "big.png", "big-chunked.png", "logo.svg", "not-an-image.png", "huge.png",
         "loop", "to-file", "to-http", "hops-3", "hops-4", "trickle.png", "webp.png", "pdf.png", "missing.png"]


def serve(handler, name):
    """Answer handler's GET for /art/NAME; False when there's no such NAME."""
    def reply(body, kind="image/png", length=True, status=200, headers=()):
        handler.send_response(status)
        handler.send_header("Content-Type", kind)
        for key, value in headers: handler.send_header(key, value)
        if length: handler.send_header("Content-Length", str(len(body)))
        else: handler.send_header("Connection", "close")
        handler.end_headers()
        try:
            handler.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        if not length: handler.close_connection = True
        return True

    def redirect(to):
        return reply(b"", "text/plain", status=302, headers=[("Location", to)])

    def stream(first, step, every, most):
        """A body with no length: first, then step every so often, up to most bytes."""
        handler.send_response(200)
        handler.send_header("Content-Type", "image/png")
        handler.send_header("Connection", "close")
        handler.end_headers()
        handler.close_connection = True
        sent = 0
        try:
            handler.wfile.write(first)
            while sent < most:
                handler.wfile.write(step)
                handler.wfile.flush()
                sent += len(step)
                time.sleep(every)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        return True

    if name == "good.jpg": return reply(with_exif(JPEG), "image/jpeg")
    if name == "progressive.jpg": return reply(PROGRESSIVE, "image/jpeg")
    if name == "good.png": return reply(png(64, (200, 120, 30), (60, 30, 10), chunk(b"tEXt", b"Title\0fake")))
    if name == "ztxt.png": return reply(ztxt_png())
    if name == "favicon.ico": return reply(icon(), "image/x-icon")
    if name == "logo.gif": return reply(GIF, "image/gif")
    if name == "interlaced.gif": return reply(GIF_INTERLACED, "image/gif")
    # Without end: 256 MiB at about 20 MiB/s, unless the reader stops first.
    if name == "endless.png": return stream(PNG, bytes(65536), .003, 256 * 1024 * 1024)
    if name == "big.png": return reply(PNG + bytes(BIG))
    if name == "big-chunked.png": return reply(PNG + bytes(BIG), length=False)
    if name == "logo.svg": return reply(SVG, "image/svg+xml")
    if name == "not-an-image.png": return reply(NOT_AN_IMAGE)
    if name == "huge.png": return reply(HUGE)
    if name == "loop": return redirect("/art/loop-again")
    if name == "loop-again": return redirect("/art/loop")
    if name == "to-file": return redirect("file:///etc/hostname")
    # The same server by plain http: from https, a step down.
    if name == "to-http": return redirect("http://" + handler.headers.get("Host", "127.0.0.1") + "/art/good.png")
    if name.startswith("hops-"):
        left = int(name[5:])
        return redirect(f"/art/hops-{left - 1}" if left > 1 else "/art/good.png")
    # A byte every half second for a minute.
    if name == "trickle.png": return stream(PNG, b"\0", .5, 120)
    if name == "webp.png": return reply(b"RIFF" + struct.pack("<I", 30) + b"WEBPVP8 " + bytes(22))
    if name == "pdf.png": return reply(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n")
    if name == "missing.png": return reply(b"Not found\n", "text/plain", status=404)
    return False


class Server(ThreadingHTTPServer):
    # A reader that stops (at its limit, or its deadline) isn't an error here.
    def handle_error(self, request, address):
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        with open(self.server.log_path, "a") as log: log.write(self.path + "\n")
        name = self.path.split("?")[0].removeprefix("/art/")
        if not serve(self, name):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()


def main():
    port_file, log = sys.argv[1], sys.argv[2]
    server = Server(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.log_path = log
    with open(port_file, "w") as f: f.write(str(server.server_address[1]))
    print("fake art ready", flush=True)
    server.serve_forever()


if __name__ == "__main__": main()
