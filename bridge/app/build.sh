#!/bin/zsh
# Builds the omarock bridge from this checkout, signed with your Apple Development
# identity (a stable signature keeps its audio capture and Apple Music permissions across
# rebuilds), and installs it. See bridge/README.md.
#   bridge/app/build.sh              # check, build, set up; the first run asks for your Team ID
#   bridge/app/build.sh --run        # ... then install to ~/Applications and (re)start it,
#                                    # once nobody is listening (a restart under mpd gives it 404s)
#   bridge/app/build.sh --run-now    # the same, without waiting for listeners to leave
#   bridge/app/build.sh --uninstall  # stop it and remove the app (keeps your settings)
# OMAROCK_TEAM_ID and OMAROCK_BUNDLE_ID answer the first run's questions without asking.
set -euo pipefail
cd ${0:A:h}
mode=${1:-}
support=~/Library/Application\ Support/omarock-bridge
app=~/Applications/OmarockBridge.app

bundle_id() { sed -n 's/^OMAROCK_BUNDLE_ID *= *//p' Local.xcconfig 2>/dev/null | tail -1; }
# The bundle id of the app installed in ~/Applications, if any.
installed_id() { /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true; }

# Listeners on the bridge's Icecast mount, from its admin stats (0 if Icecast isn't up).
listeners() {
  local conf=$support/icecast.xml user pass
  [[ -f $conf ]] || { print 0; return; }
  user=$(sed -n 's:.*<admin-user>\(.*\)</admin-user>.*:\1:p' $conf)
  pass=$(sed -n 's:.*<admin-password>\(.*\)</admin-password>.*:\1:p' $conf)
  curl -s -m 5 -K - 'http://127.0.0.1:8000/admin/listclients?mount=/omarock.ogg' <<<"user = \"$user:$pass\"" \
    | sed -n 's:.*<Listeners>\([0-9]*\)</Listeners>.*:\1:p' | head -1
}

# Stops the running bridge (and so its Icecast); true if the launch agent ran it.
stop_bridge() {
  local label=$1
  if launchctl print gui/$UID/$label >/dev/null 2>&1; then
    # Stop it cleanly, so KeepAlive (restarts after a crash only) leaves it stopped.
    launchctl kill TERM gui/$UID/$label || true
    for i in {1..50}; do pgrep -x OmarockBridge >/dev/null || break; sleep 0.1; done
    return 0
  fi
  # A copy opened by hand, from the installed app only (never another bridge).
  pkill -TERM -f "^$app/Contents/MacOS/OmarockBridge" && sleep 2 || true
  return 1
}

if [[ $mode == --uninstall ]]; then
  label=${$(bundle_id):-org.omarock.bridge}
  if [[ -d $app && $(installed_id) != $label ]]; then
    print "$app is $(installed_id), not $label (this checkout's Local.xcconfig); leaving it alone."
    exit 1
  fi
  stop_bridge $label || true
  launchctl bootout gui/$UID/$label 2>/dev/null || true
  rm -rf "$app"
  print "Removed $app."
  print "Your token, passwords, logs and settings are in $support; delete that folder to remove them too."
  print "Its permissions: System Settings → Privacy & Security → Screen & System Audio Recording, and Media & Apple Music."
  exit 0
fi

# 1. Prerequisites
problems=()
major=$(sw_vers -productVersion | cut -d. -f1); minor=$(sw_vers -productVersion | cut -d. -f2)
(( major > 14 || (major == 14 && minor >= 2) )) || problems+="macOS 14.2 or later (this is $(sw_vers -productVersion))"
xcodebuild -version >/dev/null 2>&1 \
  || problems+="Xcode, from the App Store, selected with: sudo xcode-select -s /Applications/Xcode.app"
for tool in xcodegen ffmpeg icecast; do
  command -v $tool >/dev/null || problems+="$tool: brew install $tool"
done
security find-identity -v -p codesigning 2>/dev/null | grep -q '"Apple Development' \
  || problems+="an Apple Development certificate: Xcode → Settings → Accounts → your team → Manage Certificates → +"
