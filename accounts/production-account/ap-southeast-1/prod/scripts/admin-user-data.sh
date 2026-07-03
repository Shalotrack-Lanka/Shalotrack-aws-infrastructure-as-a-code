#!/bin/bash
dnf update -y && dnf install -y docker
systemctl enable docker && systemctl start docker
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}


docker run -d --restart always --name shalotrack-admin \
  -p 80:80 \
  -e APP_ENV="production" \
  -e APP_DEBUG="false" \
  -e APP_KEY="[YOUR_APP_KEY]" \
  -e DB_CONNECTION="pgsql" \
  -e DB_HOST="aws-0-ap-southeast-1.pooler.supabase.com" \
  -e DB_PORT="6543" \
  -e DB_DATABASE="postgres" \
  -e DB_USERNAME="postgres.[YOUR_PROJECT]" \
  -e DB_PASSWORD="[YOUR_PASSWORD]" \
  ${ecr_url}:latest