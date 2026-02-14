#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GENERIC_SCRIPT="$REPO_ROOT/apps/deploy_app.sh"

SOURCE_DIR="${1:-/Users/kbrooks/Dropbox/Projects/tarot-app}"
if [ "$SOURCE_DIR" = "-h" ] || [ "$SOURCE_DIR" = "--help" ]; then
  exec "$GENERIC_SCRIPT" --help
fi

exec "$GENERIC_SCRIPT" \
  --name tarot \
  --host tarot.treadwellmedia.io \
  --source "$SOURCE_DIR" \
  --web-host-port 8090 \
  --api-host-port 8091 \
  --api-path /api \
  "${@:2}"
