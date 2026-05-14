#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Restless"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
STAGE_DIR="$DIST_DIR/$APP_NAME-release"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"

"$ROOT_DIR/script/build_and_run.sh" --verify

rm -rf "$STAGE_DIR" "$ZIP_PATH"
mkdir -p "$STAGE_DIR/script"

cp -R "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
cp "$ROOT_DIR/script/install_passwordless_toggle.sh" "$STAGE_DIR/script/install_passwordless_toggle.sh"
cp "$ROOT_DIR/script/install_startup.sh" "$STAGE_DIR/script/install_startup.sh"
cp "$ROOT_DIR/README.md" "$STAGE_DIR/README.md"
cp "$ROOT_DIR/LICENSE" "$STAGE_DIR/LICENSE"

(
  cd "$DIST_DIR"
  /usr/bin/zip -qry "$ZIP_PATH" "$APP_NAME-release"
)

echo "Created $ZIP_PATH"
