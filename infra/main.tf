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
    shell: /usr/sbin/nologin
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
  - loginctl enable-linger app
  - iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
  - iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
  - netfilter-persistent save
  - mkdir -p /home/app/.well-known/acme-challenge /home/app/.config/systemd/user /home/app/.config/containers
  - chown -R app:app /home/app
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

resource "null_resource" "wait_for_cloud_init" {
  triggers = {
    instance_id = aws_instance.tmg.id
  }

  connection {
    type        = "ssh"
    user        = "admin"
    host        = aws_eip.tmg.public_ip
    private_key = var.tmg_connect_key
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["cloud-init status --wait"]
  }

  depends_on = [aws_eip_association.tmg]
}

resource "null_resource" "provisioner" {
  triggers = {
    instance_id = aws_instance.tmg.id
  }

  connection {
    type        = "ssh"
    user        = "admin"
    host        = aws_eip.tmg.public_ip
    private_key = var.tmg_connect_key
  }

  provisioner "file" {
    content     = var.tmg_instance_key
    destination = ".ssh/id_ed25519"
  }

  provisioner "file" {
    content     = var.tmg_instance_key_pub
    destination = ".ssh/id_ed25519.pub"
  }

  provisioner "remote-exec" {
    inline = ["chmod 600 ~/.ssh/id_ed25519"]
  }

  depends_on = [null_resource.wait_for_cloud_init]
}

output "eip" {
  value = aws_eip.tmg.public_ip
}
