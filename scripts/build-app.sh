#!/bin/zsh
# Builds Offrecord.app into ./build. Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Offrecord.app"
swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/arm64-apple-macosx/release/Offrecord" "$APP/Contents/MacOS/Offrecord"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# App icon rendered from an SF Symbol (no external assets).
swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 || echo "icon skipped"

# Signing: use a stable local identity if present so macOS remembers permissions
# across rebuilds; otherwise ad-hoc (permissions must be re-granted after each rebuild).
IDENTITY="${OFFRECORD_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning | grep -q "Offrecord Local"; then
  IDENTITY="Offrecord Local"
fi
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Offrecord.app"
  cp -R "$APP" "$HOME/Applications/Offrecord.app"
  echo "Installed to ~/Applications/Offrecord.app"
fi
