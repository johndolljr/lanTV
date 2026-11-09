#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/appletv-build.sh [simulator|device]

Generates the tvOS Xcode project and builds the Apple TV app. Defaults to simulator.
EOF
}
case "${1:-simulator}" in -h|--help) usage; exit 0;; simulator|device) DESTINATION="$1";; *) usage >&2; exit 2;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/appletv-setup-dependencies.sh"
cd "$ROOT/AppleTV"
xcodegen generate
if [[ "$DESTINATION" == "simulator" ]]; then
  xcodebuild -project lanTVAppleTV.xcodeproj -scheme lanTVAppleTV -destination 'generic/platform=tvOS Simulator' -derivedDataPath "${TMPDIR:-/tmp}/lanTVAppleTVDerivedData" CODE_SIGNING_ALLOWED=NO build
else
  xcodebuild -project lanTVAppleTV.xcodeproj -scheme lanTVAppleTV -destination 'generic/platform=tvOS' -derivedDataPath "${TMPDIR:-/tmp}/lanTVAppleTVDerivedData" CODE_SIGNING_ALLOWED=NO build
fi
