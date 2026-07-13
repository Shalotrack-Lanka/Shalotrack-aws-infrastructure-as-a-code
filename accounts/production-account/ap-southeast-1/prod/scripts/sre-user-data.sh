#!/bin/bash
# Log script output for troubleshooting
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Starting SRE Infrastructure Bootstrap (AL2023) ==="
dnf update -y

# Install Docker Engine (Native to AL2023)
dnf install -y docker
systemctl enable docker
systemctl start docker

# Install Docker Compose plugin
mkdir -p /usr/libexec/docker/cli-plugins/
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose

if ! /usr/libexec/docker/cli-plugins/docker-compose version >/dev/null 2>&1; then
  echo "ERROR: docker-compose plugin failed to install correctly"
fi

if ! systemctl is-active --quiet docker; then
  echo "ERROR: Docker service is not running after install"
fi

echo "=== Attaching persistent SRE data volume ==="

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
REGION="ap-southeast-1"
VOLUME_ID="${volume_id}"

aws ec2 attach-volume --volume-id "$VOLUME_ID" --instance-id "$INSTANCE_ID" --device /dev/sdf --region "$REGION" \
  || echo "Volume already attached or attach failed — continuing"

aws ec2 wait volume-in-use --volume-ids "$VOLUME_ID" --region "$REGION"

DEVICE="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$(echo $VOLUME_ID | sed 's/-//')"

for i in {1..10}; do
  [ -e "$DEVICE" ] && break
  sleep 2
done

if [ ! -e "$DEVICE" ]; then
  echo "ERROR: Volume device never appeared at $DEVICE — skipping mount"
else
  if ! blkid "$DEVICE" > /dev/null 2>&1; then
    echo "=== Fresh volume detected, formatting as XFS ==="
    mkfs.xfs "$DEVICE"
  else
    echo "=== Existing filesystem found, skipping format ==="
  fi

  mkdir -p /mnt/sre-data
  mount "$DEVICE" /mnt/sre-data

  UUID=$(blkid -s UUID -o value "$DEVICE")
  grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /mnt/sre-data xfs defaults,nofail 0 2" >> /etc/fstab

  mkdir -p /mnt/sre-data/{prometheus,loki,tempo,grafana}

  # Ownership must match each container's internal non-root user, or they fail to write and crash-loop silently
  chown -R 472:472 /mnt/sre-data/grafana
  chown -R 65534:65534 /mnt/sre-data/prometheus
  chown -R 10001:10001 /mnt/sre-data/loki
  chown -R 10001:10001 /mnt/sre-data/tempo
fi

echo "=== Writing SRE stack configuration files ==="
mkdir -p /opt/sre-stack
cd /opt/sre-stack

cat > /opt/sre-stack/prometheus.yml << 'CONFEOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'otel-collector'
    static_configs:
      - targets: ['otel-collector:8889']
CONFEOF

cat > /opt/sre-stack/loki-config.yaml << 'CONFEOF'
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 720h

compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: filesystem
CONFEOF

cat > /opt/sre-stack/tempo.yaml << 'CONFEOF'
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
        http:

storage:
  trace:
    backend: local
    local:
      path: /var/tempo/traces
    wal:
      path: /var/tempo/wal

compactor:
  compaction:
    block_retention: 720h
CONFEOF

cat > /opt/sre-stack/otel-collector-config.yaml << 'CONFEOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

exporters:
  prometheus:
    endpoint: 0.0.0.0:8889
  loki:
    endpoint: http://loki:3100/loki/api/v1/push
  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true

service:
  pipelines:
    metrics:
      receivers: [otlp]
      exporters: [prometheus]
    logs:
      receivers: [otlp]
      exporters: [loki]
    traces:
      receivers: [otlp]
      exporters: [otlp/tempo]
CONFEOF

cat > /opt/sre-stack/docker-compose.yml << 'CONFEOF'
services:
  grafana:
    image: grafana/grafana:11.3.0
    ports:
      - "3000:3000"
    volumes:
      - /mnt/sre-data/grafana:/var/lib/grafana
    environment:
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_AUTH_ANONYMOUS_ENABLED=false
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=$${GRAFANA_ADMIN_PASSWORD}
      - GF_SECURITY_COOKIE_SECURE=true
      - GF_SECURITY_COOKIE_SAMESITE=strict
      - GF_SERVER_ROOT_URL=https://sre.shalotrack.com
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:v2.55.1
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
    ports:
      - "9090:9090"
    volumes:
      - /opt/sre-stack/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - /mnt/sre-data/prometheus:/prometheus
    restart: unless-stopped

  loki:
    image: grafana/loki:3.2.1
    ports:
      - "3100:3100"
    volumes:
      - /opt/sre-stack/loki-config.yaml:/etc/loki/local-config.yaml:ro
      - /mnt/sre-data/loki:/loki
    restart: unless-stopped

  tempo:
    image: grafana/tempo:2.6.1
    command: ["-config.file=/etc/tempo.yaml"]
    ports:
      - "3200:3200"
    volumes:
      - /opt/sre-stack/tempo.yaml:/etc/tempo.yaml:ro
      - /mnt/sre-data/tempo:/var/tempo
    restart: unless-stopped

  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.113.0
    command: ["--config=/etc/otel-collector-config.yaml"]
    ports:
      - "4317:4317"
      - "4318:4318"
      - "8889:8889"
    volumes:
      - /opt/sre-stack/otel-collector-config.yaml:/etc/otel-collector-config.yaml:ro
    depends_on:
      - prometheus
      - loki
      - tempo
    restart: unless-stopped
CONFEOF

echo "=== Fetching Grafana admin password from SSM ==="
GRAFANA_PW=$(aws ssm get-parameter --name "/shalotrack/prod/sre/grafana_admin_password" --with-decryption --query "Parameter.Value" --output text --region ap-southeast-1)

if [ -z "$GRAFANA_PW" ]; then
  echo "ERROR: Failed to retrieve Grafana admin password from SSM — stack will not start correctly"
else
  cat > /opt/sre-stack/.env << ENVEOF
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PW}
ENVEOF
  chmod 600 /opt/sre-stack/.env
fi

echo "=== Waiting for Docker to be fully ready before starting stack ==="
for i in {1..15}; do
  systemctl is-active --quiet docker && break
  sleep 2
done

echo "=== Starting SRE observability stack ==="
cd /opt/sre-stack
/usr/libexec/docker/cli-plugins/docker-compose up -d

echo "=== Bootstrap Complete ==="