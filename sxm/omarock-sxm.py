#!/usr/bin/env python3
"""omarock-sxm: SiriusXM's live channels for mpd, served on 127.0.0.1 only.

It logs in with the account in ~/.config/omarock/siriusxm.json ({"username",
"password"}, mode 600) through aiosxm, and serves on 127.0.0.1:8720:

    GET /stream/{channel_id}   the channel as one continuous AAC (ADTS) stream,
                               with ICY "Artist - Title" metadata, for mpd
    GET /art/{key}/{w}x{h}     a redirect to SiriusXM's artwork at that size
    GET /v1/...                JSON for omarock and omarock-sxm (see README.md)

It never plays audio: mpd plays the stream, through its one pinned output.
Live channels only. While nobody listens it fetches nothing but the public
now-playing feed, and only while omarock is asking.
"""
import asyncio
import base64
import json
import logging
import os
import re
import socket
import struct
import time
from pathlib import Path
from types import SimpleNamespace

from aiohttp import web
from aiosxm import SxmClient
from aiosxm.models import build_image_url
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

VERSION = "0.1.4"
HOST, PORT = "127.0.0.1", int(os.environ.get("OMAROCK_SXM_PORT", "8720"))
CONFIG = Path(os.environ.get("OMAROCK_SXM_CONFIG", Path.home() / ".config/omarock/siriusxm.json"))
BITRATE = "256k"
# Start this many segments behind the live edge: a cushion, so mpd doesn't
# run dry between segments.
LIVE_SEGMENTS = 2
# A channel's fetching stops this long after its last listener leaves.
IDLE_STOP = 20
# The now-playing feed is polled while a channel plays, or this long after
# omarock last asked.
NOW_PLAYING_EVERY = 15
NOW_PLAYING_KEEPALIVE = 300
META_INTERVAL = 8192
# Each listener gets the audio at real-time pace, this many seconds ahead. A
# segment at once would leave the connection silent for its whole ~10 s, and
# mpd's HTTP input gives up on a connection that idle (it ends the "song").
LEAD = 6.0
SAMPLE_RATES = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)
# The login at start waits until SiriusXM's name resolves, for up to
# NETWORK_WAIT seconds. Started with the session, before the network (a boot),
# it failed, and the first tune had to log in.
LOGIN_HOST = "api.edge-gateway.siriusxm.com"
NETWORK_WAIT = 300
NETWORK_POLL = 2

log = logging.getLogger("omarock-sxm")


async def wait_for_network(host, limit):
    """Until host resolves, for up to limit seconds: whether it did."""
    loop = asyncio.get_running_loop()
    deadline = time.monotonic() + limit
    waiting = False
    while True:
        try:
            await loop.getaddrinfo(host, 443)
            if waiting:
                log.info("the network is up")
            return True
        except OSError:
            if time.monotonic() >= deadline:
                return False
            if not waiting:
                log.info("waiting for the network (%s doesn't resolve yet)", host)
                waiting = True
            await asyncio.sleep(NETWORK_POLL)


def art_url(key, base):
    """A template omarock fills with {w} and {h}, like Apple's artwork."""
    if not key:
        return None
    token = base64.urlsafe_b64encode(key.encode()).decode().rstrip("=")
    return f"{base}/art/{token}/{{w}}x{{h}}"


