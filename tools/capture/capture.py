#!/usr/bin/python3
"""Run omarock's real panel offscreen against a fake mpd, check it, and save
screenshots.

Never touches the real mpd, the live bar or your HOME: it runs Quickshell
offscreen with a temporary HOME, theme and runtime directory, and serves
tools/capture/fake_mpd.py on the socket the panel looks for. Fails if the
panel logs a QML error or sends mpd an output command.

    tools/capture/capture.py [output-dir]
    tools/capture/capture.py --real-mpd [output-dir]
    tools/capture/capture.py --scratch-mpd MUSIC_DIR [output-dir]

--real-mpd points the panel at the real mpd socket instead, and only opens the
panel and searches: reads, never a play, add or remove.

--scratch-mpd starts a throwaway mpd of its own (a temporary database, playlist
directory and socket; its only output is mpd's "null" output, which plays to
nowhere) over MUSIC_DIR, e.g. one artist's folder, and runs the playlist
scenario against real mpd behaviour: it makes, plays, edits and deletes stored
playlists there. Your mpd, its playlists and its config are not touched.

The approach follows crmne.mpris's tools/capture (MIT).
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
import time

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(__file__).resolve().parent
PLUGIN_FILES = ["BarWidget.qml", "Panel.qml", "MpdClient.qml", "Mpd.js", "PlayerCard.qml",
                "TrackRow.qml", "CoverArt.qml", "KeysHelp.qml", "PlaylistPicker.qml", "manifest.json",
                "Apple.js", "AppleClient.qml", "Sxm.js", "SxmClient.qml", "Radio.js", "RadioClient.qml", "Info.js", "InfoCard.qml"]
THEME = "/usr/share/omarchy/themes/ristretto/colors.toml"
OUTPUT_COMMANDS = ("enableoutput", "disableoutput", "toggleoutput", "outputset")
# The fake Apple Music bridge, when one runs: { port, log }.
BRIDGE = {}


def wait_for(predicate, description, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate(): return
        time.sleep(.1)
    raise RuntimeError("Timed out: " + description)


def complete_png(path):
    if not path.exists() or path.stat().st_size < 12: return False
    with path.open("rb") as image:
        image.seek(-12, 2)
        return image.read() == b'\x00\x00\x00\x00IEND\xaeB`\x82'


def prepare(work):
    home, shell, plugin = (work / name for name in ["home", "shell", "plugin"])
    # A short private runtime directory: it holds Quickshell's IPC socket and
    # the fake mpd's socket, and unix socket paths are length-limited.
    runtime = Path(tempfile.mkdtemp(prefix="omarock-", dir=os.environ.get("XDG_RUNTIME_DIR")))
    shell.mkdir()
    plugin.mkdir()
    theme = home / ".local/state/omarchy/current/next-theme"
    theme.mkdir(parents=True)
    shutil.copy(THEME, theme / "colors.toml")
    env = dict(HOME=str(home), PATH="/usr/bin:/bin", LANG="C.UTF-8",
               XDG_RUNTIME_DIR=str(runtime), OMARCHY_PATH="/usr/share/omarchy")
    subprocess.run(["omarchy-theme-set-templates"], env=env, check=True, stdout=subprocess.DEVNULL)
    shutil.copytree(theme, theme.with_name("theme"))
    fonts = home / ".config/fontconfig"
    fonts.mkdir(parents=True)
    (fonts / "fonts.conf").write_text('''<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd"><fontconfig>
<match target="pattern"><test name="family"><string>monospace</string></test>
<edit name="family" mode="assign" binding="strong"><string>JetBrainsMono Nerd Font</string></edit></match>
</fontconfig>''')
    for name in ["Commons", "Ui"]:
        shutil.copytree(Path("/usr/share/omarchy/shell") / name, shell / name)
    for name in PLUGIN_FILES:
        shutil.copy(ROOT / name, plugin / name)
    # Offscreen Quickshell has no layer shell: swap in a KeyboardPanel that
    # draws the same card in an ordinary window.
    shutil.copy(TOOLS / "KeyboardPanel.qml", shell / "Ui/KeyboardPanel.qml")
    shutil.copy(TOOLS / "shell.qml", shell / "shell.qml")
    return env, shell, plugin, runtime


class Host:
    def __init__(self, env, shell):
        self.env, self.shell = env, shell

    def call(self, method, *args, quiet=False):
        result = subprocess.run(["qs", "ipc", "-p", str(self.shell), "call", "--", "capture", method,
                                 *map(str, args)], env=self.env, capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            if not quiet: print(result.stderr, file=sys.stderr, flush=True)
            return ""
        return result.stdout.strip()

    def state(self):
        return json.loads(self.call("state"))

    def settle(self, seconds=.6):
        time.sleep(seconds)

    def grab(self, path):
        path.unlink(missing_ok=True)
        result = self.call("grab", str(path))
        if result != "ok": raise RuntimeError(path.name + ": " + result)
        wait_for(lambda: complete_png(path), path.name)

    def grab_bar(self, path):
        path.unlink(missing_ok=True)
        result = self.call("grabBar", str(path))
        if result != "ok": raise RuntimeError(path.name + ": " + result)
        wait_for(lambda: complete_png(path), path.name)

    def click_bar(self, name, middle=False):
        result = self.call("clickBar", name, "true" if middle else "false")
        if result != "ok": raise RuntimeError("bar " + name + ": " + result)

    def hover(self, x, y):
        result = self.call("hover", round(x), round(y))
        if result != "ok": raise RuntimeError("hover: " + result)

    def card(self):
        return json.loads(self.call("cardSize"))
        print("saved", path, file=sys.stderr, flush=True)


def mpd_query(socket_path, command):
    """One command's reply lines, as another client sees them."""
    import socket
    s = socket.socket(socket.AF_UNIX)
    s.connect(str(socket_path))
    f = s.makefile("rb")
    f.readline()
    s.sendall((command + "\n").encode())
    lines = []
    for raw in f:
        line = raw.decode("utf-8").rstrip("\n")
        if line == "OK" or line.startswith("ACK"): break
        lines.append(line)
    s.close()
    return lines


def stored(socket_path, name):
    """A stored playlist's files, read straight from mpd."""
    return [line[6:] for line in mpd_query(socket_path, 'listplaylist "%s"' % name) if line.startswith("file: ")]


def mpd_client(socket_path, *commands):
    """Act as another mpd client (like mpc), to check the panel follows along."""
    import socket
    s = socket.socket(socket.AF_UNIX)
    s.connect(str(socket_path))
    f = s.makefile("rb")
    f.readline()
    for command in commands:
        s.sendall((command + "\n").encode())
        for line in f:
            if line == b"OK\n" or line.startswith(b"ACK"): break
    s.close()


def check(condition, message, failures):
    print(("ok   " if condition else "FAIL ") + message, file=sys.stderr, flush=True)
    if not condition: failures.append(message)


def scenarios(host, output, socket_path, command_log, failures):
    host.call("open")
    wait_for(lambda: host.state()["coverUrl"] != "", "cover for the current song")
    host.settle(1)
    s = host.state()
    check(s["connected"] and s["opened"], "panel opens connected", failures)
    check(s["nowPlaying"] == "Paper Lanterns · Glass Harbor", "now playing: " + s["nowPlaying"], failures)
    check(s["stateText"] == "Playing · song 2 of 9", "state line: " + s["stateText"], failures)
    check(s["coverUrl"].endswith("/Glass%20Harbor/Low%20Tide%20Signals/cover.png"), "cover found by listfiles", failures)
    check(len(s["rows"]) == 9 and s["rows"][0] == "queue:Glasswork", "queue shows 9 songs", failures)
    host.grab(output / "compact.png")

    # Accent-insensitive search: "flugel" finds Flügel Café.
    host.call("type", "flugel")
    wait_for(lambda: not host.state()["searching"], "search results")
    host.settle()
    s = host.state()
    check("artist:Flügel Café" in s["rows"] and "album:Nachtzug" in s["rows"],
          "'flugel' finds the artist and album: " + ", ".join(s["rows"][:4]), failures)
    host.call("move", 1)
    host.call("move", 1)
    host.settle()
    host.grab(output / "compact-search.png")

    # Enter on the album: the queue becomes that album, playing.
    album = s["rows"].index("album:Nachtzug")
    host.call("activate", album, "play")
    wait_for(lambda: host.state()["nowPlaying"].startswith("Nachtzug"), "album playing")
    host.settle()
    s = host.state()
    check(s["query"] == "" and len(s["rows"]) == 4, "playing an album replaces the queue (4 songs)", failures)
    check(s["notice"] == "Playing Nachtzug", "says what it did: " + s["notice"], failures)
    host.grab(output / "compact-playing-album.png")

    # Another client skips; the panel follows through idle.
    mpd_client(socket_path, "next")
    wait_for(lambda: host.state()["nowPlaying"].startswith("Über den Dächern"), "follows mpc next")
    check(True, "follows another client's 'next'", failures)

    # A song from search: Add appends, the queue grows.
    host.call("type", "uber")
    wait_for(lambda: not host.state()["searching"], "song search")
    host.settle()
    s = host.state()
    song = s["rows"].index("song:Über den Dächern")
    host.call("activate", song, "add")
    host.settle()
    check(host.state()["notice"] == "Added Über den Dächern to the queue", "add says what it did", failures)
    host.call("back")
    host.settle()
    check(len(host.state()["rows"]) == 5, "added song is in the queue (5 songs)", failures)

    browse_scenario(host, output, command_log, failures)
    columns_scenario(host, output, command_log, failures)
    playlists_scenario(host, output, socket_path, failures)

    host.call("keys", "true")
    host.settle()
    host.grab(output / "compact-keys.png")
    host.call("keys", "false")

    host.call("expand", "true")
    host.settle(1)
    host.grab(output / "expanded.png")
    host.call("type", "glass")
    wait_for(lambda: not host.state()["searching"], "expanded search")
    host.settle()
    host.grab(output / "expanded-search.png")
    host.call("back")
    host.call("expand", "false")

    bar_scenario(host, output, socket_path, failures)
    leave_scenario(host, failures)
    apple_scenario(host, output, socket_path, failures)
    spotify_scenario(host, output, socket_path, failures)
    sxm_scenario(host, output, socket_path, failures)
    radio_scenario(host, output, socket_path, failures)
    radio_tuning_scenario(host, socket_path, failures)
    info_scenario(host, output, socket_path, failures)
    list_tuning_scenario(host, failures)
    favourite_follow_scenario(host, output, failures)
    apple_idle_scenario(host, socket_path, failures)

    # mpd goes away: the panel says so instead of failing silently.
    host.call("close")
    # Last, as it unloads the widget.
    sources_switch_scenario(host, socket_path, failures)
    fresh_start_scenario(host, socket_path, failures)
    teardown_scenario(host, socket_path, failures)


def bar_scenario(host, output, socket_path, failures):
    """The bar: cover and Artist — Song, no transport buttons; a middle
    click plays and pauses. With an empty queue, the note, and a middle click
    on it plays a song picked at random."""
    host.call("close")
    host.settle(.3)
    s = host.state()
    check(s["bar"]["showSong"] and s["bar"]["text"] == s["nowPlaying"].split(" · ")[1] + " — " + s["nowPlaying"].split(" · ")[0],
          "the bar shows Artist — Song: " + s["bar"]["text"], failures)
    check(all(host.call("clickBar", name, "false") == "not shown" for name in ("previous", "playPause", "next")),
          "no ⏮ ⏯ ⏭ in the bar", failures)
    # The bar underlines the widget while the panel is open: across the
    # cover and the song, not the bar's default 55%.
    b = s["bar"]
    check(b["indicatorWidth"] >= b["coverWidth"] + b["songWidth"] and b["indicatorWidth"] <= b["width"],
          f"the open-panel underline spans the cover and the song: {b['indicatorWidth']} of {b['width']}", failures)
    host.grab_bar(output / "bar.png")
    host.click_bar("song", middle=True)
    wait_for(lambda: not host.state()["bar"]["playing"], "bar pause")
    host.grab_bar(output / "bar-paused.png")
    host.click_bar("cover", middle=True)
    wait_for(lambda: host.state()["bar"]["playing"], "bar play")
    check(not host.state()["opened"], "a middle click pauses and plays, and doesn't open the panel", failures)
    host.click_bar("song")
    wait_for(lambda: host.state()["opened"], "panel from the bar")
    check(True, "a click on the song opens the panel", failures)
    host.click_bar("cover")
    wait_for(lambda: not host.state()["opened"], "panel closed from the bar")
    check(True, "a click on the cover closes it again", failures)

    mpd_client(socket_path, "clear")
    wait_for(lambda: host.state()["bar"]["queueEmpty"] and not host.state()["bar"]["showSong"], "empty queue")
    host.grab_bar(output / "bar-empty.png")
    check("play a song at random" in host.state()["bar"]["tooltip"], "the note's tooltip says what a middle click does", failures)
    host.click_bar("note", middle=True)
    wait_for(lambda: host.state()["bar"]["showSong"] and host.state()["bar"]["playing"], "a random song")
    s = host.state()
    check(s["queueLength"] == 1, "a middle click on an empty queue plays one random song: " + s["bar"]["text"], failures)
    host.grab_bar(output / "bar-random.png")


def to_source(host, name):
    """Press m until the panel's source is `name`: m goes round the sources,
    on past one that fails (switched on, not set up)."""
    for _ in range(2 * len(host.state()["sources"]) + 1):
        before = host.state()["source"]
        if before == name: return
        host.call("press", "m")
        try:
            wait_for(lambda: host.state()["source"] != before, "source changes from " + before, timeout=6)
        except RuntimeError:
            pass  # that one failed; the next m goes past it
    raise RuntimeError("couldn't get to source " + name)


def bridge_requests(path_prefix=""):
    """The fake bridge's requests so far: [(method, path, body)]."""
    lines = BRIDGE["log"].read_text().splitlines() if BRIDGE["log"].exists() else []
    return [(r["method"], r["path"], r["body"]) for r in map(json.loads, lines) if r["path"].startswith(path_prefix)]


def mpd_state(socket_path):
    return dict(line.split(": ", 1) for line in mpd_query(socket_path, "status"))


def mpd_files(socket_path):
    return [line[6:] for line in mpd_query(socket_path, "playlistinfo") if line.startswith("file: ")]


def spotify_requests(path_prefix=""):
    """The fake omarock-spotify's requests so far: [(method, path, body)]."""
    path = BRIDGE["spotify_log"]
    lines = path.read_text().splitlines() if path.exists() else []
    return [(r["method"], r["path"], r["body"]) for r in map(json.loads, lines) if r["path"].startswith(path_prefix)]


def spotify_post(path, body=None):
    """As another client (omarock-sp, or a phone through Spotify Connect)."""
    request = urllib.request.Request(BRIDGE["spotify"] + path, data=json.dumps(body or {}).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=5) as reply:
        return json.loads(reply.read())


def spotify_scenario(host, output, socket_path, failures):
    """Spotify against the fake omarock-spotify: the switch (mpd pauses and
    Spotify carries on), its queue, search, a playlist whose songs Spotify
    won't list, no removing from its queue, the info card, mpd taking over,
    Spotify started from elsewhere, and back to local where it was."""
    host.call("open")
    wait_for(lambda: host.state()["opened"] and "spotify" in host.state()["sources"], "Spotify among the sources")
    host.settle(.5)
    s = host.state()
    check("spotify" in s["sources"] and s["sources"].index("spotify") == s["sources"].index("apple" if "apple" in s["sources"] else "local") + 1
          and s["source"] == "local", "with omarock-spotify running, Spotify is a source, after Apple Music: " + str(s["sources"]), failures)
    before = s
    local_files = mpd_files(socket_path)
    local = mpd_state(socket_path)
    if local["state"] != "play":
        mpd_client(socket_path, "play")
        wait_for(lambda: mpd_state(socket_path)["state"] == "play", "local music plays")

    # m (or the switch, when Apple Music comes first): Spotify becomes the
    # source; mpd pauses where it was, Spotify plays on.
    if s["sources"][1] == "spotify": host.call("press", "m")
    else: host.call("setSource", "spotify")
    wait_for(lambda: host.state()["spotifyMode"] and host.state()["bar"]["playing"], "Spotify mode")
    host.settle(.5)
    s = host.state()
    check(spotify_requests("/v1/activate"), "m asks omarock-spotify to make Spotify the source", failures)
    check(mpd_state(socket_path)["state"] == "pause" and mpd_files(socket_path) == local_files,
          "mpd pauses on its song, its queue untouched", failures)
    check(s["source"] == "spotify" and s["stateText"].startswith("Spotify · Playing · song 1 of 3")
          and s["nowPlaying"] == "New Day Rising · Hüsker Dü",
          "the panel shows Spotify's song: " + s["nowPlaying"] + " | " + s["stateText"], failures)
    check(s["rows"] == ["queue:New Day Rising", "queue:Girl Who Lives on Heaven Hill", "queue:Celebrated Summer"],
          "the queue is Spotify's", failures)
    check(s["bar"]["text"] == "Hüsker Dü — New Day Rising" and "/art/c9a227/" in s["bar"]["cover"],
          "the bar shows Spotify's song and cover", failures)
    host.grab(output / "compact-spotify.png")

    # x on its queue: Spotify can't, and says so; no x in the hints.
    host.call("press", "Down")
    check("x remove" not in host.state()["hint"], "no x remove in Spotify's queue: " + host.state()["hint"], failures)
    host.call("press", "x")
    wait_for(lambda: "can't take songs out" in host.state()["notice"], "x refused")
    check(not spotify_requests("/v1/queue/remove"), "x asks nothing of omarock-spotify", failures)
    # Enter on a queue row jumps; mpd isn't asked to play anything.
    playids = command_count(socket_path, "playid")
    host.call("press", "Return")
    wait_for(lambda: spotify_requests("/v1/queue/jump"), "jump")
    host.settle(2.5)
    check(command_count(socket_path, "playid") == playids and mpd_state(socket_path)["state"] == "pause",
          "a jump in Spotify leaves mpd alone (no stream to rejoin)", failures)

    # Search: your library, then Spotify's catalog; no genres.
    host.call("press", "/")
    host.call("typeKeys", "husker")
    wait_for(lambda: host.state()["query"] == "husker" and not host.state()["searching"], "Spotify search")
    s = host.state()
    check(s["sections"][:3] == ["YOUR ALBUMS", "SPOTIFY · ARTISTS", "SPOTIFY · ALBUMS"] and "GENRES" not in s["sections"],
          "search: your library, then Spotify: " + ", ".join(x for x in s["sections"] if x), failures)
    # Esc clears the search; the box keeps the keys, so type on.
    host.call("press", "Escape")
    host.call("typeKeys", "punk ess")
    wait_for(lambda: host.state()["query"] == "punk ess" and not host.state()["searching"], "playlist search")
    host.call("press", "Down")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "playlist:Punk Essentials"), "Spotify playlist")
    s = host.state()
    check(s["rows"] == ["playplaylist:Play the playlist", "note:Its songs aren't listed"],
          "a playlist Spotify won't list: Play, and why: " + ", ".join(s["rows"]), failures)
    host.call("press", "Up")
    host.call("press", "Return")
    wait_for(lambda: spotify_requests("/v1/play"), "play the playlist")
    check(spotify_requests("/v1/play")[-1][2] == {"items": [{"kind": "playlist", "id": "c-pl-1", "source": "catalog"}],
                                                  "mode": "play", "start": 0},
          "it still plays: " + json.dumps(spotify_requests("/v1/play")[-1][2]), failures)
    wait_for(lambda: host.state()["browse"] == "" and host.state()["nowPlaying"].startswith("Something I Learned"), "playing")

    # P: Spotify playlists.
    host.call("press", "P")
    wait_for(lambda: browsed(host, "playlists:Spotify playlists"), "Spotify playlists")
    check(host.state()["rows"][1:] == ["playlist:PunkRock", "playlist:Road Songs"], "P lists your Spotify playlists", failures)
    host.call("press", "Escape")

    # i: what's playing, from Spotify, and whether it's in the library.
    host.call("press", "i")
    wait_for(lambda: host.state()["info"] and not host.state()["info"]["loading"], "Spotify info")
    info = host.state()["info"]
    check(info["service"] == "Spotify" and info["title"] == "Something I Learned Today",
          "i: the card says Spotify: " + info["service"] + " · " + info["title"], failures)
    host.call("press", "Escape")

    # Space pauses Spotify only.
    host.call("press", "Space")
    wait_for(lambda: not host.state()["bar"]["playing"], "Space pauses Spotify")
    check(spotify_requests("/v1/pause") and mpd_state(socket_path)["state"] == "pause", "Space pauses Spotify, not mpd", failures)
    check(host.state()["source"] == "spotify", "paused, Spotify is still the source", failures)

    # mpd plays (mpc, the media keys): it's the source again.
    mpd_client(socket_path, "play")
    wait_for(lambda: host.state()["source"] == "local", "mpd takes over")
    check(not host.state()["spotifyMode"], "mpd playing makes local the source", failures)
    # Spotify started from elsewhere (a phone): it's the source, mpd pauses.
    spotify_post("/v1/resume")
    wait_for(lambda: host.state()["source"] == "spotify", "Spotify takes over")
    wait_for(lambda: mpd_state(socket_path)["state"] == "pause", "mpd pauses")
    check(True, "Spotify starting from elsewhere makes it the source, and mpd pauses", failures)

    # The switch, to local: Spotify pauses and steps aside; local plays on.
    host.call("setSource", "local")
    wait_for(lambda: host.state()["source"] == "local" and mpd_state(socket_path)["state"] == "play", "back to local")
    s = host.state()
    check(spotify_requests("/v1/release") and not s["spotifyMode"], "switching away releases Spotify", failures)
    check(s["nowPlaying"] == before["nowPlaying"] and mpd_files(socket_path) == local_files,
          "local music plays on where it was: " + s["nowPlaying"], failures)
    host.call("close")


