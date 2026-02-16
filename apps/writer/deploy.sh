#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GENERIC_SCRIPT="$REPO_ROOT/apps/deploy_app.sh"

SOURCE_DIR="${1:-/Users/kbrooks/Dropbox/Projects/LLMwriter}"
if [ "$SOURCE_DIR" = "-h" ] || [ "$SOURCE_DIR" = "--help" ]; then
  exec "$GENERIC_SCRIPT" --help
fi

# 8092 is reserved by breathing; keep writer on 8093.
WRITER_WEB_HOST_PORT=8093

exec "$GENERIC_SCRIPT" \
  --name writer \
  --host writer.treadwellmedia.io \
  --source "$SOURCE_DIR" \
  --no-api \
  --web-host-port "$WRITER_WEB_HOST_PORT" \
  --persist-file llmwriter.db:/app/llmwriter.db \
  --persist-dir assets:/app/assets \
  --persist-dir exports:/app/exports \
  "${@:2}"
