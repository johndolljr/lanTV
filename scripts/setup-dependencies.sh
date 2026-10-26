#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor"
VLCKIT_DIR="$VENDOR_DIR/VLCKit.xcframework"

if [[ -d "$VLCKIT_DIR" && -d "$VLCKIT_DIR/macos-arm64_x86_64/VLCKit.framework" ]]; then
  echo "VLCKit.xcframework already installed at $VLCKIT_DIR"
  exit 0
fi

mkdir -p "$VENDOR_DIR"

# Official VideoLAN binary release package
VIDEOLAN_UPSTREAM_URL="https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.6.0-c73b779f-dd8bfdba.tar.xz"
DOWNLOAD_URL="${VLCKIT_URL:-$VIDEOLAN_UPSTREAM_URL}"

ARCHIVE_PATH="/tmp/VLCKit-upstream.tar.xz"

echo "VLCKit.xcframework not found in Vendor/."

if command -v curl >/dev/null 2>&1; then
  echo "Downloading official VLCKit from $DOWNLOAD_URL..."
  if curl -fSL "$DOWNLOAD_URL" -o "$ARCHIVE_PATH"; then
    echo "Extracting VLCKit.xcframework into Vendor/..."
    # Extract only the XCFramework from the VideoLAN binary package
    tar -xJf "$ARCHIVE_PATH" -C "$VENDOR_DIR" --strip-components=1 "VLCKit - binary package/VLCKit.xcframework"
    rm -f "$ARCHIVE_PATH"
  else
    echo "" >&2
    echo "Error: Failed to download VLCKit from $DOWNLOAD_URL" >&2
    exit 1
  fi
else
  echo "Error: curl is required to download dependencies." >&2
  exit 1
fi

if [[ -d "$VLCKIT_DIR" ]]; then
  echo "Successfully set up VLCKit.xcframework at $VLCKIT_DIR"
else
  echo "Error: Extraction did not create $VLCKIT_DIR" >&2
  exit 1
fi
