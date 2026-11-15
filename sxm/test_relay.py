"""The relay's listeners, the login's wait for the network, and that only
omarock's own requests, from this account, are answered: run with the service's venv,
~/.local/share/omarock/sxm-venv/bin/python sxm/test_relay.py"""
import asyncio
import importlib.util
import time
from pathlib import Path
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("omarock_sxm", Path(__file__).with_name("omarock-sxm.py"))
sxm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sxm)


async def main():
    relay = sxm.Relay(service=None, channel=SimpleNamespace(title="Test", id="t", type="channel-linear"))
    # A relay already running (its task not done), as for a second listener.
    relay.task = asyncio.get_running_loop().create_future()
    first = relay.listen()
    assert first.empty(), "nothing sent yet: nothing to start with"
    relay.send(b"\xff\xf1segment-1")
    relay.send(b"\xff\xf1segment-2")
    late = relay.listen()
    assert late.get_nowait() == b"\xff\xf1segment-2" and late.empty(), "a late listener starts with the last segment"
    assert first.qsize() == 2, "the first listener has both"
    relay.send(b"\xff\xf1segment-3")
    assert late.get_nowait() == b"\xff\xf1segment-3", "then it follows along"
    # A stopped relay starts again from nothing old.
    relay.task.set_result(None)
    relay.run = lambda: asyncio.sleep(0)
    fresh = relay.listen()
    assert fresh.empty() and relay.recent is None, "a restarted relay doesn't replay the old segment"
    await relay.task
    print("ok: relay listeners")
    await network()


async def network():
    """No network yet (a boot): it waits, asking again, until the name resolves."""
    loop = asyncio.get_running_loop()
    asked = []

    async def getaddrinfo(host, port):
        asked.append(host)
        if len(asked) < 3:
            raise OSError("Temporary failure in name resolution")
        return [("address",)]
    loop.getaddrinfo = getaddrinfo
    sxm.NETWORK_POLL = 0.01
    assert await sxm.wait_for_network("example.com", 5) is True, "the network came up"
    assert asked == ["example.com"] * 3, "asked until it resolved"
    asked.clear()

    async def never(host, port):
        asked.append(host)
        raise OSError("Temporary failure in name resolution")
    loop.getaddrinfo = never
    assert await sxm.wait_for_network("example.com", 0.05) is False, "no network: it gives up"
    assert len(asked) >= 2, "after asking more than once"
    print("ok: the login waits for the network")
    await web_pages()


async def web_pages():
    """A web page can't drive the service: the real routes, on a spare port."""
    import aiohttp
    from aiohttp import web
    runner = web.AppRunner(sxm.routes(SimpleNamespace()))
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    sxm.PORT = site._server.sockets[0].getsockname()[1]
    base = f"http://127.0.0.1:{sxm.PORT}"
    try:
        async with aiohttp.ClientSession() as http:
            async def status(path, headers=None):
                async with http.get(base + path, headers=headers or {}) as reply:
                    return reply.status
            omarock = {"X-Omarock": "1"}
            assert await status("/v1/nosuch", omarock) == 404, "omarock's request gets past the check"
            assert await status("/v1/nosuch") == 403, "a request without X-Omarock is refused"
            assert await status("/v1/nosuch", dict(omarock, Host=f"rebind.example:{sxm.PORT}")) == 403, \
                "another name for this address is refused (DNS rebinding)"
            assert await status("/stream") == 404, "a stream or cover needs no header (mpd and the panel's images)"
            assert await status("/stream", {"Host": f"rebind.example:{sxm.PORT}"}) == 403, "but the right address"
            # Another account's programs: by who owns the connection's far end.
            # Every connection here is this account's, so "another account" is
            # this one with the service told it runs as another.
            me = sxm.ME
            sxm.ME = me + 4242
            try:
                async with http.get(base + "/v1/nosuch", headers=omarock) as reply:
                    assert reply.status == 403 and "Only the account running omarock-sxm" in await reply.text(), \
                        "another account's request is refused"
                assert await status("/stream") == 403, "and its stream (mpd's would be this account's)"
            finally:
                sxm.ME = me
            assert await status("/v1/nosuch", omarock) == 404, "this account's gets past it again"
    finally:
        await runner.cleanup()
    print("ok: only omarock's own requests, from this account")
    await forwarded()


async def forwarded():
    """What SiriusXM says goes on to the panel, which reads it on the shell's
    one thread: at most CHANNELS_MOST channels and entries of what's on now,
    each text at most TEXT_MOST, and an ICY title that fits its block."""
    import aiohttp
    from aiohttp import web
    huge = "x" * 200000

    def channel(n):
        return SimpleNamespace(id=f"c{n}", is_linear=True, channel_number=str(n), title=huge, title_short=huge, genre=huge,
                               description=huge, unentitled=False, off_air=False, image=lambda kind, ratio: None)
    now = SimpleNamespace(artist=huge, title=huge, show=huge, is_ad=False, started_at=huge, image_key=huge, show_image_key=None)

    class Client:
        async def get_channels(self):
            return [SimpleNamespace(**dict(vars(channel(0)), id="y" * 200000))] + [channel(n) for n in range(5000)]

        async def get_library_channels(self):
            return [channel(n) for n in range(5000)]

    async def client():
        return Client()
    service = SimpleNamespace(asked_at=0.0, client=client, now_playing={f"c{n}": now for n in range(5000)},
                              now_playing_at=time.time(), relays={})
    runner = web.AppRunner(sxm.routes(service))
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    sxm.PORT = site._server.sockets[0].getsockname()[1]
    base = f"http://127.0.0.1:{sxm.PORT}"
    try:
        async with aiohttp.ClientSession() as http:
            async def get(path):
                async with http.get(base + path, headers={"X-Omarock": "1"}) as reply:
                    return await reply.json()
            channels = await get("/v1/channels")
            assert len(channels) == sxm.CHANNELS_MOST, f"{len(channels)} channels passed on"
            longest = max(len(v) for c in channels for v in c.values() if isinstance(v, str))
            assert longest <= sxm.TEXT_MOST + 100, f"a channel's text of {longest}"
            assert all(len(c["id"]) <= sxm.TEXT_MOST for c in channels), "a channel id too long to be one is left out"
            playing = await get("/v1/nowplaying")
            assert len(playing) == sxm.CHANNELS_MOST, f"{len(playing)} entries of what's on now"
            entry = next(iter(playing.values()))
            assert max(len(v) for v in entry.values() if isinstance(v, str)) <= sxm.TEXT_MOST and entry["art"] is None, \
                "what's on now is cut short, art too long to be one left out"
    finally:
        await runner.cleanup()
    service = sxm.Service.__new__(sxm.Service)
    service.now_playing = {"c1": SimpleNamespace(artist="ü" * 3000, title="ü" * 3000, show="", is_ad=False)}
    title = service.title_for("c1")
    assert len(f"StreamTitle='{title}';".encode()) <= 255 * 16, "the ICY title fits its block"
    print("ok: what's passed on to the panel is bounded")


asyncio.run(main())
