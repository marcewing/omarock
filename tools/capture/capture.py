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
scenario against real mpd behavior: it makes, plays, edits and deletes stored
playlists there. Your mpd, its playlists and its config are not touched.

The approach follows crmne.mpris's tools/capture (MIT).
"""
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
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
PLUGIN_FILES = ["BarWidget.qml", "Panel.qml", "MpdClient.qml", "Mpd.js", "PlayerCard.qml", "SettingsView.qml",
                "TrackRow.qml", "CoverArt.qml", "KeysHelp.qml", "PlaylistPicker.qml", "manifest.json",
                "Apple.js", "AppleClient.qml", "Sxm.js", "SxmClient.qml", "Radio.js", "RadioClient.qml", "Places.js", "places.tsv", "ScrollingText.qml", "Info.js", "InfoCard.qml",
                "Settings.js", "Hints.js", "TimeMachine.js", "Keeper.js", "ChartStore.js", "ChartClient.qml", "YearPicker.qml",
                "Setup.js", "SetupView.qml", "History.js", "HistoryClient.qml", "Paging.js", "Wave.js", "WavyOutline.qml", "Heard.js",
                "tools/omarock-account", "tools/omarock-sources"]
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
    # Stand-ins first on the panel's PATH: a systemctl that reaches no real
    # services, a terminal that plays a setup out without ./install, and a
    # tailnet, bridges on the network and PipeWire outputs for the setup windows.
    fakes = work / "bin"
    fakes.mkdir()
    (fakes / "systemctl").symlink_to(TOOLS / "fake-systemctl")
    (fakes / "omarchy-launch-floating-terminal-with-presentation").symlink_to(TOOLS / "fake-terminal")
    (fakes / "tailscale").symlink_to(TOOLS / "fake-tailscale")
    (fakes / "avahi-browse").symlink_to(TOOLS / "fake-avahi-browse")
    (fakes / "pactl").symlink_to(TOOLS / "fake-pactl")
    # Never the real compositor: hyprctl only logs, and lists no windows.
    (fakes / "hyprctl").symlink_to(TOOLS / "fake-hyprctl")
    # Never a real machine: nothing here uses ssh or scp (pairing replaced
    # them), and should something start to, it fails rather than reach one.
    (fakes / "ssh").symlink_to("/usr/bin/false")
    (fakes / "scp").symlink_to("/usr/bin/false")
    env = dict(HOME=str(home), PATH=f"{fakes}:/usr/bin:/bin", LANG="C.UTF-8",
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
        (plugin / name).parent.mkdir(parents=True, exist_ok=True)
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
    now_playing_scenario(host, output, socket_path, failures)
    card_keys_scenario(host, output, socket_path, failures)
    lookup_scenario(host, output, socket_path, failures)
    spotify_scenario(host, output, socket_path, failures)
    spotify_volume_scenario(host, socket_path, failures)
    spotify_previews_scenario(host, failures)
    sxm_scenario(host, output, socket_path, failures)
    radio_scenario(host, output, socket_path, failures)
    radio_tuning_scenario(host, socket_path, failures)
    radio_area_scenario(host, output, failures)
    info_scenario(host, output, socket_path, failures)
    library_scenario(host, output, socket_path, failures)
    keep_state_scenario(host, output, failures)
    hints_scenario(host, output, failures)
    list_tuning_scenario(host, failures)
    hover_scroll_scenario(host, failures)
    paging_scenario(host, output, failures)
    search_covers_scenario(host, failures)
    history_scenario(host, output, socket_path, failures)
    scrolling_scenario(host, output, socket_path, failures)
    favorite_follow_scenario(host, output, failures)
    list_exit_scenario(host, output, failures)
    apple_idle_scenario(host, socket_path, failures)
    heard_scenario(host, socket_path, failures)
    elsewhere_scenario(host, socket_path, failures)
    reconnect_scenario(host, socket_path, failures)
    outages_scenario(host, socket_path, failures)
    apple_genres_scenario(host, output, socket_path, failures)
    apple_network_scenario(host, output, socket_path, failures)
    time_machine_scenario(host, output, socket_path, failures)

    # mpd goes away: the panel says so instead of failing silently.
    host.call("close")
    # Last, as it unloads the widget.
    settings_scenario(host, output, failures)
    setup_scenario(host, output, failures)
    sources_switch_scenario(host, socket_path, failures)
    fresh_start_scenario(host, socket_path, failures)
    late_config_scenario(host, failures)
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
    # No dead zones (Marc, 10-22: "landing between the album art and the text").
    check(host.call("clickBarAt", "gap") == "ok", "a click can land between the cover and the song", failures)
    wait_for(lambda: host.state()["opened"], "a click in the gap, at the bar's top edge")
    host.call("clickBarAt", "end")
    wait_for(lambda: not host.state()["opened"], "a click at the widget's end")
    check(True, "the gap between cover and song, the bar's top edge and the widget's end all take the click", failures)

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
    """Press m until the panel's source is `name`: m goes around the sources,
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
                                     headers={"Content-Type": "application/json", "X-Omarock": "1"}, method="POST")
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

    # Search: your library, then Spotify's catalog; no genres. / is the way
    # into the box; in it, it does nothing (Marc, 10-26).
    host.call("press", "/")
    host.call("typeKeys", "husker")
    host.call("press", "/")
    wait_for(lambda: host.state()["query"] == "husker" and not host.state()["searching"], "Spotify search")
    check(host.state()["searchFocused"], "/ in the search box types nothing: " + host.state()["query"], failures)
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
    check(s["headingLine"] == "Playlist · 3 songs · Apple Music Punk" and s["levelButtons"]["current"][-1] == "Add to playlist",
          "its heading has Spotify's count, said once: " + s["headingLine"] + " | " + str(s["levelButtons"]["current"]), failures)
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
    check(host.state()["rows"][2:] == ["playlist:PunkRock", "playlist:Road Songs"], "P lists your Spotify playlists", failures)
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
    check(s["rows"][:3] == ["artist:Hüsker Dü", "album:Zen Arcade", "album:New Day Rising"]
          and s["sections"][:3] == ["YOUR ARTISTS", "YOUR ALBUMS", "APPLE MUSIC · ALBUMS"]
          and "album:Zen Arcade" not in s["rows"][2:] and "artist:Hüsker Dü" not in s["rows"][1:],
          "search lists your library first, then Apple Music, an artist once: " + ", ".join(s["rows"][:5]), failures)
    host.grab(output / "compact-apple-search.png")

    # → into your artist: Apple Music's top songs, your albums, then the
    # catalog's others (Zen Arcade, which you have, once), singles.
    host.call("press", "Down")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "artist:Hüsker Dü"), "Apple artist")
    s = host.state()
    check(s["rows"][0] == "playall:Play top songs" and s["rows"][1] == "song:Something I Learned Today"
          and s["rows"][s["sections"].index("YOUR ALBUMS")] == "album:Zen Arcade"
          and s["rows"][s["sections"].index("APPLE MUSIC ALBUMS")] == "album:New Day Rising"
          and "SINGLES & EPS" in s["sections"] and s["rows"].count("album:Zen Arcade") == 1,
          "your artist's view has the catalog too: " + ", ".join(s["rows"]), failures)
    check(("GET", "/v1/artists/catalog/c-ar-1") in [(m, p) for m, p, _ in bridge_requests("/v1/artists/")],
          "it found the catalog's artist by name", failures)
    host.grab(output / "compact-apple-artist.png")
    # Marc: "a setting that puts the top songs at the top or the bottom ...
    # I'm constantly scrolling past those to see the list of albums".
    host.call("setSetting", "topSongs", "At the bottom", "false")
    host.call("press", "Left")
    wait_for(lambda: host.state()["browse"] == "" or not host.state()["browse"].startswith("artist:"), "back to the results")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "artist:Hüsker Dü"), "Apple artist again")
    s = host.state()
    top = s["sections"].index("TOP SONGS") if "TOP SONGS" in s["sections"] else -1
    check(s["rows"][0] == "playall:Play top songs" and s["sections"][1] == "YOUR ALBUMS" and top > s["sections"].index("APPEARS ON" if "APPEARS ON" in s["sections"] else "SINGLES & EPS")
          and s["rows"][top] == "song:Something I Learned Today" and all(r.startswith("song:") for r in s["rows"][top:]),
          "top songs at the bottom: Play top songs first, then the albums, the songs last: " + ", ".join(s["rows"]), failures)
    host.grab(output / "compact-apple-artist-top-last.png")
    host.call("setSetting", "topSongs", "At the top", "false")
    host.call("press", "Left")
    wait_for(lambda: host.state()["browse"] == "" or not host.state()["browse"].startswith("artist:"), "back to the results")
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "artist:Hüsker Dü"), "Apple artist again")
    s = host.state()
    check(s["rows"][1] == "song:Something I Learned Today", "and at the top again", failures)
    # → into Zen Arcade (yours), then Enter on its third song plays the album from it.
    for _ in range(s["sections"].index("YOUR ALBUMS") - s["cursor"]): host.call("press", "Down")
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
    check(play == {"items": [{"kind": "album", "id": "l-al-1", "source": "library"}], "mode": "play", "start": 2},
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
    check(s["rows"] == ["savequeue:Save the queue as a playlist", "historylist:History", "playlist:PunkRock", "playlist:Road Songs"],
          "P lists your Apple Music playlists: " + ", ".join(s["rows"]), failures)
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "playlist:PunkRock"), "PunkRock")
    s = host.state()
    check(len(s["rows"]) == 5, "PunkRock: Play, then 4 songs", failures)
    check(s["levelButtons"]["current"] == ["Play", "Add to queue", "Add to playlist"]
          and s["headingLine"].startswith("Playlist · 4 songs · ") and s["headingLine"].count("songs") == 1,
          "its heading says how many songs once: " + s["headingLine"] + " | " + str(s["levelButtons"]["current"]), failures)
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
    # mpd plays on, on the same connection: it keeps up with bridge 0.7.0's
    # stream by itself, and a reconnect is a stutter 2 s into the song.
    host.settle(3.5)
    status = mpd_state(socket_path)
    check(command_count(socket_path, "playid") == playids and status["state"] == "play",
          "after a jump mpd plays on, without reconnecting to the stream", failures)
    # appleRejoin is for a bridge before 0.7.0 (no minBitrate in its health),
    # whose stream a stock libFLAC fell behind on: from 0.7.0 it changes nothing.
    host.call("settings", json.dumps({"appleRejoin": True}))
    host.settle(.3)
    host.call("press", "Return")
    wait_for(lambda: len(bridge_requests("/v1/queue/jump")) >= 2, "a second jump")
    host.settle(3.5)
    check(command_count(socket_path, "playid") == playids,
          "with bridge 0.7.0 (health's minBitrate), appleRejoin changes nothing: no reconnect after a jump", failures)
    # An older bridge: mpd reconnects to the stream, at live, 2 s later, once
    # the change has reached the stream (1.5 to 1.8 s). The settings screen
    # asks the bridge's health again as it opens.
    fake_bridge_info(False, "minbitrate")
    healths = len(bridge_requests("/v1/health"))
    host.call("press", ",")
    wait_for(lambda: len(bridge_requests("/v1/health")) > healths, "the bridge's health again")
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["settingsOpen"], "the settings closed")
    host.call("press", "Return")
    jumped = time.monotonic()
    wait_for(lambda: command_count(socket_path, "playid") > playids, "mpd reconnects")
    waited = time.monotonic() - jumped
    current = dict(l.split(": ", 1) for l in mpd_query(socket_path, "currentsong")).get("file")
    check(mpd_state(socket_path)["state"] == "play" and current == stream and 1.5 < waited < 4,
          f"with appleRejoin and a bridge before 0.7.0, mpd reconnects to the stream (playid of its entry) {waited:.1f} s after a jump", failures)
    fake_bridge_info(True, "minbitrate")
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


def real_apple_search_scenario(host, output, socket_path, failures):
    """Read-only, real bridge: what a search finds (OMAROCK_REAL_QUERY), and
    what its first artist (or OMAROCK_REAL_OPEN's kind: genre, album) opens
    to, printed for a look."""
    bridge, stream = real_apple()
    query = os.environ.get("OMAROCK_REAL_QUERY", "husker")
    kind = os.environ.get("OMAROCK_REAL_OPEN", "artist")
    proxy = ReadOnlyProxy(bridge)
    try:
        host.call("settings", json.dumps({"appleBridge": proxy.url, "appleStream": stream,
                                          "appleTokenFile": str(Path.home() / ".config/omarock/bridge-token")}))
        stream_id = mpd_query(socket_path, f'addid "{stream}"')[0].split(": ")[1]
        mpd_client(socket_path, "playid " + stream_id)
        host.call("open")
        wait_for(lambda: host.state()["appleReady"], "real bridge", timeout=30)
        song = host.state()["bridgeSong"] or {}
        print("playing:", {k: song.get(k) for k in ("source", "title", "album", "albumId", "artistId", "catalogId")},
              file=sys.stderr)
        if song:
            # Its album, by the ids in its status or from /v1/info.
            wait_for(lambda: host.state()["playingIds"]["albumId"] != "", "the playing song's album id", timeout=15)
            print("ids:", host.state()["playingIds"], file=sys.stderr)
            host.call("clickPanel", "playingAlbum")
            wait_for(lambda: host.state()["browse"].startswith("album:") and not host.state()["browseLoading"], "its album", timeout=40)
            s = host.state()
            print("album:", s["browse"], "cursor on", s["rows"][s["cursor"]] if s["cursor"] >= 0 else None, file=sys.stderr)
            host.call("press", "Left")
        host.call("expand", "true")
        host.settle(1)
        host.call("press", "/")
        host.call("typeKeys", query)
        wait_for(lambda: host.state()["query"] == query and not host.state()["searching"], "search", timeout=40)
        host.settle(1)
        s = host.state()
        for section, row, subtitle in zip(s["sections"], s["rows"], s["subtitles"]):
            print(f"  {section:28} {row} | {subtitle}", file=sys.stderr)
        host.grab(output / "real-apple-search.png")
        found = [i for i, r in enumerate(s["rows"]) if r.startswith(kind + ":")]
        if found:
            host.call("press", "Down")
            for _ in range(found[0]): host.call("press", "Down")
            host.call("press", "Right")
            wait_for(lambda: host.state()["browse"].startswith(kind + ":") and not host.state()["browseLoading"], kind, timeout=40)
            host.settle(2)
            s = host.state()
            print(kind + ":", s["browse"], s["browseInfo"].get("subtitle", ""), file=sys.stderr)
            for section, row, subtitle in zip(s["sections"], s["rows"], s["subtitles"]):
                print(f"  {section:28} {row} | {subtitle}", file=sys.stderr)
            host.grab(output / f"real-apple-search-{kind}.png")
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


def spotify_volume_scenario(host, socket_path, failures):
    """Spotify without omarock's sound output (the bus): Soloist's own volume
    is the volume (omarock-spotify 0.3's status has it). The knob shows it,
    + and - and a drag set it (POST /v1/volume, one at a time), and mpd's
    is left alone. Each answer takes 0.5 s, so the drag's 16 positions
    can't each get one: answered at once, a busy machine's slow drag sent
    16 and failed (10-28, 11-03)."""
    spotify_post("/v1/fake/volume", {"on": True, "delay": 0.5})
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    to_source(host, "spotify")
    wait_for(lambda: host.state()["spotifyMode"], "Spotify")
    wait_for(lambda: json.loads(host.call("slider", "volumeSlider")).get("value") == 40, "Spotify's volume on the knob")
    check(True, "the knob shows Spotify's own volume (40)", failures)
    setvol_before = command_count(socket_path, "setvol")
    host.call("press", "+")
    wait_for(lambda: ("POST", "/v1/volume", {"volume": 45}) in spotify_requests("/v1/volume"), "+ sets it")
    wait_for(lambda: json.loads(host.call("slider", "volumeSlider")).get("value") == 45, "the knob follows")
    check(True, "+ asks omarock-spotify for 45", failures)
    sent_before = len(spotify_requests("/v1/volume"))
    _, backwards = drag_volume(host, "spotify")
    sent = len(spotify_requests("/v1/volume")) - sent_before
    wait_for(lambda: json.loads(host.call("slider", "volumeSlider")).get("value") == 90, "ends where let go")
    check(backwards == 0 and 0 < sent <= 12 and command_count(socket_path, "setvol") == setvol_before,
          f"a drag sets Spotify's volume ({sent} requests, the knob never backwards), and mpd's isn't touched", failures)
    spotify_post("/v1/fake/volume", {"on": False})
    to_source(host, "local")
    host.call("close")


def spotify_previews_scenario(host, failures):
    """The expanded panel's previews from Spotify load one at a time (Marc,
    10-28: "spotify said 429: too many requests"). Going down the results
    asked omarock-spotify for every row the cursor stopped on, all at once,
    and a Spotify artist page is up to 14 requests to Spotify."""
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    to_source(host, "spotify")
    wait_for(lambda: host.state()["spotifyMode"], "Spotify")
    host.call("expand", "true")
    host.settle(1)
    host.call("type", "husker")
    wait_for(lambda: not host.state()["searching"] and host.state()["previewRows"], "Spotify search, the top result previewed")
    spotify_post("/v1/fake/slowpages", {"on": True})

    def pages():
        return len(spotify_requests("/v1/albums")) + len(spotify_requests("/v1/artists"))

    def results_top():
        return json.loads(host.call("itemAt", "leftColumnList")).get("y")
    before = pages()
    passed = []
    # The results stay where they are while the preview loads and when it
    # has (its heading grows by a row of buttons): they used to follow it.
    tops = [results_top()]
    # The top result (already previewed), then an artist and two albums.
    for _ in range(4):
        host.call("move", 1)
        host.settle(.3)
        s = host.state()
        passed.append(s["rows"][s["cursor"]])
        tops.append(results_top())
    wanted = passed[-1]
    wait_for(lambda: host.state()["preview"] == wanted and host.state()["previewRows"], "the cursor's row previewed")
    tops.append(results_top())
    check(tops[0] is not None and len(set(tops)) == 1,
          f"the results don't move as the preview loads and changes: {tops}", failures)
    asked = pages() - before
    check(len(set(passed)) == 4 and asked <= 2,
          f"3 rows passed to be previewed ({', '.join(passed[1:])}): {asked} asked of omarock-spotify, the first and the last",
          failures)
    spotify_post("/v1/fake/slowpages", {"on": False})
    host.call("back")
    host.call("expand", "false")
    to_source(host, "local")
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
    favorite channel, the list is channels with what's on, n and p change
    channel (replacing the stream in mpd), search, A favorites, Space stops,
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
          "m tunes the first favorite (80s on 8) after the local song", failures)
    st = mpd_state(socket_path)
    check(st["repeat"] == "1" and st["single"] == "1", "a live source plays in mpd's repeat-one mode (a drop reconnects)", failures)
    check(s["stateText"] == "SiriusXM · Playing" and s["nowPlaying"] == "Take It On The Run · REO Speedwagon",
          "the panel shows what's on: " + s["nowPlaying"] + " | " + s["stateText"], failures)
    check(s["rows"][:3] == ["channel:80s on 8", "channel:E Street Radio", "channel:SiriusXM Hits 1"]
          and s["sections"][:3] == ["FAVORITES", "", "ALL CHANNELS"], "the list: favorites, then all channels: "
          + ", ".join(s["rows"][:4]), failures)
    check(s["subtitles"][0] == "REO Speedwagon – Take It On The Run", "each channel says what's on", failures)
    check(s["bar"]["text"] == "REO Speedwagon — Take It On The Run" and "/art/888888/" in s["bar"]["cover"],
          "the bar shows the song and its art", failures)
    host.grab(output / "compact-sxm.png")

    # n: the next favorite, replacing the stream.
    host.call("press", "n")
    wait_for(lambda: host.state()["nowPlaying"].startswith("Badlands"), "next favorite")
    check(mpd_files(socket_path) == local_files[:local_song + 1] + [base + "/stream/ch-20"] + local_files[local_song + 1:],
          "n tunes the next favorite in place of the last", failures)
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

    # A: a favorite.
    host.call("press", "Down")
    host.call("press", "Down")
    host.settle(.2)
    row = host.state()["rows"][host.state()["cursor"]]
    host.call("press", "A")
    wait_for(lambda: any(m in ("POST", "DELETE") for m, _ in sxm_requests("/v1/favorites")), "favorite")
    check(True, "A toggles a favorite (" + row + "): " + str(sxm_requests("/v1/favorites")[-1]), failures)

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
    tunes in the fake mpd only, and doesn't touch favorites."""
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
    a favorite in the mpd playlist "Radio", and back to local where it was."""
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
    wait_for(lambda: stored(socket_path, "Radio") == ["http://radio.example/st-wxpn#omarock-radio=st-wxpn"], "favorite")
    wait_for(lambda: host.state()["sections"][:1] == ["FAVORITES"], "favorites first")
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
    wait_for(lambda: {"station:KEXP 90.3 FM", "station:101.1 WJRR Orlando's Rock Station"} <= set(host.state()["rows"]), "favorites")
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


def radio_area_scenario(host, output, failures):
    """Marc, 10-26: local stations by city, "to be more accurate", for users
    outside the US too, with the next state's ("many big cities are near the
    border of their state, or even sort of straddle a border"). "Your area"
    is found in places.tsv on this machine (the time zone says which country
    first); its stations by coordinates, by the region field and by name,
    near ones first, then the rest of its regions; kept for a day."""
    home = BRIDGE["config"].parents[2]
    cache = home / ".cache/omarock/radio-local.json"
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    to_source(host, "radio")

    def local(s):
        """The local section's name, and its stations."""
        at = next((i for i, sec in enumerate(s["sections"]) if sec.startswith("LOCAL")), None)
        return (s["sections"][at], s["rows"][at:]) if at is not None else ("", [])

    def area_is(section):
        wait_for(lambda: local(host.state())[0] == section, section, timeout=10)
        return host.state()

    s = area_is("LOCAL · WASHINGTON")
    check(s["radioLocal"][:2] == ["KEXP 90.3 FM", "KUOW 94.9"],
          "the old setting, a US state in radio.json, still counts: " + ", ".join(s["radioLocal"][:3]), failures)

    # A city: Portland, Oregon. Near first (by coordinates, by "Portland,
    # OR"), then Washington's, the state across the river; not the other
    # Portland's, nor Canada's.
    searches = len(radio_requests("/json/stations/search"))
    host.call("settings", json.dumps({"radioArea": "Portland, Oregon"}))
    s = area_is("LOCAL · NEAR PORTLAND")
    wait_for(lambda: "station" in host.state()["settingNotes"]["radioArea"]["text"], "its stations counted")
    s = host.state()
    rows = s["radioLocal"]
    check(rows[:5] == ["KOPB 91.5 Portland", "KBOO 90.7 Portland, OR", "Portland Jazz", "KEXP 90.3 FM", "KUOW 94.9"]
          and "WMPG Portland" not in rows and "CBC Radio One Vancouver" not in rows,
          "near Portland: its own first, then Washington's; not Portland, Maine's: " + ", ".join(rows[:6]), failures)
    queries = [r["query"] for r in radio_requests("/json/stations/search")[searches:]]
    check(any("geo_lat" in q for q in queries) and {"Oregon", "Washington", "Portland"} <= {q.get("state") for q in queries},
          "found by coordinates, and by Oregon's, Washington's and Portland's names", failures)
    notes = s["settingNotes"]
    check(notes["radioArea"]["text"].startswith("Portland, Oregon, United States, with Washington · ")
          and notes["radioArea"]["kind"] == "ok" and notes["radio"]["text"] == "Local stations near Portland",
          "the settings say where that is: " + notes["radioArea"]["text"], failures)
    host.grab(output / "compact-radio-area.png")

    # Kept for a day: opening again searches nothing, and the cache has it.
    searches = len(radio_requests("/json/stations/search"))
    host.call("close")
    host.call("open")
    host.settle(1.5)
    check(len(radio_requests("/json/stations/search")) == searches and host.state()["radioLocal"][:1] == ["KOPB 91.5 Portland"],
          "opened again, the stations come from the cache, with no search", failures)
    kept = json.loads(cache.read_text()) if cache.exists() else {}
    check(kept.get("text") == "Portland, Oregon" and len(kept.get("stations", [])) == len(rows),
          "~/.cache/omarock/radio-local.json keeps the area and its stations", failures)

    # One word: the time zone says which Vancouver.
    host.call("settings", json.dumps({"radioArea": "Vancouver", "timeZone": "America/Vancouver"}))
    wait_for(lambda: host.state()["settingNotes"]["radioArea"]["text"].startswith("Vancouver, British Columbia"), "Vancouver, BC")
    s = area_is("LOCAL · NEAR VANCOUVER")
    wait_for(lambda: "station" in host.state()["settingNotes"]["radioArea"]["text"], "its stations counted")
    rows = host.state()["radioLocal"]
    check(host.state()["settingNotes"]["radioArea"]["text"].startswith("Vancouver, British Columbia, Canada, with Washington")
          and rows[:2] == ["CBC Radio One Vancouver", "KEXP 90.3 FM"],
          "in Canada's time zone, Vancouver is BC's, and Washington's across the border count: " + ", ".join(rows[:3]), failures)
    host.call("settings", json.dumps({"radioArea": "Vancouver"}))
    wait_for(lambda: host.state()["settingNotes"]["radioArea"]["text"].startswith("Vancouver, Washington"), "Vancouver, WA")
    wait_for(lambda: "station" in host.state()["settingNotes"]["radioArea"]["text"], "its stations counted")
    rows = host.state()["radioLocal"]
    check(host.state()["settingNotes"]["radioArea"]["text"].startswith("Vancouver, Washington, United States, with Oregon")
          and rows[:1] == ["KOPB 91.5 Portland"] and "CBC Radio One Vancouver" not in rows,
          "in the US's, it's Washington's, with Portland across the river: " + ", ".join(rows[:3]), failures)

    # A place it doesn't know: says so.
    host.call("settings", json.dumps({"radioArea": "Nowhereville"}))
    wait_for(lambda: host.state()["settingNotes"]["radioArea"]["kind"] == "bad", "not found")
    s = host.state()
    check(s["settingNotes"]["radioArea"]["text"].startswith("No city, region or country called Nowhereville")
          and local(s)[1][:1] == ["note:Set your area for its local stations"],
          "a place it doesn't know: the settings say so: " + s["settingNotes"]["radioArea"]["text"], failures)

    host.call("settings", "{}")
    area_is("LOCAL · WASHINGTON")
    to_source(host, "local")
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
    """Closing when the pointer leaves the panel: 3 s later (Marc, 10-24:
    "about a 3 second delay"), unless it comes back."""
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
    host.settle(2)
    host.hover(w / 2, h / 2)
    host.settle(3.5)
    check(host.state()["opened"], "coming back 2 s later keeps it open, for good", failures)
    host.hover(w + 40, 20)
    left = time.monotonic()
    host.settle(2)
    check(host.state()["opened"], "2 s after leaving it's still open", failures)
    wait_for(lambda: not host.state()["opened"], "closes on leave", timeout=6)
    waited = time.monotonic() - left
    check(2.8 <= waited <= 4.5, f"leaving the panel closes it, {waited:.1f} s later", failures)

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
    wait_for(lambda: not host.state()["opened"], "closes on leave after Compact", timeout=6)

    host.call("settings", json.dumps({"closeOnLeave": False}))
    host.call("open")
    host.settle(.5)
    host.hover(card["width"] / 2, card["height"] / 2)
    host.settle(.3)
    check(host.state()["pointerArmed"], "the pointer over the panel again", failures)
    host.hover(card["width"] + 40, 20)
    host.settle(3.5)
    check(host.state()["opened"], "closeOnLeave off: it stays open", failures)
    host.call("settings", "{}")
    host.call("close")


