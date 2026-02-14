# TMG Terraform

Single-instance EC2 deployment for `treadwellmedia.io`, managed with Terraform.

## What Terraform now bootstraps (vanilla)
- Creates EC2 instance, EIP, security group, Route53 records, and a dedicated EBS volume for `/home/app`.
- Formats/mounts the EBS volume at boot and persists mount in `/etc/fstab`.
- Installs Podman and networking dependencies.
- Installs and enables:
  - `landing.service`: nginx hello on `127.0.0.1:8081` (apex backend).
  - `hello.service`: nginx hello on `127.0.0.1:8082` (`hello.treadwellmedia.io` backend).
  - `caddy.service`: reverse proxy on `80/443`.
- Seeds `/home/app/caddy/Caddyfile` with default routes:
  - `treadwellmedia.io` -> `127.0.0.1:8081`
  - `hello.treadwellmedia.io` -> `127.0.0.1:8082`
- Enables SSM access via `AmazonSSMManagedInstanceCore` on the instance profile.

No deploy helper script is required for initial startup.

## Users
- `admin`: SSH management user with sudo and injected public keys.
- `app`: runtime user for default app containers (`landing` and `hello`).

## Runtime paths
- Caddyfile: `/home/app/caddy/Caddyfile`
- Snippets: `/home/app/caddy/apps/*.caddy`
- Caddy data/config: `/home/app/caddy/data`, `/home/app/caddy/config`

## App templates in repo
- `apps/landing/landing.service`
- `apps/landing/landing.caddy`
- `apps/hello/hello.service`
- `apps/hello/hello.caddy`
- `apps/_template/app.service`
- `apps/_template/app.caddy`

## Zero-reboot app deployment model
Use `/Users/kbrooks/Dropbox/Projects/TMG Terraform/apps/deploy_app.sh`.

It standardizes:
- Build from Dockerfile(s) as ARM64 images.
- Upload + `podman load` on EC2.
- Install/update systemd unit file(s) under `/etc/systemd/system`.
- Install/update Caddy snippet under `/home/app/caddy/apps`.
- Restart only affected services + Caddy (no instance reboot).

Requirements:
- A root `Dockerfile` is required for every app.
- If you want split web+api mode, also add `backend/Dockerfile`.
- If your app is FastAPI (or any backend), it still must be containerized via Dockerfile for this deployment flow.

`--no-api` means single-container apps:
- Static sites.
- Frontend-only SPAs (React/Vue/etc.) that call third-party APIs directly from the browser.
- Any app where one container handles all traffic and no separate backend container is needed.

Generic deploy examples:
```bash
# web + backend API mode (if backend/Dockerfile exists)
./apps/deploy_app.sh \
  --source /absolute/path/to/app \
  --host app.treadwellmedia.io \
  --env-file /Users/kbrooks/.config/tmg/app.env

# web-only mode
./apps/deploy_app.sh \
  --source /absolute/path/to/static-or-single-service-app \
  --host docs.treadwellmedia.io \
  --no-api
```

## Tarot app deployment (from Dockerfiles)
The tarot source app is at `/Users/kbrooks/Dropbox/Projects/tarot-app`.

Detected internal ports from source Dockerfiles:
- web container: `80` (`/Users/kbrooks/Dropbox/Projects/tarot-app/Dockerfile`)
- api container: `8000` (`/Users/kbrooks/Dropbox/Projects/tarot-app/backend/Dockerfile`)

This repo now includes:
- `/Users/kbrooks/Dropbox/Projects/TMG Terraform/apps/tarot/tarot-web.service`
- `/Users/kbrooks/Dropbox/Projects/TMG Terraform/apps/tarot/tarot-api.service`
- `/Users/kbrooks/Dropbox/Projects/TMG Terraform/apps/tarot/tarot.caddy`
- `/Users/kbrooks/Dropbox/Projects/TMG Terraform/apps/tarot/deploy.sh`
- `/Users/kbrooks/Dropbox/Projects/TMG Terraform/apps/tarot/tarot.env.example`

Recommended secret handling (no local commit risk):
1. Keep the real key file outside any git repo, for example: `/Users/kbrooks/.config/tmg/tarot.env`.
2. Use `apps/tarot/tarot.env.example` as the tracked template only.
3. Deploy with `TMG_ENV_FILE` pointing to the external file.

Run deploy:
```bash
cd /Users/kbrooks/Dropbox/Projects/TMG\ Terraform
./apps/tarot/deploy.sh /Users/kbrooks/Dropbox/Projects/tarot-app --env-file /Users/kbrooks/.config/tmg/tarot.env
```

What it does:
- Builds ARM64 images from both Dockerfiles.
- Copies image tarballs + service + caddy files to EC2.
- Copies your env file to `/home/app/apps/tarot/tarot.env` with `0600` permissions.
- Loads images into Podman as user `app`.
- Enables/restarts `tarot-api.service`, `tarot-web.service`, and restarts `caddy.service`.

## Provision
```bash
source .env
aws sso login --profile treadwellmedia
terraform -chdir=infra apply
```

## Access checks
From your machine:
```bash
curl -I http://treadwellmedia.io
curl -I https://treadwellmedia.io
```

Expected baseline behavior:
- HTTP responds with redirect to HTTPS.
- HTTPS apex responds from nginx hello (`landing`).
- `https://hello.treadwellmedia.io` responds from nginx hello (`hello`).

## SSH and host key churn
After rebuild/replacement:
```bash
ssh-keygen -R 54.174.206.49
ssh -i connect.key admin@54.174.206.49
```

## On-instance diagnostics
```bash
sudo systemctl status caddy.service landing.service hello.service --no-pager -l
sudo journalctl -u caddy.service -b --no-pager -l | tail -n 200
mountpoint /home/app
sudo ss -lntp | egrep ':(80|443)'
```

## SSM fallback (if SSH fails)
If port 22 access is broken, use Session Manager from AWS Console (instance now has SSM policy attached).

## Outputs
```bash
terraform -chdir=infra output -raw eip
terraform -chdir=infra output treadwellmedia_name_servers
```
