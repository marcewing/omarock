# omarock bridge (macOS)

Apple Music for omarock. Apple Music's streams are DRM-protected, so nothing on Linux
can play them. The bridge is a small Mac app that plays Apple Music with Apple's
MusicKit and streams the sound to your Linux machine, where **mpd** plays it like any
other stream. omarock talks to the bridge for search, browsing, the queue and the
transport ([API.md](API.md)).

```
Mac:   MusicKit plays ─▶ process tap (muted on the Mac) ─▶ Ogg FLAC, libFLAC ─▶ Icecast :8000
                                                                                    │ Tailscale
Linux: omarock ◀──── bridge API :8710 (JSON, bearer token) ────────────────────────┤
       mpd ◀──────── http://<mac>:8000/omarock.ogg ◀────────────────────────────────┘
```

- **Only the bridge's own playback is captured.** The Mac's default output, its volume
  and every other app's sound are left alone, and the bridge's playback is muted on the
  Mac, so the Mac can be your everyday machine.
- **Tailscale only.** The API and the stream listen on the Mac's Tailscale address and
  on loopback, never on your LAN or the internet. Every API request needs the token,
  except `/v1/health` (the bridge's version and state) and cover art (each image's
  address carries a key made from the token). The stream needs none: anyone on your
  tailnet can listen to what the bridge plays.
- **It runs in the background:** no Dock icon, started at login, restarted if it
  crashes. With nobody listening to the stream for 30 s, it pauses.

You build it yourself, because it has to be signed with your own Apple Developer
account for MusicKit to work.

## Requirements

- **A Mac** with macOS 14.2 or later (Core Audio process taps). Developed on macOS 27
  on Apple silicon; Intel Macs should work but haven't been tried.