def browsed(host, top):
    s = host.state()
    return s["browse"] == top and not s["browseLoading"]


def now_playing_scenario(host, output, socket_path, failures):
    """The now playing card's links: a click on the album line, the cover or
    the artist's name, or o and O, opens it from the queue, an album on the
    song playing; ← comes back. Then Apple Music's, by the bridge's ids."""
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    host.settle(.5)
    song = dict(line.split(": ", 1) for line in mpd_query(socket_path, "currentsong") if ": " in line)
    title, album, artist = song.get("Title", ""), song.get("Album", ""), song.get("Artist", "")
    genre, albumartist = song.get("Genre", ""), song.get("AlbumArtist", song.get("Artist", ""))

    def opens(how, top):
        wait_for(lambda: browsed(host, top), how + " opens " + top)
        s = host.state()
        check(s["browseRoot"] == "queue" and s["depth"] == 1, how + " opens " + top + " from the queue", failures)
        return s

    def back(label):
        host.call("press", "Left")
        wait_for(lambda: host.state()["browse"] == "", label)
        rows = host.state()["rows"]
        check(rows[:1] != [] and rows[0].startswith("queue:"), label, failures)

    check(host.call("clickPanel", "playingAlbum") == "ok", "the album line can be clicked", failures)
    s = opens("a click on the album", "album:" + album)
    check(s["cursor"] >= 0 and s["rows"][s["cursor"]] == "track:" + title,
          "the album opens on the song playing (" + title + ")", failures)
    host.grab(output / "now-playing-album.png")
    back("← from the album comes back to the queue")
    host.call("clickPanel", "playingCover")
    opens("a click on the cover", "album:" + album)
    back("← from the cover's album comes back to the queue")
    host.call("clickPanel", "playingArtist")
    s = opens("a click on the artist", "artist:" + artist)
    check(s["cursor"] >= 0 and s["rows"][s["cursor"]] == "album:" + album,
          "the artist opens on the album playing (" + album + ")", failures)
    back("← from the artist comes back to the queue")
    host.call("press", "o")
    opens("o", "album:" + album)
    host.call("press", "O")
    opens("O, from the album", "artist:" + artist)
    back("← from O's artist comes back to the queue")
    host.call("clickPanel", "playingGenre")
    s = opens("a click on the genre", "genre:" + genre)
    # A compilation's song (whatever was left playing) has no artist row of
    # its own there: Compilations.
    want = "artist:" + albumartist if "artist:" + albumartist in s["rows"] else "compilations:Compilations"
    check(s["cursor"] >= 0 and s["rows"][s["cursor"]] == want,
          "the genre opens on the artist playing, or Compilations (" + want + ")", failures)
    host.grab(output / "now-playing-genre.png")
    back("← from the genre comes back to the queue")
    host.call("press", "g")
    opens("g", "genre:" + genre)
    back("← from g's genre comes back to the queue")

    # A song on a compilation: the artist opens on it (APPEARS ON), the genre
    # on Compilations, where the genre lists it. Then the queue as it was.
    was = mpd_state(socket_path).get("songid", "")
    file = next(line[6:] for line in mpd_query(socket_path, 'find "(title == \\"Fernweh\\")"') if line.startswith("file: "))
    added = next(line[4:] for line in mpd_query(socket_path, f'addid "{file}"') if line.startswith("Id: "))
    mpd_client(socket_path, "playid " + added)
    wait_for(lambda: host.state()["nowPlaying"].startswith("Fernweh"), "Fernweh, from Left Of The Signal, playing")
    host.call("clickPanel", "playingArtist")
    s = opens("a click on a compilation song's artist", "artist:Flügel Café")
    check(s["cursor"] >= 0 and s["rows"][s["cursor"]] == "album:Left Of The Signal",
          "the artist opens on the compilation, under APPEARS ON: " + json.dumps([s["cursor"], s["rows"]]), failures)
    back("← from the artist comes back to the queue")
    host.call("clickPanel", "playingGenre")
    s = opens("a click on a compilation song's genre", "genre:Alternative & Punk")
    check(s["cursor"] >= 0 and s["rows"][s["cursor"]].startswith("compilations:"),
          "the genre opens on its Compilations: " + json.dumps([s["cursor"], s["rows"]]), failures)
    back("← from the genre comes back to the queue")
    if was: mpd_client(socket_path, "playid " + was)
    mpd_client(socket_path, "deleteid " + added)

    host.call("expand", "true")
    host.settle(1)
    host.call("clickPanel", "playingArtist")
    opens("a click on the expanded panel's artist", "artist:" + artist)
    host.grab(output / "now-playing-expanded.png")
    back("← in the expanded panel comes back to the queue")
    host.call("expand", "false")
    host.settle(.5)

    # Apple Music: the song's albumId and artistId.
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    to_source(host, "apple")
    wait_for(lambda: host.state()["appleReady"] and host.state()["nowPlaying"] != "", "Apple Music playing")
    host.settle(.5)
    title, artist = host.state()["nowPlaying"].split(" · ", 1)
    host.call("clickPanel", "playingAlbum")
    wait_for(lambda: host.state()["browse"].startswith("album:") and not host.state()["browseLoading"],
             "Apple Music's album opens")
    s = host.state()
    check(s["browseRoot"] == "queue" and s["cursor"] >= 0 and s["rows"][s["cursor"]] == "track:" + title,
          "Apple Music's album opens on the song playing: " + s["browse"], failures)
    check(any(path.startswith("/v1/albums/catalog/") for _, path, _ in bridge_requests("/v1/albums/")),
          "it asks the bridge for the song's album by id", failures)
    album = s["browse"][len("album:"):]
    host.call("clickPanel", "playingArtist")
    s = opens("a click on Apple Music's artist", "artist:" + artist)
    check(s["cursor"] >= 0 and s["rows"][s["cursor"]] == "album:" + album,
          "Apple Music's artist opens on the album playing (" + album + ")", failures)
    back("← from Apple Music's artist comes back to the queue")
    # Punk is one of Apple's top genres: its charts.
    host.call("clickPanel", "playingGenre")
    opens("a click on Apple Music's genre", "genre:Punk")
    back("← from Apple Music's genre comes back to the queue")
    # A song whose status has no album or artist id (MusicKit's often don't):
    # /v1/info has them.
    fake_bridge_info(True)
    fake_bridge_info(True, "bare")
    wait_for(lambda: "albumId" not in (host.state()["bridgeSong"] or {"albumId": 1}), "a song without ids")
    song_id = host.state()["bridgeSong"]["id"]
    wait_for(lambda: ("GET", f"/v1/info/catalog/song/{song_id}") in [(m, p) for m, p, _ in bridge_requests("/v1/info/")],
             "the panel asks /v1/info for the ids")
    host.settle(.5)
    host.call("clickPanel", "playingAlbum")
    opens("a click on the album of a song without ids", "album:" + album)
    back("← from it comes back to the queue")
    host.call("clickPanel", "playingArtist")
    opens("a click on the artist of a song without ids", "artist:" + artist)
    back("← from that artist comes back to the queue")
    fake_bridge_info(False, "bare")
    fake_bridge_info(False)
    # A library song whose artist id the bridge can't open (its album isn't
    # one MusicKit lists): the same name in the catalog opens instead. (With
    # /v1/info, as any bridge that sends these has: the panel asks it once a
    # song, and keeps the answer.)
    fake_bridge_info(True)
    fake_bridge_info(True, "orphan")
    wait_for(lambda: (host.state()["bridgeSong"] or {}).get("artistId") == "l-ar-gone", "a song with an artist id that won't open")
    host.settle(.3)
    asked = len(bridge_requests("/v1/artists/"))
    host.call("clickPanel", "playingArtist")
    s = opens("a click on an artist whose id doesn't open", "artist:" + artist)
    paths = [p for _, p, _ in bridge_requests("/v1/artists/")[asked:]]
    check(not (s["browseInfo"] or {}).get("failed") and any(r.startswith("album:") for r in s["rows"])
          and paths[:1] == ["/v1/artists/library/l-ar-gone"] and any(p.startswith("/v1/artists/catalog/") for p in paths),
          "it opens the catalog's artist of that name: " + json.dumps([paths, s["rows"]]), failures)
    back("← from it comes back to the queue")
    fake_bridge_info(False, "orphan")
    fake_bridge_info(False)
    to_source(host, "local")
    BRIDGE["config"].unlink()


def card_keys_scenario(host, output, socket_path, failures):
    """Marc, 10-27, for "fully keyboard driven": the arrows reach the now
    playing card's links. ↑ from the top of the list goes up into the card,
    ↑↓ between its lines and ←→ along the last, Enter does what a click
    does, ↓ from the last line or Esc goes back to the list. A with no
    cursor adds the song playing to a playlist."""
    def reopen_panel():
        host.call("close")
        host.settle(.3)
        host.call("open")
        wait_for(lambda: host.state()["opened"], "open")
        host.settle(.5)

    def to_top():
        host.call("press", "Down")
        for _ in range(len(host.state()["rows"]) + 1):
            if host.state()["cursor"] == 0: return
            host.call("press", "Up")

    def focus(want, label):
        s = host.state()
        check(s["cardFocus"] == want and s["cardBoxes"] == [want] and s["cursor"] == -1,
              label + ": " + json.dumps([s["cardFocus"], s["cardBoxes"], s["cursor"]]), failures)

    reopen_panel()
    if not mpd_query(socket_path, "currentsong"):
        mpd_client(socket_path, "play")
        wait_for(lambda: host.state()["nowPlaying"] != "", "a local song")
        host.settle(.5)
    song = dict(line.split(": ", 1) for line in mpd_query(socket_path, "currentsong") if ": " in line)
    title, album, artist = song.get("Title", ""), song.get("Album", ""), song.get("Artist", "")
    lines = ["artist", "album"] + (["genre"] if song.get("Genre") else [])

    # Tab: the next panel in this part of the bar, Shift+Tab the one before,
    # as in Omarchy's own panels, asked of the bar as omarock's widget. In
    # the settings it goes around their tabs instead.
    before = len(host.state()["panelSwitches"])
    host.call("press", "Tab")
    host.call("press", "Shift+Tab")
    wait_for(lambda: len(host.state()["panelSwitches"]) == before + 2, "Tab asks the bar for the next panel")
    check(host.state()["panelSwitches"][before:] == [{"widget": True, "direction": 1}, {"widget": True, "direction": -1}],
          "Tab and Shift+Tab: the bar's next and previous panel, from omarock's widget: "
          + json.dumps(host.state()["panelSwitches"][before:]), failures)
    host.call("press", ",")
    wait_for(lambda: host.state()["settingsOpen"], "the settings open")
    host.call("press", "Tab")
    host.settle(.3)
    check(len(host.state()["panelSwitches"]) == before + 2 and host.state()["settingsTab"] != "omarock",
          "in the settings Tab goes to their next tab, not another panel: " + host.state()["settingsTab"], failures)
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["settingsOpen"], "the settings close")
    s = host.state()
    check(s["cardLinks"] == [[n] for n in lines] + [["playlist"]], "a local song's links: " + json.dumps(s["cardLinks"]), failures)
    check(s["cardBoxes"] == [], "no box before the keys go there", failures)

    to_top()
    s = host.state()
    check(s["cursor"] == 0 and "↑ now playing" in s["hint"], "at the top of the queue the hints say ↑ goes up: " + s["hint"], failures)
    host.call("press", "Up")
    focus("playlist", "↑ from the top of the queue: Add to playlist, boxed, and no cursor in the list")
    check(host.state()["hint"].startswith("Enter add to playlist · ↑↓ move · Esc to the list"),
          "the hints say what Enter does there: " + host.state()["hint"], failures)
    host.grab(output / "card-keys.png")
    for name in reversed(lines):
        host.call("press", "Up")
        focus(name, "↑ goes up to the " + name)
    host.call("press", "Up")
    focus("artist", "↑ on the top link stays there")
    host.call("press", "Right")
    host.settle(.3)
    check(host.state()["browse"] == "" and host.state()["cardFocus"] == "artist", "→ on a line of one link does nothing", failures)
    host.call("press", "Down")
    focus("album", "↓ goes down to the album")
    host.grab(output / "card-keys-album.png")
    host.call("press", "Return")
    wait_for(lambda: browsed(host, "album:" + album), "Enter on the album opens it")
    s = host.state()
    check(s["cardFocus"] == "" and s["cardBoxes"] == [] and s["browseRoot"] == "queue"
          and s["cursor"] >= 0 and s["rows"][s["cursor"]] == "track:" + title,
          "Enter on the album opens it on the song playing, with the keys in it: " + json.dumps([s["cardFocus"], s["cursor"]]), failures)
    host.call("press", "Left")
    wait_for(lambda: host.state()["browse"] == "", "← back to the queue")

    to_top()
    host.call("press", "Up")
    host.call("press", "Down")
    s = host.state()
    check(s["cardFocus"] == "" and s["cursor"] == 0, "↓ from the last line goes back to the list where it was", failures)
    host.call("press", "Up")
    host.call("press", "Up")
    host.call("press", "Escape")
    s = host.state()
    check(s["opened"] and s["cardFocus"] == "" and s["cursor"] == 0, "Esc goes back to the list, the panel open", failures)
    host.call("press", "Up")
    host.call("press", "Return")
    wait_for(lambda: host.state()["pickerOpen"], "Enter on Add to playlist opens the picker")
    check(host.state()["pickerTitle"] == title, "the picker is for the song playing: " + host.state()["pickerTitle"], failures)
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["pickerOpen"], "the picker closes")
    check(host.state()["cardFocus"] == "playlist", "the keys are still on Add to playlist", failures)

    reopen_panel()
    host.call("press", "A")
    wait_for(lambda: host.state()["pickerOpen"], "A with no cursor opens the picker")
    check(host.state()["pickerTitle"] == title, "A with no cursor: the song playing", failures)
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["pickerOpen"], "the picker closes")

    host.call("expand", "true")
    host.settle(1)
    to_top()
    host.call("press", "Up")
    focus("playlist", "the expanded panel: ↑ from the top goes to the card too")
    for _ in lines: host.call("press", "Up")
    focus("artist", "up to the artist")
    host.grab(output / "card-keys-expanded.png")
    host.call("press", "Return")
    wait_for(lambda: browsed(host, "artist:" + artist), "Enter on the expanded panel's artist opens it")
    host.call("press", "Left")
    wait_for(lambda: host.state()["browse"] == "", "← back to the queue")
    host.call("expand", "false")
    host.settle(.5)

    # Apple Music: Add to library beside Add to playlist, ← → between them.
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    to_source(host, "apple")
    wait_for(lambda: host.state()["appleReady"] and host.state()["nowPlaying"] != "", "Apple Music playing")
    host.settle(.5)
    s = host.state()
    check(s["cardLinks"][-1:] == [["library", "playlist"]], "Apple Music's last line: Add to library, Add to playlist: "
          + json.dumps(s["cardLinks"]), failures)
    to_top()
    host.call("press", "Up")
    focus("library", "↑ from the top: Add to library, the first on the last line")
    check(host.state()["hint"].startswith("Enter add to library · ↑↓←→ move"), "its hints: " + host.state()["hint"], failures)
    host.call("press", "Right")
    focus("playlist", "→ to Add to playlist")
    host.call("press", "Right")
    focus("playlist", "→ at the end stays")
    host.call("press", "Left")
    focus("library", "← back to Add to library")
    host.call("press", "Right")
    host.call("press", "Up")
    above = s["cardLinks"][-2][0]
    focus(above, "↑ from Add to playlist to the line above (" + above + ")")
    host.call("press", "Down")
    focus("library", "↓ again lands on the line's first")
    host.call("press", "Escape")
    to_source(host, "local")
    BRIDGE["config"].unlink()
    # The switch's notice, gone before the next scenario reads the hint line.
    wait_for(lambda: host.state()["notice"] == "", "the notice clears")


def library_scenario(host, output, socket_path, failures):
    """The now playing card's Add to library and Add to playlist, L on a row,
    and the info card's link. Local music: Add to playlist only. Apple Music
    adds and can't take out; an older bridge says to update it. Spotify adds
    and takes out again."""
    def reopen_panel():
        host.call("close")
        host.settle(.3)
        host.call("open")
        wait_for(lambda: host.state()["opened"], "open")
        host.settle(.5)

    def library_said(want, label):
        wait_for(lambda: host.state()["playingLibrary"] == want, label)

    reopen_panel()
    if not mpd_query(socket_path, "currentsong"):
        mpd_client(socket_path, "play")
        wait_for(lambda: mpd_query(socket_path, "currentsong"), "a local song")
        host.settle(.5)
    song = dict(line.split(": ", 1) for line in mpd_query(socket_path, "currentsong") if ": " in line)
    s = host.state()
    check(s["playingLibrary"] == "" and s["canAddPlayingToPlaylist"],
          "local music: the card offers Add to playlist, not Add to library", failures)
    check(host.call("clickPanel", "playingLibrary") == "not shown", "no Add to library link on local music", failures)
    check(host.call("clickPanel", "playingAddToPlaylist") == "ok", "the card's Add to playlist can be clicked", failures)
    wait_for(lambda: host.state()["pickerOpen"], "the picker")
    check(host.state()["pickerTitle"] == song.get("Title", ""), "it's for the song playing: " + host.state()["pickerTitle"], failures)
    host.call("typeKeys", "Card Picks")
    host.settle(.3)
    host.call("press", "Return")
    picked(host, socket_path, "Card Picks", 1)
    check(stored(socket_path, "Card Picks") == [song["file"]], "the song playing is in the new playlist", failures)
    mpd_client(socket_path, 'rm "Card Picks"')

    # Apple Music: the song playing isn't in the library.
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    fake_bridge_info(True, "library")
    to_source(host, "apple")
    wait_for(lambda: host.state()["appleReady"] and host.state()["nowPlaying"] != "", "Apple Music playing")
    reopen_panel()
    song = host.state()["bridgeSong"]
    library_said("󰐕 Add to library", "the card offers Add to library")
    host.grab(output / "library-card.png")
    check(host.call("clickPanel", "playingLibrary") == "ok", "Add to library can be clicked", failures)
    library_said("󰄬 In your library", "the card says it's in your library")
    adds = bridge_requests("/v1/library/add")
    check(adds and adds[-1][2] == {"items": [{"kind": "song", "id": song["id"], "source": "catalog"}]},
          "it asks the bridge to add the song: " + json.dumps(adds[-1:]), failures)
    wait_for(lambda: host.state()["notice"] == f"Added {song['title']} to your Apple Music library", "says so")
    # Apple Music's API can't take it out: L says it's there already.
    host.call("press", "L")
    wait_for(lambda: host.state()["notice"] == song["title"] + " is in your library already", "L: there already")
    check(len(bridge_requests("/v1/library/add")) == len(adds), "and asks nothing more", failures)
    # The info card agrees, though the bridge took a while (the library search
    # of an older bridge doesn't find it): what was added here counts.
    fake_bridge_info(False)
    host.call("press", "i")
    card = info_card(host, "the song playing's card")
    check(card["statusKind"] == "yes" and host.state()["infoAction"] == "",
          "the info card: In your library, nothing to click: " + card["status"], failures)
    host.call("press", "i")
    fake_bridge_info(True)

    # L on a search result: the album.
    host.call("press", "/")
    host.call("typeKeys", "workbook")
    wait_for(lambda: host.state()["query"] == "workbook" and not host.state()["searching"], "search workbook")
    cursor_to(host, "album:Workbook", failures)
    host.call("press", "L")
    wait_for(lambda: host.state()["notice"] == "Added Workbook to your Apple Music library", "L adds the album")
    check(bridge_requests("/v1/library/add")[-1][2] == {"items": [{"kind": "album", "id": "c-al-3", "source": "catalog"}]},
          "L asks the bridge to add the album", failures)
    # An artist can't go in the library.
    host.call("type", "mould")
    wait_for(lambda: host.state()["query"] == "mould" and not host.state()["searching"], "search mould")
    cursor_to(host, "artist:Bob Mould", failures)
    before = len(bridge_requests("/v1/library/add"))
    host.call("press", "L")
    wait_for(lambda: host.state()["notice"] == "Your Apple Music library takes songs, albums and playlists", "L on an artist")
    check(len(bridge_requests("/v1/library/add")) == before, "an artist isn't sent", failures)
    # The info card's link, on a song not in the library.
    cursor_to(host, "song:Sunspots", failures)
    host.call("press", "i")
    card = info_card(host, "Sunspots' card")
    check(card["statusKind"] == "no" and host.state()["infoAction"] == "Add to library (L)",
          "the info card offers Add to library: " + host.state()["infoAction"], failures)
    host.grab(output / "library-info.png")
    host.call("press", "L")
    wait_for(lambda: (host.state()["info"] or {}).get("statusKind") == "yes" and not host.state()["info"]["loading"],
             "the info card says it's in your library now")
    check(host.state()["infoAction"] == "", "and offers nothing more", failures)
    host.call("press", "i")
    # An older bridge: the panel says to update it.
    fake_bridge_info(False, "library")
    cursor_to(host, "song:See a Little Light", failures)
    host.call("press", "L")
    wait_for(lambda: host.state()["notice"] == "To add to your library, update the bridge on the Mac (./install there)",
             "an older bridge: update it")
    fake_bridge_info(True, "library")
    fake_bridge_info(False)

    # An album says how much of it is yours, and marks the songs you have.
    def album_said(want, label):
        wait_for(lambda: (host.state()["albumLibrary"] or {}).get("text") == want, label)
    host.call("type", "new day rising")
    wait_for(lambda: host.state()["query"] == "new day rising" and not host.state()["searching"], "search new day rising")
    cursor_to(host, "album:New Day Rising", failures)
    host.call("press", "Right")
    wait_for(lambda: host.state()["browse"] == "album:New Day Rising" and not host.state()["browseLoading"], "the album")
    # The song the card added is marked if it's on this album (that depends on
    # what Apple Music was left playing).
    def row(title): return host.state()["rows"].index("track:" + title)
    def heading(n): return f"󰄬 {n} of 3 in your library" if n else "󰐕 Add to library"
    mine = [song["title"]] if song.get("albumId") == "c-al-2" else []
    add = next(t for t in ("Celebrated Summer", "Girl Who Lives on Heaven Hill") if t not in mine)
    album_said(heading(len(mine)), "the heading: " + heading(len(mine)))
    s = host.state()
    check(sorted(s["albumLibrary"]["owned"]) == sorted(row(t) for t in mine)
          and s["albumLibrary"]["hover"] == ("󰐕 Add the album" if mine else ""),
          "the songs you have are marked: " + json.dumps(s["albumLibrary"]), failures)
    cursor_to(host, "track:" + add, failures)
    host.call("press", "L")
    wait_for(lambda: host.state()["notice"] == f"Added {add} to your Apple Music library", "L adds the song")
    album_said(heading(len(mine) + 1), "the heading: " + heading(len(mine) + 1))
    s = host.state()
    check(sorted(s["albumLibrary"]["owned"]) == sorted(row(t) for t in mine + [add])
          and s["albumLibrary"]["hover"] == "󰐕 Add the album",
          "the song added is marked, and a click adds the album: " + json.dumps(s["albumLibrary"]), failures)
    host.grab(output / "library-album.png")
    # The info card on its Play row says the same.
    fake_bridge_info(True)
    cursor_to(host, "playalbum:Play the album", failures)
    host.call("press", "i")
    card = info_card(host, "the album's card")
    check(card["statusKind"] == "some" and card["status"] == f"{len(mine) + 1} of 3 songs in your library"
          and host.state()["infoAction"] == "Add to library (L)", "the album's info card: " + card["status"], failures)
    host.call("press", "i")
    wait_for(lambda: host.state()["info"] is None, "the card closed")
    fake_bridge_info(False)
    check(host.call("clickPanel", "albumLibrary") == "ok", "the heading's line can be clicked", failures)
    album_said("󰄬 In your library", "the heading: In your library")
    check(bridge_requests("/v1/library/add")[-1][2] == {"items": [{"kind": "album", "id": "c-al-2", "source": "catalog"}]},
          "the click adds the album", failures)
    s = host.state()
    check(s["albumLibrary"]["owned"] == [] and not s["albumLibrary"]["active"], "no marks once it's all yours, nothing to click", failures)
    cursor_to(host, "playalbum:Play the album", failures)
    host.call("press", "L")
    wait_for(lambda: host.state()["notice"] == "New Day Rising is in your library already", "L on its Play row: there already")
    # Opened again, it's the bridge that says so.
    host.call("press", "Left")
    cursor_to(host, "album:New Day Rising", failures)
    host.call("press", "Right")
    wait_for(lambda: host.state()["browse"] == "album:New Day Rising" and not host.state()["browseLoading"], "the album again")
    album_said("󰄬 In your library", "the bridge's inLibrary: In your library")
    # An older bridge doesn't say: Add to library, as the card says.
    fake_bridge_info(True, "bare")
    host.call("type", "makes no sense")
    wait_for(lambda: host.state()["query"] == "makes no sense" and not host.state()["searching"], "search makes no sense")
    cursor_to(host, "album:Makes No Sense at All", failures)
    host.call("press", "Right")
    wait_for(lambda: host.state()["browse"] == "album:Makes No Sense at All" and not host.state()["browseLoading"],
             "an album, from an older bridge")
    album_said("󰐕 Add to library", "an older bridge: Add to library")
    fake_bridge_info(False, "bare")
    host.call("press", "Left")
    host.call("press", "Escape")

    # A library song only on a playlist added to the library (bridge 0.4.2):
    # /v1/info says it isn't in the library, and Add to library adds its
    # catalog copy, since the bridge adds catalog items only.
    fake_bridge_info(True, "library")
    fake_bridge_info(True)
    fake_bridge_info(True, "orphan")
    reopen_panel()
    wait_for(lambda: (host.state()["bridgeSong"] or {}).get("source") == "library", "a library song only on a playlist")
    song = host.state()["bridgeSong"]
    library_said("󰐕 Add to library", "the card offers Add to library, though it plays from the library")
    host.call("press", "i")
    card = info_card(host, "its info card")
    check(card["statusKind"] == "no" and host.state()["infoAction"] == "Add to library (L)",
          "its info card: " + card["status"] + ", " + host.state()["infoAction"], failures)
    before = len(bridge_requests("/v1/library/add"))
    host.call("press", "L")
    wait_for(lambda: (host.state()["info"] or {}).get("statusKind") == "yes" and not host.state()["info"]["loading"],
             "the info card says it's in your library now")
    adds = [body for _, _, body in bridge_requests("/v1/library/add")[before:]]
    check(adds == [{"items": [{"kind": "song", "id": song["id"][2:], "source": "catalog"}]}],
          "L adds its catalog copy: " + json.dumps(adds), failures)
    host.call("press", "i")
    library_said("󰄬 In your library", "and the card says so")
    fake_bridge_info(False, "orphan")
    fake_bridge_info(False)

    # Spotify: add, then a click on In your library takes it out.
    host.call("setSource", "spotify")
    wait_for(lambda: host.state()["spotifyMode"] and host.state()["nowPlaying"] != "", "Spotify playing")
    reopen_panel()
    song = host.state()["bridgeSong"]
    add, remove = "󰐕 Add to library", "󰄬 In your library"
    # The song Spotify was left on may be one the (fake) library has.
    wait_for(lambda: host.state()["playingLibrary"] in (add, remove), "Spotify's card says whether it's in your library")
    owned = host.state()["playingLibrary"] == remove
    item = {"items": [{"kind": "song", "id": song["id"], "source": song["source"]}]}
    for step in range(2):
        taking_out = owned != (step == 1)
        host.call("clickPanel", "playingLibrary")
        library_said(add if taking_out else remove, "Spotify: a click " + ("takes it out" if taking_out else "adds it"))
        asked = spotify_requests("/v1/library/remove" if taking_out else "/v1/library/add")
        check(asked and asked[-1][2] == item, "it asks omarock-spotify to " + ("take it out" if taking_out else "add it"), failures)
        wait_for(lambda: host.state()["notice"] == (f"Took {song['title']} out of your Spotify library" if taking_out
                                                    else f"Added {song['title']} to your Spotify library"), "says so")
    # A Spotify album: saved apart from its songs, and taken out again.
    host.call("press", "/")
    host.call("typeKeys", "workbook")
    wait_for(lambda: host.state()["query"] == "workbook" and not host.state()["searching"], "Spotify: search workbook")
    cursor_to(host, "album:Workbook", failures)
    host.call("press", "Right")
    wait_for(lambda: host.state()["browse"] == "album:Workbook" and not host.state()["browseLoading"], "Spotify's album")
    wait_for(lambda: (host.state()["albumLibrary"] or {}).get("text") == "󰐕 Add to library", "Spotify's album: Add to library")
    cursor_to(host, "track:Sunspots", failures)
    host.call("press", "L")
    wait_for(lambda: (host.state()["albumLibrary"] or {}).get("text") == "󰄬 1 of 2 in your library", "Spotify: a liked song, 1 of 2")
    host.call("clickPanel", "albumLibrary")
    wait_for(lambda: (host.state()["albumLibrary"] or {}).get("text") == "󰄬 In your library", "Spotify: the album saved")
    s = host.state()
    check(s["albumLibrary"]["hover"] == "󰅖 Remove from library" and s["albumLibrary"]["active"]
          and s["albumLibrary"]["owned"] == [s["rows"].index("track:Sunspots")],
          "saved: a click takes it out, and the liked song is still marked: " + json.dumps(s["albumLibrary"]), failures)
    host.call("clickPanel", "albumLibrary")
    wait_for(lambda: (host.state()["albumLibrary"] or {}).get("text") == "󰄬 1 of 2 in your library", "Spotify: the album taken out")
    check(spotify_requests("/v1/library/remove")[-1][2] == {"items": [{"kind": "album", "id": "c-al-3", "source": "catalog"}]},
          "it asks omarock-spotify to take the album out", failures)
    host.call("press", "Escape")
    spotify_post("/v1/fake/library", {"on": True})
    to_source(host, "local")
    BRIDGE["config"].unlink()


