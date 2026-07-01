include "root" {
  path = find_in_parent_folders()
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
# 1. Repo for the Python TCP Parser
resource "aws_ecr_repository" "gateway" {
  name                 = "shalotrack-gateway"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# 2. Repo for the C# REST API
resource "aws_ecr_repository" "api" {
  name                 = "shalotrack-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# 3. Repo for the Laravel Admin Portal
resource "aws_ecr_repository" "admin" {
  name                 = "shalotrack-admin"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "gateway_repo_url" { value = aws_ecr_repository.gateway.repository_url }
output "api_repo_url" { value = aws_ecr_repository.api.repository_url }
output "admin_repo_url" { value = aws_ecr_repository.admin.repository_url }
EOF
}