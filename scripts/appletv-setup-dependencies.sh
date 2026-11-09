#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/appletv-setup-dependencies.sh

Fetches the pinned official VideoLAN TVVLCKit binary used for non-HLS streams.
EOF
}
case "${1:-}" in -h|--help) usage; exit 0;; "") ;; *) usage >&2; exit 2;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/AppleTV/Vendor"
ARCHIVE="${TMPDIR:-/tmp}/lantv-TVVLCKit-3.6.0.tar.xz"
URL="https://download.videolan.org/cocoapods/prod/TVVLCKit-3.6.0-c73b779f-dd8bfdba.tar.xz"
EXPECTED="90d85d85528286d7ef9cb27187e0e3027cccd602e8d2379587e65c698f04498c"

mkdir -p "$DEST"
if [[ -d "$DEST/TVVLCKit.xcframework" && -f "$DEST/COPYING.txt" ]]; then
  echo "TVVLCKit is already present in AppleTV/Vendor."
  exit 0
fi
if [[ ! -f "$ARCHIVE" ]]; then curl -fL "$URL" -o "$ARCHIVE"; fi
ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  rm -f "$ARCHIVE"
  echo "TVVLCKit archive checksum mismatch." >&2
  exit 1
fi
tar -xJf "$ARCHIVE" -C "$DEST" --strip-components=1
echo "TVVLCKit installed in AppleTV/Vendor."