def apple_scenario(host, output, socket_path, failures):
    """Apple Music mode against the fake bridge: the switch, search, browsing
    into an artist and an album, playing, the queue, playlists, mpd's pause
    (the media keys), and back to local music where it was."""
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    stream = url + "/omarock.ogg"
    # Set up as the bridge's README says: ~/.config/omarock/apple.json, next to the token.
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": stream}))
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    host.settle(.5)
    before = host.state()
    local_files = mpd_files(socket_path)
    local_song = int(mpd_state(socket_path)["song"])

    # m: the stream goes in after the local song and plays; the Mac resumes.
    host.call("press", "m")
    wait_for(lambda: host.state()["appleMode"] and host.state()["bar"]["playing"], "Apple Music mode")
    host.settle(.5)
    s = host.state()
    files = mpd_files(socket_path)
    check(files == local_files[:local_song + 1] + [stream] + local_files[local_song + 1:],
          "m puts the bridge's stream after the local song in mpd's queue", failures)
    check(mpd_state(socket_path)["state"] == "play" and int(mpd_state(socket_path)["song"]) == local_song + 1,
          "mpd plays the stream", failures)
    check(("POST", "/v1/resume", {}) in bridge_requests("/v1/resume"), "switching resumes Apple Music", failures)
    check(s["nowPlaying"] == "New Day Rising · Hüsker Dü" and s["stateText"].startswith("Apple Music · Playing · song 1 of 3"),
          "the panel shows Apple Music's song: " + s["nowPlaying"] + " | " + s["stateText"], failures)
    check("/art/c9a227/720x720bb.png" in s["coverUrl"], "the cover is Apple's artwork: " + s["coverUrl"], failures)
    check(s["rows"] == ["queue:New Day Rising", "queue:Girl Who Lives on Heaven Hill", "queue:Celebrated Summer"],
          "the queue is Apple Music's", failures)
    check(s["bar"]["text"] == "Hüsker Dü — New Day Rising" and "/art/c9a227/" in s["bar"]["cover"],
          "the bar shows Apple Music's song and cover", failures)
    host.grab(output / "compact-apple.png")
    host.call("close")
    host.settle(.3)
    host.grab_bar(output / "bar-apple.png")
    host.call("open")
    host.settle(.3)

    # Search: your library first, then Apple Music, without duplicates.
    host.call("press", "/")
    host.call("typeKeys", "husker")
    wait_for(lambda: host.state()["query"] == "husker" and not host.state()["searching"], "Apple search")
    host.settle(.3)
    s = host.state()
    check(s["rows"][:3] == ["album:Zen Arcade", "artist:Hüsker Dü", "album:New Day Rising"]
          and s["sections"][:3] == ["YOUR ALBUMS", "APPLE MUSIC · ARTISTS", "APPLE MUSIC · ALBUMS"]
          and "album:Zen Arcade" not in s["rows"][1:],
          "search lists your library first, then Apple Music: " + ", ".join(s["rows"][:5]), failures)
    host.grab(output / "compact-apple-search.png")

    # → into the artist: top songs, albums by year, singles.
    host.call("press", "Down")
    host.call("press", "Down")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "artist:Hüsker Dü"), "Apple artist")
    s = host.state()
    check(s["rows"][0] == "playall:Play top songs" and "SINGLES & EPS" in s["sections"]
          and s["rows"][s["sections"].index("ALBUMS")] == "album:Zen Arcade",
          "the artist view: " + ", ".join(s["rows"]), failures)
    # → into Zen Arcade, then Enter on its third song plays the album from it.
    for _ in range(s["sections"].index("ALBUMS") - s["cursor"]): host.call("press", "Down")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "album:Zen Arcade"), "Apple album")
    s = host.state()
    check(s["rows"] == ["playalbum:Play the album", "track:Something I Learned Today", "track:Broken Home, Broken Heart",
                        "track:Chartered Trips", "track:Turn On the News 󰬌"] and s["sections"][1] == "DISC 1"
          and s["sections"][3] == "DISC 2", "the album view, by disc: " + ", ".join(s["rows"]), failures)
    check("SST Records" in s["browseInfo"].get("detail", ""), "the album's label shows", failures)
    host.call("expand", "true")
    host.settle(1)
    host.grab(output / "expanded-apple-album.png")
    host.call("expand", "false")
    host.settle(.5)
    host.call("press", "Down")
    host.call("press", "Down")
    host.call("press", "Return")
    wait_for(lambda: host.state()["nowPlaying"].startswith("Chartered Trips"), "Apple play from a song")
    play = bridge_requests("/v1/play")[-1][2]
    check(play == {"items": [{"kind": "album", "id": "c-al-1", "source": "catalog"}], "mode": "play", "start": 2},
          "Enter on a song plays its album from it: " + json.dumps(play), failures)
    check(host.state()["browse"] == "" and host.state()["notice"] == "Playing Chartered Trips",
          "and returns to the queue", failures)

    # a, then A: add a search result to the queue, and to a playlist.
    host.call("press", "/")
    host.call("typeKeys", "workbook")
    wait_for(lambda: host.state()["query"] == "workbook" and not host.state()["searching"], "search workbook")
    host.call("press", "Down")
    host.call("press", "a")
    wait_for(lambda: bridge_requests("/v1/play")[-1][2].get("mode") == "add", "add to the queue")
    check(host.state()["notice"] == "Added Workbook to the queue", "a adds to Apple Music's queue", failures)
    host.call("press", "A")
    wait_for(lambda: host.state()["pickerOpen"] and len(host.state()["pickerChoices"]) == 3, "Apple playlists in the picker")
    s = host.state()
    check(s["pickerChoices"] == ["PunkRock", "Road Songs", "new:"],
          "the picker lists your Apple Music playlists, changed last first: " + str(s["pickerChoices"]), failures)
    host.call("press", "Return")
    wait_for(lambda: bridge_requests("/v1/library/playlists/p-1/tracks"), "added to PunkRock")
    check(bridge_requests("/v1/library/playlists/p-1/tracks")[-1][2] == {"items": [{"kind": "album", "id": "c-al-3", "source": "catalog"}]},
          "A adds the album to the Apple Music playlist", failures)
    wait_for(lambda: host.state()["notice"] == "Added Workbook to PunkRock", "says so")
    host.call("press", "Escape")

    # P: your Apple Music playlists; PunkRock now has the album too.
    host.call("press", "P")
    wait_for(lambda: browsed(host, "playlists:Apple Music playlists"), "Apple playlists")
    s = host.state()
    check(s["rows"] == ["savequeue:Save the queue as a playlist", "playlist:PunkRock", "playlist:Road Songs"],
          "P lists your Apple Music playlists: " + ", ".join(s["rows"]), failures)
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "playlist:PunkRock"), "PunkRock")
    check(len(host.state()["rows"]) == 5, "PunkRock: Play, then 4 songs", failures)
    host.call("press", "Escape")
    host.call("press", "Escape")
    host.settle(.3)

    # The queue: Enter jumps, x removes.
    host.call("press", "Down")
    host.call("press", "Down")
    playids = command_count(socket_path, "playid")
    host.call("press", "Return")
    wait_for(lambda: bridge_requests("/v1/queue/jump"), "jump")
    check(bridge_requests("/v1/queue/jump")[-1][2] == {"index": host.state()["cursor"]}, "Enter on a queue row jumps to it", failures)
    # mpd plays on, on the same connection: with the patched libFLAC it stays
    # about 0.3 s behind the Mac by itself, and a reconnect is a stutter 2 s
    # into the song.
    host.settle(3.5)
    status = mpd_state(socket_path)
    check(command_count(socket_path, "playid") == playids and status["state"] == "play",
          "after a jump mpd plays on, without reconnecting to the stream", failures)
    # appleRejoin (for a stock libFLAC): mpd reconnects to the stream, at
    # live, 2 s later, once the change has reached the stream (1.5 to 1.8 s).
    host.call("settings", json.dumps({"appleRejoin": True}))
    host.settle(.3)
    host.call("press", "Return")
    jumped = time.monotonic()
    wait_for(lambda: command_count(socket_path, "playid") > playids, "mpd reconnects")
    waited = time.monotonic() - jumped
    current = dict(l.split(": ", 1) for l in mpd_query(socket_path, "currentsong")).get("file")
    check(mpd_state(socket_path)["state"] == "play" and current == stream and 1.5 < waited < 4,
          f"with appleRejoin, mpd reconnects to the stream (playid of its entry) {waited:.1f} s after a jump", failures)
    host.call("settings", "{}")
    host.call("press", "x")
    wait_for(lambda: bridge_requests("/v1/queue/remove"), "remove")
    check(True, "x removes from Apple Music's queue", failures)

    # mpd paused (the media keys): mpd stops and the Mac pauses; mpd playing resumes it.
    mpd_client(socket_path, "pause 1")
    wait_for(lambda: mpd_state(socket_path)["state"] == "stop" and not host.state()["bar"]["playing"], "mpd pause follows")
    check(host.state()["appleMode"], "mpd paused on the stream: still Apple Music, the Mac paused, mpd stopped", failures)
    mpd_client(socket_path, "play")
    wait_for(lambda: host.state()["bar"]["playing"], "mpd play follows")
    check(True, "mpd playing again resumes the Mac", failures)
    # Space pauses the Mac only; mpd keeps the stream.
    host.call("press", "Space")
    wait_for(lambda: not host.state()["bar"]["playing"], "Space pauses")
    check(mpd_state(socket_path)["state"] == "play", "Space pauses Apple Music, mpd keeps the stream", failures)
    host.call("press", "Space")
    wait_for(lambda: host.state()["bar"]["playing"], "Space plays")

    # From Apple Music stopped (mpd's pause) to SiriusXM: the Mac stays
    # paused. mpd's status comes before its current song, so the new
    # channel playing read as the Apple Music stream playing again, and
    # resumed the Mac to play to nobody.
    mpd_client(socket_path, "pause 1")
    wait_for(lambda: mpd_state(socket_path)["state"] == "stop" and not host.state()["bar"]["playing"], "stopped")
    resumes = len(bridge_requests("/v1/resume"))
    host.call("setSource", "sxm")
    wait_for(lambda: host.state()["sxmMode"], "SiriusXM")
    host.settle(1.5)
    check(len(bridge_requests("/v1/resume")) == resumes,
          "switching from a stopped Apple Music to SiriusXM leaves the Mac paused", failures)

    # m (round the sources): back to local, where it was.
    to_source(host, "local")
    host.settle(.5)
    check(mpd_files(socket_path) == local_files, "the stream is out of mpd's queue", failures)
    st = mpd_state(socket_path)
    check(int(st["song"]) == local_song and float(st["elapsed"]) >= 1, "the local song resumes where it was: "
          + st["song"] + " at " + st["elapsed"], failures)
    check(host.state()["nowPlaying"] == before["nowPlaying"], "the panel is back on local music", failures)
    check(bridge_requests("/v1/pause"), "and the Mac pauses", failures)

    # A bridge that isn't there: m says so, and mpd's queue is left alone.
    host.call("settings", json.dumps({"appleBridge": "http://127.0.0.1:9", "appleStream": stream}))
    host.call("press", "m")
    wait_for(lambda: "Can't reach" in host.state()["notice"], "unreachable bridge")
    check(not host.state()["appleMode"] and mpd_files(socket_path) == local_files,
          "an unreachable bridge leaves local music alone: " + host.state()["notice"], failures)
    host.call("settings", "{}")
    BRIDGE["config"].unlink()
    wait_for(lambda: not host.state()["appleConfigured"], "apple.json gone")
    check(True, "without apple.json or settings, Apple Music is hidden", failures)
    host.call("close")


def real_apple():
    """The real bridge and its stream, for the real-apple scenarios, which
    reach it only through a read-only proxy: OMAROCK_REAL_BRIDGE
    (http://HOST:8710) and OMAROCK_REAL_STREAM (http://HOST:8000/omarock.ogg)."""
    bridge, stream = os.environ.get("OMAROCK_REAL_BRIDGE", ""), os.environ.get("OMAROCK_REAL_STREAM", "")
    if not bridge or not stream:
        raise RuntimeError("the real-apple scenarios need OMAROCK_REAL_BRIDGE (http://HOST:8710) and "
                           "OMAROCK_REAL_STREAM (http://HOST:8000/omarock.ogg)")
    return bridge.rstrip("/"), stream


class ReadOnlyProxy:
    """A local proxy to the real bridge that forwards GETs and refuses POSTs
    (recording them), so a test against your Mac can't play, pause or
    change anything there."""
    def __init__(self, target):
        import http.server
        import urllib.request
        proxy = self
        self.posts = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass

            def do_GET(self):
                request = urllib.request.Request(target + self.path, headers={
                    k: v for k, v in self.headers.items() if k.lower() in ("authorization", "accept")})
                try:
                    with urllib.request.urlopen(request, timeout=40) as reply:
                        body, code, kind = reply.read(), reply.status, reply.headers.get("Content-Type", "")
                except urllib.error.HTTPError as e:
                    body, code, kind = e.read(), e.code, e.headers.get("Content-Type", "")
                except Exception as e:
                    body, code, kind = json.dumps({"error": str(e)}).encode(), 502, "application/json"
                self.send_response(code)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try: self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError): pass

            def do_POST(self):
                proxy.posts.append(self.path)
                body = json.dumps({"error": "read-only test: POST refused"}).encode()
                self.send_response(403)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


class TcpReadOnlyProxy:
    """A byte-for-byte TCP proxy to the real bridge, so connections behave as
    they do live, that refuses any connection whose request is a POST. The
    bridge serves one request per connection, so each connection is one
    request."""
    def __init__(self, host, port):
        import socket
        self.posts, self.requests = [], 0
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(64)
        self.url = f"http://127.0.0.1:{self.listener.getsockname()[1]}"
        def pipe(a, b):
            try:
                while True:
                    data = a.recv(65536)
                    if not data: break
                    b.sendall(data)
            except OSError:
                pass
            finally:
                for sock in (a, b):
                    try: sock.shutdown(socket.SHUT_RDWR)
                    except OSError: pass
        def serve(client):
            head = b""
            while b"\r\n" not in head:
                chunk = client.recv(4096)
                if not chunk: client.close(); return
                head += chunk
            self.requests += 1
            if head.startswith(b"POST"):
                self.posts.append(head.split(b"\r\n")[0].decode())
                client.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
                client.close()
                return
            upstream = socket.create_connection((host, port), timeout=60)
            upstream.settimeout(None)
            upstream.sendall(head)
            threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()
            pipe(client, upstream)
        def accept():
            while True:
                try: client, _ = self.listener.accept()
                except OSError: return
                threading.Thread(target=serve, args=(client,), daemon=True).start()
        threading.Thread(target=accept, daemon=True).start()

    def close(self):
        self.listener.close()


