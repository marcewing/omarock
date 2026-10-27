"""The relay's listeners, the login's wait for the network, and that only
omarock's own requests are answered: run with the service's venv,
~/.local/share/omarock/sxm-venv/bin/python sxm/test_relay.py"""
import asyncio
import importlib.util
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
    finally:
        await runner.cleanup()
    print("ok: only omarock's own requests")


asyncio.run(main())
