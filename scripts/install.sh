#!/bin/zsh
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "usage: $0 [debug|release] [target_dir]"
  exit 0
fi
exec "$(dirname "$0")/install-app.sh" "$@"
