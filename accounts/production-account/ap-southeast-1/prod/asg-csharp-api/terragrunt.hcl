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

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter { 
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"] 
  }
}

resource "aws_launch_template" "api" {
  name_prefix   = "shalotrack-api-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.small"
  iam_instance_profile { name = var.iam_profile }
  vpc_security_group_ids = [var.web_sg]

  # Cleaned up: Removed db_connection_string from the template rendering layout completely[cite: 7]
  user_data = base64encode(templatefile("${get_terragrunt_dir()}/../scripts/api-user-data.sh", {
    ecr_url = var.ecr_url
  }))
}

resource "aws_autoscaling_group" "api" {
  name                = "shalotrack-api-asg"
  vpc_zone_identifier = var.private_subnets
  target_group_arns   = [var.tg_arn]
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1
  launch_template {
    id      = aws_launch_template.api.id
    version = "$Latest"
  }
}
EOF
}

inputs = {
  private_subnets = dependency.vpc.outputs.private_subnets
  web_sg          = dependency.sg.outputs.web_sg_id
  iam_profile     = dependency.iam.outputs.instance_profile_name
  tg_arn          = dependency.alb.outputs.api_tg_arn
  ecr_url         = dependency.ecr.outputs.api_repo_url
  
  # Cleaned up: db_connection_string get_env check has been scrubbed out entirely[cite: 7]
}