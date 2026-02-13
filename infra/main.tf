terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws",
      version = "5.46.0"
    }
  }
  backend "s3" {
    bucket = "terraform-20260201212112349700000001"
    key    = "infra.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {}

resource "aws_eip" "tmg" {
  domain = "vpc"
  tags   = { Name = "tmg" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_instance" "tmg" {
  ami                    = "ami-0f58aa386a2280f35"
  instance_type          = "t4g.nano"
  vpc_security_group_ids = [aws_security_group.tmg.id]
  iam_instance_profile   = aws_iam_instance_profile.tmg_instance.name
  tags                   = { Name = "tmg" }
  root_block_device {
    volume_size = 8
    encrypted   = true
    tags        = { Name = "tmg" }
  }
  user_data = <<-EOF
#cloud-config
users:
  - default
  - name: admin
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${trimspace(var.tmg_connect_key_pub)}
      - ${trimspace(var.tmg_instance_key_pub)}
  - name: app
    shell: /bin/bash
    home: /home/app
    create_home: true
    system: false

packages:
  - podman
  - cron
  - rsync
  - uidmap
  - slirp4netns
  - fuse-overlayfs

runcmd:
  - systemctl enable --now ssh
  - |
      if ! ss -lnt | awk '$4 ~ /:22$/ {found=1} END{exit !found}'; then
        journalctl -u ssh --no-pager -n 80 || true
        exit 1
      fi
  - usermod --add-subuids 100000-165535 --add-subgids 100000-165535 app
  - loginctl enable-linger app
  - |
      APP_BYTES=$((20 * 1024 * 1024 * 1024))
      APP_DEV="$(lsblk -dbpno NAME,TYPE,SIZE,MOUNTPOINT | awk -v size="$${APP_BYTES}" '$2=="disk" && $4=="" && $3==size {print $1; exit}')"
      if [ -z "$${APP_DEV}" ]; then
        echo "Failed to resolve app EBS device" >&2
        exit 1
      fi
      if ! blkid "$${APP_DEV}" >/dev/null 2>&1; then
        mkfs -t ext4 "$${APP_DEV}"
      fi
      APP_UUID="$(blkid -s UUID -o value "$${APP_DEV}")"
      grep -q " /home/app " /etc/fstab || echo "UUID=$${APP_UUID} /home/app ext4 defaults,nofail 0 2" >>/etc/fstab
      mkdir -p /home/app
      mountpoint -q /home/app || mount /home/app || mount -a
  - |
      cat >/etc/systemd/system/caddy.service <<'UNIT'
      [Unit]
      Description=Podman Caddy Reverse Proxy
      After=network-online.target
      Wants=network-online.target
      RequiresMountsFor=/home/app

      [Service]
      Restart=always
      TimeoutStopSec=10
      ExecStart=/usr/bin/podman run --rm --name caddy --network host -v /home/app/caddy/Caddyfile:/etc/caddy/Caddyfile:ro -v /home/app/caddy/data:/data -v /home/app/caddy/config:/config docker.io/library/caddy:2-alpine
      ExecStop=/usr/bin/podman stop -t 10 caddy
      ExecStopPost=/usr/bin/podman rm -f caddy

      [Install]
      WantedBy=multi-user.target
      UNIT
  - |
      cat >/etc/systemd/system/landing.service <<'UNIT'
      [Unit]
      Description=Podman NGINX Hello (landing)
      After=network-online.target
      Wants=network-online.target

      [Service]
      User=app
      PermissionsStartOnly=true
      ExecStartPre=/bin/mkdir -p /run/user/APP_UID_PLACEHOLDER
      ExecStartPre=/bin/chown app:app /run/user/APP_UID_PLACEHOLDER
      Environment=XDG_RUNTIME_DIR=/run/user/APP_UID_PLACEHOLDER
      Restart=always
      TimeoutStopSec=10
      ExecStart=/usr/bin/podman run --rm --name landing -p 127.0.0.1:8081:80 docker.io/library/nginx:alpine
      ExecStop=/usr/bin/podman stop -t 10 landing
      ExecStopPost=/usr/bin/podman rm -f landing

      [Install]
      WantedBy=multi-user.target
      UNIT
  - |
      cat >/etc/systemd/system/hello.service <<'UNIT'
      [Unit]
      Description=Podman NGINX Hello (hello.treadwellmedia.io)
      After=network-online.target
      Wants=network-online.target

      [Service]
      User=app
      PermissionsStartOnly=true
      ExecStartPre=/bin/mkdir -p /run/user/APP_UID_PLACEHOLDER
      ExecStartPre=/bin/chown app:app /run/user/APP_UID_PLACEHOLDER
      Environment=XDG_RUNTIME_DIR=/run/user/APP_UID_PLACEHOLDER
      Restart=always
      TimeoutStopSec=10
      ExecStart=/usr/bin/podman run --rm --name hello -p 127.0.0.1:8082:80 docker.io/library/nginx:alpine
      ExecStop=/usr/bin/podman stop -t 10 hello
      ExecStopPost=/usr/bin/podman rm -f hello

      [Install]
      WantedBy=multi-user.target
      UNIT
  - |
      APP_UID="$(id -u app)"
      sed -i "s|APP_UID_PLACEHOLDER|$${APP_UID}|g" /etc/systemd/system/landing.service /etc/systemd/system/hello.service
  - mkdir -p /home/app/caddy/apps /home/app/caddy/data /home/app/caddy/config
  - |
      cat >/home/app/caddy/Caddyfile <<'CADDYFILE'
      {
        email ${trimspace(var.tmg_acme_email)}
        auto_https disable_redirects
      }

      http://treadwellmedia.io, http://www.treadwellmedia.io, http://*.treadwellmedia.io {
        @www host www.treadwellmedia.io
        redir @www https://treadwellmedia.io{uri} 308
        redir https://{host}{uri} 308
      }

      https://treadwellmedia.io, https://www.treadwellmedia.io {
        tls {
          issuer acme {
            disable_http_challenge
          }
        }
        @www host www.treadwellmedia.io
        redir @www https://treadwellmedia.io{uri} 308
        reverse_proxy 127.0.0.1:8081
      }

      https://hello.treadwellmedia.io {
        tls {
          issuer acme {
            disable_http_challenge
          }
        }
        reverse_proxy 127.0.0.1:8082
      }

      # Add future app routes as standalone site blocks in /home/app/caddy/apps/*.caddy
      # Example:
      # https://app.treadwellmedia.io {
      #   reverse_proxy 127.0.0.1:9000
      # }
      import /home/app/caddy/apps/*.caddy
      CADDYFILE
  - rm -f /home/app/caddy/apps/maintenance.caddy
  - chown -R app:app /home/app
  - systemctl daemon-reload
  - systemctl enable --now landing.service hello.service caddy.service
EOF
}

data "aws_iam_policy_document" "tmg_instance_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "tmg_instance" {
  name               = "tmg-instance-role"
  assume_role_policy = data.aws_iam_policy_document.tmg_instance_assume_role.json
}

resource "aws_iam_role_policy_attachment" "tmg_ssm_managed" {
  role       = aws_iam_role.tmg_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "tmg_instance" {
  name = "tmg-instance-profile"
  role = aws_iam_role.tmg_instance.name
}

resource "aws_security_group" "tmg" {
  name = "tmg"
  tags = { Name = "tmg" }
  ingress {
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  ingress {
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  ingress {
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

variable "tmg_connect_key" {
  type      = string
  sensitive = true
}

variable "tmg_connect_key_pub" {
  type      = string
  sensitive = true
}

variable "tmg_instance_key" {
  type      = string
  sensitive = true
}

variable "tmg_instance_key_pub" {
  type      = string
  sensitive = true
}

variable "tmg_acme_email" {
  type = string
}

resource "aws_eip_association" "tmg" {
  instance_id   = aws_instance.tmg.id
  allocation_id = aws_eip.tmg.id
}

resource "aws_ebs_volume" "tmg_app_home" {
  availability_zone = aws_instance.tmg.availability_zone
  size              = 20
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "tmg-app-home" }
}

resource "aws_volume_attachment" "tmg_app_home" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.tmg_app_home.id
  instance_id = aws_instance.tmg.id
}

data "aws_route53_zone" "treadwellmedia" {
  zone_id = "Z0207302EZZU15VNTMGH"
}

resource "aws_route53_record" "treadwellmedia_apex" {
  zone_id = data.aws_route53_zone.treadwellmedia.zone_id
  name    = "treadwellmedia.io"
  type    = "A"
  ttl     = 300
  records = [aws_eip.tmg.public_ip]
}

resource "aws_route53_record" "treadwellmedia_www" {
  zone_id = data.aws_route53_zone.treadwellmedia.zone_id
  name    = "www.treadwellmedia.io"
  type    = "A"
  ttl     = 300
  records = [aws_eip.tmg.public_ip]
}

resource "aws_route53_record" "treadwellmedia_wildcard" {
  zone_id = data.aws_route53_zone.treadwellmedia.zone_id
  name    = "*.treadwellmedia.io"
  type    = "A"
  ttl     = 300
  records = [aws_eip.tmg.public_ip]
}

output "eip" {
  value = aws_eip.tmg.public_ip
}

output "treadwellmedia_name_servers" {
  value = data.aws_route53_zone.treadwellmedia.name_servers
}
