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
# 3. Spin up the C# API container using runtime memory injection
docker run -d --restart always --name shalotrack-api \
  -p 80:8080 \
  -e ConnectionStrings__DefaultConnection="$API_CONNECTION_STRING" \
  -e ConnectionStrings__RealtimeConnection="$API_REALTIME_CONNECTION_STRING" \
  -e AdminSync__Key="$API_ADMIN_SYNC_KEY" \
  ${ecr_url}:latest
