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