def keep_state_scenario(host, output, failures):
    """Closing the panel and opening it again leaves it as it was: the
    search, where you'd browsed to, the cursor, the info card, the picker,
    settings and the expanded view, with the keys back where they were. A
    setting being typed is dropped, not saved."""
    def reopen():
        host.call("hide")
        wait_for(lambda: not host.state()["opened"], "closed")
        host.settle(.3)
        host.call("open")
        wait_for(lambda: host.state()["opened"], "open again")
        host.settle(.5)

    host.call("close")
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    host.settle(.3)
    # Typing a search: it's still there, and so are the keys.
    host.call("press", "/")
    host.call("typeKeys", "flug")
    wait_for(lambda: host.state()["query"] == "flug" and not host.state()["searching"], "search flug")
    rows = host.state()["rows"]
    reopen()
    s = host.state()
    check(s["query"] == "flug" and s["rows"] == rows, "the search is still there", failures)
    check(host.call("focusName") == "search", "typing goes on in the search box: " + host.call("focusName"), failures)
    host.call("typeKeys", "el")
    wait_for(lambda: host.state()["query"] == "flugel" and not host.state()["searching"], "typing goes on")

    # Browsing: the level, the cursor, and the keys on the list.
    cursor_to(host, "artist:Flügel Café", failures)
    host.call("press", "Right")
    wait_for(lambda: host.state()["browse"] == "artist:Flügel Café" and not host.state()["browseLoading"], "the artist")
    host.call("press", "Down")
    host.settle(.2)
    before = host.state()
    check(before["cursor"] >= 1, "the cursor moved down the artist: " + str(before["rows"]), failures)
    reopen()
    s = host.state()
    check(s["browse"] == before["browse"] and s["cursor"] == before["cursor"] and s["query"] == "flugel",
          f"still on the artist, cursor on row {s['cursor']} (was {before['cursor']})", failures)
    check("PanelKeyCatcher" in host.call("focusName"), "the keys go to the list: " + host.call("focusName"), failures)
    host.call("press", "Up")
    wait_for(lambda: host.state()["cursor"] == before["cursor"] - 1, "↑ moves on from there")
    host.grab(output / "keep-state.png")

    # The info card stays open.
    host.call("press", "i")
    card = info_card(host, "the row's card")
    reopen()
    check((host.state()["info"] or {}).get("title") == card["title"], "the info card is still open", failures)
    host.call("press", "i")
    wait_for(lambda: host.state()["info"] is None, "i closes it")

    # The playlist picker stays up, with the keys in its box.
    host.call("press", "A")
    wait_for(lambda: host.state()["pickerOpen"], "the picker")
    reopen()
    check(host.state()["pickerOpen"] and host.call("focusName") == "picker",
          "the picker is still up, typing in it: " + host.call("focusName"), failures)
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["pickerOpen"], "Esc closes the picker")

    # The expanded view's columns.
    host.call("expand", "true")
    wait_for(lambda: host.state()["columns"], "the columns")
    reopen()
    s = host.state()
    check(s["expanded"] and s["columns"] and s["browse"] == "artist:Flügel Café", "still expanded, on the artist", failures)
    host.call("expand", "false")

    # Settings stay open, but a setting being typed is dropped, not saved.
    host.call("press", ",")
    wait_for(lambda: host.state()["settingsOpen"], "settings")
    s = host.state()
    for _ in range(s["settingsRows"].index("radioArea") - s["settingsCursor"]): host.call("press", "Down")
    was = host.state()["settingValues"].get("radioArea")
    host.call("press", "Return")
    wait_for(lambda: host.state()["settingsEditing"] == "radioArea", "editing radioArea")
    host.call("typeKeys", "Nevad")
    reopen()
    s = host.state()
    check(s["settingsOpen"] and s["expanded"] and s["settingsEditing"] == "" and s["settingValues"].get("radioArea") == was
          and settings_file().get("radioArea") in (None, was),
          "settings still open (expanded, as they opened); the half-typed state wasn't saved: " + json.dumps([s["settingsOpen"],
          s["settingsEditing"], was, s["settingValues"].get("radioArea"), settings_file().get("radioArea")]), failures)
    host.call("press", ",")
    wait_for(lambda: not host.state()["settingsOpen"], "settings closed")
    wait_for(lambda: not host.state()["expanded"], "back to compact, after a close and reopen too")

    # The harness's own close starts the next scenario fresh.
    host.call("close")
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    s = host.state()
    check(s["query"] == "" and s["browse"] == "" and s["info"] is None, "close() in the harness starts fresh", failures)


def hints_scenario(host, output, failures):
    """The line of key hints keeps its height whatever it says, so the panel
    doesn't grow: hints that don't fit are left out, and a long notice is cut
    short (Marc, 11-05: no "Space play/pause", so the compact panel's hints are
    one line too; a notice there may take a second, drawn over the list's
    foot). The keys page's RIGHT NOW lists the keys that do something where
    the panel is, all of them. w, or its Window button, keeps the keys open in
    a window of their own: fixed in size as it maps, so Hyprland floats it,
    then free to resize, and RIGHT NOW there follows the panel. The expanded
    header has no Keys or TUI buttons (? is a key)."""
    long_notice = "A notice far too long for the line: " + "it goes on and on, " * 12 + "and ends here."

    def line(label):
        s = host.state()
        h = s["hintLine"] or {}
        print(label, json.dumps(h), s["cardHeight"], file=sys.stderr)
        return s, h

    def steady(label, lines, height, card=None):
        s, h = line(label)
        check(h.get("height") == height and 0 < h.get("lines", 0) <= lines,
              f"{label}: the hints keep their height ({h.get('height')}, was {height}) in {lines} line(s) or fewer", failures)
        if card is not None:
            check(s["cardHeight"] == card, f"{label}: the panel keeps its height ({s['cardHeight']}, was {card})", failures)
        if s["notice"] == "":
            check(not h.get("truncated") and (s["searchFocused"] or h.get("text", "").endswith("? keys")),
                  f"{label}: what's shown fits, and ends with ? keys: {h.get('text')}", failures)
            shown = [part for part in h.get("text", "").split(" · ")]
            check(all(part in s["hint"].split(" · ") for part in shown),
                  f"{label}: every hint shown is one of the hints here: {h.get('text')} / {s['hint']}", failures)
        return s

    host.call("close")
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    host.settle(.5)

    for expanded in (False, True):
        mode = "expanded" if expanded else "compact"
        lines = 1
        host.call("expand", "true" if expanded else "false")
        host.settle(.8)
        s, h = line(mode + ": the queue")
        height, card = h.get("height"), s["cardHeight"]
        check(height and height > 0, mode + ": the hint line is there", failures)
        check(h.get("lines") == 1 and not h.get("truncated") and "Space" not in s["hint"] and h.get("text") == s["hint"],
              mode + ": the queue's hints, all of them on one line, with no Space: " + str(h.get("text")), failures)
        if expanded:
            # ? and t are keys, and on the hint line; the header doesn't repeat them.
            buttons = s["headerButtons"] or []
            check("Compact" in buttons and not any("Keys" in b or "TUI" in b for b in buttons),
                  "the expanded header has no Keys or TUI buttons: " + json.dumps(buttons), failures)
        host.call("press", "Down")
        host.settle(.3)
        steady(mode + ": a song in the queue", lines, height, card)
        host.call("press", "/")
        host.call("typeKeys", "glass")
        wait_for(lambda: host.state()["query"] == "glass" and not host.state()["searching"], "search glass")
        host.settle(.3)
        s = steady(mode + ": typing a search", lines, height, card)
        # In the box, letters are text: Enter, Shift+Enter, ↓ and Esc are the keys.
        check(s["searchFocused"] and s["hint"] == "Enter open · Shift+Enter add to queue · ↓ to the list · Esc clear",
              mode + ": typing, the box's own keys: " + s["hint"], failures)
        cursor_to(host, "artist:Glass Harbor", failures)
        steady(mode + ": search results", lines, height, card)
        # At the top of the list, ↑ goes up to the song playing.
        s = host.state()
        want = "Esc clear · ↑ now playing · ? keys" if s["cursor"] == 0 else "Esc clear · ? keys"
        check(s["hint"].endswith(want), mode + ": the list's keys again: " + s["hint"], failures)
        cursor_to(host, "artist:Glass Harbor", failures)
        host.call("press", "Right")
        wait_for(lambda: host.state()["browse"] == "artist:Glass Harbor" and not host.state()["browseLoading"], "the artist")
        steady(mode + ": an artist", lines, height, card)
        if cursor_to(host, "album:Paper Satellites", failures):
            host.call("press", "Right")
            wait_for(lambda: host.state()["browse"] == "album:Paper Satellites" and not host.state()["browseLoading"], "the album")
            cursor_to(host, "track:Orbit Song", failures)
            host.settle(.3)
            s = steady(mode + ": a song in an album", lines, height, card)
            check(s["hintLine"]["text"] == s["hint"] or not expanded,
                  mode + ": the album song's hints: " + s["hintLine"]["text"], failures)
            if not expanded: host.grab(output / "hints-compact.png")
        host.call("say", long_notice)
        host.settle(.3)
        s = steady(mode + ": a long notice", 1 if expanded else 2, height, card)
        check(s["hintLine"]["text"] == long_notice and s["hintLine"]["truncated"]
              and s["hintLine"]["lines"] == (1 if expanded else 2),
              mode + ": the notice is cut short (compact: on a second line, over the list's foot), and nothing moves", failures)
        host.grab(output / ("hints-expanded.png" if expanded else "hints-compact-notice.png"))
        wait_for(lambda: host.state()["notice"] == "", "the notice goes")
        host.call("close")
        host.call("open")
        wait_for(lambda: host.state()["opened"], "open")
        host.settle(.3)

    # The keys page: RIGHT NOW is the keys here, ? aside.
    host.call("expand", "false")
    host.call("press", "/")
    host.call("typeKeys", "glass")
    wait_for(lambda: host.state()["query"] == "glass" and not host.state()["searching"], "search glass")
    cursor_to(host, "artist:Glass Harbor", failures)
    host.call("press", "Right")
    wait_for(lambda: host.state()["browse"] == "artist:Glass Harbor" and not host.state()["browseLoading"], "the artist")
    cursor_to(host, "album:Paper Satellites", failures)
    host.settle(.3)
    host.call("press", "?")
    wait_for(lambda: host.state()["keysOpen"], "the keys page")
    s = host.state()
    check(s["keysHere"][0] == "→ Open it (or Enter)" and "← Back a level" in s["keysHere"]
          and not any(k.startswith("? ") for k in s["keysHere"]),
          "RIGHT NOW on an album row: " + json.dumps(s["keysHere"]), failures)
    host.grab(output / "keys-here.png")

    # w keeps it open in a window of its own; the panel's page closes.
    host.call("press", "w")
    wait_for(lambda: host.state()["keysWindow"]["open"], "the keys window")
    host.settle(.5)
    s = host.state()
    w = s["keysWindow"]
    check(not s["keysOpen"] and s["opened"], "the panel stays open, its keys page closed", failures)
    # It maps at a fixed size, so Hyprland floats it, then lets go of it.
    check(w["resizable"] and w["width"] > 0, "after its first frame the window can be resized: " + json.dumps(w), failures)
    check(w["here"] == s["keysHere"], "the window's RIGHT NOW is the panel's: " + json.dumps(w["here"]), failures)
    first = (w["width"], w["height"])
    path = output / "keys-window.png"
    path.unlink(missing_ok=True)
    check(host.call("grabKeysWindow", str(path)) == "ok", "the window can be captured", failures)
    wait_for(lambda: complete_png(path), path.name)

    # It follows the panel: into the album, onto a song. (Offscreen the new
    # window takes the keys; under Hyprland the open panel keeps them.)
    host.call("activatePopup")
    host.settle(.3)
    host.call("press", "Right")
    wait_for(lambda: host.state()["browse"] == "album:Paper Satellites" and not host.state()["browseLoading"], "the album")
    cursor_to(host, "track:Orbit Song", failures)
    wait_for(lambda: "Enter Play from this song" in host.state()["keysWindow"]["here"],
             "the window's RIGHT NOW follows the cursor onto a song")
    check(host.state()["keysWindow"]["here"] == host.state()["keysHere"], "and agrees with the panel", failures)

    # Resized, the keys fill it.
    check(host.call("resizeKeysWindow", 700, 500) == "ok", "the window is resized", failures)
    host.settle(.3)
    w = host.state()["keysWindow"]
    check((w["width"], w["height"]) == (700, 500) and 0 < 700 - w["viewWidth"] < 100,
          "a resized window keeps its size, and the keys fill it: " + json.dumps(w), failures)

    # Its own keys: Esc closes it.
    check(host.call("activateKeysWindow") == "ok", "the window takes the keys", failures)
    host.settle(.3)
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["keysWindow"]["open"], "Esc closes the keys window")

    # The Window button on the keys page does the same as w.
    host.call("close")
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    host.call("keys", "true")
    host.settle(.3)
    host.call("activatePopup")
    host.settle(.3)
    pressed = host.call("mouse", "keysWindowButton", "press", .5)
    host.call("mouse", "keysWindowButton", "release", .5)
    check(pressed == "ok", "a click on the keys page's Window button: " + pressed, failures)
    wait_for(lambda: host.state()["keysWindow"]["open"], "the Window button opens the keys window")
    host.settle(.3)
    w = host.state()["keysWindow"]
    check((w["width"], w["height"]) == (700, 500) and w["resizable"] and first != (700, 500),
          "it opens again at the size it was left, and can be resized again: " + json.dumps(w), failures)
    host.call("close")
    check(not host.state()["keysWindow"]["open"], "the harness's close closes it too", failures)


