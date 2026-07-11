include "root" {
  path = find_in_parent_folders()
}

dependency "vpc" { config_path = "../vpc" }
dependency "sg"  { config_path = "../security-groups" }
dependency "iam" { config_path = "../iam-roles" }
dependency "alb" { config_path = "../alb-shared" }
dependency "ecr" { config_path = "../ecr-repositories" }

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "private_subnets" { type = list(string) }
variable "web_sg" { type = string }
variable "iam_profile" { type = string }
variable "tg_arn" { type = string }
variable "ecr_url" { type = string }

variable "db_host" { type = string }
variable "db_port" { type = string }
variable "db_database" { type = string }
variable "db_username" { type = string }

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter { 
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"] 
  }
}

# 1. Converted to a Launch Template
resource "aws_launch_template" "admin" {
  name_prefix   = "shalotrack-admin-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"
  iam_instance_profile { name = var.iam_profile }
  vpc_security_group_ids = [var.web_sg]

  # Cleaned up: Removed app_key and db_password mapping references here
  user_data = base64encode(templatefile("${get_terragrunt_dir()}/../scripts/admin-user-data.sh", {
    ecr_url     = var.ecr_url
    db_host     = var.db_host
    db_port     = var.db_port
    db_database = var.db_database
    db_username = var.db_username
  }))

  tag_specifications {
    resource_type = "instance"
    tags = { Name = "shalotrack-admin-portal" }
  }
}

# 2. The Self-Healing ASG (Min 1, Max 1)
resource "aws_autoscaling_group" "admin" {
  name                = "shalotrack-admin-asg"
  vpc_zone_identifier = var.private_subnets
  target_group_arns   = [var.tg_arn]
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1

  launch_template {
    id      = aws_launch_template.admin.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "Admin-shalotrack"
    propagate_at_launch = true
  } 

}
EOF
}

inputs = {
  private_subnets = dependency.vpc.outputs.private_subnets
  web_sg          = dependency.sg.outputs.web_sg_id
  iam_profile     = dependency.iam.outputs.instance_profile_name
  tg_arn          = dependency.alb.outputs.admin_tg_arn
  ecr_url         = dependency.ecr.outputs.admin_repo_url
  
  # Cleaned up: Removed all local get_env secrets calls entirely
  db_host     = "aws-1-ap-southeast-1.pooler.supabase.com"
  db_port     = "5432" 
  db_database = "postgres"
  db_username = "postgres.napretecotsfackknsgf"
}