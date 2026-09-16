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

# BAN FIX: Hard-stop if the DB connection string is missing or empty.
# Previously unguarded — if this SSM fetch failed for any reason (transient
# IAM timing on boot, missing parameter, network blip), the container would
# start with a blank ConnectionStrings__DefaultConnection, fall back to the
# placeholder password baked into appsettings.json ("SET_ON_SERVER"), and
# begin hammering Supabase with bad auth — triggering a Fail2ban IP ban on
# the EC2 within seconds. Aborting here is always safer.
if [ -z "$API_CONNECTION_STRING" ]; then
  echo "FATAL: /shalotrack/prod/api/csharp_connection_string is missing or empty in SSM."
  echo "FATAL: Aborting EC2 boot to prevent Supabase IP ban from bad-password retries."
  exit 1
fi

API_ADMIN_SYNC_KEY=$(aws ssm get-parameter \
  --name "/shalotrack/prod/api/admin_sync_key" \
  --with-decryption --query "Parameter.Value" --output text)

API_REALTIME_CONNECTION_STRING=$(aws ssm get-parameter \
  --name "/shalotrack/prod/api/realtime_connection_string" \
  --with-decryption --query "Parameter.Value" --output text)

# BAN FIX: Same guard for the realtime connection string.
# LocationNotificationListener holds a persistent LISTEN connection using
# this string. A bad or missing password here causes a retry loop every 5s
# that triggers the Supabase circuit breaker (ECIRCUITBREAKER) and IP ban.
# Root cause of the September 2026 production IP ban incident.
if [ -z "$API_REALTIME_CONNECTION_STRING" ]; then
  echo "FATAL: /shalotrack/prod/api/realtime_connection_string is missing or empty in SSM."
  echo "FATAL: Aborting EC2 boot to prevent Supabase IP ban from bad-password retries."
  exit 1
fi

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

# GPS ARCHIVE: Bucket name pulled from SSM — never hardcoded in this script.
# Hardcoding a bucket name here means any bucket rename requires a Terragrunt
# apply + ASG Instance Refresh. SSM makes it a one-liner.
# SSM key: /shalotrack/prod/api/gps_archive_bucket_name
GPS_ARCHIVE_BUCKET_NAME=$(aws ssm get-parameter \
  --name "/shalotrack/prod/api/gps_archive_bucket_name" \
  --query "Parameter.Value" --output text)
if [ -z "$GPS_ARCHIVE_BUCKET_NAME" ]; then
  GPS_ARCHIVE_BUCKET_NAME="shalotrack-prod-gps-archive-054014030810"
  echo "WARNING: gps_archive_bucket_name not found in SSM — falling back to hardcoded default"
fi

# GPS ARCHIVE: AWS region for S3 client inside the container.
GPS_ARCHIVE_REGION=$(aws ssm get-parameter \
  --name "/shalotrack/prod/api/gps_archive_region" \
  --query "Parameter.Value" --output text)
if [ -z "$GPS_ARCHIVE_REGION" ]; then
  GPS_ARCHIVE_REGION="ap-southeast-1"
  echo "WARNING: gps_archive_region not found in SSM — defaulting to ap-southeast-1"
fi

# GPS ARCHIVE: PurgeDryRun flag — controls whether archived GPS rows are
# actually deleted from Supabase after being written to S3.
#
# TOGGLING WITHOUT REDEPLOYMENT:
#   Step 1 — Update SSM (from your local machine, no EC2 access needed):
#     aws ssm put-parameter \
#       --name "/shalotrack/prod/api/gps_archive_purge_dry_run" \
#       --value "false" \
#       --type String \
#       --overwrite \
#       --region ap-southeast-1
#
#   Step 2 — Restart the container to pick up the new value (SSM-in, one command):
#     aws ssm start-session --target <instance-id> --region ap-southeast-1
#     sudo docker stop shalotrack-api && sudo docker rm shalotrack-api
#     sudo /var/lib/cloud/instance/scripts/part-001  # re-runs this script
#
#   DO NOT use ASG Instance Refresh just to flip this flag — that replaces
#   the EC2 entirely and takes 5-10 minutes. The container restart above
#   takes 15 seconds.
#
# Defaults TRUE — fails safe. A missing or misspelled key means
# "don't delete anything", never the other way around.
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
  -e GoogleMaps__RoadsApiKey="$API_GOOGLE_MAPS_ROADS_API_KEY" \
  -e GpsArchive__BucketName="$GPS_ARCHIVE_BUCKET_NAME" \
  -e GpsArchive__Region="$GPS_ARCHIVE_REGION" \
  -e GpsArchive__PurgeDryRun="$GPS_ARCHIVE_PURGE_DRY_RUN" \
  ${ecr_url}:latest

# 4. Node Exporter — host-level metrics for Prometheus
docker run -d --restart always --name node-exporter \
  --net="host" \
  --pid="host" \
  -v "/:/host:ro,rslave" \
  quay.io/prometheus/node-exporter:v1.8.2 \
  --path.rootfs=/host
