#!/bin/zsh
# One-step local install: checks requirements, creates a local signing identity
# (so macOS remembers permissions across updates), builds, installs and opens the app.
#
#   ./scripts/install.sh            install or update
#   ./scripts/install.sh --no-open  do not launch after install
#
# Nothing is downloaded: the app is built from this folder with Apple's own toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Offrecord"
IDENTITY_NAME="Offrecord Local"
OPEN_AFTER=1
[[ "${1:-}" == "--no-open" ]] && OPEN_AFTER=0

bold() { print -P "%B$1%b"; }
fail() { print -P "%F{red}✗%f $1"; exit 1; }
ok()   { print -P "%F{green}✓%f $1"; }

bold "Checking requirements"

macos_major=$(sw_vers -productVersion | cut -d. -f1)
(( macos_major >= 26 )) || fail "macOS 26 or later is required (found $(sw_vers -productVersion))."
ok "macOS $(sw_vers -productVersion)"

[[ "$(uname -m)" == "arm64" ]] || fail "An Apple silicon Mac (M1 or later) is required."
ok "Apple silicon"

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  print "Apple's command line tools are missing. Opening the installer…"
  xcode-select --install 2>/dev/null || true
  fail "Finish the Command Line Tools install, then run this script again."
fi
sdk_major=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1)
(( ${sdk_major:-0} >= 26 )) || fail "macOS 26 SDK required (found ${sdk_major:-none}). Update Xcode or run: softwareupdate --list"
ok "Swift $(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -1), SDK $(xcrun --sdk macosx --show-sdk-version)"

bold "Signing identity"
if security find-identity -p codesigning | grep -q "$IDENTITY_NAME"; then
  ok "Using existing '$IDENTITY_NAME'"
else
  print "Creating a self-signed '$IDENTITY_NAME' certificate in your login keychain."
  print "It never leaves this Mac and only signs your local build, so permissions survive updates."
  print "macOS may ask for your login password once."
  ./scripts/create-signing-identity.sh >/dev/null && ok "Created '$IDENTITY_NAME'" \
    || print -P "%F{yellow}!%f Could not create it; building ad-hoc (you may need to re-grant permissions after each update)."
fi

bold "Building (first build takes a minute or two)"
./scripts/build-app.sh --install | tail -2

if (( OPEN_AFTER )); then
  pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true
  open "$HOME/Applications/$APP_NAME.app"
fi

bold "Done"
print "On first recording macOS asks for Microphone, Speech Recognition and"
print "Screen & System Audio Recording permission. Allow them, then restart the app if asked."
print "Update later with: git pull && ./scripts/install.sh"