def lookup_scenario(host, output, socket_path, failures):
    """A live station's song looked up in Apple Music: a click on SiriusXM's
    title (or O for the artist) searches Apple Music while the channel plays
    on; a adds the song to Apple Music's queue; Enter plays it there and
    switches. With the lookup setting on Spotify, it searches Spotify."""
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    # Read as the panel opens: its watch can miss a file deleted (by the last
    # scenario) and made again at once.
    host.call("close")
    host.call("open")
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    wait_for(lambda: host.state()["opened"], "open")
    host.call("setSource", "sxm")
    wait_for(lambda: host.state()["sxmMode"] and host.state()["nowPlaying"] == "Take It On The Run · REO Speedwagon",
             "SiriusXM plays 80s on 8")
    host.settle(.5)
    channel = mpd_files(socket_path)[int(mpd_state(socket_path)["song"])]

    def looked_up(service, query):
        wait_for(lambda: host.state()["lookup"] == service and host.state()["query"] == query
                 and not host.state()["searching"], service + " looks up " + query)
        return host.state()

    def still_on_channel(label):
        st = mpd_state(socket_path)
        check(host.state()["sxmMode"] and st["state"] == "play" and mpd_files(socket_path)[int(st["song"])] == channel,
              label, failures)

    check(host.call("clickPanel", "playingTitle") == "ok", "the station's song title can be clicked", failures)
    s = looked_up("apple", "Take It On The Run REO Speedwagon")
    check(s["cursor"] >= 0 and s["rows"][s["cursor"]] == "song:Take It On The Run"
          and "APPLE MUSIC · SONGS" in s["sections"],
          "the lookup finds the song in Apple Music, the cursor on it: " + ", ".join(s["rows"][:4]), failures)
    still_on_channel("the channel plays on while you look")
    host.grab(output / "lookup-sxm.png")
    host.call("press", "a")
    wait_for(lambda: bridge_requests("/v1/play") and bridge_requests("/v1/play")[-1][2].get("mode") == "add", "a adds")
    check(bridge_requests("/v1/play")[-1][2]["items"][0]["kind"] == "song",
          "a adds the song to Apple Music's queue: " + json.dumps(bridge_requests("/v1/play")[-1][2]), failures)
    still_on_channel("and the channel still plays")
    host.call("press", "Escape")
    wait_for(lambda: host.state()["query"] == "" and host.state()["lookup"] == "", "Esc ends the lookup")
    check(host.state()["rows"][0].startswith("channel:"), "Esc comes back to the channels", failures)

    host.call("press", "O")
    s = looked_up("apple", "REO Speedwagon")
    check(s["rows"][s["cursor"]] == "artist:REO Speedwagon", "O looks up the artist, the cursor on it", failures)
    host.call("press", "Escape")
    wait_for(lambda: host.state()["lookup"] == "", "Esc ends it")

    # Enter on the song: it plays on Apple Music, which becomes the source.
    host.call("clickPanel", "playingTitle")
    looked_up("apple", "Take It On The Run REO Speedwagon")
    host.call("press", "Return")
    wait_for(lambda: host.state()["appleMode"], "Apple Music becomes the source")
    play = bridge_requests("/v1/play")[-1][2]
    check(play["mode"] == "play" and play["items"][0]["kind"] == "song", "Enter plays the song on Apple Music: " + json.dumps(play), failures)
    wait_for(lambda: host.state()["nowPlaying"].startswith("Take It On The Run"), "Apple Music plays it")
    check(host.state()["lookup"] == "" and host.state()["query"] == "", "the lookup is over", failures)

    # The setting: Spotify.
    host.call("setSetting", "lookup", "Spotify", "false")
    host.call("setSource", "sxm")
    wait_for(lambda: host.state()["sxmMode"] and host.state()["nowPlaying"].startswith("Take It On The Run"), "back on SiriusXM")
    host.settle(.5)
    host.call("clickPanel", "playingArtist")
    s = looked_up("spotify", "REO Speedwagon")
    check(any(x.startswith("SPOTIFY ·") for x in s["sections"]), "with the setting on Spotify, Spotify: " + ", ".join(x for x in s["sections"] if x), failures)
    host.call("press", "Escape")
    host.call("setSetting", "lookup", "Apple Music", "false")
    to_source(host, "local")
    BRIDGE["config"].unlink()


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
    # In the box → moves the text cursor, so the hint says Enter.
    check(s["rows"][0] == "artist:Glass Harbor" and s["hint"].startswith("Enter open"),
          "typed 'glass': top result is the artist, hint says Enter opens it: " + s["hint"], failures)

    # Enter in the search box opens the top result.
    host.call("press", "Return")
    wait_for(lambda: browsed(host, "artist:Glass Harbor"), "artist view")
    host.settle()
    s = host.state()
    # Both compilations: Left Of The Signal has an album artist (Various
    # Artists), Signal Hill Sampler none.
    check(s["rows"] == ["playall:Play all songs", "album:Low Tide Signals", "album:Paper Satellites",
                        "album:Left Of The Signal", "album:Signal Hill Sampler"], "artist view: " + ", ".join(s["rows"]), failures)
    check(s["sections"][1] == "ALBUMS" and s["sections"][3] == "APPEARS ON"
          and s["subtitles"][3:] == ["1988 · on 1 of 3 songs", "1990 · on 1 of 4 songs"],
          "the compilations are under APPEARS ON: " + ", ".join(s["subtitles"][3:]), failures)
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
    # Play, Add to queue and Add to playlist are buttons under the heading,
    # and the list is the songs.
    # What Play stands for fits beside them in the compact panel (464 wide
    # since 0.16.1; at 430 it went on the heading's line).
    check(s["levelButtons"]["current"] == ["Play", "Add to queue", "Add to playlist", "(" + s["subtitles"][0] + ")"]
          and s["headingLine"] == "Glass Harbor · 2021"
          and host.call("clickRow", 0, "false") == "not shown",
          "the album's buttons, and only its songs in the list: " + str(s["levelButtons"]["current"])
          + " | " + s["headingLine"], failures)
    host.grab(output / "compact-album.png")

    # a adds one song and stays in the album.
    queued = s["queueLength"]
    host.call("press", "Down")
    host.call("press", "a")
    wait_for(lambda: host.state()["queueLength"] == queued + 1, "song added")
    s = host.state()
    check(s["notice"] == "Added Static Bloom to the queue" and s["browse"] == "album:Paper Satellites",
          "a adds the song and stays in the album: " + s["notice"], failures)
    # ↑ from the first song: the cursor on the buttons, where the keys act on the album.
    host.call("press", "Up")
    host.call("press", "Up")
    s = host.state()
    check(s["cursor"] == 0 and s["levelButtons"]["current"][0] == "[Play]"
          and s["hint"].startswith("Enter play · a add to queue · A add to playlist"),
          "↑ from the first song goes onto Play: " + str(s["levelButtons"]["current"]) + " | " + s["hint"], failures)
    # Add to queue (a real click) adds the album and stays in it.
    queued = s["queueLength"]
    check(host.call("clickPanel", "levelButton:Add to queue") == "ok", "Add to queue can be clicked", failures)
    wait_for(lambda: host.state()["queueLength"] == queued + 4, "album added")
    s = host.state()
    check(s["notice"] == "Added Paper Satellites to the queue" and s["browse"] == "album:Paper Satellites",
          "Add to queue adds the album and stays in it: " + s["notice"], failures)

    # ← goes back to the artist, with the cursor on the album it came from.
    host.call("press", "Left")
    host.settle(.3)
    s = host.state()
    check(s["browse"] == "artist:Glass Harbor" and s["cursor"] == 2, "← goes back to the artist", failures)
    # → on a song does nothing; Esc also goes back.
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "album:Paper Satellites"), "album view again")
    queued = host.state()["queueLength"]
    host.call("press", "Right")
    host.settle(.3)
    s = host.state()
    check(s["browse"] == "album:Paper Satellites" and s["queueLength"] == queued, "→ on a song does nothing",
          failures)
    host.call("press", "Escape")
    host.settle(.3)
    check(host.state()["browse"] == "artist:Glass Harbor", "Esc also goes back", failures)

    # The compilation opens whole, each song with its artist.
    host.call("press", "Down")
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
    s = host.state()
    check(s["levelButtons"]["current"][:3] == ["Play", "Add to queue", "Add to playlist"]
          and s["levelButtons"]["parent"][:3] == ["Play all songs", "Add to queue", "Add to playlist"],
          "expanded, each column's heading has its buttons: " + str(s["levelButtons"]), failures)
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
    # With its number of songs, so a one-song album shows before it's opened.
    check([a for a in albums if a[0] == "album:Signal Hill Sampler"] == [("album:Signal Hill Sampler", "3 artists · 4 songs")],
          "one row per compilation, with its songs: " + str(albums), failures)

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
    # Play (a real click) replaces the queue with the album, and plays it.
    songs = len(s["rows"]) - 1
    check(host.call("clickPanel", "levelButton:Play") == "ok", "Play can be clicked", failures)
    wait_for(lambda: host.state()["browse"] == "" and host.state()["queueLength"] == songs, "album playing")
    s = host.state()
    check(s["notice"] == "Playing Live at the Basement" and "Playing" in s["stateText"],
          "Play replaces the queue with the album and plays it: " + s["notice"] + " | " + s["stateText"], failures)
    # Back to it, then Backspace.
    host.call("type", "basement")
    wait_for(lambda: not host.state()["searching"] and "album:Live at the Basement" in host.state()["rows"], "two-disc search again")
    host.call("activate", host.state()["rows"].index("album:Live at the Basement"), "open")
    wait_for(lambda: browsed(host, "album:Live at the Basement"), "two-disc album again")
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
          and s["browseInfo"]["subtitle"] == "Alternative & Punk · 2 albums"
          and s["subtitles"] == ["Various Artists · 1988 · 3 songs", "3 artists · 1990 · 4 songs"],
          "Compilations lists the genre's compilations, with their songs: " + ", ".join(s["rows"])
          + " | " + " / ".join(s["subtitles"]), failures)
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
    check(s["rows"] == ["savequeue:Save the queue as a playlist", "historylist:History", "playlist:Late Night"] and s["cursor"] == 2
          and s["subtitles"][2] == "4 songs · 10 min" and s["browseRoot"] == "queue",
          "P opens Playlists: " + ", ".join(s["rows"]) + " | " + s["subtitles"][2], failures)
    check(s["levelButtons"]["current"][:2] == ["Save the queue as a playlist", "History"],
          "Save the queue and History are buttons: " + str(s["levelButtons"]["current"]), failures)
    host.grab(output / "compact-playlists.png")

    # → opens it: Play the playlist, then its songs; one has left the library.
    host.call("press", "Right")
    wait_for(lambda: browsed(host, "playlist:Late Night"), "playlist view")
    host.settle()
    s = host.state()
    check(s["rows"] == ["playplaylist:Play the playlist", "track:Fernweh", "track:Glasswork", "track:01 Missing Song",
                        "track:Schnee"] and s["subtitles"][3] == "Not in the library anymore"
          and s["browseInfo"]["subtitle"] == "Playlist · 4 songs · 10 min",
          "the playlist view: " + ", ".join(s["rows"]), failures)
    check(s["levelButtons"]["current"] == ["Play", "Add to queue", "Add to playlist"]
          and s["headingLine"] == "Playlist · 4 songs · 10 min",
          "the playlist's buttons, its count said once: " + str(s["levelButtons"]["current"]) + " | " + s["headingLine"], failures)
    check(s["levelTips"] == ["Replace the queue with the playlist and play it (Enter)", "Add its songs to the end of the queue (a)",
                             "Add its songs to a playlist, or to a new one (A)"],
          "each button's tooltip ends with its key: " + str(s["levelTips"]), failures)
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
    check(s["query"] == "" and s["rows"][2:] == ["playlist:Late Night", "playlist:Road Trip"],
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
    wait_for(lambda: host.state()["rows"] == ["savequeue:Save the queue as a playlist", "historylist:History", "playlist:Late Night"], "deleted")
    s = host.state()
    check(stored(socket_path, "Road Trip") == [] and s["notice"] == "Deleted the playlist Road Trip",
          "x, Enter deletes it: " + s["notice"], failures)

    # Save the queue: its button (↑ onto History's, ↑ onto it, Enter), then a name.
    host.call("press", "Up")
    check(host.state()["levelButtons"]["current"][:2] == ["Save the queue as a playlist", "[History]"],
          "↑ goes onto History first: " + str(host.state()["levelButtons"]["current"]), failures)
    host.call("press", "Up")
    check(host.state()["levelButtons"]["current"][0] == "[Save the queue as a playlist]",
          "↑ again, onto Save the queue: " + str(host.state()["levelButtons"]["current"]), failures)
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
    check(s["parentRows"] == ["savequeue:Save the queue as a playlist", "historylist:History", "playlist:Late Night", "playlist:Saved Queue"],
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
    host.call("columnRemove", "parent", 3)
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


def fake_bridge_info(on, switch="info"):
    """Give the fake bridge GET /v1/info, or take it away (an older bridge);
    with switch="bare", leave the status's songs without albumId and artistId."""
    request = urllib.request.Request(f"http://127.0.0.1:{BRIDGE['port']}/v1/fake/{switch}", method="POST",
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

    # A SiriusXM channel: favorite or not, what's on.
    to_source(host, "sxm")
    wait_for(lambda: host.state()["sxmMode"] and host.state()["nowPlaying"] != "", "SiriusXM")
    host.call("press", "Down")
    host.settle(.3)
    row = host.state()["rows"][host.state()["cursor"]]
    host.call("press", "i")
    card = info_card(host, "a channel's card")
    check(card["service"] == "SiriusXM" and card["kind"] == "Channel" and "channel:" + card["title"] == row
          and card["status"] in ("In your favorites", "Not in your favorites")
          and any(f.startswith("CHANNEL: Number = ") for f in card["fields"]),
          "the channel's card: " + card["title"] + " · " + card["status"], failures)
    host.grab(output / "info-sxm.png")
    host.call("press", "i")

    # A station: favorite or not, its stream.
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


def bridge_post(path, body):
    """POST to the fake bridge, as another of its clients would."""
    request = urllib.request.Request(f"http://127.0.0.1:{BRIDGE['port']}{path}", method="POST",
                                     data=json.dumps(body).encode(),
                                     headers={"Authorization": "Bearer fake-bridge-token", "Content-Type": "application/json",
                                              "X-Omarock": "1"})
    urllib.request.urlopen(request, timeout=5).read()


def fake_bridge(switch, body):
    """POST a test control to the fake bridge (/v1/fake/SWITCH)."""
    bridge_post("/v1/fake/" + switch, body)


def heard_scenario(host, socket_path, failures):
    """Apple Music as heard. mpd plays the bridge's stream behind the Mac (the
    fake mpd 2 s here, and the bridge's streamDelay 0.5 s), so the card and the
    bar show the song and time as heard. The panel measures mpd's lag 4 s after
    mpd joins the stream. A change made here (next, a seek, play) shows at
    once, its time "…" until its sound arrives; a song that starts by itself
    shows when it's heard; after a pause the time runs on until the sound
    stops."""
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    mpd_client(socket_path, "fake_stream_lag 2")
    fake_bridge("streamdelay", {"seconds": 0.5})
    # Zen Arcade from its first song, paused: the switch plays it.
    bridge_post("/v1/play", {"items": [{"kind": "album", "id": "c-al-1", "source": "catalog"}], "mode": "play", "start": 0})
    bridge_post("/v1/pause", {})
    host.call("open")
    to_source(host, "apple")
    wait_for(lambda: host.state()["appleReady"] and host.state()["bar"]["playing"], "Apple Music playing")
    wait_for(lambda: host.state()["heard"]["lag"] >= 0, "mpd's lag measured", timeout=10)
    s = host.state()
    check(abs(s["heard"]["lag"] - 2) < 0.3 and abs(s["heard"]["delay"] - 2.5) < 0.3,
          f"the panel measures mpd's lag ({s['heard']['lag']:.2f} s) and adds the bridge's ({s['heard']['delay']:.2f} s)", failures)
    host.settle(3)

    def times(n=3, gap=.4):
        out = []
        for _ in range(n):
            out.append(host.state()["heard"]["time"])
            host.settle(gap)
        return out

    # Next, here: the new song shows at once, its time waits for the sound.
    before = host.state()["bridgeSong"]["title"]
    host.call("press", "n")
    wait_for(lambda: host.state()["heard"]["live"] != before, "the Mac plays the next song")
    host.settle(.3)
    s = host.state()
    check(s["bridgeSong"]["title"] == s["heard"]["live"] and s["heard"]["waiting"] and s["heard"]["time"].startswith("."),
          f"next: {s['bridgeSong']['title']} shows at once, the time waiting ({s['heard']['time']!r})", failures)
    check(len(set(times())) > 1, "the waiting time cycles its dots", failures)
    wait_for(lambda: not host.state()["heard"]["waiting"], "its sound arrives", timeout=5)
    s = host.state()
    check(s["heard"]["time"] in ("0:00", "0:01"), "then the time from the start: " + s["heard"]["time"], failures)

    # A song that starts by itself: shown once it's heard.
    host.settle(1)
    before = host.state()["bridgeSong"]["title"]
    fake_bridge("advance", {})
    wait_for(lambda: host.state()["heard"]["live"] != before, "the Mac moves on")
    host.settle(1)
    s = host.state()
    check(s["bridgeSong"]["title"] == before and s["bar"]["text"].find(before) >= 0 and not s["heard"]["waiting"],
          f"a song that starts by itself: {before} still shows while it's heard, on the bar too", failures)
    wait_for(lambda: host.state()["bridgeSong"]["title"] == host.state()["heard"]["live"], "the new song shows", timeout=4)
    s = host.state()
    check(s["bar"]["text"].find(s["heard"]["live"]) >= 0 and s["heard"]["time"] in ("0:00", "0:01"),
          f"then {s['heard']['live']} shows, from its start ({s['heard']['time']})", failures)

    # A seek: the time waits at its place.
    host.settle(1)
    host.call("press", "Shift+Right")
    host.settle(.3)
    s = host.state()
    check(s["heard"]["waiting"] and s["heard"]["time"].startswith("."), "a seek: the time waits", failures)
    wait_for(lambda: not host.state()["heard"]["waiting"], "the seek is heard", timeout=5)
    s = host.state()
    check(s["heard"]["time"] in ("0:11", "0:12", "0:13"), "then the time from where it went: " + s["heard"]["time"], failures)

    # Pause: paused at once; the time runs on until the sound stops.
    host.settle(1)
    host.call("press", "Space")
    wait_for(lambda: not host.state()["bar"]["playing"], "paused")
    running = times(3, .5)
    host.settle(2.5)
    stopped = times(3, .5)
    check(len(set(running)) > 1 and len(set(stopped)) == 1 and not host.state()["heard"]["waiting"],
          f"pause: the time runs on ({', '.join(running)}) until the sound stops ({stopped[0]})", failures)

    # Play: the time waits for the sound again.
    host.call("press", "Space")
    wait_for(lambda: host.state()["bar"]["playing"], "playing")
    check(host.state()["heard"]["waiting"], "play: the time waits for the sound", failures)
    wait_for(lambda: not host.state()["heard"]["waiting"], "the sound arrives", timeout=6)

    # Playing on time (the fakes, as everywhere else): no waiting at all.
    mpd_client(socket_path, "fake_stream_lag 0")
    fake_bridge("streamdelay", {"seconds": 0})
    to_source(host, "local")
    host.call("close")


def elsewhere_scenario(host, socket_path, failures):
    """Apple Music and Spotify play on one machine at a time: the one that
    last pressed Play. Another machine taking over (the fakes' "elsewhere"):
    here the card says where it plays, mpd stops listening to the Mac's
    stream without pausing the Mac, skipping is refused, and Play takes it
    back. The local sources aren't touched."""
    def fake_elsewhere(base, name):
        request = urllib.request.Request(base + "/v1/fake/elsewhere", data=json.dumps({"name": name}).encode(), method="POST",
                                         headers={"Authorization": "Bearer fake-bridge-token", "Content-Type": "application/json",
                                                  "X-Omarock": "1"})
        urllib.request.urlopen(request, timeout=5).read()

    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    host.call("open")
    to_source(host, "apple")
    wait_for(lambda: host.state()["appleReady"] and host.state()["bar"]["playing"], "Apple Music playing")
    host.settle(.5)
    check(host.state()["clientName"] != "", "the panel knows this machine's name: " + host.state()["clientName"], failures)
    # Play here: the bridge plays for this machine.
    host.call("press", "Space")
    wait_for(lambda: not host.state()["bar"]["playing"], "paused")
    host.call("press", "Space")
    wait_for(lambda: host.state()["bar"]["playing"] and mpd_state(socket_path)["state"] == "play", "playing here")
    pauses = len(bridge_requests("/v1/pause"))

    # Another machine presses Play: mpd here stops, the Mac plays on.
    fake_elsewhere(url, "otherbox")
    wait_for(lambda: host.state()["elsewhere"] == "otherbox", "the panel hears it plays on otherbox")
    wait_for(lambda: mpd_state(socket_path)["state"] != "play", "mpd here stops listening")
    host.settle(.5)
    s = host.state()
    check(not s["bar"]["playing"] and s["appleMode"] and s["playerExtra"] == "Playing on otherbox · Play moves it here",
          "Apple Music on otherbox: paused here, still the source, the card says where: " + s["playerExtra"], failures)
    check(len(bridge_requests("/v1/pause")) == pauses, "and the Mac isn't paused", failures)
    host.call("press", "n")
    wait_for(lambda: host.state()["notice"] == "Apple Music is playing on otherbox: Play moves it here", "n is refused, saying why")
    # Play here takes it back.
    host.call("press", "Space")
    wait_for(lambda: host.state()["elsewhere"] == "" and mpd_state(socket_path)["state"] == "play", "Play takes it back")
    check(host.state()["bar"]["playing"], "Play moves Apple Music back here: mpd plays the stream", failures)
    # The media keys (mpd's own play) take it back too.
    fake_elsewhere(url, "otherbox")
    wait_for(lambda: mpd_state(socket_path)["state"] != "play", "mpd here stops listening again")
    resumes = len(bridge_requests("/v1/resume"))
    mpd_client(socket_path, "play")
    wait_for(lambda: len(bridge_requests("/v1/resume")) > resumes and host.state()["elsewhere"] == "", "mpd's play takes it back")
    check(len(bridge_requests("/v1/pause")) == pauses, "the Mac was never paused for the other machine", failures)

    # Spotify: the other machine's Spotify plays, so it's paused here.
    host.call("setSource", "spotify")
    wait_for(lambda: host.state()["spotifyMode"] and host.state()["bar"]["playing"], "Spotify playing here")
    fake_elsewhere(BRIDGE["spotify"], "otherbox")
    wait_for(lambda: host.state()["elsewhere"] == "otherbox", "Spotify plays on otherbox")
    s = host.state()
    check(not s["bar"]["playing"] and s["spotifyMode"] and s["playerExtra"] == "Playing on otherbox · Play moves it here",
          "Spotify on otherbox: paused here, the card says where: " + s["playerExtra"], failures)
    host.call("press", "n")
    wait_for(lambda: host.state()["notice"] == "Spotify is playing on otherbox: Play moves it here", "Spotify's n is refused")
    host.call("press", "Space")
    wait_for(lambda: host.state()["elsewhere"] == "" and host.state()["bar"]["playing"], "Play moves Spotify here")
    check(True, "Play moves Spotify back here", failures)
    to_source(host, "local")
    host.call("close")
    BRIDGE["config"].unlink()


def reconnect_scenario(host, socket_path, failures):
    """Things going wrong while it plays (the VM's failure tests, 10-30): a
    live stream that loses its connection is played again until it's back
    (mpd tries once and gives up), for streamRetryFor; the bridge, back after
    being out of reach, shows again within seconds, not after the long poll's
    25 s; and Spotify stays the source while omarock-spotify can't be
    reached (Soloist plays on), its release sent again once it can."""
    def offline(base, closed, hang=0):
        request = urllib.request.Request(base + "/v1/fake/offline", data=json.dumps({"closed": closed, "hang": hang}).encode(),
                                         method="POST", headers={"Authorization": "Bearer fake-bridge-token",
                                                                 "Content-Type": "application/json", "X-Omarock": "1"})
        urllib.request.urlopen(request, timeout=5).read()
        return time.monotonic() + closed + hang
    plays = lambda: command_count(socket_path, "play")
    lost = lambda: host.state()["notice"].startswith("Lost ")

    # SiriusXM's stream drops, and the first try to reconnect fails too.
    host.call("open")
    host.call("setSource", "sxm")
    wait_for(lambda: host.state()["sxmMode"] and host.state()["bar"]["playing"], "SiriusXM playing")
    host.settle(5.5)
    before = plays()
    mpd_client(socket_path, "fake_stream_drop 1")
    wait_for(lost, "the drop noticed")
    s = host.state()
    name = s["notice"][len("Lost "):-len(". Reconnecting…")]
    check(s["stateText"] == "SiriusXM · Reconnecting…" and s["notice"] == "Lost " + name + ". Reconnecting…",
          "a dropped stream: " + s["stateText"] + " | " + s["notice"], failures)
    wait_for(lambda: host.state()["notice"] == "Back on " + name, "back on the channel", timeout=12)
    s = host.state()
    check(plays() == before + 2 and mpd_state(socket_path)["state"] == "play" and s["stateText"] == "SiriusXM · Playing",
          f"played again after 2 s (still out) and 5 s more: back on {name} ({plays() - before} plays)", failures)

    # Out for longer than streamRetryFor (4 s here): it gives up, saying why.
    host.call("settings", json.dumps({"streamRetryFor": 4}))
    host.settle(5.5)
    before = plays()
    mpd_client(socket_path, "fake_stream_drop 99")
    wait_for(lost, "the drop noticed")
    wait_for(lambda: host.state()["notice"].startswith("Couldn't reconnect"), "giving up", timeout=12)
    s = host.state()
    check(s["notice"] == f"Couldn't reconnect to {name}: Failed to connect to 127.0.0.1 port 9 after 0 ms: Could not connect to server"
          and s["stateText"] == "SiriusXM · Stopped", "after streamRetryFor it stops: " + s["notice"], failures)
    host.settle(3)
    check(plays() == before + 1, f"and tries no more ({plays() - before} plays)", failures)

    # Switching away while it reconnects ends it.
    host.call("settings", "{}")
    mpd_client(socket_path, "fake_stream_drop 0")
    host.call("press", "Space")
    wait_for(lambda: mpd_state(socket_path)["state"] == "play", "the channel again")
    host.settle(5.5)
    mpd_client(socket_path, "fake_stream_drop 99")
    wait_for(lost, "the drop noticed")
    host.call("setSource", "local")
    wait_for(lambda: host.state()["source"] == "local", "local")
    host.settle(7)
    s = host.state()
    check(s["source"] == "local" and not any("://" in line for line in mpd_query(socket_path, "currentsong") if line.startswith("file: ")) and not s["stateText"].endswith("Reconnecting…"),
          "switching to local ends the reconnecting: " + s["stateText"], failures)
    mpd_client(socket_path, "fake_stream_drop 0")

    # Apple Music's bridge out of reach: closed connections for 4 s, then
    # requests that hang for 10 s and are answered once it's over.
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    host.call("open")
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    to_source(host, "apple")
    wait_for(lambda: host.state()["appleReady"] and host.state()["bar"]["playing"], "Apple Music playing")
    host.settle(1)
    log_at = len(BRIDGE["qs_log"].read_text(errors="replace"))
    back = offline(url, 4, 10)
    wait_for(lambda: host.state()["stateText"] == "Apple Music · Not connected", "the bridge out of reach", timeout=8)
    wait_for(lambda: host.state()["appleReady"], "the bridge back", timeout=40)
    after = time.monotonic() - back
    check(after < 6, f"the bridge shows again {after:.1f} s after it's back (the long poll alone: up to 25 s)", failures)
    # The journal: the first request with no answer, and when it answers
    # again (Marc's laptop, 11-03: a line every 8 s for half an hour).
    host.settle(.5)
    lines = [line for line in BRIDGE["qs_log"].read_text(errors="replace")[log_at:].splitlines() if "omarock: Apple Music" in line]
    unanswered = [line for line in lines if "(no answer)" in line]
    again = [line for line in lines if " answers again, after " in line]
    count = re.search(r"and (\d+) requests? with no answer", again[0]) if len(again) == 1 else None
    check(len(unanswered) == 1 and "only POSTs are logged" in unanswered[0] and count and int(count.group(1)) >= 2,
          f"logged: the first with no answer and the answer again ({len(unanswered)} unanswered lines, "
          f"{again[0].split('omarock: ')[-1] if again else 'no answer-again line'})", failures)
    to_source(host, "local")
    BRIDGE["config"].unlink()

    # Spotify: omarock-spotify out of reach for 6 s. Soloist would play on.
    host.call("setSource", "spotify")
    wait_for(lambda: host.state()["spotifyMode"] and host.state()["bar"]["playing"], "Spotify playing")
    back = offline(BRIDGE["spotify"], 6)
    wait_for(lambda: host.state()["stateText"].endswith("Not connected") or host.state()["source"] != "spotify",
             "omarock-spotify out of reach", timeout=8)
    s = host.state()
    check(s["source"] == "spotify" and s["stateText"] == "Spotify · Not connected",
          "Spotify stays the source while omarock-spotify is out of reach: " + s["source"] + " | " + s["stateText"], failures)
    wait_for(lambda: host.state()["spotifyMode"] and not host.state()["stateText"].endswith("Not connected"), "back", timeout=20)
    after = time.monotonic() - back
    check(after < 5 and host.state()["source"] == "spotify", f"and shows again {after:.1f} s after it's back", failures)
    # Leaving it while it's out of reach: local at once, the release once it's back.
    host.settle(1)
    offline(BRIDGE["spotify"], 6)
    wait_for(lambda: host.state()["stateText"] == "Spotify · Not connected", "omarock-spotify out of reach", timeout=8)
    releases = len(spotify_requests("/v1/release"))
    host.call("setSource", "local")
    wait_for(lambda: host.state()["source"] == "local", "local at once", timeout=3)
    wait_for(lambda: len(spotify_requests("/v1/release")) > releases, "the release, once it's back", timeout=15)
    host.settle(1.5)
    check(host.state()["source"] == "local" and mpd_state(socket_path)["state"] == "play",
          "leaving Spotify while it's out of reach: local plays, and the release goes once it's back", failures)
    host.call("close")


def outages_scenario(host, socket_path, failures):
    """The rest of what the VM's failure tests found (10-30): a live stream
    with nothing coming in reads Buffering…, not Playing, whether mpd still
    answers or not (and a stuck mpd then says why); while mpd is down, its
    missing socket isn't tried every 3 s (each a warning in the journal);
    and with omarock-sxm out of reach, no SiriusXM cover is tried (each a
    warning too), until it's back."""
    qs_log = lambda: BRIDGE["qs_log"].read_text(errors="replace")
    host.call("settings", json.dumps({"streamWatchAfter": 1}))
    host.call("open")
    host.call("setSource", "sxm")
    wait_for(lambda: host.state()["sxmMode"] and host.state()["bar"]["playing"], "SiriusXM playing")
    host.settle(2)

    # Nothing comes in for 14 s: mpd's clock stands still.
    mpd_client(socket_path, "fake_stream_starve 14")
    wait_for(lambda: host.state()["stateText"] == "SiriusXM · Buffering…", "the quiet stream noticed", timeout=13)
    check(host.state()["bar"]["playing"], "a stream with nothing coming in reads Buffering…, still playing", failures)
    wait_for(lambda: host.state()["stateText"] == "SiriusXM · Playing", "playing again", timeout=20)
    check(True, "and Playing once it sends again", failures)

    # And once mpd's buffer has run dry, mpd answers no one for 22 s.
    mpd_client(socket_path, "fake_stream_starve 22 hang")
    wait_for(lambda: host.state()["stateText"] == "SiriusXM · Buffering…", "mpd stuck on the stream noticed", timeout=13)
    wait_for(lambda: host.state()["notice"] != "", "the stuck mpd's notice", timeout=15)
    s = host.state()
    check(s["notice"] == "No sound is coming in: mpd waits for the stream",
          "a stream with nothing coming in, mpd stuck: " + s["stateText"] + " | " + s["notice"], failures)
    wait_for(lambda: host.state()["stateText"] == "SiriusXM · Playing", "playing again", timeout=30)
    check(True, "Playing again once mpd answers", failures)

    # mpd stops (its socket goes) for 10 s, and starts again.
    log_at = len(qs_log())
    mpd_client(socket_path, "fake_down 10")
    down = time.monotonic()
    wait_for(lambda: not host.state()["connected"], "mpd gone")
    wait_for(lambda: host.state()["connected"], "mpd back", timeout=20)
    back = time.monotonic() - down - 10
    missing = [line for line in qs_log()[log_at:].splitlines() if "ServerNotFoundError" in line]
    check(not missing and back < 4, f"mpd down 10 s: no try at its missing socket ({len(missing)} warnings), back {back:.1f} s after it", failures)

    # The same with its socket left behind, refusing: back as quickly.
    mpd_client(socket_path, "fake_down 5 stale")
    down = time.monotonic()
    wait_for(lambda: not host.state()["connected"], "mpd gone")
    wait_for(lambda: host.state()["connected"], "mpd back", timeout=15)
    back = time.monotonic() - down - 5
    check(back < 4, f"mpd down 5 s, its socket left behind: back {back:.1f} s after it", failures)
    wait_for(lambda: host.state()["stateText"] == "SiriusXM · Playing", "SiriusXM playing")

    # omarock-sxm out of reach for 25 s: its art goes until it's back.
    request = urllib.request.Request(BRIDGE["sxm"] + "/v1/fake/offline", data=json.dumps({"closed": 25}).encode(),
                                     method="POST", headers={"Content-Type": "application/json", "X-Omarock": "1"})
    urllib.request.urlopen(request, timeout=5).read()
    gone = time.monotonic()
    wait_for(lambda: host.state()["stateText"] == "SiriusXM · SiriusXM isn't running", "omarock-sxm missed", timeout=20)
    host.call("press", "i")
    wait_for(lambda: host.state()["info"] is not None, "the info card")
    s = host.state()
    check(s["coverUrl"] == "" and s["artRows"] == 0 and s["info"]["cover"] == "",
          f"omarock-sxm out of reach: no cover tried (card {s['coverUrl']!r}, {s['artRows']} rows, info card {s['info']['cover']!r})", failures)
    host.call("press", "Escape")
    wait_for(lambda: host.state()["stateText"] == "SiriusXM · Playing" and host.state()["coverUrl"] != "", "omarock-sxm back",
             timeout=max(1, 25 - (time.monotonic() - gone)) + 8)
    check(host.state()["artRows"] > 0, "and its art back once it is", failures)
    host.call("settings", "{}")


def apple_network_scenario(host, output, socket_path, failures):
    """Marc, 11-04: no Tailscale needed ("I'm OK with telling the user that
    stuff is sent in the clear ... or use tailscale"). Bridge 0.9.0 listens
    on any network and says so over Bonjour, and its stream's address has a
    secret from the token, which /v1/health gives only with the token (the
    fake's secretstream). omarock takes the stream from health, still knows an
    entry with the old address as Apple Music and swaps it on play, says why
    it can't switch without a stream, and its setup window lists the Macs on
    this network as well as the tailnet's, the tailnet's way first."""
    port = BRIDGE["port"]
    url = f"http://127.0.0.1:{port}"
    old = url + "/omarock.ogg"
    secret = hmac.new(b"fake-bridge-token", b"stream", hashlib.sha256).hexdigest()[:32]
    new = f"{url}/omarock-{secret}.ogg"
    token_file = BRIDGE["config"].parent / "bridge-token"
    home = BRIDGE["config"].parents[2]
    fake_bridge("secretstream", {"on": True})
    try:
        def health(token, host_name=None):
            headers = {"X-Omarock": "1"}
            if token: headers["Authorization"] = "Bearer " + token
            if host_name: headers["Host"] = f"{host_name}:{port}"
            return json.loads(urllib.request.urlopen(urllib.request.Request(url + "/v1/health", headers=headers), timeout=5).read())
        check("stream" not in health(None) and "stream" not in health("wrong") and health("fake-bridge-token")["stream"] == new
              and health("fake-bridge-token", "studio-mac.local")["stream"] == f"http://studio-mac.local:{port}/omarock-{secret}.ogg",
              "the bridge's health gives the stream only with the token, at the address it was asked by", failures)

        # Installed before 0.9.0: apple.json has the old address, and so has mpd's queue.
        BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": old}))
        host.call("open")
        wait_for(lambda: host.state()["opened"], "open")
        wait_for(lambda: host.state()["appleStream"] == new, "the stream from the bridge's health")
        check(True, "the panel takes the stream's address from the bridge's health, over apple.json's", failures)
        to_source(host, "local")
        host.call("close")
        mpd_client(socket_path, f'addid "{old}"')
        files = mpd_files(socket_path)
        mpd_client(socket_path, f"play {files.index(old)}")
        wait_for(lambda: host.state()["source"] == "apple", "the old address counts as Apple Music")
        check(True, "mpd playing the stream's old address: still Apple Music", failures)
        host.call("open")
        wait_for(lambda: host.state()["opened"], "open")
        wait_for(lambda: host.state()["appleReady"], "Apple Music")
        # mpd paused (the media keys): the Mac pauses, and mpd stops.
        mpd_client(socket_path, "pause 1")
        wait_for(lambda: mpd_state(socket_path)["state"] == "stop" and not host.state()["bar"]["playing"], "paused")
        host.call("press", "Space")
        wait_for(lambda: new in mpd_files(socket_path) and mpd_state(socket_path)["state"] == "play", "the stream's new address plays")
        current = dict(l.split(": ", 1) for l in mpd_query(socket_path, "currentsong")).get("file")
        wait_for(lambda: old not in mpd_files(socket_path), "the old address gone", timeout=5)
        check(current == new and old not in mpd_files(socket_path) and host.state()["source"] == "apple",
              "Play swaps the old entry for the stream's new address, and the old one goes", failures)
        to_source(host, "local")
        check(new not in mpd_files(socket_path), "back to local music, the stream goes", failures)

        # Another address of the same Mac (Tailscale's, then its .local name):
        # the same secret is the same stream, and Play moves it to the new
        # address, the old entry gone. Qt asks in lower case.
        other = f"http://LocalHost:{port}"
        by_name = f"http://localhost:{port}/omarock-{secret}.ogg"
        BRIDGE["config"].write_text(json.dumps({"bridge": other}))
        host.call("close")
        host.call("open")
        wait_for(lambda: host.state()["appleStream"] == by_name, "the stream by the new address, in lower case")
        mpd_client(socket_path, f'addid "{new}"')
        mpd_client(socket_path, f"play {mpd_files(socket_path).index(new)}")
        wait_for(lambda: host.state()["source"] == "apple", "the stream by its old address is still Apple Music")
        check(True, "the Mac by another address: mpd's entry by the old one still counts as Apple Music (the same secret)", failures)
        mpd_client(socket_path, "pause 1")
        wait_for(lambda: mpd_state(socket_path)["state"] == "stop", "paused")
        host.call("press", "Space")
        wait_for(lambda: by_name in mpd_files(socket_path) and mpd_state(socket_path)["state"] == "play", "the new address plays")
        # The old entry goes once the new one plays (deleteStreams after playid).
        wait_for(lambda: new not in mpd_files(socket_path), "the old entry gone", timeout=5)
        check(True, "and Play moves it to the new address, the old entry gone", failures)
        to_source(host, "local")
        BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": old}))
        host.call("close")
        host.call("open")
        wait_for(lambda: host.state()["appleStream"] == new, "back to the first address")

        # A Mac set up before this one (Marc's laptop, 11-04: moved to another
        # Mac, the bar said "omarock-1637fdd…"): its stream still counts as
        # Apple Music, and Play swaps in this Mac's, the old entry gone.
        before_mac = f"http://127.0.0.1:{port}/omarock-{'f' * 32}.ogg"
        mpd_client(socket_path, f'addid "{before_mac}"')
        mpd_client(socket_path, f"play {mpd_files(socket_path).index(before_mac)}")
        wait_for(lambda: host.state()["source"] == "apple", "another Mac's stream is still Apple Music")
        check(True, "another Mac's bridge stream in mpd's queue still counts as Apple Music", failures)
        mpd_client(socket_path, "pause 1")
        wait_for(lambda: mpd_state(socket_path)["state"] == "stop", "paused")
        host.call("press", "Space")
        wait_for(lambda: mpd_state(socket_path)["state"] == "play"
                 and dict(l.split(": ", 1) for l in mpd_query(socket_path, "currentsong")).get("file") == new, "this Mac's stream plays")
        wait_for(lambda: before_mac not in mpd_files(socket_path), "the other Mac's gone", timeout=5)
        check(True, "and Play swaps in this Mac's stream, the other's gone", failures)
        to_source(host, "local")

        # No token, and no stream in apple.json: switching says why it can't.
        saved = token_file.read_text()
        token_file.write_text("")
        BRIDGE["config"].write_text(json.dumps({"bridge": url}))
        host.call("close")
        host.call("open")
        wait_for(lambda: host.state()["appleStream"] == "", "no stream known")
        host.call("setSource", "apple")
        wait_for(lambda: "hasn't given omarock its stream" in host.state()["notice"], "the reason")
        check(host.state()["source"] == "local", "no token: Apple Music says the bridge hasn't given its stream, and stays off", failures)
        token_file.write_text(saved)
        wait_for(lambda: host.state()["appleStream"] == new, "the token back, the stream again")
        check(True, "the token back: the stream's address comes with it", failures)
        host.call("close")

        # The setup window: the tailnet's Attic Mac is also on this network, and
        # Studio Mac only here. One Mac found: its tailnet address is picked
        # (nothing set up yet, so nothing is filled in before).
        avahi = home / ".fake-avahi"
        attic = ("=;enp1s0;IPv4;Attic\\032Mac;_omarock._tcp;local;Attic-Mac.local;192.0.2.7;8710;\"version=0.9.0\"\n"
                 "=;enp1s0;IPv6;Attic\\032Mac;_omarock._tcp;local;Attic-Mac.local;fe80::7;8710;\"version=0.9.0\"\n")
        avahi.write_text(attic)
        # A Mac set up already: the window shows that one, not one it picks.
        host.call("openSetup", "apple-music")
        wait_for(lambda: host.state()["setupWindow"]["open"] and len(host.state()["setupWindow"]["macs"]) == 2, "both ways to the Mac")
        wait_for(lambda: host.state()["setupWindow"]["values"]["appleMac"] == url, "the Mac set up")
        check(True, "set up already: the window shows the Mac set up, over the one it would pick", failures)
        host.call("setupClick", "setupCancel")
        wait_for(lambda: not host.state()["setupWindow"]["open"], "closed")
        # Removed (apple.json gone): the window reads what's set again, so the
        # Mac removed isn't filled in (Marc's laptop, 11-04).
        BRIDGE["config"].unlink()
        host.call("openSetup", "apple-music")
        wait_for(lambda: host.state()["setupWindow"]["open"] and len(host.state()["setupWindow"]["macs"]) == 2, "both ways to the Mac")
        w = host.state()["setupWindow"]
        check(w["macs"] == ["Attic Mac 127.0.0.2", "Attic Mac Attic-Mac.local"] and w["macWays"] == ["tailnet", "network"]
              and w["values"]["appleMac"] == "127.0.0.2",
              "one Mac on the tailnet and this network: listed both ways, the tailnet's first and picked: "
              + repr(w["macs"]) + " " + repr(w["values"].get("appleMac")) + " other " + repr(w["otherMac"]), failures)
        host.call("grabSetupWindow", str(output / "setup-apple-network.png"))
        host.call("setupClick", "setupCancel")
        wait_for(lambda: not host.state()["setupWindow"]["open"], "closed")
        avahi.write_text(attic + "=;enp1s0;IPv4;Studio\\032Mac;_omarock._tcp;local;Studio-Mac.local;192.0.2.8;8710;\"\"\n")
        host.call("openSetup", "apple-music")
        wait_for(lambda: host.state()["setupWindow"]["open"] and len(host.state()["setupWindow"]["macs"]) == 3, "three")
        w = host.state()["setupWindow"]
        check(w["macs"] == ["Attic Mac 127.0.0.2", "Attic Mac Attic-Mac.local", "Studio Mac Studio-Mac.local"]
              and w["values"]["appleMac"] == "",
              "two Macs: Studio Mac, on this network only, listed by its host name, and none picked for you: " + repr(w), failures)
        host.call("setupClick", "setupCancel")
        wait_for(lambda: not host.state()["setupWindow"]["open"], "closed")
        avahi.unlink()
    finally:
        fake_bridge("secretstream", {"on": False})
        BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": old}))


def apple_genres_scenario(host, output, socket_path, failures):
    """Marc, 10-29, in Apple Music with Time Machine on 1989: "I enter punk in
    the box, but I'm not seeing any genres listed". Apple's catalog has only
    its top genres, as charts; the library's genres (bridge 0.6) are listed
    under YOUR GENRES and open as local genres do: Shuffle, the artists, then
    the compilations. Time Machine counts and lists only what's from its year
    or before, and an older bridge lists none."""
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    # Opening reads it again: the watch can miss a file rewritten as it was.
    host.call("open")
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    to_source(host, "apple")
    wait_for(lambda: host.state()["appleReady"], "Apple Music")

    def search(query):
        host.call("type", query)
        wait_for(lambda: host.state()["query"] == query and not host.state()["searching"], "search " + query)
        host.settle(.3)
        return host.state()

    def genres(s):
        return [(r, sub, sec) for r, sub, sec in zip(s["rows"], s["subtitles"], s["sections"]) if r.startswith("genre:")]

    s = search("punk")
    check(genres(s)[:2] == [("genre:Alternative & Punk", "10 songs", "YOUR GENRES"), ("genre:Punk", "3 songs", "")]
          and ("genre:Punk", "Apple Music charts", "GENRES") in genres(s),
          "'punk' lists your library's genres, then Apple's: " + str(genres(s)), failures)
    check(s["rows"].index("genre:Alternative & Punk") == 1 and s["rows"][0] == "playlist:PunkRock",
          "your genres come right after your playlists: " + ", ".join(s["rows"][:3]), failures)
    host.call("activate", 1, "open")
    wait_for(lambda: browsed(host, "genre:Alternative & Punk"), "the library genre")
    host.settle(.5)
    s = host.state()
    check(s["rows"] == ["shuffleall:Shuffle all songs", "artist:Bob Mould", "artist:Hüsker Dü", "artist:Sugar",
                        "compilations:Compilations"],
          "it opens to Shuffle, its artists, then its compilations: " + ", ".join(s["rows"]), failures)
    check(s["subtitles"][0] == "10 songs · 32 min" and s["subtitles"][1] == "1 album"
          and s["browseInfo"].get("subtitle") == "Genre · your library · 3 artists · 4 albums",
          "with counts: " + s["subtitles"][0] + " | " + str(s["browseInfo"].get("subtitle")), failures)
    check(s["levelButtons"]["current"][:1] == ["Shuffle"], "Shuffle is the heading's button: " + str(s["levelButtons"]["current"]), failures)
    host.grab(output / "compact-apple-library-genre.png")

    # Compilations, then an artist, open; ← comes back.
    host.call("activate", 4, "open")
    wait_for(lambda: browsed(host, "compilations:Compilations"), "the compilations")
    s = host.state()
    check(s["rows"] == ["album:Left of the Dial"] and s["subtitles"][0].startswith("Various Artists · 1987"),
          "Compilations lists the genre's compilations: " + str(s["rows"]) + " " + str(s["subtitles"]), failures)
    host.call("back")
    wait_for(lambda: browsed(host, "genre:Alternative & Punk"), "back to the genre")
    host.call("activate", 3, "open")
    wait_for(lambda: browsed(host, "artist:Sugar"), "Sugar")
    check("album:Copper Blue" in host.state()["rows"], "an artist opens to their page: " + str(host.state()["rows"]), failures)
    host.call("back")
    wait_for(lambda: browsed(host, "genre:Alternative & Punk"), "back to the genre")

    # Shuffle: the genre's songs, shuffled, to the Mac.
    plays = len(bridge_requests("/v1/play"))
    host.call("activate", 0, "play")
    wait_for(lambda: len(bridge_requests("/v1/play")) > plays, "Shuffle plays")
    body = bridge_requests("/v1/play")[-1][2]
    ids = [i["id"] for i in body["items"]]
    check(body["mode"] == "play" and sorted(ids) == sorted(["l-c-so-8", "l-c-so-9", "l-c-so-1", "l-c-so-2", "l-c-so-3", "l-c-so-4",
                                                            "l-so-1", "l-so-2", "l-so-3", "l-so-4"])
          and all(i["kind"] == "song" and i["source"] == "library" for i in body["items"]),
          "Shuffle sends the genre's 10 library songs: " + str(ids), failures)
    try:
        wait_for(lambda: host.state()["notice"] == "Playing your Alternative & Punk songs, shuffled", "it says so", timeout=5)
    except RuntimeError:
        pass
    check(host.state()["notice"] == "Playing your Alternative & Punk songs, shuffled", "and says so: " + host.state()["notice"], failures)

    # Time Machine on 1989: Sugar's 1992 album goes, and the counts follow.
    host.call("setSetting", "timeMachine", "true", "true")
    wait_for(lambda: host.state()["timeMachine"]["chip"] == "OFF", "the chip")
    host.call("press", "t")
    wait_for(lambda: host.state()["timeMachine"]["picker"]["open"], "the year picker")
    host.settle(.3)
    host.call("typeKeys", "1989")
    wait_for(lambda: host.state()["timeMachine"]["picker"]["valid"], "1989 typed")
    host.call("press", "Return")
    wait_for(lambda: host.state()["timeMachine"]["year"] == 1989, "1989 picked")
    s = search("punk")
    check(genres(s)[:2] == [("genre:Alternative & Punk", "8 songs", "YOUR GENRES"), ("genre:Punk", "3 songs", "")],
          "with 1989, only songs from then or before count: " + str(genres(s)), failures)
    s = search("rock")
    check(genres(s)[:1] == [("genre:Rock", "2 songs", "YOUR GENRES")], "'rock' finds yours: " + str(genres(s)), failures)
    s = search("punk")
    host.call("activate", s["rows"].index("genre:Alternative & Punk"), "open")
    wait_for(lambda: browsed(host, "genre:Alternative & Punk"), "the genre in 1989")
    host.settle(.3)
    s = host.state()
    check(s["rows"] == ["shuffleall:Shuffle all songs", "artist:Bob Mould", "artist:Hüsker Dü", "compilations:Compilations"]
          and s["subtitles"][0].startswith("8 songs"),
          "and the genre lists what's from 1989 or before: " + ", ".join(s["rows"]) + " | " + s["subtitles"][0], failures)
    plays = len(bridge_requests("/v1/play"))
    host.call("activate", 0, "play")
    wait_for(lambda: len(bridge_requests("/v1/play")) > plays, "Shuffle in 1989")
    ids = [i["id"] for i in bridge_requests("/v1/play")[-1][2]["items"]]
    check(len(ids) == 8 and "l-so-1" not in ids and "l-so-2" not in ids, "Shuffle plays only those 8: " + str(ids), failures)
    host.grab(output / "compact-apple-library-genre-1989.png")
    host.call("press", "t")
    wait_for(lambda: host.state()["timeMachine"]["picker"]["open"], "the year picker")
    host.settle(.3)
    host.call("typeKeys", "off")
    host.call("press", "Return")
    wait_for(lambda: host.state()["timeMachine"]["year"] == 0, "Time Machine off")
    host.call("setSetting", "timeMachine", "false", "true")

    # An older bridge: no library genres, Apple's still there.
    fake_bridge_info(False, "genres")
    s = search("punk")
    check(genres(s) == [("genre:Punk", "Apple Music charts", "GENRES")],
          "an older bridge lists only Apple's genres: " + str(genres(s)), failures)
    fake_bridge_info(True, "genres")
    host.call("back")
    to_source(host, "local")
    host.call("close")
    BRIDGE["config"].unlink()


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


def search_covers_scenario(host, failures):
    """An album found by search shows its cover, looked up by its name and
    album artist, as a genre's albums are (Marc, 10-26: Scratch Acid's one
    album showed none until it was opened)."""
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    to_source(host, "local")
    host.call("press", "/")
    host.call("typeKeys", "basement")
    wait_for(lambda: host.state()["query"] == "basement" and not host.state()["searching"], "search")
    album_at = host.state()["rows"].index("album:Basement Tapes")
    wait_for(lambda: host.state()["rowCovers"][album_at], "the album's cover in search", timeout=8)
    check(True, "an album found by search shows its cover", failures)
    host.call("close")


def history_scenario(host, output, socket_path, failures):
    """Marc, 10-27: a History "of everything the user played", from every
    source, with the source shown, on by default and kept 7 days (both
    settings). A play counts at half the song or 4 minutes, a station's song
    after 30 s; historyAfter makes that 1 s here. H opens it, as does its row
    at the top of Playlists; Enter plays a song again where it was heard, and
    looks a station's song up in Apple Music or Spotify."""
    home = BRIDGE["config"].parents[2]
    file = home / ".local/share/omarock/history.jsonl"
    file.unlink(missing_ok=True)

    def entries():
        return [json.loads(line) for line in file.read_text().splitlines() if line.strip()] if file.exists() else []

    def file_of(title):
        return next(line[6:] for line in mpd_query(socket_path, f'find "(title == \\"{title}\\")"') if line.startswith("file: "))

    def play_local(title):
        added = next(line[4:] for line in mpd_query(socket_path, f'addid "{file_of(title)}"') if line.startswith("Id: "))
        mpd_client(socket_path, "playid " + added)
        wait_for(lambda: host.state()["nowPlaying"].startswith(title), title + " playing")

    def heard_again(title):
        # A song played again goes on top of History once it counts (1 s):
        # open History after that, or a row picked by its place can move.
        try:
            wait_for(lambda: sum(e["title"] == title for e in entries()) >= 2, title + " in the history again", timeout=5)
        except RuntimeError:
            pass

    def open_history():
        host.call("key", "H")
        wait_for(lambda: host.state()["browse"] == "history:History" and not host.state()["browseLoading"], "History open")
        return host.state()

    host.call("settings", json.dumps({"historyAfter": 1}))
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    to_source(host, "local")
    play_local("Glasswork")
    wait_for(lambda: any(e["title"] == "Glasswork" for e in entries()), "Glasswork in the history", timeout=8)
    e = next(e for e in entries() if e["title"] == "Glasswork")
    check(e["source"] == "local" and e["file"] == file_of("Glasswork") and e["artist"] and e["album"] and e["at"] > 0,
          "a song of yours, once heard: its file, artist and album: " + json.dumps(e), failures)

    to_source(host, "radio")
    mpd_client(socket_path, 'fake_stream_title "The Rolling Stones - Gimme Shelter"')
    wait_for(lambda: host.state()["nowPlaying"].startswith("Gimme Shelter"), "the station's song")
    wait_for(lambda: any(e["title"] == "Gimme Shelter" for e in entries()), "the station's song in the history", timeout=8)
    e = next(e for e in entries() if e["title"] == "Gimme Shelter")
    station = e["station"]
    check(e["source"] == "radio" and e["artist"] == "The Rolling Stones" and station not in ("", "Radio"),
          "a station's song, with the station: " + json.dumps(e), failures)
    mpd_client(socket_path, 'fake_stream_title "' + station + '"')
    host.settle(2.5)
    check(not any(e["title"] == station for e in entries()), "the station saying its own name isn't a song", failures)

    # One from Spotify, two days ago (as if played then): a song its catalog has.
    found = urllib.request.Request(BRIDGE["spotify"] + "/v1/search?q=Sunspots&scope=catalog", headers={"X-Omarock": "1"})
    with urllib.request.urlopen(found, timeout=5) as reply:
        song = json.loads(reply.read())["catalog"]["songs"][0]
    spotify_entry = {"at": int(time.time() * 1000) - 2 * 86400 * 1000, "source": "spotify", "title": song["title"],
                     "artist": song["artist"], "album": song["album"], "ref": {"kind": "song", "id": song["id"], "source": "catalog"}}
    with file.open("a") as f:
        f.write(json.dumps(spotify_entry) + "\n")

    s = open_history()
    check(s["rows"] == ["historylookup:Gimme Shelter", "history:Glasswork", "history:" + song["title"]]
          and s["sections"][0] == "TODAY" and s["sections"][1] == "" and s["sections"][2] not in ("", "TODAY")
          and s["subtitles"][0] == "The Rolling Stones · " + station + " · Radio" and s["subtitles"][2].endswith("· Spotify"),
          "H: newest first, by day, with where each was heard: " + " | ".join(f"{a} [{b}] {c}" for a, b, c in
                                                                         zip(s["rows"], s["sections"], s["subtitles"])), failures)
    check(s["browseInfo"]["subtitle"] == "3 songs · the last 7 days", "its heading: " + s["browseInfo"]["subtitle"], failures)
    check("Enter look it up" in s["hint"] if s["cursor"] == 0 else True, "a station's song: Enter looks it up", failures)
    host.grab(output / "compact-history.png")

    # Enter on your song, while the radio plays: local music again, and it plays.
    host.call("activate", 1, "open")
    wait_for(lambda: host.state()["source"] == "local" and host.state()["nowPlaying"].startswith("Glasswork"),
             "Glasswork playing again, on local music")
    check(True, "a song of yours plays again from mpd, on local music", failures)
    heard_again("Glasswork")

    # Spotify's song plays there, by its id; the station's is looked up.
    # By name, not place: what was heard again since (a second is enough
    # here) goes on top.
    before = len(spotify_requests("/v1/play"))
    s = open_history()
    host.call("activate", s["rows"].index("history:Sunspots"), "open")
    wait_for(lambda: len(spotify_requests("/v1/play")) > before, "Spotify asked to play it")
    body = spotify_requests("/v1/play")[-1][2] or {}
    check(song["id"] in json.dumps(body), "a Spotify song plays on Spotify by its id: " + json.dumps(body), failures)
    wait_for(lambda: host.state()["source"] == "spotify", "Spotify the source")
    heard_again(song["title"])
    s = open_history()
    host.call("activate", s["rows"].index("historylookup:Gimme Shelter"), "open")
    wait_for(lambda: host.state()["query"] == "Gimme Shelter The Rolling Stones", "the station's song looked up")
    check(host.state()["lookup"] in ("apple", "spotify"), "a station's song is looked up in Apple Music or Spotify: "
          + host.state()["lookup"], failures)
    host.call("back")
    to_source(host, "local")

    # History at the top of Playlists, after its buttons.
    host.call("key", "P")
    wait_for(lambda: host.state()["browse"].startswith("playlists:") and not host.state()["browseLoading"], "Playlists")
    rows = host.state()["rows"]
    check("historylist:History" in rows and all(r.startswith("savequeue:") for r in rows[:rows.index("historylist:History")])
          and "History" in host.state()["levelButtons"]["current"],
          "Playlists has a History button, after Save the queue: " + str(host.state()["levelButtons"]["current"]), failures)
    host.call("activate", rows.index("historylist:History"), "open")
    wait_for(lambda: host.state()["browse"] == "history:History", "its row opens History")
    host.call("close")

    # Off: nothing more is kept.
    host.call("settings", json.dumps({"historyAfter": 1, "history": False}))
    count = len(entries())
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    play_local("Fernweh")
    host.settle(2.5)
    check(len(entries()) == count, "switched off, nothing more is kept", failures)

    # Clear the history (the settings' button, after asking).
    host.call("settings", json.dumps({"historyAfter": 1}))
    host.call("press", ",")
    wait_for(lambda: host.state()["settingsOpen"] and host.state()["settingsRows"], "settings open")
    settings_cursor_to(host, "historyClear")
    host.call("press", "Return")
    wait_for(lambda: host.state()["confirmOpen"], "asked before clearing")
    host.call("press", "Return")
    wait_for(lambda: not file.exists(), "the file gone")
    check(host.state()["notice"] == "History cleared", "Clear the history empties it: " + host.state()["notice"], failures)
    host.call("press", "Escape")
    host.call("settings", "{}")
    host.call("close")


def hover_scroll_scenario(host, failures):
    """The pointer on a row that the list's edge cuts in half puts the cursor
    there and leaves the list where it is. It used to scroll that row into
    view, which moved the list under the pointer: as the mouse went up and
    down over the list, the list rocked a row back and forth. The keys still
    scroll to the cursor."""
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    to_source(host, "sxm")
    wait_for(lambda: host.state()["sxmMode"] and len(host.state()["rows"]) > 20, "sxm's channels")
    reopen(host)
    host.call("scrollList", 400)
    host.settle(.4)
    for edge, key, step in (("bottom", "Down", 1), ("top", "Up", -1)):
        cut = json.loads(host.call("cutRow", edge))
        host.settle(.3)
        host.hover(cut["x"], cut["y"])
        host.settle(.6)
        s = host.state()
        check(s["cursor"] == cut["index"] and abs(s["listY"] - cut["listY"]) <= 1,
              f"the pointer on the row half off the {edge}: the cursor on it ({s['cursor']}, row {cut['index']}), "
              f"the list put ({cut['listY']} -> {s['listY']})", failures)
        # The pointer off the list, onto the card's corner; then a key.
        host.hover(4, 4)
        host.call("press", key)
        host.settle(.4)
        after = host.state()
        # The cursor left the list with the pointer: the key brings it back
        # there, scrolled into view.
        check(after["cursor"] == cut["index"] and (after["listY"] - s["listY"]) * step > 0,
              f"then {key} brings the cursor back to row {after['cursor']}, in view ({s['listY']} -> {after['listY']})", failures)


def page_sweep(host, what, get, failures):
    """PgDn to the end, then PgUp to the top, each press checked against
    Paging.js's rule: the cursor to the last (first) row in full view, else a
    page on, and in full view after. get(state) is (cursor, rows in full
    view, scroll, count, scrolled to the top)."""
    scrolled = False
    for key, direction in (("PageDown", 1), ("PageUp", -1)):
        end = get(host.state())[3] - 1 if direction > 0 else 0
        for _ in range(get(host.state())[3] + 1):
            cursor, shown, scroll, count, _ = get(host.state())
            if cursor == end: break
            if not shown:
                check(False, f"{what}: rows in full view, to page through", failures)
                return
            edge = shown["last"] if direction > 0 else shown["first"]
            want = edge if (edge - cursor) * direction > 0 else cursor + direction * max(1, shown["last"] - shown["first"])
            want = max(0, min(count - 1, want))
            host.call("press", key)
            host.settle(.35)
            after = get(host.state())
            if after[0] != want or not after[1] or not after[1]["first"] <= want <= after[1]["last"]:
                check(False, f"{what}: {key} from {cursor} (in view {shown}) goes to {want}, in full view: "
                      f"got {after[0]} (in view {after[1]})", failures)
                return
            scrolled = scrolled or after[2] != scroll
        check(get(host.state())[0] == end, f"{what}: {key} again and again goes to row {end}", failures)
    check(scrolled, f"{what}: the list follows a page at a time", failures)
    check(get(host.state())[4], f"{what}: back at the top ({get(host.state())[2]})", failures)


def paging_scenario(host, output, failures):
    """Marc, 10-28: "can we make 'e' work in the setting panel, and also can
    we make pgup and pgdn work in settings and in any panel list?" PgDn takes
    the cursor to the last row in full view, then a page on, the list
    following; PgUp the same way back. In both panels' lists, the expanded
    panel's columns, the settings and the playlist picker; the info card and
    the keys page scroll a page. e expands and compacts the settings, the
    info card and the keys page as it does the rest."""
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    host.call("expand", "false")
    to_source(host, "sxm")
    wait_for(lambda: host.state()["sxmMode"] and len(host.state()["rows"]) > 20, "sxm's channels")
    reopen(host)
    host.hover(4, 4)
    the_list = lambda s: (s["cursor"], s["paging"]["list"], s["paging"]["listY"], len(s["rows"]), s["paging"]["listTop"])
    host.call("press", "PageDown")
    host.settle(.35)
    check(host.state()["cursor"] >= 0, "PgDn with no cursor puts one on the list", failures)
    page_sweep(host, "the compact panel's list", the_list, failures)

    # The card: PgDn goes back down to the list. (It has links only while
    # something with an artist or a song plays; in the full run, at this
    # point, a channel may have none.)
    if host.state()["cardLinks"]:
        host.call("press", "Up")
        host.settle(.2)
        check(host.state()["cardFocus"] != "", "↑ from the top goes up into the card", failures)
        host.call("press", "PageUp")
        host.settle(.2)
        check(host.state()["cardFocus"] != "", "in the now playing card, PgUp stays there", failures)
        host.call("press", "PageDown")
        host.settle(.3)
        check(host.state()["cardFocus"] == "" and host.state()["cursor"] == 0, "PgDn goes back down to the list", failures)

    # The keys page: a page, a line, and e.
    host.call("press", "?")
    wait_for(lambda: host.state()["keysOpen"], "the keys page")
    host.settle(.2)
    host.call("press", "PageDown")
    host.settle(.2)
    paged = host.state()["paging"]["keysY"]
    host.call("press", "Down")
    host.settle(.2)
    lined = host.state()["paging"]["keysY"]
    check(paged > 100 and lined > paged, f"the keys page: PgDn scrolls a page ({paged}), ↓ a line more ({lined})", failures)
    host.call("press", "PageUp")
    host.call("press", "PageUp")
    host.settle(.2)
    check(host.state()["paging"]["keysY"] == 0, "PgUp goes back up the keys page", failures)
    host.call("press", "e")
    wait_for(lambda: host.state()["expanded"], "e on the keys page expands")
    check(host.state()["keysOpen"], "e on the keys page expands it, still open", failures)
    host.call("press", "e")
    wait_for(lambda: not host.state()["expanded"], "and compacts")
    host.call("press", "?")
    wait_for(lambda: not host.state()["keysOpen"], "the keys page closed")

    # The info card: e, and PgDn doesn't close it.
    host.call("press", "i")
    wait_for(lambda: host.state()["info"] is not None, "the info card")
    host.call("press", "PageDown")
    host.settle(.2)
    check(host.state()["info"] is not None and host.state()["paging"]["infoY"] >= 0, "PgDn in the info card scrolls it, open", failures)
    host.call("press", "e")
    wait_for(lambda: host.state()["expanded"], "e on the info card expands")
    check(host.state()["info"] is not None, "e in the info card expands it, still open", failures)
    host.grab(output / "expanded-info-e.png")
    host.call("press", "e")
    wait_for(lambda: not host.state()["expanded"], "and compacts")
    host.call("press", "Escape")
    wait_for(lambda: host.state()["info"] is None, "the info card closed")

    # The settings: a page at a time, and e. From the compact panel they open
    # in the expanded one (Marc, 11-05), which goes back to compact as they close.
    host.call("press", ",")
    wait_for(lambda: host.state()["settingsOpen"] and host.state()["settingsRows"], "the settings")
    wait_for(lambda: host.state()["expanded"], "the settings, expanded")
    host.settle(.3)
    the_settings = lambda s: (s["settingsCursor"], s["paging"]["settings"], s["paging"]["settingsY"], len(s["settingsRows"]),
                              s["paging"]["settingsY"] <= 1)
    page_sweep(host, "the settings", the_settings, failures)
    host.call("press", "Down")
    host.call("press", "Down")
    host.settle(.2)
    before = host.state()
    host.call("press", "e")
    wait_for(lambda: not host.state()["expanded"], "e in the settings compacts")
    after = host.state()
    check(after["settingsOpen"] and after["settingsTab"] == before["settingsTab"] and after["settingsCursor"] == before["settingsCursor"],
          f"e in the settings compacts them, on the same tab and row ({before['settingsCursor']} -> {after['settingsCursor']})", failures)
    host.grab(output / "compact-settings-e.png")
    host.call("press", "PageDown")
    host.settle(.3)
    s = host.state()
    shown = s["paging"]["settings"]
    check(shown is not None and s["settingsCursor"] in (shown["last"], len(s["settingsRows"]) - 1),
          f"PgDn in the compact settings: to the last row in view ({s['settingsCursor']}, {shown})", failures)
    host.call("press", "e")
    wait_for(lambda: host.state()["expanded"], "e in the settings expands")
    check(host.state()["settingsOpen"], "and expands them again, still open", failures)
    host.call("press", ",")
    wait_for(lambda: not host.state()["settingsOpen"], "the settings closed")
    wait_for(lambda: not host.state()["expanded"], "back to compact")
    check(True, "the settings closed: back to the compact panel they were opened from", failures)

    # The expanded panel: its list, then the results' column.
    host.call("press", "e")
    wait_for(lambda: host.state()["expanded"], "expanded")
    reopen(host)
    host.hover(4, 4)
    host.call("press", "Down")
    host.settle(.3)
    page_sweep(host, "the expanded panel's list", the_list, failures)
    host.call("press", "/")
    host.call("type", "deep")
    wait_for(lambda: host.state()["columns"] and len(host.state()["rows"]) > 12 and not host.state()["searching"], "results for deep")
    host.call("press", "Down")
    host.settle(.4)
    page_sweep(host, "the results' column", the_list, failures)
    host.call("press", "Escape")
    host.call("expand", "false")

    # The playlist picker, on a local song.
    to_source(host, "local")
    host.call("press", "/")
    host.call("type", "glass")
    wait_for(lambda: any(r.startswith("song:") for r in host.state()["rows"]) and not host.state()["searching"], "songs for glass")
    host.call("press", "Down")
    rows = host.state()["rows"]
    for _ in range(next(i for i, r in enumerate(rows) if r.startswith("song:"))): host.call("press", "Down")
    host.call("press", "A")
    wait_for(lambda: host.state()["pickerOpen"], "the playlist picker")
    choices = len(host.state()["pickerChoices"])
    host.call("press", "PageDown")
    host.settle(.3)
    at = host.state()["pickerIndex"]
    host.call("press", "PageUp")
    host.settle(.3)
    check(choices > 1 and at > 0 and host.state()["pickerIndex"] == 0,
          f"the playlist picker: PgDn down its {choices} choices (to {at}), PgUp back to the first", failures)
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["pickerOpen"], "the picker closed")
    host.call("close")


def scrolling_scenario(host, output, socket_path, failures):
    """Marc, 10-26: "an option to scroll long song names in the bar ... We
    should scroll them in the panels automatically, no option." On the bar a
    song too wide ends in … unless Scroll a long song (scrollBarSong) is on;
    in the now playing card a long title, artist or album scrolls, while the
    panel is open. Each rests at its start a moment first."""
    host.call("open")
    wait_for(lambda: host.state()["opened"] and host.state()["bar"]["showSong"], "a song on the bar")
    host.call("settings", json.dumps({"maxLabelWidth": 80}))
    wait_for(lambda: host.state()["bar"]["songWidth"] == 80, "the song 80 px wide")
    bar = host.state()["bar"]
    check(bar["overflowing"] and not bar["scrolling"], "a song too wide for the bar ends in …, by default", failures)
    host.call("settings", json.dumps({"maxLabelWidth": 80, "scrollBarSong": True}))
    wait_for(lambda: host.state()["bar"]["scrolling"], "the bar's song scrolls")
    check(host.state()["bar"]["scrolled"] == 0, "it rests at the start first", failures)
    wait_for(lambda: host.state()["bar"]["scrolled"] > 5, "it moves", timeout=6)
    check(True, "with Scroll a long song on, the bar's song scrolls", failures)
    host.call("settings", "{}")
    wait_for(lambda: not host.state()["bar"]["scrolling"] and host.state()["bar"]["scrolled"] == 0, "back to …")

    # The card: a station's long song title.
    to_source(host, "radio")
    wait_for(lambda: host.state()["radioMode"] and host.state()["nowPlaying"] != "", "the radio")
    mpd_client(socket_path, 'fake_stream_title "Godspeed You! Black Emperor - Storm (Lift Yr. Skinny Fists Like Antennas To Heaven), Part One"')
    wait_for(lambda: (host.state()["cardScrolling"][0] or {}).get("scrolling"), "the card's title scrolls")
    wait_for(lambda: host.state()["cardScrolling"][0]["offset"] > 5, "it moves", timeout=6)
    check(True, "the card's long title scrolls, with no setting", failures)
    host.grab(output / "compact-scrolling.png")
    host.call("hide")
    wait_for(lambda: not host.state()["opened"], "closed")
    card = host.state()["cardScrolling"][0]
    check(card is None or (not card["scrolling"] and card["offset"] == 0), "closed, it stops, back at its start", failures)
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open again")
    wait_for(lambda: (host.state()["cardScrolling"][0] or {}).get("scrolling"), "opened again, it scrolls again")
    to_source(host, "local")
    host.call("close")


def favorite_follow_scenario(host, output, failures):
    """A on a station used to move it to the favorites while the list stayed
    put. A in the list: the cursor follows the station or channel
    up into the favorites, and A again takes it back to its place, each time
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
        def followed(favorite):
            s = host.state()
            if s["cursor"] < 0 or s["rows"][s["cursor"]] != name: return False
            start = s["sections"].index(rest) if rest in s["sections"] else len(s["rows"])
            return (s["cursor"] < start) == favorite
        wait_for(lambda: followed(True), f"{source}: the cursor follows {name} into the favorites", timeout=10)
        host.settle(.4)
        s = host.state()
        check(in_view(s), f"{source}: A, and the cursor follows {name} up to the favorites, in view "
              f"(row {s['cursor']}, y {s['listY']})", failures)
        host.grab(output / f"favorite-follow-{source}.png")
        host.call("press", "A")
        wait_for(lambda: followed(False), f"{source}: the cursor follows {name} back", timeout=10)
        host.settle(.4)
        s = host.state()
        check(in_view(s), f"{source}: A again, and it follows {name} back to its place, in view "
              f"(row {s['cursor']}, y {s['listY']})", failures)
    to_source(host, "local")
    host.call("close")


def list_exit_scenario(host, output, failures):
    """Marc, 11-02: on SiriusXM, A favorites the channel under the cursor,
    and the cursor stayed where the pointer left the list, so making the
    channel playing a favorite meant finding it first. A cursor the pointer
    put on a row now leaves the list with it, as does ↑ from the top (into
    the card, or off the list); with no cursor, A makes the channel or
    station playing a favorite or takes it out, and ↓ brings the cursor
    back where it was. The expanded panel's columns are one area: moving to
    the preview keeps the cursor it follows."""
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    host.call("expand", "false")
    host.settle(.4)

    def soon(predicate, timeout=3):
        end = time.time() + timeout
        while time.time() < end:
            if predicate(): return True
            time.sleep(.1)
        return predicate()

    def point(name, index):
        return json.loads(host.call("rowPoint", name, index))

    def flip(source, how):
        before = host.state()["playingStation"]
        host.call("press", "A")
        flipped = soon(lambda: (host.state()["playingStation"] or {}).get("favorite") == (not before["favorite"]), 10)
        s = host.state()
        check(flipped and s["cursor"] < 0,
              f"{source}: {how}, A {'unfavorites' if before['favorite'] else 'favorites'} {before['name']}, "
              f"the one playing, and no cursor comes back ({s['cursor']})", failures)
        host.call("press", "A")
        soon(lambda: (host.state()["playingStation"] or {}).get("favorite") == before["favorite"], 10)

    for source, mode in (("sxm", "sxmMode"), ("radio", "radioMode")):
        to_source(host, source)
        wait_for(lambda: host.state()[mode] and host.state()["playingStation"], source + ": something playing")
        reopen(host)
        playing = host.state()["playingStation"]
        rows = host.state()["rows"]
        other = next(i for i, r in enumerate(rows) if r.split(":", 1)[1] != playing["name"] and point("", i))
        at = point("", other)
        host.hover(at["x"], at["y"])
        host.settle(.4)
        check(host.state()["cursor"] == other, f"{source}: the pointer on {rows[other]} puts the cursor there", failures)
        host.hover(4, 4)
        left = soon(lambda: host.state()["cursor"] < 0)
        s = host.state()
        want = "A unfavorite" if playing["favorite"] else "A favorite"
        check(left and want in s["hint"], f"{source}: the pointer off the list, and so is the cursor; "
              f"the hints offer {want} for {playing['name']}: {s['hint']}", failures)
        flip(source, "the pointer off the list")
        host.call("press", "Down")
        host.settle(.3)
        check(host.state()["cursor"] == other, f"{source}: ↓ brings the cursor back to {rows[other]}", failures)

        for _ in range(len(rows) + 1):
            if host.state()["cursor"] == 0: break
            host.call("press", "Up")
        host.call("press", "Up")
        host.settle(.3)
        s = host.state()
        check(s["cursor"] < 0 and (s["cardFocus"] != "" or not s["cardLinks"]),
              f"{source}: ↑ from the top leaves the list ({'into the card: ' + s['cardFocus'] if s['cardFocus'] else 'off it'})",
              failures)
        flip(source, "after ↑ off the top")
        host.call("press", "Down")
        host.settle(.3)
        check(host.state()["cursor"] == 0, f"{source}: ↓ comes back to the top row", failures)

    to_source(host, "local")
    reopen(host)
    rows = host.state()["rows"]
    at = point("", 2)
    if at:
        host.hover(at["x"], at["y"])
        host.settle(.4)
        host.hover(4, 4)
        left = soon(lambda: host.state()["cursor"] < 0)
        host.call("press", "Down")
        host.settle(.3)
        check(left and host.state()["cursor"] == 2,
              f"local: the cursor leaves the queue with the pointer, and ↓ brings it back to {rows[2]}", failures)

    host.call("expand", "true")
    host.settle(.6)
    host.call("press", "/")
    host.call("typeKeys", "basement")
    soon(lambda: host.state()["query"] == "basement" and len(host.state()["rows"]) >= 2, 10)
    host.settle(.5)
    rows = host.state()["rows"]
    at = point("leftColumnList", 1)
    if len(rows) < 2 or not at:
        check(False, "the expanded panel: two results to hover: " + ", ".join(rows), failures)
    else:
        host.hover(at["x"], at["y"])
        wait_for(lambda: host.state()["cursor"] == 1 and host.state()["preview"] != "", "the second result's preview")
        host.settle(.6)
        preview = host.state()["preview"]
        there = json.loads(host.call("itemAt", "rightColumnList"))
        host.hover(there["x"] + 30, there["y"] + 10)
        host.settle(.6)
        s = host.state()
        check(s["cursor"] == 1 and s["preview"] == preview,
              f"the expanded panel: into the preview, the cursor stays on {rows[1]} and its preview ({s['preview']})", failures)
        host.hover(4, 4)
        check(soon(lambda: host.state()["cursor"] < 0), "then off both columns, the cursor goes", failures)
    host.call("press", "Escape")
    host.call("press", "Escape")
    host.call("expand", "false")
    host.call("close")


def chart_requests():
    """The fake Wikipedia's requests so far: [{path, query, agent}]."""
    return [json.loads(line) for line in BRIDGE["charts_log"].read_text().splitlines()]


def time_machine_scenario(host, output, socket_path, failures):
    """Marc, 10-25: "Time Machine. The user would pick a year": a chip at the
    top, "Time Machine: OFF" until a year is picked, then the year; music
    after it left out of every search and list, on local music, Apple Music
    and Spotify; a Top 100 button beside Playlists, Billboard's year-end
    chart for the year (from Wikipedia), played on the "look up songs in"
    service; a setting switches it all on."""
    to_source(host, "local")
    queue_before = mpd_files(socket_path)
    playing_before = mpd_state(socket_path).get("song", "0")
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    s = host.state()
    check(not s["timeMachine"]["enabled"] and s["timeMachine"]["chip"] == "" and "t time machine" not in s["hint"],
          "Time Machine is off until the setting switches it on: no chip, no t", failures)
    host.call("press", "t")
    host.settle(.3)
    check(not host.state()["timeMachine"]["picker"]["open"], "t does nothing while it's off", failures)

    host.call("setSetting", "timeMachine", "true", "true")
    wait_for(lambda: host.state()["timeMachine"]["chip"] == "OFF", "the chip, off")
    s = host.state()
    check(s["timeMachine"]["top100"] == "" and "t time machine" in s["hint"] and not s["timeMachine"]["wavy"],
          "switched on: the chip says OFF, t picks a year, no Top 100 yet, and the search box is straight: " + s["hint"], failures)
    host.call("expand", "true")
    host.settle(.5)
    check(host.state()["timeMachine"]["chip"] == "Time Machine: OFF" and "Time Machine: OFF" in host.state()["headerButtons"],
          "the expanded header's chip: Time Machine: OFF", failures)
    host.grab(output / "expanded-time-machine-off.png")
    host.call("expand", "false")
    host.settle(.5)

    def pick(typed):
        host.call("press", "t")
        wait_for(lambda: host.state()["timeMachine"]["picker"]["open"], "the year picker")
        host.settle(.3)
        host.call("typeKeys", typed)
        wait_for(lambda: host.state()["timeMachine"]["picker"]["typed"] == typed, "typed " + typed)
        host.call("press", "Return")
        wait_for(lambda: not host.state()["timeMachine"]["picker"]["open"], "the picker closes")

    def file_of(title):
        return next(l[6:] for l in mpd_query(socket_path, 'find "(title == \\"%s\\")"' % title) if l.startswith("file: "))

    # A queue from either side of 1988, playing a 2019 song.
    mixed = [file_of(t) for t in ("Glasswork", "Fernweh", "Orbit Song", "Schnee")]
    mpd_client(socket_path, "clear", *['add "%s"' % f for f in mixed], "play 0")
    wait_for(lambda: host.state()["queueLength"] == 4 and host.state()["nowPlaying"].startswith("Glasswork"), "a mixed queue")

    # t: a box for the year, warning that the queue's later songs will go.
    host.call("press", "t")
    wait_for(lambda: host.state()["timeMachine"]["picker"]["open"], "the year picker")
    host.settle(.3)
    s = host.state()
    check(s["timeMachine"]["picker"]["warning"] == "Anything in the queue from after the year you enter will be removed from it.",
          "t asks for a year, warning that the queue's songs from after it will go: " + s["timeMachine"]["picker"]["warning"], failures)
    host.call("typeKeys", "1988")
    wait_for(lambda: host.state()["timeMachine"]["picker"]["valid"], "1988 typed")
    s = host.state()
    check(s["timeMachine"]["picker"]["warning"] == "2 songs in the queue are from after 1988, and will be removed from it.",
          "with a year typed, it says how many: " + s["timeMachine"]["picker"]["warning"], failures)
    host.grab(output / "compact-time-machine-picker.png")
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["timeMachine"]["picker"]["open"], "Esc closes it")
    check(host.state()["timeMachine"]["year"] == 0 and len(mpd_files(socket_path)) == 4, "Esc picks nothing, and the queue stays", failures)

    # 1988, for the local library: its 2019 and 2021 albums, and 1990's sampler, go.
    pick("1988")
    s = host.state()
    check(s["timeMachine"]["year"] == 1988 and s["timeMachine"]["chip"] == "1988" and s["timeMachine"]["top100"] == "Top 100"
          and settings_file().get("timeMachineYear") == 1988,
          "a year picked: the chip says it, Top 100 shows, and settings.json keeps it", failures)
    check("T top 100" in s["hint"], "and T is in the hints: " + s["hint"], failures)
    check(s["timeMachine"]["wavy"], "and the search box's outline waves (compact-time-machine.png)", failures)
    wait_for(lambda: mpd_files(socket_path) == [mixed[1], mixed[3]], "the later songs out of the queue")
    wait_for(lambda: host.state()["nowPlaying"].startswith("Fernweh"), "the next song up to 1988 plays")
    check(mpd_state(socket_path)["state"] == "play" and "2 songs from after it came out of the queue" in host.state()["notice"],
          "the queue's 2019 and 2021 songs come out, and the next one from 1988 plays: " + host.state()["notice"], failures)
    mpd_client(socket_path, 'add "%s"' % mixed[2])
    wait_for(lambda: mpd_files(socket_path) == [mixed[1], mixed[3]], "a later song added comes out again", timeout=6)
    check(True, "a 2021 song added from another client (mpc) comes out too", failures)
    host.grab(output / "compact-time-machine.png")
    host.call("expand", "true")
    host.settle(.5)
    host.grab(output / "expanded-time-machine.png")
    host.call("expand", "false")
    host.settle(.5)

    def results(query):
        host.call("type", query)
        wait_for(lambda: host.state()["query"] == query and not host.state()["searching"], "search " + query)
        host.settle(.3)
        return host.state()

    s = results("glass")
    check(s["rows"] == [], "search leaves out what's after 1988: Glass Harbor's own albums are 2019's and 2021's: "
          + ", ".join(s["rows"]), failures)
    check(any('date =~ \\"^(1[0-8][0-9]{2}|19[0-7][0-9]|198[0-7]|1988)\\"' in line
              for line in BRIDGE["mpd_log"].read_text().splitlines() if line.startswith("search")),
          "mpd's search asks for songs from 1988 or before", failures)
    s = results("signal")
    check("album:Left Of The Signal" in s["rows"] and not any(r.endswith("Signal Hill Sampler") for r in s["rows"]),
          "1988's compilation shows, 1990's sampler doesn't: " + ", ".join(s["rows"]), failures)
    s = results("quiet riots")
    host.call("activate", s["rows"].index("artist:The Quiet Riots"), "open")
    wait_for(lambda: host.state()["browse"] == "artist:The Quiet Riots" and not host.state()["browseLoading"], "the artist")
    s = host.state()
    check("album:Basement Tapes" in s["rows"] and "album:Live at the Basement" in s["rows"] and "album:Left Of The Signal" in s["rows"]
          and "album:Signal Hill Sampler" not in s["rows"],
          "an artist: their albums to 1988, and the 1988 compilation they're on: " + ", ".join(s["rows"]), failures)
    host.call("back")
    host.call("back")

    # A playlist: only its songs to 1988, each removed from its own place.
    mpd_client(socket_path, *['playlistadd "Then and Now" "%s"' % f for f in mixed])
    host.call("key", "P")
    wait_for(lambda: host.state()["browse"] == "playlists:Playlists" and "playlist:Then and Now" in host.state()["rows"], "Playlists")
    host.call("activate", host.state()["rows"].index("playlist:Then and Now"), "open")
    wait_for(lambda: host.state()["browse"] == "playlist:Then and Now" and not host.state()["browseLoading"], "the playlist")
    s = host.state()
    check(s["rows"] == ["playplaylist:Play the playlist", "track:Fernweh", "track:Schnee"]
          and "2 of 4 songs, to 1988" in s["browseInfo"]["subtitle"],
          "a playlist lists its songs to 1988, not 2019's or 2021's: " + ", ".join(s["rows"]) + " | " + s["browseInfo"]["subtitle"], failures)
    host.call("activate", 2, "open")
    wait_for(lambda: mpd_files(socket_path) == [mixed[1], mixed[3]] and mpd_state(socket_path).get("song") == "1", "the playlist plays")
    check(True, "Enter on its second song plays those two, from that one", failures)
    host.call("key", "P")
    wait_for(lambda: host.state()["browse"] == "playlists:Playlists" and not host.state()["browseLoading"], "Playlists again")
    host.call("activate", host.state()["rows"].index("playlist:Then and Now"), "open")
    wait_for(lambda: host.state()["browse"] == "playlist:Then and Now" and len(host.state()["rows"]) == 3, "the playlist again")
    host.call("columnRemove", "current", 2)
    wait_for(lambda: len(stored(socket_path, "Then and Now")) == 3, "Schnee removed")
    check(stored(socket_path, "Then and Now") == mixed[:3], "x takes out the song it's on, at its own place in the playlist", failures)
    mpd_client(socket_path, 'rm "Then and Now"')
    host.call("back")
    host.call("back")

    # Play with an empty queue: a song from 1988 or before.
    mpd_client(socket_path, "clear")
    wait_for(lambda: host.state()["queueLength"] == 0, "an empty queue")
    host.call("press", "Space")
    wait_for(lambda: len(mpd_files(socket_path)) == 1, "a random song")
    picked = mpd_files(socket_path)[0]
    check(not picked.startswith("Glass Harbor/") and "Signal Hill" not in picked,
          "Play on an empty queue picks a song from 1988 or before: " + picked, failures)

    # 1985 for Apple Music and the chart. Apple Music: Bob Mould's 1989 album goes.
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    # Read as the panel opens (as in the lookup scenario).
    host.call("hide")
    host.call("open")
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
    picked = len(bridge_requests("/v1/search"))

    def chart_searches():
        return sum(1 for r in map(json.loads, BRIDGE["log"].read_text().splitlines())
                   if r["path"] == "/v1/search" and r["query"].get("background") == "1")
    # Picking a year looks its chart's songs up at once; another year picked
    # stops them where they are, and the first again goes on from there.
    before = chart_searches()
    fake_bridge_info(True, "slowsearch")
    pick("1985")
    wait_for(lambda: chart_searches() - before >= 2, "1985's chart looked up")
    pick("1988")
    host.settle(1.5)
    stopped = chart_searches() - before
    host.settle(1.5)
    check(stopped < 12 and chart_searches() - before == stopped,
          f"another year picked: 1985's lookups stop where they are ({stopped} of 12 asked)", failures)
    fake_bridge_info(False, "slowsearch")
    pick("1985")
    host.call("setSource", "apple")
    wait_for(lambda: host.state()["appleMode"] and host.state()["appleReady"], "Apple Music")
    s = results("bob mould")
    check("artist:Bob Mould" in s["rows"] and "album:Workbook" not in s["rows"] and "song:Sunspots" not in s["rows"],
          "Apple Music's search leaves out 1989's Workbook, and keeps the artist: " + ", ".join(s["rows"]), failures)
    # Marc, 10-28, with 1969 set: Foo Fighters' page said Apple Music had
    # nothing by them. Bob Mould's only album is from 1989.
    host.call("activate", s["rows"].index("artist:Bob Mould"), "open")
    wait_for(lambda: host.state()["browse"] == "artist:Bob Mould" and not host.state()["browseLoading"], "Bob Mould's page")
    s = host.state()
    check(s["rows"] == [] and s["browseInfo"].get("emptyText") == "Nothing by Bob Mould is from 1985 or before (Time Machine).",
          "an artist with nothing to the year: the page says Time Machine left it all out: " + str(s["browseInfo"].get("emptyText")),
          failures)
    host.call("back")
    s = results("husker")
    check("album:Zen Arcade" in s["rows"] and "album:New Day Rising" in s["rows"],
          "and keeps 1984's and 1985's albums: " + ", ".join(s["rows"]), failures)
    host.call("back")

    # Apple Music's queue, as another device left it: 1989's songs either
    # side of 1984's, the first playing. It moves on to 1984's, and 1989's
    # Sunspots goes; See a Little Light, a later version of a song on 1985's
    # chart (looked up as 1985 was picked), stays.
    def songs(*ids): return [{"kind": "song", "id": i, "source": "catalog"} for i in ids]
    request = urllib.request.Request(f"http://127.0.0.1:{BRIDGE['port']}/v1/play", method="POST",
                                     data=json.dumps({"items": songs("c-so-8", "c-so-1", "c-so-9", "c-so-11"), "mode": "play"}).encode(),
                                     headers={"Authorization": "Bearer fake-bridge-token", "Content-Type": "application/json"})
    removes = len(bridge_requests("/v1/queue/remove"))
    urllib.request.urlopen(request, timeout=5).read()
    wait_for(lambda: host.state()["rows"] == ["queue:Something I Learned Today", "queue:See a Little Light",
                                              "queue:Keep On Loving You"], "Apple Music's queue to 1985")
    removed = [b["index"] for _, _, b in bridge_requests("/v1/queue/remove")][removes:]
    check(host.state()["nowPlaying"].startswith("Something I Learned Today") and removed == [0],
          "Apple Music's queue: past 1989's song playing to 1984's, it taken out, and the chart's song kept: " + str(removed),
          failures)
    to_source(host, "local")

    # Spotify's queue can't be changed: a later song playing is skipped.
    host.call("setSource", "spotify")
    wait_for(lambda: host.state()["spotifyMode"], "Spotify")
    spotify_post("/v1/play", {"items": songs("c-so-8", "c-so-1"), "mode": "play"})
    wait_for(lambda: host.state()["nowPlaying"].startswith("Something I Learned Today"), "Spotify past 1989's song")
    jumps = [b["index"] for _, _, b in spotify_requests("/v1/queue/jump")]
    check(jumps[-1:] == [1] and not spotify_requests("/v1/queue/remove"),
          "Spotify: 1989's song playing is skipped, to 1984's: " + str(jumps), failures)
    to_source(host, "local")

    # Top 100, from local music: the chart from Wikipedia, its songs found on
    # Apple Music (the lookup's service).
    searches = len(bridge_requests("/v1/search"))
    host.call("press", "T")
    wait_for(lambda: host.state()["browse"] == "top100:Top 100 of 1985" and len(host.state()["rows"]) == 14, "the Top 100")
    wait_for(lambda: "found on Apple Music" in host.state()["subtitles"][0], "its songs looked up")
    s = host.state()
    asked = [r for r in chart_requests() if r["query"].get("page", "").endswith("1985")][-1]
    check(asked["query"].get("page") == "Billboard Year-End Hot 100 singles of 1985" and asked["agent"].startswith("omarock"),
          "T reads Billboard's chart from Wikipedia, saying who's asking: " + json.dumps(asked["query"].get("page")), failures)
    check(s["rows"][:7] == ["playtop:Play the Top 100", "shuffletop:Shuffle the Top 100", "track:New Day Rising",
                            "track:Celebrated Summer", "track:Keep On Loving You", "chartmiss:Careless Whisper",
                            "track:Makes No Sense at All / Love Is All Around"]
          and s["subtitles"][0] == "5 of 12 found on Apple Music" and s["lookup"] == "apple" and s["cursor"] == 0
          and s["subtitles"][3] == "Hüsker Dü · New Day Rising" and s["subtitles"][5].endswith("not on Apple Music"),
          "its songs found on Apple Music, or not, the cursor on Play: " + ", ".join(s["rows"][:7]) + " | " + s["subtitles"][0], failures)
    asked = [r["query"] for r in map(json.loads, BRIDGE["log"].read_text().splitlines()) if r["path"] == "/v1/search"]
    preloaded = [q for q in asked[picked:searches] if q.get("background") == "1"]
    check(len(preloaded) >= 12 and not asked[searches:],
          f"picking 1985 looked its chart's songs up at once ({len(preloaded)} searches), and T asked nothing more: "
          + str(len(asked[searches:])), failures)
    check(all(q.get("background") == "1" for q in preloaded),
          "the chart's searches can wait their turn (background=1): omarock-spotify paces them", failures)
    check(s["levelButtons"]["current"][:4] == ["[Play]", "Shuffle", "Add to queue", "Add to playlist"],
          "the chart's buttons, the cursor on Play: " + str(s["levelButtons"]["current"]), failures)
    host.grab(output / "compact-top100.png")
    host.call("expand", "true")
    host.settle(1)
    host.grab(output / "expanded-top100.png")
    host.call("expand", "false")
    host.settle(.5)
    # The Mac slow to load them (ten seconds and more for a hundred): the
    # chart stays, saying so, until they play.
    fake_bridge_info(True, "slow")
    host.call("activate", 3, "open")
    host.settle(1)
    s = host.state()
    check(s["browse"] == "top100:Top 100 of 1985" and s["notice"] == "Starting the Top 100 of 1985 from Celebrated Summer on Apple Music…",
          "while the Mac loads the chart, it stays, saying so: " + s["notice"], failures)
    wait_for(lambda: host.state()["appleMode"], "Apple Music plays the chart")
    fake_bridge_info(False, "slow")
    play = bridge_requests("/v1/play")[-1][2]
    check(play["mode"] == "play" and len(play["items"]) == 5 and play["start"] == 1 and all(i["kind"] == "song" for i in play["items"]),
          "Enter on its second song plays the chart's songs on Apple Music, from that one: " + json.dumps(play), failures)
    check(host.state()["browse"] == "" and host.state()["rows"][0].startswith("queue:"),
          "once it plays, Apple Music's queue: " + ", ".join(host.state()["rows"][:2]), failures)
    # Its 1989 version of a 1985 hit is the year's all the same: it stays.
    host.settle(1.5)
    check("queue:See a Little Light" in host.state()["rows"],
          "the chart's songs stay in the queue, a later version too: " + ", ".join(host.state()["rows"]), failures)
    to_source(host, "local")
    # Shuffle: the same songs, in an order of their own.
    host.call("press", "T")
    wait_for(lambda: host.state()["browse"] == "top100:Top 100 of 1985" and "found on" in host.state()["subtitles"][0], "Top 100")
    check(host.call("clickPanel", "levelButton:Shuffle") == "ok", "Shuffle can be clicked", failures)
    wait_for(lambda: host.state()["appleMode"], "Apple Music plays the chart, shuffled")
    shuffled = bridge_requests("/v1/play")[-1][2]
    check(sorted(i["id"] for i in shuffled["items"]) == sorted(i["id"] for i in play["items"]) and shuffled["start"] == 0,
          "Shuffle the Top 100 plays the same songs from the first of its own order: " + json.dumps([i["id"] for i in shuffled["items"]]), failures)
    to_source(host, "local")
    searches = len(bridge_requests("/v1/search"))
    charts_asked = len(chart_requests())
    host.call("press", "T")
    wait_for(lambda: host.state()["browse"] == "top100:Top 100 of 1985" and "found on" in host.state()["subtitles"][0], "Top 100 again")
    check(len(bridge_requests("/v1/search")) == searches and len(chart_requests()) == charts_asked,
          "the second time, from what it found the first", failures)
    host.call("back")
    check(host.state()["lookup"] == "", "back in the queue, the rows are local music's again", failures)

    # The lookup setting on Spotify: the chart's songs from Spotify.
    host.call("setSetting", "lookup", "Spotify", "false")
    host.call("press", "T")
    wait_for(lambda: host.state()["browse"] == "top100:Top 100 of 1985" and "found on Spotify" in host.state()["subtitles"][0],
             "the Top 100 on Spotify")
    check(host.state()["lookup"] == "spotify" and spotify_requests("/v1/search"),
          "with the setting on Spotify, it's looked up there: " + host.state()["subtitles"][0], failures)
    host.call("activate", 0, "open")
    wait_for(lambda: host.state()["spotifyMode"], "Spotify plays the chart")
    play = spotify_requests("/v1/play")[-1][2]
    check(play["mode"] == "play" and len(play["items"]) == 5 and play["start"] == 0,
          "Play the Top 100 plays them all on Spotify: " + json.dumps(play), failures)
    host.call("setSetting", "lookup", "Apple Music", "false")
    to_source(host, "local")

    # Where songs are looked up, changed while the Top 100's are being
    # found: those stop, they're found there instead, and the open Top 100
    # follows (Marc, 10-28). 1984's chart has the same songs, looked up on
    # neither yet.
    host.call("setSetting", "lookup", "Spotify", "false")
    spotify_post("/v1/fake/slowsearch", {"on": True, "seconds": 1})
    on_spotify, on_apple = len(spotify_requests("/v1/search")), len(bridge_requests("/v1/search"))
    pick("1984")
    host.call("press", "T")
    wait_for(lambda: host.state()["browse"] == "top100:Top 100 of 1984" and spotify_requests("/v1/search")[on_spotify:],
             "1984's chart looked up on Spotify")
    host.call("setSetting", "lookup", "Apple Music", "false")
    wait_for(lambda: host.state()["browse"] == "top100:Top 100 of 1984" and host.state()["lookup"] == "apple"
             and host.state()["subtitles"][0] == "5 of 12 found on Apple Music", "the Top 100 follows to Apple Music")
    host.settle(1.2)
    stopped = len(spotify_requests("/v1/search")) - on_spotify
    host.settle(2.5)
    check(stopped < 12 and len(spotify_requests("/v1/search")) - on_spotify == stopped
          and len(bridge_requests("/v1/search")) - on_apple >= 12,
          f"the setting changed mid-lookup: Spotify's stop ({stopped} asked), and Apple Music finds them, the Top 100 with it",
          failures)
    spotify_post("/v1/fake/slowsearch", {"on": False})
    host.call("back")

    # A year Wikipedia has no page for says so.
    pick("1988")
    host.call("press", "T")
    wait_for(lambda: host.state()["browse"] == "top100:Top 100 of 1988" and not host.state()["browseLoading"], "1988's chart")
    check("no page for 1988" in (host.state()["browseInfo"].get("emptyText") or ""),
          "a chart that can't be read says why: " + str(host.state()["browseInfo"].get("emptyText")), failures)
    host.call("back")

    # Off: everything again, and no Top 100.
    pick("off")
    s = host.state()
    check(s["timeMachine"]["year"] == 0 and s["timeMachine"]["chip"] == "OFF" and s["timeMachine"]["top100"] == ""
          and not s["timeMachine"]["wavy"],
          "Off: the chip says OFF, Top 100 goes, and the search box is straight again", failures)
    s = results("glass")
    check("album:Low Tide Signals" in s["rows"], "and search finds everything again", failures)
    host.call("back")

    # The setting off, from the settings screen: no chip, and the year forgotten.
    pick("1985")
    host.call("press", ",")
    wait_for(lambda: host.state()["settingsOpen"] and "timeMachine" in host.state()["settingsRows"], "settings")
    settings_cursor_to(host, "timeMachine")
    host.call("press", "Space")
    wait_for(lambda: settings_file().get("timeMachine") is False, "Time Machine off")
    host.call("press", ",")
    wait_for(lambda: not host.state()["settingsOpen"], "settings closed")
    s = host.state()
    check(settings_file().get("timeMachineYear") == 0 and s["timeMachine"]["chip"] == "" and s["timeMachine"]["year"] == 0,
          "switched off in the settings: no chip, and its year forgotten", failures)

    saved = settings_file()
    for key in ("timeMachine", "timeMachineYear"): saved.pop(key, None)
    (BRIDGE["config"].parent / "settings.json").write_text(json.dumps(saved))
    host.call("setSetting", "timeMachine", "false", "true")
    BRIDGE["config"].unlink()
    mpd_client(socket_path, "clear", *['add "%s"' % f for f in queue_before], "play " + playing_before)
    host.call("close")


def settings_file():
    """omarock's settings file in the test HOME, as saved so far."""
    path = BRIDGE["config"].parent / "settings.json"
    return json.loads(path.read_text()) if path.exists() else {}


def settings_cursor_to(host, key):
    """Move the settings' cursor to a row: Tab to its tab, then up or down."""
    for _ in range(len(host.state()["settingsTabs"])):
        if key in host.state()["settingsRows"]: break
        host.call("press", "Tab")
    s = host.state()
    to, at = s["settingsRows"].index(key), s["settingsCursor"]
    for _ in range(abs(to - at)): host.call("press", "Down" if to > at else "Up")


def settings_scenario(host, output, failures):
    """Marc, 10-21: "where are the settings? ... a setting screen, accessible
    from a gear icon in the expanded pane"; 10-22: "Really everything should be
    changeable there", in "our own settings file". , (or the gear) opens the
    settings, in groups, each source with how its service is doing. A change
    goes into ~/.config/omarock/settings.json; an account or a key into its
    own file (tools/omarock-account), a secret never shown; the music folder
    after asking."""
    host.call("settings", "{}")
    host.call("open")
    wait_for(lambda: host.state()["opened"], "open")
    # Tab in the list does nothing (before 0.9.6 it called a function that
    # wasn't there: a QML warning, which fails the run).
    host.call("press", "Tab")
    host.settle(.3)
    check(host.state()["opened"] and not host.state()["settingsOpen"], "Tab outside the settings does nothing", failures)
    check(not host.state()["expanded"], "the panel starts compact", failures)
    host.call("press", ",")
    wait_for(lambda: host.state()["settingsOpen"] and host.state()["settingsRows"], "settings open")
    wait_for(lambda: host.state()["sourcesState"], "what's set up, read")
    # Marc, 11-05: the settings in the expanded panel, back to compact when they close.
    check(host.state()["expanded"], ", in the compact panel: the settings open in the expanded one", failures)
    s = host.state()
    # Marc, 10-26: "split the settings panel into a few tabs, "omarock",
    # apple, xm, spotify, and sound. In omarock we put the your music, radio,
    # timemachine, panel and bar".
    check([t.removesuffix(" •") for t in s["settingsTabs"]] == ["omarock", "Apple Music", "SiriusXM", "Spotify", "Sound"]
          and s["settingsTab"] == "omarock"
          and s["settingsRows"] == ["musicFolder", "radio", "radioArea", "lookup", "history", "historyDays", "historyClear",
                                    "timeMachine", "topSongs", "closeOnLeave", "maxLabelWidth", "scrollBarSong"],
          ", opens the settings on the omarock tab: your music and the radio, History, Time Machine, the panel and the bar: "
          + str(s["settingsTabs"]) + " | " + ", ".join(s["settingsRows"]), failures)
    check(all(k in s["settingsAllRows"] for k in ("sxmUser", "sxmPassword", "spotifyClient", "soloistKey",
                                                  "spotifyLogin", "bridgePair", "spotifyRemove", "sxmRemove", "appleRemove")),
          "each source set up here has its account and keys, and Remove", failures)
    # Tab goes around the tabs, each from its top; Shift+Tab goes back.
    shown = []
    for _ in range(5):
        host.call("press", "Down")
        host.call("press", "Tab")
        shown.append((host.state()["settingsTab"], host.state()["settingsRows"][0], host.state()["settingsCursor"]))
    check(shown == [("Apple Music", "appleMusic", 0), ("SiriusXM", "siriusXM", 0), ("Spotify", "spotify", 0), ("Sound", "sound", 0),
                    ("omarock", "musicFolder", 0)],
          "Tab goes around the tabs, each from its top: " + str(shown), failures)
    host.call("press", "Shift+Tab")
    check(host.state()["settingsTab"] == "Sound", "Shift+Tab goes back, round to Sound: " + host.state()["settingsTab"], failures)
    check(host.call("clickPanel", "settingsTab:Spotify") == "ok", "a tab is a button", failures)
    wait_for(lambda: host.state()["settingsTab"] == "Spotify", "the Spotify tab")
    check(host.state()["settingsRows"][0] == "spotify" and "sxmUser" not in host.state()["settingsRows"],
          "a click shows its tab, and only it: " + ", ".join(host.state()["settingsRows"]), failures)
    host.grab(output / "compact-settings-spotify.png")
    host.call("press", "Tab")
    host.call("press", "Tab")
    kinds = s["settingKinds"]
    check("spotify:boolean" in kinds and "siriusXM:boolean" in kinds and "sound:action:Set up…" in kinds
          and "localSetUp" not in s["settingsRows"],
          "a source set up has its switch; the sound output, not set up, its Set up button", failures)
    notes = s["settingNotes"]
    wait_for(lambda: host.state()["settingNotes"]["spotify"]["kind"] == "ok", "Spotify's health")
    notes = host.state()["settingNotes"]
    check(notes["spotify"]["kind"] == "ok" and notes["siriusXM"]["kind"] == "ok" and notes["radio"]["text"].endswith("Washington")
          and (notes["appleMusic"]["kind"] == "ok" or "address" in notes["appleMusic"]["text"]),
          "each source says how it's doing: " + " | ".join(n["text"] for n in notes.values()), failures)
    host.grab(output / "compact-settings.png")

    # Space on Spotify's switch: off, into the settings file, its services
    # stopped (omarock-sources stop); and back on, started again.
    systemctl_log = BRIDGE["config"].parents[2] / "systemctl.log"
    settings_cursor_to(host, "spotify")
    host.call("press", "Space")
    wait_for(lambda: settings_file().get("spotify") is False and host.state()["settingValues"]["spotify"] is False, "Spotify off")
    wait_for(lambda: "disable --now omarock-soloist omarock-spotify" in systemctl_log.read_text(), "its services stopped")
    check("spotify" not in host.state()["sources"] and host.state()["settingNotes"]["spotify"]["text"].startswith("Off"),
          "Space switches Spotify off, saved in settings.json, and stops its services: "
          + host.state()["settingNotes"]["spotify"]["text"], failures)
    host.call("press", "Space")
    wait_for(lambda: host.state()["settingValues"]["spotify"] is True, "Spotify on")
    wait_for(lambda: "enable --now omarock-soloist omarock-spotify" in systemctl_log.read_text(), "its services started")
    check("spotify" in host.state()["sources"], "and on again, its services started", failures)

    # Enter on the radio's area: type it, Enter saves it as text, and says
    # where it is.
    settings_cursor_to(host, "radioArea")
    host.call("press", "Return")
    wait_for(lambda: host.state()["settingsEditing"] == "radioArea", "editing")
    host.call("typeKeys", "Oregon")
    host.call("press", "Return")
    wait_for(lambda: host.state()["settingValues"]["radioArea"] == "Oregon", "radioArea saved")
    wait_for(lambda: "station" in host.state()["settingNotes"]["radioArea"]["text"], "Oregon found, and its stations")
    check(settings_file().get("radioArea") == "Oregon" and host.state()["settingsEditing"] == ""
          and host.state()["settingNotes"]["radio"]["text"] == "Local stations from Oregon"
          and host.state()["settingNotes"]["radioArea"]["text"].startswith("Oregon, United States · "),
          "Enter edits the radio's area, Enter saves it, and it says where that is: "
          + host.state()["settingNotes"]["radioArea"]["text"], failures)
    # Esc drops an edit.
    host.call("press", "Return")
    host.call("typeKeys", "Texas")
    host.call("press", "Escape")
    wait_for(lambda: host.state()["settingsEditing"] == "", "edit dropped")
    check(host.state()["settingValues"]["radioArea"] == "Oregon" and host.state()["settingsOpen"],
          "Esc drops an edit, and the settings stay open", failures)

    # ← → on a number: one step each way.
    rows = host.state()["settingsRows"]
    for _ in range(rows.index("maxLabelWidth") - host.state()["settingsCursor"]): host.call("press", "Down")
    host.call("press", "Right")
    wait_for(lambda: host.state()["settingValues"]["maxLabelWidth"] == 310, "width up")
    check(settings_file().get("maxLabelWidth") == 310, "→ on a number steps it up, saved as a number", failures)
    host.call("press", "Left")
    wait_for(lambda: host.state()["settingValues"]["maxLabelWidth"] == 300, "width back")

    # An account: the SiriusXM username, into siriusxm.json, not settings.json.
    sxm_login = BRIDGE["config"].parent / "siriusxm.json"
    settings_cursor_to(host, "sxmUser")
    host.call("press", "Return")
    wait_for(lambda: host.state()["settingsEditing"] == "sxmUser", "editing the username")
    host.call("typeKeys", "me@example.com")
    host.call("press", "Return")
    wait_for(lambda: host.state()["accounts"].get("sxmUser") == "me@example.com", "the username saved")
    check(json.loads(sxm_login.read_text())["username"] == "me@example.com" and "sxmUser" not in settings_file()
          and oct(sxm_login.stat().st_mode & 0o777) == "0o600",
          "the username goes into siriusxm.json (mode 600), not the settings file", failures)
    # A secret: typed into a hidden field, kept only in its file.
    host.call("press", "Down")
    host.call("press", "Return")
    wait_for(lambda: host.state()["settingsEditing"] == "sxmPassword", "editing the password")
    check("sxmPassword" not in host.state()["settingMasked"], "a secret being typed has no dots over it", failures)
    host.call("typeKeys", "hunter 2")
    host.call("press", "Return")
    wait_for(lambda: host.state()["accounts"].get("sxmPassword") is True, "the password saved")
    login = json.loads(sxm_login.read_text())
    check(login == {"username": "me@example.com", "password": "hunter 2"} and host.state()["settingValues"]["sxmPassword"] is True
          and "hunter" not in json.dumps(host.state()), "the password is saved as typed, and never shown", failures)
    # Marc, 10-24: a set secret shows as dots, "standard for most password
    # style fields"; one not set says so.
    s = host.state()
    secrets = [k for k in ("sxmPassword", "soloistKey") if k in s["settingsAllRows"]]
    check(sorted(s["settingMasked"]) == sorted(k for k in secrets if s["settingValues"].get(k) is True)
          and "sxmPassword" in s["settingMasked"],
          "each secret that's set shows dots, and only those: " + ", ".join(s["settingMasked"]), failures)

    # Marc, 10-24: signed in, the Spotify row offers Sign out (asking
    # first), not Sign in again.
    def login_row():
        return next(k for k in host.state()["settingKinds"] if k.startswith("spotifyLogin:"))
    check(login_row() == "spotifyLogin:action:Sign out" and s["settingNotes"]["spotifyLogin"]["text"].startswith("Until "),
          "signed in to Spotify: Sign out, and until when: " + s["settingNotes"]["spotifyLogin"]["text"], failures)
    settings_cursor_to(host, "spotifyLogin")
    host.call("press", "Return")
    wait_for(lambda: host.state()["confirmOpen"], "asked before signing out")
    host.grab(output / "compact-settings-sign-out.png")
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["confirmOpen"], "kept")
    check(not any(r[1] == "/v1/logout" for r in spotify_requests()), "Esc keeps the sign-in", failures)
    host.call("press", "Return")
    wait_for(lambda: host.state()["confirmOpen"], "asked again")
    host.call("press", "Return")
    wait_for(lambda: login_row() == "spotifyLogin:action:Sign in", "signed out")
    check(any(r[1] == "/v1/logout" for r in spotify_requests()) and host.state()["notice"] == "Signed out of Spotify"
          and host.state()["settingNotes"]["spotifyLogin"]["text"] == "Not signed in yet",
          "Enter signs out: the row is Sign in again: " + host.state()["notice"], failures)
    spotify_post("/v1/fake/signin", {"on": True})
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["settingsOpen"], "closed")
    host.call("press", ",")
    wait_for(lambda: host.state()["settingsOpen"] and host.state()["settingKinds"]
             and login_row() == "spotifyLogin:action:Sign out", "signed in again")
    host.grab(output / "compact-settings-accounts.png")

    # The music folder: asked about first, and Esc keeps it.
    settings_cursor_to(host, "musicFolder")
    folder = host.state()["settingValues"]["musicFolder"]
    host.call("press", "Return")
    wait_for(lambda: host.state()["settingsEditing"] == "musicFolder", "editing the folder")
    host.call("typeKeys", "/elsewhere")
    host.call("press", "Return")
    wait_for(lambda: host.state()["confirmOpen"], "asked first")
    check(host.state()["confirmFolder"].endswith("/elsewhere"), "a new music folder is asked about first: "
          + host.state()["confirmFolder"], failures)
    host.grab(output / "compact-settings-folder.png")
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["confirmOpen"], "kept")
    check(host.state()["settingValues"]["musicFolder"] == folder and host.state()["settingsOpen"],
          "Esc keeps the folder as it was: " + folder, failures)

    # Esc closes, back to the compact panel; the gear there opens them again,
    # expanded, and so does the expanded panel's.
    host.call("press", "Escape")
    wait_for(lambda: not host.state()["settingsOpen"], "closed")
    wait_for(lambda: not host.state()["expanded"], "compact again")
    check(host.state()["opened"], "Esc closes the settings, not the panel, and it's compact again", failures)
    host.settle(.5)
    host.grab(output / "compact-header.png")
    compact_width = host.card()["width"]
    check(host.call("clickPanel", "settingsButton") == "ok", "the compact panel has a gear", failures)
    wait_for(lambda: host.state()["settingsOpen"] and host.state()["expanded"], "the compact gear opens them, expanded")
    # Marc, 11-05: opened from the compact panel, the settings are only as
    # wide as they need; from the expanded one, the panel keeps its width.
    host.settle(.5)
    from_compact = host.card()["width"]
    host.grab(output / "compact-gear-settings.png")
    host.call("press", "e")
    wait_for(lambda: not host.state()["expanded"], "e compacts the settings")
    host.call("press", "e")
    wait_for(lambda: host.state()["expanded"], "e widens them again")
    host.settle(.5)
    check(compact_width < from_compact < 1000 and host.card()["width"] == from_compact,
          f"from the compact panel, the settings are only as wide as they need ({compact_width} -> {from_compact}), "
          f"after e twice too ({host.card()['width']})", failures)
    host.call("press", ",")
    wait_for(lambda: not host.state()["settingsOpen"] and not host.state()["expanded"], ", closes them, back to compact")
    host.settle(.5)
    check(host.card()["width"] == compact_width, f"and back to the compact width ({host.card()['width']})", failures)
    host.call("expand", "true")
    host.settle(1)
    expanded_width = host.card()["width"]
    check(host.call("clickPanel", "settingsButton") == "ok", "the expanded panel has a gear", failures)
    wait_for(lambda: host.state()["settingsOpen"], "gear opens settings")
    host.settle(.5)
    check(host.card()["width"] == expanded_width and expanded_width > from_compact,
          f"opened from the expanded panel, the settings keep its width ({expanded_width} -> {host.card()['width']})", failures)
    check(host.state()["settingsCursor"] == 0 and host.state()["settingsTab"] == "omarock",
          "and they open at the top of the omarock tab, whatever was chosen last time", failures)
    host.grab(output / "expanded-settings.png")
    host.call("press", ",")
    wait_for(lambda: not host.state()["settingsOpen"], ", closes them")
    check(host.state()["expanded"], "opened from the expanded panel, it stays expanded", failures)
    host.call("expand", "false")
    host.call("settings", "{}")
    host.call("close")
    # The scenarios after this one set the widget's settings, which the file
    # would outrank.
    (BRIDGE["config"].parent / "settings.json").unlink()
    sxm_login.unlink()


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


