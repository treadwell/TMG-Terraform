#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./apps/deploy_app.sh --source /absolute/path/to/app --host app.example.com [options]

Required:
  --source PATH          App source directory containing Dockerfile
  --host HOSTNAME        Public hostname for Caddy route

Optional:
  --name APP             App name slug (default: first host label)
  --env-file PATH        Runtime env file (used for backend API container)
  --web-host-port PORT   Host loopback port for web container
  --api-host-port PORT   Host loopback port for api container
  --api-path PATH        API prefix path (default: /api)
  --no-api               Deploy as single-container app (skip backend/Dockerfile)
  -h, --help             Show help

Environment fallbacks:
  TMG_HOST               EC2 public IP/host (default: terraform infra output eip)
  TMG_SSH_USER           SSH user (default: admin)
  TMG_SSH_KEY            SSH key path (default: ./connect.key)
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

detect_exposed_port() {
  local dockerfile="$1"
  local fallback="$2"
  local detected
  detected="$(awk 'toupper($1)=="EXPOSE"{print $2; exit}' "$dockerfile" | sed -E 's#/tcp$##' || true)"
  if [ -z "$detected" ]; then
    echo "$fallback"
  else
    echo "$detected"
  fi
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

default_ports() {
  local seed
  seed="$(cksum <<<"$1" | awk '{print $1}')"
  local web=$((8200 + (seed % 300)))
  local api=$((8600 + (seed % 300)))
  echo "$web $api"
}

validate_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le 65535 ] ;;
  esac
}

SOURCE_DIR=""
HOSTNAME=""
APP_NAME=""
ENV_FILE=""
WEB_HOST_PORT=""
API_HOST_PORT=""
API_PATH="/api"
NO_API="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE_DIR="${2:-}"
      shift 2
      ;;
    --host)
      HOSTNAME="${2:-}"
      shift 2
      ;;
    --name)
      APP_NAME="${2:-}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --web-host-port)
      WEB_HOST_PORT="${2:-}"
      shift 2
      ;;
    --api-host-port)
      API_HOST_PORT="${2:-}"
      shift 2
      ;;
    --api-path)
      API_PATH="${2:-}"
      shift 2
      ;;
    --no-api)
      NO_API="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$SOURCE_DIR" ] || [ -z "$HOSTNAME" ]; then
  usage
  exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Source directory does not exist: $SOURCE_DIR" >&2
  exit 1
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "$APP_NAME" ]; then
  APP_NAME="${HOSTNAME%%.*}"
fi
APP_NAME="$(slugify "$APP_NAME")"
if [ -z "$APP_NAME" ]; then
  echo "Could not derive valid app name." >&2
  exit 1
fi

if [ "${API_PATH#/}" = "$API_PATH" ]; then
  API_PATH="/$API_PATH"
fi
API_PATH="${API_PATH%/}"
if [ -z "$API_PATH" ]; then
  API_PATH="/api"
fi

WEB_DOCKERFILE="$SOURCE_DIR/Dockerfile"
API_DOCKERFILE="$SOURCE_DIR/backend/Dockerfile"
API_ENABLED="true"
if [ "$NO_API" = "true" ] || [ ! -f "$API_DOCKERFILE" ]; then
  API_ENABLED="false"
fi

if [ ! -f "$WEB_DOCKERFILE" ]; then
  echo "Missing Dockerfile: $WEB_DOCKERFILE" >&2
  exit 1
fi

if [ -z "$ENV_FILE" ]; then
  ENV_FILE="$SOURCE_DIR/.env"
fi

require_cmd docker
require_cmd ssh
require_cmd scp
require_cmd terraform

TMG_HOST="${TMG_HOST:-$(terraform -chdir="$REPO_ROOT/infra" output -raw eip 2>/dev/null || true)}"
TMG_SSH_USER="${TMG_SSH_USER:-admin}"
TMG_SSH_KEY="${TMG_SSH_KEY:-$REPO_ROOT/connect.key}"

if [ -z "$TMG_HOST" ]; then
  echo "TMG_HOST is empty and terraform output eip was unavailable." >&2
  exit 1
fi

if [ ! -f "$TMG_SSH_KEY" ]; then
  echo "SSH key not found: $TMG_SSH_KEY" >&2
  exit 1
fi

if [ -z "$WEB_HOST_PORT" ] || { [ "$API_ENABLED" = "true" ] && [ -z "$API_HOST_PORT" ]; }; then
  read -r AUTO_WEB AUTO_API < <(default_ports "$APP_NAME")
  WEB_HOST_PORT="${WEB_HOST_PORT:-$AUTO_WEB}"
  API_HOST_PORT="${API_HOST_PORT:-$AUTO_API}"
fi

