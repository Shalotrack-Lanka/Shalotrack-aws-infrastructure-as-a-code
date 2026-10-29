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

# SECURITY (2026-10-24): shared secret for the gateway's Command API (port 9001 inside the
# container, 8001 on the host). command_api.py REFUSES TO START the Command API when
# COMMAND_API_KEY is empty (fails closed), which silently disables "send commands to devices"
# from the ERP Device Command Center and the C# API -- GPS ingestion on 9000 is unaffected.
# This line was missing from this script until 2026-10-29, so every gateway server booted from
# it had no working Command API. Must hold the SAME value as
#   /shalotrack/prod/admin/gateway_command_api_key
#   /shalotrack/prod/api/gateway_command_api_key
# Warn instead of aborting the boot: GPS ingestion must keep running even if this is missing.
GATEWAY_COMMAND_API_KEY=$(aws ssm get-parameter --name "/shalotrack/prod/gateway/command_api_key" --with-decryption --query "Parameter.Value" --output text --region ap-southeast-1)
if [ -z "$GATEWAY_COMMAND_API_KEY" ]; then
  echo "WARNING: /shalotrack/prod/gateway/command_api_key is missing or empty in SSM."
  echo "WARNING: Command API will not start -- ERP Device Command Center will show the gateway as unreachable."
fi

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
  -e COMMAND_API_KEY="$GATEWAY_COMMAND_API_KEY" \
  ${ecr_url}:latest

# ---------------------------------------------------------------------------
# DYNAMIC DNS SELF-REGISTRATION (2026-10-27)
# gateway.shalotrack.internal (private Route53 zone) is what ShaloTrack_API
# calls for the Gateway Command API (port 8001, VPC-internal only -- see
# security-groups/terragrunt.hcl). This ASG can replace this instance at any
# time (min=1, max=3), which hands the new instance a different private IP.
# Without this block, the DNS record goes stale on every replacement and the
# API silently starts calling a dead or wrong host. Runs on every boot,
# UPSERT, so the record always reflects whichever instance is actually
# running right now.
#
# Deliberately best-effort, not fail-fast: the gateway's own job (serving
# GPS device connections on 8000) does not depend on this succeeding, so a
# transient Route53 API hiccup should not crash-loop the boot. It still logs
# loudly on failure so it is visible in `docker logs`/cloud-init output.
#
# IAM: shalotrack-gateway-role grants route53:ChangeResourceRecordSets
# scoped to ONLY this one hosted zone -- not the shared admin/api/fleet
# role. See iam-roles/terragrunt.hcl for why this lives on its own role.
# ---------------------------------------------------------------------------
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

if [ -z "$PRIVATE_IP" ]; then
  echo "WARNING: could not read instance private IP from IMDS -- skipping DNS self-registration."
  echo "WARNING: gateway.shalotrack.internal may now be pointing at a stale/dead instance."
else
  aws route53 change-resource-record-sets \
    --hosted-zone-id "${hosted_zone_id}" \
    --change-batch '{
      "Comment": "Gateway self-registration on boot",
      "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "gateway.shalotrack.internal",
          "Type": "A",
          "TTL": 60,
          "ResourceRecords": [{ "Value": "'"$PRIVATE_IP"'" }]
        }
      }]
    }'

  if [ $? -ne 0 ]; then
    echo "WARNING: Route53 self-registration failed. gateway.shalotrack.internal may now be stale."
    echo "WARNING: Gateway service itself is unaffected -- this only breaks the API's ability to find it by name."
  else
    echo "DNS self-registration OK: gateway.shalotrack.internal -> $PRIVATE_IP"
  fi
fi