def real_apple_watch_scenario(host, output, socket_path, failures):
    """Read-only: watch omarock's link to the real bridge for a minute, as it
    runs live (through the TCP proxy, which refuses POSTs)."""
    bridge, stream = real_apple()
    address = urllib.parse.urlsplit(bridge)
    proxy = TcpReadOnlyProxy(address.hostname, address.port or 80)
    try:
        host.call("settings", json.dumps({"appleBridge": proxy.url, "appleStream": stream,
                                          "appleTokenFile": str(Path.home() / ".config/omarock/bridge-token")}))
        stream_id = mpd_query(socket_path, f'addid "{stream}"')[0].split(": ")[1]
        mpd_client(socket_path, "playid " + stream_id)
        host.call("open")
        wait_for(lambda: host.state()["appleReady"], "real bridge", timeout=30)
        samples, t0 = [], time.monotonic()
        while time.monotonic() - t0 < 60:
            s = host.state()
            samples.append((round(time.monotonic() - t0, 1), s["appleReady"], s["appleSeq"], s["appleDropouts"], s["appleError"]))
            time.sleep(.25)
        flips = sum(1 for a, b in zip(samples, samples[1:]) if a[1] != b[1])
        seqs = sorted({x[2] for x in samples})
        print(f"ready flips {flips}; dropouts {samples[-1][3]}; seqs {seqs}; requests {proxy.requests}; errors "
              + str(sorted({x[4] for x in samples if x[4]})), file=sys.stderr)
        for a, b in zip(samples, samples[1:]):
            if a[1] != b[1]: print("   flip at", b, file=sys.stderr)
        check(flips == 0, f"omarock's link to the bridge stays up for a minute (flips {flips}, requests {proxy.requests})", failures)
        check(not proxy.posts, "nothing was sent to the Mac but GETs: " + ", ".join(proxy.posts), failures)
    finally:
        host.call("close")
        mpd_client(socket_path, "deleteid " + stream_id)
        host.call("settings", "{}")
        proxy.close()


def real_apple_keys_scenario(host, output, socket_path, failures):
    """Read-only, real bridge: the expanded panel, search "jazz", ↓↓↓↑."""
    bridge, stream = real_apple()
    proxy = ReadOnlyProxy(bridge)
    try:
        host.call("settings", json.dumps({"appleBridge": proxy.url, "appleStream": stream,
                                          "appleTokenFile": str(Path.home() / ".config/omarock/bridge-token")}))
        stream_id = mpd_query(socket_path, f'addid "{stream}"')[0].split(": ")[1]
        mpd_client(socket_path, "playid " + stream_id)
        host.call("open")
        wait_for(lambda: host.state()["appleReady"], "real bridge", timeout=30)
        host.call("expand", "true")
        host.settle(.8)
        host.call("press", "/")
        host.call("typeKeys", "jazz")
        wait_for(lambda: host.state()["query"] == "jazz" and not host.state()["searching"], "jazz", timeout=40)
        host.settle(1)
        s = host.state()
        print("rows:", list(zip(s["sections"], s["rows"]))[:12], len(s["rows"]), file=sys.stderr)
        trail = []
        for key in ["Down", "Down", "Down", "Up"]:
            host.call("press", key)
            host.settle(.6)
            st = host.state()
            trail.append((key, st["cursor"], st["searchFocused"], st["preview"], st["notice"]))
        print("trail:", trail, file=sys.stderr)
        host.grab(output / "real-apple-jazz.png")
        check([t[1] for t in trail] == [0, 1, 2, 1], "↓↓↓↑ in the real results: " + str([t[1] for t in trail]), failures)
        check(not proxy.posts, "nothing was sent to the Mac but GETs: " + ", ".join(proxy.posts), failures)
    finally:
        host.call("close")
        mpd_client(socket_path, "deleteid " + stream_id)
        host.call("settings", "{}")
        proxy.close()


def real_apple_catalog_scenario(host, output, socket_path, failures):
    """Read-only, real bridge with the catalog: search, a catalog album, genres."""
    bridge, stream = real_apple()
    proxy = ReadOnlyProxy(bridge)
    try:
        host.call("settings", json.dumps({"appleBridge": proxy.url, "appleStream": stream,
                                          "appleTokenFile": str(Path.home() / ".config/omarock/bridge-token")}))
        stream_id = mpd_query(socket_path, f'addid "{stream}"')[0].split(": ")[1]
        mpd_client(socket_path, "playid " + stream_id)
        host.call("open")
        wait_for(lambda: host.state()["appleReady"], "real bridge", timeout=30)
        host.call("expand", "true")
        host.settle(1)
        host.call("press", "/")
        host.call("typeKeys", "husker")
        wait_for(lambda: host.state()["query"] == "husker" and not host.state()["searching"], "search", timeout=40)
        host.settle(1)
        s = host.state()
        sections = [x for x in s["sections"] if x]
        print("sections:", sections, file=sys.stderr)
        print("rows:", s["rows"][:14], file=sys.stderr)
        check(any(x.startswith("APPLE MUSIC") for x in sections) and "note:The Apple Music catalog isn't available" not in s["rows"],
              "search finds Apple Music's catalog too: " + ", ".join(sections), failures)
        catalog = [i for i, (sec, r) in enumerate(zip(s["sections"], s["rows"])) if r.startswith("album:")
                   and any(x == "APPLE MUSIC · ALBUMS" for x in s["sections"][:i + 1])]
        if catalog:
            host.call("press", "Down")
            for _ in range(catalog[0]): host.call("press", "Down")
            host.call("press", "Right")
            wait_for(lambda: host.state()["browse"].startswith("album:") and not host.state()["browseLoading"], "catalog album", timeout=40)
            host.settle(3)
            s = host.state()
            check(len(s["rows"]) > 1, "a catalog album opens: " + s["browse"] + " · " + s["browseInfo"].get("subtitle", "")
                  + " · " + s["browseInfo"].get("detail", "") + " " + s["browseInfo"].get("emptyText", ""), failures)
            host.grab(output / "real-apple-catalog-album.png")
            host.call("press", "Escape")
            host.call("press", "Escape")
        host.call("press", "Escape")
        host.call("press", "/")
        host.call("typeKeys", "alternative")
        wait_for(lambda: host.state()["query"] == "alternative" and not host.state()["searching"], "genre search", timeout=40)
        host.settle(1)
        s = host.state()
        check(any(r.startswith("genre:") for r in s["rows"]), "Apple's genres match: " + ", ".join(r for r in s["rows"] if r.startswith("genre:")), failures)
        host.grab(output / "real-apple-catalog-search.png")
        check(not proxy.posts, "nothing was sent to the Mac but GETs: " + ", ".join(proxy.posts), failures)
    finally:
        host.call("close")
        mpd_client(socket_path, "deleteid " + stream_id)
        host.call("settings", "{}")
        proxy.close()


def real_apple_info_scenario(host, output, socket_path, failures):
    """Read-only, real bridge: the info card's library status and details, from
    the bridge's /v1/info, for a library song, a catalog song and an album."""
    bridge, stream = real_apple()
    proxy = ReadOnlyProxy(bridge)

    def in_section(rows, sections, section):
        out, current = [], ""
        for i, (sec, row) in enumerate(zip(sections, rows)):
            current = sec or current
            if current == section: out.append(i)
        return out

    def card_for(index, what):
        host.call("move", 0)
        while host.state()["cursor"] != index:
            host.call("press", "Down" if host.state()["cursor"] < index else "Up")
        host.call("press", "i")
        wait_for(lambda: (host.state()["info"] or {}).get("loading") is False, what, timeout=30)
        host.settle(.5)
        return host.state()["info"]

    try:
        host.call("settings", json.dumps({"appleBridge": proxy.url, "appleStream": stream,
                                          "appleTokenFile": str(Path.home() / ".config/omarock/bridge-token")}))
        stream_id = mpd_query(socket_path, f'addid "{stream}"')[0].split(": ")[1]
        mpd_client(socket_path, "playid " + stream_id)
        host.call("open")
        wait_for(lambda: host.state()["appleReady"], "real bridge", timeout=30)
        host.call("press", "/")
        host.call("typeKeys", "no one knows")
        wait_for(lambda: host.state()["query"] == "no one knows" and not host.state()["searching"], "search", timeout=40)
        host.settle(1)
        host.call("press", "Down")
        s = host.state()
        mine = [i for i in in_section(s["rows"], s["sections"], "YOUR SONGS") if s["rows"][i] == "song:No One Knows"]
        theirs = in_section(s["rows"], s["sections"], "APPLE MUSIC · SONGS")
        check(bool(mine) and bool(theirs), "search lists your No One Knows and Apple Music's songs", failures)
        if mine:
            card = card_for(mine[0], "your song's card")
            print("library song:", card["status"], card["fields"], file=sys.stderr)
            check(card["status"] == "In your library" and any(f.startswith("YOUR LIBRARY: Plays = ") for f in card["fields"])
                  and any(f.startswith("YOUR LIBRARY: Added = ") for f in card["fields"]),
                  "your song: In your library, with plays and the date added", failures)
            host.grab(output / "real-info-library-song.png")
            host.call("press", "i")
        if theirs:
            card = card_for(theirs[0], "a catalog song's card")
            print("catalog song:", card["title"], card["lines"], card["status"], file=sys.stderr)
            check(card["statusKind"] in ("yes", "no"), "a catalog song: the bridge says whether it's yours: " + card["status"], failures)
            host.grab(output / "real-info-catalog-song.png")
            host.call("press", "i")
        host.call("press", "/")
        host.call("type", "")
        host.call("typeKeys", "songs for the deaf")
        wait_for(lambda: host.state()["query"] == "songs for the deaf" and not host.state()["searching"], "album search", timeout=40)
        host.settle(1)
        host.call("press", "Down")
        s = host.state()
        albums = [i for i in in_section(s["rows"], s["sections"], "YOUR ALBUMS") if s["rows"][i].startswith("album:")]
        if albums:
            card = card_for(albums[0], "your album's card")
            print("library album:", card["status"], card["fields"], file=sys.stderr)
            check(card["status"] == "In your library" and any(f.startswith("YOUR LIBRARY: Songs you have = ") for f in card["fields"]),
                  "your album: In your library, with the songs you have", failures)
            host.grab(output / "real-info-library-album.png")
            host.call("press", "i")
        else:
            check(False, "search lists your Songs for the Deaf: " + ", ".join(s["rows"][:8]), failures)
        check(not proxy.posts, "nothing was sent to the Mac but GETs: " + ", ".join(proxy.posts), failures)
    finally:
        host.call("close")
        mpd_client(socket_path, "deleteid " + stream_id)
        host.call("settings", "{}")
        proxy.close()


def real_apple_scenario(host, output, socket_path, failures):
    """Read-only, against your real bridge through ReadOnlyProxy,
    with the fake mpd (which plays nothing): Apple Music playlists, a
    playlist, search and an album, through omarock's own code."""
    bridge, stream = real_apple()
    proxy = ReadOnlyProxy(bridge)
    try:
        host.call("settings", json.dumps({"appleBridge": proxy.url, "appleStream": stream,
                                          "appleTokenFile": str(Path.home() / ".config/omarock/bridge-token")}))
        # Apple Music mode without omarock's switch (which would resume the Mac):
        # the fake mpd simply has the stream as its current entry.
        stream_id = mpd_query(socket_path, f'addid "{stream}"')[0].split(": ")[1]
        mpd_client(socket_path, "playid " + stream_id)
        host.call("open")
        wait_for(lambda: host.state()["appleMode"] and "Not connected" not in host.state()["stateText"], "real bridge", timeout=30)
        host.settle(1)
        print("state:", host.state()["stateText"], file=sys.stderr)
        host.call("press", "P")
        wait_for(lambda: browsed(host, "playlists:Apple Music playlists") and len(host.state()["rows"]) > 1, "real playlists", timeout=30)
        s = host.state()
        check(len(s["rows"]) > 10, f"your Apple Music playlists: {len(s['rows']) - 1}, e.g. " + ", ".join(s["rows"][1:5]), failures)
        host.settle(2)
        host.grab(output / "real-apple-playlists.png")
        host.call("press", "Right")
        wait_for(lambda: host.state()["browse"].startswith("playlist:") and not host.state()["browseLoading"], "a real playlist", timeout=40)
        s = host.state()
        check(len(s["rows"]) > 1 or s["browseInfo"].get("failed"), "a playlist opens: " + s["browse"] + " · "
              + str(len(s["rows"])) + " rows · " + s["browseInfo"].get("subtitle", "") + s["browseInfo"].get("emptyText", ""), failures)
        host.settle(3)
        host.grab(output / "real-apple-playlist.png")
        host.call("press", "Escape")
        host.call("press", "Escape")
        host.call("press", "/")
        host.call("typeKeys", "husker")
        wait_for(lambda: host.state()["query"] == "husker" and not host.state()["searching"], "real search", timeout=40)
        host.settle(1)
        s = host.state()
        print("search:", ", ".join(s["rows"][:8]), "| notice:", s["notice"], file=sys.stderr)
        albums = [i for i, r in enumerate(s["rows"]) if r.startswith("album:")]
        if albums:
            host.call("press", "Down")
            for _ in range(albums[0]): host.call("press", "Down")
            host.call("press", "Right")
            wait_for(lambda: host.state()["browse"].startswith("album:") and not host.state()["browseLoading"], "a real album", timeout=40)
            s = host.state()
            check(len(s["rows"]) > 1, "a library album opens: " + s["browse"] + " · " + s["browseInfo"].get("subtitle", ""), failures)
            host.call("expand", "true")
            host.settle(3)
            host.grab(output / "real-apple-album.png")
            host.call("expand", "false")
        else:
            check(False, "search found a library album (rows: " + ", ".join(s["rows"][:5]) + ")", failures)
        check(not proxy.posts, "nothing was sent to the Mac but GETs: " + ", ".join(proxy.posts), failures)
    finally:
        host.call("close")
        mpd_client(socket_path, "deleteid " + stream_id)
        host.call("settings", "{}")
        proxy.close()


def command_count(socket_path, name):
    """How many times the panel has sent this command to the fake mpd."""
    log = BRIDGE["mpd_log"].read_text().splitlines() if BRIDGE.get("mpd_log") else []
    return sum(1 for line in log if line.split(" ")[0] == name)


def drag_volume(host, label):
    """Drag the volume slider from 20% to 90% of its width in 15 steps, like a
    hand would, and record where the knob is after each step."""
    timeline = []
    def sample(step):
        t = time.monotonic()
        v = json.loads(host.call("slider", "volumeSlider"))
        timeline.append((step, round(v.get("live", -1), 1), v.get("value"), round((time.monotonic() - t) * 1000)))
    t0 = time.monotonic()
    host.call("mouse", "volumeSlider", "press", .2)
    sample("press")
    for i in range(1, 15):
        start = time.monotonic()
        host.call("mouse", "volumeSlider", "move", .2 + .05 * i)
        sample(f"{.2 + .05 * i:.2f}")
    host.call("mouse", "volumeSlider", "release", .9)
    for i in range(6):
        sample(f"after {i}")
        time.sleep(.15)
    print(f"{label}: drag took {time.monotonic() - t0:.2f} s", file=sys.stderr)
    for row in timeline: print("   ", row, file=sys.stderr)
    # The knob, from the press to well after the release: it should only
    # move forwards and end where the mouse let go.
    lives = [r[1] for r in timeline]
    backwards = sum(1 for a, b in zip(lives, lives[1:]) if b < a)
    return timeline, backwards


def volume_scenario(host, socket_path, failures):
    """The volume slider while dragging, local and in Apple Music mode."""
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    host.settle(.5)
    _, back_local = drag_volume(host, "local")
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    host.call("press", "m")
    wait_for(lambda: host.state()["appleMode"], "Apple Music mode")
    host.settle(1)
    _, back_apple = drag_volume(host, "apple")
    check(back_local == 0 and back_apple == 0, f"the knob never moves backwards while dragging (local {back_local}, apple {back_apple})", failures)
    # A slow mixer (mpd while it plays a live stream): the commands must not
    # pile up, and the knob must stay where it was let go.
    mpd_client(socket_path, "fake_setvol_delay 0.25")
    sent_before = command_count(socket_path, "setvol")
    timeline, back_slow = drag_volume(host, "apple, slow mixer")
    sent = command_count(socket_path, "setvol") - sent_before
    final = timeline[-1]
    check(back_slow == 0, f"with a slow mixer the knob doesn't jump back after release ({back_slow} backward steps)", failures)
    check(sent <= 8, f"with a slow mixer omarock doesn't pile up volume commands ({sent} sent for a 1.5 s drag)", failures)
    wait_for(lambda: json.loads(host.call("slider", "volumeSlider")).get("value") == 90, "mpd catches up", timeout=5)
    check(True, "and mpd ends at the released volume", failures)
    # One click, with a mixer that takes 3 s (on the radio the knob once moved,
    # went back, then forward again): it stays where clicked.
    mpd_client(socket_path, "fake_setvol_delay 3")
    host.call("mouse", "volumeSlider", "press", .3)
    host.call("mouse", "volumeSlider", "release", .3)
    clicked = json.loads(host.call("slider", "volumeSlider")).get("value")
    knob = []
    for _ in range(25):
        knob.append(json.loads(host.call("slider", "volumeSlider")).get("value"))
        time.sleep(.2)
    check(clicked == 30 and set(knob) == {30} and int(mpd_state(socket_path)["volume"]) == 30,
          f"a click with a 3 s mixer: the knob stays where clicked until mpd has it ({clicked}, then {sorted(set(knob))})", failures)
    check("omarock: mpd setvol took 3" in BRIDGE["qs_log"].read_text(),
          "a slow setvol goes to the journal", failures)
    mpd_client(socket_path, "fake_setvol_delay 0")
    to_source(host, "local")
    BRIDGE["config"].unlink()
    host.call("close")


def expanded_keys_scenario(host, failures):
    """The expanded panel: search, then ↓↓ in the results column, Local and
    Apple Music (searching gave a list that ↑↓ couldn't move in)."""
    def run(label, query, pointer=None, scrollbar=False):
        host.call("open")
        host.call("expand", "true")
        host.settle(.8)
        host.call("press", "/")
        host.call("typeKeys", query)
        wait_for(lambda: host.state()["query"] == query and not host.state()["searching"], label + " search")
        host.settle(.5)
        rows = host.state()["rows"]
        if pointer:
            # The pointer resting over the results column, as it does live.
            host.hover(*pointer)
            host.settle(.3)
        if scrollbar:
            # A click on the results' scrollbar, as when scrolling a long list.
            pressed = host.call("mouse", "listScrollBar", "press", .5)
            host.call("mouse", "listScrollBar", "release", .5)
            print(label, "scrollbar click:", pressed, file=sys.stderr)
            host.settle(.3)
        trail = []
        for key in ["Down", "Down", "Down", "Up"]:
            host.call("press", key)
            host.settle(.4)
            s = host.state()
            trail.append((key, s["cursor"], s["searchFocused"], s["preview"]))
        print(label, "rows:", rows[:5], file=sys.stderr)
        print(label, "trail:", trail, file=sys.stderr)
        cursors = [t[1] for t in trail]
        steps = [b - a for a, b in zip(cursors, cursors[1:])]
        check(cursors[0] >= 0 and steps == [1, 1, -1] or len(rows) < 4,
              f"{label}: ↓↓↓↑ moves the cursor in the results column: " + str(cursors), failures)
        host.call("press", "Escape")
        host.call("expand", "false")
        host.call("close")
        host.settle(.3)
    run("local", "glass")
    run("local, pointer over the results", "glass", pointer=(520, 330))
    run("local, after a click on the scrollbar", "a", scrollbar=True)
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    host.call("open")
    host.call("press", "m")
    wait_for(lambda: host.state()["appleMode"], "Apple Music mode")
    host.call("close")
    run("apple", "husker")
    run("apple, pointer over the results", "husker", pointer=(520, 330))
    host.call("open")
    to_source(host, "local")
    host.call("close")
    BRIDGE["config"].unlink()


