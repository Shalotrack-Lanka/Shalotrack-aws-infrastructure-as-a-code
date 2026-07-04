#!/bin/bash
dnf update -y && dnf install -y docker
systemctl enable docker && systemctl start docker

aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}

# Passwords are swept out; variables are safely dynamically injected
docker run -d --restart always --name shalotrack-gateway \
  -p 8000:9000 \
  -e PORT="9000" \
  -e DATABASE_URL="${database_url}" \
  ${ecr_url}:latest