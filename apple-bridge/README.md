# omarock bridge (macOS)

Apple Music for omarock. Apple Music's streams are DRM-protected, so nothing on Linux
can play them. The bridge is a small Mac app that plays Apple Music with Apple's
MusicKit and streams the sound to your Linux machine, where **mpd** plays it like any
other stream. omarock talks to the bridge for search, browsing, the queue and the
transport ([API.md](API.md)).

```
Mac:   MusicKit plays ─▶ process tap (muted on the Mac) ─▶ Ogg FLAC, libFLAC ─▶ Icecast :8000
                                                                                    │ your network
Linux: omarock ◀──── bridge API :8710 (JSON, bearer token) ────────────────────────┤
       mpd ◀──────── http://<mac>:8000/omarock-<secret>.ogg ◀───────────────────────┘
```

- **Only the bridge's own playback is captured.** The Mac's default output, its volume
  and every other app's sound are left alone, and the bridge's playback is muted on the
  Mac, so the Mac can be your everyday machine.
- **Any network, and nothing encrypted.** The API and the stream listen on every
  network the Mac is on: your home network, Tailscale's if it runs, and a café's Wi-Fi
  too when the Mac is a laptop there. It's plain HTTP, so the token, the replies and
  the sound cross the network as they are. Securing the network is up to you;
  [Tailscale](https://tailscale.com) is one way (it encrypts, and works away from home
  too), and `listenHost` (below) keeps the bridge to one address, Tailscale's, say.