def sxm_requests(prefix=""):
    lines = BRIDGE["sxm_log"].read_text().splitlines() if BRIDGE["sxm_log"].exists() else []
    return [(r["method"], r["path"]) for r in map(json.loads, lines) if r["path"].startswith(prefix)]


def sxm_scenario(host, output, socket_path, failures):
    """SiriusXM against the fake omarock-sxm: m tunes the last or first
    favourite channel, the list is channels with what's on, n and p change
    channel (replacing the stream in mpd), search, A favourites, Space stops,
    mpd's pause becomes a stop, and m back to local where it was."""
    base = BRIDGE["sxm"]
    host.call("open")
    wait_for(lambda: "sxm" in host.state()["sources"], "SiriusXM available")
    host.settle(.5)
    before = host.state()
    local_files = mpd_files(socket_path)
    local_song = int(mpd_state(socket_path)["song"])

    # The switch (m would go to Spotify first).
    host.call("setSource", "sxm")
    wait_for(lambda: host.state()["sxmMode"] and host.state()["nowPlaying"].startswith("Take It On The Run"), "SiriusXM mode")
    host.settle(.5)
    s = host.state()
    files = mpd_files(socket_path)
    check(files == local_files[:local_song + 1] + [base + "/stream/ch-8"] + local_files[local_song + 1:],
          "m tunes the first favourite (80s on 8) after the local song", failures)
    st = mpd_state(socket_path)
    check(st["repeat"] == "1" and st["single"] == "1", "a live source plays in mpd's repeat-one mode (a drop reconnects)", failures)
    check(s["stateText"] == "SiriusXM · Playing" and s["nowPlaying"] == "Take It On The Run · REO Speedwagon",
          "the panel shows what's on: " + s["nowPlaying"] + " | " + s["stateText"], failures)
    check(s["rows"][:3] == ["channel:80s on 8", "channel:E Street Radio", "channel:SiriusXM Hits 1"]
          and s["sections"][:3] == ["FAVORITES", "", "ALL CHANNELS"], "the list: favourites, then all channels: "
          + ", ".join(s["rows"][:4]), failures)
    check(s["subtitles"][0] == "REO Speedwagon – Take It On The Run", "each channel says what's on", failures)
    check(s["bar"]["text"] == "REO Speedwagon — Take It On The Run" and "/art/888888/" in s["bar"]["cover"],
          "the bar shows the song and its art", failures)
    host.grab(output / "compact-sxm.png")

    # n: the next favourite, replacing the stream.
    host.call("press", "n")
    wait_for(lambda: host.state()["nowPlaying"].startswith("Badlands"), "next favourite")
    check(mpd_files(socket_path) == local_files[:local_song + 1] + [base + "/stream/ch-20"] + local_files[local_song + 1:],
          "n tunes the next favourite in place of the last", failures)
    # A quick run of channel changes still leaves one channel in mpd's queue.
    for _ in range(3):
        host.call("press", "n")
    host.settle(1.5)
    streams = [f for f in mpd_files(socket_path) if f.startswith(base)]
    check(len(streams) == 1 and len(mpd_files(socket_path)) == len(local_files) + 1,
          f"three quick n's leave one channel in mpd's queue ({len(streams)})", failures)

    # Search, then Enter tunes.
    host.call("press", "/")
    host.call("typeKeys", "jazz")
    wait_for(lambda: host.state()["query"] == "jazz", "channel search")
    host.settle(.3)
    s = host.state()
    check(s["rows"] == ["channel:Real Jazz"] and s["sections"] == ["CHANNELS"],
          "search finds the channel: " + str(list(zip(s["sections"], s["rows"]))), failures)
    host.call("press", "Return")
    wait_for(lambda: host.state()["nowPlaying"].startswith("So What"), "tuned from search")
    check(host.state()["query"] == "" and base + "/stream/ch-67" in mpd_files(socket_path), "Enter tunes it", failures)

    # A: a favourite.
    host.call("press", "Down")
    host.call("press", "Down")
    host.settle(.2)
    row = host.state()["rows"][host.state()["cursor"]]
    host.call("press", "A")
    wait_for(lambda: any(m in ("POST", "DELETE") for m, _ in sxm_requests("/v1/favorites")), "favourite")
    check(True, "A toggles a favourite (" + row + "): " + str(sxm_requests("/v1/favorites")[-1]), failures)

    # Space stops (live radio), and plays again.
    host.call("press", "Escape")
    host.call("press", "Space")
    wait_for(lambda: mpd_state(socket_path)["state"] == "stop", "stopped")
    host.call("press", "Space")
    wait_for(lambda: mpd_state(socket_path)["state"] == "play", "playing")
    check(True, "Space stops and starts the channel", failures)
    # mpd paused from elsewhere: a stop.
    mpd_client(socket_path, "pause 1")
    wait_for(lambda: mpd_state(socket_path)["state"] == "stop", "pause becomes stop")
    check(True, "mpd's pause on a channel becomes a stop", failures)
    mpd_client(socket_path, "play")
    host.settle(.3)
    host.call("expand", "true")
    host.settle(1)
    host.grab(output / "expanded-sxm.png")
    host.call("expand", "false")

    # m (round the sources): back to local, where it was.
    to_source(host, "local")
    host.settle(.5)
    check(mpd_files(socket_path) == local_files, "the channel's stream is out of mpd's queue", failures)
    check(int(mpd_state(socket_path)["song"]) == local_song, "and the local song resumes", failures)
    check(not sxm_requests("/stream"), "omarock never fetches streams itself (mpd does)", failures)
    wait_for(lambda: mpd_state(socket_path)["single"] == "0", "single off")
    check(mpd_state(socket_path)["repeat"] == "1", "back on local, repeat and single are as they were", failures)
    host.call("close")


def real_sxm_scenario(host, output, socket_path, failures):
    """The panel against the real omarock-sxm on 127.0.0.1:8720, with the fake
    mpd (which never fetches the stream, so nothing plays). Read-only: it
    tunes in the fake mpd only, and doesn't touch favourites."""
    real = "http://127.0.0.1:8720"
    try:
        host.call("settings", json.dumps({"sxmService": real}))
        host.call("open")
        wait_for(lambda: "sxm" in host.state()["sources"], "real SiriusXM", timeout=90)
        to_source(host, "sxm")
        wait_for(lambda: host.state()["sxmMode"] and len(host.state()["rows"]) > 100, "real channels", timeout=90)
        host.settle(3)
        s = host.state()
        filled = sum(1 for x in s["subtitles"] if " – " in x)
        print("rows:", len(s["rows"]), "| with what's on:", filled, "| now:", s["nowPlaying"], file=sys.stderr)
        check(len(s["rows"]) > 400 and filled > 100, f"your SiriusXM: {len(s['rows'])} channels, {filled} saying what's on", failures)
        host.grab(output / "real-sxm.png")
        host.call("press", "/")
        host.call("typeKeys", "80s")
        wait_for(lambda: host.state()["query"] == "80s", "search")
        host.settle(.5)
        s = host.state()
        check(s["rows"][:1] == ["channel:80s on 8"] or "channel:80s on 8" in s["rows"][:3],
              "search '80s': " + ", ".join(s["rows"][:4]), failures)
        host.call("expand", "true")
        host.settle(3)
        host.grab(output / "real-sxm-expanded.png")
        host.call("expand", "false")
        host.call("press", "Escape")
        to_source(host, "local")
    finally:
        host.call("close")
        host.call("settings", "{}")


def radio_requests(path=""):
    lines = BRIDGE["radio_log"].read_text().splitlines() if BRIDGE["radio_log"].exists() else []
    return [r for r in map(json.loads, lines) if r["path"].startswith(path)]


def radio_scenario(host, output, socket_path, failures):
    """Internet radio against the fake Radio Browser: m round to the radio
    tunes the most listened local station, iHeart-style titles become the
    song and its art, search and Enter tune, HLS-only stations can't, A keeps
    a favourite in the mpd playlist "Radio", and back to local where it was."""
    host.call("open")
    wait_for(lambda: "radio" in host.state()["sources"], "radio source")
    host.settle(.5)
    local_files = mpd_files(socket_path)
    local_song = int(mpd_state(socket_path)["song"])
    to_source(host, "radio")
    wait_for(lambda: host.state()["nowPlaying"].startswith("KEXP"), "a local station")
    host.settle(.5)
    s = host.state()
    streams = [f for f in mpd_files(socket_path) if "#omarock-radio=" in f]
    check(streams == ["http://radio.example/st-kexp#omarock-radio=st-kexp"] and len(mpd_files(socket_path)) == len(local_files) + 1,
          "m round to the radio tunes the most listened local station", failures)
    check(s["stateText"] == "Radio · Playing" and s["rows"][:2] == ["station:KEXP 90.3 FM", "station:KUOW 94.9"]
          and s["sections"][0] == "LOCAL · WASHINGTON", "the list: local stations: " + ", ".join(s["rows"]), failures)
    check(radio_requests("/json/url/st-kexp"), "Radio Browser hears about the play", failures)

    # A station's ICY title, iHeart style: the song and its art.
    art = BRIDGE["radio"] + "/logo/aa5500.png"
    mpd_client(socket_path, 'fake_stream_title "Days Of The New - text=\\"Touch, Peel & Stand\\" song_spot=\\"M\\" amgArtworkURL=\\"' + art + '\\""')
    wait_for(lambda: host.state()["nowPlaying"].startswith("Touch, Peel & Stand"), "the song")
    s = host.state()
    check(s["nowPlaying"] == "Touch, Peel & Stand · Days Of The New" and s["coverUrl"] == art,
          "the station's title becomes the song and its art: " + s["nowPlaying"], failures)
    host.grab(output / "compact-radio.png")

    # Search, then Enter tunes; one station stays in mpd's queue.
    host.call("press", "/")
    host.call("typeKeys", "wxpn")
    wait_for(lambda: host.state()["query"] == "wxpn" and not host.state()["searching"], "station search")
    host.settle(.3)
    check(host.state()["rows"] == ["station:WXPN 88.5"], "search finds the station by call sign", failures)
    host.call("press", "Return")
    wait_for(lambda: "http://radio.example/st-wxpn#omarock-radio=st-wxpn" in mpd_files(socket_path), "tuned")
    host.settle(.5)
    check(len([f for f in mpd_files(socket_path) if "#omarock-radio=" in f]) == 1, "one station in mpd's queue", failures)

    # The station found by search is at the top (NOW PLAYING); A keeps it, in
    # the mpd playlist "Radio".
    wait_for(lambda: host.state()["rows"][:1] == ["station:WXPN 88.5"], "now playing row")
    check(host.state()["sections"][0] == "NOW PLAYING", "the station found by search is listed, at the top", failures)
    host.call("press", "Down")
    wait_for(lambda: host.state()["cursor"] == 0, "cursor on it")
    host.call("press", "A")
    wait_for(lambda: stored(socket_path, "Radio") == ["http://radio.example/st-wxpn#omarock-radio=st-wxpn"], "favourite")
    wait_for(lambda: host.state()["sections"][:1] == ["FAVORITES"], "favourites first")
    check(host.state()["rows"][0] == "station:WXPN 88.5", "A keeps it in the mpd playlist Radio, first in the list", failures)

    # HLS only: dimmed, and Enter says why instead of tuning.
    host.call("press", "/")
    host.call("typeKeys", "hls")
    wait_for(lambda: host.state()["query"] == "hls" and not host.state()["searching"], "hls search")
    host.call("press", "Return")
    wait_for(lambda: "HLS" in host.state()["notice"], "can't play")
    check(not any("st-hls" in f for f in mpd_files(socket_path)), "an HLS-only station isn't tuned: " + host.state()["notice"], failures)
    host.call("press", "Escape")

    host.call("expand", "true")
    host.settle(1)
    host.grab(output / "expanded-radio.png")
    host.call("expand", "false")
    to_source(host, "local")
    host.settle(.5)
    check(mpd_files(socket_path) == local_files and int(mpd_state(socket_path)["song"]) == local_song,
          "back to local: the station is out of the queue and the song resumes", failures)
    host.call("close")


def radio_tuning_scenario(host, socket_path, failures):
    """Tuning takes time (stations here take 1.5 s to connect, as real ones
    take up to a second or two): "Tuning …" at once, "Tuned to …" once mpd has
    sound. A double click is one click, though the first click changes the
    list under the pointer. Two stations picked in quick succession end on
    the second, with one station in the queue and no fall through to local
    music. The station playing isn't tuned again, mpd stuck is said, and a
    station that refuses says so by name."""
    host.call("open")
    wait_for(lambda: "radio" in host.state()["sources"], "radio source")
    host.settle(.5)
    local_files = mpd_files(socket_path)
    local_song = int(mpd_state(socket_path)["song"])
    mpd_client(socket_path, "fake_stream_delay 1.5")
    marked = lambda uuid: f"http://radio.example/{uuid}#omarock-radio={uuid}"
    stations = lambda: [f for f in mpd_files(socket_path) if "#omarock-radio=" in f]
    current = lambda: dict(l.split(": ", 1) for l in mpd_query(socket_path, "currentsong")).get("file", "")
    to_source(host, "radio")
    wait_for(lambda: host.state()["radioMode"] and host.state()["notice"].startswith("Tuned to"), "the first station", timeout=10)

    # A double click on a station found by search: the first click tunes it
    # and the list goes back to the stations, so the second lands on another.
    host.call("press", "/")
    host.call("typeKeys", "kuow")
    wait_for(lambda: host.state()["query"] == "kuow" and not host.state()["searching"], "search")
    host.settle(.3)
    check(host.call("clickRow", 0, "true") == "ok", "double click on KUOW", failures)
    s = host.state()
    check(s["notice"] == "Tuning KUOW 94.9…", "the panel says Tuning at once: " + s["notice"], failures)
    check(s["rows"][0] != "station:KUOW 94.9", "the second click landed on another station: " + s["rows"][0], failures)
    wait_for(lambda: host.state()["notice"] == "Tuned to KUOW 94.9", "Tuned to, once it sounds", timeout=6)
    host.settle(2)
    check(stations() == [marked("st-kuow")] and current() == marked("st-kuow") and mpd_state(socket_path)["state"] == "play"
          and host.state()["radioMode"], "a double click tunes the one station, and it stays on: " + ", ".join(stations()), failures)

    # Two stations in quick succession: the second wins.
    mpd_client(socket_path, *[f'playlistadd Radio "{marked(u)}"' for u in ("st-kexp", "st-wjrr")])
    wait_for(lambda: {"station:KEXP 90.3 FM", "station:101.1 WJRR Orlando's Rock Station"} <= set(host.state()["rows"]), "favourites")
    rows = host.state()["rows"]
    host.call("activate", rows.index("station:KEXP 90.3 FM"), "open")
    host.call("activate", rows.index("station:101.1 WJRR Orlando's Rock Station"), "open")
    wait_for(lambda: host.state()["notice"].startswith("Tuned to"), "tuned", timeout=6)
    host.settle(2)
    check(host.state()["notice"] == "Tuned to 101.1 WJRR Orlando's Rock Station" and stations() == [marked("st-wjrr")]
          and current() == marked("st-wjrr") and mpd_state(socket_path)["state"] == "play",
          "two stations in quick succession end on the second, alone: " + ", ".join(stations()), failures)

    # The station playing: nothing to do.
    adds = lambda: sum(1 for l in BRIDGE["mpd_log"].read_text().splitlines() if l.startswith("addid"))
    before = adds()
    host.call("activate", host.state()["rows"].index("station:101.1 WJRR Orlando's Rock Station"), "open")
    host.settle(.5)
    check(adds() == before and stations() == [marked("st-wjrr")], "picking the station playing doesn't tune it again", failures)

    # mpd stuck (here, held 17 s by one connect): the panel says so, then
    # carries on when mpd answers.
    mpd_client(socket_path, "fake_stream_delay 17")
    host.call("activate", host.state()["rows"].index("station:KUOW 94.9"), "open")
    wait_for(lambda: host.state()["notice"].startswith("mpd isn't answering"), "stuck mpd noticed", timeout=20)
    wait_for(lambda: host.state()["notice"] == "Tuned to KUOW 94.9", "tuned once mpd answers", timeout=10)
    check(stations() == [marked("st-kuow")], "a stuck mpd is said, and the tune completes when it answers", failures)
    mpd_client(socket_path, "fake_stream_delay 1.5")

    # A station that refuses: why, by name, and the radio stays the source.
    mpd_client(socket_path, "fake_stream_refuse st-kexp")
    host.call("activate", host.state()["rows"].index("station:KEXP 90.3 FM"), "open")
    wait_for(lambda: "refused" in host.state()["notice"], "refused", timeout=6)
    s = host.state()
    check(s["notice"] == "KEXP 90.3 FM refused the connection (HTTP 403). Try another, or again later." and s["radioMode"]
          and stations() == [marked("st-kexp")], "a station that refuses says so: " + s["notice"], failures)

    mpd_client(socket_path, "fake_stream_delay 0")
    to_source(host, "local")
    host.settle(.5)
    check(mpd_files(socket_path) == local_files and int(mpd_state(socket_path)["song"]) == local_song,
          "back to local where it was", failures)
    host.call("close")


def real_radio_scenario(host, output, socket_path, failures):
    """The panel against the real Radio Browser, with the fake mpd (which never
    fetches the stream, so nothing plays). Local stations: Washington's."""
    try:
        host.call("settings", json.dumps({"radioBrowser": ""}))
        host.call("open")
        host.settle(.5)
        to_source(host, "radio")
        wait_for(lambda: host.state()["radioMode"] and len(host.state()["rows"]) > 10, "real local stations", timeout=60)
        host.settle(3)
        s = host.state()
        print("now:", s["nowPlaying"], "| rows:", s["rows"][:6], file=sys.stderr)
        check(s["sections"][0].startswith("LOCAL") or s["sections"][0] == "NOW PLAYING",
              f"real local stations: {len(s['rows'])}, e.g. " + ", ".join(s["rows"][:3]), failures)
        host.grab(output / "real-radio.png")
        host.call("press", "/")
        host.call("typeKeys", "wxpn")
        wait_for(lambda: host.state()["query"] == "wxpn" and not host.state()["searching"], "real search", timeout=60)
        host.settle(2)
        s = host.state()
        check(any("WXPN" in r for r in s["rows"]), "real search by call sign: " + ", ".join(s["rows"][:4]), failures)
        host.call("expand", "true")
        host.settle(3)
        host.grab(output / "real-radio-expanded.png")
        host.call("expand", "false")
        host.call("press", "Escape")
        to_source(host, "local")
    finally:
        host.call("close")
        host.call("settings", "{}")


