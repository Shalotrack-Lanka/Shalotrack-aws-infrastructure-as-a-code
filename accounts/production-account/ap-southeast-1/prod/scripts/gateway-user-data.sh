#!/bin/bash
dnf update -y && dnf install -y docker
systemctl enable docker && systemctl start docker
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}

docker run -d --restart always --name shalotrack-gateway \
  -p 8000:9000 \
  -e PORT="9000" \
  -e DATABASE_URL="postgresql://postgres.riyjkfwxkamqbuuuwdli:tadK*7ASa_#,-NL@aws-1-ap-southeast-1.pooler.supabase.com:5432/postgres" \
  ${ecr_url}:latest