- **The token.** Every API request needs it, except `/v1/health` (the bridge's version
  and state) and cover art (each image's address carries a key made from the token).
  The stream's address has a secret made from the token in it, which `/v1/health`
  gives only with the token, so only omarock finds the stream. Your Omarchy machine
  gets the token by **pairing**: the Mac shows a 6-digit code, and you type it into
  omarock there.
- **It runs in the background:** no Dock icon, started at login, restarted if it
  crashes. With nobody listening to the stream for 30 s, it pauses.

You build it yourself, because it has to be signed with your own Apple Developer
account for MusicKit to work.

## Before you start

Most of the work is on Apple's side, and it is best done before you run the installer.
Set aside an hour the first time: Xcode is a large download, and a new developer
membership can take a day or two to be approved. With all of this in place, `./install`
takes about 15 minutes.

Do them in this order:

1. **An Apple silicon Mac with macOS 15 or later.** The bridge itself needs macOS 14.2
   (Core Audio process taps), but Homebrew, which the installer uses, supports only
   Apple silicon on macOS 15 and later: since September 2026 Intel Macs and macOS 14
   are its Tier 3, "not supported" ([docs.brew.sh/Support-Tiers](https://docs.brew.sh/Support-Tiers)).
   Developed on macOS 27.
2. **A paid Apple Developer Program membership** ($99 a year), approved. Enroll at
   [developer.apple.com/programs](https://developer.apple.com/programs/). A free Apple
   developer account isn't enough: MusicKit needs the paid membership.
3. **Xcode**, from the App Store, opened once: it asks you to agree to its license, and
   installs its components. Apple's command-line tools alone aren't enough. Xcode also
   gives you `git`, for the clone.
4. **Your developer Apple ID in Xcode:** Xcode → Settings → Accounts → **+** → Apple ID.
   You make a signing certificate there (step 1, below).
5. **[Homebrew](https://brew.sh)**, installed as its page says. The installer gets
   `gum`, `xcodegen` and `icecast` from it.
6. **An Apple Music subscription** on the Apple ID the Mac's Music app uses.
7. **The Mac and the Linux machine on one network:** your home network, or both on
   Tailscale. Omarchy finds the bridge on your network by itself (Bonjour).
8. **On Linux:** omarock with mpd, as in the [main README](../README.md).

### What Apple's steps are for

Apple lets an app use MusicKit only when it can tell which paid developer the app
belongs to. So you set up three things with Apple, and they must all belong to the
same team:

- **Your team.** A membership is a team, with a **Team ID**: 10 letters and digits,
  under Membership details on developer.apple.com. Xcode also lists a "(Personal
  Team)" for any Apple ID. That's the free kind, and MusicKit doesn't work with it.
- **An Apple Development certificate:** your signing identity. Xcode makes it, and it's
  kept in your login keychain. macOS trusts it through a chain: Apple's Worldwide
  Developer Relations certificate signed yours, and Apple's root certificate signed
  that one. Xcode usually adds that middle certificate. When it hasn't, yours is
  there but not trusted, and nothing can be signed with it.
- **A bundle ID:** the app's name to Apple, such as `com.yourname.omarock.bridge`. You
  register it on developer.apple.com and switch MusicKit on for it there (step 1). The
  bridge is built with it, and MusicKit works only for a bundle ID that has it on.

After the build, the Mac itself asks a few questions (below, "The Mac's questions").
Those are between you and macOS.

## 1. A bundle ID with MusicKit

1. At [developer.apple.com/account](https://developer.apple.com/account), open
   **Certificates, Identifiers & Profiles → Identifiers**, then **+** and **App IDs**
   (type App).
2. Give it a description and an explicit **bundle ID** of your own, such as
   `com.example.omarock.bridge`.
3. Register it, open it again (the Identifiers list shows your bundle ID in its
   **Identifier** column), and on the **App Services** tab check **MusicKit**. Save.
4. Note your **Team ID** (Account → Membership details: 10 letters and digits).

Apple can take a few minutes before MusicKit answers for a new bundle ID; until then
catalog requests come back empty.

You also need an **Apple Development** signing certificate. In Xcode:

1. Settings → **Accounts**, and your developer Apple ID (**+** adds it if it isn't there).
2. On the right, pick your team: your name, or your company's. Not the one marked
   "(Personal Team)".
3. **Manage Certificates…**, then **+** → **Apple Development**, and **Done**.

`./install` waits for the certificate, so you can also make it while it waits.

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
through the Mac's permissions and its network with you (the firewall, if it's on). It
ends with what your Omarchy machine needs: this Mac's name on your network
(`NAME.local`), and on Tailscale if it runs, and then a pairing code for it (below).
Every command it runs is shown, and it asks before changing anything.

Run it again whenever you like. What's done is checked and skipped. The bridge is
rebuilt only if this checkout's code has changed since the installed build, and only
once nothing is listening to the stream.

### The Mac's questions

The first time the bridge runs, the Mac asks three things. Allow them (`./install` waits
for them, and offers to open System Settings):
- **Apple Music access** ("OmarockBridge would like to access Apple Music…").
- **Audio capture**, for its own playback. If you miss the prompt, switch it on in
  System Settings → Privacy & Security → Screen & System Audio Recording (the "System
  Audio Recording Only" list).
- **Local Network access** (omarock bridge, "find devices on local networks"), so the
  bridge can announce itself and your Omarchy machine finds it by itself. Without it
  the bridge still works, but omarock needs the Mac's name typed in. If you turned it
  down, switch omarock bridge on in System Settings → Privacy & Security → Local Network.

**The firewall.** If macOS's firewall is on, `./install` offers to let the bridge (port
8710) and Icecast (port 8000) through (`sudo socketfilterfw`). Homebrew's Icecast changes
with each upgrade, so run `./install` again after `brew upgrade icecast`. With "Block all
incoming connections" on, nothing gets through: switch that off first.

If macOS says the login item needs approval, allow OmarockBridge in System Settings →
General → Login Items.

### Pairing

The installer's last step pairs your Omarchy machine with the bridge, so it gets the
bridge's token without your copying anything across. It asks "Show a pairing code for
your Omarchy machine?", then shows a 6-digit code, such as `048 213`. On your Omarchy
machine, type it into omarock's Apple Music setup (part 3, below). The installer waits,
and says "✓ paired with" that machine's name once it's done.

The code works once, within 10 minutes, and 5 wrong tries close it. That keeps anyone
else on your network from guessing it while it's open.

For a new code at any time (another Omarchy machine, say, or after a reinstalled bridge
made a new token), run `./install pair` in the Mac's omarock folder. It does only this
step.

### If the installer stops

At each step the installer waits until what it needs is there, checking every few
seconds, so you can fix things while it waits. If you stop it (Ctrl-C), run `./install`
again: what's done is skipped. What it says, in the order you'd meet it, and what to do:

- **"The installer needs Homebrew"** or **"Homebrew isn't here":** install Homebrew as
  [brew.sh](https://brew.sh) says, then run `./install` again. On an Intel Mac, or
  macOS 14 or older, the installer stops and says why: Homebrew doesn't support them.
- **"Xcode is here, but the command-line tools are selected instead":** Homebrew's
  installer adds Apple's command-line tools, and they can end up selected instead of
  Xcode. Say yes, and it selects Xcode (`sudo xcode-select`).
- **"Waiting for Xcode…":** Xcode hasn't been opened since it was installed. Open it,
  agree to its license, and let it install its components.
- **"Waiting for the certificate…":** make your Apple Development certificate in Xcode
  (step 1, above). It doesn't matter whether you make it before or while it waits.
- **"your Apple Development certificate is there, but macOS doesn't trust it":** Apple's
  middle certificate is missing from your keychain (above, "What Apple's steps are
  for"). Here `security find-identity -p codesigning` lists your certificate, but with
  `-v` it finds 0 valid identities. Say yes, and the installer fetches the right one
  from Apple and adds it to your login keychain. By hand:
  1. In Keychain Access, open login → My Certificates → your Apple Development
     certificate. Its issuer's Organizational Unit says which one signed it: G3 to G6.
  2. Download that Worldwide Developer Relations certificate from
     [apple.com/certificateauthority](https://www.apple.com/certificateauthority/)
     (`AppleWWDRCAG3.cer`, say).
  3. In Keychain Access, choose File → Import Items, into the login keychain.
     Double-clicking the file can fail with error -25294, which means it went to a
     keychain that can't take it.

  Don't set your own certificate to Always Trust: that hides the problem, and doesn't
  fix it.
- **"Your Team ID":** the installer suggests your certificate's team. It must be the
  team your bundle ID is registered to.
- **"Your bundle ID":** type it exactly as the Identifiers list's **Identifier** column
  shows it.
- **"the build didn't finish":** the installer shows Xcode's errors, and the whole build
  is in `apple-bridge/app/build/build.log`. For a signing error, check your Team ID and
  bundle ID. They're in `apple-bridge/app/Local.xcconfig`; delete that file, and
  `./install` asks for both again.
- **"Waiting for the bridge…"**, then **"the bridge doesn't answer":** `bridge.log` says
  why (below, "What it keeps where"), and see Troubleshooting.
- **"Waiting for the login item…"**, **"Waiting for Apple Music access…"**, **"Waiting
  for audio capture…"** or **"Waiting for Local Network access…":** there's a question
  on the Mac's screen, maybe behind the terminal (above, "The Mac's questions"). Ctrl-C
  skips one, and the next run checks it again.
- **"MusicKit says this Mac can't play Apple Music's catalog":** check that the Music
  app is signed in to an Apple ID with an Apple Music subscription, and that MusicKit is
  checked for your bundle ID on developer.apple.com. A new bundle ID can take a few
  minutes.
- **"Waiting for your Omarchy machine…":** type the code into omarock's Apple Music
  setup there (above, "Pairing"). Ctrl-C closes the code.
- **"the code expired"**, **"the code was closed after 5 wrong tries"** or **"the code
  is closed":** `./install pair` opens a new one.
- From `./install pair`: **"the bridge isn't installed on this Mac"**, or **"the bridge
  here (0.9.0) is too old to pair":** run `./install` first, which sets the bridge up or
  updates it.

### Keep the Mac awake

The bridge keeps the Mac awake only while it plays. A Mac that sleeps, a laptop with its
lid closed or idle on battery, takes the bridge with it: omarock says the bridge didn't
answer until the Mac wakes. For a Mac that serves omarock, keep it on power and switch on
System Settings → Battery → Options → **Prevent automatic sleeping on power adapter when
the display is off** (on a desktop Mac: System Settings → Energy).

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

Check it from the Mac or Linux (`/v1/health` needs no token; its `"bonjour"` says
whether the bridge announces itself: `advertised`, or `denied` without Local Network
access):

```sh
curl http://my-mac.local:8710/v1/health   # your Mac's name, or its Tailscale address
```

`authorized`, `canPlayCatalog`, `capturing` and `encoding` should all be `true`.

### What it keeps where

Everything lives in `~/Library/Application Support/omarock-bridge`, not in the repo:

| File | What it is |
| --- | --- |
| `token` | The API token omarock sends (made on first run). |
| `source.password`, `admin.password`, `relay.password` | Icecast's passwords (made on first run). |
| `icecast.xml` | Icecast's config, rewritten at each launch. Delete its first comment line to keep your own edits. |
| `config.json` | Optional settings (below). |
| `INSTALLED` | The commit the installed app was built from. |
| `log/` | `bridge.log`, `encoder.log` (the stream's encoder), and Icecast's `error.log` and `access.log`. |

`config.json`, every field optional:

```jsonc
{ "listenHost": "100.64.0.10",   // only this address and loopback, and no Bonjour
                                 // (default: every address the Mac has)
  "port": 8710,                  // the API's port (Icecast's is 8000)
  "streamURL": "http://…:8000/live.ogg",  // what /health hands out (default: the secret one)
  "icecast": "/opt/homebrew/bin/icecast",
  "startAtLogin": true }         // false: no launch agent; run the app by hand
```

### Updating

```sh
git pull && ./install
```

or `git pull && apple-bridge/app/build.sh --run`. Both wait until nothing is listening to the
stream, because restarting the bridge under mpd gives mpd errors until it's back.
`build.sh --run-now` restarts right away.

## 3. The Linux side

On your Omarchy machine, **Set up…** on the Apple Music tab of omarock's settings (`,`
in the panel), or `./install apple-music` in your clone there, connects to the bridge.
Its window lists the bridges it finds on your network, and the Macs among your Tailscale
machines, with a Mac's Tailscale address first, and checks that the bridge answers. Then
type the pairing code the Mac shows (above, "Pairing"): the window pairs as soon as it
has all 6 digits, and the token goes straight into `~/.config/omarock/bridge-token`.
`./install apple-music` asks for the code the same way.

By hand instead, from your omarock clone:

```sh
mkdir -p ~/.config/omarock
echo '{ "bridge": "http://my-mac.local:8710" }' > ~/.config/omarock/apple.json
echo 048213 | tools/omarock-account bridge-pair http://my-mac.local:8710   # the Mac's code
```

Or copy the token file across yourself: it's
`~/Library/Application Support/omarock-bridge/token` on the Mac (`build.sh` prints an
`scp` line for it), and goes in `~/.config/omarock/bridge-token`, mode 600. The stream's
address comes from the bridge once the token is in (omarock asks for it).

Then switch Apple Music on in omarock's settings (`,` in the panel). A reinstalled
bridge makes a new token: the old one is refused, and the Apple Music tab is marked •
until omarock pairs again (hover over the tab for why). Run `./install pair` on the
Mac, and type its code into **Pair with the bridge** on that tab. If the Mac's
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

For smooth playback, the setup window's switch (on to start) builds a patched mpd-mpris
on the Linux side; [patches/README.md](../patches/README.md) says what it fixes. Arch's own
libFLAC keeps up with the stream from bridge 0.7.0; a patched libFLAC built for an older
bridge can go (`./install apple-music` offers to remove it). `tools/omarock-doctor`
checks the Linux side: `apple.json`, the token file, the bridge's `/v1/health`, and
whether the bridge is new enough.

## Troubleshooting

For what `./install` says while it sets the bridge up, see
[If the installer stops](#if-the-installer-stops).

- **The build fails** (`build.sh`, or an update): it shows the errors from its log; the
  whole build is in `apple-bridge/app/build/build.log`. A signing error after the
  certificate worked before: check it in Xcode → Settings → Accounts → Manage
  Certificates (they expire after a year).
- **`authorized: false`:** allow the bridge in System Settings → Privacy & Security →
  Media & Apple Music, or ask again from Linux with `tools/omarock-am authorize` in
  your omarock clone (the dialog shows on the Mac). It gives curl the token on stdin:
  on a command line (`curl -H "Authorization: Bearer …"`), any account on the machine
  could read it while curl runs.
- **`canPlayCatalog: false`, or catalog searches fail:** check the Apple Music
  subscription, that MusicKit is checked for the bundle ID in `Local.xcconfig`
  (Identifiers, on developer.apple.com), and give a new bundle ID a few minutes.
- **`capturing: false`, or the stream is silent:** the audio capture permission (above).
  It belongs to the app's code signature, so building with another identity or bundle
  ID asks again.
- **Nothing answers on :8710:** is the Mac asleep? A sleeping Mac may still answer
  `ping`, slowly, while the bridge doesn't (above, "Keep the Mac awake"). From Linux,
  `avahi-browse -rt _omarock._tcp` lists the bridges on your network. A bridge older
  than 0.9.0 listens only on the Mac's Tailscale address: update it (`git pull`, then
  `./install`, in the Mac's clone). On the Mac, check
  `launchctl print gui/$UID/<your bundle ID>`; `bridge.log`'s `login:` lines
  say what it did about its launch agent: since 0.5.1, if macOS lists the agent but
  launchd hasn't got it (left by an uninstall of 0.5.0 or older), the bridge registers it
  again, or runs without it. With 0.5.0 or older, switch OmarockBridge off and on in
  System Settings → General → Login Items & Extensions (App Background Activity).
- **mpd far behind live:** update the bridge to 0.7.0 or later (`git pull`, then
  `./install`, in the Mac's clone). Older bridges' streams made mpd fall behind.
- **omarock says the bridge refused its token:** a reinstalled bridge has a new one.
  Pair again: `./install pair` on the Mac, then its code in **Pair with the bridge** on
  omarock's Apple Music tab.
- **On Linux,** run `tools/omarock-doctor`.
- **Another Icecast on port 8000** (`"icecast": "taken"` in the bridge's health, and a
  Fix in omarock's settings): the bridge talks only to its own Icecast, so it sends the
  other one nothing and waits for the port. Stop the other server, or move it. The
  bridge's own Icecast serves only the stream: its status pages answer 404.
- **Logs:** `~/Library/Application Support/omarock-bridge/log/`.

## Uninstalling

```sh
./install --uninstall
```

Each part is its own step, and asks first. It takes the bridge out of macOS's login
items (`OmarockBridge --unregister`), stops it and its Icecast, removes
`~/Applications/OmarockBridge.app`, and offers to make macOS forget
the app's permissions, and to take the firewall entries it added out again. It also
offers to delete the support folder (the token, the
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
