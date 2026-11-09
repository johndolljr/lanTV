#!/bin/zsh
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "usage: $0 [--last]"
  echo "Compile and run isolated desktop API export/request tests; never opens saved settings."
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/api-tests"
mkdir -p "$OUT_DIR"
if [[ "${1:-}" == "--last" ]]; then
  cat "$OUT_DIR/coverage.txt"
  exit 0
fi
swiftc -profile-generate -profile-coverage-mapping -module-cache-path /tmp/lantv-api-module-cache -o "$OUT_DIR/desktop-api-tests" \
  "$ROOT_DIR/Sources/lanTV/Models/GuideModels.swift" \
  "$ROOT_DIR/Sources/lanTV/Models/RecordingModels.swift" \
  "$ROOT_DIR/Sources/lanTV/Plugins/GuidePluginModels.swift" \
  "$ROOT_DIR/Sources/lanTV/Services/LocalAPIServer.swift" \
  "$ROOT_DIR/Tests/DesktopAPI/main.swift"
LLVM_PROFILE_FILE="$OUT_DIR/api-tests.profraw" "$OUT_DIR/desktop-api-tests"
xcrun llvm-profdata merge -sparse "$OUT_DIR/api-tests.profraw" -o "$OUT_DIR/api-tests.profdata"
xcrun llvm-cov report "$OUT_DIR/desktop-api-tests" -instr-profile="$OUT_DIR/api-tests.profdata" \
  "$ROOT_DIR/Sources/lanTV/Services/LocalAPIServer.swift" | tee "$OUT_DIR/coverage.txt"
echo "Coverage thresholds: regions 85%, lines 80%, functions 90%. Network/UI branches need integration coverage."
