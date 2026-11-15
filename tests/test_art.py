#!/usr/bin/env python3
"""Tests for tools/omarock-art, which fetches and checks cover art for the
panel outside the shell: against servers on 127.0.0.1 only (the harness's
fake art, tools/capture/fake_art.py, and a few made here), with a cache folder
of its own.

    python3 -I tests/test_art.py
"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tools/omarock-art"
sys.path.insert(0, str(ROOT / "tools/capture"))
import fake_art  # noqa: E402

loader = importlib.machinery.SourceFileLoader("omarock_art", str(HELPER))
spec = importlib.util.spec_from_loader("omarock_art", loader)
art = importlib.util.module_from_spec(spec)
loader.exec_module(art)

failures = []


def check(what, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + what + (f": {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(what)


def chunks(png):
    pos, kinds = 8, []
    while pos < len(png):
        length, kind = struct.unpack(">I4s", png[pos:pos + 8])
        kinds.append(kind.decode())
        pos += 12 + length
    return kinds


def pixels(png):
    """An 8-bit RGBA PNG's pixels, as omarock-art writes them (filter 0)."""
    pos, data = 8, b""
    while pos < len(png):
        length, kind = struct.unpack(">I4s", png[pos:pos + 8])
        if kind == b"IHDR": width, height, depth, color = struct.unpack(">IIBB", png[pos + 8:pos + 18])
        if kind == b"IDAT": data += png[pos + 8:pos + 8 + length]
        pos += 12 + length
    raw = zlib.decompress(data)
    assert depth == 8 and color == 6
    return width, height, [raw[y * (4 * width + 1) + 1:(y + 1) * (4 * width + 1)] for y in range(height)]


def refused(what, call):
    try:
        call()
    except art.Refused as e:
        return e.why
    return None


def png_with(width, height, depth, color, data_size, interlace=0, extra=b"", short=0):
    raw = bytes(data_size - short)
    header = struct.pack(">IIBBBBB", width, height, depth, color, 0, 0, interlace)
    return (art.PNG + art.chunk(b"IHDR", header) + extra + art.chunk(b"IDAT", zlib.compress(raw))
            + art.chunk(b"IEND", b""))


def jpeg_with(sof=0xC0, precision=8, scans=1, eoi=True):
    """A JPEG's skeleton: tables, a frame and its scans (no real coded data)."""
    out = bytearray(b"\xff\xd8")
    out += b"\xff\xdb" + struct.pack(">H", 67) + bytes(65)
    out += bytes((0xFF, sof)) + struct.pack(">HBHHB", 11, precision, 8, 8, 1) + bytes((1, 0x11, 0))
    for _ in range(scans):
        out += b"\xff\xc4" + struct.pack(">H", 20) + bytes(18)
        out += b"\xff\xda" + struct.pack(">HB", 8, 1) + bytes((1, 0)) + bytes((0, 63, 0)) + b"\x12\x34\xff\x00\x56"
    if eoi: out += b"\xff\xd9"
    return bytes(out)


