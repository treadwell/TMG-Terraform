#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GENERIC_SCRIPT="$REPO_ROOT/apps/deploy_app.sh"

SOURCE_DIR="${1:-/Users/kbrooks/Dropbox/Projects/CalibreRemote}"
if [ "$SOURCE_DIR" = "-h" ] || [ "$SOURCE_DIR" = "--help" ]; then
  exec "$GENERIC_SCRIPT" --help
fi

DEPLOY_ENV="$(mktemp /tmp/calibre-remote.deploy.env.XXXXXX)"
cleanup() {
  rm -f "$DEPLOY_ENV"
}
trap cleanup EXIT

perl -pe 's#^BASE_URL=.*#BASE_URL=https://calibre.treadwellmedia.io#; s#^TRUST_PROXY=.*#TRUST_PROXY=1#' "$SOURCE_DIR/.env" >"$DEPLOY_ENV"
chmod 600 "$DEPLOY_ENV"

exec "$GENERIC_SCRIPT" \
  --name calibre-remote \
  --host calibre.treadwellmedia.io \
  --source "$SOURCE_DIR" \
  --no-api \
  --web-host-port 8094 \
  --env-file "$DEPLOY_ENV" \
  --no-expand-env-file \
  --persist-dir data:/app/data \
  "${@:2}"
