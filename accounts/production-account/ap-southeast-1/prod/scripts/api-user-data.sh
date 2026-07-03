#!/bin/bash
dnf update -y && dnf install -y docker
systemctl enable docker && systemctl start docker
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin ${ecr_url}
docker run -d --restart always -p 80:80 ${ecr_url}:latest