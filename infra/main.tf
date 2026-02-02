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
  - usermod --add-subuids 100000-165535 --add-subgids 100000-165535 app
  - iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
  - iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
  - netfilter-persistent save
  - mkdir -p /home/app/.well-known/acme-challenge /home/app/.config/containers
  - chown -R app:app /home/app
  - |
      cat >/etc/systemd/system/nginx-hello.service <<'UNIT'
      [Unit]
      Description=Podman NGINX Hello
      After=network-online.target
      Wants=network-online.target

      [Service]
      User=app
      Restart=always
      TimeoutStopSec=10
      ExecStart=/usr/bin/podman run --rm --name nginx-hello -p 8080:80 docker.io/library/nginx:alpine
      ExecStop=/usr/bin/podman stop -t 10 nginx-hello
      ExecStopPost=/usr/bin/podman rm -f nginx-hello

      [Install]
      WantedBy=multi-user.target
      UNIT
  - systemctl daemon-reload
  - systemctl enable --now nginx-hello.service
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

resource "aws_eip_association" "tmg" {
  instance_id = aws_instance.tmg.id
  allocation_id = aws_eip.tmg.id
}

output "eip" {
  value = aws_eip.tmg.public_ip
}