class Relay:
    """One channel's live HLS, decrypted into a continuous ADTS AAC stream for
    each listener. Fetching starts with the first listener and stops a little
    after the last one leaves."""

    def __init__(self, service, channel):
        self.service = service
        self.channel = channel
        self.listeners = set()
        self.task = None
        self.error = ""
        # The last segment sent, for a listener that joins the running relay.
        self.recent = None

    def listen(self):
        """A new listener's queue. One joining a running relay starts with the
        last segment, rather than nothing until the next one (up to 10 s).
        mpd, holding every client meanwhile, waited that long for a channel
        it tuned, and each time mpd-mpris read the stream for album art
        (the panel once waited a minute behind six of those)."""
        queue = asyncio.Queue(maxsize=32)
        self.listeners.add(queue)
        if not self.task or self.task.done():
            self.recent = None
            self.task = asyncio.create_task(self.run())
        elif self.recent is not None:
            queue.put_nowait(self.recent)
        return queue

    def leave(self, queue):
        self.listeners.discard(queue)

    def send(self, data):
        self.recent = data
        for queue in list(self.listeners):
            try:
                queue.put_nowait(data)
            except asyncio.QueueFull:
                # A listener this far behind is gone or stuck: end its stream.
                log.warning("%s: a listener fell behind; ending its stream", self.channel.title)
                self.listeners.discard(queue)
                end(queue)

    async def run(self):
        name = self.channel.title
        try:
            client = await self.service.client()
            stream = await client.get_stream(self.channel.type, self.channel.id)
            key, key_uri, next_seq, idle_since = None, None, None, None
            while True:
                if self.listeners:
                    idle_since = None
                else:
                    idle_since = idle_since or time.monotonic()
                    if time.monotonic() - idle_since > IDLE_STOP:
                        log.info("%s: no listeners, stopping", name)
                        return
                # The live end only (SiriusXM's playlist holds ~5 hours), with
                # segment paths that get_segment resolves; the sequence numbers,
                # and so the IVs, stay right.
                text = await stream.get_proxied_playlist("key", BITRATE, window=8)
                target, segments = parse_playlist(text)
                if not segments:
                    await asyncio.sleep(2)
                    continue
                first, last = segments[0]["seq"], segments[-1]["seq"]
                if next_seq is None or not first <= next_seq <= last + 1:
                    next_seq = max(first, last - LIVE_SEGMENTS + 1)
                for segment in segments:
                    if segment["seq"] < next_seq:
                        continue
                    if key is None or segment["key_uri"] != key_uri:
                        key, key_uri = await stream.get_key(BITRATE), segment["key_uri"]
                    uri = segment["uri"]
                    # A segment outside the stream's folder comes as a signed CDN URL.
                    data = await (client.request("GET", uri) if uri.startswith("https://")
                                  else stream.get_segment(uri, BITRATE))
                    audio = strip_id3(decrypt(data, key, segment["iv"], segment["seq"]))
                    if audio[:1] != b"\xff":
                        log.warning("%s: segment %d doesn't start with an ADTS frame (%s)",
                                    name, segment["seq"], audio[:4].hex())
                    self.send(audio)
                    next_seq = segment["seq"] + 1
                self.error = ""
                await asyncio.sleep(max(2.0, target / 2))
        except asyncio.CancelledError:
            raise
        except Exception as error:  # noqa: BLE001 - report anything to the listeners
            self.error = f"{type(error).__name__}: {error}"
            log.exception("%s: relay failed", name)
        finally:
            self.recent = None
            for queue in list(self.listeners):
                end(queue)
            self.listeners.clear()


def end(queue):
    """End a listener's stream: drop what it hasn't sent, then None."""
    while not queue.empty():
        queue.get_nowait()
    queue.put_nowait(None)


def parse_playlist(text):
    """An HLS media playlist: its target duration, and its segments as
    {seq, uri, key_uri, iv}."""
    target, seq, key_uri, iv = 10.0, 0, None, None
    segments, pending = [], False
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#EXT-X-TARGETDURATION:"):
            target = float(line.split(":", 1)[1])
        elif line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
            seq = int(line.split(":", 1)[1])
        elif line.startswith("#EXT-X-KEY:"):
            uri = re.search(r'URI="([^"]+)"', line)
            iv_match = re.search(r"IV=0[xX]([0-9a-fA-F]+)", line)
            key_uri = uri.group(1) if uri else None
            iv = bytes.fromhex(iv_match.group(1).rjust(32, "0")) if iv_match else None
        elif line.startswith("#EXTINF"):
            pending = True
        elif line and not line.startswith("#") and pending:
            segments.append({"seq": seq, "uri": line, "key_uri": key_uri, "iv": iv})
            seq += 1
            pending = False
    return target, segments


def adts_frames(audio):
    """ADTS AAC as (frame, seconds) pairs."""
    frames, i = [], 0
    while i + 7 <= len(audio):
        if audio[i] != 0xFF or audio[i + 1] & 0xF0 != 0xF0:
            j = audio.find(b"\xff", i + 1)
            if j < 0:
                break
            i = j
            continue
        length = ((audio[i + 3] & 0x03) << 11) | (audio[i + 4] << 3) | (audio[i + 5] >> 5)
        if length < 7:
            i += 1
            continue
        index = (audio[i + 2] >> 2) & 0x0F
        rate = SAMPLE_RATES[index] if index < len(SAMPLE_RATES) else 44100
        frames.append((audio[i:i + length], 1024 * ((audio[i + 6] & 0x03) + 1) / rate))
        i += length
    return frames


