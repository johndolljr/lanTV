#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
TARGET_DIR="${2:-$HOME/Applications}"
APP_PATH="$ROOT_DIR/build/$CONFIGURATION/lanTV.app"

"$ROOT_DIR/scripts/build-app.sh" "$CONFIGURATION"
mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_DIR/lanTV.app"
cp -R "$APP_PATH" "$TARGET_DIR/lanTV.app"

echo "Installed $TARGET_DIR/lanTV.app"
