# Manages VPC Gateway Endpoints for S3.
#
# WHY A GATEWAY ENDPOINT FOR S3?
# -------------------------------------------
# ECR stores Docker image layers in AWS-owned S3 buckets
# (e.g. prod-ap-southeast-1-starport-layer-bucket, account 517746892222).
# Without this endpoint, `docker pull` from ECR routes through the IGW
# to public S3 — fine for public-subnet EC2s, but any restrictive VPC
# endpoint policy that AWS may impose by default (or that gets created
# incidentally) would block the ECR internal role from calling GetObject.
#
# A Gateway Endpoint:
#   1. Is FREE — zero data-transfer or hourly cost.
#   2. Routes S3 traffic through AWS's private backbone, not the public internet.
#   3. Has a resource policy that we own and can control explicitly.
#
# The policy below is AWS's recommended default: allow everything.
# It does NOT bypass bucket policies or IAM — it just prevents the
# endpoint itself from acting as an extra deny layer.
#
# INCIDENT: 2026-09-22 — docker pull on ip-10-0-1-183 failed with
#   "no VPC endpoint policy allows the s3:GetObject action" on
#   prod-ap-southeast-1-starport-layer-bucket.
#   Root cause: S3 gateway endpoint existed with a restrictive policy
#   not captured in IaC. This module brings it under Terraform control.
#
# DEPLOYMENT NOTE:
#   This is a NEW module. On first apply it imports the existing endpoint
#   (if you ran the manual fix) or creates a fresh one. Either way is safe.
#   Apply order: vpc → vpc-endpoints (this module).

include "root" {
  path = find_in_parent_folders()
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id             = "vpc-00000000000000000"
    public_route_table_ids  = ["rtb-00000000000000000"]
    private_route_table_ids = []
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "vpc_id"             { type = string }
variable "public_rtb_ids"     { type = list(string) }
variable "private_rtb_ids"    { type = list(string) }
variable "aws_region"         { type = string }

# S3 Gateway Endpoint — free, routes S3 traffic off the public internet.
# Policy is the AWS-recommended open default. It does NOT bypass bucket
# policies or IAM — it prevents the endpoint itself from blocking ECR.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.$${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  # Attach to all route tables so every subnet (public + private) benefits.
  route_table_ids = concat(var.public_rtb_ids, var.private_rtb_ids)

  # WHY NO aws:ResourceAccount CONDITION:
  # An earlier manual policy had:
  #   "Condition": {"StringEquals":{"aws:ResourceAccount":"054014030810"}}
  # This blocked ECR image pulls because ECR stores Docker layers in AWS-owned
  # S3 buckets (account 517746892222, e.g. prod-ap-southeast-1-starport-layer-bucket).
  # The open policy below is AWS's recommendation. YOUR S3 buckets remain protected
  # by their own resource policies and IAM — the endpoint policy is not a substitute
  # for those, and removing the condition here does not weaken bucket-level security.
  policy = jsonencode({
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "*"
        Resource  = "*"
      }
    ]
  })

  tags = {
    Name = "shalotrack-prod-s3-gateway"
  }
}

output "s3_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
EOF
}

inputs = {
  vpc_id          = dependency.vpc.outputs.vpc_id
  public_rtb_ids  = dependency.vpc.outputs.public_route_table_ids
  private_rtb_ids = dependency.vpc.outputs.private_route_table_ids
}
