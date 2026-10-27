#!/bin/bash
dnf update -y && dnf install -y docker

# Docker log rotation. With the observability stack removed, `docker logs` is
# the only log source on this host, and Docker's default json-file driver never
# rotates -- an unbounded log would eventually fill the root disk. Written
# BEFORE Docker starts so every container created below inherits it.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DOCKEREOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DOCKEREOF

systemctl enable docker && systemctl start docker

# 1. Authenticate with ECR
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}

# 2. Dynamically fetch sensitive production credentials out of AWS SSM
export AWS_DEFAULT_REGION="ap-southeast-1"

FLEET_APP_KEY=$(aws ssm get-parameter --name "/shalotrack/prod/fleet/app_key" --with-decryption --query "Parameter.Value" --output text)
FLEET_GOOGLE_MAPS_API_KEY=$(aws ssm get-parameter --name "/shalotrack/prod/fleet/google_maps_api_key" --with-decryption --query "Parameter.Value" --output text)
FLEET_FIREBASE_PROJECT_ID=$(aws ssm get-parameter --name "/shalotrack/prod/fleet/firebase_project_id" --query "Parameter.Value" --output text)
FLEET_FIREBASE_API_KEY=$(aws ssm get-parameter --name "/shalotrack/prod/fleet/firebase_api_key" --query "Parameter.Value" --output text)
FLEET_FIREBASE_AUTH_DOMAIN=$(aws ssm get-parameter --name "/shalotrack/prod/fleet/firebase_auth_domain" --query "Parameter.Value" --output text)
FLEET_FIREBASE_APP_ID=$(aws ssm get-parameter --name "/shalotrack/prod/fleet/firebase_app_id" --query "Parameter.Value" --output text)

if [ -z "$FLEET_FIREBASE_PROJECT_ID" ] || [ -z "$FLEET_FIREBASE_API_KEY" ] || [ -z "$FLEET_FIREBASE_AUTH_DOMAIN" ] || [ -z "$FLEET_FIREBASE_APP_ID" ]; then
  echo "FATAL: one or more /shalotrack/prod/fleet/firebase_* parameters missing/empty in SSM."
  echo "FATAL: Aborting EC2 boot — the entrypoint's own guard will crash-loop the container without these."
  exit 1
fi

# Hard-stop on boot if the app key came back empty, instead of letting the
# container start broken. (Fleet has NO database: it is a BFF to the C# API,
# with file sessions/cache, so no DB_* credentials are passed to it. Least
# privilege -- a compromised Fleet container must not hold DB credentials.)
if [ -z "$FLEET_APP_KEY" ]; then
  echo "FATAL: /shalotrack/prod/fleet/app_key missing/empty in SSM."
  echo "FATAL: Aborting EC2 boot to prevent a broken container."
  exit 1
fi

# 3. Spin up the application container. Note: -p 8080:8080, NOT 80:80 —
# this container's nginx binds 8080 (see Dockerfile/nginx.conf), unlike admin.
# SESSION_DOMAIN is intentionally NOT set: cookies stay host-only
# (fleet.shalotrack.com) and are never sent to sibling subdomains.
docker run -d --restart always --name shalotrack-fleet \
  -p 8080:8080 \
  -e APP_NAME="ShaloTrack Fleet" \
  -e APP_ENV="production" \
  -e APP_DEBUG="false" \
  -e APP_KEY="$FLEET_APP_KEY" \
  -e APP_URL="https://fleet.shalotrack.com" \
  -e SHALOTRACK_API_BASE_URL="https://api.shalotrack.com" \
  -e GEOCODER_USER_AGENT="ShaloTrack-Fleet/1.0 (contact@shalotrack.com)" \
  -e GOOGLE_MAPS_API_KEY="$FLEET_GOOGLE_MAPS_API_KEY" \
  -e FIREBASE_PROJECT_ID="$FLEET_FIREBASE_PROJECT_ID" \
  -e FIREBASE_API_KEY="$FLEET_FIREBASE_API_KEY" \
  -e FIREBASE_AUTH_DOMAIN="$FLEET_FIREBASE_AUTH_DOMAIN" \
  -e FIREBASE_APP_ID="$FLEET_FIREBASE_APP_ID" \
  -e LOG_CHANNEL="stderr" \
  -e LOG_LEVEL="warning" \
  -e SESSION_DRIVER="file" \
  -e SESSION_LIFETIME="120" \
  -e SESSION_COOKIE="shalotrack_fleet_session" \
  -e SESSION_SECURE_COOKIE="true" \
  -e SESSION_SAME_SITE="lax" \
  ${ecr_url}:latest

# 4. Wait briefly for the container to stabilize
sleep 3

# 5. Clear application runtime caches
docker exec shalotrack-fleet php artisan config:clear
docker exec shalotrack-fleet php artisan cache:clear