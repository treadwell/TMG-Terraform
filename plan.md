1. Confirm AWS profile and default VPC baseline (done).
2. Configure IAM for root + administrator logins (pending).
3. Local AWS CLI credentials (done).
4. SSH keys and Terraform EC2 instance (done).
5. Security group rules for 22/80/443 (done).
6. EIP created and associated (done).
7. Podman + non-root `app` user setup (done).
8. Caddy reverse proxy bootstrap via cloud-init (in progress, now deterministic mount + service ordering and direct 80/443 listeners; verify runtime on fresh apply).
9. Route 53 hosted zone and DNS records for `treadwellmedia.io` (done).
10. Remove manual snippet deploy path and rely on vanilla bootstrap defaults (done).
11. Add non-SSH recovery path (SSM instance profile) (done).
12. Validate site availability at domain + IP after fresh apply (pending).
