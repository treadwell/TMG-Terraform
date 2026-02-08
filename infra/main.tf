terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws",
      version = "5.46.0"
    }
    null = {
      source = "hashicorp/null"
      version = "~> 3.0"
    }
  }
  backend "s3" {
    bucket = "terraform-20260201212112349700000001"
    key = "infra.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {}

resource "aws_eip" "tmg" {
  domain = "vpc"
  tags = { Name = "tmg" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_instance" "tmg" {
  ami = "ami-0f58aa386a2280f35"
  instance_type = "t4g.nano"
  vpc_security_group_ids = [aws_security_group.tmg.id]
  tags = { Name = "tmg" }
  lifecycle {
    create_before_destroy = true
  }
  root_block_device {
    volume_size = 8
    encrypted = true
    tags = { Name = "tmg" }
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
  - iptables-persistent
  - uidmap
  - slirp4netns
  - fuse-overlayfs

runcmd:
  - mkdir -p /etc/systemd/system
  - mkdir -p /home/app
  - mkdir -p /home/app/caddy/apps /home/app/caddy/data /home/app/caddy/config
  - usermod --add-subuids 100000-165535 --add-subgids 100000-165535 app
  - iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
  - iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
  - netfilter-persistent save
  - loginctl enable-linger app
  - |
      cat >/etc/systemd/system/home-app.mount <<'UNIT'
      [Unit]
      Description=Mount /home/app

      [Mount]
      What=/dev/disk/by-id/placeholder
      Where=/home/app
      Type=ext4
      Options=defaults,nofail

      [Install]
      WantedBy=multi-user.target
      UNIT
  - |
      cat >/etc/systemd/system/home-app.automount <<'UNIT'
      [Unit]
      Description=Automount /home/app

      [Automount]
      Where=/home/app

      [Install]
      WantedBy=multi-user.target
      UNIT
  - |
      cat >/etc/systemd/system/caddy.service <<'UNIT'
      [Unit]
      Description=Podman Caddy Reverse Proxy
      After=network-online.target
      Wants=network-online.target

      [Service]
      User=app
      Environment=XDG_RUNTIME_DIR=/run/user/APP_UID_PLACEHOLDER
      Restart=always
      TimeoutStopSec=10
      ExecStart=/usr/bin/podman run --rm --name caddy --network host -v /home/app/caddy/Caddyfile:/etc/caddy/Caddyfile:ro -v /home/app/caddy/data:/data -v /home/app/caddy/config:/config docker.io/library/caddy:2-alpine
      ExecStop=/usr/bin/podman stop -t 10 caddy
      ExecStopPost=/usr/bin/podman rm -f caddy

      [Install]
      WantedBy=multi-user.target
      UNIT
  - |
      APP_UID="$(id -u app)"
      mkdir -p "/run/user/$${APP_UID}"
      chown app:app "/run/user/$${APP_UID}"
      sed -i "s|APP_UID_PLACEHOLDER|$${APP_UID}|" /etc/systemd/system/caddy.service
      APP_BYTES=$((20 * 1024 * 1024 * 1024))
      APP_DEV="$(lsblk -dbno NAME,TYPE,SIZE,MOUNTPOINT | awk -v size="$${APP_BYTES}" '$2=="disk" && $4=="" && $3==size {print $1; exit}')"
      if [ -n "$APP_DEV" ] && ! blkid "$APP_DEV" >/dev/null 2>&1; then
        mkfs -t ext4 "$APP_DEV"
      fi
      if [ -n "$APP_DEV" ]; then
        sed -i "s|^What=.*$|What=$${APP_DEV}|" /etc/systemd/system/home-app.mount
      fi
  - systemctl daemon-reload
  - systemctl enable --now home-app.automount
  - ls /home/app >/dev/null
  - mkdir -p /home/app/caddy/apps /home/app/caddy/data /home/app/caddy/config
  - |
      cat >/home/app/caddy/Caddyfile <<'CADDYFILE'
      {
        email ${trimspace(var.tmg_acme_email)}
      }

      http://treadwellmedia.io:8080, http://*.treadwellmedia.io:8080 {
        @www host www.treadwellmedia.io
        redir @www https://treadwellmedia.io{uri} 308
        redir https://{host}{uri} 308
      }

      https://treadwellmedia.io:8443, https://*.treadwellmedia.io:8443 {
        @www host www.treadwellmedia.io
        redir @www https://treadwellmedia.io{uri} 308
        import /home/app/caddy/apps/*.caddy
      }
      CADDYFILE
  - |
      if [ -z "$(ls -A /home/app/caddy/apps 2>/dev/null)" ]; then
        cat >/home/app/caddy/apps/maintenance.caddy <<'CADDYFILE'
@maintenance host treadwellmedia.io *.treadwellmedia.io
respond @maintenance "Maintenance" 503
CADDYFILE
      fi
  - chown -R app:app /home/app
  - systemctl enable --now caddy.service
EOF
}

resource "aws_security_group" "tmg" {
  name = "tmg"
  tags = { Name = "tmg" }
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  ingress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

variable "tmg_connect_key" {
  type = string
  sensitive = true
}

variable "tmg_connect_key_pub" {
  type = string
  sensitive = true
}

variable "tmg_instance_key" {
  type = string
  sensitive = true
}

variable "tmg_instance_key_pub" {
  type = string
  sensitive = true
}

variable "tmg_acme_email" {
  type = string
}

resource "aws_eip_association" "tmg" {
  instance_id = aws_instance.tmg.id
  allocation_id = aws_eip.tmg.id
}

resource "aws_ebs_volume" "tmg_app_home" {
  availability_zone = aws_instance.tmg.availability_zone
  size = 20
  type = "gp3"
  encrypted = true
  tags = { Name = "tmg-app-home" }
}

resource "aws_volume_attachment" "tmg_app_home" {
  device_name = "/dev/sdf"
  volume_id = aws_ebs_volume.tmg_app_home.id
  instance_id = aws_instance.tmg.id
}

data "aws_route53_zone" "treadwellmedia" {
  zone_id = "Z0207302EZZU15VNTMGH"
}

resource "aws_route53_record" "treadwellmedia_apex" {
  zone_id = data.aws_route53_zone.treadwellmedia.zone_id
  name = "treadwellmedia.io"
  type = "A"
  ttl = 300
  records = [aws_eip.tmg.public_ip]
}

resource "aws_route53_record" "treadwellmedia_www" {
  zone_id = data.aws_route53_zone.treadwellmedia.zone_id
  name = "www.treadwellmedia.io"
  type = "A"
  ttl = 300
  records = [aws_eip.tmg.public_ip]
}

resource "aws_route53_record" "treadwellmedia_wildcard" {
  zone_id = data.aws_route53_zone.treadwellmedia.zone_id
  name = "*.treadwellmedia.io"
  type = "A"
  ttl = 300
  records = [aws_eip.tmg.public_ip]
}

output "eip" {
  value = aws_eip.tmg.public_ip
}

output "treadwellmedia_name_servers" {
  value = data.aws_route53_zone.treadwellmedia.name_servers
}
