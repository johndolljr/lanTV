#!/bin/zsh
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "usage: $0 [debug|release]"
  exit 0
fi
exec "$(dirname "$0")/run-app.sh" "$@"
