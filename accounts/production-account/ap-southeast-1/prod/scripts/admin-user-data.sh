#!/bin/bash
dnf update -y && dnf install -y docker
systemctl enable docker && systemctl start docker

aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}

docker run -d --restart always --name shalotrack-admin \
  -p 80:80 \
  -e APP_ENV="production" \
  -e APP_DEBUG="false" \
  -e APP_KEY="${app_key}" \
  -e DB_CONNECTION="pgsql" \
  -e DB_HOST="${db_host}" \
  -e DB_PORT="${db_port}" \
  -e DB_DATABASE="${db_database}" \
  -e DB_USERNAME="${db_username}" \
  -e DB_PASSWORD="${db_password}" \
  ${ecr_url}:latest


#clear cache by forcing
docker exec shalotrack-admin php artisan config:clear
docker exec shalotrack-admin php artisan cache:clear