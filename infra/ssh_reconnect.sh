#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./infra/ssh_reconnect.sh [options]

Options:
  --host HOST        Override target host/IP (skip terraform output lookup)
  --user USER        SSH user (default: admin or TMG_SSH_USER)
  --key PATH         SSH private key path (default: ./connect.key or TMG_SSH_KEY)
  --profile PROFILE  AWS profile for SSO login (default: AWS_PROFILE or treadwellmedia)
  --no-sso           Skip aws sso login
  --no-ssh           Run prep/checks only; do not open SSH session
  --verbose          Use -vvv when opening SSH
  -h, --help         Show help
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

HOST_OVERRIDE=""
SSH_USER="${TMG_SSH_USER:-admin}"
SSH_KEY="${TMG_SSH_KEY:-$REPO_ROOT/connect.key}"
AWS_PROFILE_NAME="${AWS_PROFILE:-treadwellmedia}"
RUN_SSO="true"
RUN_SSH="true"
VERBOSE_SSH="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      HOST_OVERRIDE="${2:-}"
      shift 2
      ;;
    --user)
      SSH_USER="${2:-}"
      shift 2
      ;;
    --key)
      SSH_KEY="${2:-}"
      shift 2
      ;;
    --profile)
      AWS_PROFILE_NAME="${2:-}"
      shift 2
      ;;
    --no-sso)
      RUN_SSO="false"
      shift
      ;;
    --no-ssh)
      RUN_SSH="false"
      shift
      ;;
    --verbose)
      VERBOSE_SSH="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd ssh
require_cmd ssh-keygen
require_cmd terraform

if [ ! -f "$SSH_KEY" ]; then
  echo "SSH key not found: $SSH_KEY" >&2
  exit 1
fi

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

if [ "$RUN_SSO" = "true" ]; then
  require_cmd aws
  echo "Refreshing AWS SSO session for profile: ${AWS_PROFILE_NAME}"
  aws sso login --profile "$AWS_PROFILE_NAME"
fi

TMG_HOST="$HOST_OVERRIDE"
if [ -z "$TMG_HOST" ]; then
  echo "Resolving EIP from terraform output..."
  TMG_HOST="$(terraform -chdir="$REPO_ROOT/infra" output -raw eip)"
fi

if [ -z "$TMG_HOST" ]; then
  echo "Could not determine target host." >&2
  exit 1
fi

echo "Using host: $TMG_HOST"
echo "Using user: $SSH_USER"
echo "Using key:  $SSH_KEY"

chmod 600 "$SSH_KEY"
ssh-keygen -R "$TMG_HOST" >/dev/null 2>&1 || true

if command -v nc >/dev/null 2>&1; then
  echo "Checking TCP reachability on ${TMG_HOST}:22 ..."
  nc -vz "$TMG_HOST" 22
fi

if [ "$RUN_SSH" = "false" ]; then
  echo "Prep complete (--no-ssh set)."
  exit 0
fi

SSH_OPTS=(-o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -i "$SSH_KEY")
if [ "$VERBOSE_SSH" = "true" ]; then
  SSH_OPTS=(-vvv "${SSH_OPTS[@]}")
fi

echo "Opening SSH session..."
exec ssh "${SSH_OPTS[@]}" "${SSH_USER}@${TMG_HOST}"
