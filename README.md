# TMG Terraform

Infrastructure setup for a single EC2 deployment in the default VPC, with Terraform-managed resources and a simple deploy workflow.

See `plan.md` for the current checklist and sequencing.

## Current status
The environment is not fully working yet. Known issues:
- SSH access can fail after instance recreation if `user_data` does not apply or the EIP points at a different instance.
- Caddy must listen with TLS on `:8443` (not plain HTTP) because 443 is redirected there.
- `/home/app` is EBS-backed and auto-mounted; Caddy config/snippets must be written after the mount is active.

## Users on the instance
- `admin`: SSH user with sudo (used for management).
- `app`: non-root user that runs containers/services.

## Runtime layout
- Reverse proxy: Caddy in Podman, managed by systemd.
- App config/data: `/home/app` is an EBS-backed volume mounted via systemd automount.
- Caddy config: `/home/app/caddy/Caddyfile`
- Caddy snippets: `/home/app/caddy/apps/*.caddy` (manually copied from repo)

## Systemd service (Caddy)
Useful commands (run after SSH):
```bash
systemctl status caddy.service
systemctl restart caddy.service
journalctl -u caddy.service -f
```

## Deploy / reprovision
From your machine:
```bash
source .env
aws sso login --profile treadwellmedia
terraform -chdir=infra apply
```

## Full command sequences (reference)
### One-time local SSH key file
```bash
source .env
printf '%b' "$TF_VAR_tmg_connect_key" > connect.key
chmod 600 connect.key
```

### If host key changes (after rebuild)
```bash
ssh-keygen -R 54.174.206.49
```

### Verify service on the instance
```bash
ssh -i connect.key admin@54.174.206.49 "systemctl is-active caddy.service && systemctl status --no-pager caddy.service"
```

### Enable runtime dir for app (only if needed)
```bash
ssh -i connect.key admin@54.174.206.49 "sudo loginctl enable-linger app && sudo mkdir -p /run/user/\$(id -u app) && sudo chown app:app /run/user/\$(id -u app)"
```

### Restart the service
```bash
ssh -i connect.key admin@54.174.206.49 "sudo systemctl restart caddy.service"
```

### Check from your machine
```bash
curl -I https://treadwellmedia.io
```

## Access the site
- HTTPS: `https://treadwellmedia.io`
- Get the EIP from Terraform output (if needed):
```bash
terraform -chdir=infra output -raw eip
```

## App units and snippets
- App systemd units live in:
  - `apps/landing/landing.service` (nginx on 8081)
  - `apps/writer/writer.service` (nginx on 8082)
- Caddy snippets live in:
  - `apps/landing/landing.caddy` (apex -> 8081)
  - `apps/writer/writer.caddy` (`writer.treadwellmedia.io` -> 8082)
  - `apps/landing/maintenance.caddy` (apex + subdomains -> 503)
- These are repo files only; copy to `/home/app/caddy/apps/` on the server when deploying.

### Deploy snippets
```bash
./deploy_snippets.sh
```

## Troubleshooting
- SSH fails with `Permission denied (publickey)`. Confirm EIP `54.174.206.49` is attached to the expected instance. Confirm instance user data includes `admin` with your `tmg_connect_key_pub`. Recreate the instance if user data did not apply.
- HTTPS fails with `ERR_SSL_PROTOCOL_ERROR`. Caddy must serve TLS on `:8443` (see `infra/main.tf` user data).
- Connection refused. Check `systemctl status caddy.service` and `ss -lntp | egrep ':(8080|8443)'`.

## Rebuild checklist
```bash
terraform -chdir=infra taint aws_instance.tmg
terraform -chdir=infra apply
```
Then:
```bash
ssh -i connect.key admin@54.174.206.49 "systemctl status caddy.service --no-pager"
ssh -i connect.key admin@54.174.206.49 "ss -lntp | egrep ':(8080|8443)'"
```
