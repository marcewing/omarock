#!/usr/bin/env python3
"""Test omarock's audio bus on a throwaway PipeWire, never the real one.

    audio/test-bus.py

It starts its own pipewire and wireplumber: their own runtime, config and
state directories, a private D-Bus session, and WirePlumber's device monitors
off, so no sound card is opened. Its outputs are silent null sinks: the
speakers the bus is pinned to, a radio's audio interface (ranked last), an
unranked tunnel to another radio, and a laptop's own output. Silent players
stand in for mpd and Soloist. With the bus run as omarock-bus.service runs
it (its own pipewire process with omarock-bus.conf, pinned to the speakers)
and omarock-players.conf (PipeWire client config) from this folder, it
checks that:
- the bus plays into the card, and the players into the bus;
- the bus's volume can be set (omarock's one volume);
- the bus and the players can't be moved, to a radio or elsewhere;
- with the card gone the bus falls silent, never onto another output, and
  it plays into the card again when the card comes back;
- the bus is the default output only when nothing but a radio is left;
- with the bus stopped, the players wait silently, and go back to it when it
  starts again; with no bus at all, they wait silently, never falling back;
- omarock-guard cuts links made by hand into a radio, from the bus, its
  monitor or a player, and lets a recorder listen.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
CARD = "alsa_output.test-speakers"
RADIO = "alsa_output.test-radio-tx"
LAPTOP = "alsa_output.test-laptop"
# A tunnel to a radio that nobody ranked: with no priority.session, it counts
# as 0 and outranks the bus.
TUNNEL = "test-tunnel-tx"
PLAYERS = {"spotify": '{ node.name = "spotify" }', "mpd.omarock": '{ node.name = "mpd.omarock" }'}

if os.environ.get("OMAROCK_BUS_TEST") != "private":
    # Again, inside a private D-Bus session.
    os.execvp("dbus-run-session", ["dbus-run-session", "--", "env", "OMAROCK_BUS_TEST=private",
                                   sys.executable, "-I", __file__] + sys.argv[1:])

failures = []


def check(ok, message):
    print(("ok   " if ok else "FAIL ") + message, flush=True)
    if not ok: failures.append(message)


class Graph:
    """A private pipewire and wireplumber, with or without the bus."""

    def __init__(self, with_bus):
        self.work = Path(tempfile.mkdtemp(prefix="omarock-pw-"))
        run = self.work / "run"
        run.mkdir(mode=0o700)
        # A home of its own too: PipeWire also reads ~/.config/pipewire, and
        # other programs' drop-ins there (a silent output of their own, say)
        # mustn't change what this tests.
        (self.work / "home").mkdir()
        self.env = dict(os.environ, HOME=str(self.work / "home"), XDG_RUNTIME_DIR=str(run), XDG_CONFIG_HOME=str(self.work / "config"),
                        XDG_STATE_HOME=str(self.work / "state"), XDG_DATA_HOME=str(self.work / "data"),
                        GIO_USE_VFS="local", GVFS_DISABLE_FUSE="1")
        for key in ("PIPEWIRE_REMOTE", "PIPEWIRE_RUNTIME_DIR", "PULSE_SERVER", "PIPEWIRE_CONFIG_DIR"):
            self.env.pop(key, None)
        conf = self.work / "config"
        for d in ("pipewire/client.conf.d", "wireplumber/wireplumber.conf.d"):
            (conf / d).mkdir(parents=True)
        shutil.copy(HERE / "omarock-players.conf", conf / "pipewire/client.conf.d/50-omarock-players.conf")
        (conf / "wireplumber/wireplumber.conf.d/10-no-devices.conf").write_text(
            "wireplumber.profiles = { main = { monitor.alsa = disabled, monitor.alsa-midi = disabled,"
            " monitor.bluez = disabled, monitor.bluez-midi = disabled, monitor.v4l2 = disabled,"
            " monitor.libcamera = disabled } }\n")
        self.silence = self.work / "silence.wav"
        with wave.open(str(self.silence), "wb") as w:
            w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
            w.writeframes(b"\0" * 4 * 44100 * 300)
        logs = Path(os.environ.get("OMAROCK_BUS_LOGS", self.work))
        tag = "bus" if with_bus else "nobus"
        self.procs = [subprocess.Popen(["pipewire"], env=self.env, stdout=subprocess.DEVNULL,
                                       stderr=(logs / f"pipewire-{tag}.log").open("w"))]
        for _ in range(50):
            if (run / "pipewire-0").exists(): break
            time.sleep(0.1)
        self.procs.append(subprocess.Popen(["wireplumber"], env=self.env, stdout=subprocess.DEVNULL,
                                           stderr=(logs / f"wireplumber-{tag}.log").open("w")))
        time.sleep(2)
        self.bus = None
        if with_bus: self.start_bus()

    def start_bus(self):
        """The bus, as omarock-bus.service runs it: its own pipewire process."""
        # As tools/install-audio installs it: pinned to the (fake) card.
        conf = self.work / "omarock-bus.conf"
        conf.write_text((HERE / "omarock-bus.conf").read_text().replace("@OUTPUT@", CARD))
        self.bus = subprocess.Popen(["pipewire", "-c", str(conf)], env=self.env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(self.bus)
        time.sleep(1.5)

    def stop_bus(self):
        self.bus.terminate()
        self.bus.wait(timeout=5)

    def pw(self, *args):
        return subprocess.run(list(args), env=self.env, capture_output=True, text=True, timeout=20)

    def dump(self):
        objs = json.loads(self.pw("pw-dump").stdout or "[]")
        nodes = {o["id"]: (o.get("info") or {}).get("props") or {} for o in objs if o.get("type") == "PipeWire:Interface:Node"}
        links = {(nodes.get(o["info"]["output-node-id"], {}).get("node.name"), nodes.get(o["info"]["input-node-id"], {}).get("node.name"))
                 for o in objs if o.get("type") == "PipeWire:Interface:Link"}
        return nodes, links

    def names(self):
        return {p.get("node.name") for p in self.dump()[0].values()}

    def node_id(self, name):
        return next((i for i, p in self.dump()[0].items() if p.get("node.name") == name), None)

    def linked_from(self, name):
        return sorted(b for a, b in self.dump()[1] if a == name)

    def default_sink(self):
        for line in self.pw("pw-metadata", "-n", "default", "0", "default.audio.sink").stdout.splitlines():
            if "value:" in line:
                try: return json.loads(line.split("value:'", 1)[1].split("'", 1)[0]).get("name")
                except (IndexError, ValueError): pass
        return None

    def make_sink(self, name, priority, description):
        rank = "" if priority is None else f"priority.session = {priority} "
        self.pw("pw-cli", "create-node", "adapter",
                f'{{ factory.name = support.null-audio-sink node.name = "{name}" node.description = "{description}" '
                f'media.class = Audio/Sink audio.position = [ FL FR ] object.linger = true {rank}}}')

    def remove(self, name):
        i = self.node_id(name)
        if i is not None: self.pw("pw-cli", "destroy", str(i))

    def play(self, props):
        self.procs.append(subprocess.Popen(["pw-play", "--target", "omarock", "-P", props, str(self.silence)],
                                           env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

    def close(self):
        for p in reversed(self.procs):
            p.terminate()
            try: p.wait(timeout=5)
            except subprocess.TimeoutExpired: p.kill()
        shutil.rmtree(self.work, ignore_errors=True)


def settle(seconds=2):
    time.sleep(seconds)


g = Graph(with_bus=True)
try:
    nodes, _ = g.dump()
    check(not any(str(p.get("factory.name", "")).startswith("api.alsa") or "alsa.card" in p for p in nodes.values()),
          "the private PipeWire opened no sound card")
    g.make_sink(CARD, 1000, "FAKE speakers")
    g.make_sink(LAPTOP, 900, "FAKE laptop output")
    g.make_sink(RADIO, -1000, "FAKE radio interface (a radio)")
    g.make_sink(TUNNEL, None, "FAKE tunnel to a radio (unranked)")
    settle()
    check({"omarock", "omarock.output", CARD, RADIO, LAPTOP, TUNNEL} <= g.names(), "the bus and the fake outputs are up")
    check(g.linked_from("omarock.output") == [CARD], f"the bus plays into the card: {g.linked_from('omarock.output')}")
    check(g.default_sink() == CARD, f"the desktop's default output is the card, not the bus: {g.default_sink()}")
    for props in PLAYERS.values(): g.play(props)
    settle()
    for name in PLAYERS:
        check(g.linked_from(name) == ["omarock"], f"{name} plays into the bus: {g.linked_from(name)}")
    props = g.dump()[0][g.node_id("spotify")]
    check(str(props.get("node.dont-move")).lower() == "true" and str(props.get("node.dont-fallback")).lower() == "true",
          f"the players carry the lock: dont-move {props.get('node.dont-move')}, dont-fallback {props.get('node.dont-fallback')}")

    # A player's own volume isn't restored: it comes back at full.
    g.pw("wpctl", "set-volume", str(g.node_id("mpd.omarock")), "0.2")
    settle(1)
    old = [p for p in g.procs if p.args[:1] == ["pw-play"] and "mpd.omarock" in " ".join(p.args)][0]
    old.terminate(); old.wait(timeout=5)
    settle(1)
    g.play(PLAYERS["mpd.omarock"])
    settle()
    vol = g.pw("wpctl", "get-volume", str(g.node_id("mpd.omarock"))).stdout.strip()
    check(vol.startswith("Volume: 1.00") and g.linked_from("mpd.omarock") == ["omarock"],
          f"a player started again plays at full volume, into the bus: {vol}, {g.linked_from('mpd.omarock')}")

    g.pw("wpctl", "set-volume", str(g.node_id("omarock")), "0.37")
    vol = g.pw("wpctl", "get-volume", str(g.node_id("omarock"))).stdout.strip()
    check(vol.startswith("Volume: 0.37"), f"the bus's volume can be set: {vol}")

    for name in ["omarock.output"] + list(PLAYERS):
        g.pw("pw-metadata", str(g.node_id(name)), "target.object", RADIO)
    settle()
    check(g.linked_from("omarock.output") == [CARD], f"the bus can't be moved to the radio: {g.linked_from('omarock.output')}")
    check(all(g.linked_from(n) == ["omarock"] for n in PLAYERS),
          "the players can't be moved off the bus: " + ", ".join(f"{n} {g.linked_from(n)}" for n in PLAYERS))

    # The guard: links made by hand into the radio are cut; a recorder may listen.
    g.procs.append(subprocess.Popen([sys.executable, "-I", str(HERE / "omarock-guard.py")],
                                    env=dict(g.env, OMAROCK_GUARD_DEBUG=os.environ.get("OMAROCK_BUS_DEBUG", "")),
                                    stdout=subprocess.DEVNULL, stderr=(g.work / "guard.log").open("w")))
    settle()
    g.procs.append(subprocess.Popen(["pw-record", "--target", "omarock", "-P", '{ stream.capture.sink = true node.name = "visualizer" }',
                                     str(g.work / "rec.wav")], env=g.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    for out_port in ("omarock.output:output_FL", "omarock:monitor_FL", "spotify:output_FL"):
        g.pw("pw-link", out_port, RADIO + ":playback_FL")
    g.pw("pw-link", "mpd.omarock:output_FR", TUNNEL + ":playback_FR")
    settle()
    cuts = (g.work / "guard.log").read_text()
    check(not {RADIO, TUNNEL} & {b for _, b in g.dump()[1]}, "the guard cut every link made by hand into a radio: "
          + ", ".join(l.split(": ", 1)[1] for l in cuts.splitlines() if "cut link" in l))
    check(g.linked_from("omarock.output") == [CARD] and all(g.linked_from(n) == ["omarock"] for n in PLAYERS),
          "and left the bus's and players' own links alone")
    check("visualizer" in {b for a, b in g.dump()[1] if a == "omarock"}, "a recorder may still listen to the bus")
    # The Spotify desktop app (a "spotify" stream not aimed at the bus) isn't omarock's.
    desktop = subprocess.Popen(["pw-play", "--target", CARD, "-P", '{ node.name = "spotify" }', str(g.silence)],
                               env=g.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    g.procs.append(desktop)
    settle()
    objs = json.loads(g.pw("pw-dump").stdout)
    desktop_ids = [o["id"] for o in objs if o.get("type") == "PipeWire:Interface:Node"
                   and ((o.get("info") or {}).get("props") or {}).get("node.name") == "spotify"
                   and ((o.get("info") or {}).get("props") or {}).get("target.object") == CARD]
    desktop_links = [o for o in objs if o.get("type") == "PipeWire:Interface:Link" and o["info"]["output-node-id"] in desktop_ids]
    check(len(desktop_links) >= 1 and "spotify → " + CARD not in (g.work / "guard.log").read_text(),
          f"the guard leaves the Spotify desktop app's link to the card alone ({len(desktop_links)} links)")
    desktop.terminate(); desktop.wait(timeout=5)
    # Soloist (by its program, "soloist") is guarded wherever it's aimed: a
    # stand-in under that name, aimed at the radio by mistake.
    fake = g.work / "soloist"
    shutil.copy(shutil.which("pw-cat"), fake)  # PipeWire names the program from the executable
    log_before = len((g.work / "guard.log").read_text())
    stray = subprocess.Popen([str(fake), "--playback", "--target", RADIO, "-P", '{ node.name = "spotify" }', str(g.silence)],
                             env=g.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    g.procs.append(stray)
    settle(3)
    objs = json.loads(g.pw("pw-dump").stdout)
    nodes = {o["id"]: ((o.get("info") or {}).get("props") or {}) for o in objs if o.get("type") == "PipeWire:Interface:Node"}
    stray_into = [nodes.get(o["info"]["input-node-id"], {}).get("node.name") for o in objs
                  if o.get("type") == "PipeWire:Interface:Link" and nodes.get(o["info"]["output-node-id"], {}).get("target.object") == RADIO]
    binaries = {((o.get("info") or {}).get("props") or {}).get("application.process.binary") for o in objs
                if o.get("type") == "PipeWire:Interface:Client"}
    cut_lines = [l for l in (g.work / "guard.log").read_text()[log_before:].splitlines()
                 if "cut link" in l and "spotify →" in l and RADIO in l]
    check("soloist" in binaries and RADIO not in stray_into and len(cut_lines) >= 1,
          f"a Soloist aimed at the radio by mistake is cut off it: links {stray_into}, "
          f"programs seen {sorted(b for b in binaries if b)}, cuts {len(cut_lines)}")
    if os.environ.get("OMAROCK_BUS_DEBUG") or not cut_lines:
        print("\n".join(l for l in (g.work / "guard.log").read_text()[log_before:].splitlines() if f"omarock.output [pipewire] → {CARD}" not in l and "→ omarock: True" not in l))
        print([((o.get("info") or {}).get("props") or {}) for o in objs if o.get("type") == "PipeWire:Interface:Node"
               and ((o.get("info") or {}).get("props") or {}).get("target.object") == RADIO])
    stray.terminate(); stray.wait(timeout=5)

    g.remove(CARD)
    settle()
    check(g.linked_from("omarock.output") == [], f"with the card gone, the bus plays into nothing: {g.linked_from('omarock.output')}")
    check(all(g.linked_from(n) == ["omarock"] for n in PLAYERS), "and the players stay on the bus")
    check(g.default_sink() == LAPTOP, f"the desktop's default goes to the laptop output, not the radio: {g.default_sink()}")
    g.remove(LAPTOP)
    settle()
    check(g.linked_from("omarock.output") == [] and all(g.linked_from(n) == ["omarock"] for n in PLAYERS),
          f"with only radios left, the bus still plays into nothing: {g.linked_from('omarock.output')}")
    # The desktop's default is then the unranked radio tunnel (the business of
    # whatever set it up), or the silent bus if every radio is ranked.
    print(f"     (the desktop's default with only radios left: {g.default_sink()})", flush=True)
    g.remove(TUNNEL)
    settle(3)
    check(g.default_sink() == "omarock", f"with only ranked radios left, the desktop's default is the silent bus: {g.default_sink()}")
    g.make_sink(CARD, 1000, "FAKE speakers")
    settle(3)
    check(g.linked_from("omarock.output") == [CARD], f"the card back, the bus plays into it again: {g.linked_from('omarock.output')}")

    # The bus's service stopped, then started again.
    g.stop_bus()
    settle()
    check("omarock" not in g.names() and all(g.linked_from(n) == [] for n in PLAYERS),
          "with the bus stopped, the players wait silently: " + ", ".join(f"{n} {g.linked_from(n)}" for n in PLAYERS))
    g.start_bus()
    settle()
    check(g.linked_from("omarock.output") == [CARD] and all(g.linked_from(n) == ["omarock"] for n in PLAYERS),
          "the bus started again: the players play into it, and it into the card")
finally:
    g.close()

g = Graph(with_bus=False)
try:
    g.make_sink(CARD, 1000, "FAKE speakers")
    g.make_sink(RADIO, -1000, "FAKE radio interface (a radio)")
    settle()
    for props in PLAYERS.values(): g.play(props)
    settle()
    check("omarock" not in g.names(), "no bus in the second graph")
    check(all(g.linked_from(n) == [] for n in PLAYERS) and all(n in g.names() for n in PLAYERS),
          "with no bus, the players wait silently, not on the default output: "
          + ", ".join(f"{n} {g.linked_from(n)}" for n in PLAYERS))
finally:
    g.close()

print(f"\n{len(failures)} failure(s)")
sys.exit(1 if failures else 0)