- **Xcode** from the App Store, and [Homebrew](https://brew.sh) for `xcodegen`
  and `icecast`.
- **A paid Apple Developer Program membership** ($99 a year). MusicKit needs it, and a
  bundle ID registered with MusicKit switched on (below).
- **An Apple Music subscription** on the Apple ID the Mac's Music app uses.
- **Tailscale** on the Mac and the Linux machine, in the same tailnet.
- **On Linux:** omarock with mpd, as in the [main README](../README.md).

## 1. A bundle ID with MusicKit

1. At [developer.apple.com/account](https://developer.apple.com/account), open
   **Certificates, Identifiers & Profiles → Identifiers**, then **+** and **App IDs**
   (type App).
2. Give it a description and an explicit **bundle ID** of your own, such as
   `com.example.omarock.bridge`.
3. Register it, open it again (the Identifiers list shows your bundle ID in its
   **Identifier** column), and on the **App Services** tab tick **MusicKit**. Save.
4. Note your **Team ID** (Account → Membership details: 10 letters and digits).

Apple can take a few minutes before MusicKit answers for a new bundle ID; until then
catalog requests come back empty.

You also need an **Apple Development** signing certificate: Xcode → Settings → Accounts →
add your Apple ID → your team → Manage Certificates → + → Apple Development.

## 2. Build and install

```sh
git clone https://github.com/marcewing/omarock
cd omarock && ./install
```

On a Mac, `./install` sets up the bridge (`apple-bridge/install`), one step at a time. It
checks the requirements and offers to install what's missing from Homebrew (`xcodegen`,
`icecast`, and `gum` for its prompts). It asks for your Team ID and bundle ID
and saves them in `apple-bridge/app/Local.xcconfig`, which git ignores. Then it builds and
signs the app, installs it to `~/Applications/OmarockBridge.app`, starts it, and goes
through the Mac's permissions with you. It ends with what your Omarchy machine needs.
Every command it runs is shown, and it asks before changing anything.

Run it again whenever you like. What's done is checked and skipped. The bridge is
rebuilt only if this checkout's code has changed since the installed build, and only
once nothing is listening to the stream.

### The Mac's questions

The first time the bridge runs, the Mac asks two things. Allow both (`./install` waits
for them, and offers to open System Settings):
- **Apple Music access** ("OmarockBridge would like to access Apple Music…").
- **Audio capture**, for its own playback. If you miss the prompt, switch it on in
  System Settings → Privacy & Security → Screen & System Audio Recording (the "System
  Audio Recording Only" list).

If macOS says the login item needs approval, allow OmarockBridge in System Settings →
General → Login Items.

### Keep the Music app running

Changes to your library reach the Mac's library only while the Music app runs. That
includes songs you add from omarock and changes from your other devices. Until then,
the bridge's library lists, search and an artist's albums don't have them. omarock still
shows what you added as in your library: Apple knows at once. So have Music open at
login, in System Settings → General → Login Items & Extensions → Open at Login → +.
`./install` offers to add it, or from a terminal:

```sh
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/System/Applications/Music.app"}'
```

macOS opens Music's window at login. Closing the window leaves Music running.

### By hand

`./install` uses `apple-bridge/app/build.sh`, which you can run yourself:

```sh
brew install xcodegen icecast
apple-bridge/app/build.sh --run
```

It checks the requirements, asks once for your Team ID and bundle ID, builds (Xcode's
output goes to `apple-bridge/app/build/build.log`), installs and starts the app, and
prints what the Linux side needs.

Check it from the Mac or Linux (`/v1/health` needs no token):

```sh
curl http://100.64.0.10:8710/v1/health   # your Mac's Tailscale address
```

`authorized`, `canPlayCatalog`, `capturing` and `encoding` should all be `true`.

### What it keeps where

Everything lives in `~/Library/Application Support/omarock-bridge`, not in the repo:

| File | What it is |
| --- | --- |
| `token` | The API token omarock sends (made on first run). |
| `source.password`, `admin.password`, `relay.password` | Icecast's passwords (made on first run). |
| `icecast.xml` | Icecast's config, rewritten at each launch for the current Tailscale address. Delete its first comment line to keep your own edits. |
| `config.json` | Optional settings (below). |
| `INSTALLED` | The commit the installed app was built from. |
| `log/` | `bridge.log`, `encoder.log` (the stream's encoder), and Icecast's `error.log` and `access.log`. |

`config.json`, every field optional:

```jsonc
{ "listenHost": "100.64.0.10",   // default: the Mac's Tailscale address
  "port": 8710,                  // the API's port (Icecast's is 8000)
  "streamURL": "http://…:8000/omarock.ogg",  // what /health hands out
  "icecast": "/opt/homebrew/bin/icecast",
  "startAtLogin": true }         // false: no launch agent; run the app by hand
```

### Updating

```sh
git pull && ./install
```

or `git pull && apple-bridge/app/build.sh --run`. Both wait until nothing is listening to the
stream, because restarting the bridge under mpd gives mpd errors until it's back.
`build.sh --run-now` restarts straight away.

## 3. The Linux side

On your Omarchy machine, **Set up…** on the Apple Music tab of omarock's settings (`,`
in the panel), or `./install apple-music` in your clone there, connects to the bridge.
Its window lists the Macs among your Tailscale machines and checks that the bridge
answers. Then the bridge's token:
- **Left blank,** setup copies it from the Mac with `scp`. That needs the Mac's Remote
  Login (System Settings → General → Sharing), which the window checks first.
- **Or paste it,** and the window checks it. On the Mac it's in
  `~/Library/Application Support/omarock-bridge/token`; `pbcopy < ~/Library/Application\
  Support/omarock-bridge/token` copies it without showing it (the Mac's `./install`
  offers to). The Mac's clipboard doesn't reach Linux, so bring it across your own way.

By hand instead (`build.sh` prints these with your addresses filled in):

```sh
mkdir -p ~/.config/omarock
echo '{ "bridge": "http://100.64.0.10:8710", "stream": "http://100.64.0.10:8000/omarock.ogg" }' \
  > ~/.config/omarock/apple.json
scp you@100.64.0.10:'Library/Application Support/omarock-bridge/token' ~/.config/omarock/bridge-token
chmod 600 ~/.config/omarock/bridge-token
```

Then switch Apple Music on in omarock's settings (`,` in the panel). The token can be
pasted there later too, or copied again with **Copy with ssh** (Remote Login again).
A reinstalled bridge makes a new token: the old one is refused, and the Apple Music
tab is marked • until the new one is in (hover over the tab for why). If the Mac's
address changes, **Fix…** there (or `./install apple-music`) asks again. Its other setting there, also in
`~/.config/omarock/settings.json`:
- `appleIdleStop`: after the bridge has been paused this many seconds, mpd lets go of the
  stream.

And in the file only:
- `appleRejoin` (on by default): reconnects mpd to the stream after each change. Only a
  bridge older than 0.7.0 needs it: its stream was nearly empty while paused, and a stock
  libFLAC fell behind on it. From 0.7.0 (`"minBitrate": true` in `/v1/health`) it does
  nothing.
- `appleBridge` and `appleStream`: the addresses, instead of `apple.json`'s.
- `appleStreamLag` (1.9): how far behind the stream mpd is taken to play, until omarock
  has measured it.

You hear the Mac a moment late: mpd buffers a second of the stream before it plays, and
the sound takes a little while to get here. omarock measures how far behind mpd plays
(4 s after it joins the stream, then every 30 s) and adds what the bridge's `/v1/health`
says it holds (`streamDelay`), so the card and the bar show the song and time you hear,
not the Mac's: a song that starts by itself shows when you hear it, and one you pick
shows at once, its time cycling dots until its sound arrives.

For smooth playback, the setup window's tick (on to start) builds a patched mpd-mpris
on the Linux side; [patches/README.md](../patches/README.md) says what it fixes. Arch's own
libFLAC keeps up with the stream from bridge 0.7.0; a patched libFLAC built for an older
bridge can go (`./install apple-music` offers to remove it). `tools/omarock-doctor`
checks the Linux side: `apple.json`, the token file, the bridge's `/v1/health`, and
whether the bridge is new enough.

## Troubleshooting

- **The build fails:** `build.sh` shows the errors from its log; the whole build is in
  `apple-bridge/app/build/build.log`.
- **`authorized: false`:** allow the bridge in System Settings → Privacy & Security →
  Media & Apple Music, or ask again with
  `curl -X POST -H "Authorization: Bearer $(cat ~/.config/omarock/bridge-token)" http://…:8710/v1/authorize`
  (the dialog shows on the Mac).
- **`canPlayCatalog: false`, or catalog searches fail:** check the Apple Music
  subscription, that MusicKit is ticked for the bundle ID in `Local.xcconfig`
  (Identifiers, on developer.apple.com), and give a new bundle ID a few minutes.
- **`capturing: false`, or the stream is silent:** the audio capture permission (above).
  It belongs to the app's code signature, so building with another identity or bundle
  id asks again.
- **Nothing answers on :8710:** `bridge.log` says "waiting for a Tailscale address" until
  Tailscale is up. Check `launchctl print gui/$UID/<your bundle ID>`. Its `login:` lines
  say what it did about its launch agent: since 0.5.1, if macOS lists the agent but
  launchd hasn't got it (left by an uninstall of 0.5.0 or older), the bridge registers it
  again, or runs without it. With 0.5.0 or older, switch OmarockBridge off and on in
  System Settings → General → Login Items & Extensions (App Background Activity).
- **mpd far behind live:** update the bridge to 0.7.0 or later (`git pull`, then
  `./install`, in the Mac's clone). Older bridges' streams made mpd fall behind.
- **On Linux,** run `tools/omarock-doctor`.
- **Another Icecast on port 8000:** the bridge uses whatever answers on 127.0.0.1:8000,
  so stop the other one, or move it.
- **Logs:** `~/Library/Application Support/omarock-bridge/log/`.

## Uninstalling

```sh
./install --uninstall
```

Each part is its own step, and asks first. It takes the bridge out of macOS's login
items (`OmarockBridge --unregister`), stops it and its Icecast, removes
`~/Applications/OmarockBridge.app`, and offers to make macOS forget
the app's permissions. It also offers to delete the support folder (the token, the
passwords, `config.json`, the logs). The default is to keep that, so a reinstall works
with your Omarchy machine as it is. It only removes an app whose bundle ID matches this
checkout's `Local.xcconfig`. At the end it lists what stays: Homebrew's tools, Xcode,
the clone and its `Local.xcconfig`, and your bundle ID on developer.apple.com, which you
can delete there (Identifiers).

By hand:

```sh
tccutil reset All com.example.omarock.bridge   # your bundle ID: forgets its permissions
apple-bridge/app/build.sh --uninstall          # unregisters and stops it, removes the app
rm -rf ~/Library/Application\ Support/omarock-bridge
```

`tccutil` finds the app by its bundle ID, so run it before the app is removed.

On the Omarchy machine, **Remove…** on the Apple Music tab of omarock's settings (or
`./install --remove apple-music`) deletes the bridge's address and token there,
and the patched builds for its stream.

## Limits

- Apple's API can add to your library and your playlists, and create playlists, but
  can't take anything out of the library, remove songs or delete playlists. Smart
  playlists are read-only.
- One Mac plays for one omarock at a time: the Mac has one Apple Music queue.
- Library lists come from the Mac's music library, read every 5 minutes, and again a
  few times in the minutes after an add. Adds reach it only while the Music app runs
  (above).

## The code

- `app/`: the bridge app (Swift, XcodeGen). `Sources/API.swift` routes [API.md](API.md);
  `Player.swift` is MusicKit's player and the status long poll; `StreamService.swift` is
  the tap, the encoder (`FlacEncoder.swift`, which is also Icecast's source) and Icecast; `LibraryIndex.swift` reads the library through
  iTunesLibrary, which is much faster than MusicKit's library requests on macOS.
- `flac/`: libFLAC 1.5.0's encoder, from [xiph/flac](https://github.com/xiph/flac)
  (BSD, `flac/COPYING.Xiph`), built into the app; `flac/README.md` says what's there.
- `tap/`: `ProcessTap`, the Core Audio process tap library the app uses, and
  `omarock-tap`, a test tool that streams any one process's or app's audio
  (`tap/build.sh`).
