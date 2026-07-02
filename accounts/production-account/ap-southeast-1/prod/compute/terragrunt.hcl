include "root" {
  path = find_in_parent_folders()
}

# 1. Pull data from all previous phases
dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = { private_subnets = ["subnet-mock1", "subnet-mock2"] }
}
dependency "sg" {
  config_path = "../security-groups"
  mock_outputs = { gateway_sg_id = "sg-mock1", web_sg_id = "sg-mock2" }
}
dependency "iam" {
  config_path = "../iam-roles"
  mock_outputs = { instance_profile_name = "mock-profile" }
}
dependency "nlb" {
  config_path = "../nlb-gateway"
  mock_outputs = { gateway_tg_arn = "arn:mock:tg" }
}
dependency "alb" {
  config_path = "../alb-shared"
  mock_outputs = { api_tg_arn = "arn:mock:tg", admin_tg_arn = "arn:mock:tg" }
}
dependency "ecr" {
  config_path = "../ecr-repositories"
  mock_outputs = {
    gateway_repo_url = "mock.dkr.ecr.region.amazonaws.com/gateway"
    api_repo_url     = "mock.dkr.ecr.region.amazonaws.com/api"
    admin_repo_url   = "mock.dkr.ecr.region.amazonaws.com/admin"
  }
}

# 2. Generate the Terraform code
generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "private_subnets" { type = list(string) }
variable "gateway_sg" { type = string }
variable "web_sg" { type = string }
variable "iam_profile" { type = string }
variable "tg_gateway" { type = string }
variable "tg_api" { type = string }
variable "tg_admin" { type = string }
variable "ecr_gateway" { type = string }
variable "ecr_api" { type = string }
variable "ecr_admin" { type = string }

# Use Amazon Linux 2023 (Optimized for AWS natively)
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# --- 1. GATEWAY (TCP PARSER) ---
resource "aws_launch_template" "gateway" {
  name_prefix   = "shalotrack-gateway-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro" 
  iam_instance_profile { name = var.iam_profile }
  vpc_security_group_ids = [var.gateway_sg]

  # The Startup Script: Installs Docker, authenticates with ECR, and runs the image
  user_data = base64encode(<<-EOT
    #!/bin/bash
    dnf update -y && dnf install -y docker
    systemctl enable docker && systemctl start docker
    aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin $${var.ecr_gateway}
    docker run -d --restart always -p 8000:8000 $${var.ecr_gateway}:latest
  EOT
  )
}

resource "aws_autoscaling_group" "gateway" {
  name                = "shalotrack-gateway-asg"
  vpc_zone_identifier = var.private_subnets
  target_group_arns   = [var.tg_gateway]
  min_size            = 1
  max_size            = 3
  desired_capacity    = 1
  launch_template {
    id      = aws_launch_template.gateway.id
    version = "$Latest"
  }
}

# --- 2. C# REST API ---
resource "aws_launch_template" "api" {
  name_prefix   = "shalotrack-api-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"
  iam_instance_profile { name = var.iam_profile }
  vpc_security_group_ids = [var.web_sg]

  user_data = base64encode(<<-EOT
    #!/bin/bash
    dnf update -y && dnf install -y docker
    systemctl enable docker && systemctl start docker
    aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin $${var.ecr_api}
    docker run -d --restart always -p 80:80 $${var.ecr_api}:latest
  EOT
  )
}

resource "aws_autoscaling_group" "api" {
  name                = "shalotrack-api-asg"
  vpc_zone_identifier = var.private_subnets
  target_group_arns   = [var.tg_api]
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1
  launch_template {
    id      = aws_launch_template.api.id
    version = "$Latest"
  }
}

# --- 3. LARAVEL ADMIN ---
resource "aws_launch_template" "admin" {
  name_prefix   = "shalotrack-admin-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"
  iam_instance_profile { name = var.iam_profile }
  vpc_security_group_ids = [var.web_sg]

  user_data = base64encode(<<-EOT
    #!/bin/bash
    dnf update -y && dnf install -y docker
    systemctl enable docker && systemctl start docker
    aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin $${var.ecr_admin}
    docker run -d --restart always -p 80:80 $${var.ecr_admin}:latest
  EOT
  )
}

resource "aws_autoscaling_group" "admin" {
  name                = "shalotrack-admin-asg"
  vpc_zone_identifier = var.private_subnets
  target_group_arns   = [var.tg_admin]
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1
  launch_template {
    id      = aws_launch_template.admin.id
    version = "$Latest"
  }
}
EOF
}

# 3. Pass all the dependency data into the variables
inputs = {
  private_subnets = dependency.vpc.outputs.private_subnets
  gateway_sg      = dependency.sg.outputs.gateway_sg_id
  web_sg          = dependency.sg.outputs.web_sg_id
  iam_profile     = dependency.iam.outputs.instance_profile_name
  tg_gateway      = dependency.nlb.outputs.gateway_tg_arn
  tg_api          = dependency.alb.outputs.api_tg_arn
  tg_admin        = dependency.alb.outputs.admin_tg_arn
  ecr_gateway     = dependency.ecr.outputs.gateway_repo_url
  ecr_api         = dependency.ecr.outputs.api_repo_url
  ecr_admin       = dependency.ecr.outputs.admin_repo_url
}