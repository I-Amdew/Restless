#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Restless"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
STAGE_DIR="$DIST_DIR/$APP_NAME-release"
DMG_STAGE_DIR="$DIST_DIR/$APP_NAME-dmg"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
RW_DMG_PATH="$DIST_DIR/$APP_NAME-rw.dmg"

if [[ "${CI:-}" == "true" ]]; then
  "$ROOT_DIR/script/build_and_run.sh" --build
else
  "$ROOT_DIR/script/build_and_run.sh" --verify
fi

rm -rf "$STAGE_DIR" "$DMG_STAGE_DIR" "$ZIP_PATH" "$DMG_PATH" "$RW_DMG_PATH"
mkdir -p "$STAGE_DIR/script"
mkdir -p "$DMG_STAGE_DIR"

cp -R "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
cp "$ROOT_DIR/script/install_passwordless_toggle.sh" "$STAGE_DIR/script/install_passwordless_toggle.sh"
cp "$ROOT_DIR/script/install_startup.sh" "$STAGE_DIR/script/install_startup.sh"
cp "$ROOT_DIR/README.md" "$STAGE_DIR/README.md"
cp "$ROOT_DIR/LICENSE" "$STAGE_DIR/LICENSE"

(
  cd "$DIST_DIR"
  /usr/bin/zip -qry "$ZIP_PATH" "$APP_NAME-release"
)

cp -R "$APP_BUNDLE" "$DMG_STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE_DIR/Applications"
/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDRW \
  "$RW_DMG_PATH" >/dev/null

MOUNT_DIR="$(/usr/bin/mktemp -d "/tmp/$APP_NAME-dmg.XXXXXX")"
/usr/bin/hdiutil attach "$RW_DMG_PATH" \
  -mountpoint "$MOUNT_DIR" \
  -readwrite \
  -noverify \
  -noautoopen >/dev/null

/usr/bin/osascript >/dev/null <<APPLESCRIPT || true
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {420, 160, 900, 430}
    set theOptions to icon view options of container window
    set arrangement of theOptions to not arranged
    set icon size of theOptions to 96
    set position of item "$APP_NAME.app" of container window to {160, 120}
    set position of item "Applications" of container window to {320, 120}
    close
  end tell
end tell
APPLESCRIPT

/bin/sync
/usr/bin/hdiutil detach "$MOUNT_DIR" >/dev/null
/usr/bin/hdiutil convert "$RW_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" >/dev/null
rm -rf "$RW_DMG_PATH"
rm -rf "$DMG_STAGE_DIR"

echo "Created $ZIP_PATH"
echo "Created $DMG_PATH"