def setup_scenario(host, output, failures):
    """Marc, 10-24: each source "has a button to setup and configure. Pressing
    the button launches a terminal running the install flow for that piece,
    just like Omarchy does for package installs. When done the section ...
    will then have a switch ... and the additional relevant settings fields",
    and a button that "removes the relevant bits, and returns the panel to the
    original single button". The terminal is a stand-in (fake-terminal) that
    plays the run out on the test HOME's files, never the real ./install."""
    home = BRIDGE["config"].parents[2]
    terminal_log = home / "terminal.log"
    result_file = home / ".fake-flow-result"

    def open_settings():
        host.call("open")
        wait_for(lambda: host.state()["opened"], "open")
        if not host.state()["settingsOpen"]:
            host.call("press", ",")
        wait_for(lambda: host.state()["settingsOpen"] and host.state()["settingsRows"], "settings open")

    def press_row(key):
        settings_cursor_to(host, key)
        host.call("press", "Return")

    def launched():
        return terminal_log.read_text().splitlines()[-1] if terminal_log.exists() else ""

    def finished():
        """The run the panel started has ended, and the panel has read it."""
        wait_for(lambda: host.state()["setupLaunched"] is None, "the run ended", timeout=15)

    def window():
        return host.state()["setupWindow"]

    def open_window(key, piece):
        """Set up… on a source: its setup window, and the panel closed."""
        open_settings()
        press_row(key)
        wait_for(lambda: window()["open"] and window()["piece"] == piece, piece + "'s setup window")

    def retype(field, old, new):
        host.call("setupFocus", field)
        for _ in old: host.call("press", "Backspace")
        host.call("typeKeys", new)

    config = home / ".config/omarock"

    host.call("settings", "{}")
    open_settings()
    wait_for(lambda: host.state()["sourcesState"], "what's set up, read")

    # Remove Spotify: the terminal runs ./install --remove spotify; the panel
    # closes, so the terminal has the keyboard.
    press_row("spotifyRemove")
    wait_for(lambda: "--remove spotify" in launched(), "the terminal")
    check(launched().endswith("/install' --remove spotify") and not host.state()["opened"],
          "Remove… runs ./install --remove spotify in a terminal, and the panel closes: " + launched(), failures)
    open_settings()
    wait_for(lambda: "Being removed" in host.state()["settingNotes"]["spotify"]["text"], "being removed")
    check(True, "while it runs, the section says so: " + host.state()["settingNotes"]["spotify"]["text"], failures)
    finished()
    wait_for(lambda: "spotify:action:Set up…" in host.state()["settingKinds"], "back to Set up")
    s = host.state()
    check(not any(k in s["settingsAllRows"] for k in ("spotifyClient", "soloistKey", "spotifyLogin", "spotifyRemove"))
          and "spotify" not in s["sources"],
          "removed: the section is its Set up button again, and Spotify is gone from the panel", failures)
    host.grab(output / "compact-settings-removed.png")

    # Set up…: its window first (Marc, 10-26: "a dialog first, which has the
    # explanation of the service and how it works … links to the various
    # other bits the user needs to do … places to enter them right there …
    # a "start setup" button … that would launch the terminal"). The panel
    # closes, so the window has the keys.
    removed = launched()
    open_window("spotify", "spotify")
    w = window()
    check(not host.state()["opened"] and w["title"] == "omarock: Set up Spotify" and not w["canStart"]
          and w["blocker"] == "Needs the app's Client ID" and launched() == removed,
          "Set up… opens Spotify's setup window, not yet the terminal, and the panel closes: " + w["blocker"], failures)
    host.call("grabSetupWindow", str(output / "setup-spotify.png"))
    host.call("setupFocus", "spotifyClient")
    host.call("typeKeys", "abc123")
    wait_for(lambda: window()["notes"]["spotifyClient"] == "A Client ID is 32 letters and digits", "the Client ID's check")
    check(not window()["canStart"] and host.call("setupClick", "setupStart") == "off",
          "a Client ID that isn't one: the field says so, and Start setup is off", failures)
    client_id = "0123456789abcdef0123456789abcdef"
    retype("spotifyClient", "abc123", client_id)
    host.call("press", "Return")
    host.call("typeKeys", "soloist-test-key")
    wait_for(lambda: window()["canStart"], "Start setup, ready")
    check(window()["values"]["soloistKey"] == "•" and window()["footer"] == "Ready",
          "Enter goes on to the Soloist key; with both, Start setup is ready", failures)
    host.call("press", "Return")
    wait_for(lambda: launched().endswith("/install' spotify"), "the setup's terminal")
    key_file = config / "soloist-key"
    check(json.loads((config / "spotify.json").read_text())["clientId"] == client_id
          and key_file.read_text() == "soloist-test-key\n" and key_file.stat().st_mode & 0o777 == 0o600
          and not window()["open"],
          "Enter in the last field starts: the Client ID and the Soloist key (mode 600) saved, the window closed, "
          "./install spotify in a terminal", failures)
    open_settings()
    finished()
    wait_for(lambda: "spotify:boolean" in host.state()["settingKinds"], "its switch")
    s = host.state()
    check(all(k in s["settingsAllRows"] for k in ("spotifyClient", "soloistKey", "spotifyLogin", "spotifyRemove"))
          and s["settingValues"]["spotify"] is True and "spotify" in s["sources"],
          "Set up… runs ./install spotify; done, the section has its switch, on, and its settings", failures)

    # A setup that doesn't finish: the Set up button stays, and says so.
    press_row("sxmRemove")
    open_settings()
    finished()
    wait_for(lambda: "siriusXM:action:Set up…" in host.state()["settingKinds"], "SiriusXM removed")
    result_file.write_text("failed")
    open_window("siriusXM", "siriusxm")
    check(window()["blocker"] == "Needs you to accept the risk" and not window()["canStart"],
          "SiriusXM's window: its risk has to be accepted first", failures)
    # The switch by the keys: Tab brings it, Space flips it.
    host.call("setupFocus", "setupCheck:sxmTerms")
    host.call("press", "Space")
    check(window()["values"]["sxmTerms"] is True, "Space flips the switch", failures)
    host.call("setupFocus", "sxmUser")
    host.call("typeKeys", "me@example.com")
    host.call("press", "Return")
    host.call("typeKeys", "pass word")
    wait_for(lambda: window()["canStart"], "SiriusXM ready")
    host.call("grabSetupWindow", str(output / "setup-siriusxm.png"))
    host.call("setupClick", "setupStart")
    wait_for(lambda: launched().endswith("/install' siriusxm --yes terms"), "SiriusXM's terminal")
    login = config / "siriusxm.json"
    check(json.loads(login.read_text()) == {"username": "me@example.com", "password": "pass word"}
          and login.stat().st_mode & 0o777 == 0o600,
          "the login saved (mode 600, the password's space kept), then ./install siriusxm --yes terms: the switch", failures)
    open_settings()
    finished()
    note = host.state()["settingNotes"]["siriusXM"]
    check(note["kind"] == "bad" and "didn't finish" in note["text"] and "siriusXM:action:Set up…" in host.state()["settingKinds"],
          "a setup that fails leaves Set up…, which says it didn't finish: " + note["text"], failures)
    result_file.unlink()
    # Again: the login is there already, so only the switch.
    open_window("siriusXM", "siriusxm")
    wait_for(lambda: window()["values"]["sxmUser"] == "me@example.com", "the login filled in")
    check(window()["values"]["sxmPassword"] == "" and window()["blocker"] == "Needs you to accept the risk",
          "set up again: the window has the login already (the password set, not shown)", failures)
    host.call("setupClick", "setupCheck:sxmTerms")
    saved = login.stat().st_mtime_ns
    host.call("setupClick", "setupStart")
    wait_for(lambda: terminal_log.read_text().count("siriusxm --yes terms") == 2, "SiriusXM's terminal again")
    check(login.stat().st_mtime_ns == saved, "nothing retyped, nothing saved again", failures)
    open_settings()
    finished()
    wait_for(lambda: "siriusXM:boolean" in host.state()["settingKinds"], "SiriusXM set up")
    check(host.state()["settingNotes"]["siriusXM"]["kind"] != "bad", "set up again, it carries on", failures)

    # The sound output: picked in its window, then a line saying where it
    # plays, then removed again. Hyprland tiles its window this time (as it
    # did once on the laptop): a moment later it's floated and centered.
    tiled, hyprctl_log = home / ".fake-hypr-tiled", home / "hyprctl.log"
    tiled.write_text("omarock: Set up omarock's sound output")
    open_window("sound", "sound")
    wait_for(lambda: hyprctl_log.exists() and 'hl.dsp.window.center({ window = "address:0xfake" })' in hyprctl_log.read_text(),
             "the window floated")
    check('dispatch hl.dsp.window.float({ action = "on", window = "address:0xfake" })' in hyprctl_log.read_text(),
          "a setup window Hyprland tiled is floated and centered", failures)
    tiled.unlink()
    rule = next((l for l in hyprctl_log.read_text().splitlines() if l.startswith("eval ")), "")
    check("hl.window_rule({ match = { class = \"^org.quickshell$\", title = \"^omarock(: Set up .*| keys)$\" }, float = true, center = true })" in rule,
          "before a setup window shows, Hyprland is given a rule that floats it, centered", failures)
    wait_for(lambda: window()["outputs"], "the outputs")
    w = window()
    check(w["outputs"] == ["alsa_output.test-speakers", "alsa_output.test-headphones"]
          and w["values"]["output"] == "alsa_output.test-speakers" and w["canStart"],
          "the sound output's window lists the outputs (not omarock's own), the default picked", failures)
    host.call("setupClick", "setupOutput:alsa_output.test-headphones")
    check(window()["values"]["output"] == "alsa_output.test-headphones", "a click picks another", failures)
    host.call("setupFocus", "setupOutput:alsa_output.test-speakers")
    host.call("press", "Return")
    check(window()["values"]["output"] == "alsa_output.test-speakers", "so does Enter on one, from the keys", failures)
    host.call("grabSetupWindow", str(output / "setup-sound.png"))
    host.call("setupClick", "setupStart")
    wait_for(lambda: launched().endswith("/install' sound --output alsa_output.test-speakers"), "the sound output's setup")
    check(True, "Start setup: ./install sound --output (the one picked)", failures)
    open_settings()
    finished()
    wait_for(lambda: "sound:info" in host.state()["settingKinds"], "its line")
    check("alsa_output.test-speakers" in host.state()["settingNotes"]["sound"]["text"] and "soundRemove" in host.state()["settingsAllRows"],
          "the sound output set up: a line saying where it plays, and Remove: " + host.state()["settingNotes"]["sound"]["text"], failures)
    host.grab(output / "compact-settings-sound.png")
    press_row("soundRemove")
    open_settings()
    finished()
    wait_for(lambda: "sound:action:Set up…" in host.state()["settingKinds"], "sound removed")

    # Apple Music: the Mac from the tailnet, checked live, then pairing.
    apple_json, token_file = config / "apple.json", config / "bridge-token"
    before = {f: f.read_bytes() if f.exists() else None for f in (apple_json, token_file)}
    press_row("appleRemove")
    open_settings()
    finished()
    wait_for(lambda: "appleMusic:action:Set up…" in host.state()["settingKinds"], "Apple Music removed")
    open_window("appleMusic", "apple-music")
    wait_for(lambda: "Nothing answers at http://127.0.0.2:8710" in window()["notes"]["appleMac"], "the tailnet's Mac checked")
    w = window()
    check(w["macs"] == ["Attic Mac 127.0.0.2"] and w["values"]["appleMac"] == "127.0.0.2" and not w["otherMac"] and not w["canStart"]
          and w["blocker"].startswith("Nothing answers"),
          "the tailnet's one Mac is picked, and checked: nothing answers there, so Start setup waits", failures)
    # The pairing code isn't tried on a Mac that doesn't answer (as the
    # token wasn't: the VM, 11-03).
    check(w["notes"]["pairCode"] == "", "and the pairing code says nothing under it: " + repr(w["notes"]["pairCode"]), failures)
    host.call("setupClick", "setupMacOther")
    host.call("setupFocus", "appleMac")
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    host.call("typeKeys", f"127.0.0.1:{BRIDGE['port']}")
    wait_for(lambda: window()["notes"]["appleMac"].startswith("The bridge answers"), "the bridge answers")
    check(not window()["canStart"] and window()["otherMac"] and window()["blocker"] == "Needs the pairing code from the Mac"
          and window()["notes"]["pairCode"] == "",
          "another address: the bridge answers, and Start setup waits for the pairing code: " + window()["blocker"], failures)

    def pair_state():
        request = urllib.request.Request(url + "/v1/pair", headers={"Authorization": "Bearer fake-bridge-token"})
        return json.loads(urllib.request.urlopen(request, timeout=5).read())

    def pair_posts():
        return [r for r in map(json.loads, BRIDGE["log"].read_text().splitlines()) if r["path"] == "/v1/pair" and r["method"] == "POST"]

    # Typing: nothing is sent until there are 6 digits.
    posts = len(pair_posts())
    host.call("setupFocus", "pairCode")
    host.call("typeKeys", "048 21")
    host.settle(1.5)
    check(len(pair_posts()) == posts and window()["notes"]["pairCode"] == "",
          "a code half typed: nothing sent, nothing said under it", failures)
    # No code open on the Mac yet: the bridge says so.
    host.call("typeKeys", "3")
    wait_for(lambda: window()["notes"]["pairCode"].startswith("No pairing code is open"), "no code open")
    check(not window()["canStart"] and not token_file.exists(),
          "six digits are sent at once, with no code open on the Mac: the bridge's answer, and Start setup waits: "
          + window()["notes"]["pairCode"], failures)
    # The Mac opens one (./install pair): another code is wrong, and costs a try.
    fake_bridge("pair", {"code": "048213", "tries": 5})
    retype("pairCode", "048 213", "111111")
    wait_for(lambda: window()["notes"]["pairCode"] == "That isn't the code the Mac shows", "a wrong code")
    check(not window()["canStart"] and pair_state() == {"open": True, "expiresIn": pair_state()["expiresIn"], "triesLeft": 4},
          "a wrong code: the field says so, it cost one of the code's tries, and Start setup waits", failures)
    # The right one, typed with a dash: paired at once, the token straight
    # from the bridge into its file (mode 600).
    retype("pairCode", "111111", "048-213")
    wait_for(lambda: window()["notes"]["pairCode"] == "Paired with the bridge", "paired")
    hostname = Path("/etc/hostname").read_text().strip()
    check(window()["canStart"] and token_file.read_text() == "fake-bridge-token" and token_file.stat().st_mode & 0o777 == 0o600
          and pair_state() == {"open": False, "closed": "paired", "client": hostname}
          and [r["body"] for r in pair_posts()[posts:]] == [{"code": "048213"}, {"code": "111111"}, {"code": "048213"}],
          "the right code: paired, the token in its file (mode 600), the code used up, the Mac told this machine's name; "
          "each code sent once, as digits: " + str(pair_state()) + " " + str([r["body"] for r in pair_posts()[posts:]]), failures)
    # Closed and opened again: a token the bridge takes needs no code.
    host.call("setupClick", "setupCancel")
    wait_for(lambda: not window()["open"], "closed")
    open_window("appleMusic", "apple-music")
    host.call("setupClick", "setupMacOther")
    host.call("setupFocus", "appleMac")
    host.call("typeKeys", f"127.0.0.1:{BRIDGE['port']}")
    wait_for(lambda: window()["notes"]["pairCode"] == "Paired already: no code needed", "paired already")
    check(window()["canStart"], "opened again: the token saved is checked with the bridge, and no code is needed", failures)
    # A bridge before 0.10.0, with no token: it can't pair, and says to update it.
    token_file.unlink()
    fake_bridge("pairing", {"on": False})
    host.call("setupClick", "setupCancel")
    wait_for(lambda: not window()["open"], "closed")
    open_window("appleMusic", "apple-music")
    host.call("setupClick", "setupMacOther")
    host.call("setupFocus", "appleMac")
    host.call("typeKeys", f"127.0.0.1:{BRIDGE['port']}")
    wait_for(lambda: "older than 0.10.0" in window()["notes"]["pairCode"], "an older bridge")
    check(not window()["canStart"] and "git pull, then ./install" in window()["blocker"],
          "a bridge before 0.10.0: it can't pair, and the window says to update it: " + window()["notes"]["pairCode"], failures)
    fake_bridge("pairing", {"on": True})
    fake_bridge("pair", {"code": "300400"})
    retype("appleMac", str(BRIDGE["port"])[-1], str(BRIDGE["port"])[-1])
    host.call("setupFocus", "pairCode")
    host.call("typeKeys", "300400")
    wait_for(lambda: window()["notes"]["pairCode"] == "Paired with the bridge", "paired again")
    # The smooth-playback fix starts on (recommended); off here.
    host.call("setupClick", "setupCheck:mpris")
    host.call("grabSetupWindow", str(output / "setup-apple-music.png"))
    host.call("setupClick", "setupStart")
    wait_for(lambda: launched().endswith("/install' apple-music --no mpris"), "Apple Music's terminal")
    check(json.loads(apple_json.read_text()) == {"bridge": url, "stream": url + "/omarock.ogg"}
          and token_file.read_text() == "fake-bridge-token" and token_file.stat().st_mode & 0o777 == 0o600,
          "the Mac's address saved with the stream the bridge names, and the token from pairing; ./install apple-music --no mpris",
          failures)
    open_settings()
    finished()
    wait_for(lambda: "appleMusic:boolean" in host.state()["settingKinds"], "Apple Music set up")

    # Marc, 10-28, after setting the Mac's bridge up again (a new token):
    # "omarock still allows you to select Apple Music, but says refused token".
    # A refused token marks the tab, with the dot updates use and the reason
    # on hover, and Fix…; pairing again, in the tab, brings the new one.
    token_file.write_text("stale-token")
    host.call("close")
    open_settings()
    wait_for(lambda: "Apple Music •" in host.state()["settingsTabs"], "the refused token marks the tab", timeout=15)
    s = host.state()
    check(s["settingsTabTips"].get("Apple Music •") == "Apple Music: The bridge refused omarock's token"
          and "appleUpdate:action:Fix…" in s["settingKinds"] and "bridgePair:pair" in s["settingKinds"]
          and s["settingNotes"]["bridgePair"] == {"text": "The bridge refused omarock's token: pair again", "kind": "bad"},
          "a refused token: the tab's dot (its hover says why), Fix…, and the pairing field says to pair again: "
          + str(s["settingsTabTips"]), failures)
    settings_cursor_to(host, "bridgePair")
    wait_for(lambda: host.state()["expanded"], "the settings, expanded")
    host.settle(.5)
    host.grab(output / "expanded-settings-pair.png")
    host.call("press", "e")
    wait_for(lambda: not host.state()["expanded"], "compact settings")
    host.settle(.5)
    host.grab(output / "compact-settings-pair.png")
    host.call("press", "e")
    wait_for(lambda: host.state()["expanded"], "expanded settings")
    host.settle(.5)
    # Half a code, then Esc: nothing sent (each try counts).
    posts = len(pair_posts())
    settings_cursor_to(host, "bridgePair")
    host.call("press", "Return")
    host.call("typeKeys", "123")
    host.call("press", "Escape")
    host.settle(1)
    check(len(pair_posts()) == posts and host.state()["settingsEditing"] == "" and host.state()["settingsOpen"],
          "a code half typed, then Esc: nothing sent, the settings stay open", failures)
    # No code open on the Mac: the bridge's answer under the field.
    host.call("press", "Return")
    host.call("typeKeys", "222222")
    host.call("press", "Return")
    wait_for(lambda: host.state()["settingNotes"]["bridgePair"]["text"].startswith("No pairing code is open"), "no code open")
    check(token_file.read_text() == "stale-token" and host.state()["settingsEditing"] == "",
          "Enter pairs: with no code open on the Mac, the field says so, and the token stays", failures)
    # The Mac opens one: Enter pairs, and the dot and Fix… go.
    fake_bridge("pair", {"code": "654321"})
    host.call("press", "Return")
    host.call("typeKeys", "654 321")
    host.call("press", "Return")
    wait_for(lambda: host.state()["settingNotes"]["bridgePair"]["text"] == "Paired with the bridge", "paired")
    check(token_file.read_text() == "fake-bridge-token" and token_file.stat().st_mode & 0o777 == 0o600,
          "pairing again: the new token in its file (mode 600)", failures)
    wait_for(lambda: "Apple Music" in host.state()["settingsTabs"] and "appleUpdate:action:Fix…" not in host.state()["settingKinds"],
             "the mark gone", timeout=15)
    check(host.state()["settingNotes"]["bridgePair"] == {"text": "Paired with the bridge", "kind": "ok"},
          "the bridge takes it: the dot and Fix… go, and the note says it paired", failures)
    host.call("close")
    open_settings()
    settings_cursor_to(host, "bridgePair")
    wait_for(lambda: host.state()["settingNotes"]["bridgePair"]["text"].startswith("Paired: "), "the settled note")
    check(host.state()["settingNotes"]["bridgePair"] == {"text": "Paired: the bridge takes omarock's token", "kind": "ok"},
          "opened again: the field says omarock is paired", failures)
    for f, data in before.items():
        if data is None: f.unlink(missing_ok=True)
        else: f.write_bytes(data)

    # Cancel, or Esc in a field: the window closes, nothing runs, and what
    # was picked is forgotten.
    runs = launched()
    open_window("sound", "sound")
    wait_for(lambda: window()["outputs"], "the outputs")
    host.call("setupClick", "setupOutput:alsa_output.test-headphones")
    host.call("setupClick", "setupCancel")
    wait_for(lambda: not window()["open"], "canceled")
    open_window("sound", "sound")
    wait_for(lambda: window()["values"]["output"] == "alsa_output.test-speakers", "the default again")
    check(launched() == runs, "Cancel closes the window and runs nothing; opened again, it starts afresh", failures)
    host.call("activateSetupWindow")
    host.call("press", "Escape")
    wait_for(lambda: not window()["open"], "Esc")
    check(launched() == runs, "Esc closes it too", failures)
    open_settings()

    # Update: a Soloist build 85 days old (they stop at 90).
    soloist = home / ".local/lib/omarock-soloist/soloist"
    soloist.parent.mkdir(parents=True, exist_ok=True)
    built = time.strftime("%Y%m%d", time.localtime(time.time() - 85 * 86400))
    soloist.write_text(f"#!/bin/sh\necho 'soloist 1.3.10 ({built})'\n")
    soloist.chmod(0o755)
    host.call("press", "Escape")
    host.call("press", ",")
    wait_for(lambda: "spotifyUpdate:action:Update…" in host.state()["settingKinds"], "Update", timeout=10)
    update = next(r for r in host.state()["settingKinds"] if r.startswith("spotifyUpdate"))
    check(True, "an old Soloist: Spotify's section offers Update… (" + update + ")", failures)
    # It's on the Spotify tab, which is marked (Apple Music's may be too: the
    # harness's bridge address doesn't answer, so it has a Fix button).
    check(host.state()["settingsTab"] == "omarock" and host.state()["settingsTabs"][3] == "Spotify •"
          and host.state()["settingsTabs"][2] == "SiriusXM" and host.state()["settingsTabs"][4] == "Sound",
          "the Spotify tab is marked, so Update is seen from the first tab: " + str(host.state()["settingsTabs"]), failures)
    soloist.unlink()

    # Fix: omarock-spotify can't be reached.
    host.call("settings", json.dumps({"spotifyService": "http://127.0.0.1:9"}))
    host.call("press", "Escape")
    host.call("press", ",")
    wait_for(lambda: "spotifyUpdate:action:Fix…" in host.state()["settingKinds"], "Fix", timeout=10)
    check("Can't reach" in host.state()["settingNotes"]["spotify"]["text"],
          "something wrong: Fix…, and what's wrong: " + host.state()["settingNotes"]["spotify"]["text"], failures)
    host.grab(output / "compact-settings-fix.png")
    host.call("settings", "{}")
    host.call("close")
    # The setups switched their sources on in the settings file, which would
    # outrank the widget settings the scenarios after this one set.
    (BRIDGE["config"].parent / "settings.json").unlink(missing_ok=True)


