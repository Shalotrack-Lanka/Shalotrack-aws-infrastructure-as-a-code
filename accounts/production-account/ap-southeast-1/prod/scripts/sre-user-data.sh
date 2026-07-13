#!/bin/bash
# Log script output for troubleshooting
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

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

# Verify the install actually landed before declaring victory
if ! /usr/libexec/docker/cli-plugins/docker-compose version >/dev/null 2>&1; then
  echo "ERROR: docker-compose plugin failed to install correctly"
fi

if ! systemctl is-active --quiet docker; then
  echo "ERROR: Docker service is not running after install"
fi

echo "=== Bootstrap Complete ==="