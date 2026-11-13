#!/bin/zsh
# Builds the omarock bridge from this checkout, signed with your Apple Development
# identity (a stable signature keeps its audio capture and Apple Music permissions across
# rebuilds), and installs it. See apple-bridge/README.md.
#   apple-bridge/app/build.sh              # check, build, set up; the first run asks for your Team ID
#   apple-bridge/app/build.sh --run        # ... then install to ~/Applications and (re)start it,
#                                    # once nobody is listening (a restart under mpd gives it 404s)
#   apple-bridge/app/build.sh --run-now    # the same, without waiting for listeners to leave
#   apple-bridge/app/build.sh --uninstall  # stop it and remove the app (keeps your settings)
# OMAROCK_TEAM_ID and OMAROCK_BUNDLE_ID answer the first run's questions without asking.
set -euo pipefail
cd ${0:A:h}
mode=${1:-}
support=${OMAROCK_BRIDGE_SUPPORT:-$HOME/Library/Application Support/omarock-bridge}
app=~/Applications/OmarockBridge.app

bundle_id() { sed -n 's/^OMAROCK_BUNDLE_ID *= *//p' Local.xcconfig 2>/dev/null | tail -1; }
# The bundle ID of the app installed in ~/Applications, if any.
installed_id() { /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true; }

if [[ -t 1 ]]; then green=$'\e[32m' red=$'\e[31m' reset=$'\e[0m'; else green= red= reset=; fi
# Minutes and seconds since $1 (a $SECONDS).
clock() { local s=$(( SECONDS - $1 )); printf '%d:%02d' $(( s / 60 )) $(( s % 60 )); }
# Runs a long command with its output in a log: on a terminal, a spinner and a clock
# until it ends. Ctrl-C stops the command too. Returns its status.
timed() {
  local title=$1 log=$2 start=$SECONDS pid st=0 i=0
  local -a frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  shift 2
  "$@" >$log 2>&1 &
  pid=$!
  trap "pkill -TERM -P $pid 2>/dev/null; kill $pid 2>/dev/null; print; exit 130" INT TERM
  if [[ -t 1 ]]; then
    while kill -0 $pid 2>/dev/null; do
      (( i = i % 10 + 1 ))
      printf '\r  %s %s %s ' $frames[i] $title $(clock $start)
      sleep 0.1
    done
    printf '\r\e[K'
  else
    print "  $title"
  fi
  wait $pid || st=$?
  trap - INT TERM
  return $st
}

# Listeners on the stream, as the running bridge counts them (its /v1/health, from 0.13.0,
# which tells this Mac). Nothing if it can't tell: no bridge, an older one, or its Icecast
# isn't up. Never Icecast's admin password: whatever holds 127.0.0.1:8000 would get it.
# Health by the bridge's control socket (0.14.0), which only this account can answer on,
# or else by TCP, which asks nothing secret.
bridge_health() {
  local sock=$support/api.sock
  [[ -S $sock && -O $sock ]] && curl -s -m 5 --unix-socket "$sock" http://localhost/v1/health 2>/dev/null ||
    curl -s -m 5 "http://127.0.0.1:${$(plutil -extract port raw -o - "$support/config.json" 2>/dev/null || true):-8710}/v1/health" 2>/dev/null ||
    true
}
listeners() { bridge_health | plutil -extract listeners raw -o - - 2>/dev/null || true; }

# Forgets the installed app's launch agent through SMAppService, which stops it too: a
# bootout alone leaves SMAppService's record enabled, and the next install's bridge then
# hands over to a job launchd doesn't have. Apps before 0.5.1 don't know --unregister.
unregister_agent() {
  local version
  version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null) || return 0
  autoload -Uz is-at-least
  is-at-least 0.5.1 $version && "$app/Contents/MacOS/OmarockBridge" --unregister || true
}

# launchd's state for a job ("running", "not running"), empty if it has no such job.
job_state() { launchctl print gui/$UID/$1 2>/dev/null | sed -n $'s/^\tstate = //p'; }

# Starts the launch agent's job and waits for launchd to run it, asking once more if not.
start_agent() {
  local try i
  for try in 1 2; do
    launchctl kickstart gui/$UID/$1 || true
    for i in {1..30}; do [[ $(job_state $1) == running ]] && return 0; sleep 0.1; done
  done
  print "  ${red}✗${reset} launchd didn't start it: try launchctl kickstart gui/\$UID/$1"
}