def late_config_scenario(host, failures):
    """In a fresh install (the 4.5 RC VM, 10-22), ~/.config/omarock didn't exist
    when omarock loaded; then ./install made it and wrote apple.json. FileView
    can't watch a file in a folder that isn't there, so Apple Music stayed
    "not set up". The panel reads its files again when it opens."""
    folder = BRIDGE["config"].parent
    aside = folder.with_name(folder.name + "-aside")
    folder.rename(aside)
    try:
        host.call("reload")
        wait_for(lambda: host.call("state", quiet=True) != "", "the widget again")
        wait_for(lambda: not host.state()["appleConfigured"], "no apple.json")
    finally:
        aside.rename(folder)
    url = f"http://127.0.0.1:{BRIDGE['port']}"
    BRIDGE["config"].write_text(json.dumps({"bridge": url, "stream": url + "/omarock.ogg"}))
    host.settle(1.5)
    if host.state()["appleConfigured"]:
        print("note: Quickshell now notices a file in a folder made after it loaded")
    host.call("open")
    try:
        wait_for(lambda: host.state()["appleConfigured"], "apple.json read", timeout=5)
    except RuntimeError:
        pass
    check(host.state()["appleConfigured"], "apple.json, made after omarock loaded (and its folder too), is read when the panel opens", failures)
    host.call("close")
    BRIDGE["config"].unlink()


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
    # Opening reads it (after late-config's folder dance, whether Quickshell
    # still watches the file is a race).
    host.call("open")
    wait_for(lambda: host.state()["appleConfigured"], "apple.json read")
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
    check(s["rows"] == ["savequeue:Save the queue as a playlist", "historylist:History", "note:No playlists yet"],
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
        env.update(OMAROCK_CAPTURE_SHELL=str(shell))
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
        # And a fake Wikipedia, for Time Machine's charts.
        BRIDGE["charts_log"] = work / "chart-requests.log"
        BRIDGE["charts_log"].touch()
        charts = subprocess.Popen([sys.executable, "-I", str(TOOLS / "fake_charts.py"), str(work / "charts.port"),
                                   str(BRIDGE["charts_log"])], stdout=subprocess.PIPE, text=True)
        assert charts.stdout.readline().strip() == "fake charts ready"
        env["OMAROCK_CHARTS"] = f"http://127.0.0.1:{int((work / 'charts.port').read_text())}"
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
        # As if Spotify and SiriusXM had been set up here (./install spotify,
        # ./install siriusxm), as tools/omarock-sources finds them, so their
        # settings show; Apple Music's is the token above.
        home = Path(env["HOME"])
        for piece, unit_names in (("spotify", ["omarock-spotify", "omarock-soloist"]), ("sxm", ["omarock-sxm"])):
            (home / ".local/share/omarock" / piece).mkdir(parents=True, exist_ok=True)
            (home / ".local/share/omarock" / piece / "INSTALLED").write_text("harness\n")
            for name in unit_names:
                (home / ".config/systemd/user").mkdir(parents=True, exist_ok=True)
                (home / ".config/systemd/user" / (name + ".service")).touch()
                (home / ".fake-systemd").mkdir(exist_ok=True)
                (home / ".fake-systemd" / name).touch()
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
                            elif name == "spotify-volume": spotify_volume_scenario(host, socket_path, failures)
                            elif name == "spotify-previews": spotify_previews_scenario(host, failures)
                            elif name == "expanded-keys": expanded_keys_scenario(host, failures)
                            elif name == "sxm": sxm_scenario(host, output, socket_path, failures)
                            elif name == "real-sxm": real_sxm_scenario(host, output, socket_path, failures)
                            elif name == "radio": radio_scenario(host, output, socket_path, failures)
                            elif name == "real-radio": real_radio_scenario(host, output, socket_path, failures)
                            elif name == "radio-tuning": radio_tuning_scenario(host, socket_path, failures)
                            elif name == "radio-area": radio_area_scenario(host, output, failures)
                            elif name == "info": info_scenario(host, output, socket_path, failures)
                            elif name == "now-playing": now_playing_scenario(host, output, socket_path, failures)
                            elif name == "card-keys": card_keys_scenario(host, output, socket_path, failures)
                            elif name == "lookup": lookup_scenario(host, output, socket_path, failures)
                            elif name == "library": library_scenario(host, output, socket_path, failures)
                            elif name == "keep-state": keep_state_scenario(host, output, failures)
                            elif name == "hints": hints_scenario(host, output, failures)
                            elif name == "teardown": teardown_scenario(host, socket_path, failures)
                            elif name == "fresh-start": fresh_start_scenario(host, socket_path, failures)
                            elif name == "late-config": late_config_scenario(host, failures)
                            elif name == "sources-switch": sources_switch_scenario(host, socket_path, failures)
                            elif name == "settings": settings_scenario(host, output, failures)
                            elif name == "setup": setup_scenario(host, output, failures)
                            elif name == "apple-idle": apple_idle_scenario(host, socket_path, failures)
                            elif name == "heard": heard_scenario(host, socket_path, failures)
                            elif name == "elsewhere": elsewhere_scenario(host, socket_path, failures)
                            elif name == "reconnect": reconnect_scenario(host, socket_path, failures)
                            elif name == "outages": outages_scenario(host, socket_path, failures)
                            elif name == "apple-genres": apple_genres_scenario(host, output, socket_path, failures)
                            elif name == "apple-network": apple_network_scenario(host, output, socket_path, failures)
                            elif name == "list-tuning": list_tuning_scenario(host, failures)
                            elif name == "scrolling": scrolling_scenario(host, output, socket_path, failures)
                            elif name == "hover-scroll": hover_scroll_scenario(host, failures)
                            elif name == "paging": paging_scenario(host, output, failures)
                            elif name == "search-covers": search_covers_scenario(host, failures)
                            elif name == "history": history_scenario(host, output, socket_path, failures)
                            elif name == "time-machine": time_machine_scenario(host, output, socket_path, failures)
                            elif name == "favorite-follow": favorite_follow_scenario(host, output, failures)
                            elif name == "list-exit": list_exit_scenario(host, output, failures)
                            elif name == "bus-volume": bus_volume_scenario(host, socket_path, failures)
                            elif name == "real-apple-info": real_apple_info_scenario(host, output, socket_path, failures)
                            elif name == "real-apple-keys": real_apple_keys_scenario(host, output, socket_path, failures)
                            elif name == "real-apple-catalog": real_apple_catalog_scenario(host, output, socket_path, failures)
                            elif name == "real-apple-search": real_apple_search_scenario(host, output, socket_path, failures)
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
            charts.terminate()
            charts.wait(timeout=10)
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