def strip_id3(audio):
    """Each segment starts with an ID3 tag (HLS packed audio's timestamp);
    in one continuous stream it would sit between AAC frames, so drop it."""
    while audio[:3] == b"ID3" and len(audio) >= 10:
        size = (audio[6] << 21) | (audio[7] << 14) | (audio[8] << 7) | audio[9]
        footer = 10 if audio[5] & 0x10 else 0
        audio = audio[10 + size + footer:]
    return audio


def decrypt(data, key, iv, seq):
    """AES-128-CBC, with the IV from the playlist or else the segment's
    sequence number, as HLS specifies; then PKCS#7 padding off."""
    if not key:
        return data
    iv = iv or seq.to_bytes(16, "big")
    decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    plain = decryptor.update(data) + decryptor.finalize()
    pad = plain[-1] if plain else 0
    return plain[:-pad] if 0 < pad <= 16 else plain


class Service:
    def __init__(self):
        self._client = None
        # The now-playing feed is public: this client never logs in.
        self._feed = SxmClient("feed", "public")
        self._login_lock = asyncio.Lock()
        self.account_error = ""
        self.relays = {}
        self.now_playing = {}
        self.now_playing_at = 0.0
        self.asked_at = 0.0

    def credentials(self):
        try:
            data = json.loads(CONFIG.read_text())
            return data.get("username") or "", data.get("password") or ""
        except (OSError, ValueError):
            return "", ""

    async def client(self):
        """A logged-in aiosxm client, made on first use."""
        async with self._login_lock:
            if self._client is None:
                username, password = self.credentials()
                if not username or not password:
                    self.account_error = f"No SiriusXM account in {CONFIG}"
                    raise RuntimeError(self.account_error)
                client = SxmClient(username, password)
                try:
                    await client.connect()
                    self.account_error = ""
                except Exception as error:
                    await client.close()
                    self.account_error = f"SiriusXM login failed: {error}"
                    raise
                self._client = client
            return self._client

    async def channel(self, channel_id):
        """A live channel by id. Without the catalog yet (its first load takes
        ~8 s) a stand-in will do: tuning needs only the id."""
        client = await self.client()
        cached = client._channels_cache or []
        found = next((c for c in cached if c.id == channel_id), None)
        if found is not None or cached:
            return found
        return SimpleNamespace(id=channel_id, type="channel-linear", title="SiriusXM", channel_number="",
                               genre="", is_linear=True)

    async def warm(self):
        """Log in and load the channel catalog at start, so the first tune is quick."""
        await wait_for_network(LOGIN_HOST, NETWORK_WAIT)
        try:
            await (await self.client()).get_channels()
            log.info("channel catalog loaded")
        except Exception as error:  # noqa: BLE001
            log.warning("couldn't load the catalog yet: %s", error)

    def relay(self, channel):
        relay = self.relays.get(channel.id)
        if relay is None:
            relay = self.relays[channel.id] = Relay(self, channel)
        return relay

    async def refresh_now_playing(self):
        try:
            self.now_playing = await self._feed.get_now_playing_all()
            self.now_playing_at = time.time()
        except Exception as error:  # noqa: BLE001
            log.warning("now playing: %s", error)

    async def poll_now_playing(self):
        """The public feed, while something plays or omarock is looking."""
        while True:
            busy = any(r.listeners for r in self.relays.values())
            wanted = time.monotonic() - self.asked_at < NOW_PLAYING_KEEPALIVE
            if (busy or wanted) and time.time() - self.now_playing_at >= NOW_PLAYING_EVERY - 1:
                await self.refresh_now_playing()
            await asyncio.sleep(NOW_PLAYING_EVERY)

    def title_for(self, channel_id):
        now = self.now_playing.get(channel_id)
        if not now:
            return ""
        if now.is_ad:
            return now.show or ""
        parts = [p for p in (now.artist, now.title) if p]
        return " - ".join(parts) if parts else (now.show or "")


def channel_json(channel, base, favorites=()):
    image = channel.image("tile", "1x1") or channel.image("logo", "1x1")
    return {"id": channel.id, "number": channel.channel_number or "", "name": channel.title,
            "shortName": channel.title_short or "", "genre": channel.genre or "",
            "description": channel.description or "", "logo": art_url(image.key if image else None, base),
            "stream": f"{base}/stream/{channel.id}", "favorite": channel.id in favorites,
            "available": not channel.unentitled and not channel.off_air}


