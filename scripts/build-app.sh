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

# Configure App Transport Security (ATS) for local network domains
DOMAINS=()
if [[ -n "${ATS_DOMAINS:-}" ]]; then
  for d in ${(s: :)ATS_DOMAINS}; do
    DOMAINS+=("$d")
  done
fi

if [[ -f "$ROOT_DIR/.local-domains" ]]; then
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -n "$line" && ! "$line" =~ ^# ]]; then
      DOMAINS+=("$line")
    fi
  done < "$ROOT_DIR/.local-domains"
fi

SETTINGS_FILE="$HOME/Library/Application Support/lanTV/settings.json"
if [[ -f "$SETTINGS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
  AUTO_DOMAINS=$(python3 -c "
import json, urllib.parse
try:
    with open('$SETTINGS_FILE') as f:
        data = json.load(f)
    for s in data.get('sources', []):
        k = s.get('kind', {})
        url = k.get('url')
        if url:
            host = urllib.parse.urlparse(url).hostname
            if host and not host.endswith('.local') and host not in ('localhost', '127.0.0.1'):
                print(host)
except Exception:
    pass
" 2>/dev/null || true)
  if [[ -n "$AUTO_DOMAINS" ]]; then
    while IFS= read -r host; do
      [[ -n "$host" ]] && DOMAINS+=("$host")
    done <<< "$AUTO_DOMAINS"
  fi
fi

if [[ ${#DOMAINS[@]} -gt 0 ]]; then
  UNIQUE_DOMAINS=($(printf "%s\n" "${DOMAINS[@]}" | sort -u))
  PLIST="$APP_DIR/Contents/Info.plist"
  if [[ -f "$PLIST" ]] && command -v python3 >/dev/null 2>&1; then
    echo "Configuring ATS exceptions for local domains: ${UNIQUE_DOMAINS[*]}"
    python3 -c "
import plistlib, sys
plist_path = sys.argv[1]
domains = sys.argv[2:]
try:
    with open(plist_path, 'rb') as f:
        pl = plistlib.load(f)
    ats = pl.setdefault('NSAppTransportSecurity', {})
    ats['NSAllowsArbitraryLoads'] = True
    ats['NSAllowsArbitraryLoadsForMedia'] = True
    ats['NSAllowsLocalNetworking'] = True
    exceptions = ats.setdefault('NSExceptionDomains', {})
    for d in domains:
        exceptions[d] = {
            'NSExceptionAllowsInsecureHTTPLoads': True,
            'NSIncludesSubdomains': True
        }
    with open(plist_path, 'wb') as f:
        plistlib.dump(pl, f)
except Exception as e:
    print(f'Warning: failed to update Info.plist: {e}', file=sys.stderr)
" "$PLIST" "${UNIQUE_DOMAINS[@]}"
    codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null 2>&1 || true
  fi
fi

if [[ -n "${STALE_APP_DIR:-}" && -e "${STALE_APP_DIR:-}" ]]; then
  (rm -rf "$STALE_APP_DIR" >/dev/null 2>&1 || true) &
fi

echo "Built $APP_DIR"