ifconfig | grep -qE 'inet 100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' \
  || problems+="Tailscale, running and logged in (no 100.64.0.0/10 address on this Mac)"
if (( ${#problems} )); then
  print "The bridge needs:"
  for p in $problems; print "  - $p"
  exit 1
fi

# 2. Your settings (Local.xcconfig, not in git)
if [[ ! -f Local.xcconfig ]]; then
  team=${OMAROCK_TEAM_ID:-}
  bundle=${OMAROCK_BUNDLE_ID:-}
  if [[ -z $team && ! -t 0 ]]; then
    print "No Team ID: run this in a terminal, or set OMAROCK_TEAM_ID (and OMAROCK_BUNDLE_ID)."
    exit 1
  fi
  if [[ -z $team ]]; then
    print "Your Apple Developer Team ID: 10 characters, at developer.apple.com → Account → Membership details."
    read -r "team?Team ID: " || true
  fi
  [[ $team =~ '^[A-Z0-9]{10}$' ]] || { print "That isn't a Team ID (10 letters and digits)."; exit 1; }
  if [[ -z $bundle && -t 0 ]]; then
    print "The bundle id of your App ID with MusicKit (see bridge/README.md)."
    read -r "bundle?Bundle id [org.omarock.bridge]: " || true
  fi
  bundle=${bundle:-org.omarock.bridge}
  [[ $bundle =~ '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' ]] || { print "That isn't a bundle id (like com.example.omarock.bridge)."; exit 1; }
  print "DEVELOPMENT_TEAM = $team\nOMAROCK_BUNDLE_ID = $bundle" >Local.xcconfig
  print "Wrote ${0:A:h}/Local.xcconfig (edit it to change these)."
fi
label=$(bundle_id)

# 3. Build and sign
xcodegen generate --quiet
xcodebuild -project OmarockBridge.xcodeproj -scheme OmarockBridge -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build -quiet build
built=$PWD/build/Build/Products/Release/OmarockBridge.app
codesign -dv "$built" 2>&1 | grep -E '^(Identifier|TeamIdentifier)='

# 4. Token, Icecast's passwords and config, and the addresses
info=$("$built/Contents/MacOS/OmarockBridge" --setup)
field() { sed -n "s/^ *\"$1\" *: *\"\(.*\)\".*/\1/p" <<<"$info"; }

if [[ $mode == --run ]]; then
  while (( ${$(listeners):-0} > 0 )); do
    print "The stream has a listener (mpd); waiting for it to leave (or use --run-now)."
    sleep 30
  done
fi

# 5. Install and start
if [[ $mode == --run || $mode == --run-now ]]; then
  previous=$(installed_id)
  if [[ -n $previous && $previous != $label ]]; then
    # One bridge per Mac: the one installed under another bundle id goes.
    print "Replacing $app ($previous) with $label."
    stop_bridge $previous || true
    launchctl bootout gui/$UID/$previous 2>/dev/null || true
  fi
  if stop_bridge $label; then
    mkdir -p ~/Applications && rm -rf "$app" && ditto "$built" "$app"
    launchctl kickstart gui/$UID/$label
  else
    mkdir -p ~/Applications && rm -rf "$app" && ditto "$built" "$app"
    # Opened through LaunchServices: it registers its launch agent and hands over to it.
    open "$app"
  fi
  print "Installed $app."
else
  print "Built $built (install it with --run)."
fi

cat <<EOF

On the Linux machine (omarock):
  mkdir -p ~/.config/omarock
  echo '{ "bridge": "$(field bridge)", "stream": "$(field stream)" }' > ~/.config/omarock/apple.json
  scp $(whoami)@$(field bridge | sed -E 's#^https?://##; s#:[0-9]+$##'):'$(field token)' ~/.config/omarock/bridge-token
  chmod 600 ~/.config/omarock/bridge-token
(or copy that file by hand), then switch on "Apple Music" in omarock's settings. The first time the bridge runs, the
Mac asks for Apple Music access and for audio capture: allow both.
EOF
