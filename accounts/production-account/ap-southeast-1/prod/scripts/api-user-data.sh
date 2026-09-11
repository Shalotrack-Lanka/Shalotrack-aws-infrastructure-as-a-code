#!/bin/bash
dnf update -y && dnf install -y docker
systemctl enable docker && systemctl start docker

# 1. Authenticate with ECR
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}

# 2. Pull down production secrets directly out of AWS SSM
export AWS_DEFAULT_REGION="ap-southeast-1"

API_CONNECTION_STRING=$(aws ssm get-parameter \
  --name "/shalotrack/prod/api/csharp_connection_string" \
  --with-decryption --query "Parameter.Value" --output text)

API_ADMIN_SYNC_KEY=$(aws ssm get-parameter \
  --name "/shalotrack/prod/api/admin_sync_key" \
  --with-decryption --query "Parameter.Value" --output text)

API_REALTIME_CONNECTION_STRING=$(aws ssm get-parameter \
  --name "/shalotrack/prod/api/realtime_connection_string" \
  --with-decryption --query "Parameter.Value" --output text)

API_FIREBASE_SERVICE_ACCOUNT_JSON=$(aws ssm get-parameter \
  --name "/shalotrack/prod/api/firebase_service_account_json" \
  --with-decryption --query "Parameter.Value" --output text)
if [ -z "$API_FIREBASE_SERVICE_ACCOUNT_JSON" ]; then
  echo "ERROR: Firebase service account JSON not found in SSM — container will crash-loop without it"
fi

API_GOOGLE_MAPS_ROADS_API_KEY=$(aws ssm get-parameter \
  --name "/shalotrack/prod/api/google_maps_roads_api_key" \
  --with-decryption --query "Parameter.Value" --output text)
if [ -z "$API_GOOGLE_MAPS_ROADS_API_KEY" ]; then
  echo "ERROR: Google Maps Roads API key not found in SSM — container will crash-loop without it"
fi

# PHASE 2 FIX: Read PurgeDryRun from SSM so it can be toggled without redeployment.
# To promote to live deletes: aws ssm put-parameter --name "/shalotrack/prod/api/gps_archive_purge_dry_run" --value "false" --overwrite
# Then trigger an Instance Refresh on the ASG to pick up the new value.
GPS_ARCHIVE_PURGE_DRY_RUN=$(aws ssm get-parameter \
  --name "/shalotrack/prod/api/gps_archive_purge_dry_run" \
  --query "Parameter.Value" --output text)
if [ -z "$GPS_ARCHIVE_PURGE_DRY_RUN" ]; then
  GPS_ARCHIVE_PURGE_DRY_RUN="true"
  echo "WARNING: gps_archive_purge_dry_run not found in SSM — defaulting to true (safe)"
fi

# 3. Spin up the C# API container
# PHASE 2 FIX: ASPNETCORE_ENVIRONMENT=Production added.
# Previously missing entirely — every fresh ASG instance was booting in
# Development mode: Swagger exposed, wrong appsettings loaded, raw DB errors
# visible in HTTP responses.
docker run -d --restart always --name shalotrack-api \
  -p 80:8080 \
  -e ASPNETCORE_ENVIRONMENT="Production" \
  -e ConnectionStrings__DefaultConnection="$API_CONNECTION_STRING" \
  -e ConnectionStrings__RealtimeConnection="$API_REALTIME_CONNECTION_STRING" \
  -e AdminSync__Key="$API_ADMIN_SYNC_KEY" \
  -e Firebase__ServiceAccountJson="$API_FIREBASE_SERVICE_ACCOUNT_JSON" \
  -e GpsArchive__BucketName="shalotrack-prod-gps-archive-054014030810" \
  -e GoogleMaps__RoadsApiKey="$API_GOOGLE_MAPS_ROADS_API_KEY" \
  -e GpsArchive__PurgeDryRun="$GPS_ARCHIVE_PURGE_DRY_RUN" \
  ${ecr_url}:latest

# 4. Node Exporter — host-level metrics for Prometheus
docker run -d --restart always --name node-exporter \
  --net="host" \
  --pid="host" \
  -v "/:/host:ro,rslave" \
  quay.io/prometheus/node-exporter:v1.8.2 \
  --path.rootfs=/host