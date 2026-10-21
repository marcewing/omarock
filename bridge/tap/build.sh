#!/bin/zsh
# Build omarock-tap, a test tool that streams one process's or app's audio, and sign it
# with your Apple Development identity, so the audio capture permission (granted to this
# code signature) survives rebuilds. The bridge app doesn't need it.
#   SIGN_IDENTITY="Apple Development: …" TAP_BUNDLE_ID=com.example.omarock.tap bridge/tap/build.sh
set -euo pipefail
cd ${0:A:h}
swift build -c release
codesign --force --sign "${SIGN_IDENTITY:-Apple Development}" --identifier "${TAP_BUNDLE_ID:-org.omarock.tap}" \
  .build/release/omarock-tap
codesign -dv .build/release/omarock-tap 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier)='
