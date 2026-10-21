"""The relay's listeners: run with the service's venv,
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


asyncio.run(main())
