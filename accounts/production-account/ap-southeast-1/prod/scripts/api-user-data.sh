#!/bin/bash
dnf update -y && dnf install -y docker
systemctl enable docker && systemctl start docker
# 1. Authenticate with ECR
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}
# 2. Pull down production secrets directly out of AWS SSM
export AWS_DEFAULT_REGION="ap-southeast-1"
API_CONNECTION_STRING=$(aws ssm get-parameter --name "/shalotrack/prod/api/csharp_connection_string" --with-decryption --query "Parameter.Value" --output text)
API_ADMIN_SYNC_KEY=$(aws ssm get-parameter --name "/shalotrack/prod/api/admin_sync_key" --with-decryption --query "Parameter.Value" --output text)
API_REALTIME_CONNECTION_STRING=$(aws ssm get-parameter --name "/shalotrack/prod/api/realtime_connection_string" --with-decryption --query "Parameter.Value" --output text)
# NEW — was missing entirely, which is why every fresh instance crash-loops with
# "Firebase:ServiceAccountJson is not configured" (see SETUP_PART1_CREDENTIALS.md).
# Parameter name below follows this file's existing naming convention — verify it
# actually exists in SSM before trusting it (see chat).
API_FIREBASE_SERVICE_ACCOUNT_JSON=$(aws ssm get-parameter --name "/shalotrack/prod/api/firebase_service_account_json" --with-decryption --query "Parameter.Value" --output text)
if [ -z "$API_FIREBASE_SERVICE_ACCOUNT_JSON" ]; then
  echo "ERROR: Firebase service account JSON not found in SSM — container will crash-loop without it"
fi
# NEW — Roads API key for live-trail road-snapping (RoadSnappingService.cs).
# Program.cs fail-fast-checks GoogleMaps:RoadsApiKey at startup, same as Firebase
# above — without this, every fresh instance will crash-loop with
# "GoogleMaps:RoadsApiKey is not configured." Confirmed to exist in SSM as of
# this addition (created via Cloud Console + AWS Console together, see chat).
API_GOOGLE_MAPS_ROADS_API_KEY=$(aws ssm get-parameter --name "/shalotrack/prod/api/google_maps_roads_api_key" --with-decryption --query "Parameter.Value" --output text)
if [ -z "$API_GOOGLE_MAPS_ROADS_API_KEY" ]; then
  echo "ERROR: Google Maps Roads API key not found in SSM — container will crash-loop without it"
fi
# 3. Spin up the C# API container using runtime memory injection
docker run -d --restart always --name shalotrack-api \
  -p 80:8080 \
  -e ConnectionStrings__DefaultConnection="$API_CONNECTION_STRING" \
  -e ConnectionStrings__RealtimeConnection="$API_REALTIME_CONNECTION_STRING" \
  -e AdminSync__Key="$API_ADMIN_SYNC_KEY" \
  -e Firebase__ServiceAccountJson="$API_FIREBASE_SERVICE_ACCOUNT_JSON" \
  -e GpsArchive__BucketName="shalotrack-prod-gps-archive-054014030810" \
  -e GoogleMaps__RoadsApiKey="$API_GOOGLE_MAPS_ROADS_API_KEY" \
  -e GpsArchive__PurgeDryRun="true" \
  ${ecr_url}:latest
# 4. Node Exporter — exposes host-level CPU/RAM/Disk/Network metrics for Prometheus.
# --net=host so it reports the real EC2 host's stats, not an isolated container's own.
docker run -d --restart always --name node-exporter \
  --net="host" \
  --pid="host" \
  -v "/:/host:ro,rslave" \
  quay.io/prometheus/node-exporter:v1.8.2 \
  --path.rootfs=/host
