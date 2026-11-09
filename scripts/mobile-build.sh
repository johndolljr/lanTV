#!/bin/zsh
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "usage: $0 [debug|release] [simulator|device]"
  echo "Builds lanTV for iPhone and iPad. Device builds use the project’s configured Apple Development signing."
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
PLATFORM="${2:-simulator}"
case "$CONFIG" in debug) CONFIG=Debug ;; release) CONFIG=Release ;; *) echo "Expected debug or release" >&2; exit 1 ;; esac
case "$PLATFORM" in simulator) DEST='generic/platform=iOS Simulator' ;; device) DEST='generic/platform=iOS' ;; *) echo "Expected simulator or device" >&2; exit 1 ;; esac
"$ROOT_DIR/scripts/mobile-setup-dependencies.sh"
SIGNING=()
if [[ "$PLATFORM" == simulator ]]; then SIGNING+=(CODE_SIGNING_ALLOWED=NO); fi
xcodebuild -project "$ROOT_DIR/Mobile/lanTVMobile.xcodeproj" -scheme lanTVMobile -configuration "$CONFIG" -destination "$DEST" -derivedDataPath "$ROOT_DIR/build/mobile" "${SIGNING[@]}" INDEX_ENABLE_DATA_STORE=NO build
