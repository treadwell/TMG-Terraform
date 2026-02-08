#!/usr/bin/env bash
set -euo pipefail

HOST="${TMG_HOST:-54.174.206.49}"
USER="${TMG_USER:-admin}"
KEY="${TMG_KEY:-connect.key}"
REMOTE_DIR="${TMG_REMOTE_DIR:-/home/app/caddy/apps}"
TMP_DIR="/tmp/caddy-snippets-$RANDOM"

if [[ ! -f "${KEY}" ]]; then
  echo "Missing SSH key: ${KEY}" >&2
  exit 1
fi

files=()
while IFS= read -r f; do
  files+=("$f")
done < <(find "./apps" -type f -name "*.caddy" | sort)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No .caddy files found under ./apps" >&2
  exit 1
fi

ssh -i "${KEY}" "${USER}@${HOST}" "mkdir -p '${TMP_DIR}'"

for f in "${files[@]}"; do
  base="$(basename "${f}")"
  scp -i "${KEY}" "${f}" "${USER}@${HOST}:${TMP_DIR}/${base}"
done

ssh -i "${KEY}" "${USER}@${HOST}" "sudo mkdir -p '${REMOTE_DIR}' && sudo mv ${TMP_DIR}/*.caddy '${REMOTE_DIR}/' && sudo chown app:app '${REMOTE_DIR}'/*.caddy && sudo systemctl reload caddy.service"

ssh -i "${KEY}" "${USER}@${HOST}" "rmdir '${TMP_DIR}'" >/dev/null 2>&1 || true

echo "Deployed ${#files[@]} snippet(s) to ${USER}@${HOST}:${REMOTE_DIR}"
