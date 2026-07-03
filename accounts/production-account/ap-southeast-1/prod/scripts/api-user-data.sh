#!/bin/bash
dnf update -y && dnf install -y docker
systemctl enable docker && systemctl start docker
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}

docker run -d --restart always --name shalotrack-api \
  -p 80:80 \
  -e ASPNETCORE_HTTP_PORTS="80" \
  -e ConnectionStrings__DefaultConnection="Host=aws-1-ap-southeast-1.pooler.supabase.com;Port=5432;Database=postgres;Username=postgres.riyjkfwxkamqbuuuwdli;Password=tadK*7ASa_#,-NL" \
  ${ecr_url}:latest