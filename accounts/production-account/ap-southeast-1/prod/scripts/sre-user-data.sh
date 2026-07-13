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


echo "=== Bootstrap Complete ==="