def leave_scenario(host, failures):
    """Closing when the pointer leaves the panel."""
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    host.settle(.5)
    card = host.card()
    w, h = card["width"], card["height"]
    host.settle(.8)
    check(host.state()["opened"], "opening with the pointer elsewhere doesn't close it", failures)
    host.hover(w / 2, h / 2)
    host.settle(.3)
    check(host.state()["pointerArmed"], "the pointer over the panel arms it", failures)
    host.hover(w / 2, h - 40)
    host.settle(.7)
    check(host.state()["opened"], "moving over the rows keeps it open", failures)
    host.hover(w + 40, 20)
    host.settle(.15)
    host.hover(w / 2, h / 2)
    host.settle(.7)
    check(host.state()["opened"], "coming back within the delay keeps it open", failures)
    host.hover(w + 40, 20)
    wait_for(lambda: not host.state()["opened"], "closes on leave", timeout=3)
    check(True, "leaving the panel closes it", failures)

    # Compact from the expanded panel: the card shrinks from under the pointer.
    host.call("open")
    host.call("expand", "true")
    host.settle(.8)
    card = host.card()
    host.hover(card["width"] - 60, 30)
    host.settle(.3)
    check(host.state()["pointerArmed"], "the pointer over Compact in the expanded panel", failures)
    host.call("expand", "false")
    host.settle(1)
    check(host.state()["opened"], "a card that shrinks away from the pointer stays open", failures)
    card = host.card()
    host.hover(card["width"] / 2, card["height"] / 2)
    host.settle(.3)
    host.hover(card["width"] + 40, 20)
    wait_for(lambda: not host.state()["opened"], "closes on leave after Compact", timeout=3)

    host.call("settings", json.dumps({"closeOnLeave": False}))
    host.call("open")
    host.settle(.5)
    host.hover(card["width"] / 2, card["height"] / 2)
    host.settle(.3)
    check(host.state()["pointerArmed"], "the pointer over the panel again", failures)
    host.hover(card["width"] + 40, 20)
    host.settle(.8)
    check(host.state()["opened"], "closeOnLeave off: it stays open", failures)
    host.call("settings", "{}")
    host.call("close")


def browsed(host, top):
    s = host.state()
    return s["browse"] == top and not s["browseLoading"]


def seeks(command_log):
    return sum(1 for line in command_log.read_text().splitlines() if line.startswith("seekcur"))


def browse_scenario(host, output, command_log, failures):
    """Into an artist, into an album, and back out, with real key presses."""
    # In the queue, → no longer seeks; Shift+→ does.
    before = seeks(command_log)
    host.call("press", "Right")
    host.settle(.3)
    plain = seeks(command_log) - before
    host.call("press", "Shift+Right")
    host.settle(.3)
    check(plain == 0 and seeks(command_log) - before == 1, "→ doesn't seek, Shift+→ does", failures)

    pressed = host.call("press", "/")
    check(pressed == "ok" and host.state()["searchFocused"],
          "/ focuses the search box (" + host.call("focusInfo") + ")", failures)
    host.call("typeKeys", "glass")
    wait_for(lambda: host.state()["query"] == "glass" and not host.state()["searching"], "typed search")
    host.settle()
    s = host.state()
    check(s["rows"][0] == "artist:Glass Harbor" and s["hint"].startswith("→ open"),
          "typed 'glass': top result is the artist, hint says → opens it: " + s["hint"], failures)

    # Enter in the search box opens the top result.
    host.call("press", "Return")
    wait_for(lambda: browsed(host, "artist:Glass Harbor"), "artist view")
    host.settle()
    s = host.state()
    check(s["rows"] == ["playall:Play all songs", "album:Low Tide Signals", "album:Paper Satellites",
                        "album:Signal Hill Sampler"], "artist view: " + ", ".join(s["rows"]), failures)
    check(s["sections"][1] == "ALBUMS" and s["sections"][3] == "APPEARS ON"
          and s["subtitles"][3] == "1990 · on 1 of 4 songs",
          "the compilation is under APPEARS ON: " + s["subtitles"][3], failures)
    check(s["cursor"] == 1 and not s["searchFocused"], "cursor starts on the first album, keys leave the search box",
          failures)
    host.grab(output / "compact-artist.png")

    host.call("press", "Down")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "album:Paper Satellites"), "album view")
    host.settle()
    s = host.state()
    check(s["rows"] == ["playalbum:Play the album", "track:Orbit Song", "track:Static Bloom",
                        "track:Long Distance", "track:Satellites"], "album view: " + ", ".join(s["rows"]), failures)
    check(s["browseInfo"]["subtitle"] == "Glass Harbor · 2021", "album heading: " + s["browseInfo"]["subtitle"], failures)
    host.grab(output / "compact-album.png")

    # a adds one song and stays in the album.
    queued = s["queueLength"]
    host.call("press", "Down")
    host.call("press", "a")
    wait_for(lambda: host.state()["queueLength"] == queued + 1, "song added")
    s = host.state()
    check(s["notice"] == "Added Static Bloom to the queue" and s["browse"] == "album:Paper Satellites",
          "a adds the song and stays in the album: " + s["notice"], failures)

    # ← goes back to the artist, with the cursor on the album it came from.
    host.call("press", "Left")
    host.settle(.3)
    s = host.state()
    check(s["browse"] == "artist:Glass Harbor" and s["cursor"] == 2, "← goes back to the artist", failures)
    # → on a song does nothing; Esc also goes back.
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "album:Paper Satellites"), "album view again")
    host.call("press", "Right")
    host.settle(.3)
    s = host.state()
    check(s["browse"] == "album:Paper Satellites" and s["queueLength"] == queued + 1, "→ on a song does nothing",
          failures)
    host.call("press", "Escape")
    host.settle(.3)
    check(host.state()["browse"] == "artist:Glass Harbor", "Esc also goes back", failures)

    # The compilation opens whole, each song with its artist.
    host.call("press", "Down")
    host.call("press", "Return")
    wait_for(lambda: browsed(host, "album:Signal Hill Sampler"), "compilation view")
    host.settle()
    s = host.state()
    check(len(s["rows"]) == 5 and s["subtitles"][1:] == ["Glass Harbor", "Flügel Café", "The Quiet Riots",
                                                         "The Quiet Riots"]
          and s["browseInfo"]["subtitle"] == "Various artists · 1990",
          "a compilation shows all its songs and artists: " + s["browseInfo"]["subtitle"], failures)
    host.grab(output / "compact-compilation.png")

    host.call("expand", "true")
    host.settle(1)
    host.grab(output / "expanded-album.png")
    host.call("expand", "false")
    host.settle(.5)

    # Enter on its second song plays the album from that song.
    host.call("press", "Down")
    host.call("press", "Return")
    wait_for(lambda: host.state()["nowPlaying"].startswith("Am Hafen"), "album playing from song 2")
    host.settle()
    s = host.state()
    check(s["query"] == "" and s["browse"] == "" and s["rows"][:2] == ["queue:Lighthouse", "queue:Am Hafen"]
          and s["queueLength"] == 4 and s["notice"] == "Playing Am Hafen",
          "Enter on song 2 plays the album from there, replacing the queue", failures)

    # A compilation without AlbumArtist tags is one search result, not one per artist.
    host.call("type", "signal")
    wait_for(lambda: not host.state()["searching"], "compilation search")
    host.settle()
    s = host.state()
    albums = [(r, sub) for r, sub in zip(s["rows"], s["subtitles"]) if r.startswith("album:")]
    check([a for a in albums if a[0] == "album:Signal Hill Sampler"] == [("album:Signal Hill Sampler", "3 artists")],
          "one row per compilation: " + str(albums), failures)

    # A two-disc album has a heading per disc; Backspace goes back to the results.
    host.call("type", "basement")
    wait_for(lambda: not host.state()["searching"], "two-disc search")
    host.settle()
    s = host.state()
    host.call("activate", s["rows"].index("album:Live at the Basement"), "open")
    wait_for(lambda: browsed(host, "album:Live at the Basement"), "two-disc album")
    s = host.state()
    check(s["sections"][1] == "DISC 1" and s["sections"][4] == "DISC 2" and s["sections"][2] == "",
          "disc headings: " + str(s["sections"]), failures)
    host.call("press", "Backspace")
    host.settle(.3)
    s = host.state()
    check(s["browse"] == "" and s["query"] == "basement", "Backspace goes back to the results", failures)
    host.call("press", "Escape")
    host.settle(.3)
    check(host.state()["query"] == "" and host.state()["opened"], "Esc then clears the search", failures)

    # Genres: "punk" finds the genre first; → opens it: Shuffle all, its
    # artists (only those with their own album), then one Compilations row.
    host.call("type", "punk")
    wait_for(lambda: not host.state()["searching"] and host.state()["rows"], "genre search")
    host.settle()
    s = host.state()
    check(s["rows"][0] == "genre:Alternative & Punk" and s["sections"][0] == "GENRES" and s["subtitles"][0] == "18 songs",
          "'punk' finds the genre: " + s["rows"][0] + " · " + s["subtitles"][0], failures)
    host.call("move", 1)
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "genre:Alternative & Punk"), "genre view")
    host.settle(1)
    s = host.state()
    check(s["rows"] == ["shuffleall:Shuffle all songs", "artist:The Quiet Riots", "compilations:Compilations"]
          and s["subtitles"][1:] == ["2 albums", "2 albums"] and s["browseInfo"]["subtitle"] == "Genre · 1 artist · 4 albums",
          "genre view: " + ", ".join(s["rows"]) + " | " + " / ".join(s["subtitles"]), failures)
    host.grab(output / "compact-genre.png")
    # The artist opens to their albums, as from search.
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "artist:The Quiet Riots"), "artist from genre")
    s = host.state()
    check("album:Basement Tapes" in s["rows"] and "album:Live at the Basement" in s["rows"],
          "→ on an artist in a genre opens the artist", failures)
    host.call("press", "Left")
    host.settle(.3)
    # Compilations opens to the genre's compilations; a does nothing on it.
    host.call("press", "Down")
    queued = host.state()["queueLength"]
    host.call("press", "a")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "compilations:Compilations"), "compilations")
    host.settle(.5)
    s = host.state()
    check(s["rows"] == ["album:Left Of The Signal", "album:Signal Hill Sampler"] and s["queueLength"] == queued
          and s["browseInfo"]["subtitle"] == "Alternative & Punk · 2 albums",
          "Compilations lists the genre's compilations: " + ", ".join(s["rows"]), failures)
    host.grab(output / "compact-compilations.png")
    host.call("press", "Left")
    host.settle(.3)
    # Enter on Shuffle all: the whole genre, shuffled, replaces the queue.
    host.call("press", "Up")
    host.call("press", "Up")
    host.call("press", "Return")
    wait_for(lambda: host.state()["queueLength"] == 18, "genre queued")
    host.settle()
    s = host.state()
    shuffled = any(l.strip() == "shuffle" for l in command_log.read_text().splitlines())
    check(shuffled and s["notice"] == "Playing Alternative & Punk, shuffled" and s["browse"] == "",
          "Shuffle all queues the genre's 18 songs, shuffled: " + s["notice"], failures)


def finds(command_log):
    return sum(1 for line in command_log.read_text().splitlines() if line.startswith("find "))


def columns_scenario(host, output, command_log, failures):
    """The expanded panel's columns: results with a preview of what → opens,
    then the open level beside the one it came from."""
    host.call("expand", "true")
    host.settle(1)
    host.call("type", "glass")
    wait_for(lambda: not host.state()["searching"] and host.state()["rows"], "expanded search")
    # Nothing highlighted yet: the top result, the artist, is previewed.
    wait_for(lambda: host.state()["preview"] == "artist:Glass Harbor" and host.state()["previewRows"], "preview")
    host.settle(.5)
    s = host.state()
    check(s["columns"] and s["previewRows"][:2] == ["playall:Play all songs", "album:Low Tide Signals"],
          "the right column previews the top result: " + ", ".join(s["previewRows"]), failures)
    host.grab(output / "expanded-columns.png")

    # The preview follows the cursor.
    host.call("move", 1)
    host.call("move", 1)
    wait_for(lambda: host.state()["preview"] == "album:Low Tide Signals" and host.state()["previewRows"], "album preview")
    check(host.state()["previewRows"][1] == "track:Glasswork", "moving the cursor previews the album under it", failures)
    host.call("move", -1)
    wait_for(lambda: host.state()["preview"] == "artist:Glass Harbor" and host.state()["previewRows"], "artist preview")

    # → moves into the preview without asking mpd again; the results stay on the left.
    before = finds(command_log)
    host.call("press", "Right")
    host.settle(.3)
    s = host.state()
    check(s["browse"] == "artist:Glass Harbor" and s["cursor"] == 1 and finds(command_log) == before
          and s["parentRows"][0] == "artist:Glass Harbor",
          "→ opens the previewed artist at once, results on the left", failures)
    host.grab(output / "expanded-columns-artist.png")

    # One deeper: the artist moves to the left column.
    host.call("press", "Down")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "album:Paper Satellites"), "album in columns")
    host.settle(.3)
    s = host.state()
    check(s["depth"] == 2 and s["parentRows"][:2] == ["playall:Play all songs", "album:Low Tide Signals"],
          "→ on an album: the artist on the left, the album on the right", failures)
    host.grab(output / "expanded-columns-album.png")

    # A click in the left column opens that row instead.
    host.call("columnActivate", "parent", 1, "open")
    wait_for(lambda: browsed(host, "album:Low Tide Signals"), "album clicked on the left")
    check(host.state()["depth"] == 2, "a click on the left column opens another album there", failures)

    # ← twice: back at the results, with the artist as the preview again.
    host.call("press", "Left")
    host.call("press", "Left")
    host.settle(.3)
    s = host.state()
    check(s["depth"] == 0 and s["preview"] == "artist:Glass Harbor" and s["cursor"] == 0,
          "← back to the results, the artist previewed again", failures)

    # A click in the preview goes in and opens that row: two levels at once.
    host.call("columnActivate", "preview", 2, "open")
    wait_for(lambda: browsed(host, "album:Paper Satellites"), "album clicked in the preview")
    check(host.state()["depth"] == 2, "a click on an album in the preview opens it", failures)

    for _ in range(3): host.call("press", "Escape")
    host.settle(.3)
    check(host.state()["query"] == "", "Esc backs out level by level, then clears", failures)
    host.call("expand", "false")
    host.settle(.5)


def picked(host, socket_path, name, count):
    wait_for(lambda: not host.state()["pickerOpen"] and len(stored(socket_path, name)) == count,
             f"{name} has {count} songs")