if ! validate_port "$WEB_HOST_PORT"; then
  echo "Invalid --web-host-port: $WEB_HOST_PORT" >&2
  exit 1
fi
if [ "$API_ENABLED" = "true" ] && ! validate_port "$API_HOST_PORT"; then
  echo "Invalid --api-host-port: $API_HOST_PORT" >&2
  exit 1
fi

WEB_CONTAINER_PORT="$(detect_exposed_port "$WEB_DOCKERFILE" "80")"
API_CONTAINER_PORT=""
if [ "$API_ENABLED" = "true" ]; then
  API_CONTAINER_PORT="$(detect_exposed_port "$API_DOCKERFILE" "8000")"
fi

WEB_IMAGE="localhost/${APP_NAME}-web:deploy"
API_IMAGE="localhost/${APP_NAME}-api:deploy"
SINGLE_IMAGE="localhost/${APP_NAME}:deploy"

REMOTE_STAGE="/tmp/${APP_NAME}-deploy"
TMP_DIR="$(mktemp -d "/tmp/${APP_NAME}-deploy.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [ "$API_ENABLED" = "true" ]; then
  WEB_SERVICE_NAME="${APP_NAME}-web"
  API_SERVICE_NAME="${APP_NAME}-api"

  cat >"$TMP_DIR/${WEB_SERVICE_NAME}.service" <<EOF2
[Unit]
Description=Podman ${APP_NAME} web
After=network-online.target
Wants=network-online.target

