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

# 4. Repo for the Laravel Fleet Management Portal
resource "aws_ecr_repository" "fleet" {
  name                 = "shalotrack-fleet"
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keeps ECR storage bounded: last 15 tagged images (enough history to roll
# back several deploys), untagged images (orphaned by a re-push of the same
# tag) purged after 1 day. Not applied to gateway/api/admin — pre-existing,
# out of scope for this change, flagged separately.
resource "aws_ecr_lifecycle_policy" "fleet" {
  repository = aws_ecr_repository.fleet.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 15 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 15
        }
        action = { type = "expire" }
      }
    ]
  })
}

output "gateway_repo_url" { value = aws_ecr_repository.gateway.repository_url }
output "api_repo_url" { value = aws_ecr_repository.api.repository_url }
output "admin_repo_url" { value = aws_ecr_repository.admin.repository_url }
output "fleet_repo_url" { value = aws_ecr_repository.fleet.repository_url }
EOF
}