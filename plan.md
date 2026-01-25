1. assess current AWS profile: clean up the account (single EC2 instance in default VPC with internet access; default VPC handles IGW/route table)
2. properly configure IAM for root + administrator logins
3. set up local AWS CLI credentials (maybe solved by #1)
4. create SSH keys locally via ssh-keygen, add them to .gitignore, and create a simple EC2 instance via Terraform that we can reliably SSH into
5. configure security group rules (22, 80, 443)
6. create an EIP and associate it with the EC2 instance
7. configure docker via EC2 setup script, ensuring non-root user has access on EC2
8. configure setup script to activate NGINX reverse proxy based on domain name (once configured) to localhost:8081 (single app for now), NGINX listens on 8080/8443, set iptables 80->8080, 443->8443, persist iptables across reboot, and bootstrap certbot (standalone or NGINX webroot)
9. port treadwellmedia.com to Route 53 and manage DNS records via Terraform
10. create a deploy script that builds a docker image locally, uses docker save + scp + docker load, runs one container at a time, and registers it with the reverse proxy
11. set up basic logging/monitoring on the EC2 instance (ensure docker containers log to systemd)
12. test at the IP address to reach the app
