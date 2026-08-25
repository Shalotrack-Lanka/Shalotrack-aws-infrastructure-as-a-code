#!/bin/bash
dnf update -y && dnf install -y docker
systemctl enable docker && systemctl start docker

# 1. Authenticate with ECR
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}

# 2. Dynamically pull production database secrets from AWS SSM parameter store
export AWS_DEFAULT_REGION="ap-southeast-1"
GATEWAY_DATABASE_URL=$(aws ssm get-parameter --name "/shalotrack/prod/gateway/database_url" --with-decryption --query "Parameter.Value" --output text)
GATEWAY_CONNECTION_TIMEOUT=$(aws ssm get-parameter --name "/shalotrack/prod/gateway/connection_timeout" --with-decryption --query "Parameter.Value" --output text --region ap-southeast-1)
GATEWAY_MAX_CONNECTIONS=$(aws ssm get-parameter --name "/shalotrack/prod/gateway/max_connections" --with-decryption --query "Parameter.Value" --output text --region ap-southeast-1)

# 3. Spin up the TCP Gateway container, passing the secret securely from memory[cite: 3]
docker run -d --restart always --name shalotrack-gateway \
  -p 8000:9000 \
  -p 8001:9001 \
  -e PORT="9000" \
  -e DATABASE_URL="$GATEWAY_DATABASE_URL" \
  -e CONNECTION_TIMEOUT="$GATEWAY_CONNECTION_TIMEOUT" \
  -e MAX_CONNECTIONS="$GATEWAY_MAX_CONNECTIONS" \
  -e OTEL_EXPORTER_OTLP_ENDPOINT="http://otel.shalotrack.internal:4317" \
  ${ecr_url}:latest

# 4. Node Exporter — exposes host-level CPU/RAM/Disk/Network metrics for Prometheus.
# --net=host so it reports the real EC2 host's stats, not an isolated container's own.
docker run -d --restart always --name node-exporter \
  --net="host" \
  --pid="host" \
  -v "/:/host:ro,rslave" \
  quay.io/prometheus/node-exporter:v1.8.2 \
  --path.rootfs=/host