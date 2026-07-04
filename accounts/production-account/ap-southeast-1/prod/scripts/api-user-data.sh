#!/bin/bash
dnf update -y && dnf install -y docker
systemctl enable docker && systemctl start docker

aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}

docker run -d --restart always --name shalotrack-api \
  -p 80:80 \
  -e ASPNETCORE_HTTP_PORTS="80" \
  -e ConnectionStrings__DefaultConnection="${db_connection_string}" \
  ${ecr_url}:latest