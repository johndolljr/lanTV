#!/bin/zsh
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "usage: $0  Download the official stable MobileVLCKit 3.6.0 binary framework."
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT_DIR/Mobile/Vendor"
[[ -d "$DEST/MobileVLCKit.xcframework" && -f "$DEST/COPYING.txt" ]] && exit 0
ARCHIVE="$(mktemp /tmp/lantv-mobilevlc.XXXXXX)"
trap 'rm -f "$ARCHIVE"' EXIT
curl --fail --location --retry 3 "https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.6.0-c73b779f-dd8bfdba.tar.xz" -o "$ARCHIVE"
EXPECTED="1a5077beeb7bf943a3fbbb91523752e50a10d490a3046cb9808d906784ddbc36"
ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "MobileVLCKit checksum mismatch." >&2; exit 1; }
mkdir -p "$DEST"
tar -xJf "$ARCHIVE" -C "$DEST" --strip-components=1
