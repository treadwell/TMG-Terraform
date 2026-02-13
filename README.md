# TMG Terraform

Single-instance EC2 deployment for `treadwellmedia.io`, managed with Terraform.

## What Terraform now bootstraps (vanilla)
- Creates EC2 instance, EIP, security group, Route53 records, and a dedicated EBS volume for `/home/app`.
- Formats/mounts the EBS volume at boot and persists mount in `/etc/fstab`.
- Installs Podman and networking dependencies.
- Installs and enables `caddy.service` as user `app`.
- Seeds `/home/app/caddy/Caddyfile` and a default maintenance snippet if snippets are missing.
- Enables SSM access via `AmazonSSMManagedInstanceCore` on the instance profile.

No deploy helper script is required for initial startup.

## Users
- `admin`: SSH management user with sudo and injected public keys.
- `app`: runtime user for Podman/Caddy.

## Runtime paths
- Caddyfile: `/home/app/caddy/Caddyfile`
- Snippets: `/home/app/caddy/apps/*.caddy`
- Caddy data/config: `/home/app/caddy/data`, `/home/app/caddy/config`

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
- HTTPS responds from Caddy (default maintenance is `503` until app snippets are in place).

## SSH and host key churn
After rebuild/replacement:
```bash
ssh-keygen -R 54.174.206.49
ssh -i connect.key admin@54.174.206.49
```

## On-instance diagnostics
```bash
sudo systemctl status caddy.service --no-pager -l
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
