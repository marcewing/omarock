#!/usr/bin/env python3
"""omarock-guard: omarock's sound goes where its bus says, and nowhere else.

The bus (omarock-bus.conf) and the players' settings (omarock-players.conf)
keep omarock's sound on one path: mpd and Spotify's Soloist into the
"omarock" bus, and the bus into one pinned output, your speakers, never an
output that must not carry music (a radio's). Those settings stop
WirePlumber and mixers from moving it. They can't stop a link made by hand
(pw-link, a patchbay), so this watches PipeWire's links as they're made and
cuts any that carry omarock's sound elsewhere:
- from a player (mpd.*; Spotify's Soloist, by its program, wherever it's
  aimed; or "spotify" aimed at the bus): only into the bus;
- from the bus's output: only into the output its own target.object names;
- from the bus's monitor: only into recorders (Stream/Input/Audio, such as a
  visualiser), never into another output.
Recorders may listen anywhere. Each cut is logged (the journal, as a user
service) and shown as a desktop notification, at most once per ten minutes
for the same source and output.

    omarock-guard.py            watch until stopped
    OMAROCK_GUARD_DEBUG=1 ...   also log every link it judges
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

BUS = "omarock"
BUS_OUTPUT = "omarock.output"
MPD = re.compile(r"^mpd[.].*$")
NOTIFY_EVERY = 600  # seconds, for the same source and output


def log(message):
    print("omarock-guard: " + message, file=sys.stderr, flush=True)


def notify(message):
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-u", "critical", "-a", "omarock", "omarock cut an audio link", message],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Graph:
    def __init__(self):
        self.objects = {}

    def update(self, items):
        for item in items:
            if item.get("info") is None:
                self.objects.pop(item["id"], None)
            else:
                merged = self.objects.get(item["id"], {})
                merged.update(item)
                self.objects[item["id"]] = merged

    def binary(self, props):
        """The program behind a node: its client's application.process.binary."""
        try: client = self.objects.get(int(props.get("client.id")))
        except (TypeError, ValueError): return ""
        return (((client or {}).get("info") or {}).get("props") or {}).get("application.process.binary", "")

    def node(self, node_id):
        o = self.objects.get(node_id)
        return ((o or {}).get("info") or {}).get("props") or {} if o and o.get("type") == "PipeWire:Interface:Node" else None

    def links(self):
        return [o for o in self.objects.values() if o.get("type") == "PipeWire:Interface:Link" and o.get("info")]


def allowed(source, sink, program=""):
    """Whether a link from node props source into sink may carry omarock's
    sound; program is the source's process (soloist: Spotify's, for omarock)."""
    name = source.get("node.name", "")
    into = sink.get("node.name", "")
    if sink.get("media.class") == "Stream/Input/Audio":
        return True  # a recorder or visualiser listening
    if MPD.match(name) or program == "soloist" or (name == "spotify" and source.get("target.object") == BUS):
        return into == BUS
    if name == BUS_OUTPUT:
        return into != "" and into == source.get("target.object")
    if name == BUS:
        return False  # the bus's monitor, into anything but a recorder
    return True


notified = {}


def check(graph, cut):
    """cut: the links already cut, by object.serial: PipeWire reuses a removed
    object's id, so a new link can carry an id that was cut before."""
    for link in graph.links():
        info = link["info"]
        serial = (info.get("props") or {}).get("object.serial", ("id", link["id"]))
        source, sink = graph.node(info.get("output-node-id")), graph.node(info.get("input-node-id"))
        if source is None or sink is None or serial in cut:
            continue
        ok = allowed(source, sink, graph.binary(source))
        if os.environ.get("OMAROCK_GUARD_DEBUG"):
            log(f"link {link['id']}: {source.get('node.name')} [{graph.binary(source)}] → {sink.get('node.name')}: {ok}")
        if not ok:
            cut.add(serial)
            what = f"{source.get('node.name')} → {sink.get('node.name')} ({sink.get('node.description', '')})"
            result = subprocess.run(["pw-cli", "destroy", str(link["id"])], capture_output=True, text=True)
            log(f"cut link {link['id']}: {what}" + ("" if result.returncode == 0 else f" (pw-cli: {result.stderr.strip()})"))
            pair = (source.get("node.name"), sink.get("node.name"))
            if time.monotonic() - notified.get(pair, -NOTIFY_EVERY) >= NOTIFY_EVERY:
                notified[pair] = time.monotonic()
                notify(what)


def main():
    graph = Graph()
    cut = set()
    monitor = subprocess.Popen(["pw-dump", "--monitor", "--no-colors"], stdout=subprocess.PIPE, text=True)
    decoder = json.JSONDecoder()
    buffer = ""
    log("watching")
    for chunk in iter(lambda: monitor.stdout.readline(), ""):
        buffer += chunk
        while True:
            text = buffer.lstrip()
            if not text:
                buffer = ""
                break
            try:
                items, end = decoder.raw_decode(text)
            except ValueError:
                break  # an array still arriving
            buffer = text[end:]
            if isinstance(items, list):
                graph.update(items)
                check(graph, cut)
    sys.exit(monitor.wait() or 1)


if __name__ == "__main__":
    main()