def playlists_scenario(host, output, socket_path, failures):
    """Stored playlists: browse and play one, build them with A, remove
    songs, delete one (after asking), save the queue, find them in search."""
    host.call("press", "P")
    wait_for(lambda: browsed(host, "playlists:Playlists"), "Playlists view")
    s = host.state()
    check(s["rows"] == ["savequeue:Save the queue as a playlist", "playlist:Late Night"] and s["cursor"] == 1
          and s["subtitles"][1] == "4 songs · 10 min" and s["browseRoot"] == "queue",
          "P opens Playlists: " + ", ".join(s["rows"]) + " | " + s["subtitles"][1], failures)
    host.grab(output / "compact-playlists.png")

    # → opens it: Play the playlist, then its songs; one has left the library.
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "playlist:Late Night"), "playlist view")
    host.settle()
    s = host.state()
    check(s["rows"] == ["playplaylist:Play the playlist", "track:Fernweh", "track:Glasswork", "track:01 Missing Song",
                        "track:Schnee"] and s["subtitles"][3] == "Not in the library any more"
          and s["browseInfo"]["subtitle"] == "Playlist · 4 songs · 10 min",
          "the playlist view: " + ", ".join(s["rows"]), failures)
    check(s["hint"] == "Enter play from here · a add to queue · A add to playlist · x remove · i info · ← back · ? keys",
          "hint on a playlist song: " + s["hint"], failures)
    host.grab(output / "compact-playlist.png")

    # Enter on Schnee plays the playlist from Schnee; load skips the missing song.
    for _ in range(3): host.call("press", "Down")
    host.call("press", "Return")
    wait_for(lambda: host.state()["nowPlaying"].startswith("Schnee"), "playlist playing from Schnee")
    host.settle()
    s = host.state()
    check(s["queueLength"] == 3 and s["browse"] == "" and s["notice"] == "Playing Schnee",
          "Enter on a song plays the playlist from it (3 songs queued)", failures)

    # A on an album in search: the picker. A new name makes a new playlist.
    host.call("press", "/")
    host.call("typeKeys", "basement")
    wait_for(lambda: host.state()["query"] == "basement" and not host.state()["searching"], "search")
    host.settle()
    host.call("press", "Down")
    host.call("press", "A")
    wait_for(lambda: host.state()["pickerOpen"], "picker")
    s = host.state()
    check(s["pickerTitle"] == "Basement Tapes" and s["pickerChoices"] == ["Late Night", "new:"],
          "A opens the picker for the album: " + str(s["pickerChoices"]), failures)
    host.call("typeKeys", "Road Trip")
    host.settle(.3)
    s = host.state()
    check(s["pickerChoices"] == ["new:Road Trip"], "a new name offers a new playlist", failures)
    host.grab(output / "compact-picker.png")
    host.call("press", "Return")
    picked(host, socket_path, "Road Trip", 6)
    host.settle(.3)
    s = host.state()
    check(s["notice"] == "New playlist Road Trip, with Basement Tapes" and s["query"] == "basement",
          "Enter makes the playlist with the album's 6 songs: " + s["notice"], failures)

    # In an album, A on one song: the playlist changed last comes first.
    host.call("press", "Down")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "album:Live at the Basement"), "album")
    host.call("press", "Down")
    host.call("press", "A")
    wait_for(lambda: host.state()["pickerOpen"], "picker")
    s = host.state()
    check(s["pickerChoices"] == ["Road Trip", "Late Night", "new:"], "the playlist changed last is first: "
          + str(s["pickerChoices"]), failures)
    host.call("press", "Down")
    host.settle(.2)
    check(host.state()["pickerIndex"] == 1, "↓ in the picker moves to Late Night: "
          + str(host.state()["pickerIndex"]), failures)
    host.call("press", "Up")
    host.settle(.2)
    check(host.state()["pickerIndex"] == 0, "↑ in the picker moves back", failures)
    host.call("press", "Return")
    picked(host, socket_path, "Road Trip", 7)
    check(host.state()["notice"] == "Added Turn It Down to Road Trip", "Enter adds the song to it", failures)
    # ↓ reaches "New playlist…" with nothing typed; typing keeps the cursor
    # there even when the name also matches a playlist.
    host.call("press", "A")
    wait_for(lambda: host.state()["pickerOpen"], "picker")
    host.call("press", "Down")
    host.call("press", "Down")
    host.settle(.2)
    check(host.state()["pickerIndex"] == 2, "↓↓ reaches New playlist…", failures)
    host.call("press", "Return")
    host.settle(.2)
    check(host.state()["pickerOpen"], "Enter on an unnamed New playlist… waits for a name", failures)
    host.call("typeKeys", "Late")
    host.settle(.3)
    s = host.state()
    check(s["pickerChoices"] == ["Late Night", "new:Late"] and s["pickerIndex"] == 1,
          "typing on New playlist… stays on it: " + str(s["pickerChoices"]) + " at " + str(s["pickerIndex"]), failures)
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["pickerOpen"], "picker closed")
    # Typing filters; the typed text is offered as a new name after the matches.
    host.call("press", "Down")
    host.call("press", "A")
    wait_for(lambda: host.state()["pickerOpen"], "picker")
    host.call("typeKeys", "nig")
    host.settle(.3)
    s = host.state()
    check(s["pickerChoices"] == ["Late Night", "new:nig"], "typing filters: " + str(s["pickerChoices"]), failures)
    host.call("press", "Return")
    picked(host, socket_path, "Late Night", 5)

    # P, then Road Trip; x removes a song, and the view follows.
    host.call("press", "P")
    wait_for(lambda: browsed(host, "playlists:Playlists"), "Playlists view")
    s = host.state()
    check(s["query"] == "" and s["rows"][1:] == ["playlist:Late Night", "playlist:Road Trip"],
          "P from search goes to Playlists, by name", failures)
    host.call("press", "Down")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "playlist:Road Trip"), "Road Trip")
    host.call("press", "Down")
    host.call("press", "x")
    picked(host, socket_path, "Road Trip", 6)
    wait_for(lambda: len(host.state()["rows"]) == 7, "the view follows")
    s = host.state()
    check(s["rows"][2] == "track:No Future Plans" and s["cursor"] == 2 and s["notice"] == "Removed Basement from Road Trip",
          "x removes the song from the playlist: " + s["notice"], failures)
    # Another client (mpc) adds a song: the open playlist follows.
    schnee = stored(socket_path, "Late Night")[3]
    mpd_client(socket_path, 'playlistadd "Road Trip" "%s"' % schnee)
    wait_for(lambda: host.state()["rows"][-1] == "track:Schnee", "follows another client")
    check(True, "the open playlist follows another client's playlistadd", failures)

    # ← to Playlists; x asks before deleting. Esc keeps it; x then Enter deletes.
    host.call("press", "Left")
    host.settle(.3)
    host.call("press", "x")
    wait_for(lambda: host.state()["confirmOpen"], "delete dialog")
    host.settle(.3)
    host.grab(output / "compact-delete.png")
    host.call("press", "Escape")
    host.settle(.3)
    s = host.state()
    check(not s["confirmOpen"] and "Road Trip" in s["playlists"] and s["browse"] == "playlists:Playlists",
          "Esc in the dialog keeps the playlist", failures)
    host.call("press", "x")
    wait_for(lambda: host.state()["confirmOpen"], "delete dialog")
    host.call("press", "Return")
    wait_for(lambda: host.state()["rows"] == ["savequeue:Save the queue as a playlist", "playlist:Late Night"], "deleted")
    s = host.state()
    check(stored(socket_path, "Road Trip") == [] and s["notice"] == "Deleted the playlist Road Trip",
          "x, Enter deletes it: " + s["notice"], failures)

    # Save the queue: the top row, then a name.
    host.call("press", "Up")
    host.call("press", "Return")
    wait_for(lambda: host.state()["pickerOpen"], "picker")
    check(host.state()["pickerTitle"] == "The queue", "Save the queue opens the picker", failures)
    host.call("typeKeys", "Saved Queue")
    host.call("press", "Return")
    picked(host, socket_path, "Saved Queue", 3)
    check(host.state()["notice"] == "Saved the queue as Saved Queue", "the queue is saved as a playlist", failures)

    # Search finds playlists by name, first; ▶ plays one.
    host.call("press", "Escape")
    host.settle(.3)
    s = host.state()
    check(s["browse"] == "" and s["rows"][0].startswith("queue:"), "Esc goes back to the queue", failures)
    host.call("type", "late")
    wait_for(lambda: not host.state()["searching"] and host.state()["rows"], "search")
    host.settle()
    s = host.state()
    check(s["rows"][0] == "playlist:Late Night" and s["sections"][0] == "PLAYLISTS" and s["subtitles"][0].startswith("5 songs"),
          "search finds the playlist first: " + s["subtitles"][0], failures)
    host.call("activate", 0, "play")
    wait_for(lambda: host.state()["nowPlaying"].startswith("Fernweh"), "playlist playing")
    check(host.state()["queueLength"] == 4, "▶ plays the playlist, without the missing song", failures)

    # Expanded: P puts the queue and Playlists side by side; → goes into one.
    host.call("expand", "true")
    host.settle(1)
    host.call("press", "P")
    wait_for(lambda: browsed(host, "playlists:Playlists"), "Playlists view")
    host.settle(.5)
    s = host.state()
    check(s["columns"] and s["parentRows"][0].startswith("queue:") and len(s["parentRows"]) == 4,
          "expanded: the queue on the left, Playlists on the right", failures)
    host.grab(output / "expanded-playlists.png")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "playlist:Late Night"), "playlist in columns")
    host.settle(.5)
    s = host.state()
    check(s["parentRows"] == ["savequeue:Save the queue as a playlist", "playlist:Late Night", "playlist:Saved Queue"],
          "→: Playlists on the left, the playlist on the right", failures)
    host.grab(output / "expanded-playlist.png")
    host.call("press", "A")
    wait_for(lambda: host.state()["pickerOpen"], "picker")
    host.settle(.5)
    host.grab(output / "expanded-picker.png")
    host.call("press", "Escape")
    host.settle(.3)
    s = host.state()
    check(not s["pickerOpen"] and s["browse"] == "playlist:Late Night", "Esc closes the picker, nothing else", failures)
    # × on a playlist in the left column asks about that playlist.
    host.call("columnRemove", "parent", 2)
    wait_for(lambda: host.state()["confirmOpen"], "delete dialog")
    host.call("press", "Return")
    wait_for(lambda: "Saved Queue" not in host.state()["playlists"], "deleted from the left column")
    check(host.state()["browse"] == "playlist:Late Night", "× in the left column deletes that playlist", failures)
    host.call("press", "Escape")
    host.call("press", "Escape")
    host.settle(.3)
    check(host.state()["browse"] == "", "Esc twice: back to the queue", failures)
    host.call("expand", "false")
    host.settle(.5)


def info_card(host, what):
    """The info card once it has finished loading."""
    wait_for(lambda: (host.state()["info"] or {}).get("loading") is False, what)
    host.settle(.3)
    return host.state()["info"]


def info_closed(host, key, failures, label):
    host.call("press", key)
    wait_for(lambda: host.state()["info"] is None, label)
    check(host.state()["opened"], label + ", and the panel stays open", failures)


def fake_bridge_info(on):
    """Give the fake bridge GET /v1/info, or take it away (an older bridge)."""
    request = urllib.request.Request(f"http://127.0.0.1:{BRIDGE['port']}/v1/fake/info", method="POST",
                                     data=json.dumps({"on": on}).encode(),
                                     headers={"Authorization": "Bearer fake-bridge-token", "Content-Type": "application/json"})
    urllib.request.urlopen(request, timeout=5).read()


def cursor_to(host, wanted, failures):
    """Move the list cursor to the row "kind:title"."""
    rows = host.state()["rows"]
    if wanted not in rows:
        check(False, f"{wanted} is listed: " + ", ".join(rows), failures)
        return False
    if host.state()["cursor"] < 0: host.call("press", "Down")
    for _ in range(40):
        s = host.state()
        if s["rows"][s["cursor"]] == wanted: return True
        host.call("press", "Down" if s["rows"].index(wanted) > s["cursor"] else "Up")
    return False


def reopen(host):
    """Close and open the panel: it opens with no cursor."""
    host.call("close")
    wait_for(lambda: not host.state()["opened"], "closed")
    host.call("open")
    wait_for(lambda: host.state()["opened"] and host.state()["cursor"] < 0, "open, no cursor")
    host.settle(.3)


def info_scenario(host, output, socket_path, failures):
    """i, the info card: the service at the top and, for Apple
    Music, whether it's in the library; then everything known about the song,
    album, station or channel. Local songs and albums (from the queue, search
    and an album's Play row), Apple Music songs and albums in the library or
    not (with the bridge's /v1/info, and an older bridge without it), a
    SiriusXM channel and a station. i, Esc and ← close it."""
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    fake_bridge_info(False)
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    to_source(host, "local")
    host.call("type", "")
    host.settle(.5)

    # Nothing highlighted: what's playing.
    current = dict(line.split(": ", 1) for line in mpd_query(socket_path, "currentsong"))
    reopen(host)
    host.call("press", "i")
    card = info_card(host, "the info card for the song playing")
    check(card["service"] == "Local music" and card["kind"] == "Song" and card["title"] == current["Title"]
          and card["status"] == "", f"i without a cursor: the song playing: {card['service']} · {card['kind']} · {card['title']}", failures)
    for want in ["FILE: Type = FLAC · 44.1 kHz · 16-bit · stereo", "FILE: Bitrate = 900 kbps (average)",
                 "FILE: Added to mpd = 18 Oct 2026", "SONG: Album = " + current["Album"]]:
        check(want in card["fields"], "the song's card has " + want, failures)
    host.grab(output / "info-local-song.png")
    info_closed(host, "i", failures, "i closes the card")

    # A song from search: its tags, file and stickers; Esc closes the card only.
    host.call("type", "glasswork")
    wait_for(lambda: not host.state()["searching"], "search")
    host.call("press", "Down")
    host.settle(.3)
    check("i info" in host.state()["hint"], "the hint says i: " + host.state()["hint"], failures)
    host.call("press", "i")
    card = info_card(host, "a song's card")
    check(card["title"] == "Glasswork" and "STICKERS: rating = 8" in card["fields"]
          and card["lines"] == ["Glass Harbor", "Low Tide Signals · 2019"]
          and card["cover"].endswith("/Low%20Tide%20Signals/cover.png"),
          "the song's card: tags, stickers and its cover: " + "; ".join(card["lines"] + card["fields"][-2:]), failures)
    info_closed(host, "Escape", failures, "Esc closes the card")
    check(host.state()["query"] == "glasswork", "and the search stays", failures)

    # An album from search: its songs and files together.
    host.call("type", "nachtzug")
    wait_for(lambda: not host.state()["searching"], "search")
    cursor_to(host, "album:Nachtzug", failures)
    host.call("press", "i")
    card = info_card(host, "an album's card")
    for want in ["ALBUM: Album artist = Flügel Café", "ALBUM: Songs = 4", "ALBUM: Length = 14 min",
                 "FILES: Size = 89.6 MB", "FILES: Bitrate = 900 kbps (average)", "FILES: Folder = Flügel Café/Nachtzug",
                 "FILES: Cover = cover.png"]:
        check(want in card["fields"], "the album's card has " + want, failures)
    check(card["kind"] == "Album" and card["title"] == "Nachtzug" and card["lines"] == ["Flügel Café", "1986"],
          "the album's card heading: " + card["title"] + " · " + "; ".join(card["lines"]), failures)
    host.grab(output / "info-local-album.png")
    info_closed(host, "Left", failures, "← closes the card")

    # Inside the album, its Play row stands for the album.
    host.call("press", "Right")
    wait_for(lambda: host.state()["browse"] == "album:Nachtzug" and not host.state()["browseLoading"], "the album")
    host.call("press", "Up")
    host.settle(.3)
    host.call("press", "i")
    card = info_card(host, "the album's card from its Play row")
    check(card["kind"] == "Album" and card["title"] == "Nachtzug", "i on Play the album: the album's card", failures)
    info_closed(host, "i", failures, "i closes it")
    host.call("type", "")
    host.settle(.3)

    # The expanded panel: the same card, wider.
    host.call("expand", "true")
    host.settle(.8)
    reopen(host)
    host.call("press", "i")
    info_card(host, "the card in the expanded panel")
    host.grab(output / "info-expanded.png")
    info_closed(host, "i", failures, "i closes it, expanded")
    host.call("expand", "false")
    host.settle(.5)

    # Apple Music, from an older bridge with no /v1/info: a library search
    # says whether a catalog song is in the library.
    to_source(host, "apple")
    wait_for(lambda: host.state()["appleReady"], "Apple Music mode")
    host.call("type", "husker")
    wait_for(lambda: not host.state()["searching"] and "artist:Hüsker Dü" in host.state()["rows"], "Apple search")
    cursor_to(host, "artist:Hüsker Dü", failures)
    host.call("press", "Right")
    wait_for(lambda: host.state()["browse"] == "artist:Hüsker Dü" and not host.state()["browseLoading"], "the artist")
    cursor_to(host, "song:Something I Learned Today", failures)
    before = len(bridge_requests())
    host.call("press", "i")
    first = host.state()["info"]
    card = info_card(host, "a catalog song's card")
    asked = [(m, p) for m, p, _ in bridge_requests()[before:]]
    check(first["service"] == "Apple Music" and first["status"] in ("Checking your library…", "In your library"),
          "the card opens at once, checking the library: " + first["status"], failures)
    check(card["status"] == "In your library" and card["statusKind"] == "yes",
          "a catalog song you own: In your library (by a library search): " + card["status"], failures)
    check(("GET", "/v1/info/catalog/song/c-so-1") in asked and ("GET", "/v1/search") in asked,
          "it asked /v1/info, then searched the library: " + ", ".join(p for _, p in asked), failures)
    check("APPLE MUSIC: Catalog id = c-so-1" in card["fields"] and "SONG: Album = Zen Arcade" in card["fields"],
          "the song's card has the catalog's details", failures)
    host.call("press", "i")
    cursor_to(host, "song:New Day Rising", failures)
    host.call("press", "i")
    card = info_card(host, "a catalog song not in the library")
    check(card["status"] == "Not in your library" and card["statusKind"] == "no",
          "a catalog song you don't own: Not in your library: " + card["status"], failures)
    host.call("press", "i")

    # With the bridge's /v1/info: the library's details too.
    fake_bridge_info(True)
    cursor_to(host, "song:Something I Learned Today", failures)
    host.call("press", "i")
    card = info_card(host, "a song's card from /v1/info")
    for want in ["YOUR LIBRARY: Plays = 12", "YOUR LIBRARY: Rating = ★★★★☆", "YOUR LIBRARY: Added = 2 Apr 2019",
                 "YOUR LIBRARY: File = Apple Music AAC audio file", "APPLE MUSIC: Link = https://music.apple.com/us/song/c-so-1"]:
        check(want in card["fields"], "the bridge's details: " + want, failures)
    check(card["status"] == "In your library", "and it's in your library", failures)
    host.grab(output / "info-apple-song.png")
    host.call("press", "i")
    host.call("press", "Left")
    wait_for(lambda: host.state()["browse"] == "", "back at the results")
    cursor_to(host, "album:Zen Arcade", failures)
    host.call("press", "i")
    card = info_card(host, "a library album's card")
    check(card["kind"] == "Album" and card["status"] == "In your library"
          and "YOUR LIBRARY: Songs you have = 4 songs of 4" in card["fields"] and "ALBUM: Label = SST Records" in card["fields"],
          "a library album: In your library, with the songs you have: " + "; ".join(card["fields"]), failures)
    host.call("press", "i")
    cursor_to(host, "album:New Day Rising", failures)
    host.call("press", "i")
    card = info_card(host, "a catalog album's card")
    check(card["status"] == "Not in your library" and card["notes"] == "New Day Rising, from 1985.",
          "a catalog album: Not in your library, with Apple's notes: " + card["status"], failures)
    host.grab(output / "info-apple-album.png")
    host.call("press", "i")
    fake_bridge_info(False)
    host.call("type", "")
    host.settle(.3)

    # A SiriusXM channel: favourite or not, what's on.
    to_source(host, "sxm")
    wait_for(lambda: host.state()["sxmMode"] and host.state()["nowPlaying"] != "", "SiriusXM")
    host.call("press", "Down")
    host.settle(.3)
    row = host.state()["rows"][host.state()["cursor"]]
    host.call("press", "i")
    card = info_card(host, "a channel's card")
    check(card["service"] == "SiriusXM" and card["kind"] == "Channel" and "channel:" + card["title"] == row
          and card["status"] in ("In your favourites", "Not in your favourites")
          and any(f.startswith("CHANNEL: Number = ") for f in card["fields"]),
          "the channel's card: " + card["title"] + " · " + card["status"], failures)
    host.grab(output / "info-sxm.png")
    host.call("press", "i")

    # A station: favourite or not, its stream.
    to_source(host, "radio")
    wait_for(lambda: host.state()["radioMode"] and host.state()["nowPlaying"] != "", "the radio")
    host.call("press", "Down")
    host.settle(.3)
    row = host.state()["rows"][host.state()["cursor"]]
    host.call("press", "i")
    card = info_card(host, "a station's card")
    check(card["service"] == "Radio" and card["kind"] == "Station" and "station:" + card["title"] == row
          and any(f.startswith("STREAM: Format = ") for f in card["fields"]) and card["status"] != "",
          "the station's card: " + card["title"] + " · " + card["status"], failures)
    host.grab(output / "info-radio.png")
    host.call("press", "i")
    to_source(host, "local")
    host.call("close")


