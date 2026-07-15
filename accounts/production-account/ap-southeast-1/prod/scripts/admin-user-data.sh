#!/bin/bash
dnf update -y && dnf install -y docker
systemctl enable docker && systemctl start docker

# 1. Authenticate with ECR
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}

# 2. Dynamically fetch sensitive production credentials out of AWS SSM
export AWS_DEFAULT_REGION="ap-southeast-1"
ADMIN_APP_KEY=$(aws ssm get-parameter --name "/shalotrack/prod/admin/app_key" --with-decryption --query "Parameter.Value" --output text)
ADMIN_DB_PASSWORD=$(aws ssm get-parameter --name "/shalotrack/prod/admin/db_password" --with-decryption --query "Parameter.Value" --output text)
ADMIN_SYNC_KEY=$(aws ssm get-parameter --name "/shalotrack/prod/admin/sync_key" --with-decryption --query "Parameter.Value" --output text)

# 3. Spin up the application container injecting runtime parameters
# Note: APP_URL is correctly pointed to your production domain to resolve the 419 error
docker run -d --restart always --name shalotrack-admin \
  -p 80:80 \
  -e APP_NAME="Laravel" \
  -e APP_ENV="production" \
  -e APP_DEBUG="false" \
  -e APP_KEY="$ADMIN_APP_KEY" \
  -e APP_URL="https://admin.shalotrack.com" \
  -e SHALOTRACK_API_BASE_URL="https://api.shalotrack.com" \
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

# 4. Wait brief moment for the container app initialization layer to stabilize
sleep 3

# 5. Clear application runtime caches
docker exec shalotrack-admin php artisan config:clear
docker exec shalotrack-admin php artisan cache:clear