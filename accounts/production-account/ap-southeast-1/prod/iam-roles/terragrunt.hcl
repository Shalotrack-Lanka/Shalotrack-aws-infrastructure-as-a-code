include "root" {
  path = find_in_parent_folders()
}

# NEW — needed only for the bucket_arn output, to scope the new write
# policy below to exactly one bucket instead of granting s3:PutObject on
# everything. Must be applied BEFORE this module the first time — see
# deployment order note in chat.
dependency "s3_archive" {
  config_path = "../s3-gps-archive"

  mock_outputs = {
    bucket_arn = "arn:aws:s3:::mock-bucket"
  }
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "gps_archive_bucket_arn" { type = string }

# 1. Create the IAM Role for EC2
resource "aws_iam_role" "ec2_app_role" {
  name = "shalotrack-amoda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# 2. ECR Read-Only Access (To pull Docker images)
resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# 3. SSM Core (Allows AWS Session Manager for secure terminal access without SSH keys)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 4. S3 Read-Only (Future-proofing for downloading config files or backups from S3)
# NOTE: this managed policy already grants read/list on EVERY bucket in the
# account, including the new GPS archive bucket below — broader than ideal,
# pre-existing before this change, left as-is here. Worth tightening later
# by replacing this with per-bucket scoped read policies; out of scope for
# this ticket.
resource "aws_iam_role_policy_attachment" "s3_read" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# 5. Create the Instance Profile to attach to the ASGs
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "shalotrack-amoda-profile"
  role = aws_iam_role.ec2_app_role.name
}

# 6. Custom SSM Parameter Store Policy (Allows decryption of admin, gateway & api parameters)
resource "aws_iam_role_policy" "ssm_parameters" {
  name = "shalotrack-ssm-parameters-policy"
  role = aws_iam_role.ec2_app_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = [
          "arn:aws:ssm:ap-southeast-1:*:parameter/shalotrack/prod/admin/*",
          "arn:aws:ssm:ap-southeast-1:*:parameter/shalotrack/prod/gateway/*",
          "arn:aws:ssm:ap-southeast-1:*:parameter/shalotrack/prod/api/*"
        ]
      }
    ]
  })
}

# 7. NEW — GPS Archive Write Policy. Scoped to ONLY this one bucket's
# archive/ prefix, PutObject only. Read access for the same bucket already
# comes from the AmazonS3ReadOnlyAccess attachment above (#4) — deliberately
# not duplicating a GetObject/ListBucket grant here. No DeleteObject is
# granted anywhere in this file, on purpose: the S3 lifecycle rule is the
# only thing that ever deletes an archived trip.
resource "aws_iam_role_policy" "gps_archive_write" {
  name = "shalotrack-gps-archive-write-policy"
  role = aws_iam_role.ec2_app_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "$${var.gps_archive_bucket_arn}/archive/*"
      }
    ]
  })
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.ec2_profile.name
}

# 8. NEW (2026-10-27) — Dedicated role for the TCP Gateway ONLY. Deliberately
# NOT added to the shared shalotrack-amoda role above: that role is also used
# by Admin Portal, C# API, and Fleet. Admin Portal is the most
# internet-exposed of the four; if it were ever compromised and had this
# permission, an attacker could silently repoint gateway.shalotrack.internal
# at their own host and MITM every Command API call the C# API makes to the
# gateway. Keeping this on its own role means only the gateway instance
# itself can ever touch this DNS record.
resource "aws_iam_role" "gateway_role" {
  name = "shalotrack-gateway-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "gateway_ecr_read" {
  role       = aws_iam_role.gateway_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "gateway_ssm_core" {
  role       = aws_iam_role.gateway_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Scoped to gateway/* only -- unlike the shared role's SSM policy above,
# this instance never needs to read admin/* or api/* secrets.
resource "aws_iam_role_policy" "gateway_ssm_parameters" {
  name = "shalotrack-gateway-ssm-parameters-policy"
  role = aws_iam_role.gateway_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = [
          "arn:aws:ssm:ap-southeast-1:*:parameter/shalotrack/prod/gateway/*"
        ]
      }
    ]
  })
}

# NEW (2026-10-27) — lets the gateway instance keep gateway.shalotrack.internal
# pointed at its own current private IP on every boot (the ASG can replace
# this instance at any time: min=1, max=3). Scoped to ONLY this one hosted
# zone ARN -- not route53:*, not every zone in the account. This zone
# (shalotrack.internal, Z06675171G0TY639DCHZN) was created manually in the
# console, not by Terraform -- see chat 2026-10-27 for why; worth importing
# properly later, out of scope for this change.
resource "aws_iam_role_policy" "gateway_dns_self_register" {
  name = "shalotrack-gateway-dns-policy"
  role = aws_iam_role.gateway_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = "arn:aws:route53:::hostedzone/Z06675171G0TY639DCHZN"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "gateway_profile" {
  name = "shalotrack-gateway-profile"
  role = aws_iam_role.gateway_role.name
}

output "gateway_instance_profile_name" {
  value = aws_iam_instance_profile.gateway_profile.name
}
EOF
}

inputs = {
  gps_archive_bucket_arn = dependency.s3_archive.outputs.bucket_arn
}