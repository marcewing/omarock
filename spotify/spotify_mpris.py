"""MPRIS for omarock-spotify: Spotify on the media keys.

Omarchy's media keys go through `omarchy-shell media`, which acts on an MPRIS
player: the one playing, else the one the keys last worked. Soloist has no
MPRIS of its own, so this puts it on the session bus as
org.mpris.MediaPlayer2.omarock_spotify ("Spotify"), from omarock-spotify's view
of Soloist: what's playing, and play, pause, next, previous and seek.

Once mpd plays, the player steps aside until Spotify plays again: Stopped,
nothing loaded, nothing it can do (Soloist's `yielded`). Otherwise the shell
would pick a paused Spotify, whose PipeWire stream stays open, over a
stopped mpd, and the play key would bring back Spotify.

Its Volume stays at 1.0 and ignores changes: the bus's volume is omarock's one
volume, and Soloist's own stays at full.

It runs a GLib main loop on a thread of its own. Every D-Bus call and signal
happens on that thread; Soloist's changes reach it through GLib.idle_add.
"""
import re
import threading
import time

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

BUS_NAME = "org.mpris.MediaPlayer2.omarock_spotify"
PATH = "/org/mpris/MediaPlayer2"
ROOT = "org.mpris.MediaPlayer2"
PLAYER = "org.mpris.MediaPlayer2.Player"
PROPS = "org.freedesktop.DBus.Properties"
STATUS = {"playing": "Playing", "buffering": "Playing", "paused": "Paused"}
LOOP = {"context": "Playlist", "track": "Track"}


