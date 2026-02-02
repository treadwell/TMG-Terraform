# TMG Terraform

Infrastructure setup for a single EC2 deployment in the default VPC, with Terraform-managed resources and a simple deploy workflow.

See `plan.md` for the current checklist and sequencing.

## Users on the instance
- `admin`: SSH user with sudo (used for management).
- `app`: non-root user that runs containers/services.

## Systemd service (NGINX hello)
The instance boots with a system-level unit that starts a Podman NGINX container:
- Unit: `/etc/systemd/system/nginx-hello.service`
- Port: container listens on 8080; iptables redirects 80 -> 8080.

Useful commands (run after SSH):
```bash
systemctl status nginx-hello.service
systemctl restart nginx-hello.service
journalctl -u nginx-hello.service -f
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
ssh -i connect.key admin@54.174.206.49 "systemctl is-active nginx-hello.service && systemctl status --no-pager nginx-hello.service"
```

### Enable runtime dir for app (only if needed)
```bash
ssh -i connect.key admin@54.174.206.49 "sudo loginctl enable-linger app && sudo mkdir -p /run/user/\$(id -u app) && sudo chown app:app /run/user/\$(id -u app)"
```

### Restart the service
```bash
ssh -i connect.key admin@54.174.206.49 "sudo systemctl restart nginx-hello.service"
```

### Check from your machine
```bash
curl -I http://54.174.206.49
```

## Access the site
- HTTP: `http://<EIP>` (example: `http://54.174.206.49`)
- Get the EIP from Terraform output:
```bash
terraform -chdir=infra output -raw eip
```
