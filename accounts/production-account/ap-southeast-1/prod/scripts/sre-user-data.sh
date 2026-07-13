#!/bin/bash
# Log script output for troubleshooting
exec > >(tee /var/log/user-data.log|logger -t user-data -s2>/dev/console) 2>&1

echo "=== Starting SRE Infrastructure Bootstrap ==="
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release

# Install Docker Engine natively
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/lists/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker

# Install Cloudflared for secure tunnel access
mkdir -p /usr/local/bin
curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

echo "=== Bootstrap Complete ==="