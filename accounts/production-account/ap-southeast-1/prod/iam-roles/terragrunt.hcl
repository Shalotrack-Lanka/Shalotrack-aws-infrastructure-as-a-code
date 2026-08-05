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

# 4. CloudWatch Agent (Future-proofing for sending server logs and custom metrics)
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# 5. S3 Read-Only (Future-proofing for downloading config files or backups from S3)
# NOTE: this managed policy already grants read/list on EVERY bucket in the
# account, including the new GPS archive bucket below — broader than ideal,
# pre-existing before this change, left as-is here. Worth tightening later
# by replacing this with per-bucket scoped read policies; out of scope for
# this ticket.
resource "aws_iam_role_policy_attachment" "s3_read" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# 6. Create the Instance Profile to attach to the ASGs
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "shalotrack-amoda-profile"
  role = aws_iam_role.ec2_app_role.name
}

# 7. Custom SSM Parameter Store Policy (Allows decryption of admin, gateway, api & sre parameters)
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
          "arn:aws:ssm:ap-southeast-1:*:parameter/shalotrack/prod/api/*",
          "arn:aws:ssm:ap-southeast-1:*:parameter/shalotrack/prod/sre/*"
        ]
      }
    ]
  })
}

# 8. EBS Attach Policy (Allows the SRE instance to attach its persistent data volume to itself on boot)
resource "aws_iam_role_policy" "ebs_attach" {
  name = "shalotrack-sre-ebs-attach-policy"
  role = aws_iam_role.ec2_app_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:DescribeVolumes",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "route53_internal" {
  name = "shalotrack-sre-route53-policy"
  role = aws_iam_role.ec2_app_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:GetHostedZone"]
        Resource = "*"
      }
    ]
  })
}

# 9. NEW — GPS Archive Write Policy. Scoped to ONLY this one bucket's
# archive/ prefix, PutObject only. Read access for the same bucket already
# comes from the AmazonS3ReadOnlyAccess attachment above (#5) — deliberately
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
EOF
}

inputs = {
  gps_archive_bucket_arn = dependency.s3_archive.outputs.bucket_arn
}