# Stops the running bridge (and so its Icecast); true if the launch agent ran it.
stop_bridge() {
  local label=$1
  if launchctl print gui/$UID/$label >/dev/null 2>&1; then
    # Stop it cleanly, so KeepAlive (restarts after a crash only) leaves it stopped. Then
    # wait for launchd, not only the process: until launchd has seen it exit, a kickstart
    # does nothing, and the new build never starts.
    launchctl kill TERM gui/$UID/$label || true
    for i in {1..100}; do [[ $(job_state $label) == running ]] || break; sleep 0.1; done
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
  unregister_agent
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
for tool in xcodegen icecast; do
  command -v $tool >/dev/null || problems+="$tool: brew install $tool"
done
security find-identity -v -p codesigning 2>/dev/null | grep -q '"Apple Development' \
  || problems+="an Apple Development certificate: Xcode → Settings → Accounts → your team → Manage Certificates → +"
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
    print "Your bundle ID, registered with MusicKit (see apple-bridge/README.md)."
    read -r "bundle?Bundle ID [org.omarock.bridge]: " || true
  fi
  bundle=${bundle:-org.omarock.bridge}
  [[ $bundle =~ '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' ]] || { print "That isn't a bundle ID (like com.example.omarock.bridge)."; exit 1; }
  print "DEVELOPMENT_TEAM = $team\nOMAROCK_BUNDLE_ID = $bundle" >Local.xcconfig
  print "Wrote ${0:A:h}/Local.xcconfig (edit it to change these)."
fi
label=$(bundle_id)

# 3. Build and sign
compile() {
  xcodegen generate --quiet &&
    xcodebuild -project OmarockBridge.xcodeproj -scheme OmarockBridge -configuration Release \
      -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build build
}
mkdir -p build
log=$PWD/build/build.log
start=$SECONDS
if ! timed "Building the bridge…" $log compile; then
  print "  ${red}✗${reset} the build failed after $(clock $start). From its log, ${log/#$HOME/~}:"
  errors=$(grep -E '(^|: )(fatal )?error: ' $log | awk '!seen[$0]++' | head -20 || true)
  print -r -- "${errors:-$(tail -20 $log)}" | sed 's/^/    /'
  exit 1
fi
built=$PWD/build/Build/Products/Release/OmarockBridge.app
signed=$(codesign -dv "$built" 2>&1 || true)
print "  ${green}✓${reset} built in $(clock $start), signed as $(sed -n 's/^Identifier=//p' <<<$signed)" \
  "(team $(sed -n 's/^TeamIdentifier=//p' <<<$signed))"

# 4. Token, Icecast's passwords and config, and the bridge's address
info=$("$built/Contents/MacOS/OmarockBridge" --setup)
field() { sed -n "s/^ *\"$1\" *: *\"\(.*\)\".*/\1/p" <<<"$info"; }

if [[ $mode == --run ]]; then
  count=$(listeners)
  [[ -z $count && -n $(bridge_health) ]] &&
    print "  The bridge doesn't say whether anything is listening to the stream (before 0.13.0 it can't); restarting it now."
  while (( ${count:-0} > 0 )); do
    print "  The stream has a listener (mpd); waiting for it to leave (or use --run-now)."
    sleep 30
    count=$(listeners)
  done
fi

# 5. Install and start
if [[ $mode == --run || $mode == --run-now ]]; then
  previous=$(installed_id)
  if [[ -n $previous && $previous != $label ]]; then
    # One bridge per Mac: the one installed under another bundle ID goes.
    print "  Replacing ${app/#$HOME/~} ($previous) with $label."
    unregister_agent
    stop_bridge $previous || true
    launchctl bootout gui/$UID/$previous 2>/dev/null || true
  fi
  # Copied in beside the installed app first, then swapped in with two renames, so there's
  # never a half-copied app at $app for macOS to open (and call damaged).
  mkdir -p ~/Applications
  stage=$(mktemp -d ~/Applications/.OmarockBridge.XXXXXX)
  trap 'rm -rf "$stage"' EXIT
  ditto "$built" "$stage/OmarockBridge.app"
  swap_in() {
    [[ -e $app ]] && mv "$app" "$stage/old.app"
    mv "$stage/OmarockBridge.app" "$app"
  }
  if stop_bridge $label; then
    swap_in
    start_agent $label
  else
    swap_in
    # Opened through LaunchServices: it registers its launch agent and hands over to it.
    open "$app"
  fi
  # The commit it was built from, so ../install rebuilds only when the bridge changes.
  mkdir -p "$support" && git rev-parse HEAD >"$support/INSTALLED"
  [[ -n ${OMAROCK_FROM_INSTALL:-} ]] || print "  ${green}✓${reset} installed ${app/#$HOME/~} and started it"
else
  print "  Install it with --run."
fi

# apple-bridge/install shows the next steps itself.
[[ -n ${OMAROCK_FROM_INSTALL:-} ]] && exit 0

cat <<EOF

On the Linux machine (omarock):
  mkdir -p ~/.config/omarock
  echo '{ "bridge": "$(field bridge)" }' > ~/.config/omarock/apple.json
  scp $(whoami)@$(field bridge | sed -E 's#^https?://##; s#:[0-9]+$##'):'$(field token)' ~/.config/omarock/bridge-token
  chmod 600 ~/.config/omarock/bridge-token
(or copy the token file by hand), then switch Apple Music on in omarock's settings. The first time the bridge runs, the Mac asks for
Apple Music access, audio capture and Local Network access: allow all three.
EOF
