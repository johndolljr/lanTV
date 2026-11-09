#!/bin/zsh
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "usage: $0 [--no-build] [--fixture] [--device SIMULATOR_UUID]"
  echo "Installs and launches on an already booted iPhone or iPad simulator."
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD=1
SIMULATOR=booted
ARGS=()
while (( $# )); do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --fixture) ARGS+=(--ui-fixture); shift ;;
    --device) SIMULATOR="${2:?Pass a simulator UUID}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
if (( BUILD )); then "$ROOT_DIR/scripts/mobile-build.sh" debug simulator; fi
APP="$ROOT_DIR/build/mobile/Build/Products/Debug-iphonesimulator/lanTVMobile.app"
# CoreSimulator cannot reliably install directly from network-mounted projects.
STAGE="$(mktemp -d /tmp/lantv-mobile-run.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/lanTVMobile.app"
xcrun simctl install "$SIMULATOR" "$STAGE/lanTVMobile.app"
xcrun simctl launch "$SIMULATOR" com.ragingcoders.lanTV.mobile "${ARGS[@]}"