class Silent:
    """A server that takes connections and never says anything."""

    def __init__(self):
        self.sock = socket.create_server(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        self.held = []
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                self.held.append(self.sock.accept()[0])
            except OSError:
                return


def run(folder, urls, deadline=2, extra=(), env=None):
    started = time.monotonic()
    result = subprocess.run([sys.executable, "-I", str(HELPER), "--dir", str(folder), "--deadline", str(deadline), *extra],
                            input="\n".join(urls) + "\n", capture_output=True, text=True, timeout=60, env=env)
    answers = [json.loads(line) for line in result.stdout.splitlines()]
    return {a["url"]: a for a in answers}, answers, result, time.monotonic() - started


def https(tmp):
    """The same fake over TLS, with a certificate of its own (openssl's): one the
    helper is told to trust (SSL_CERT_FILE), then one it isn't."""
    import shutil
    import ssl
    if not shutil.which("openssl"):
        print("skip https: no openssl")
        return
    key, cert = tmp / "key.pem", tmp / "cert.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                    "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=127.0.0.1",
                    "-addext", "subjectAltName=IP:127.0.0.1"], check=True, capture_output=True)
    server = fake_art.Server(("127.0.0.1", 0), fake_art.Handler)
    server.daemon_threads = True
    server.log_path = tmp / "https.log"
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"https://127.0.0.1:{server.server_address[1]}/art/"
    trusted = dict(os.environ, SSL_CERT_FILE=str(cert))
    by, _, _, _ = run(tmp / "https", [base + "good.png", base + "to-http"], env=trusted)
    check("https: a PNG", "file" in by[base + "good.png"], repr(by[base + "good.png"]))
    check("https: a redirect down to http is refused", by[base + "to-http"].get("refused") == "a redirect from https to http",
          repr(by[base + "to-http"]))
    by, _, _, _ = run(tmp / "https-untrusted", [base + "good.png"])
    check("https: a certificate that doesn't check out is refused",
          by[base + "good.png"].get("refused") == "its server's certificate doesn't check out", repr(by[base + "good.png"]))
    server.shutdown()


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        log = tmp / "requests.log"
        log.touch()
        server = fake_art.Server(("127.0.0.1", 0), fake_art.Handler)
        server.daemon_threads = True
        server.log_path = log
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_address[1]}/art/"
        silent = Silent()
        closed = socket.create_server(("127.0.0.1", 0))
        closed_port = closed.getsockname()[1]
        closed.close()
        folder = tmp / "cache/omarock/art"

        names = fake_art.NAMES
        urls = [base + n for n in names] + [f"http://127.0.0.1:{silent.port}/cover.jpg",
                                            f"http://127.0.0.1:{closed_port}/cover.jpg",
                                            "ftp://127.0.0.1/cover.jpg", "file:///etc/hostname",
                                            "data:image/png;base64,iVBORw0KGgo=", base + "good.png"]
        by, answers, result, took = run(folder, urls)
        check("every address is answered once, a repeat once", len(answers) == len(urls) - 1 and set(by) == set(urls),
              f"{len(answers)} answers for {len(set(urls))}")
        check("nothing on stderr", result.stderr == "", result.stderr[:300])
        check("it ends within its deadlines", took < 2 * 2 + 5 + 2, f"{took:.1f} s")

        def file(name):
            a = by[base + name]
            return Path(a["file"]).read_bytes() if "file" in a else None

        def why(name):
            return by[base + name].get("refused")

        jpeg = file("good.jpg")
        check("a JPEG is kept, its Exif and comment dropped",
              jpeg is not None and jpeg.startswith(b"\xff\xd8\xff\xe0") and jpeg.endswith(b"\xff\xd9")
              and b"Exif" not in jpeg and b"made for omarock" not in jpeg and jpeg == fake_art.JPEG,
              repr(by[base + "good.jpg"]))
        check("a progressive JPEG is kept as it was", file("progressive.jpg") == fake_art.PROGRESSIVE)
        good = file("good.png")
        check("a PNG is kept, its text dropped", good is not None and chunks(good) == ["IHDR", "IDAT", "IEND"],
              repr(chunks(good) if good else by[base + "good.png"]))
        ztxt = file("ztxt.png")
        check("a PNG with 60 zTXt chunks (7 MiB each, inflated), an ICC profile and text: only its image is kept",
              ztxt is not None and chunks(ztxt) == ["IHDR", "IDAT", "IEND"] and len(ztxt) < 1000,
              repr(chunks(ztxt) if ztxt else by[base + "ztxt.png"]))
        icon = file("favicon.ico")
        if icon:
            width, height, rows = pixels(icon)
            check("a Windows icon becomes a PNG, its transparency kept",
                  (width, height) == (16, 16) and rows[0][:4] == b"\xff\0\0\0" and rows[0][16:20] == b"\xff\0\0\xff"
                  and rows[-1][:4] == b"\xff\0\0\xff", repr(rows[0][:20]))
        else:
            check("a Windows icon becomes a PNG", False, repr(by[base + "favicon.ico"]))
        for name in ("logo.gif", "interlaced.gif"):
            image = file(name)
            check(f"a GIF ({name}) becomes a PNG of its first frame",
                  image is not None and pixels(image)[:2] == (20, 12), repr(by[base + name]))
        check("hops-3: three redirects are followed", file("hops-3") == good)
        for name, want in (("endless.png", "bigger than 2 MiB"), ("big.png", "bigger than 2 MiB"),
                           ("big-chunked.png", "bigger than 2 MiB"), ("logo.svg", "an SVG"),
                           ("not-an-image.png", "not a JPEG, PNG, GIF or icon"),
                           ("huge.png", "an image of 30000 by 30000, over 4096 a side"),
                           ("loop", "more than 3 redirects"), ("hops-4", "more than 3 redirects"),
                           ("to-file", "not an http or https address"), ("webp.png", "a WebP image"),
                           ("pdf.png", "not a JPEG, PNG, GIF or icon"), ("missing.png", "its server said 404"),
                           ("trickle.png", "no answer in time")):
            check(f"{name}: refused, {want}", why(name) == want, repr(by[base + name]))
        check("refusals that may pass are asked again sooner", by[base + "trickle.png"]["again"] == art.FAILED_FOR
              and by[base + "logo.svg"]["again"] == art.REFUSED_FOR)
        check("a server that never answers: no answer in time",
              by[urls[len(names)]].get("refused") == "no answer in time", repr(by[urls[len(names)]]))
        check("a server that isn't there: can't reach it",
              by[urls[len(names) + 1]].get("refused") == "can't reach its server", repr(by[urls[len(names) + 1]]))
        check("ftp, file and data addresses are refused",
              all(by[u].get("refused") == "not an http or https address" for u in urls[len(names) + 2:len(names) + 5]))
        sent = log.read_text().splitlines()
        check("the fake was asked for neither the file nor the data address", not any("hostname" in s for s in sent))

        made = [Path(a["file"]) for a in answers if "file" in a]
        check("the folder is 0700, and every file in it 0600",
              folder.stat().st_mode & 0o777 == 0o700 and folder.parent.stat().st_mode & 0o777 == 0o700
              and all(p.stat().st_mode & 0o777 == 0o600 for p in folder.iterdir()),
              ", ".join(f"{oct(p.stat().st_mode & 0o777)} {p.name}" for p in folder.iterdir()))
        check("files are named by the address's hash, not the address",
              all(len(p.stem) == 64 and p.suffix in (".jpg", ".png") for p in made)
              and not any(n.split(".")[0] in p.name for p in folder.iterdir() for n in names))

        # Again: from the cache and the refusals, without a fetch.
        asked = len(log.read_text().splitlines())
        again, answers2, _, took = run(folder, urls)
        check("asked again: the same answers", all(again[u].get("file") == by[u].get("file")
                                                    and again[u].get("refused") == by[u].get("refused") for u in by))
        check("and nothing fetched again (made files and remembered refusals)",
              len(log.read_text().splitlines()) == asked and took < 2, f"{len(log.read_text().splitlines()) - asked} fetched, {took:.1f} s")

        # A refusal past its time is asked again; a file made isn't.
        for refusal in folder.glob("*.no"):
            held = json.loads(refusal.read_text())
            refusal.write_text(json.dumps({"why": held["why"], "until": time.time() - 1}))
        run(folder, [base + "missing.png", base + "good.png"])
        new = log.read_text().splitlines()[asked:]
        check("a refusal past its time is fetched again, a file isn't", new == ["/art/missing.png"], repr(new))

        # The deadline is for everything: a trickle, a slow server, redirects.
        _, _, _, took = run(tmp / "fresh", [base + "trickle.png"], deadline=1.5)
        check("a body that trickles in stops at the deadline", 1.4 < took < 3.5, f"{took:.1f} s")
        _, _, _, took = run(tmp / "fresh", [base + "endless.png"], deadline=5)
        check("an endless body stops at 2 MiB, not the deadline", took < 3, f"{took:.1f} s")
        small, _, _, _ = run(tmp / "fresh", [base + "good.png"], extra=("--max-bytes", "100"))
        check("--max-bytes refuses as it reads", small[base + "good.png"].get("refused") == "bigger than 100 bytes",
              repr(small))

        # Pruning, once a day: files unused for 30 days, refusals over a day old, temp files.
        prune = tmp / "prune"
        prune.mkdir(mode=0o700)
        old, recent, stale_no, temp = prune / ("a" * 64 + ".png"), prune / ("b" * 64 + ".jpg"), prune / ("c" * 64 + ".no"), prune / ".x.tmp"
        for p in (old, recent, stale_no, temp): p.write_bytes(b"x")
        month, two_days = time.time() - 31 * 86400, time.time() - 2 * 86400
        os.utime(old, (month, month))
        os.utime(stale_no, (two_days, two_days))
        os.utime(temp, (two_days, two_days))
        (prune / ".pruned").write_bytes(b"")
        os.utime(prune / ".pruned", (time.time() - 3600, time.time() - 3600))
        run(prune, [])
        check("pruned at most once a day", old.exists())
        os.utime(prune / ".pruned", (two_days, two_days))
        run(prune, [])
        check("a day later: unused for 30 days, refusals past their day and temp files go",
              not old.exists() and recent.exists() and not stale_no.exists() and not temp.exists(),
              ", ".join(p.name for p in prune.iterdir()))
        recent.unlink()
        art.MAX_CACHE, kept = 2, art.MAX_CACHE
        for i, p in enumerate(prune / (c * 64 + ".png") for c in "def"):
            p.write_bytes(b"xx")
            os.utime(p, (time.time() - 100 + i, time.time() - 100 + i))
        os.utime(prune / ".pruned", (two_days, two_days))
        art.prune(prune)
        art.MAX_CACHE = kept
        left = sorted(p.name[0] for p in prune.iterdir() if not p.name.startswith("."))
        check("over its size, the oldest go first", left == ["f"], repr(left))
        https(tmp)
        server.shutdown()

        # A server that closes the connection after each answer (HTTP/1.0,
        # as many do): the body read to its end closes the socket with it.
        class Closing(fake_art.Handler):
            protocol_version = "HTTP/1.0"
        server = fake_art.Server(("127.0.0.1", 0), Closing)
        server.daemon_threads = True
        server.log_path = log
        threading.Thread(target=server.serve_forever, daemon=True).start()
        closing = f"http://127.0.0.1:{server.server_address[1]}/art/"
        by, _, _, _ = run(tmp / "closing", [closing + n for n in ("good.jpg", "good.png", "hops-3", "endless.png")])
        check("a server that closes after each answer: files made, redirects followed, the endless body refused",
              all("file" in by[closing + n] for n in ("good.jpg", "good.png", "hops-3"))
              and by[closing + "endless.png"].get("refused") == "bigger than 2 MiB", repr(by))
        server.shutdown()

    # ---- A server on this machine: only this account's ----
    # (Another account can't be made here; the socket table is read for this
    # one's, and another's is played by owners() answering for it.)
    listener = socket.create_server(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    mine = socket.create_connection(("127.0.0.1", port))
    check("the socket table says who owns the far end: this account",
          art.owners(mine.getpeername()[:2], mine.getsockname()[:2]) == [os.getuid()])
    mine.close()
    real = art.owners
    for found, what in (([os.getuid() + 1], "another account's"), ([], "one whose owner can't be found")):
        art.owners = lambda peer, ours, found=found: found
        why = refused("", lambda: art.connect("127.0.0.1", port, time.monotonic() + 2))
        check(f"a loopback server that's {what} is refused", why == "a server on this machine another account runs", repr(why))
    art.owners = real
    listener.close()

    # ---- The checks themselves ----
    gray = art.png_data_size(13, 7, 8, 0, 0)
    check("a PNG's data must inflate to its size", art.clean_png(png_with(13, 7, 8, 0, gray)) is not None
          and refused("short", lambda: art.clean_png(png_with(13, 7, 8, 0, gray, short=1))) == "a damaged PNG"
          and refused("long", lambda: art.clean_png(png_with(13, 7, 8, 0, gray + 1))) == "a damaged PNG")
    laced = art.png_data_size(13, 7, 8, 0, 1)
    check("an interlaced PNG's size counts its seven passes",
          laced != gray and art.clean_png(png_with(13, 7, 8, 0, laced, interlace=1)) is not None)
    check("16-bit RGBA", art.clean_png(png_with(9, 5, 16, 6, art.png_data_size(9, 5, 16, 6, 0))) is not None)
    plte = art.chunk(b"PLTE", bytes(3 * 4))
    check("a palette PNG needs its palette, one that fits its depth",
          art.clean_png(png_with(5, 5, 2, 3, art.png_data_size(5, 5, 2, 3, 0), extra=plte)) is not None
          and refused("", lambda: art.clean_png(png_with(5, 5, 2, 3, art.png_data_size(5, 5, 2, 3, 0)))) is not None
          and refused("", lambda: art.clean_png(png_with(5, 5, 1, 3, art.png_data_size(5, 5, 1, 3, 0), extra=plte))) is not None)
    check("a palette in a gray PNG is refused",
          refused("", lambda: art.clean_png(png_with(5, 5, 8, 0, art.png_data_size(5, 5, 8, 0, 0), extra=plte))) is not None)
    good = png_with(4, 4, 8, 2, art.png_data_size(4, 4, 8, 2, 0))
    bad_crc = good[:30] + bytes((good[30] ^ 1,)) + good[31:]
    check("a chunk whose CRC is wrong is refused", refused("", lambda: art.clean_png(bad_crc)) == "a damaged PNG")
    check("an unknown critical chunk is refused",
          refused("", lambda: art.clean_png(png_with(4, 4, 8, 2, art.png_data_size(4, 4, 8, 2, 0), extra=art.chunk(b"ABCD", b"x"))))
          == "a PNG with a part omarock doesn't know")
    kept = art.clean_png(png_with(4, 4, 8, 2, art.png_data_size(4, 4, 8, 2, 0),
                                  extra=art.chunk(b"iCCP", b"x\0\0" + zlib.compress(b"y")) + art.chunk(b"eXIf", b"z")
                                  + art.chunk(b"acTL", bytes(8))))
    check("ICC profiles, Exif and animation go", chunks(kept) == ["IHDR", "IDAT", "IEND"], repr(chunks(kept)))
    check("a PNG cut short is refused", refused("", lambda: art.clean_png(good[:-12])) == "a PNG that ends early")
    check("a 4096-pixel side is the most", art.check_size(4096, 4096) is None
          and refused("", lambda: art.check_size(4097, 1)) is not None and refused("", lambda: art.check_size(0, 1)) is not None)

    check("a JPEG's skeleton passes", art.clean_jpeg(jpeg_with()).endswith(b"\xff\xd9"))
    for sof, what in ((0xC3, "a lossless"), (0xC9, "an arithmetic-coded"), (0xC5, "a hierarchical")):
        check(f"{what} JPEG is refused", refused("", lambda: art.clean_jpeg(jpeg_with(sof))) == "a kind of JPEG omarock doesn't show")
    check("a 12-bit JPEG is refused", refused("", lambda: art.clean_jpeg(jpeg_with(precision=12))) == "a kind of JPEG omarock doesn't show")
    check("a JPEG with no end is refused", refused("", lambda: art.clean_jpeg(jpeg_with(eoi=False))) == "a JPEG that ends early")
    check(f"a JPEG of more than {art.MAX_SCANS} scans is refused",
          art.clean_jpeg(jpeg_with(scans=art.MAX_SCANS)) is not None
          and refused("", lambda: art.clean_jpeg(jpeg_with(scans=art.MAX_SCANS + 1))) == f"a JPEG of more than {art.MAX_SCANS} scans")
    icc = jpeg_with()[:2] + b"\xff\xe2" + struct.pack(">H", 18) + b"ICC_PROFILE\0" + bytes(4) + jpeg_with()[2:]
    check("a JPEG's ICC profile goes", art.clean_jpeg(icc) == jpeg_with())

    # An icon of one 8-bit bitmap, 3 by 2, its AND mask clearing one pixel.
    palette = bytes((0, 0, 255, 0, 0, 255, 0, 0)) + bytes(4 * 254)
    rows = bytes((1, 0, 1, 0)) + bytes((0, 1, 0, 0))  # bottom row first, each padded to 4 bytes
    mask = bytes((0b01000000, 0, 0, 0)) + bytes(4)
    dib = struct.pack("<IiiHHIIiiII", 40, 3, 4, 1, 8, 0, 0, 0, 0, 0, 0) + palette + rows + mask
    ico = struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", 3, 2, 0, 0, 1, 8, len(dib), 22) + dib
    width, height, lines = pixels(art.icon_png(ico))
    check("an icon's 8-bit bitmap and AND mask", (width, height) == (3, 2)
          and lines == [b"\xff\0\0\xff\0\xff\0\xff\xff\0\0\xff", b"\0\xff\0\xff\xff\0\0\0\0\xff\0\xff"], repr(lines))
    inner = png_with(4, 4, 8, 2, art.png_data_size(4, 4, 8, 2, 0), extra=art.chunk(b"tEXt", b"a\0b"))
    ico_png = struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", 4, 4, 0, 0, 1, 32, len(inner), 22) + inner
    check("an icon's PNG is checked as a PNG", chunks(art.icon_png(ico_png)) == ["IHDR", "IDAT", "IEND"])
    check("an icon with no images is refused", refused("", lambda: art.icon_png(struct.pack("<HHH", 0, 1, 0))) is not None)

    # A 1 by 1 GIF whose first code (7, of 3 bits) isn't in its table yet.
    gif = (b"GIF89a" + struct.pack("<HHBBB", 1, 1, 0x80, 0, 0) + bytes(6) + b","
           + struct.pack("<HHHHB", 0, 0, 1, 1, 0) + b"\x02\x01\x07\x00;")
    check("a GIF whose codes go wrong is refused", refused("", lambda: art.vet(gif)) == "a damaged GIF")
    big = b"GIF89a" + struct.pack("<HHBBB", 2000, 10, 0, 0, 0) + b";"
    check("a GIF over 1024 a side is refused", refused("", lambda: art.vet(big)) == "an image of 2000 by 10, over 1024 a side")
    check("an SVG without its XML line is refused", refused("", lambda: art.vet(b"  <svg xmlns='x'/>")) == "an SVG")
    check("bytes that are no image are refused", refused("", lambda: art.vet(b"\0" * 64)) == "not a JPEG, PNG, GIF or icon")

    print(f"\n{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__": main()
