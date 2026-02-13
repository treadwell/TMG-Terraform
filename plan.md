1. Confirm AWS profile and default VPC baseline (done).
2. Configure IAM for root + administrator logins (pending).
3. Local AWS CLI credentials (done).
4. SSH keys and Terraform EC2 instance (done).
5. Security group rules for 22/80/443 (done).
6. EIP created and associated (done).
7. Podman + non-root `app` user setup (done).
8. Caddy reverse proxy bootstrap via cloud-init (in progress, now deterministic mount + service ordering and direct 80/443 listeners with default routes for apex + hello subdomain; verify runtime on fresh apply).
9. Route 53 hosted zone and DNS records for `treadwellmedia.io` (done).
10. Remove manual snippet deploy path and rely on vanilla bootstrap defaults (done).
11. Add non-SSH recovery path (SSM instance profile) (done).
12. Validate site availability at domain + IP after fresh apply (pending).
13. Future app rollout pattern (pending): deploy `tarot.treadwellmedia.io` by building an ARM64 image locally, transferring via `docker save` tarball, loading into Podman on EC2, creating `tarot.service` bound to localhost port, and adding a Caddy snippet in `/home/app/caddy/apps/` that reverse proxies the new subdomain.
14. Add fallback subdomain behavior (pending): any subdomain not explicitly configured (for example, anything except `hello.treadwellmedia.io` and future named app routes) should redirect to `https://treadwellmedia.io`.
15. Add zero-reboot app deployment workflow (pending): deploy/update Docker/Podman images and start/stop app services via systemd + Podman on the running host without rebuilding or restarting the EC2 instance.
