#!/bin/bash
set -euo pipefail   # Fail fast — any error exits immediately instead of silently continuing

# ─── Install Docker CE ────────────────────────────────────────────────────────
# AL2023 does NOT have a package named "docker" in its native repos.
# Docker CE must be installed from Docker's own repo using the package name "docker-ce".
dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io --allowerasing

systemctl enable docker
systemctl start docker

# Block until Docker daemon is actually ready to accept commands.
# The old "sleep 3" was a guess — this is deterministic.
timeout 60 bash -c 'until docker info >/dev/null 2>&1; do sleep 2; done' || {
    echo "ERROR: Docker daemon failed to start within 60 seconds" >&2
    exit 1
}

# ─── 1. Authenticate with ECR ─────────────────────────────────────────────────
aws ecr get-login-password --region ap-southeast-1 | \
    docker login --username AWS --password-stdin ${ecr_url}

# ─── 2. Fetch sensitive credentials from SSM ──────────────────────────────────
export AWS_DEFAULT_REGION="ap-southeast-1"

ADMIN_APP_KEY=$(aws ssm get-parameter \
    --name "/shalotrack/prod/admin/app_key" \
    --with-decryption --query "Parameter.Value" --output text)

ADMIN_DB_PASSWORD=$(aws ssm get-parameter \
    --name "/shalotrack/prod/admin/db_password" \
    --with-decryption --query "Parameter.Value" --output text)

ADMIN_SYNC_KEY=$(aws ssm get-parameter \
    --name "/shalotrack/prod/admin/sync_key" \
    --with-decryption --query "Parameter.Value" --output text)

# Google Maps key is now fetched from SSM — NOT hardcoded in this file.
# Before deploying, create this parameter:
#   aws ssm put-parameter --name "/shalotrack/prod/admin/google_maps_api_key" \
#       --value "YOUR_KEY" --type SecureString --region ap-southeast-1
GOOGLE_MAPS_KEY=$(aws ssm get-parameter \
    --name "/shalotrack/prod/admin/google_maps_api_key" \
    --with-decryption --query "Parameter.Value" --output text)

# ─── 3. Start admin application container ─────────────────────────────────────
docker run -d \
    --restart always \
    --name shalotrack-admin \
    -p 80:80 \
    -e APP_NAME="Laravel" \
    -e APP_ENV="production" \
    -e APP_DEBUG="false" \
    -e APP_KEY="$ADMIN_APP_KEY" \
    -e APP_URL="https://admin.shalotrack.com" \
    -e SHALOTRACK_API_BASE_URL="https://api.shalotrack.com" \
    -e GOOGLE_MAPS_API_KEY="$GOOGLE_MAPS_KEY" \
    -e SHALOTRACK_SYNC_KEY="$ADMIN_SYNC_KEY" \
    -e LOG_CHANNEL="stack" \
    -e LOG_LEVEL="error" \
    -e DB_CONNECTION="pgsql" \
    -e DB_HOST="${db_host}" \
    -e DB_PORT="${db_port}" \
    -e DB_DATABASE="${db_database}" \
    -e DB_USERNAME="${db_username}" \
    -e DB_PASSWORD="$ADMIN_DB_PASSWORD" \
    -e SESSION_DRIVER="file" \
    -e SESSION_LIFETIME="120" \
    -e SESSION_ENCRYPT="false" \
    -e SESSION_PATH="/" \
    -e SESSION_DOMAIN=".shalotrack.com" \
    ${ecr_url}:latest

# Block until the Laravel health endpoint responds 200.
# This ensures the ALB only sees the instance as ready when the app is actually up.
timeout 120 bash -c \
    'until docker exec shalotrack-admin curl -sf http://localhost/up >/dev/null 2>&1; do sleep 3; done' || {
    echo "WARNING: Admin container did not pass health check within 120 seconds — check logs below:"
    docker logs shalotrack-admin --tail 100
}

# ─── 4. Node Exporter (host metrics for Prometheus) ───────────────────────────
# --net=host so it reports the real EC2 host's stats, not the container's.
docker run -d \
    --restart always \
    --name node-exporter \
    --net="host" \
    --pid="host" \
    -v "/:/host:ro,rslave" \
    quay.io/prometheus/node-exporter:v1.8.2 \
    --path.rootfs=/host
