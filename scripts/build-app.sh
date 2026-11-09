#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
APP_NAME="lanTV"
PRODUCT_NAME="$APP_NAME.app"
PROJECT_PATH="$ROOT_DIR/lanTV.xcodeproj"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/lanTV-derived}"

"$ROOT_DIR/scripts/setup-dependencies.sh"

case "$CONFIGURATION" in
  debug)
    XCODE_CONFIGURATION="Debug"
    ;;
  release)
    XCODE_CONFIGURATION="Release"
    ;;
  *)
    echo "usage: $0 [debug|release]" >&2
    exit 1
    ;;
esac

BUILD_ROOT="$ROOT_DIR/build/$CONFIGURATION"
PRODUCTS_DIR="$ROOT_DIR/build/xcode-products/$CONFIGURATION"
BUILT_APP_DIR="$PRODUCTS_DIR/$PRODUCT_NAME"
APP_DIR="$BUILD_ROOT/$PRODUCT_NAME"
STAGED_APP_DIR="$BUILD_ROOT/.new-$PRODUCT_NAME-$$"

mkdir -p "$BUILD_ROOT" "$PRODUCTS_DIR"
export COPYFILE_DISABLE=1

find "$BUILD_ROOT" -maxdepth 1 \( -name ".stale-$PRODUCT_NAME-*" -o -name ".new-$PRODUCT_NAME-*" \) -exec rm -rf {} + 2>/dev/null || true
rm -rf "$STAGED_APP_DIR"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$APP_NAME" \
  -configuration "$XCODE_CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR" \
  INDEX_ENABLE_DATA_STORE=NO \
  build

if [[ ! -d "$BUILT_APP_DIR" ]]; then
  echo "error: expected built app at $BUILT_APP_DIR" >&2
  exit 1
fi

cp -R "$BUILT_APP_DIR" "$STAGED_APP_DIR"

if [[ -e "$APP_DIR" ]]; then
  STALE_APP_DIR="$BUILD_ROOT/.stale-$PRODUCT_NAME-$$"
  mv "$APP_DIR" "$STALE_APP_DIR"
fi

mv "$STAGED_APP_DIR" "$APP_DIR"

# ATS is declared in Support/Info.plist for arbitrary user-configured HTTP LAN
# hosts. Fine-grained ATS keys must not override NSAllowsArbitraryLoads; sources
# added after installation must work without rebuilding the app's exceptions.

if [[ -n "${STALE_APP_DIR:-}" && -e "${STALE_APP_DIR:-}" ]]; then
  (rm -rf "$STALE_APP_DIR" >/dev/null 2>&1 || true) &
fi

echo "Built $APP_DIR"
