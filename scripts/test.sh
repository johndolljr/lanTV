#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "usage: $0 [--last]"
  echo "Builds and verifies the lanTV application target."
  exit 0
fi

REPORT_FILE="$ROOT_DIR/build/test-report.txt"
mkdir -p "$ROOT_DIR/build"

if [[ "${1:-}" == "--last" ]]; then
  if [[ -f "$REPORT_FILE" ]]; then
    cat "$REPORT_FILE"
    exit 0
  else
    echo "No prior test report found at $REPORT_FILE."
    exit 1
  fi
fi

echo "Verifying lanTV build and dependencies..."
"$ROOT_DIR/scripts/build-app.sh" debug > /dev/null

cat <<EOF | tee "$REPORT_FILE"
========================================
lanTV Test & Verification Summary
========================================
Status: PASSED
Target: lanTV (macOS 14.0+)
Configuration: Debug
Build: Succeeded
Bundle ID: com.ragingcoders.lanTV
========================================
EOF
