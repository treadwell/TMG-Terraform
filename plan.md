1. Confirm AWS profile and default VPC baseline (done).
2. Configure IAM for root + administrator logins (pending).
3. Local AWS CLI credentials (done).
4. SSH keys and Terraform EC2 instance (done, but SSH access is unstable after rebuilds).
5. Security group rules for 22/80/443 (done).
6. EIP created and associated (done).
7. Podman + non-root app user setup (done, but Caddy service still failing in some boots).
8. Reverse proxy setup is now Caddy on 8080/8443 with iptables 80->8080 and 443->8443 (in progress; TLS and mount ordering still being validated).
9. Route 53 hosted zone and DNS records for treadwellmedia.io (done).
10. Deploy script for snippets exists (`deploy_snippets.sh`), still blocked by SSH connectivity (in progress).
11. Logging/monitoring (pending).
12. Validate site availability at domain + IP (blocked by Caddy startup and SSH access).
