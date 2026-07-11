include "root" {
  path = find_in_parent_folders()
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
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
resource "aws_iam_role_policy_attachment" "s3_read" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# 6. Create the Instance Profile to attach to the ASGs
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "shalotrack-amoda-profile"
  role = aws_iam_role.ec2_app_role.name
}

# 7. Custom SSM Parameter Store Policy (Allows decryption of app parameters)
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
        Resource = "arn:aws:ssm:*:*:parameter/shalotrack/prod/admin/*"
      }
    ]
  })
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.ec2_profile.name
}
EOF
}