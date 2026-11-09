#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "usage: $0 [--last]"
  echo "Builds desktop and runs isolated desktop API and mobile core tests with coverage."
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
"$ROOT_DIR/scripts/test-desktop-api.sh" > "$ROOT_DIR/build/desktop-api-test-report.txt"
cat "$ROOT_DIR/build/desktop-api-test-report.txt"
"$ROOT_DIR/scripts/mobile-test.sh"

cat <<EOF | tee "$REPORT_FILE"
========================================
lanTV Test & Verification Summary
========================================
Status: PASSED
Target: lanTV (macOS 14.0+)
Configuration: Debug
Build: Succeeded
Desktop API tests: Passed (build/desktop-api-test-report.txt)
Mobile core tests: Passed (build/mobile-test-report.txt)
Coverage: See per-suite reports; full app/UI coverage is not measured.
Bundle ID: com.ragingcoders.lanTV
========================================
EOF