def apple_idle_scenario(host, socket_path, failures):
    """Once the Mac has been paused for a while (appleIdleStop,
    60 s; 2 s here), mpd stops, so the bridge's mount has no listener. A short
    pause leaves mpd on the stream; Play, or mpd's play (the media keys),
    reconnects it, and the mode stays Apple Music throughout."""
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    host.call("settings", json.dumps({"appleIdleStop": 2}))
    host.call("open")
    to_source(host, "apple")
    wait_for(lambda: host.state()["appleReady"] and host.state()["bar"]["playing"], "Apple Music playing")
    host.settle(2.5)
    stops = lambda: command_count(socket_path, "stop")
    before = stops()

    # A short pause: mpd stays on the stream.
    host.call("press", "Space")
    wait_for(lambda: not host.state()["bar"]["playing"], "paused")
    host.settle(1)
    host.call("press", "Space")
    wait_for(lambda: host.state()["bar"]["playing"], "playing again")
    host.settle(2.5)
    check(stops() == before and mpd_state(socket_path)["state"] == "play",
          "a pause shorter than appleIdleStop leaves mpd on the stream", failures)

    # A long one: mpd stops, still on the stream.
    host.call("press", "Space")
    wait_for(lambda: not host.state()["bar"]["playing"], "paused")
    wait_for(lambda: mpd_state(socket_path)["state"] == "stop", "mpd stopped after the idle time", timeout=8)
    s = host.state()
    check(stops() == before + 1 and s["appleMode"] and s["source"] == "apple",
          "after appleIdleStop paused, mpd stops once, and the mode stays Apple Music", failures)

    # Play in the panel: the Mac resumes, then mpd reconnects.
    host.call("press", "Space")
    wait_for(lambda: mpd_state(socket_path)["state"] == "play", "mpd playing again", timeout=8)
    check(host.state()["bar"]["playing"], "Play resumes the Mac and starts mpd on the stream", failures)

    # The media keys: mpd stopped by the idle stop, then mpd's own play.
    host.call("press", "Space")
    wait_for(lambda: mpd_state(socket_path)["state"] == "stop", "mpd stopped again", timeout=8)
    resumes = len(bridge_requests("/v1/resume"))
    mpd_client(socket_path, "play")
    wait_for(lambda: len(bridge_requests("/v1/resume")) > resumes, "the Mac resumes", timeout=8)
    wait_for(lambda: host.state()["bar"]["playing"], "playing", timeout=8)
    check(True, "mpd's play (the media keys) after the idle stop resumes the Mac", failures)
    host.call("settings", "{}")
    to_source(host, "local")
    host.call("close")


def list_tuning_scenario(host, failures):
    """Tuning a station or channel from the list used to jump the list back
    to the start; it should stay where it is, with the new one selected. For
    a click, Enter, and a click after a mouse-wheel
    scroll, on SiriusXM and the radio: the list stays put, and the station or
    channel tuned is under the cursor."""
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")

    def tuned_in_place(label, index, target, y):
        name = target.split(":", 1)[1]
        wait_for(lambda: host.state()["notice"] == "Tuned to " + name, label + ": tuned to " + name, timeout=10)
        host.settle(.8)
        s = host.state()
        under = s["rows"][s["cursor"]] if s["cursor"] >= 0 else "no cursor"
        check(under == target and abs(s["listY"] - y) <= 2,
              f"{label}: the list stays put ({y} -> {s['listY']}), {target} under the cursor ({under})", failures)

    for source, mode in (("sxm", "sxmMode"), ("radio", "radioMode")):
        to_source(host, source)
        wait_for(lambda: host.state()[mode] and host.state()["nowPlaying"] != "", source)
        reopen(host)
        # The keys: well down the list, then a click on the cursor's row.
        for _ in range(16): host.call("press", "Down")
        host.settle(.5)
        s = host.state()
        index, y = s["cursor"], s["listY"]
        check(y > 0, f"{source}: the list scrolled down to {s['rows'][index]} (y {y})", failures)
        check(host.call("clickRow", index, "false") == "ok", f"{source}: clicked row {index}", failures)
        tuned_in_place(f"{source}, a click", index, s["rows"][index], y)
        # Enter, a few rows on.
        for _ in range(3): host.call("press", "Down")
        host.settle(.4)
        s = host.state()
        host.call("press", "Return")
        tuned_in_place(f"{source}, Enter", s["cursor"], s["rows"][s["cursor"]], s["listY"])
        # The mouse alone: no cursor, the list wheeled down, a click.
        reopen(host)
        host.call("scrollList", 400)
        host.settle(.5)
        s = host.state()
        y = s["listY"]
        target_index = int(host.call("rowAtMiddle"))
        check(host.call("clickRow", target_index, "false") == "ok", f"{source}: clicked row {target_index}", failures)
        tuned_in_place(f"{source}, a click after a wheel", target_index, s["rows"][target_index], y)
        # From search: back to the list, the cursor on it, in the middle.
        name = "Deep Cuts 120" if source == "sxm" else "KW18 88.4 FM"
        kind = "channel" if source == "sxm" else "station"
        host.call("press", "/")
        host.call("typeKeys", name.split()[0] + " " + name.split()[1] if source == "sxm" else "KW18")
        wait_for(lambda: f"{kind}:{name}" in host.state()["rows"] and not host.state()["searching"], "search")
        cursor_to(host, f"{kind}:{name}", failures)
        host.call("press", "Return")
        wait_for(lambda: host.state()["notice"] == "Tuned to " + name, f"{source}: tuned from search", timeout=10)
        host.settle(.8)
        s = host.state()
        middle = int(host.call("rowAtMiddle"))
        check(s["query"] == "" and s["cursor"] >= 0 and s["rows"][s["cursor"]] == f"{kind}:{name}" and abs(middle - s["cursor"]) <= 1,
              f"{source}, from search: the list with {name} under the cursor, mid-view (row {s['cursor']}, middle {middle})", failures)
    to_source(host, "local")
    host.call("close")


def favourite_follow_scenario(host, output, failures):
    """A on a station used to move it to the favourites while the list stayed
    put. A in the list: the cursor follows the station or channel
    up into the favourites, and A again takes it back to its place, each time
    with the list scrolled to show it."""
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")

    def in_view(s):
        middle = int(host.call("rowAtMiddle"))
        return abs(middle - s["cursor"]) <= 1 or (s["listY"] <= 2 and s["cursor"] <= middle)

    for source, mode, name, rest in (("sxm", "sxmMode", "channel:Deep Cuts 115", "ALL CHANNELS"),
                                     ("radio", "radioMode", "station:KW15 85.1 FM", "LOCAL · WASHINGTON")):
        to_source(host, source)
        wait_for(lambda: host.state()[mode] and host.state()["nowPlaying"] != "", source)
        reopen(host)
        cursor_to(host, name, failures)
        host.settle(.4)
        before = host.state()
        check(before["listY"] > 0, f"{source}: {name} is down the list (y {before['listY']})", failures)
        host.call("press", "A")
        def followed(favourite):
            s = host.state()
            if s["cursor"] < 0 or s["rows"][s["cursor"]] != name: return False
            start = s["sections"].index(rest) if rest in s["sections"] else len(s["rows"])
            return (s["cursor"] < start) == favourite
        wait_for(lambda: followed(True), f"{source}: the cursor follows {name} into the favourites", timeout=10)
        host.settle(.4)
        s = host.state()
        check(in_view(s), f"{source}: A, and the cursor follows {name} up to the favourites, in view "
              f"(row {s['cursor']}, y {s['listY']})", failures)
        host.grab(output / f"favourite-follow-{source}.png")
        host.call("press", "A")
        wait_for(lambda: followed(False), f"{source}: the cursor follows {name} back", timeout=10)
        host.settle(.4)
        s = host.state()
        check(in_view(s), f"{source}: A again, and it follows {name} back to its place, in view "
              f"(row {s['cursor']}, y {s['listY']})", failures)
    to_source(host, "local")
    host.call("close")


def sources_switch_scenario(host, socket_path, failures):
    """The sources beyond local music are opt-in settings, which enable them
    and their buttons. Off: no button, and its service isn't
    asked anything. On, its service down: the button stays, and switching
    says why. Internet radio starts on; the others start off."""
    host.call("open")
    host.call("settings", json.dumps({"spotify": False, "appleMusic": False, "siriusXM": False, "radio": False}))
    wait_for(lambda: host.state()["sources"] == ["local"], "only local")
    host.settle(1)
    spotify_before, sxm_before = len(spotify_requests()), len(sxm_requests())
    host.call("close")
    host.call("open")
    host.settle(3)
    s = host.state()
    check(s["sources"] == ["local"] and "m " not in s["hint"],
          "every optional source off: local only, no switch and no m: " + s["hint"], failures)
    check(len(spotify_requests()) == spotify_before and len(sxm_requests()) == sxm_before,
          "Spotify and SiriusXM switched off are asked nothing, even when the panel opens", failures)
    # The defaults, with no settings at all: local and radio.
    host.call("settings", json.dumps({"spotify": None, "appleMusic": None, "siriusXM": None, "radio": None}))
    wait_for(lambda: "radio" in host.state()["sources"], "radio back")
    check(host.state()["sources"] == ["local", "radio"], "by default: local and internet radio: "
          + str(host.state()["sources"]), failures)
    # Spotify on, with omarock-spotify not running: its button, and why not.
    host.call("settings", json.dumps({"spotify": True, "spotifyService": "http://127.0.0.1:9"}))
    wait_for(lambda: "spotify" in host.state()["sources"], "Spotify on")
    host.call("setSource", "spotify")
    wait_for(lambda: "omarock-spotify" in host.state()["notice"], "says why")
    check(host.state()["source"] == "local", "Spotify on but not running: the switch says why: "
          + host.state()["notice"], failures)
    # m past it: local, Spotify (fails), then radio.
    host.call("settings", json.dumps({"spotify": True, "spotifyService": "http://127.0.0.1:9", "appleMusic": False,
                                      "siriusXM": False, "radio": True}))
    wait_for(lambda: host.state()["sources"] == ["local", "spotify", "radio"], "local, Spotify, radio")
    host.call("press", "m")
    wait_for(lambda: "omarock-spotify" in host.state()["notice"], "Spotify fails")
    check("m the radio" in host.state()["hint"], "then the hint's m points past it: " + host.state()["hint"], failures)
    host.call("press", "m")
    wait_for(lambda: host.state()["source"] == "radio", "m goes on to the radio", timeout=10)
    check(True, "m goes on past a source that fails, instead of trying it again", failures)
    host.call("setSource", "local")
    wait_for(lambda: host.state()["source"] == "local", "local")
    host.call("settings", "{}")
    host.call("close")


def fresh_start_scenario(host, socket_path, failures):
    """Each time another plugin reloaded (the shell reloads them all), the bar
    showed only the music note until the panel was opened, while SiriusXM
    played. On each source: the widget made again, and the bar
    shows the song without the panel being opened."""
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    for source, mode in (("sxm", "sxmMode"), ("radio", "radioMode"), ("apple", "appleMode"), ("spotify", "spotifyMode")):
        host.call("open")
        host.call("setSource", source)
        wait_for(lambda: host.state()[mode] and host.state()["bar"]["showSong"], source + " playing")
        before = host.state()["bar"]["text"]
        host.call("close")
        host.call("reload")
        wait_for(lambda: host.call("state", quiet=True) != "", "the widget again")
        shown = lambda: host.state()["bar"]["showSong"] and host.state()["bar"]["text"] != ""
        try:
            wait_for(shown, source + ": the song in the bar", timeout=8)
        except RuntimeError:
            pass
        s = host.state()
        check(shown() and not s["opened"], f"{source}, made again: the bar shows {s['bar']['text']!r} "
              f"(was {before!r}) without the panel opened", failures)
    host.call("open")
    host.call("setSource", "local")
    wait_for(lambda: host.state()["source"] == "local", "local")
    host.call("close")
    BRIDGE["config"].unlink()


def teardown_scenario(host, socket_path, failures):
    """A plugin reload destroys the widget while Apple Music's long poll is
    open; the poll's late answer must not reach the destroyed client ("Cannot
    read property 'inflight' of null" at every reload). The check
    for QML warnings at the end of the run catches it."""
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    host.call("open")
    to_source(host, "apple")
    wait_for(lambda: host.state()["appleReady"], "Apple Music mode")
    host.settle(1)
    host.call("unload")
    host.settle(.3)
    # A change on the Mac: the open long poll answers now.
    request = urllib.request.Request(url + "/v1/shuffle", method="POST", data=json.dumps({"on": True}).encode(),
                                     headers={"Authorization": "Bearer fake-bridge-token", "Content-Type": "application/json"})
    urllib.request.urlopen(request, timeout=5).read()
    time.sleep(1.5)
    check(True, "the long poll answered after the widget was gone", failures)


