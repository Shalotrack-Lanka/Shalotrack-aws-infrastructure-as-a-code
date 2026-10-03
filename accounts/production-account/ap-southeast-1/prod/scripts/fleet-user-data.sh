#!/bin/bash
dnf update -y && dnf install -y docker
systemctl enable docker && systemctl start docker

# 1. Authenticate with ECR
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}

# 2. Dynamically fetch sensitive production credentials out of AWS SSM
export AWS_DEFAULT_REGION="ap-southeast-1"

FLEET_APP_KEY=$(aws ssm get-parameter --name "/shalotrack/prod/fleet/app_key" --with-decryption --query "Parameter.Value" --output text)
FLEET_DB_PASSWORD=$(aws ssm get-parameter --name "/shalotrack/prod/fleet/db_password" --with-decryption --query "Parameter.Value" --output text)
FLEET_GOOGLE_MAPS_API_KEY=$(aws ssm get-parameter --name "/shalotrack/prod/fleet/google_maps_api_key" --with-decryption --query "Parameter.Value" --output text)

# BAN FIX (same class of bug fixed on api-user-data.sh, Sep 22): hard-stop
# on boot if the app key or DB password came back empty, instead of letting
# the container start broken and hammer Supabase with bad auth.
if [ -z "$FLEET_APP_KEY" ] || [ -z "$FLEET_DB_PASSWORD" ]; then
  echo "FATAL: /shalotrack/prod/fleet/app_key or db_password missing/empty in SSM."
  echo "FATAL: Aborting EC2 boot to prevent a broken container and Supabase bad-auth retries."
  exit 1
fi

# 3. Spin up the application container. Note: -p 8080:8080, NOT 80:80 —
# this container's nginx binds 8080 (see Dockerfile/nginx.conf), unlike admin.
docker run -d --restart always --name shalotrack-fleet \
  -p 8080:8080 \
  -e APP_NAME="ShaloTrack Fleet" \
  -e APP_ENV="production" \
  -e APP_DEBUG="false" \
  -e APP_KEY="$FLEET_APP_KEY" \
  -e APP_URL="https://fleet.shalotrack.com" \
  -e SHALOTRACK_API_BASE_URL="https://api.shalotrack.com" \
  -e GOOGLE_MAPS_API_KEY="$FLEET_GOOGLE_MAPS_API_KEY" \
  -e LOG_CHANNEL="stderr" \
  -e LOG_LEVEL="warning" \
  -e DB_CONNECTION="pgsql" \
  -e DB_HOST="${db_host}" \
  -e DB_PORT="${db_port}" \
  -e DB_DATABASE="${db_database}" \
  -e DB_USERNAME="${db_username}" \
  -e DB_PASSWORD="$FLEET_DB_PASSWORD" \
  -e SESSION_DRIVER="file" \
  -e SESSION_LIFETIME="120" \
  -e SESSION_COOKIE="shalotrack_fleet_session" \
  -e SESSION_SECURE_COOKIE="true" \
  -e SESSION_SAME_SITE="lax" \
  -e SESSION_DOMAIN=".shalotrack.com" \
  ${ecr_url}:latest

# 4. Wait briefly for the container to stabilize
sleep 3

# 5. Clear application runtime caches
docker exec shalotrack-fleet php artisan config:clear
docker exec shalotrack-fleet php artisan cache:clear

# 6. Node Exporter — host-level metrics for Prometheus (SRE stack).
docker run -d --restart always --name node-exporter \
  --net="host" \
  --pid="host" \
  -v "/:/host:ro,rslave" \
  quay.io/prometheus/node-exporter:v1.8.2 \
  --path.rootfs=/host