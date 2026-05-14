#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Restless"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
if [[ ! -d "$APP_BUNDLE" && -d "$ROOT_DIR/$APP_NAME.app" ]]; then
  APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"
fi
if [[ ! -d "$APP_BUNDLE" && -d "/Applications/$APP_NAME.app" ]]; then
  APP_BUNDLE="/Applications/$APP_NAME.app"
fi
LABEL="com.andrewturner.Restless"
OLD_LABEL="com.andrewturner.ScreenStay"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
OLD_PLIST_PATH="$LAUNCH_AGENTS_DIR/$OLD_LABEL.plist"

if [[ ! -d "$APP_BUNDLE" ]]; then
  "$ROOT_DIR/script/build_and_run.sh" --verify
  APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
fi

mkdir -p "$LAUNCH_AGENTS_DIR"

cat >"$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>$APP_BUNDLE</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST

plutil -lint "$PLIST_PATH" >/dev/null

launchctl bootout "gui/$(id -u)" "$OLD_PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$OLD_PLIST_PATH"
launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo "Restless will start when you log in."