def now_json(now, base):
    return {"artist": now.artist or "", "title": now.title or "", "show": now.show or "",
            "isAd": now.is_ad, "startedAt": now.started_at or "",
            "art": art_url(now.image_key or now.show_image_key, base)}


# Only the account running this service. Every account here can reach
# 127.0.0.1, so a header alone (below) keeps out web pages but not another
# account's programs: the kernel's socket table says who owns the other end.
ME = os.getuid()


def proc_address(ip, port):
    """An address as /proc/net/tcp and tcp6 show it: each 32-bit word of the
    address in hex, in this machine's byte order, then the port."""
    raw = socket.inet_pton(socket.AF_INET6 if ":" in ip else socket.AF_INET, ip)
    return "".join("%08X" % w for w in struct.unpack("=%dI" % (len(raw) // 4), raw)) + ":%04X" % port


def socket_owners(peer, ours):
    """The accounts owning the far end of a loopback connection (peer, ours:
    (address, port) as seen here), from /proc/net/tcp and tcp6: [] when it has
    closed (the table lists a closed socket with no inode, and a TIME_WAIT one
    as uid 0: no owner left to check)."""
    pairs = [(peer[0], ours[0])]
    if ":" not in peer[0]:  # an IPv6 socket connected to 127.0.0.1
        pairs.append(("::ffff:" + peer[0], "::ffff:" + ours[0]))
    wanted = {(proc_address(a, peer[1]), proc_address(b, ours[1])) for a, b in pairs}
    owners = []
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            lines = Path(table).read_text().splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            f = line.split()
            if len(f) > 9 and (f[1], f[2]) in wanted and f[9] != "0":
                owners.append(int(f[7]))
    return owners


_refused_logged = 0.0


def from_another_account(transport):
    """Why a connection is refused, or None: it has to be this account's."""
    global _refused_logged
    peer = transport.get_extra_info("peername") if transport else None
    ours = transport.get_extra_info("sockname") if transport else None
    try:
        owners = socket_owners(peer[:2], ours[:2]) if peer and ours else []
    except (OSError, ValueError):
        owners = []
    if owners and all(uid == ME for uid in owners):
        return None
    if time.monotonic() - _refused_logged > 60:
        _refused_logged = time.monotonic()
        if owners:
            log.warning("refused a connection from another account (uid %s)", owners[0])
        else:
            log.warning("refused a connection that closed before its owner could be checked")
    return "Only the account running omarock-sxm can use it."


def routes(service):
    # Only this account's programs (from_another_account), and of those only
    # omarock's own clients, never a web page: /v1 wants a header a page
    # can't send without asking first (CORS, never allowed here), and every
    # request this address as its Host, which a page that points a name of
    # its own at 127.0.0.1 (DNS rebinding) doesn't have. mpd's streams and the
    # panel's covers can't send headers, so those need only the Host.
    @web.middleware
    async def omarock_only(request, handler):
        why = from_another_account(request.transport)
        if why:
            return error(403, why)
        if request.host not in (f"{HOST}:{PORT}", f"localhost:{PORT}"):
            return error(403, "Not this address.")
        if request.path.startswith("/v1/") and request.headers.get("X-Omarock") != "1":
            return error(403, "Only omarock asks here (X-Omarock: 1).")
        return await handler(request)

    app = web.Application(middlewares=[omarock_only])
    base = f"http://{HOST}:{PORT}"

    def error(status, message):
        return web.json_response({"error": message}, status=status)

    async def health(request):
        username, _ = service.credentials()
        body = {"ok": True, "version": VERSION, "account": bool(username), "loggedIn": service._client is not None,
                "error": service.account_error,
                "playing": [r.channel.title for r in service.relays.values() if r.listeners]}
        return web.json_response(body)

    async def channels(request):
        service.asked_at = time.monotonic()
        try:
            client = await service.client()
            found = [c for c in await client.get_channels() if c.is_linear]
            favorites = {c.id for c in await client.get_library_channels()}
        except Exception as e:  # noqa: BLE001
            return error(502, str(e) or type(e).__name__)
        found.sort(key=lambda c: (int(c.channel_number) if (c.channel_number or "").isdigit() else 10**6, c.title))
        return web.json_response([channel_json(c, base, favorites) for c in found])

    async def now_playing(request):
        service.asked_at = time.monotonic()
        if time.time() - service.now_playing_at > NOW_PLAYING_EVERY * 2:
            await service.refresh_now_playing()
        return web.json_response({cid: now_json(now, base) for cid, now in service.now_playing.items()})

    async def favorite(request):
        channel_id = request.match_info["id"]
        try:
            client = await service.client()
            if request.method == "POST":
                await client.add_to_library("channel-linear", channel_id)
            else:
                await client.remove_from_library("channel-linear", channel_id)
        except Exception as e:  # noqa: BLE001
            return error(502, str(e) or type(e).__name__)
        return web.json_response({"ok": True})

    async def art(request):
        try:
            token = request.match_info["token"]
            key = base64.urlsafe_b64decode(token + "=" * (-len(token) % 4)).decode()
            width, height = (max(16, min(3000, int(n))) for n in request.match_info["size"].split("x"))
        except (ValueError, UnicodeDecodeError):
            return error(400, "Bad artwork address")
        raise web.HTTPFound(build_image_url(key, width, height, "jpeg"))

    async def stream(request):
        channel_id = request.match_info["id"]
        try:
            channel = await service.channel(channel_id)
        except Exception as e:  # noqa: BLE001
            return error(502, str(e) or type(e).__name__)
        if channel is None or not channel.is_linear:
            return error(404, "No such live channel")
        icy = request.headers.get("Icy-MetaData") == "1"
        name = f"{channel.title} ({channel.channel_number})" if channel.channel_number else channel.title
        response = web.StreamResponse(headers={
            "Content-Type": "audio/aac", "Cache-Control": "no-cache, no-store",
            "icy-name": name, "icy-genre": channel.genre or "SiriusXM",
            **({"icy-metaint": str(META_INTERVAL)} if icy else {})})
        await response.prepare(request)
        # The song title for the stream's first metadata, if the feed is stale.
        if time.time() - service.now_playing_at > NOW_PLAYING_EVERY:
            await service.refresh_now_playing()
        relay = service.relay(channel)
        queue = relay.listen()
        log.info("%s: listener connected (icy %s)", channel.title, icy)
        state = {"title": None, "until_meta": META_INTERVAL}

        async def write(data):
            if not icy:
                await response.write(data)
                return
            # ICY: a metadata block after every META_INTERVAL bytes of audio,
            # with the title only when it changed.
            while data:
                part, data = data[:state["until_meta"]], data[state["until_meta"]:]
                await response.write(part)
                state["until_meta"] -= len(part)
                if state["until_meta"] == 0:
                    title = service.title_for(channel.id)
                    block = b"\x00"
                    if title != state["title"]:
                        text = f"StreamTitle='{title}';".encode()
                        length = -(-len(text) // 16)
                        block = bytes([length]) + text.ljust(length * 16, b"\x00")
                        state["title"] = title
                    await response.write(block)
                    state["until_meta"] = META_INTERVAL

        started, sent = time.monotonic(), 0.0
        try:
            while True:
                data = await queue.get()
                if data is None:
                    break
                # Real-time pace, LEAD seconds ahead, in quarter-second groups.
                group, seconds = [], 0.0
                for frame, duration in adts_frames(data) + [(None, 0.0)]:
                    if frame is not None:
                        group.append(frame)
                        seconds += duration
                    if group and (seconds >= 0.25 or frame is None):
                        await write(b"".join(group))
                        sent += seconds
                        group, seconds = [], 0.0
                        ahead = sent - (time.monotonic() - started)
                        if ahead > LEAD:
                            await asyncio.sleep(ahead - LEAD)
        except (ConnectionResetError, asyncio.CancelledError):
            pass
        finally:
            relay.leave(queue)
            log.info("%s: listener left", channel.title)
        return response

    app.router.add_get("/v1/health", health)
    app.router.add_get("/v1/channels", channels)
    app.router.add_get("/v1/nowplaying", now_playing)
    app.router.add_post("/v1/favorites/{id}", favorite)
    app.router.add_delete("/v1/favorites/{id}", favorite)
    app.router.add_get("/art/{token}/{size}", art)
    app.router.add_get("/stream/{id}", stream)
    return app


async def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    logging.getLogger("aiohttp.access").setLevel(logging.WARNING)
    service = Service()
    app = routes(service)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, HOST, PORT).start()
    log.info("omarock-sxm %s on http://%s:%d", VERSION, HOST, PORT)
    poller = asyncio.create_task(service.poll_now_playing())
    warming = asyncio.create_task(service.warm())
    try:
        await asyncio.Event().wait()
    finally:
        poller.cancel()
        warming.cancel()
        if service._client:
            await service._client.close()
        await service._feed.close()
        await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
