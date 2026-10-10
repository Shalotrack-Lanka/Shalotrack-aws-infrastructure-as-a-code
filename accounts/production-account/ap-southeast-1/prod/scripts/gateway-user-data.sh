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

# 2. Dynamically pull production secrets from AWS SSM parameter store
export AWS_DEFAULT_REGION="ap-southeast-1"
GATEWAY_DATABASE_URL=$(aws ssm get-parameter --name "/shalotrack/prod/gateway/database_url" --with-decryption --query "Parameter.Value" --output text)
GATEWAY_CONNECTION_TIMEOUT=$(aws ssm get-parameter --name "/shalotrack/prod/gateway/connection_timeout" --query "Parameter.Value" --output text --region ap-southeast-1)
GATEWAY_MAX_CONNECTIONS=$(aws ssm get-parameter --name "/shalotrack/prod/gateway/max_connections" --query "Parameter.Value" --output text --region ap-southeast-1)
GATEWAY_DB_POOL_MIN=$(aws ssm get-parameter --name "/shalotrack/prod/gateway/db_pool_min" --query "Parameter.Value" --output text --region ap-southeast-1)
GATEWAY_DB_POOL_MAX=$(aws ssm get-parameter --name "/shalotrack/prod/gateway/db_pool_max" --query "Parameter.Value" --output text --region ap-southeast-1)

# 3. Start the TCP Gateway container
docker run -d --restart always --name shalotrack-gateway \
  -p 8000:9000 \
  -p 8001:9001 \
  -e PORT="9000" \
  -e DATABASE_URL="$GATEWAY_DATABASE_URL" \
  -e CONNECTION_TIMEOUT="$GATEWAY_CONNECTION_TIMEOUT" \
  -e MAX_CONNECTIONS="$GATEWAY_MAX_CONNECTIONS" \
  -e DB_POOL_MIN="$GATEWAY_DB_POOL_MIN" \
  -e DB_POOL_MAX="$GATEWAY_DB_POOL_MAX" \
  ${ecr_url}:latest