#!/bin/zsh
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "usage: $0 [--last]  Run mobile parser and lock policy tests with coverage."
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$ROOT_DIR/build/mobile-test-report.txt"
if [[ "${1:-}" == "--last" ]]; then cat "$REPORT"; exit 0; fi
mkdir -p "$ROOT_DIR/build"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/build/mobile-modulecache"
export CLANG_MODULE_CACHE_PATH="$SWIFTPM_MODULECACHE_OVERRIDE"
swift test --package-path "$ROOT_DIR/Mobile" --scratch-path "$ROOT_DIR/build/mobile-core" --enable-code-coverage --disable-sandbox 2>&1 | tee "$REPORT"
PROFILE="$(find "$ROOT_DIR/build/mobile-core" -name default.profdata -print -quit)"
BINARY="$(find "$ROOT_DIR/build/mobile-core" -path '*/MobileCoreTests.xctest/Contents/MacOS/MobileCoreTests' -type f -print -quit)"
[[ -n "$PROFILE" && -n "$BINARY" ]] || { echo "Coverage artifacts not found" >&2; exit 1; }
xcrun llvm-cov report "$BINARY" -instr-profile "$PROFILE" -ignore-filename-regex='Tests|\.build|build/' 2>&1 | tee -a "$REPORT"
SUMMARY="$ROOT_DIR/build/mobile-core-coverage.json"
xcrun llvm-cov export "$BINARY" -instr-profile "$PROFILE" -summary-only -ignore-filename-regex='Tests|\.build|build/' > "$SUMMARY"
python3 - "$SUMMARY" <<'PYCODE' | tee -a "$REPORT"
import json, sys
with open(sys.argv[1]) as report:
    total = json.load(report)['data'][0]['totals']
limits = {'regions': 85, 'lines': 80, 'functions': 90}
passed = all(total[key]['percent'] >= minimum for key, minimum in limits.items())
print('Coverage thresholds (regions 85%, lines 80%, functions 90%): ' + ('PASSED' if passed else 'FAILED'))
sys.exit(0 if passed else 1)
PYCODE
