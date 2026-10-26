#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET_DIR="$ROOT_DIR/build/AppIcon.iconset"
OUTPUT_ICNS="$ROOT_DIR/Support/AppIcon.icns"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

swift "$ROOT_DIR/scripts/render_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"

echo "Generated $OUTPUT_ICNS"
