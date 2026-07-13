#!/bin/bash
# Log script output for troubleshooting
exec > >(tee /var/log/user-data.log|logger -t user-data -s2>/dev/console) 2>&1

echo "=== Starting SRE Infrastructure Bootstrap (AL2023) ==="
dnf update -y

# Install Docker Engine (Native to AL2023)
dnf install -y docker
systemctl enable docker
systemctl start docker

# Install Docker Compose plugin
mkdir -p /usr/libexec/docker/cli-plugins/
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose

# Install Cloudflared for secure tunnel access
mkdir -p /usr/local/bin
curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

echo "=== Bootstrap Complete ==="