[Service]
User=app
PermissionsStartOnly=true
ExecStartPre=/bin/mkdir -p /run/user/APP_UID_PLACEHOLDER
ExecStartPre=/bin/chown app:app /run/user/APP_UID_PLACEHOLDER
Environment=XDG_RUNTIME_DIR=/run/user/APP_UID_PLACEHOLDER
Restart=always
RestartSec=2
TimeoutStopSec=10
ExecStartPre=-/usr/bin/podman rm -f ${WEB_SERVICE_NAME}
ExecStart=/usr/bin/podman run --rm --name ${WEB_SERVICE_NAME} -p 127.0.0.1:${WEB_HOST_PORT}:${WEB_CONTAINER_PORT} ${WEB_IMAGE}
ExecStop=/usr/bin/podman stop -t 10 ${WEB_SERVICE_NAME}
ExecStopPost=-/usr/bin/podman rm -f ${WEB_SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF2

  cat >"$TMP_DIR/${API_SERVICE_NAME}.service" <<EOF2
[Unit]
Description=Podman ${APP_NAME} api
After=network-online.target
Wants=network-online.target

[Service]
User=app
PermissionsStartOnly=true
ExecStartPre=/bin/mkdir -p /run/user/APP_UID_PLACEHOLDER
ExecStartPre=/bin/chown app:app /run/user/APP_UID_PLACEHOLDER
Environment=XDG_RUNTIME_DIR=/run/user/APP_UID_PLACEHOLDER
EnvironmentFile=-/home/app/apps/${APP_NAME}/${APP_NAME}.env
Restart=always
RestartSec=2
TimeoutStopSec=10
ExecStartPre=-/usr/bin/podman rm -f ${API_SERVICE_NAME}
ExecStart=/usr/bin/podman run --rm --name ${API_SERVICE_NAME} -p 127.0.0.1:${API_HOST_PORT}:${API_CONTAINER_PORT} --env-file /home/app/apps/${APP_NAME}/${APP_NAME}.env ${API_IMAGE}
ExecStop=/usr/bin/podman stop -t 10 ${API_SERVICE_NAME}
ExecStopPost=-/usr/bin/podman rm -f ${API_SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF2

  cat >"$TMP_DIR/${APP_NAME}.caddy" <<EOF2
https://${HOSTNAME} {
  handle ${API_PATH}/* {
    reverse_proxy 127.0.0.1:${API_HOST_PORT}
  }

  handle {
    reverse_proxy 127.0.0.1:${WEB_HOST_PORT}
  }
}
EOF2

  if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "$TMP_DIR/${APP_NAME}.env"
    chmod 600 "$TMP_DIR/${APP_NAME}.env"
  else
    cat >"$TMP_DIR/${APP_NAME}.env" <<'EOF2'
# Runtime variables for backend API service
# OPENAI_API_KEY=...
# OPENAI_MODEL=gpt-4o-mini
EOF2
    echo "Warning: no env file found at $ENV_FILE. API may fail until /home/app/apps/${APP_NAME}/${APP_NAME}.env is populated." >&2
  fi
else
  SERVICE_NAME="$APP_NAME"

  cat >"$TMP_DIR/${SERVICE_NAME}.service" <<EOF2
[Unit]
Description=Podman ${APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
User=app
PermissionsStartOnly=true
ExecStartPre=/bin/mkdir -p /run/user/APP_UID_PLACEHOLDER
ExecStartPre=/bin/chown app:app /run/user/APP_UID_PLACEHOLDER
Environment=XDG_RUNTIME_DIR=/run/user/APP_UID_PLACEHOLDER
Restart=always
RestartSec=2
TimeoutStopSec=10
ExecStartPre=-/usr/bin/podman rm -f ${SERVICE_NAME}
ExecStart=/usr/bin/podman run --rm --name ${SERVICE_NAME} -p 127.0.0.1:${WEB_HOST_PORT}:${WEB_CONTAINER_PORT} ${SINGLE_IMAGE}
ExecStop=/usr/bin/podman stop -t 10 ${SERVICE_NAME}
ExecStopPost=-/usr/bin/podman rm -f ${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF2

  cat >"$TMP_DIR/${APP_NAME}.caddy" <<EOF2
https://${HOSTNAME} {
  reverse_proxy 127.0.0.1:${WEB_HOST_PORT}
}
EOF2
fi

# Write the remote script with escaped runtime vars so expansion happens on EC2.
cat >"$TMP_DIR/remote-apply.sh" <<EOF2
#!/usr/bin/env bash
set -euo pipefail

REMOTE_STAGE="${REMOTE_STAGE}"
APP_NAME="${APP_NAME}"
API_ENABLED="${API_ENABLED}"

APP_UID="\$(id -u app)"
sudo mkdir -p "/run/user/\${APP_UID}"
sudo chown app:app "/run/user/\${APP_UID}"

if ! sudo grep -q '/home/app/caddy/apps:/home/app/caddy/apps:ro' /etc/systemd/system/caddy.service; then
  sudo sed -i 's|-v /home/app/caddy/data:/data |-v /home/app/caddy/apps:/home/app/caddy/apps:ro -v /home/app/caddy/data:/data |' /etc/systemd/system/caddy.service
fi

sudo sed -i "s|APP_UID_PLACEHOLDER|\${APP_UID}|g" "\${REMOTE_STAGE}"/*.service
sudo chmod 755 "\${REMOTE_STAGE}"

if [ "\${API_ENABLED}" = "true" ]; then
  sudo install -m 644 "\${REMOTE_STAGE}/\${APP_NAME}-web.service" "/etc/systemd/system/\${APP_NAME}-web.service"
  sudo install -m 644 "\${REMOTE_STAGE}/\${APP_NAME}-api.service" "/etc/systemd/system/\${APP_NAME}-api.service"
  sudo chmod 644 "\${REMOTE_STAGE}/\${APP_NAME}-web.tar" "\${REMOTE_STAGE}/\${APP_NAME}-api.tar"
  sudo chown app:app "\${REMOTE_STAGE}/\${APP_NAME}-web.tar" "\${REMOTE_STAGE}/\${APP_NAME}-api.tar"
  sudo mkdir -p "/home/app/apps/\${APP_NAME}"
  sudo install -m 600 "\${REMOTE_STAGE}/\${APP_NAME}.env" "/home/app/apps/\${APP_NAME}/\${APP_NAME}.env"
  sudo chown app:app "/home/app/apps/\${APP_NAME}/\${APP_NAME}.env"
else
  sudo install -m 644 "\${REMOTE_STAGE}/\${APP_NAME}.service" "/etc/systemd/system/\${APP_NAME}.service"
  sudo chmod 644 "\${REMOTE_STAGE}/\${APP_NAME}.tar"
  sudo chown app:app "\${REMOTE_STAGE}/\${APP_NAME}.tar"
fi

sudo mkdir -p /home/app/caddy/apps
sudo install -m 644 "\${REMOTE_STAGE}/\${APP_NAME}.caddy" "/home/app/caddy/apps/\${APP_NAME}.caddy"
sudo chown app:app "/home/app/caddy/apps/\${APP_NAME}.caddy"

if [ "\${API_ENABLED}" = "true" ]; then
  sudo -u app XDG_RUNTIME_DIR="/run/user/\${APP_UID}" podman load -i "\${REMOTE_STAGE}/\${APP_NAME}-web.tar"
  sudo -u app XDG_RUNTIME_DIR="/run/user/\${APP_UID}" podman load -i "\${REMOTE_STAGE}/\${APP_NAME}-api.tar"
else
  sudo -u app XDG_RUNTIME_DIR="/run/user/\${APP_UID}" podman load -i "\${REMOTE_STAGE}/\${APP_NAME}.tar"
fi

sudo systemctl daemon-reload
if [ "\${API_ENABLED}" = "true" ]; then
  sudo systemctl enable --now "\${APP_NAME}-web.service" "\${APP_NAME}-api.service"
  sudo systemctl restart "\${APP_NAME}-web.service" "\${APP_NAME}-api.service"
else
  sudo systemctl enable --now "\${APP_NAME}.service"
  sudo systemctl restart "\${APP_NAME}.service"
fi
sudo systemctl restart caddy.service

if [ "\${API_ENABLED}" = "true" ]; then
  sudo systemctl --no-pager --full status "\${APP_NAME}-web.service" "\${APP_NAME}-api.service" caddy.service | sed -n '1,160p'
else
  sudo systemctl --no-pager --full status "\${APP_NAME}.service" caddy.service | sed -n '1,160p'
fi
EOF2
chmod +x "$TMP_DIR/remote-apply.sh"

echo "Deploying app '${APP_NAME}' from ${SOURCE_DIR} to ${HOSTNAME}"
echo "Target host: ${TMG_HOST}"
if [ "$API_ENABLED" = "true" ]; then
  echo "Mode: web+api (web host port ${WEB_HOST_PORT}, api host port ${API_HOST_PORT})"
else
  echo "Mode: single container (host port ${WEB_HOST_PORT})"
fi

echo "Building ARM64 image(s) from Dockerfile(s)..."
if docker buildx version >/dev/null 2>&1; then
  if [ "$API_ENABLED" = "true" ]; then
    docker buildx build --platform linux/arm64 --load -t "$WEB_IMAGE" -f "$WEB_DOCKERFILE" "$SOURCE_DIR"
    docker buildx build --platform linux/arm64 --load -t "$API_IMAGE" -f "$API_DOCKERFILE" "$SOURCE_DIR/backend"
  else
    docker buildx build --platform linux/arm64 --load -t "$SINGLE_IMAGE" -f "$WEB_DOCKERFILE" "$SOURCE_DIR"
  fi
else
  echo "docker buildx unavailable; falling back to docker build (host architecture)." >&2
  if [ "$API_ENABLED" = "true" ]; then
    docker build -t "$WEB_IMAGE" -f "$WEB_DOCKERFILE" "$SOURCE_DIR"
    docker build -t "$API_IMAGE" -f "$API_DOCKERFILE" "$SOURCE_DIR/backend"
  else
    docker build -t "$SINGLE_IMAGE" -f "$WEB_DOCKERFILE" "$SOURCE_DIR"
  fi
fi

echo "Saving image archive(s)..."
if [ "$API_ENABLED" = "true" ]; then
  docker save "$WEB_IMAGE" -o "$TMP_DIR/${APP_NAME}-web.tar"
  docker save "$API_IMAGE" -o "$TMP_DIR/${APP_NAME}-api.tar"
else
  docker save "$SINGLE_IMAGE" -o "$TMP_DIR/${APP_NAME}.tar"
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -i "$TMG_SSH_KEY")

echo "Preparing remote stage: ${REMOTE_STAGE}"
ssh "${SSH_OPTS[@]}" "${TMG_SSH_USER}@${TMG_HOST}" "sudo rm -rf '${REMOTE_STAGE}'; sudo mkdir -p '${REMOTE_STAGE}'; sudo chown ${TMG_SSH_USER}:${TMG_SSH_USER} '${REMOTE_STAGE}'"

echo "Uploading deployment artifacts..."
if [ "$API_ENABLED" = "true" ]; then
  scp "${SSH_OPTS[@]}" \
    "$TMP_DIR/${APP_NAME}-web.tar" \
    "$TMP_DIR/${APP_NAME}-api.tar" \
    "$TMP_DIR/${APP_NAME}-web.service" \
    "$TMP_DIR/${APP_NAME}-api.service" \
    "$TMP_DIR/${APP_NAME}.caddy" \
    "$TMP_DIR/${APP_NAME}.env" \
    "$TMP_DIR/remote-apply.sh" \
    "${TMG_SSH_USER}@${TMG_HOST}:${REMOTE_STAGE}/"
else
  scp "${SSH_OPTS[@]}" \
    "$TMP_DIR/${APP_NAME}.tar" \
    "$TMP_DIR/${APP_NAME}.service" \
    "$TMP_DIR/${APP_NAME}.caddy" \
    "$TMP_DIR/remote-apply.sh" \
    "${TMG_SSH_USER}@${TMG_HOST}:${REMOTE_STAGE}/"
fi

echo "Applying on remote host..."
ssh "${SSH_OPTS[@]}" "${TMG_SSH_USER}@${TMG_HOST}" "bash '${REMOTE_STAGE}/remote-apply.sh'"

echo
echo "Deployment complete. Verify:"
echo "  curl -I https://${HOSTNAME}"
if [ "$API_ENABLED" = "true" ]; then
  echo "  curl -I https://${HOSTNAME}${API_PATH}/health"
fi
