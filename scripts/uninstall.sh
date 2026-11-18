#!/bin/zsh
# Removes the app, its settings and permission grants.
#   --purge   also delete the signing identity (recordings are always kept)
set -euo pipefail

APP_NAME="Offrecord"
BUNDLE_ID="local.offrecord.app"
IDENTITY_NAME="Offrecord Local"

pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "$HOME/Applications/$APP_NAME.app"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
for service in Microphone SpeechRecognition ScreenCapture AudioCapture Calendar; do
  tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
done
echo "Removed $APP_NAME.app, its settings and permissions."

if [[ "${1:-}" == "--purge" ]]; then
  security delete-identity -c "$IDENTITY_NAME" >/dev/null 2>&1 && echo "Deleted signing identity '$IDENTITY_NAME'." || true
fi
echo "Recordings were kept in ~/Documents/$APP_NAME (delete that folder yourself if you want)."
