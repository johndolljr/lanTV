#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
APP_PATH="$ROOT_DIR/build/$CONFIGURATION/lanTV.app"

osascript -e 'tell application "lanTV" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  if ! pgrep -x "lanTV" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if pgrep -x "lanTV" >/dev/null 2>&1; then
  pkill -TERM -x "lanTV" >/dev/null 2>&1 || true
  sleep 1
fi

"$ROOT_DIR/scripts/build-app.sh" "$CONFIGURATION"
open "$APP_PATH"