def start_private_pipewire(env, runtime):
    """A PipeWire of the harness's own (its private runtime directory, so
    never the real one): no device monitors, one silent output standing in for
    your speakers, and omarock's bus pinned to it, as omarock-bus.service runs it. For
    --bus: Quickshell finds the "omarock" node there."""
    home = Path(env["HOME"])
    wp = home / ".config/wireplumber/wireplumber.conf.d"
    wp.mkdir(parents=True, exist_ok=True)
    (wp / "10-no-devices.conf").write_text(
        "wireplumber.profiles = { main = { monitor.alsa = disabled, monitor.alsa-midi = disabled,"
        " monitor.bluez = disabled, monitor.bluez-midi = disabled, monitor.v4l2 = disabled,"
        " monitor.libcamera = disabled } }\n")
    client = home / ".config/pipewire/client.conf.d"
    client.mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "audio/omarock-players.conf", client / "50-omarock-players.conf")
    pw_env = dict(env, PATH="/usr/bin:/bin")
    procs = [subprocess.Popen(["pipewire"], env=pw_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]
    wait_for(lambda: (runtime / "pipewire-0").exists(), "private pipewire")
    procs.append(subprocess.Popen(["wireplumber"], env=pw_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    time.sleep(1.5)
    subprocess.run(["pw-cli", "create-node", "adapter",
                    '{ factory.name = support.null-audio-sink node.name = "alsa_output.test-speakers"'
                    ' node.description = "FAKE speakers" media.class = Audio/Sink audio.position = [ FL FR ]'
                    ' object.linger = true priority.session = 1000 }'], env=pw_env, capture_output=True, timeout=10)
    # As tools/install-audio installs it: pinned to the (fake) speakers.
    bus_conf = home / "omarock-bus.conf"
    bus_conf.write_text((ROOT / "audio/omarock-bus.conf").read_text().replace("@OUTPUT@", "alsa_output.test-speakers"))
    procs.append(subprocess.Popen(["pipewire", "-c", str(bus_conf)], env=pw_env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    wait_for(lambda: '"omarock"' in subprocess.run(["pw-dump"], env=pw_env, capture_output=True, text=True).stdout,
             "omarock's bus in the private pipewire")
    BRIDGE["pw_env"] = pw_env
    return procs


def bus_volume(name="omarock"):
    """A node's volume in the private PipeWire, as wpctl reports it (0-1)."""
    env = BRIDGE["pw_env"]
    objs = json.loads(subprocess.run(["pw-dump"], env=env, capture_output=True, text=True).stdout or "[]")
    node = next((o["id"] for o in objs if o.get("type") == "PipeWire:Interface:Node"
                 and ((o.get("info") or {}).get("props") or {}).get("node.name") == name), None)
    out = subprocess.run(["wpctl", "get-volume", str(node)], env=env, capture_output=True, text=True).stdout
    return float(out.split()[1]) if out.startswith("Volume:") else -1


def set_bus_volume(value):
    env = BRIDGE["pw_env"]
    objs = json.loads(subprocess.run(["pw-dump"], env=env, capture_output=True, text=True).stdout or "[]")
    node = next(o["id"] for o in objs if o.get("type") == "PipeWire:Interface:Node"
                and ((o.get("info") or {}).get("props") or {}).get("node.name") == "omarock")
    subprocess.run(["wpctl", "set-volume", str(node), str(value)], env=env, capture_output=True)


def bus_volume_scenario(host, socket_path, failures):
    """One volume for everything, controlled by omarock. With
    omarock's bus in PipeWire, the knob, + and - and every source's volume are
    the bus's, set at once, and mpd's own volume isn't touched (setvol)."""
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    set_bus_volume(0.40)
    wait_for(lambda: json.loads(host.call("slider", "volumeSlider")).get("value") == 40, "the knob shows the bus's 40")
    check(json.loads(host.call("slider", "volumeSlider")).get("value") == 40,
          "the knob shows the bus's volume (40), not mpd's (72)", failures)
    setvols = command_count(socket_path, "setvol")
    timeline, backwards = drag_volume(host, "bus")
    host.settle(.5)
    check(abs(bus_volume() - 0.90) <= 0.02 and backwards == 0,
          f"dragging the knob sets the bus, smoothly: {bus_volume():.2f}, {backwards} steps back", failures)
    host.call("press", "-")
    host.settle(.5)
    check(abs(bus_volume() - 0.85) <= 0.02, f"- turns the bus down 5: {bus_volume():.2f}", failures)
    check(command_count(socket_path, "setvol") == setvols, "and mpd's own volume isn't touched", failures)
    to_source(host, "radio")
    wait_for(lambda: host.state()["radioMode"], "the radio")
    host.call("press", "+")
    host.settle(.5)
    check(abs(bus_volume() - 0.90) <= 0.02 and json.loads(host.call("slider", "volumeSlider")).get("value") == 90,
          f"on the radio too, + turns the bus up: {bus_volume():.2f}", failures)
    to_source(host, "local")
    host.call("close")


def scratch_scenario(host, output, socket_path, failures):
    """Playlists against a throwaway mpd: real mpd's answers to playlistadd,
    searchaddpl, save, load, playlistdelete and rm."""
    # A middle click on the bar with an empty queue: findadd (base "") window N:N+1, play.
    wait_for(lambda: host.state()["bar"]["queueEmpty"], "empty queue")
    host.click_bar("note", middle=True)
    wait_for(lambda: host.state()["bar"]["showSong"], "a random song")
    s = host.state()
    check(s["queueLength"] == 1 and s["bar"]["playing"], "a middle click on an empty queue plays a random song: "
          + s["bar"]["text"], failures)
    host.grab_bar(output / "scratch-bar.png")
    mpd_client(socket_path, "clear")

    host.call("open")
    host.settle(1)
    host.call("press", "P")
    wait_for(lambda: browsed(host, "playlists:Playlists"), "Playlists view")
    s = host.state()
    check(s["rows"] == ["savequeue:Save the queue as a playlist", "note:No playlists yet"],
          "no playlists yet: " + ", ".join(s["rows"]), failures)
    host.grab(output / "scratch-no-playlists.png")
    host.call("press", "Escape")

    albums = [line[7:] for line in mpd_query(socket_path, "list album") if line.startswith("Album: ")]
    genres = [line[7:] for line in mpd_query(socket_path, "list genre") if line.startswith("Genre: ")]
    songs = len([l for l in mpd_query(socket_path, 'find "(album == \\"%s\\")"' % albums[0]) if l.startswith("file: ")])
    print("scratch library:", albums, genres, file=sys.stderr)

    # An album into a new playlist.
    host.call("type", albums[0])
    wait_for(lambda: not host.state()["searching"] and host.state()["rows"], "search")
    host.settle()
    album = host.state()["rows"].index("album:" + albums[0])
    host.call("press", "Tab")
    for _ in range(album + 1): host.call("press", "Down")
    host.call("press", "A")
    wait_for(lambda: host.state()["pickerOpen"], "picker")
    host.call("typeKeys", "omarock test")
    host.call("press", "Return")
    picked(host, socket_path, "omarock test", songs)
    check(True, f"an album makes a new playlist ({songs} songs)", failures)

    # A whole genre onto it (searchaddpl).
    if genres:
        in_genre = int(next(l for l in mpd_query(socket_path, 'count "(genre == \\"%s\\")"' % genres[0])
                            if l.startswith("songs: "))[7:])
        host.call("type", genres[0])
        wait_for(lambda: not host.state()["searching"] and host.state()["rows"], "genre search")
        host.settle()
        host.call("press", "Tab")
        host.call("press", "Down")
        check(host.state()["rows"][host.state()["cursor"]] == "genre:" + genres[0], "cursor on the genre", failures)
        host.call("press", "A")
        wait_for(lambda: host.state()["pickerOpen"], "picker")
        host.call("press", "Return")
        picked(host, socket_path, "omarock test", songs + in_genre)
        check(True, f"a genre goes onto it with searchaddpl (+{in_genre})", failures)

    # Play it from its third song.
    total = len(stored(socket_path, "omarock test"))
    host.call("press", "P")
    wait_for(lambda: browsed(host, "playlists:Playlists"), "Playlists view")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "playlist:omarock test"), "playlist view")
    host.settle(1)
    s = host.state()
    third = s["rows"][3][len("track:"):]
    host.grab(output / "scratch-playlist.png")
    host.call("press", "Down")
    host.call("press", "Down")
    host.call("press", "Return")
    wait_for(lambda: host.state()["nowPlaying"].startswith(third), "playing from the third song")
    s = host.state()
    check(s["queueLength"] == total, f"Enter plays the playlist from its third song ({third})", failures)

    # x removes a song.
    host.call("press", "P")
    wait_for(lambda: browsed(host, "playlists:Playlists"), "Playlists view")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "playlist:omarock test"), "playlist view")
    host.call("press", "x")
    picked(host, socket_path, "omarock test", total - 1)
    check(True, "x removes a song (playlistdelete)", failures)

    # Save the queue as a new playlist, then onto the old one (save ... append).
    host.call("press", "Left")
    host.settle(.5)
    host.call("press", "Up")
    host.call("press", "Return")
    wait_for(lambda: host.state()["pickerOpen"], "picker")
    host.call("typeKeys", "omarock queue")
    host.call("press", "Return")
    picked(host, socket_path, "omarock queue", total)
    host.call("press", "Return")
    wait_for(lambda: host.state()["pickerOpen"], "picker")
    host.call("typeKeys", "omarock test")
    host.settle(.3)
    check(host.state()["pickerChoices"][0] == "omarock test", "the picker finds the playlist by name", failures)
    host.call("press", "Return")
    picked(host, socket_path, "omarock test", 2 * total - 1)
    check(True, "save append adds the queue to an existing playlist", failures)
    host.grab(output / "scratch-playlists.png")

    # Delete both.
    for name in ["omarock queue", "omarock test"]:
        for _ in range(5):
            if host.state()["rows"][host.state()["cursor"]] == "playlist:" + name: break
            host.call("press", "Down")
        host.call("press", "x")
        wait_for(lambda: host.state()["confirmOpen"], "delete dialog")
        host.call("press", "Return")
        wait_for(lambda: name not in host.state()["playlists"], "deleted " + name)
    check(mpd_query(socket_path, "listplaylists") == [], "both deleted (rm)", failures)
    host.call("close")


def real_scenario(host, output, failures):
    """Read-only: open the panel and search, against the real mpd."""
    host.call("open")
    host.settle(2)
    s = host.state()
    check(s["connected"], "connected to the real mpd: " + s["stateText"], failures)
    print("now playing:", s["nowPlaying"], "| cover:", s["coverUrl"] or "none", file=sys.stderr)
    host.grab(output / "real-compact.png")
    host.call("type", "husker")
    wait_for(lambda: not host.state()["searching"], "search results")
    host.settle()
    s = host.state()
    check(any(r.startswith("artist:H") and "sker" in r for r in s["rows"]),
          "'husker' finds Hüsker Dü: " + ", ".join(s["rows"][:3]), failures)
    host.grab(output / "real-search.png")
    # Opening an artist and an album only reads (find, count, listfiles).
    artist = next(i for i, r in enumerate(s["rows"]) if r.startswith("artist:H") and "sker" in r)
    host.call("activate", artist, "open")
    wait_for(lambda: host.state()["browse"].startswith("artist:") and not host.state()["browseLoading"], "artist")
    host.settle(1)
    s = host.state()
    print("artist view:", s["rows"], s["subtitles"], file=sys.stderr)
    check(len(s["rows"]) > 2 and s["rows"][0] == "playall:Play all songs", "real artist view lists albums", failures)
    host.grab(output / "real-artist.png")
    host.call("activate", 1, "open")
    wait_for(lambda: host.state()["browse"].startswith("album:") and not host.state()["browseLoading"], "album")
    host.settle(1)
    s = host.state()
    print("album view:", s["browseInfo"], s["rows"][:5], file=sys.stderr)
    check(len(s["rows"]) > 2 and s["rows"][1].startswith("track:"), "real album view lists songs", failures)
    host.grab(output / "real-album.png")
    host.call("back")
    host.call("back")
    host.call("back")
    host.call("type", "punk")
    wait_for(lambda: not host.state()["searching"] and host.state()["rows"], "genre search")
    host.settle()
    s = host.state()
    # Your own playlists may match too, and they come first.
    genre = s["rows"].index("genre:Alternative & Punk") if "genre:Alternative & Punk" in s["rows"] else -1
    check(genre >= 0 and all(r.startswith("playlist:") for r in s["rows"][:genre]),
          "'punk' finds Alternative & Punk, after any playlists: " + ", ".join(s["rows"][:genre + 1]), failures)
    host.call("activate", max(genre, 0), "open")
    wait_for(lambda: host.state()["browse"].startswith("genre:") and not host.state()["browseLoading"], "genre")
    host.settle(2)
    s = host.state()
    print("genre view:", s["browseInfo"]["subtitle"], s["rows"][:4], s["subtitles"][:4], file=sys.stderr)
    check(len(s["rows"]) > 100 and s["rows"][0] == "shuffleall:Shuffle all songs"
          and s["rows"][-1] == "compilations:Compilations", "real genre view lists artists, then Compilations",
          failures)
    host.grab(output / "real-genre.png")
    host.call("back")
    host.call("back")
    # The expanded panel's columns.
    host.call("expand", "true")
    host.call("type", "husker")
    wait_for(lambda: host.state()["preview"].startswith("artist:H") and host.state()["previewRows"], "preview")
    host.settle(2)
    check(host.state()["previewRows"][0] == "playall:Play all songs", "real preview of Hüsker Dü", failures)
    host.grab(output / "real-columns.png")
    host.call("activate", 0, "open")
    host.settle(2)
    host.grab(output / "real-columns-artist.png")
    host.call("back")
    host.call("back")
    host.call("expand", "false")
    host.call("expand", "true")
    host.settle(1)
    host.grab(output / "real-expanded.png")
    # Playlists only lists them (listplaylists, playlistlength).
    host.call("press", "P")
    wait_for(lambda: browsed(host, "playlists:Playlists"), "Playlists view")
    host.settle(1)
    s = host.state()
    print("playlists:", s["rows"], file=sys.stderr)
    check(s["rows"][0] == "savequeue:Save the queue as a playlist", "real Playlists view", failures)
    host.grab(output / "real-playlists.png")
    host.call("back")
    host.call("expand", "false")
    host.call("close")


SCRATCH_CONF = """music_directory "{music}"
playlist_directory "{work}/playlists"
db_file "{work}/database"
bind_to_address "{socket}"
port "16699"
zeroconf_enabled "no"
log_level "verbose"
auto_update "no"
audio_output {{
  type "null"
  name "omarock scratch (plays nowhere)"
  mixer_type "none"
}}
"""


def start_scratch_mpd(work, socket_path, music):
    """A throwaway mpd: its own database, playlists and socket, and only the
    null output. Waits until it has indexed MUSIC."""
    scratch = work / "scratch-mpd"
    (scratch / "playlists").mkdir(parents=True)
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    conf = scratch / "mpd.conf"
    conf.write_text(SCRATCH_CONF.format(music=music, work=scratch, socket=socket_path))
    assert conf.read_text().count("audio_output") == 1 and 'type "null"' in conf.read_text()
    proc = subprocess.Popen(["mpd", "--no-daemon", "--stderr", str(conf)],
                            stdout=subprocess.DEVNULL, stderr=(scratch / "mpd.log").open("w"))
    wait_for(socket_path.exists, "scratch mpd socket")
    def indexed():
        status = mpd_query(socket_path, "status")
        stats = mpd_query(socket_path, "stats")
        return not any(l.startswith("updating_db") for l in status) and "songs: 0" not in stats
    wait_for(indexed, "scratch mpd database", timeout=120)
    return proc


def main():
    real = "--real-mpd" in sys.argv
    with_bus = "--bus" in sys.argv
    scratch_music = None
    only = None
    args = []
    argv = sys.argv[1:]
    while argv:
        a = argv.pop(0)
        if a == "--scratch-mpd": scratch_music = Path(argv.pop(0)).resolve()
        elif a == "--only": only = argv.pop(0)
        elif a not in ("--real-mpd", "--bus"): args.append(a)
    output = Path(args[0]).resolve() if args else ROOT / "tools/capture/out"
    output.mkdir(parents=True, exist_ok=True)
    failures = []
    with tempfile.TemporaryDirectory(prefix="omarock-capture-") as work_path:
        work = Path(work_path)
        env, shell, plugin, runtime = prepare(work)
        socket_path = runtime / "mpd/socket"
        command_log = work / "mpd-commands.log"
        (work / "screen.json").write_text(json.dumps({"screens": [dict(
            name="CAPTURE", x=0, y=0, width=2560, height=1600,
            logicalDpi=96, logicalBaseDpi=96, dpr=1)]}))
        env.update(QT_QPA_PLATFORM=f"offscreen:configfile={work / 'screen.json'}",
                   QT_QUICK_BACKEND="software",
                   QT_SCALE_FACTOR="2", OMAROCK_PLUGIN=str(plugin))
        if real:
            socket_path.parent.mkdir()
            socket_path.symlink_to(Path(os.environ["XDG_RUNTIME_DIR"]) / "mpd/socket")
            command_log.touch()
            fake = subprocess.Popen(["sleep", "infinity"])
        elif scratch_music:
            command_log.touch()
            fake = start_scratch_mpd(work, socket_path, scratch_music)
        else:
            fake = subprocess.Popen([sys.executable, "-I", str(TOOLS / "fake_mpd.py"), str(socket_path),
                                     str(work / "music"), str(command_log)], stdout=subprocess.PIPE, text=True)
        # A fake SiriusXM service, always: the panel must never reach the real
        # omarock-sxm on 127.0.0.1:8720 from a test.
        BRIDGE["sxm_log"] = work / "sxm-requests.log"
        sxm = subprocess.Popen([sys.executable, "-I", str(TOOLS / "fake_sxm.py"), str(work / "sxm.port"),
                                str(BRIDGE["sxm_log"])], stdout=subprocess.PIPE, text=True)
        assert sxm.stdout.readline().strip() == "fake sxm ready"
        BRIDGE["sxm"] = f"http://127.0.0.1:{int((work / 'sxm.port').read_text())}"
        env["OMAROCK_SXM"] = BRIDGE["sxm"]
        # And a fake Radio Browser, never the real one; local stations are Washington's.
        BRIDGE["radio_log"] = work / "radio-requests.log"
        radio = subprocess.Popen([sys.executable, "-I", str(TOOLS / "fake_radio.py"), str(work / "radio.port"),
                                  str(BRIDGE["radio_log"])], stdout=subprocess.PIPE, text=True)
        assert radio.stdout.readline().strip() == "fake radio ready"
        env["OMAROCK_RADIO"] = BRIDGE["radio"] = f"http://127.0.0.1:{int((work / 'radio.port').read_text())}"
        radio_config = Path(env["HOME"]) / ".config/omarock/radio.json"
        radio_config.parent.mkdir(parents=True, exist_ok=True)
        radio_config.write_text(json.dumps({"state": "Washington"}))
        bridge = spotify = None
        if not real and not scratch_music:
            # The fake Apple Music bridge, and its token where the panel looks by default.
            token = "fake-bridge-token"
            token_file = Path(env["HOME"]) / ".config/omarock/bridge-token"
            token_file.parent.mkdir(parents=True, exist_ok=True)
            token_file.write_text(token + "\n")
            BRIDGE["config"] = token_file.parent / "apple.json"
            BRIDGE["log"] = work / "bridge-requests.log"
            BRIDGE["mpd_log"] = command_log
            bridge = subprocess.Popen([sys.executable, "-I", str(TOOLS / "fake_bridge.py"), str(work / "bridge.port"),
                                       token, str(BRIDGE["log"])], stdout=subprocess.PIPE, text=True)
            assert bridge.stdout.readline().strip() == "fake bridge ready"
            BRIDGE["port"] = int((work / "bridge.port").read_text())
            # A fake omarock-spotify, watching the fake mpd as the real one
            # watches mpd. Without it (--real-mpd, --scratch-mpd) the panel's
            # Spotify points at a port nothing listens on.
            BRIDGE["spotify_log"] = work / "spotify-requests.log"
            spotify = subprocess.Popen([sys.executable, "-I", str(TOOLS / "fake_bridge.py"), str(work / "spotify.port"),
                                        "", str(BRIDGE["spotify_log"]), "--spotify", str(socket_path)],
                                       stdout=subprocess.PIPE, text=True)
            assert spotify.stdout.readline().strip() == "fake spotify ready"
            env["OMAROCK_SPOTIFY"] = BRIDGE["spotify"] = f"http://127.0.0.1:{int((work / 'spotify.port').read_text())}"
        log = work / "qs.log"
        BRIDGE["qs_log"] = log
        # --bus: a private PipeWire with omarock's bus, for Quickshell to find.
        pipewire = start_private_pipewire(env, runtime) if with_bus else []
        try:
            assert real or scratch_music or fake.stdout.readline().strip() == "fake mpd ready"
            host = Host(env, shell)
            with log.open("w") as stream:
                qs = subprocess.Popen(["qs", "-p", str(shell)], env=env, stdout=stream, stderr=subprocess.STDOUT)
                try:
                    wait_for(lambda: host.call("ready", quiet=True) == "true", "panel connected to fake mpd")
                    if real: real_scenario(host, output, failures)
                    elif scratch_music: scratch_scenario(host, output, socket_path, failures)
                    elif only:
                        # --only bar,leave: just those scenarios, in order.
                        for name in only.split(","):
                            if name == "bar": bar_scenario(host, output, socket_path, failures)
                            elif name == "leave": leave_scenario(host, failures)
                            elif name == "apple": apple_scenario(host, output, socket_path, failures)
                            elif name == "spotify": spotify_scenario(host, output, socket_path, failures)
                            elif name == "real-apple": real_apple_scenario(host, output, socket_path, failures)
                            elif name == "volume": volume_scenario(host, socket_path, failures)
                            elif name == "expanded-keys": expanded_keys_scenario(host, failures)
                            elif name == "sxm": sxm_scenario(host, output, socket_path, failures)
                            elif name == "real-sxm": real_sxm_scenario(host, output, socket_path, failures)
                            elif name == "radio": radio_scenario(host, output, socket_path, failures)
                            elif name == "real-radio": real_radio_scenario(host, output, socket_path, failures)
                            elif name == "radio-tuning": radio_tuning_scenario(host, socket_path, failures)
                            elif name == "info": info_scenario(host, output, socket_path, failures)
                            elif name == "teardown": teardown_scenario(host, socket_path, failures)
                            elif name == "fresh-start": fresh_start_scenario(host, socket_path, failures)
                            elif name == "sources-switch": sources_switch_scenario(host, socket_path, failures)
                            elif name == "apple-idle": apple_idle_scenario(host, socket_path, failures)
                            elif name == "list-tuning": list_tuning_scenario(host, failures)
                            elif name == "favourite-follow": favourite_follow_scenario(host, output, failures)
                            elif name == "bus-volume": bus_volume_scenario(host, socket_path, failures)
                            elif name == "real-apple-info": real_apple_info_scenario(host, output, socket_path, failures)
                            elif name == "real-apple-keys": real_apple_keys_scenario(host, output, socket_path, failures)
                            elif name == "real-apple-catalog": real_apple_catalog_scenario(host, output, socket_path, failures)
                            elif name == "real-apple-watch": real_apple_watch_scenario(host, output, socket_path, failures)
                            else: raise ValueError("no scenario " + name)
                    else: scenarios(host, output, socket_path, command_log, failures)
                    # Then the widget's teardown, for its warnings (the shell's own
                    # plugin reload tears down in another order).
                    host.call("unload")
                    host.settle(.5)
                except Exception as error:
                    print("FAIL", repr(error), file=sys.stderr)
                    failures.append(repr(error))
                finally:
                    qs.terminate()
                    qs.wait(timeout=5)
        finally:
            fake.terminate()
            fake.wait(timeout=10)
            for p in (bridge, spotify):
                if p:
                    p.terminate()
                    p.wait(timeout=10)
            sxm.terminate()
            sxm.wait(timeout=10)
            radio.terminate()
            radio.wait(timeout=10)
            for p in reversed(pipewire):
                p.terminate()
                try: p.wait(timeout=5)
                except subprocess.TimeoutExpired: p.kill()
            shutil.rmtree(runtime, ignore_errors=True)
        if scratch_music:
            # At log level verbose, the scratch mpd logs each command it runs.
            mpd_log = (work / "scratch-mpd/mpd.log").read_text(errors="replace")
            command_log.write_text("".join(line.split('process command "', 1)[1].rsplit('"', 1)[0] + "\n"
                                           for line in mpd_log.splitlines() if 'process command "' in line))
        text = log.read_text()
        shutil.copy(log, output / "qs.log")
        shutil.copy(command_log, output / "mpd-commands.log")
        problems = [line for line in text.splitlines()
                    if ("WARN" in line or "ERROR" in line or "rror:" in line)
                    and ("/plugin/" in line or "shell.qml" in line)]
        for line in problems: print(line, file=sys.stderr)
        check(not problems, "no QML warnings or errors from omarock", failures)
        sent = command_log.read_text().splitlines()
        check(not any(l.strip().split(" ")[0].lower() in OUTPUT_COMMANDS for l in sent),
              f"no output commands among {len(sent)} sent to mpd", failures)
    print(f"\n{len(failures)} failure(s); screenshots and logs in {output}", file=sys.stderr)
    sys.exit(1 if failures else 0)


if __name__ == "__main__": main()