class Player(dbus.service.Object):
    def __init__(self, bus, soloist, log):
        super().__init__(bus, PATH)
        self.soloist = soloist
        self.log = log
        self.last = {}
        self.track = None
        self.position = (0.0, 0.0, False)   # where, when, playing: for Seeked

    # ---------- what's playing ----------

    def loaded(self):
        return bool(self.soloist.item) and not self.soloist.yielded

    def song(self):
        s = self.soloist
        return (s.song_for(s.item) or {}) if self.loaded() else {}

    def metadata(self):
        song = self.song()
        if not song:
            return dbus.Dictionary({}, signature="sv")
        tid = re.sub(r"[^A-Za-z0-9_]", "_", song.get("id") or "none")
        m = {"mpris:trackid": dbus.ObjectPath("/org/omarock/spotify/track/" + tid),
             "xesam:title": song.get("title", "")}
        if song.get("artist"): m["xesam:artist"] = dbus.Array([song["artist"]], signature="s")
        if song.get("album"): m["xesam:album"] = song["album"]
        if song.get("duration"): m["mpris:length"] = dbus.Int64(int(song["duration"] * 1e6))
        if (song.get("artwork") or {}).get("url"): m["mpris:artUrl"] = song["artwork"]["url"]
        if song.get("trackNumber"): m["xesam:trackNumber"] = dbus.Int32(song["trackNumber"])
        if song.get("discNumber"): m["xesam:discNumber"] = dbus.Int32(song["discNumber"])
        if song.get("id"): m["xesam:url"] = "https://open.spotify.com/track/" + song["id"]
        return dbus.Dictionary(m, signature="sv")

    def playback_status(self):
        return STATUS.get(self.soloist.heard(), "Stopped") if self.loaded() else "Stopped"

    def player_props(self):
        s = self.soloist
        loaded = dbus.Boolean(self.loaded())
        options = s.options or {}
        return {"PlaybackStatus": self.playback_status(),
                "LoopStatus": LOOP.get(options.get("repeat"), "None"),
                "Shuffle": dbus.Boolean(bool(options.get("shuffle"))),
                "Metadata": self.metadata(),
                "Position": dbus.Int64(int(s.position_now() * 1e6)),
                "Rate": 1.0, "MinimumRate": 1.0, "MaximumRate": 1.0, "Volume": 1.0,
                "CanGoNext": loaded, "CanGoPrevious": loaded, "CanPlay": dbus.Boolean(self.loaded() and s.logged_in),
                "CanPause": loaded, "CanSeek": loaded, "CanControl": dbus.Boolean(True)}

    def root_props(self):
        return {"CanQuit": dbus.Boolean(False), "CanRaise": dbus.Boolean(False),
                "HasTrackList": dbus.Boolean(False), "Identity": "Spotify",
                "SupportedUriSchemes": dbus.Array([], signature="s"),
                "SupportedMimeTypes": dbus.Array([], signature="s")}

    def props(self, interface):
        if interface == ROOT:
            return self.root_props()
        if interface == PLAYER:
            return self.player_props()
        raise dbus.exceptions.DBusException("No such interface " + interface,
                                            name="org.freedesktop.DBus.Error.UnknownInterface")

    # ---------- org.freedesktop.DBus.Properties ----------

    @dbus.service.method(PROPS, in_signature="ss", out_signature="v")
    def Get(self, interface, name):
        props = self.props(interface)
        if name not in props:
            raise dbus.exceptions.DBusException("No such property " + name,
                                                name="org.freedesktop.DBus.Error.UnknownProperty")
        return props[name]

    @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return self.props(interface)

    @dbus.service.method(PROPS, in_signature="ssv")
    def Set(self, interface, name, value):
        if interface == PLAYER and name == "Shuffle":
            self.soloist.safe("set_shuffle", enabled=bool(value))
        elif interface == PLAYER and name == "LoopStatus":
            self.soloist.safe("set_repeat_track", enabled=value == "Track")
            self.soloist.safe("set_repeat_context", enabled=value == "Playlist")
        # Volume and Rate stay as they are.

    @dbus.service.signal(PROPS, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass

    # ---------- org.mpris.MediaPlayer2 ----------

    @dbus.service.method(ROOT)
    def Raise(self):
        pass

    @dbus.service.method(ROOT)
    def Quit(self):
        pass

    # ---------- org.mpris.MediaPlayer2.Player ----------

    # While another machine's Spotify plays, the keys here don't reach it;
    # Play moves it here.
    @dbus.service.method(PLAYER)
    def Next(self):
        if self.loaded() and not self.soloist.playing_elsewhere():
            self.soloist.safe("skip_next")

    @dbus.service.method(PLAYER)
    def Previous(self):
        if self.loaded() and not self.soloist.playing_elsewhere():
            self.soloist.safe("skip_prev")

    @dbus.service.method(PLAYER)
    def Pause(self):
        if not self.soloist.playing_elsewhere():
            self.soloist.safe("pause")

    @dbus.service.method(PLAYER)
    def Stop(self):
        self.Pause()

    @dbus.service.method(PLAYER)
    def Play(self):
        if self.loaded():
            self.soloist.play_here_soon()

    @dbus.service.method(PLAYER)
    def PlayPause(self):
        if not self.loaded():
            return
        if self.soloist.heard() in ("playing", "buffering"):
            self.Pause()
        else:
            self.Play()

    @dbus.service.method(PLAYER, in_signature="x")
    def Seek(self, offset):
        self.seek_to(self.soloist.position_now() + offset / 1e6)

    @dbus.service.method(PLAYER, in_signature="ox")
    def SetPosition(self, trackid, position):
        if trackid == self.metadata().get("mpris:trackid"):
            self.seek_to(position / 1e6)

    @dbus.service.method(PLAYER, in_signature="s")
    def OpenUri(self, uri):
        pass

    @dbus.service.signal(PLAYER, signature="x")
    def Seeked(self, position):
        pass

    def seek_to(self, seconds):
        length = self.song().get("duration")
        if length and seconds >= length:
            self.Next()
        elif self.loaded() and not self.soloist.playing_elsewhere():
            self.soloist.safe("seek", position_ms=int(max(0.0, seconds) * 1000))

    # ---------- telling the bus ----------

    def update(self):
        """On the GLib thread, after Soloist's state changed."""
        now = self.player_props()
        position = now.pop("Position") / 1e6
        changed = {k: v for k, v in now.items() if self.last.get(k) != v}
        if changed:
            self.last.update(changed)
            self.PropertiesChanged(PLAYER, dbus.Dictionary(changed, signature="sv"), dbus.Array([], signature="s"))
        # A jump in the same song is a seek; a new song's position is its own.
        track = now["Metadata"].get("mpris:trackid")
        where, when, playing = self.position
        expected = where + (time.monotonic() - when if playing else 0)
        if track == self.track and abs(position - expected) > 1.5:
            self.Seeked(dbus.Int64(int(position * 1e6)))
        self.track = track
        self.position = (position, time.monotonic(), now["PlaybackStatus"] == "Playing")
        return False

    def watch(self):
        s = self.soloist
        seq = None
        while True:
            with s.cond:
                s.cond.wait_for(lambda: s.seq != seq, timeout=60)
                seq = s.seq
            GLib.idle_add(self.update)


def start(soloist, log):
    """Put Spotify on the session bus; returns once it's there."""
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    player = Player(bus, soloist, log)
    player.bus_name = dbus.service.BusName(BUS_NAME, bus)
    threading.Thread(target=GLib.MainLoop().run, daemon=True).start()
    threading.Thread(target=player.watch, daemon=True).start()
    log("on the session bus as " + BUS_NAME)
    return player
